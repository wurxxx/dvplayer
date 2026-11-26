package com.dvplayer.player

import android.view.Display
import kotlin.math.abs
import kotlin.math.round

/**
 * 帧率匹配（A4）。规则：在同一分辨率的显示模式里，选**刷新率是片源帧率整数倍、
 * 且倍数最小**的那个；没有整数倍时退回最高刷新率。
 *
 * 24p → 120Hz（×5）是最干净的 pulldown；25p 在 120Hz 上没有整数倍（4.8），
 * 会退回最高刷新率。23.976 的 5.005 倍在 1% 容差内仍按 5 倍处理。
 */
object FrameRateMatcher {

    fun bestMode(
        modes: List<Display.Mode>,
        fps: Double,
        tolerance: Double = 0.01,
    ): Display.Mode? {
        if (fps <= 1.0 || modes.isEmpty()) return null
        val integral = modes
            .map { it to it.refreshRate / fps }
            .filter { (_, ratio) ->
                ratio >= 1.0 - tolerance && abs(ratio - round(ratio)) < tolerance
            }
            .minByOrNull { (_, ratio) -> ratio }
            ?.first
        return integral ?: modes.maxByOrNull { it.refreshRate }
    }

    /** 与当前模式同分辨率的模式集。 */
    fun sameSizeModes(display: Display): List<Display.Mode> {
        val current = display.mode
        return display.supportedModes.filter {
            it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight
        }
    }
}
