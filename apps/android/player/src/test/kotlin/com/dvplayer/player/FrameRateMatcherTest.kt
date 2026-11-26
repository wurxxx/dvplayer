package com.dvplayer.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FrameRateMatcherTest {

    private fun mode(id: Int, hz: Float) =
        FrameRateMatcher.ModeInfo(modeId = id, refreshRate = hz, width = 3840, height = 2160)

    @Test
    fun `24p 选最小的整数倍刷新率`() {
        val modes = listOf(mode(1, 60f), mode(2, 120f))
        assertEquals(2, FrameRateMatcher.pickMode(modes, 24.0)?.modeId)
    }

    @Test
    fun `23_976 的 5_005 倍仍按 5 倍处理`() {
        val modes = listOf(mode(1, 60f), mode(2, 120f))
        assertEquals(2, FrameRateMatcher.pickMode(modes, 24000.0 / 1001.0)?.modeId)
    }

    @Test
    fun `25p 在 100Hz 上是 4 倍`() {
        val modes = listOf(mode(1, 60f), mode(2, 100f), mode(3, 120f))
        assertEquals(2, FrameRateMatcher.pickMode(modes, 25.0)?.modeId)
    }

    @Test
    fun `25p 在 120Hz 上没有整数倍时退回最高刷新率`() {
        val modes = listOf(mode(1, 60f), mode(2, 120f))
        assertEquals(2, FrameRateMatcher.pickMode(modes, 25.0)?.modeId)
    }

    @Test
    fun `25p 在 50Hz 上是 2 倍`() {
        val modes = listOf(mode(1, 50f), mode(2, 60f))
        assertEquals(1, FrameRateMatcher.pickMode(modes, 25.0)?.modeId)
    }

    @Test
    fun `30p 优先 60Hz 而不是 120Hz`() {
        val modes = listOf(mode(1, 60f), mode(2, 120f))
        assertEquals(1, FrameRateMatcher.pickMode(modes, 30.0)?.modeId)
    }

    @Test
    fun `非法帧率返回 null`() {
        val modes = listOf(mode(1, 60f))
        assertNull(FrameRateMatcher.pickMode(modes, 0.0))
        assertNull(FrameRateMatcher.pickMode(modes, 1.0))
        assertNull(FrameRateMatcher.pickMode(emptyList(), 24.0))
    }
}
