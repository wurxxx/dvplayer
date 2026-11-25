package com.dvplayer.design

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * 色板来自 docs/UI-DESIGN.md §1。四端共用同一套取值，不要在这里加新色相。
 */
object DvColors {
    val Background = Color(0xFF141419)
    val Sidebar = Color(0xFF17171D)
    val Card = Color(0xFF1F1F27)
    val CardHover = Color(0xFF2B2B35)
    val Divider = Color(0xFF3B3B49)
    val Text = Color(0xFFF5F5F8)
    val Subtle = Color(0xFFBDBDCB)
    val Muted = Color(0xFF9696A4)
    val Accent = Color(0xFFFFB020)
    val Danger = Color(0xFFFF6B6B)
    val Success = Color(0xFF4ADE80)
}

/** 圆角：卡片 12、按钮 / 输入框 / 下拉框 9、小角标 5–6（UI-DESIGN.md §3）。 */
object DvRadius {
    const val Card = 12
    const val Control = 9
    const val Badge = 6
}

private val DvColorScheme = darkColorScheme(
    primary = DvColors.Accent,
    onPrimary = DvColors.Background,
    secondary = DvColors.Subtle,
    onSecondary = DvColors.Background,
    background = DvColors.Background,
    onBackground = DvColors.Text,
    surface = DvColors.Card,
    onSurface = DvColors.Text,
    surfaceVariant = DvColors.CardHover,
    onSurfaceVariant = DvColors.Subtle,
    outline = DvColors.Divider,
    error = DvColors.Danger,
    onError = DvColors.Background,
)

@Composable
fun DvTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = DvColorScheme, content = content)
}
