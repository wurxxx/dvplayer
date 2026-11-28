package com.dvplayer.core.vfs

import android.util.Log
import com.dvplayer.core.vfs.nfs.MountException
import com.dvplayer.core.vfs.nfs.Nfs3Client
import java.io.Closeable
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

/**
 * NFSv3 浏览与随机读（A9）。
 *
 * 地址形如 `nfs://10.0.0.134/volume1/movies`：主机后面的部分既是 URL 路径，
 * 也是服务器上的导出路径 + 子目录。导出点由用户给，客户端不猜（`exports`
 * 只有服务器知道）；但 `nfs://host/a/b/c` 这种「导出在 a，后面是子目录」的
 * 情况很常见，所以挂载时从最深路径往上一层一层试 `MOUNT`，成功的那一层就是
 * 导出点，余下的路径用 `LOOKUP` 走。
 *
 * 播放和 SMB 一样走 [VfsHttpBridge]：mpv / Media3 都不认 `nfs://`，由桥接
 * 把 [VfsFile] 暴露成 `127.0.0.1` 上的 HTTP。
 *
 * 只支持 AUTH_SYS，uid / gid 默认 anonymous（65534）。很多 NAS 的导出是
 * `all_squash` 或按 IP 放行，匿名就能读；要特定 uid 时由调用方传。
 */
class NfsVfs internal constructor(
    baseUrl: String,
    private val client: Nfs3Client,
) : Vfs, Closeable {

    /**
     * [uid] / [gid] 只用于 AUTH_SYS 凭据。默认 anonymous（65534）：
     * 很多 NAS 的导出按 IP 放行或 all_squash，匿名就能读；要特定身份时再传。
     */
    constructor(
        baseUrl: String,
        uid: Int = ANONYMOUS_UID,
        gid: Int = ANONYMOUS_GID,
    ) : this(baseUrl, Nfs3Client(host = hostOfUrl(baseUrl), uid = uid, gid = gid))

    private val tag = "DvNfs"

    private val host: String = hostOfUrl(baseUrl)
    private val prefix = "nfs://$host"

    /** 挂载点对应的路径段（不含主机），以及它的文件句柄。 */
    private var mountSegments: List<String> = emptyList()
    private var mountHandle: ByteArray? = null

    /** 已经解析过的路径 → 句柄（列表与 LOOKUP 都会填）。 */
    private val handles = HashMap<List<String>, ByteArray>()

    override fun list(dir: String): List<VfsEntry> {
        val segments = segmentsOf(dir)
        val handle = handleOf(segments)
        val entries = client.readdirPlus(handle)
        val result = entries.mapNotNull { entry ->
            val path = segments + entry.name
            entry.handle?.let { handles[path] = it }
            val attr = entry.attr
            // 没有句柄也没有属性的条目读不了，列出来只会让用户点到失败。
            if (entry.handle == null && attr == null) return@mapNotNull null
            VfsEntry(
                name = entry.name,
                path = pathOf(path),
                isDirectory = attr?.isDirectory ?: false,
                size = if (attr?.isDirectory == true) -1 else (attr?.size ?: -1),
                lastModifiedMs = attr?.modifiedMs ?: -1,
            )
        }
        Log.i(tag, "list ${pathOf(segments)} -> ${result.size} 项")
        return result.sortedWith(compareByDescending<VfsEntry> { it.isDirectory }.thenBy { it.name })
    }

    override fun open(path: String): VfsFile {
        val segments = segmentsOf(path)
        val handle = handleOf(segments)
        val attr = client.getattr(handle)
        if (attr.isDirectory) throw IllegalStateException("$path 是目录")
        Log.i(tag, "open ${pathOf(segments)}：${attr.size} 字节")
        return object : VfsFile {
            override val size: Long = attr.size
            private var closed = false

            override fun read(offset: Long, buffer: ByteArray, count: Int): Int {
                if (closed || count <= 0 || offset >= size) return 0
                val want = minOf(count.toLong(), size - offset, MAX_READ.toLong()).toInt()
                val data = client.read(handle, offset, want)
                data.copyInto(buffer, 0, 0, minOf(data.size, count))
                return minOf(data.size, count)
            }

            override fun close() {
                closed = true
            }
        }
    }

    /** 路径的每一段都解码成服务器认识的名字。 */
    private fun segmentsOf(path: String): List<String> {
        val raw = when {
            path.startsWith("nfs://") -> path.removePrefix("nfs://")
                .substringAfter('/', missingDelimiterValue = "")
            else -> path
        }
        return raw.split('/')
            .filter { it.isNotEmpty() }
            .map { decode(it) }
    }

    private fun pathOf(segments: List<String>): String =
        if (segments.isEmpty()) "$prefix/" else "$prefix/" + segments.joinToString("/") { encode(it) }

    /**
     * 从深到浅挂载：`/a/b/c` 先试 `MOUNT /a/b/c`，失败再试 `/a/b`……最后 `/`。
     * 成功后缓存句柄，之后的路径从导出点开始逐个 `LOOKUP`。
     */
    private fun handleOf(segments: List<String>): ByteArray {
        handles[segments]?.let { return it }
        ensureMounted(segments)
        val mounted = mountSegments
        if (segments.size < mounted.size) {
            // 只在挂载点内部解析；上层目录不属于这个导出，重新挂载一次。
            handles.clear()
            mountHandle = null
            mountSegments = emptyList()
            return handleOf(segments)
        }
        var handle = mountHandle ?: throw IllegalStateException("NFS 未挂载")
        val rest = segments.subList(mounted.size, segments.size)
        var current = mounted
        for (name in rest) {
            current = current + name
            handles[current]?.let { handle = it; continue }
            val found = client.lookup(handle, name)
                ?: throw IllegalStateException("NFS 路径不存在：${pathOf(current)}")
            handle = found.handle
            handles[current] = handle
        }
        return handle
    }

    private fun ensureMounted(segments: List<String>) {
        if (mountHandle != null && segments.take(mountSegments.size) == mountSegments) return
        var candidates = segments
        while (true) {
            val path = "/" + candidates.joinToString("/")
            try {
                mountHandle = client.mount(path)
                mountSegments = candidates
                handles[candidates] = mountHandle!!
                Log.i(tag, "导出点 ${if (path == "/") "/" else path}（深 ${candidates.size} 段）")
                return
            } catch (e: MountException) {
                Log.i(tag, "MOUNT $path -> ${e.message}")
            }
            if (candidates.isEmpty()) {
                throw IllegalStateException("NFS 找不到导出点：$host")
            }
            candidates = candidates.dropLast(1)
        }
    }

    override fun close() {
        client.close()
        handles.clear()
        mountHandle = null
    }

    private fun encode(segment: String): String =
        URLEncoder.encode(segment, "UTF-8").replace("+", "%20")

    /** `URLDecoder` 会把 `+` 当空格，路径里的加号要先转义。 */
    private fun decode(segment: String): String =
        URLDecoder.decode(segment.replace("+", "%2B"), "UTF-8")

    companion object {
        const val ANONYMOUS_UID = 65534
        const val ANONYMOUS_GID = 65534
        private const val MAX_READ = 1 shl 20

        internal fun hostOfUrl(url: String): String =
            url.removePrefix("nfs://").substringBefore('/').substringBefore(':')
    }
}
