package com.dvplayer.player.media3

import android.graphics.Bitmap
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.text.Cue
import androidx.media3.common.util.Consumer
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.text.CuesWithTiming
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.extractor.text.SubtitleParser
import androidx.media3.extractor.text.pgs.PgsParser

/**
 * 裸 `.sup`（Blu-ray PGS）字幕解析器（A6）。
 *
 * Media3 自带的 [PgsParser] 只认 Matroska 里的载荷：从分段类型字节直接开始。
 * 而 `.sup` 文件每个分段前面还有 `PG` + PTS(4) + DTS(4) + 类型(1) + 长度(2)
 * 共 13 字节，整文件喂给 [PgsParser] 会在第一段就判越界、一个 cue 都出不来
 * （轨道能识别，画面没字幕）。这里按 `.sup` 的分段格式拆开，复用同一套
 * PCS/ODS/PDS/END 解析，并按显示集的 PTS 输出带时间的 cue。
 *
 * 嵌入式 PGS（Matroska）没有 `PG` 头，直接转给 [PgsParser]，行为不变。
 */
@UnstableApi
class SupSubtitleParser : SubtitleParser {

    private val delegate = PgsParser()

    override fun getCueReplacementBehavior(): Int = Format.CUE_REPLACEMENT_BEHAVIOR_REPLACE

    override fun parse(
        data: ByteArray,
        offset: Int,
        length: Int,
        outputOptions: SubtitleParser.OutputOptions,
        output: Consumer<CuesWithTiming>,
    ) {
        if (!isSup(data, offset, length)) {
            delegate.parse(data, offset, length, outputOptions, output)
            return
        }
        val sets = parseDisplaySets(data, offset, offset + length)
        sets.forEachIndexed { index, (startUs, cue) ->
            // 持续到下一个显示集；最后一段给 5 秒兜底（片尾的清屏段会覆盖它）。
            val durationUs =
                if (index + 1 < sets.size) (sets[index + 1].first - startUs).coerceAtLeast(0)
                else 5_000_000L
            val cues = if (cue != null) listOf(cue) else emptyList()
            output.accept(CuesWithTiming(cues, startUs, durationUs))
        }
    }

    override fun reset() {
        delegate.reset()
    }

    private fun isSup(data: ByteArray, offset: Int, length: Int): Boolean =
        length >= 13 &&
            data[offset] == 'P'.code.toByte() &&
            data[offset + 1] == 'G'.code.toByte()

    /** 返回 (起始时间 us, cue)，cue 为 null 表示清除。 */
    private fun parseDisplaySets(data: ByteArray, start: Int, end: Int): List<Pair<Long, Cue?>> {
        val out = ArrayList<Pair<Long, Cue?>>()
        val builder = CueBuilder()
        var p = start
        var ptsUs = 0L
        while (p + 13 <= end) {
            if (data[p] != 'P'.code.toByte() || data[p + 1] != 'G'.code.toByte()) {
                // 不是分段头，跳过这一拍继续找；正常文件不会走到这里。
                p++
                continue
            }
            ptsUs = readU32(data, p + 2) * 100L / 9L  // 90kHz -> us
            val type = data[p + 10].toInt() and 0xff
            val size = readU16(data, p + 11)
            val body = p + 13
            if (body + size > end) break
            when (type) {
                SECTION_PALETTE -> builder.parsePalette(data, body, size)
                SECTION_BITMAP -> builder.parseBitmap(data, body, size)
                SECTION_COMPOSITION -> builder.parseComposition(data, body, size)
                SECTION_END -> {
                    out += ptsUs to builder.build()
                    builder.reset()
                }
            }
            p = body + size
        }
        return out
    }

    private class CueBuilder {
        private var bitmapData = ByteArray(0)
        private var bitmapLength = 0
        private val colors = IntArray(256)
        private var colorsSet = false
        private var planeWidth = 0
        private var planeHeight = 0
        private var bitmapX = 0
        private var bitmapY = 0
        private var bitmapWidth = 0
        private var bitmapHeight = 0

        fun reset() {
            bitmapLength = 0
            colorsSet = false
            planeWidth = 0
            planeHeight = 0
            bitmapX = 0
            bitmapY = 0
            bitmapWidth = 0
            bitmapHeight = 0
        }

        fun parsePalette(data: ByteArray, offset: Int, size: Int) {
            // PDS：palette_id(1) palette_version(1) 之后每 5 字节一个
            // (index, Y, Cr, Cb, alpha)。
            if (size < 2 || (size - 2) % 5 != 0) return
            colors.fill(0)
            var p = offset + 2
            val entries = (size - 2) / 5
            repeat(entries) {
                val index = data[p].toInt() and 0xff
                val y = data[p + 1].toInt() and 0xff
                val cr = data[p + 2].toInt() and 0xff
                val cb = data[p + 3].toInt() and 0xff
                val a = data[p + 4].toInt() and 0xff
                val r = (y + 1.40200 * (cr - 128)).toInt()
                val g = (y - 0.34414 * (cb - 128) - 0.71414 * (cr - 128)).toInt()
                val b = (y + 1.77200 * (cb - 128)).toInt()
                colors[index] = (a shl 24) or
                    (r.coerceIn(0, 255) shl 16) or
                    (g.coerceIn(0, 255) shl 8) or
                    b.coerceIn(0, 255)
                p += 5
            }
            colorsSet = true
        }

        fun parseBitmap(data: ByteArray, offset: Int, size: Int) {
            // ODS：object_id(2) version(1) flags(1) [data_length(3) width(2) height(2)] 数据
            if (size < 4) return
            var p = offset + 3
            val flags = data[p].toInt() and 0xff
            p++
            var remaining = size - 4
            if (flags and 0x80 != 0) {
                if (remaining < 7) return
                val totalLength = readU24(data, p)
                p += 3
                if (totalLength < 4) return
                bitmapWidth = readU16(data, p)
                bitmapHeight = readU16(data, p + 2)
                p += 4
                if (bitmapData.size < totalLength - 4) bitmapData = ByteArray(totalLength - 4)
                bitmapLength = 0
                remaining -= 7
            }
            if (remaining > 0) {
                val want = minOf(remaining, bitmapData.size - bitmapLength)
                if (want > 0) {
                    System.arraycopy(data, p, bitmapData, bitmapLength, want)
                    bitmapLength += want
                }
            }
        }

        fun parseComposition(data: ByteArray, offset: Int, size: Int) {
            // PCS：video_width(2) video_height(2) …… num_objects(1) 后第一个对象
            // object_id(2) window_id(1) cropped_flag(1) x(2) y(2)。
            if (size < 19) return
            planeWidth = readU16(data, offset)
            planeHeight = readU16(data, offset + 2)
            bitmapX = readU16(data, offset + 15)
            bitmapY = readU16(data, offset + 17)
        }

        fun build(): Cue? {
            if (planeWidth == 0 || planeHeight == 0 || bitmapWidth == 0 || bitmapHeight == 0 ||
                bitmapLength == 0 || !colorsSet
            ) {
                return null
            }
            val pixels = IntArray(bitmapWidth * bitmapHeight)
            var index = 0
            var p = 0
            while (index < pixels.size && p < bitmapLength) {
                val colorIndex = bitmapData[p++].toInt() and 0xff
                if (colorIndex != 0) {
                    pixels[index++] = colors[colorIndex]
                } else {
                    if (p >= bitmapLength) break
                    val switchBits = bitmapData[p++].toInt() and 0xff
                    if (switchBits != 0) {
                        val runLength = if (switchBits and 0x40 == 0) {
                            switchBits and 0x3f
                        } else {
                            ((switchBits and 0x3f) shl 8) or (bitmapData[p++].toInt() and 0xff)
                        }
                        val color = if (switchBits and 0x80 == 0) {
                            colors[0]
                        } else if (p < bitmapLength) {
                            colors[bitmapData[p++].toInt() and 0xff]
                        } else {
                            colors[0]
                        }
                        val until = minOf(index + runLength, pixels.size)
                        java.util.Arrays.fill(pixels, index, until, color)
                        index = until
                    }
                }
            }
            if (index == 0) return null
            val bitmap = Bitmap.createBitmap(pixels, bitmapWidth, bitmapHeight, Bitmap.Config.ARGB_8888)
            return Cue.Builder()
                .setBitmap(bitmap)
                .setPosition(bitmapX.toFloat() / planeWidth)
                .setPositionAnchor(Cue.ANCHOR_TYPE_START)
                .setLine(bitmapY.toFloat() / planeHeight, Cue.LINE_TYPE_FRACTION)
                .setLineAnchor(Cue.ANCHOR_TYPE_START)
                .setSize(bitmapWidth.toFloat() / planeWidth)
                .setBitmapHeight(bitmapHeight.toFloat() / planeHeight)
                .build()
        }
    }

    private companion object {
        const val SECTION_PALETTE = 0x14
        const val SECTION_BITMAP = 0x15
        const val SECTION_COMPOSITION = 0x16
        const val SECTION_END = 0x80

        fun readU16(data: ByteArray, at: Int): Int =
            ((data[at].toInt() and 0xff) shl 8) or (data[at + 1].toInt() and 0xff)

        fun readU24(data: ByteArray, at: Int): Int =
            ((data[at].toInt() and 0xff) shl 16) or
                ((data[at + 1].toInt() and 0xff) shl 8) or
                (data[at + 2].toInt() and 0xff)

        fun readU32(data: ByteArray, at: Int): Long =
            ((data[at].toLong() and 0xff) shl 24) or
                ((data[at + 1].toLong() and 0xff) shl 16) or
                ((data[at + 2].toLong() and 0xff) shl 8) or
                (data[at + 3].toLong() and 0xff)
    }
}

/**
 * Media3 的字幕解析工厂：`.sup` 走 [SupSubtitleParser]，其余保持默认。
 * 通过 `DefaultMediaSourceFactory.setSubtitleParserFactory(...)` 挂进去。
 */
@UnstableApi
class DvSubtitleParserFactory : SubtitleParser.Factory {

    private val default = DefaultSubtitleParserFactory()

    override fun supportsFormat(format: Format): Boolean =
        format.sampleMimeType == MimeTypes.APPLICATION_PGS || default.supportsFormat(format)

    override fun getCueReplacementBehavior(format: Format): Int =
        if (format.sampleMimeType == MimeTypes.APPLICATION_PGS) {
            Format.CUE_REPLACEMENT_BEHAVIOR_REPLACE
        } else {
            default.getCueReplacementBehavior(format)
        }

    override fun create(format: Format): SubtitleParser =
        if (format.sampleMimeType == MimeTypes.APPLICATION_PGS) {
            SupSubtitleParser()
        } else {
            default.create(format)
        }
}
