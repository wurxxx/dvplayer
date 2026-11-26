package com.dvplayer.player

import android.util.Log
import java.io.File
import java.io.RandomAccessFile

/**
 * Dolby Vision 探测（A7 路由用）。
 *
 * 设备没有 DV 解码器时 mpv 会把 DV 片源整形（RPU 元数据 + BL 解码）输出 HDR/SDR，
 * Media3 / 平台解码器只会当普通 HEVC 播、把 DV 元数据丢掉。所以路由要先知道
 * 片源是不是 DV。
 *
 * DV 的配置记录（dvcC / dvvC）在 MP4 里是 `stsd` 下的一个 box，在 MKV 里由
 * ffmpeg 写进 CodecPrivate，两者都会出现 `dvcC` / `dvvC` 四字符码；记录本身以
 * `version_major=1, version_minor=0` 开头，所以只认「四字符码 + 01 00」的组合，
 * 避免把普通字节误判成 DV。
 *
 * 只看本地文件；网络流 / 原盘里的 DV 由 mpv 自己在解复用时判断。
 */
object DolbyVisionProbe {

    private const val TAG = "DvDovi"

    data class Info(val profile: Int, val level: Int)

    private val TAGS = arrayOf("dvcC", "dvvC")

    /**
     * 探测本地文件的 DV 配置记录。找到返回 profile/level；不是 DV 返回 null。
     *
     * 扫文件头 1MB（MKV 的 CodecPrivate 与 faststart 的 MP4 都在这里），
     * 没找到再扫尾部 2MB（moov 在末尾的 MP4）。
     */
    fun probe(path: String): Info? {
        val file = File(path)
        if (!file.isFile) return null
        return try {
            RandomAccessFile(file, "r").use { raf ->
                probe(
                    { offset, buffer, count ->
                        if (offset >= raf.length()) {
                            0
                        } else {
                            raf.seek(offset)
                            raf.read(buffer, 0, minOf(count.toLong(), raf.length() - offset).toInt())
                        }
                    },
                    raf.length(),
                )
            }
        } catch (t: Throwable) {
            Log.w(TAG, "探测失败：$path", t)
            null
        }
    }

    /**
     * 对任意随机读源探测（SMB / WebDAV 的 `VfsFile` 直接套进来）。播放器拿到的
     * 往往只是 `http://127.0.0.1` 的桥接地址，不能按本地路径判断。
     */
    fun probe(readAt: (offset: Long, buffer: ByteArray, count: Int) -> Int, size: Long): Info? {
        if (size <= 0) return null
        return try {
            findIn(readAt, 0, minOf(size, 1L shl 20))
                ?: findIn(readAt, maxOf(0, size - (2L shl 20)), size)
        } catch (t: Throwable) {
            Log.w(TAG, "探测失败（size=$size）", t)
            null
        }
    }

    private fun findIn(
        readAt: (offset: Long, buffer: ByteArray, count: Int) -> Int,
        start: Long,
        end: Long,
    ): Info? {
        val length = (end - start).toInt()
        if (length < 8) return null
        val buffer = loadRange(readAt, start, length) ?: return null
        for (tag in TAGS) {
            val needle = tag.toByteArray(Charsets.US_ASCII)
            var i = 0
            while (true) {
                val at = indexOf(buffer, needle, i)
                if (at < 0) break
                // MP4：size(4) + 'dvcC' + 记录，记录紧跟四字符码。
                // MKV：'dvcC' 是 BlockAddIDType，后面还有 EBML 长度字段，记录会晚几字节。
                // 在 +4..+12 里找以 01 00 开头的配置记录。
                for (delta in 4..12) {
                    val record = at + delta
                    if (record + 6 > buffer.size) break
                    if (buffer[record].toInt() != 1 || buffer[record + 1].toInt() != 0) continue
                    val bits = buffer[record + 2].toInt() and 0xff
                    val profile = (bits shr 1) and 0x7f
                    if (profile !in 1..9) continue
                    val levelBits = ((bits and 0x01) shl 5) or
                        ((buffer[record + 3].toInt() and 0xff) shr 3)
                    if (levelBits > 13) continue
                    return Info(profile, levelBits)
                }
                i = at + 1
            }
        }
        return null
    }

    private fun loadRange(
        readAt: (offset: Long, buffer: ByteArray, count: Int) -> Int,
        start: Long,
        length: Int,
    ): ByteArray? {
        val out = ByteArray(length)
        val chunk = ByteArray(minOf(length, 256 * 1024))
        var done = 0
        while (done < length) {
            val want = minOf(chunk.size, length - done)
            val n = readAt(start + done, chunk, want)
            if (n <= 0) return if (done == 0) null else out.copyOf(done)
            System.arraycopy(chunk, 0, out, done, n)
            done += n
        }
        return out
    }

    private fun indexOf(haystack: ByteArray, needle: ByteArray, from: Int): Int {
        val last = haystack.size - needle.size
        var i = from
        while (i <= last) {
            var j = 0
            while (j < needle.size && haystack[i + j] == needle[j]) j++
            if (j == needle.size) return i
            i++
        }
        return -1
    }
}
