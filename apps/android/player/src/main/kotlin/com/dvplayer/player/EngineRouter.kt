package com.dvplayer.player

import android.content.Context
import android.os.Build
import android.view.Display

/**
 * 内核路由（A7 的第一块）：按设备能力 + 片源特征选内核。
 *
 * 规则（M2 定稿）：
 * 1. 非本地文件 → mpv。
 * 2. 蓝光原盘（ISO / BDMV 目录）→ mpv：只有它链了 libbluray，能选播放列表、
 *    章节与 PGS 字幕；Media3 不认识原盘结构。
 * 3. Dolby Vision（dvcC/dvvC）→ mpv：平台解码器丢掉 DV 元数据，只有 mpv
 *    会按 DV 做整形（P5 输出 SDR / P8 保留 HDR10 兼容层）。
 * 4. 设备不支持 HDR10+ → mpv（不用解 SEI）。
 * 5. 片源带 ST2094-40（HDR10+）→ Media3：只有平台 MediaCodec 能把动态元数据
 *    交给显示端；mpv 的 EGL 路径没有公开写入接口。
 * 6. 其余 → mpv（默认内核，负责 ASS）。
 *
 * 探测直接用 [Hdr10PlusProbe] 解十几帧，看解码器输出格式里有没有
 * `hdr10-plus-info`，代价约 0.2–0.5 秒。
 *
 * 判定顺序在 [RoutingPolicy] 里，可单独单测；这里只做平台探测。
 */
class EngineRouter(private val context: Context) {

    fun choose(url: String, probeFrames: Int = 12): RoutingPolicy.Decision {
        if (url.contains("://")) {
            return RoutingPolicy.decide(RoutingPolicy.Inputs(isLocal = false))
        }
        // 原盘先判：ISO 与 BDMV 目录既没有可探测的普通视频轨，也不能交给 Media3。
        DiscSource.detect(url)?.let {
            return RoutingPolicy.decide(
                RoutingPolicy.Inputs(isLocal = true, discLabel = it.kind.label),
            )
        }
        // Dolby Vision 必须先于 HDR10+：P7 的 BL 兼容层 SEI 会被当成 HDR10+。
        DolbyVisionProbe.probe(url)?.let {
            return RoutingPolicy.decide(
                RoutingPolicy.Inputs(isLocal = true, dvProfile = it.profile),
            )
        }
        if (!supportsHdr10Plus()) {
            return RoutingPolicy.decide(
                RoutingPolicy.Inputs(isLocal = true, deviceSupportsHdr10Plus = false),
            )
        }
        val probe = Hdr10PlusProbe.probe(
            url = url,
            surface = null,
            maxFrames = probeFrames,
            timeoutMs = 5_000,
        )
        return RoutingPolicy.decide(
            RoutingPolicy.Inputs(
                isLocal = true,
                deviceSupportsHdr10Plus = true,
                probeHasHdr10Plus = probe?.hasHdr10Plus,
            ),
        )
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
