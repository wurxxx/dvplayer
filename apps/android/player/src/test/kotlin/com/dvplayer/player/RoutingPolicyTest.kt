package com.dvplayer.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 路由顺序回归：这些规则改顺序就会静默改变内核选择（P7 的 DV 兼容层 SEI
 * 会被当成 HDR10+、原盘会被当成普通文件），所以逐条钉住。
 */
class RoutingPolicyTest {

    private fun decide(
        isLocal: Boolean = true,
        discLabel: String? = null,
        dvProfile: Int? = null,
        device: Boolean = false,
        probe: Boolean? = null,
    ) = RoutingPolicy.decide(
        RoutingPolicy.Inputs(
            isLocal = isLocal,
            discLabel = discLabel,
            dvProfile = dvProfile,
            deviceSupportsHdr10Plus = device,
            probeHasHdr10Plus = probe,
        ),
    )

    @Test
    fun `非本地片源直接给 mpv`() {
        val d = decide(isLocal = false, device = true, probe = true)
        assertEquals(EngineId.MPV, d.engine)
        assertTrue(d.reason.contains("非本地"))
    }

    @Test
    fun `原盘优先于 DV 判定`() {
        val d = decide(discLabel = "ISO", dvProfile = 8, device = true, probe = true)
        assertEquals(EngineId.MPV, d.engine)
        assertTrue(d.reason.contains("原盘"))
    }

    @Test
    fun `DV 必须先于 HDR10+ 判定`() {
        // P7 自带 HDR10 兼容层，SEI 看起来像 HDR10+；但 DV 必须交 mpv 整形。
        val d = decide(dvProfile = 7, device = true, probe = true)
        assertEquals(EngineId.MPV, d.engine)
        assertTrue(d.reason.contains("Dolby Vision P7"))
    }

    @Test
    fun `设备不支持 HDR10+ 时不去解 SEI`() {
        val d = decide(dvProfile = null, device = false, probe = true)
        assertEquals(EngineId.MPV, d.engine)
        assertTrue(d.reason.contains("不支持 HDR10+"))
    }

    @Test
    fun `设备支持但探测失败回退 mpv`() {
        val d = decide(device = true, probe = null)
        assertEquals(EngineId.MPV, d.engine)
        assertTrue(d.reason.contains("探测失败"))
    }

    @Test
    fun `HDR10+ 交 Media3`() {
        val d = decide(device = true, probe = true)
        assertEquals(EngineId.MEDIA3, d.engine)
    }

    @Test
    fun `普通 HDR10 走默认 mpv`() {
        val d = decide(device = true, probe = false)
        assertEquals(EngineId.MPV, d.engine)
        assertTrue(d.reason.contains("无 HDR10+"))
    }
}
