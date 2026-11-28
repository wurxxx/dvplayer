package com.dvplayer.design

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * 手机端色板：冰川蓝（#2563EB / #60A5FA）。
 *
 * 深浅是两套独立推出来的值，不是把浅色反色——深色下卡片用不透明蓝黑而非半透明白，
 * 分层靠 1px 描边（深色背景上阴影看不见）。
 *
 * 播放页固定用深色一套（[DvColors]），视频本身就是暗场，浅色主题不该让它变白。
 */
data class DvPalette(
    val isDark: Boolean,
    val background: Color,
    /** 卡片 / 输入框 / 设置行容器。 */
    val surface: Color,
    /** 卡片内的次级层：分类块、图标底、开关轨道。 */
    val surfaceAlt: Color,
    val text: Color,
    /** 正文里略淡的一档，用于副标题。 */
    val subtle: Color,
    /** 次要信息、未选中的图标。 */
    val muted: Color,
    /** 说明文字、计数。 */
    val faint: Color,
    val divider: Color,
    val accent: Color,
    val onAccent: Color,
    /** 强调色的 9%（浅）/ 14%（深）填充，用于胶囊、选中块、图标底。 */
    val accentSoft: Color,
    val success: Color,
    val warning: Color,
    val danger: Color,
) {
    /** 浮空 tab 的玻璃底。 */
    val glass: Color get() = if (isDark) Color.White.copy(alpha = 0.07f) else Color.White.copy(alpha = 0.55f)

    /** 玻璃里选中项的填充块。 */
    val glassPill: Color get() = if (isDark) Color.White.copy(alpha = 0.12f) else Color.White.copy(alpha = 0.62f)

    /** 玻璃顶部那道高光。 */
    val glassHighlight: Color
        get() = if (isDark) Color.White.copy(alpha = 0.10f) else Color.White.copy(alpha = 0.60f)
}

object DvPalettes {

    val Light = DvPalette(
        isDark = false,
        background = Color(0xFFF5F7FB),
        surface = Color(0xFFFFFFFF),
        surfaceAlt = Color(0xFFE9EEF7),
        text = Color(0xFF14171F),
        subtle = Color(0xFF3F4655),
        muted = Color(0xFF626875),
        faint = Color(0xFF6B7280),
        divider = Color(0x0D000000),
        accent = Color(0xFF2563EB),
        onAccent = Color(0xFFFFFFFF),
        accentSoft = Color(0x172563EB),
        success = Color(0xFF22A55B),
        warning = Color(0xFFD98E04),
        danger = Color(0xFFE5484D),
    )

    val Dark = DvPalette(
        isDark = true,
        background = Color(0xFF0A0E16),
        surface = Color(0xFF141926),
        surfaceAlt = Color(0xFF1C2433),
        text = Color(0xFFEEF2F9),
        subtle = Color(0xFFC3CBD9),
        muted = Color(0xFF8A93A6),
        faint = Color(0xFF7C879B),
        divider = Color(0x12FFFFFF),
        accent = Color(0xFF60A5FA),
        onAccent = Color(0xFF071019),
        accentSoft = Color(0x2460A5FA),
        success = Color(0xFF4ADE80),
        warning = Color(0xFFFBBF24),
        danger = Color(0xFFF87171),
    )
}

val LocalDvPalette = staticCompositionLocalOf { DvPalettes.Dark }

/**
 * 压在图片 / 视频上的内容色。
 *
 * 这类地方不能用调色板（浅色主题下 text 是黑的、subtle 是深灰），只能走白色 alpha；
 * 但 alpha 也不能随手写 —— 之前散成 18 档，同样的「次要文字」在 0.72 / 0.74 / 0.85
 * 之间乱跳。这里只保留四档，按层级用。
 */
object DvOnImage {
    /** 片名、卡片标题。 */
    val Primary = Color.White.copy(alpha = 0.98f)
    /** meta、简介、chips 文字。 */
    val Secondary = Color.White.copy(alpha = 0.72f)
    /** 角标、极次要说明。 */
    val Tertiary = Color.White.copy(alpha = 0.50f)
    /** 压在图片上的图标（返回、工具）。 */
    val Icon = Color.White.copy(alpha = 0.92f)
}

/** 页面调色板的快捷入口：`val p = DvTheme.palette`。 */
object DvTheme {
    val palette: DvPalette
        @Composable @ReadOnlyComposable get() = LocalDvPalette.current
}

/**
 * 旧的四端共用深色取值，保留给播放页（控制层永远是暗的）。
 *
 * 注意这里只放播放页真正用到的几个名字；新页面请用 [DvTheme.palette]。
 */
object DvColors {
    val Background = Color(0xFF0A0E16)
    val Sidebar = Color(0xFF141926)
    val Card = Color(0xFF141926)
    val CardHover = Color(0xFF1C2433)
    val Divider = Color(0x12FFFFFF)
    val Text = Color(0xFFEEF2F9)
    val Subtle = Color(0xFFC3CBD9)
    val Muted = Color(0xFF8A93A6)
    val Accent = Color(0xFF60A5FA)
    val Danger = Color(0xFFE5484D)
    val Success = Color(0xFF4ADE80)
}

/** 圆角：卡片 12、按钮 / 输入框 / 下拉框 9、小角标 5–6（UI-DESIGN.md §3）。 */
object DvRadius {
    const val Card = 12
    const val Control = 9
    const val Badge = 6
}

/** 页面级尺寸。屏幕宽 360dp，左右留 18dp。 */
object DvSpace {
    val Gutter = 18.dp
    val CardRadius = 14.dp
    val ControlRadius = 9.dp
    val PillRadius = 99.dp
    val TabHeight = 60.dp
    val TabRadius = 26.dp
    val TabInset = 11.dp
    /** 宽屏底部胶囊的最大宽度：不跟着屏幕拉满，也不会挤成一团。 */
    val TabBarMaxWidth = 500.dp
}

object DvType {
    /** 详情页片名：整页唯一的最大号。 */
    val Display = TextStyle(
        fontSize = 30.sp,
        lineHeight = 36.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = (-0.8).sp,
    )
    val PageTitle = TextStyle(
        fontSize = 26.sp,
        lineHeight = 30.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = (-0.7).sp,
    )
    val SectionTitle = TextStyle(
        fontSize = 15.sp,
        lineHeight = 19.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = (-0.2).sp,
    )
    val CardTitle = TextStyle(
        fontSize = 13.sp,
        lineHeight = 17.sp,
        fontWeight = FontWeight.Medium,
    )
    val Body = TextStyle(
        fontSize = 15.sp,
        lineHeight = 21.sp,
        fontWeight = FontWeight.Normal,
    )
    val Caption = TextStyle(
        fontSize = 12.sp,
        lineHeight = 16.sp,
        fontWeight = FontWeight.Normal,
    )
    val Micro = TextStyle(
        fontSize = 11.sp,
        lineHeight = 14.sp,
        fontWeight = FontWeight.Medium,
        letterSpacing = 0.2.sp,
    )
    /** 缩略图角标（1080p / 播放中 / 时长）：唯一允许小于 10.5sp 的地方。 */
    val Badge = TextStyle(
        fontSize = 9.sp,
        lineHeight = 11.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = 0.1.sp,
    )
    val Numeral = TextStyle(
        fontSize = 17.sp,
        lineHeight = 20.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = (-0.5).sp,
    )
}

private fun DvPalette.toColorScheme() = if (isDark) {
    darkColorScheme(
        primary = accent,
        onPrimary = onAccent,
        secondary = muted,
        background = background,
        onBackground = text,
        surface = surface,
        onSurface = text,
        surfaceVariant = surfaceAlt,
        onSurfaceVariant = subtle,
        outline = divider,
        error = danger,
    )
} else {
    lightColorScheme(
        primary = accent,
        onPrimary = onAccent,
        secondary = muted,
        background = background,
        onBackground = text,
        surface = surface,
        onSurface = text,
        surfaceVariant = surfaceAlt,
        onSurfaceVariant = subtle,
        outline = divider,
        error = danger,
    )
}

@Composable
fun DvTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val palette = if (darkTheme) DvPalettes.Dark else DvPalettes.Light
    CompositionLocalProvider(LocalDvPalette provides palette) {
        MaterialTheme(colorScheme = palette.toColorScheme(), content = content)
    }
}

/** 播放页用：无论系统深浅，一律深色。 */
@Composable
fun DvPlayerTheme(content: @Composable () -> Unit) {
    DvTheme(darkTheme = true, content = content)
}
