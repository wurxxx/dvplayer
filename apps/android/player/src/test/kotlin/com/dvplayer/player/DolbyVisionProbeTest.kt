package com.dvplayer.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DolbyVisionProbeTest {

    private fun probeBytes(data: ByteArray): DolbyVisionProbe.Info? =
        DolbyVisionProbe.probe(
            readAt = { offset, buffer, count ->
                if (offset >= data.size) {
                    0
                } else {
                    val n = minOf(count.toLong(), data.size - offset).toInt()
                    System.arraycopy(data, offset.toInt(), buffer, 0, n)
                    n
                }
            },
            size = data.size.toLong(),
        )

    /** 在 [at] 处放一个 `dvcC`/`dvvC` 配置记录（version 1.0 + profile/level）。 */
    private fun dvRecord(
        tag: String = "dvcC",
        profile: Int,
        level: Int,
        at: Int = 16,
        total: Int = 64,
    ): ByteArray {
        val data = ByteArray(total)
        val name = tag.toByteArray(Charsets.US_ASCII)
        name.copyInto(data, at)
        val record = at + 4
        data[record] = 1
        data[record + 1] = 0
        val bits = (profile shl 1) or ((level shr 5) and 0x01)
        data[record + 2] = bits.toByte()
        data[record + 3] = ((level and 0x1f) shl 3).toByte()
        return data
    }

    @Test
    fun `识别 P8 配置记录`() {
        val info = probeBytes(dvRecord(profile = 8, level = 6))
        assertEquals(8, info?.profile)
        assertEquals(6, info?.level)
    }

    @Test
    fun `识别 P5 与 dvvC`() {
        val info = probeBytes(dvRecord(tag = "dvvC", profile = 5, level = 9))
        assertEquals(5, info?.profile)
        assertEquals(9, info?.level)
    }

    @Test
    fun `四字符码后面的版本不是 01 00 时不误判`() {
        val data = dvRecord(profile = 8, level = 6)
        data[20] = 2 // record[0] = 2
        assertNull(probeBytes(data))
    }

    @Test
    fun `profile 越界时不误判`() {
        val data = dvRecord(profile = 8, level = 6)
        data[22] = 0x7e // profile = 63
        assertNull(probeBytes(data))
    }

    @Test
    fun `非 DV 文件返回 null`() {
        assertNull(probeBytes(ByteArray(4096)))
    }

    @Test
    fun `空文件返回 null`() {
        assertNull(DolbyVisionProbe.probe({ _, _, _ -> 0 }, 0))
    }
}
