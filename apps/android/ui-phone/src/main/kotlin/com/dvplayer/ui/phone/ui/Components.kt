package com.dvplayer.ui.phone.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dvplayer.core.MediaItem
import com.dvplayer.core.PlayRecord
import com.dvplayer.design.DvGlyph
import com.dvplayer.design.DvSpace
import com.dvplayer.design.DvTheme
import com.dvplayer.design.DvType
import com.dvplayer.design.clickableNoRipple
import com.dvplayer.design.DvOnImage

// ------------------------------------------------------------------ 基础

@Composable
fun DvPill(
    text: String,
    selected: Boolean,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    badge: Int? = null,
) {
    val p = DvTheme.palette
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(DvSpace.PillRadius))
            .background(if (selected) p.accent else p.surface)
            .border(
                1.dp,
                if (selected) Color.Transparent else p.divider,
                RoundedCornerShape(DvSpace.PillRadius),
            )
            .then(if (onClick != null) Modifier.clickableNoRipple(onClick) else Modifier)
            .padding(horizontal = 11.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = text,
            style = DvType.Caption,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) p.onAccent else p.muted,
        )
        if (badge != null && badge > 0) {
            Text(
                text = badge.toString(),
                style = DvType.Micro,
                color = if (selected) p.onAccent else p.accent,
                modifier = Modifier
                    .clip(RoundedCornerShape(4.dp))
                    .background(if (selected) p.onAccent.copy(alpha = 0.18f) else p.accentSoft)
                    .padding(horizontal = 4.dp, vertical = 1.dp),
            )
        }
    }
}

@Composable
fun SectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    trailing: String? = null,
    onTrailing: (() -> Unit)? = null,
) {
    val p = DvTheme.palette
    Row(
        modifier = modifier.fillMaxWidth().padding(horizontal = DvSpace.Gutter, vertical = 0.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = DvType.SectionTitle, color = p.text)
        Spacer(Modifier.weight(1f))
        if (trailing != null) {
            Text(
                trailing,
                style = DvType.Caption,
                color = p.faint,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .then(if (onTrailing != null) Modifier.clickableNoRipple(onTrailing) else Modifier)
                    .padding(horizontal = 4.dp, vertical = 2.dp),
            )
        }
    }
}

/**
 * 圆形图标按钮。
 *
 * 压在封面图上时传 `onImage = true`：底色换成半透明黑、图标强制白色——浅色主题下
 * 白底白图标是一片空白，而在亮封面上白底也压不住。
 */
@Composable
fun RoundIconButton(
    glyph: DvGlyph,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = 32.dp,
    tint: Color? = null,
    onImage: Boolean = false,
) {
    val p = DvTheme.palette
    val bg = if (onImage) Color.Black.copy(alpha = 0.34f) else p.surface
    val fg = if (onImage) Color.White else (tint ?: p.text)
    Box(
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(99.dp))
            .background(bg)
            .border(
                1.dp,
                if (onImage) Color.White.copy(alpha = 0.18f) else p.divider,
                RoundedCornerShape(99.dp),
            )
            .clickableNoRipple(onClick),
        contentAlignment = Alignment.Center,
    ) {
        DvGlyph(glyph, tint = fg, sizeDp = (size.value * 0.45f).toInt())
    }
}

/** 返回 + 标题 + 右侧动作。二级页面的顶栏。 */
@Composable
fun ScreenHeader(
    title: String,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    subtitle: String? = null,
    actions: @Composable RowScope.() -> Unit = {},
) {
    val p = DvTheme.palette
    Row(
        modifier = modifier.fillMaxWidth().height(44.dp).padding(horizontal = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (onBack != null) {
            RoundIconButton(DvGlyph.Back, onBack, size = 32.dp)
        } else {
            Spacer(Modifier.width(8.dp))
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                style = DvType.CardTitle,
                fontWeight = FontWeight.SemiBold,
                color = p.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (subtitle != null) {
                Text(subtitle, style = DvType.Micro, color = p.faint, maxLines = 1)
            }
        }
        actions()
        Spacer(Modifier.width(4.dp))
    }
}

// ------------------------------------------------------------------ 按钮

@Composable
fun PrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    glyph: DvGlyph? = null,
) {
    val p = DvTheme.palette
    val fg = if (p.isDark) Color(0xFF0A0E16) else Color.White
    val bg = if (p.isDark) p.text else p.text
    Row(
        modifier = modifier
            .height(36.dp)
            .clip(RoundedCornerShape(DvSpace.ControlRadius))
            .background(bg)
            .clickableNoRipple(onClick)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (glyph != null) {
            DvGlyph(glyph, tint = fg, sizeDp = 12)
            Spacer(Modifier.width(5.dp))
        }
        Text(
            text,
            style = DvType.Caption,
            fontWeight = FontWeight.SemiBold,
            color = fg,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
fun SoftButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    glyph: DvGlyph = DvGlyph.HeartFilled,
    active: Boolean = true,
) {
    val p = DvTheme.palette
    Row(
        modifier = modifier
            .height(36.dp)
            .clip(RoundedCornerShape(DvSpace.ControlRadius))
            .background(if (active) p.accentSoft else p.surface)
            .clickableNoRipple(onClick)
            .padding(horizontal = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        DvGlyph(
            glyph = if (active) glyph else DvGlyph.Heart,
            tint = if (active) p.accent else p.muted,
            sizeDp = 13,
        )
        Spacer(Modifier.width(4.dp))
        Text(
            text,
            style = DvType.Caption,
            fontWeight = FontWeight.SemiBold,
            color = if (active) p.accent else p.muted,
            maxLines = 1,
        )
    }
}

/** 详情页第二层的「图标 + 小字」按钮。 */
@Composable
fun IconAction(
    glyph: DvGlyph,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    active: Boolean = false,
    tintOverride: Color? = null,
) {
    val p = DvTheme.palette
    val tint = tintOverride ?: if (active) p.accent else p.muted
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(9.dp))
            .background(if (active) p.accentSoft else Color.Transparent)
            .clickableNoRipple(onClick)
            .padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        DvGlyph(glyph, tint = tint, sizeDp = 18)
        Text(
            label,
            style = DvType.Micro,
            fontSize = DvType.Micro.fontSize,
            color = if (active) tint else p.muted,
            maxLines = 1,
        )
    }
}

// ------------------------------------------------------------------ 进度

@Composable
fun ProgressLine(
    progress: Float,
    modifier: Modifier = Modifier,
    color: Color = Color.White,
    track: Color = Color.White.copy(alpha = 0.28f),
    height: Dp = 2.5.dp,
) {
    Box(
        modifier = modifier
            .height(height)
            .clip(RoundedCornerShape(2.dp))
            .background(track),
    ) {
        Box(
            Modifier
                .fillMaxWidth(progress.coerceIn(0f, 1f))
                .fillMaxHeight()
                .background(color),
        )
    }
}

// ------------------------------------------------------------------ 卡片

/**
 * 竖版海报卡。
 *
 * `badge` 优先放集数（"12"），否则放清晰度（"4K"）——两者都放会挤，
 * 而集数对"追到哪了"更有用。
 */
@Composable
fun PosterCard(
    title: String,
    posterPath: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    badge: String? = null,
    subtitle: String? = null,
    progress: Float = 0f,
    width: Dp = 104.dp,
    fillWidth: Boolean = false,
) {
    val p = DvTheme.palette
    Column(
        modifier = (if (fillWidth) modifier.fillMaxWidth() else modifier.width(width))
            .clickableNoRipple(onClick),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(2f / 3f)
                .clip(RoundedCornerShape(10.dp)),
        ) {
            RemoteImage(posterPath, Modifier.fillMaxSize())
            if (badge != null) {
                Text(
                    text = badge,
                    style = DvType.Micro,
                    fontSize = DvType.Badge.fontSize,
                    fontWeight = FontWeight.Bold,
                    color = Color.White,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(3.dp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(Color.Black.copy(alpha = 0.62f))
                        .padding(horizontal = 4.dp, vertical = 1.dp),
                )
            }
            if (progress > 0f) {
                ProgressLine(
                    progress = progress,
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .fillMaxWidth(),
                    track = Color.Black.copy(alpha = 0.35f),
                    color = p.accent,
                )
            }
        }
        Text(
            title,
            style = DvType.Caption,
            fontSize = DvType.CardTitle.fontSize,
            color = p.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 8.dp),
        )
        if (subtitle != null) {
            Text(
                subtitle,
                style = DvType.Micro,
                fontSize = DvType.Micro.fontSize,
                color = p.faint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 1.dp),
            )
        }
    }
}

@Composable
fun PosterCard(
    item: MediaItem,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    width: Dp = 104.dp,
    fillWidth: Boolean = false,
) {
    val badge = item.episodeCount?.takeIf { it > 1 }?.toString()
        ?: item.resolution
    PosterCard(
        title = cleanTitle(item.title),
        posterPath = item.posterPath,
        onClick = onClick,
        modifier = modifier,
        badge = badge,
        subtitle = item.year?.toString() ?: item.rating?.let { "★ %.1f".format(it) },
        progress = item.progress.toFloat(),
        width = width,
        fillWidth = fillWidth,
    )
}

/** 首屏大图：最新入库 / 继续观看。 */
@Composable
fun HeroCard(
    title: String,
    posterPath: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    badge: String? = null,
    subtitle: String? = null,
    progress: Float = 0f,
    height: Dp = 150.dp,
    playGlyph: DvGlyph = DvGlyph.Play,
) {
    val p = DvTheme.palette
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(height)
            .clip(RoundedCornerShape(DvSpace.CardRadius))
            .clickableNoRipple(onClick),
    ) {
        RemoteImage(posterPath, Modifier.fillMaxSize(), ContentScale.Crop)
        // 底部压暗，标题才压得住亮场景。
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0f to Color.Black.copy(alpha = 0.22f),
                        0.34f to Color.Transparent,
                        1f to Color.Black.copy(alpha = 0.76f),
                    ),
                ),
        )
        if (badge != null) {
            Text(
                text = badge,
                style = DvType.Micro,
                fontWeight = FontWeight.Bold,
                color = p.onAccent,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(9.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(p.accent)
                    .padding(horizontal = 5.dp, vertical = 2.dp),
            )
        }
        Column(
            Modifier
                .align(Alignment.BottomStart)
                .padding(start = 11.dp, end = 48.dp, bottom = 10.dp),
        ) {
            Text(
                title,
                style = DvType.SectionTitle,
                color = Color.White,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (subtitle != null) {
                Text(
                    subtitle,
                    style = DvType.Micro,
                    color = DvOnImage.Secondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
        }
        Box(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(9.dp)
                .size(26.dp)
                .clip(RoundedCornerShape(99.dp))
                .background(Color.White.copy(alpha = 0.95f)),
            contentAlignment = Alignment.Center,
        ) {
            DvGlyph(playGlyph, tint = Color(0xFF111111), sizeDp = 11)
        }
        if (progress > 0f) {
            ProgressLine(
                progress = progress,
                modifier = Modifier.align(Alignment.BottomStart).fillMaxWidth(),
            )
        }
    }
}

/** 16:9 的继续观看卡。 */
@Composable
fun WideCard(
    title: String,
    posterPath: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    badge: String? = null,
    subtitle: String? = null,
    progress: Float = 0f,
    width: Dp = 200.dp,
) {
    val p = DvTheme.palette
    Column(modifier = modifier.width(width).clickableNoRipple(onClick)) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .clip(RoundedCornerShape(10.dp)),
        ) {
            RemoteImage(posterPath, Modifier.fillMaxSize())
            if (badge != null) {
                Text(
                    text = badge,
                    style = DvType.Micro,
                    fontWeight = FontWeight.Bold,
                    color = Color.White,
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .padding(6.dp),
                )
            }
            Box(
                Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            0.55f to Color.Transparent,
                            1f to Color.Black.copy(alpha = 0.55f),
                        ),
                    ),
            )
            if (progress > 0f) {
                ProgressLine(
                    progress = progress,
                    modifier = Modifier.align(Alignment.BottomStart).fillMaxWidth(),
                    track = Color.White.copy(alpha = 0.3f),
                    color = Color.White,
                )
            }
        }
        Text(
            title,
            style = DvType.Caption,
            color = p.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 5.dp),
        )
        if (subtitle != null) {
            Text(
                subtitle,
                style = DvType.Micro,
                fontSize = DvType.Micro.fontSize,
                color = p.faint,
                maxLines = 1,
            )
        }
    }
}

@Composable
fun WideCard(
    record: PlayRecord,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    width: Dp = 200.dp,
) {
    val remain = record.durationSeconds - record.positionSeconds
    val badge = when {
        record.episodeNumber != null && record.seasonNumber != null ->
            "S${record.seasonNumber} E${record.episodeNumber}"
        record.episodeNumber != null -> "第 ${record.episodeNumber} 集"
        else -> null
    }
    WideCard(
        title = cleanTitle(record.seriesTitle ?: record.title),
        posterPath = record.posterPath,
        onClick = onClick,
        modifier = modifier,
        badge = badge,
        subtitle = runtimeLabel(remain)?.let { "剩 $it" },
        progress = record.progress.toFloat(),
        width = width,
    )
}

// ------------------------------------------------------------------ 空态

@Composable
fun EmptyHint(
    glyph: DvGlyph,
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    val p = DvTheme.palette
    Column(
        modifier = modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            modifier = Modifier
                .size(46.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(p.accentSoft),
            contentAlignment = Alignment.Center,
        ) {
            DvGlyph(glyph, tint = p.accent, sizeDp = 20)
        }
        Text(title, style = DvType.SectionTitle, color = p.text)
        Text(
            message,
            style = DvType.Caption,
            color = p.faint,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        if (actionLabel != null && onAction != null) {
            Spacer(Modifier.height(4.dp))
            PrimaryButton(actionLabel, onAction, glyph = DvGlyph.Plus)
        }
    }
}
