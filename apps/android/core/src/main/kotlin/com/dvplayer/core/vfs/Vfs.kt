package com.dvplayer.core.vfs

/**
 * 虚拟文件系统（A9 的第一层）。
 *
 * UI / 播放器只认这一个接口：列目录、拿条目。具体协议（WebDAV / SMB / NFS）
 * 各自实现。播放时不需要把文件读进来——把 [VfsEntry.path]（一个 URL 或本地
 * 路径）交给内核即可：mpv 与 Media3 都能直接读 HTTP 与本地文件，SMB / NFS
 * 才需要额外的 DataSource。
 */
interface Vfs {

    /** 列出 [dir] 下的直接子项；失败抛异常由调用方兜底。 */
    fun list(dir: String): List<VfsEntry>

    /** 打开一个文件做随机读（SMB / WebDAV 都可以）。 */
    fun open(path: String): VfsFile
}

/**
 * 随机读的文件句柄。播放器不能把整个原盘 / 4K 文件读进内存，所以按 offset
 * 读。[read] 返回实际读到的字节数，0 表示 EOF。
 */
interface VfsFile : java.io.Closeable {
    val size: Long
    fun read(offset: Long, buffer: ByteArray, count: Int): Int
}

/**
 * 一个文件或目录。
 *
 * [path] 是**可直接交给播放器**的完整地址（WebDAV 是 `http(s)://`，
 * 本地是绝对路径）。[name] 只用于显示与认集号。
 */
data class VfsEntry(
    val name: String,
    val path: String,
    val isDirectory: Boolean,
    val size: Long = -1,
    val lastModifiedMs: Long = -1,
)
