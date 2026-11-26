package com.dvplayer.core.vfs

import org.junit.Assert.assertEquals
import org.junit.Test

class ByteRangeTest {

    private val size = 1000L

    @Test
    fun `没有 Range 头时全量`() {
        assertEquals(ByteRange.Full, parseByteRange(null, size))
        assertEquals(ByteRange.Full, parseByteRange("", size))
    }

    @Test
    fun `闭区间按原样返回`() {
        assertEquals(ByteRange.Partial(0, 99), parseByteRange("bytes=0-99", size))
        assertEquals(ByteRange.Partial(500, 999), parseByteRange("bytes=500-", size))
    }

    @Test
    fun `结尾超出文件时夹到文件尾`() {
        assertEquals(ByteRange.Partial(900, 999), parseByteRange("bytes=900-5000", size))
    }

    @Test
    fun `后缀范围取最后 N 字节`() {
        assertEquals(ByteRange.Partial(900, 999), parseByteRange("bytes=-100", size))
        assertEquals(ByteRange.Partial(0, 999), parseByteRange("bytes=-99999", size))
    }

    @Test
    fun `起点越界不可满足`() {
        assertEquals(ByteRange.Unsatisfiable, parseByteRange("bytes=1000-", size))
        assertEquals(ByteRange.Unsatisfiable, parseByteRange("bytes=1200-1300", size))
    }

    @Test
    fun `起点大于终点不可满足`() {
        assertEquals(ByteRange.Unsatisfiable, parseByteRange("bytes=500-400", size))
    }

    @Test
    fun `后缀为零不可满足`() {
        assertEquals(ByteRange.Unsatisfiable, parseByteRange("bytes=-0", size))
    }

    @Test
    fun `不认识的单位忽略 Range`() {
        assertEquals(ByteRange.Full, parseByteRange("items=0-10", size))
        assertEquals(ByteRange.Full, parseByteRange("bytes=abc-def", size))
        assertEquals(ByteRange.Full, parseByteRange("bytes=-", size))
    }

    @Test
    fun `大小为零不可满足`() {
        assertEquals(ByteRange.Unsatisfiable, parseByteRange(null, 0))
    }
}
