package com.dvplayer.core.vfs

import android.net.Uri
import android.util.Log
import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.msfscc.FileAttributes
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import java.util.EnumSet

/**
 * SMB2/3 浏览与随机读（A9）。
 *
 * 地址格式：`smb://host[:port]/share/path`。一台机器一个实例（一个连接 +
 * 一个会话，按 share 复用 [DiskShare]），所以 [close] 要显式调用。
 *
 * 播放不走 SMB 协议本身：`VfsHttpBridge` 把 [VfsFile] 通过 127.0.0.1 的 HTTP
 * 暴露出去，mpv / Media3 都能直接播——它们都不支持 smb://。
 */
class SmbVfs(
    private val user: String = "",
    private val password: String = "",
    private val domain: String = "",
) : Vfs, AutoCloseable {

    private val tag = "DvSmb"
    private val client = SMBClient()
    private var connection: Connection? = null
    private var session: Session? = null
    private val shares = HashMap<String, DiskShare>()
    private var defaultHost = ""
    private var connectPort = 445

    /** 允许 `SmbVfs(url, ...)` 之外的简写：host 从第一个 smb:// 地址里取。 */
    constructor(url: String, user: String, password: String, domain: String = "") : this(
        user,
        password,
        domain,
    ) {
        val p = parse(url)
        defaultHost = p.host
        connectPort = p.port
    }

    data class SmbPath(val host: String, val port: Int, val share: String, val path: String)

    /**
     * 不用 [java.net.URI]：NAS 上的目录名常带空格 / 括号 / 中文，URI 会直接抛
     * URISyntaxException。这里手工拆，且每段先 [Uri.decode] 一次——[VfsEntry.path]
     * 是编码过的，命令行传进来的原始路径也能吃。
     */
    private fun parse(url: String): SmbPath {
        require(url.startsWith("smb://", ignoreCase = true)) { "不是 smb:// 地址：$url" }
        val rest = url.substring("smb://".length)
        val hostPart = rest.substringBefore('/')
        val rawPath = if (rest.contains('/')) rest.substringAfter('/') else ""
        val host = hostPart.substringBefore(':').ifEmpty {
            defaultHost.ifEmpty { throw IllegalArgumentException("缺少主机：$url") }
        }
        val port = hostPart.substringAfter(':', "").toIntOrNull()?.takeIf { it > 0 } ?: 445
        val segments = rawPath.split('/').map { Uri.decode(it) }.filter { it.isNotEmpty() && it != "." }
        require(segments.isNotEmpty()) { "缺少共享名：$url" }
        return SmbPath(host, port, segments.first(), segments.drop(1).joinToString("\\"))
    }

    private fun share(name: String): DiskShare {
        shares[name]?.let { return it }
        val conn = connection ?: client.connect(
            defaultHost.ifEmpty { throw IllegalStateException("没有主机名") },
            connectPort,
        ).also { connection = it }
        val sess = session ?: run {
            val auth = AuthenticationContext(user, password.toCharArray(), domain)
            try {
                conn.authenticate(auth).also { session = it }
            } catch (t: Throwable) {
                // 认证失败时把协商结果一起打出来：区分密码错、方言 / 签名不兼容。
                Log.e(
                    tag,
                    "SMB 认证失败 user=$user domain=${if (domain.isEmpty()) "空" else domain} " +
                        "密码长度=${password.length}: ${t.javaClass.simpleName} ${t.message}",
                    t,
                )
                throw t
            }
        }
        val disk = sess.connectShare(name) as DiskShare
        shares[name] = disk
        return disk
    }

    private fun shareFor(p: SmbPath): DiskShare {
        // 不同 host / port 的地址在同一个实例里不混用。
        if (p.host != defaultHost || p.port != connectPort) {
            throw IllegalStateException("SmbVfs 只服务 $defaultHost:$connectPort")
        }
        return share(p.share)
    }

    override fun list(dir: String): List<VfsEntry> {
        val p = parse(dir)
        val share = shareFor(p)
        val items = share.list(p.path)
        val entries = items
            .filter { it.fileName != "." && it.fileName != ".." }
            .map { info ->
                val isDir = info.fileAttributes and
                    FileAttributes.FILE_ATTRIBUTE_DIRECTORY.value != 0L
                val childPath = if (p.path.isEmpty()) info.fileName else "${p.path}\\${info.fileName}"
                // 每段单独编码：空格 / [ ] / ! 这些在 URI 里非法，原样拼会解析失败。
                val encoded = childPath.split('\\').joinToString("/") { Uri.encode(it, "") }
                VfsEntry(
                    name = info.fileName,
                    path = "smb://${Uri.encode(p.host)}/${Uri.encode(p.share, "")}/$encoded" +
                        if (isDir) "/" else "",
                    isDirectory = isDir,
                    size = info.endOfFile,
                    lastModifiedMs = runCatching { info.lastWriteTime.toEpochMillis() }
                        .getOrDefault(-1L),
                )
            }
        Log.i(tag, "list ${p.share}\\${p.path} -> ${entries.size} 项")
        return entries.sortedWith(
            compareByDescending<VfsEntry> { it.isDirectory }.thenBy { it.name },
        )
    }

    override fun open(path: String): VfsFile {
        val p = parse(path)
        val share = shareFor(p)
        val size = share.getFileInformation(p.path).standardInformation.endOfFile
        val file = share.openFile(
            p.path,
            EnumSet.of(AccessMask.GENERIC_READ),
            null,
            EnumSet.of(
                SMB2ShareAccess.FILE_SHARE_READ,
                SMB2ShareAccess.FILE_SHARE_WRITE,
                SMB2ShareAccess.FILE_SHARE_DELETE,
            ),
            SMB2CreateDisposition.FILE_OPEN,
            null,
        )
        Log.i(tag, "open ${p.share}\\${p.path} size=$size")
        return object : VfsFile {
            private var closed = false

            override val size: Long = size

            @Synchronized
            override fun read(offset: Long, buffer: ByteArray, count: Int): Int {
                if (closed || count <= 0 || offset >= size) return 0
                val want = minOf(count.toLong(), size - offset).toInt()
                val n = file.read(buffer, offset, 0, want)
                return if (n < 0) 0 else n
            }

            @Synchronized
            override fun close() {
                if (!closed) {
                    closed = true
                    runCatching { file.close() }
                }
            }
        }
    }

    override fun close() {
        shares.values.forEach { runCatching { it.close() } }
        shares.clear()
        runCatching { session?.close() }
        runCatching { connection?.close() }
        session = null
        connection = null
    }
}
