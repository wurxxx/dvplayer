package com.dvplayer.core.vfs.nfs

import java.io.Closeable

/**
 * NFSv3 客户端（RFC 1813）+ MOUNT 协议（RFC 1813 附录 I）。
 *
 * 只实现播放需要的五个过程：`GETATTR`、`LOOKUP`、`READDIRPLUS`、`READ`，
 * 外加 `MOUNT`。`READDIRPLUS` 一次就把名字、属性、文件句柄都带回来，
 * 列表与后续 `READ` 都不需要再逐个 `LOOKUP`。
 *
 * 端口发现走 rpcbind 的 `GETPORT`：mountd 一般不在固定端口，NFS 本身
 * 通常是 2049 但也可能被改过。
 */
internal class Nfs3Client(
    private val host: String,
    private val uid: Int = 0,
    private val gid: Int = 0,
    private val connectTimeoutMs: Int = 5_000,
    private val readTimeoutMs: Int = 20_000,
    private val log: (String) -> Unit = {},
    /** 端口解析：生产环境走 rpcbind，单测直接指向本机的临时端口。 */
    private val portResolver: ((program: Int, version: Int) -> Int)? = null,
) : Closeable {

    private val auth = AuthSys(uid = uid, gid = gid)
    private var mountClient: OncRpcClient? = null
    private var nfsClient: OncRpcClient? = null

    private fun mountRpc(): OncRpcClient = mountClient ?: run {
        val port = portOf(OncRpcClient.PROG_MOUNT, OncRpcClient.VERS_MOUNT)
        if (port <= 0) {
            throw OncRpcException("$host 没有注册 NFSv3 mountd（rpcbind GETPORT 返回 0）")
        }
        log("mountd 端口 $port")
        OncRpcClient(host, port, auth, connectTimeoutMs, readTimeoutMs)
            .also { mountClient = it }
    }

    private fun nfsRpc(): OncRpcClient = nfsClient ?: run {
        // 少数 NAS 不在 rpcbind 里注册 NFS，退回标准端口。
        val port = portOf(OncRpcClient.PROG_NFS, OncRpcClient.VERS_NFS)
            .takeIf { it > 0 } ?: DEFAULT_NFS_PORT
        log("nfsd 端口 $port")
        OncRpcClient(host, port, auth, connectTimeoutMs, readTimeoutMs)
            .also { nfsClient = it }
    }

    private fun portOf(program: Int, version: Int): Int {
        portResolver?.let { return it(program, version) }
        OncRpcClient(host, PORTMAPPER_PORT, null, connectTimeoutMs, readTimeoutMs).use { client ->
            val args = XdrWriter(16)
                .u32(program)
                .u32(version)
                .u32(OncRpcClient.PROTO_TCP)
                .u32(0)
            return client.call(
                OncRpcClient.PROG_PORTMAPPER,
                OncRpcClient.VERS_PORTMAPPER,
                GETPORT,
                args,
            ).u32()
        }
    }

    /**
     * MOUNT 一个导出路径，返回根文件句柄。
     *
     * 路径必须是服务器 `exports` 里写的那个（例如 `/volume1/movies`），
     * 不是客户端理解的某个子目录——所以上层要能从深到浅逐个尝试。
     */
    fun mount(exportPath: String): ByteArray {
        val args = XdrWriter().string(exportPath)
        val reply = mountRpc().call(
            OncRpcClient.PROG_MOUNT,
            OncRpcClient.VERS_MOUNT,
            MOUNTPROC_MNT,
            args,
        )
        val status = reply.u32()
        if (status != MNT3_OK) {
            throw MountException(status, "MOUNT $exportPath 失败：${mountStatusName(status)}")
        }
        val handle = reply.opaque()
        val flavors = reply.u32()
        repeat(flavors.coerceIn(0, 16)) { reply.u32() }
        log("MOUNT $exportPath 成功：句柄 ${handle.size} 字节")
        return handle
    }

    /** `GETATTR`：大小、类型、mtime。 */
    fun getattr(handle: ByteArray): NfsAttr {
        val args = XdrWriter(72).opaque(handle)
        val reply = nfsRpc().call(
            OncRpcClient.PROG_NFS,
            OncRpcClient.VERS_NFS,
            NFSPROC3_GETATTR,
            args,
        )
        checkStatus(reply, "GETATTR")
        return readAttr(reply)
    }

    /** 目录里按名字查一项；不存在返回 null。 */
    fun lookup(dir: ByteArray, name: String): LookupResult? {
        val args = XdrWriter(96).opaque(dir).string(name)
        val reply = nfsRpc().call(
            OncRpcClient.PROG_NFS,
            OncRpcClient.VERS_NFS,
            NFSPROC3_LOOKUP,
            args,
        )
        val status = reply.u32()
        if (status == NFS3ERR_NOENT) return null
        if (status != NFS3_OK) throw NfsException(status, "LOOKUP $name 失败：${nfsStatusName(status)}")
        val handle = reply.opaque()
        val attr = readPostOpAttr(reply)
        readPostOpAttr(reply)   // dir_attributes，用不到
        return LookupResult(handle, attr)
    }

    /**
     * 列目录，自动翻页到 eof。
     *
     * `cookieverf` 由服务器给、客户端原样带回；同一个 verf 下如果服务器
     * 重复给同一个 cookie，说明它不认分页，直接停，避免死循环。
     */
    fun readdirPlus(dir: ByteArray): List<DirEntry> {
        val result = ArrayList<DirEntry>()
        var cookie = 0L
        var verifier = ByteArray(8)
        var first = true
        repeat(MAX_PAGES) {
            val args = XdrWriter(128)
                .opaque(dir)
                .u64(cookie)
                .fixed(verifier)
                .u32(DIRCOUNT)
                .u32(MAXCOUNT)
            val reply = nfsRpc().call(
                OncRpcClient.PROG_NFS,
                OncRpcClient.VERS_NFS,
                NFSPROC3_READDIRPLUS,
                args,
            )
            checkStatus(reply, "READDIRPLUS")
            readPostOpAttr(reply)              // dir_attributes
            verifier = reply.fixed(8)
            var lastCookie = cookie
            while (reply.bool()) {
                reply.u64()                    // fileid，句柄里已有
                val name = reply.string()
                val nextCookie = reply.u64()
                val attr = readPostOpAttr(reply)
                val handle = if (reply.bool()) reply.opaque() else null
                if (name != "." && name != "..") {
                    result += DirEntry(name, handle, attr)
                }
                lastCookie = nextCookie
            }
            val eof = reply.bool()
            if (eof) return result
            if (!first && lastCookie <= cookie) {
                log("READDIRPLUS 的 cookie 没有前进（$lastCookie），停止翻页")
                return result
            }
            cookie = lastCookie
            first = false
        }
        log("READDIRPLUS 达到 ${MAX_PAGES} 页上限，返回 ${result.size} 项")
        return result
    }

    /** 读一块，返回实际读到的字节（服务器可能少于请求量）。 */
    fun read(handle: ByteArray, offset: Long, count: Int): ByteArray {
        val args = XdrWriter(80).opaque(handle).u64(offset).u32(count)
        val reply = nfsRpc().call(
            OncRpcClient.PROG_NFS,
            OncRpcClient.VERS_NFS,
            NFSPROC3_READ,
            args,
        )
        checkStatus(reply, "READ")
        readPostOpAttr(reply)                  // file_attributes
        val declared = reply.u32()
        reply.bool()                           // eof
        val data = reply.opaque()
        if (declared != data.size) {
            throw XdrException("READ 的 count=$declared 与实际 ${data.size} 字节不一致")
        }
        return data
    }

    private fun checkStatus(reply: XdrReader, what: String) {
        val status = reply.u32()
        if (status != NFS3_OK) {
            throw NfsException(status, "$what 失败：${nfsStatusName(status)}")
        }
    }

    private fun readAttr(reader: XdrReader): NfsAttr {
        val type = reader.u32()
        reader.u32()                           // mode
        reader.u32()                           // nlink
        reader.u32()                           // uid
        reader.u32()                           // gid
        val size = reader.u64()
        reader.u64()                           // used
        reader.skip(8)                         // rdev（两个 u32）
        reader.u64()                           // fsid
        val fileId = reader.u64()
        reader.skip(8)                         // atime
        val mtimeSec = reader.u32()
        val mtimeNsec = reader.u32()
        reader.skip(8)                         // ctime
        val modifiedMs = if (mtimeSec == 0) -1L else {
            (mtimeSec.toLong() and 0xffffffffL) * 1000L + mtimeNsec / 1_000_000L
        }
        return NfsAttr(type, size = size, fileId = fileId, modifiedMs = modifiedMs)
    }

    private fun readPostOpAttr(reader: XdrReader): NfsAttr? =
        if (reader.bool()) readAttr(reader) else null

    override fun close() {
        runCatching { mountClient?.close() }
        runCatching { nfsClient?.close() }
        mountClient = null
        nfsClient = null
    }

    companion object {
        const val DEFAULT_NFS_PORT = 2049
        const val PORTMAPPER_PORT = 111

        private const val GETPORT = 3

        private const val MOUNTPROC_MNT = 1

        private const val NFSPROC3_GETATTR = 1
        private const val NFSPROC3_LOOKUP = 3
        private const val NFSPROC3_READ = 6
        private const val NFSPROC3_READDIRPLUS = 17

        private const val DIRCOUNT = 8 * 1024
        private const val MAXCOUNT = 32 * 1024
        private const val MAX_PAGES = 512

        const val NFS3_OK = 0
        const val NFS3ERR_NOENT = 2
        const val MNT3_OK = 0

        const val NF3REG = 1
        const val NF3DIR = 2

        fun nfsStatusName(code: Int): String = when (code) {
            0 -> "OK"
            1 -> "PERM"
            2 -> "NOENT"
            5 -> "IO"
            6 -> "NXIO"
            13 -> "ACCESS"
            17 -> "EXIST"
            18 -> "XDEV"
            20 -> "NOTDIR"
            21 -> "ISDIR"
            22 -> "INVAL"
            27 -> "FBIG"
            28 -> "NOSPC"
            30 -> "ROFS"
            31 -> "MLINK"
            63 -> "NAMETOOLONG"
            66 -> "NOTEMPTY"
            69 -> "DQUOT"
            70 -> "STALE"
            10001 -> "BADHANDLE"
            10002 -> "NOT_SYNC"
            10003 -> "BAD_COOKIE"
            10004 -> "NOTSUPP"
            10005 -> "TOOSMALL"
            10006 -> "SERVERFAULT"
            10008 -> "REJECT_JUKEBOX"
            else -> "status=$code"
        }

        fun mountStatusName(code: Int): String = when (code) {
            0 -> "OK"
            1 -> "PERM"
            2 -> "NOENT"
            5 -> "IO"
            13 -> "ACCESS"
            20 -> "NOTDIR"
            63 -> "NAMETOOLONG"
            10004 -> "NOTSUPP"
            10006 -> "SERVERFAULT"
            else -> "status=$code"
        }
    }
}

internal data class NfsAttr(
    val type: Int,
    val size: Long,
    val fileId: Long,
    val modifiedMs: Long,
) {
    val isDirectory: Boolean get() = type == Nfs3Client.NF3DIR
    val isRegularFile: Boolean get() = type == Nfs3Client.NF3REG
}

internal data class DirEntry(val name: String, val handle: ByteArray?, val attr: NfsAttr?)

internal data class LookupResult(val handle: ByteArray, val attr: NfsAttr?)

/** NFS 过程返回非 OK 状态。 */
class NfsException(val status: Int, message: String) : java.io.IOException(message)

/** MOUNT 返回非 OK 状态——上层靠它判断「这个路径不是一个导出点」。 */
class MountException(val status: Int, message: String) : java.io.IOException(message)
