package com.dvplayer.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackControllerTest {

    private class FakeMemory : ProgressStore {
        val saved = HashMap<String, Long>()
        override fun position(url: String): Long = saved[url] ?: 0L
        override fun save(url: String, positionMs: Long, durationMs: Long) {
            saved[url] = positionMs
        }
    }

    private fun controller(
        memory: ProgressStore? = null,
        router: PlaybackController.Router? = null,
    ) = PlaybackController(memory, router)

    @Test
    fun `手动指定内核优先于自动路由`() {
        val choice = controller(router = { error("不该调用路由") })
            .chooseEngine("smb://nas/a.mkv", EngineId.MEDIA3, auto = true)
        assertEquals(EngineId.MEDIA3, choice.engine)
        assertNull(choice.reason)
    }

    @Test
    fun `没有 auto 时默认 mpv`() {
        val choice = controller(router = { error("不该调用路由") })
            .chooseEngine("/sdcard/a.mkv", null, auto = false)
        assertEquals(EngineId.MPV, choice.engine)
    }

    @Test
    fun `auto 时采用路由结论`() {
        val choice = controller(router = {
            RoutingPolicy.Decision(EngineId.MEDIA3, "HDR10+")
        }).chooseEngine("/sdcard/a.mp4", null, auto = true)
        assertEquals(EngineId.MEDIA3, choice.engine)
        assertEquals("HDR10+", choice.reason)
    }

    @Test
    fun `路由抛异常时回退 mpv`() {
        val choice = controller(router = { throw IllegalStateException("boom") })
            .chooseEngine("/sdcard/a.mp4", null, auto = true)
        assertEquals(EngineId.MPV, choice.engine)
        assertTrue(choice.reason!!.contains("回退 mpv"))
    }

    @Test
    fun `路由超时回退 mpv`() {
        val choice = controller(router = {
            Thread.sleep(2_000)
            RoutingPolicy.Decision(EngineId.MEDIA3, "slow")
        }).chooseEngine("/sdcard/a.mp4", null, auto = true, timeoutMs = 50)
        assertEquals(EngineId.MPV, choice.engine)
        assertTrue(choice.reason!!.contains("超时"))
    }

    @Test
    fun `显式 seek 优先于续播记录`() {
        val memory = FakeMemory().apply { saved["/a.mkv"] = 60_000 }
        val r = controller(memory).resume("/a.mkv", explicitMs = 12_000, durationMs = 600_000)
        assertEquals(PlaybackController.Resume.Explicit(12_000), r)
    }

    @Test
    fun `没有显式位置时用上次进度`() {
        val memory = FakeMemory().apply { saved["/a.mkv"] = 60_000 }
        val r = controller(memory).resume("/a.mkv", explicitMs = -1, durationMs = 600_000)
        assertEquals(PlaybackController.Resume.Saved(60_000), r)
    }

    @Test
    fun `开头三秒内不续播`() {
        val memory = FakeMemory().apply { saved["/a.mkv"] = 2_000 }
        assertNull(controller(memory).resume("/a.mkv", -1, 600_000))
    }

    @Test
    fun `片尾五秒内不续播`() {
        val memory = FakeMemory().apply { saved["/a.mkv"] = 597_000 }
        assertNull(controller(memory).resume("/a.mkv", -1, 600_000))
    }

    @Test
    fun `片长未知时不动`() {
        val memory = FakeMemory().apply { saved["/a.mkv"] = 60_000 }
        assertNull(controller(memory).resume("/a.mkv", -1, 0))
    }

    @Test
    fun `Media3 失败回退 mpv 一次`() {
        val c = controller()
        assertEquals(
            PlaybackController.Recovery.FallbackToMpv(1234),
            c.recovery(EngineId.MEDIA3, fallbackTried = false, positionMs = 1234),
        )
        assertEquals(
            PlaybackController.Recovery.None,
            c.recovery(EngineId.MEDIA3, fallbackTried = true, positionMs = 1234),
        )
    }

    @Test
    fun `mpv 失败不换内核`() {
        assertEquals(
            PlaybackController.Recovery.None,
            controller().recovery(EngineId.MPV, fallbackTried = false, positionMs = 0),
        )
    }

    @Test
    fun `切换内核在两个内核之间对换`() {
        assertEquals(EngineId.MPV, controller().otherEngine(EngineId.MEDIA3))
        assertEquals(EngineId.MEDIA3, controller().otherEngine(EngineId.MPV))
    }
}
