package com.dvplayer.player.media3

/**
 * 裸 `.sup`（Blu-ray PGS）的分段切分（A6）。
 *
 * 每个分段 13 字节头：`PG` + PTS(4, 90kHz) + DTS(4) + 类型(1) + 长度(2, 大端)，
 * 后面跟 `长度` 字节的载荷。Media3 的 `PgsParser` 只吃 Matroska 里的载荷，
 * 所以这里先把文件拆成段，再按类型喂给 PGS 状态机。
 *
 * 只做字节切分、不构造 `Cue`，单测可以完全脱离 Media3 跑。
 */
internal data class SupSection(
    val ptsUs: Long,
    val type: Int,
    /** 载荷在原始数组里的起点。 */
    val body: Int,
    val size: Int,
)

internal object SupSections {
    const val HEADER_SIZE = 13

    const val PALETTE = 0x14
    const val BITMAP = 0x15
    const val COMPOSITION = 0x16
    const val END = 0x80

    fun isSup(data: ByteArray, offset: Int, length: Int): Boolean =
        length >= HEADER_SIZE &&
            data[offset] == 'P'.code.toByte() &&
            data[offset + 1] == 'G'.code.toByte()

    /**
     * 从 `[start, end)` 里切出所有完整分段。
     *
     * 不是 `PG` 开头就往前挪一字节继续找（正常文件不会出现）；载荷越界的
     * 最后一段直接丢弃——截断文件不值得让整条字幕失败。
     */
    fun split(data: ByteArray, start: Int, end: Int): List<SupSection> {
        val out = ArrayList<SupSection>()
        var p = start
        while (p + HEADER_SIZE <= end) {
            if (data[p] != 'P'.code.toByte() || data[p + 1] != 'G'.code.toByte()) {
                p++
                continue
            }
            val ptsUs = readU32(data, p + 2) * 100L / 9L  // 90kHz -> us
            val type = data[p + 10].toInt() and 0xff
            val size = readU16(data, p + 11)
            val body = p + HEADER_SIZE
            if (body + size > end) break
            out += SupSection(ptsUs, type, body, size)
            p = body + size
        }
        return out
    }

    fun readU16(data: ByteArray, at: Int): Int =
        ((data[at].toInt() and 0xff) shl 8) or (data[at + 1].toInt() and 0xff)

    fun readU32(data: ByteArray, at: Int): Long =
        ((data[at].toLong() and 0xff) shl 24) or
            ((data[at + 1].toLong() and 0xff) shl 16) or
            ((data[at + 2].toLong() and 0xff) shl 8) or
            (data[at + 3].toLong() and 0xff)
}
