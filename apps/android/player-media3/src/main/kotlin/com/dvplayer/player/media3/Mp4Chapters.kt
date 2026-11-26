package com.dvplayer.player.media3

import com.dvplayer.player.ChapterInfo
import java.io.File
import java.io.RandomAccessFile

/**
 * 解析 MP4 / MOV 的章节（`moov/udta/chpl`）。
 *
 * ExoPlayer 1.11 的 `Mp4Extractor` 不解析 `chpl`，`MediaMetadata` 也没有章节字段，
 * 所以 Media3 内核的章节由这里补上。只看本地文件；网络流等 A9 的 VFS 接进来再说。
 *
 * `chpl` 载荷：
 *   version(1) flags(3) reserved(4) count(1)
 *   每章：start(8, 100ns) title_len(1) title(UTF-8)
 */
object Mp4Chapters {

    private val CONTAINERS = setOf("moov", "trak", "mdia", "minf", "stbl", "edts", "udta")

    fun parse(file: File): List<ChapterInfo> {
        if (!file.isFile) return emptyList()
        return try {
            RandomAccessFile(file, "r").use { raf ->
                val body = findBox(raf, 0, raf.length(), "chpl", 0) ?: return emptyList()
                decode(body)
            }
        } catch (_: Throwable) {
            emptyList()
        }
    }

    private fun findBox(
        raf: RandomAccessFile,
        start: Long,
        end: Long,
        wanted: String,
        depth: Int,
    ): ByteArray? {
        if (depth > 8) return null
        var pos = start
        val header = ByteArray(8)
        while (pos + 8 <= end) {
            raf.seek(pos)
            raf.readFully(header)
            val size = readU32(header, 0)
            val type = String(header, 4, 4, Charsets.ISO_8859_1)
            val boxSize = if (size == 0L) end - pos else size.toLong()
            if (boxSize < 8L || pos + boxSize > end) break
            if (type == wanted) {
                val body = ByteArray((boxSize - 8).toInt())
                raf.readFully(body)
                return body
            }
            if (type in CONTAINERS) {
                findBox(raf, pos + 8, pos + boxSize, wanted, depth + 1)?.let { return it }
            } else if (type == "meta") {
                // meta 是 full box：8 字节头后面还有 4 字节 version/flags。
                findBox(raf, pos + 12, pos + boxSize, wanted, depth + 1)?.let { return it }
            }
            pos += boxSize
        }
        return null
    }

    private fun decode(body: ByteArray): List<ChapterInfo> {
        if (body.size < 9) return emptyList()
        val language = body[0].toInt() and 0xff
        // version 1 的载荷是 version/flags + reserved(4) + count(1)。
        // 少数工具写 version 0 且没有 reserved，按最少 9 字节兜底。
        val countAt = if (language >= 1) 8 else 4
        if (body.size <= countAt) return emptyList()
        val count = body[countAt].toInt() and 0xff
        var p = countAt + 1
        val out = ArrayList<ChapterInfo>(count)
        for (i in 0 until count) {
            if (p + 9 > body.size) break
            val start100ns = readU64(body, p)
            p += 8
            val len = body[p].toInt() and 0xff
            p += 1
            if (p + len > body.size) break
            val title = String(body, p, len, Charsets.UTF_8)
            p += len
            out += ChapterInfo(
                index = i,
                title = title.ifBlank { "章节 ${i + 1}" },
                startMs = start100ns / 10_000,
            )
        }
        return out
    }

    private fun readU32(bytes: ByteArray, at: Int): Long {
        var v = 0L
        for (i in 0 until 4) v = (v shl 8) or (bytes[at + i].toLong() and 0xff)
        return v
    }

    private fun readU64(bytes: ByteArray, at: Int): Long {
        var v = 0L
        for (i in 0 until 8) v = (v shl 8) or (bytes[at + i].toLong() and 0xff)
        return v
    }
}
