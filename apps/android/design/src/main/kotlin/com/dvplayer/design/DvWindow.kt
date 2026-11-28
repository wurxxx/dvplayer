package com.dvplayer.design

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * 响应式断点。
 *
 * 量的是**窗口宽度**（dp），不是物理屏幕：分屏、折叠屏展开、桌面窗口拖动都会改它，
 * 所以拿 `LocalConfiguration.screenWidthDp` 或 `BoxWithConstraints.maxWidth`，
 * 不要用 `Resources.displayMetrics`。
 *
 * 取值照 Material 3 的 window size class：
 * - compact  (< 600)   手机竖屏，原来的单列布局不动；
 * - medium   (600–839) 平板竖屏 / 折叠屏展开：详情改「左海报 + 右信息」、网格加列；
 * - expanded (≥ 840)   平板横屏 / 大屏：详情海报更大，段落收进 1040dp。
 */
object DvBreakpoints {
    val Medium = 600.dp
    val Expanded = 840.dp
    val Wide = 1200.dp

    /** 宽屏时内容收在这个宽度里并居中，别让一行拉到 1200dp。 */
    val ReadableWidth = 760.dp
}

@Immutable
data class DvWindow(val width: Dp, val height: Dp = 800.dp) {
    val compact: Boolean get() = width < DvBreakpoints.Medium
    val medium: Boolean get() = width >= DvBreakpoints.Medium
    val expanded: Boolean get() = width >= DvBreakpoints.Expanded
    val wide: Boolean get() = width >= DvBreakpoints.Wide

    /**
     * 海报网格的列数。
     *
     * 手机固定 3 列（设计定稿，不因为大屏手机变 4 列），平板往上加。
     */
    fun gridColumns(): Int = when {
        wide -> 6
        expanded -> 5
        medium -> 4
        else -> 3
    }

    /**
     * 宽屏时列表类页面（设置、源列表）的内容宽度上限；手机上就是整宽。
     */
    fun listMaxWidth(): Dp = if (medium) DvBreakpoints.ReadableWidth else Dp.Unspecified
}

/** 当前窗口尺寸。由 `DvScaffold` 在根上量一次并提供给所有页面。 */
val LocalDvWindow = compositionLocalOf { DvWindow(360.dp, 780.dp) }

/**
 * 列表类页面的左右留白。
 *
 * 手机上就是原来的 18dp；宽屏时把内容收进 [DvBreakpoints.ReadableWidth] 居中，
 * 避免一行设置项从屏幕左沿拉到右沿、值贴在角上。
 */
val DvPageInset: Dp
    @Composable get() = with(LocalDvWindow.current) {
        if (medium) {
            ((width - DvBreakpoints.ReadableWidth) / 2).coerceAtLeast(DvSpace.Gutter)
        } else {
            DvSpace.Gutter
        }
    }
