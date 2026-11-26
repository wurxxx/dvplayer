package com.dvplayer.player

import android.content.Context
import android.os.Build
import android.view.Display

/**
 * 内核路由（A7 的第一块）：按设备能力 + 片源特征选内核。
 *
 * 规则（M2 定稿）：
 * 1. 非本地文件 → mpv。
 * 2. Dolby Vision（dvcC/dvvC）→ mpv：平台解码器丢掉 DV 元数据，只有 mpv
 *    会按 DV 做整形（P5 输出 SDR / P8 保留 HDR10 兼容层）。
 * 3. 设备不支持 HDR10+ → mpv（不用解 SEI）。
 * 4. 片源带 ST2094-40（HDR10+）→ Media3：只有平台 MediaCodec 能把动态元数据
 *    交给显示端；mpv 的 EGL 路径没有公开写入接口。
 * 5. 其余 → mpv（默认内核，负责原盘 / ASS）。
 *
 * 探测直接用 [Hdr10PlusProbe] 解十几帧，看解码器输出格式里有没有
 * `hdr10-plus-info`，代价约 0.2–0.5 秒。
 */
class EngineRouter(private val context: Context) {

    data class Decision(val engine: EngineId, val reason: String)

    fun choose(url: String, probeFrames: Int = 12): Decision {
        if (url.contains("://")) {
            return Decision(EngineId.MPV, "非本地片源，跳过探测")
        }
        // Dolby Vision：平台解码器不认 DV 元数据，只有 mpv 会整形。
        DolbyVisionProbe.probe(url)?.let {
            return Decision(EngineId.MPV, "Dolby Vision P${it.profile}，交 mpv 整形")
        }
        if (!supportsHdr10Plus()) {
            return Decision(EngineId.MPV, "设备不支持 HDR10+")
        }
        val probe = Hdr10PlusProbe.probe(
            url = url,
            surface = null,
            maxFrames = probeFrames,
            timeoutMs = 5_000,
        )
        return when {
            probe == null -> Decision(EngineId.MPV, "探测失败，回退 mpv")
            probe.hasHdr10Plus ->
                Decision(EngineId.MEDIA3, "片源带 HDR10+（ST2094-40），动态元数据交 Media3")
            else -> Decision(EngineId.MPV, "无 HDR10+，用默认 mpv")
        }
    }

    private fun supportsHdr10Plus(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
        @Suppress("DEPRECATION") // getDefaultDisplay：API 30 弃用，基线要兼容 26
        val display: Display = wm.defaultDisplay ?: return false
        return display.hdrCapabilities?.supportedHdrTypes
            ?.contains(Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS) == true
    }
}
