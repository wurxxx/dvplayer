package com.dvplayer.player.media3

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SupSectionsTest {

    private fun section(type: Int, pts90: Long, body: ByteArray): ByteArray {
        val out = ByteArray(SupSections.HEADER_SIZE + body.size)
        out[0] = 'P'.code.toByte()
        out[1] = 'G'.code.toByte()
        out[2] = (pts90 ushr 24).toByte()
        out[3] = (pts90 ushr 16).toByte()
        out[4] = (pts90 ushr 8).toByte()
        out[5] = pts90.toByte()
        out[10] = type.toByte()
        out[11] = (body.size ushr 8).toByte()
        out[12] = body.size.toByte()
        body.copyInto(out, SupSections.HEADER_SIZE)
        return out
    }

    @Test
    fun `90kHz 换算成微秒`() {
        val data = section(SupSections.COMPOSITION, 90_000, byteArrayOf(1, 2, 3)) +
            section(SupSections.END, 180_000, ByteArray(0))
        val sections = SupSections.split(data, 0, data.size)
        assertEquals(2, sections.size)
        assertEquals(1_000_000L, sections[0].ptsUs)
        assertEquals(2_000_000L, sections[1].ptsUs)
        assertEquals(SupSections.COMPOSITION, sections[0].type)
        assertEquals(3, sections[0].size)
        assertEquals(SupSections.HEADER_SIZE, sections[0].body)
        assertEquals(SupSections.END, sections[1].type)
        assertEquals(data.size, sections[1].body)
    }

    @Test
    fun `载荷被截断的最后一段丢弃`() {
        val ok = section(SupSections.COMPOSITION, 90_000, byteArrayOf(1, 2, 3))
        val broken = section(SupSections.BITMAP, 180_000, ByteArray(10))
        // 只给前 5 字节载荷，声明的是 10。
        val data = ok + broken.copyOf(SupSections.HEADER_SIZE + 5)
        val sections = SupSections.split(data, 0, data.size)
        assertEquals(1, sections.size)
        assertEquals(SupSections.COMPOSITION, sections[0].type)
    }

    @Test
    fun `跳过不是 PG 开头的垃圾字节`() {
        val body = byteArrayOf(9, 9)
        val data = ByteArray(2) + section(SupSections.PALETTE, 0, body)
        val sections = SupSections.split(data, 0, data.size)
        assertEquals(1, sections.size)
        assertEquals(SupSections.HEADER_SIZE + 2, sections[0].body)
    }

    @Test
    fun `isSup 需要完整头`() {
        val head = section(SupSections.END, 0, ByteArray(0))
        assertTrue(SupSections.isSup(head, 0, head.size))
        assertFalse(SupSections.isSup(head, 0, SupSections.HEADER_SIZE - 1))
        assertFalse(SupSections.isSup(ByteArray(13), 0, 13))
    }
}
