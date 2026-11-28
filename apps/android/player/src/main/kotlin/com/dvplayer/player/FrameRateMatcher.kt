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
 *
 * 选择逻辑放在 [pickMode] 上、只吃 [ModeInfo]，这样不碰 `android.view.Display`
 * 就能在 JVM 单测里覆盖；[bestMode] 只是把平台的 `Display.Mode` 转过来。
 */
object FrameRateMatcher {

    /** 平台模式的最小投影（[Display.Mode] 不能直接构造）。 */
    data class ModeInfo(
        val modeId: Int,
        val refreshRate: Float,
        val width: Int,
        val height: Int,
    )

    fun pickMode(
        modes: List<ModeInfo>,
        fps: Double,
        tolerance: Double = 0.01,
    ): ModeInfo? {
        if (fps <= 1.0 || modes.isEmpty()) return null
        val integral = modes
            .map { it to it.refreshRate.toDouble() / fps }
            .filter { (_, ratio) ->
                if (ratio < 1.0 - tolerance) return@filter false
                // 容差按倍数放大：23.976@120 的 5.005 差 0.005，按 5 的 1% 是 0.05。
                abs(ratio - round(ratio)) <= tolerance * maxOf(1.0, round(ratio))
            }
            .minByOrNull { (_, ratio) -> ratio }
            ?.first
        return integral ?: modes.maxByOrNull { it.refreshRate }
    }

    fun bestMode(
        modes: List<Display.Mode>,
        fps: Double,
        tolerance: Double = 0.01,
    ): Display.Mode? {
        val infos = modes.map {
            ModeInfo(it.modeId, it.refreshRate, it.physicalWidth, it.physicalHeight)
        }
        val chosen = pickMode(infos, fps, tolerance) ?: return null
        return modes.firstOrNull { it.modeId == chosen.modeId }
    }

    /** 与当前模式同分辨率的模式集。 */
    fun sameSizeModes(display: Display): List<Display.Mode> =
        sameSize(display.supportedModes.toList(), display.mode)

    fun sameSize(modes: List<Display.Mode>, current: Display.Mode): List<Display.Mode> =
        modes.filter {
            it.physicalWidth == current.physicalWidth &&
                it.physicalHeight == current.physicalHeight
        }
}
