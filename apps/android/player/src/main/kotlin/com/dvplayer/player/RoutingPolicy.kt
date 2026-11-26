package com.dvplayer.player

/**
 * 内核路由的**纯决策**部分（A7）。
 *
 * [EngineRouter] 负责探测（读显示能力、扫 DV 配置记录、解 HDR10+ SEI），
 * 这里只按顺序判一次。顺序本身就是规则，改顺序会改变结果，所以单独抽出来
 * 在 JVM 单测里钉住：
 *
 * 1. 非本地 → mpv（网络流没有可探测的本地文件）
 * 2. 蓝光原盘 → mpv（Media3 不认识 ISO / BDMV）
 * 3. Dolby Vision → mpv（必须**先于** HDR10+；P7 的兼容层 SEI 会被误判成 HDR10+）
 * 4. 设备不支持 HDR10+ → mpv
 * 5. 探测失败 → mpv（回退最稳的内核）
 * 6. 片源带 HDR10+ → Media3（动态元数据只有平台解码器能交给显示端）
 * 7. 其余 → mpv
 */
object RoutingPolicy {

    data class Decision(val engine: EngineId, val reason: String)

    /**
     * @param isLocal 是否是本地普通文件（没有 `://`，且不是原盘）
     * @param discLabel 原盘类型标签（ISO / BDMV），非原盘为 null
     * @param dvProfile 探测到的 DV profile，非 DV 为 null
     * @param deviceSupportsHdr10Plus 设备是否声明支持 HDR10+
     * @param probeHasHdr10Plus 片源是否带 ST2094-40；null 表示没探测或探测失败
     */
    data class Inputs(
        val isLocal: Boolean,
        val discLabel: String? = null,
        val dvProfile: Int? = null,
        val deviceSupportsHdr10Plus: Boolean = false,
        val probeHasHdr10Plus: Boolean? = null,
    )

    fun decide(inputs: Inputs): Decision {
        if (!inputs.isLocal) {
            return Decision(EngineId.MPV, "非本地片源，跳过探测")
        }
        inputs.discLabel?.let {
            return Decision(EngineId.MPV, "蓝光原盘（$it），交 mpv/libbluray")
        }
        inputs.dvProfile?.let {
            return Decision(EngineId.MPV, "Dolby Vision P$it，交 mpv 整形")
        }
        if (!inputs.deviceSupportsHdr10Plus) {
            return Decision(EngineId.MPV, "设备不支持 HDR10+")
        }
        return when (inputs.probeHasHdr10Plus) {
            null -> Decision(EngineId.MPV, "探测失败，回退 mpv")
            true -> Decision(
                EngineId.MEDIA3,
                "片源带 HDR10+（ST2094-40），动态元数据交 Media3",
            )
            false -> Decision(EngineId.MPV, "无 HDR10+，用默认 mpv")
        }
    }
}
