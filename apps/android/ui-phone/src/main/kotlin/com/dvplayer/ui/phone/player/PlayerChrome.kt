package com.dvplayer.ui.phone.player

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dvplayer.design.DvColors

/** 播放页的固定尺寸（UI-DESIGN §5：顶栏 40dp / 底栏 48dp）。 */
object PlayerDimens {
    val TopBar = 40.dp
    val BottomBar = 48.dp
    val Edge = 12.dp
    val Accent = DvColors.Accent
}

private val white90 = Color(0xFFF5F5F8)
private val white70 = Color(0xB3FFFFFF)
private val white55 = Color(0x8CFFFFFF)
private val white22 = Color(0x38FFFFFF)
private val glass = Color(0xCC000000)

/** 无涟漪的图标按钮；播放页的点击区 40dp，视觉大小另给。 */
@Composable
fun IconAction(
    icon: DvIcon,
    iconSize: Int,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = white90,
    contentDescription: String? = null,
) {
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = modifier
            .size(40.dp)
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClickLabel = contentDescription,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        DvIcon(icon, tint = tint, sizeDp = iconSize)
    }
}

/** 顶栏：关闭 / 片名 / PiP / 全屏 / 设置。 */
@Composable
fun PlayerTopBar(
    title: String,
    onBack: () -> Unit,
    onPip: () -> Unit,
    onFullscreen: () -> Unit,
    onSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(PlayerDimens.TopBar)
            // 半透明压在画面上；纯黑会把画面「切」成上下两段。
            .background(
                Brush.verticalGradient(
                    listOf(Color(0xD9000000), Color(0x66000000)),
                ),
            )
            .padding(start = 6.dp, end = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconAction(DvIcon.Close, 20, onBack, contentDescription = "关闭")
        Spacer(Modifier.width(4.dp))
        Text(
            text = title,
            color = white90,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        IconAction(DvIcon.Pip, 20, onPip, contentDescription = "画中画")
        Spacer(Modifier.width(2.dp))
        IconAction(DvIcon.Fullscreen, 18, onFullscreen, contentDescription = "全屏")
        Spacer(Modifier.width(2.dp))
        IconAction(DvIcon.Gear, 20, onSettings, contentDescription = "设置")
    }
}

/** 底栏：快退 / 播放暂停 / 快进 + 下一集 / 倍速 / 音轨 / 字幕。 */
@Composable
fun PlayerBottomBar(
    paused: Boolean,
    speed: Float,
    hasNext: Boolean,
    onRewind: () -> Unit,
    onToggle: () -> Unit,
    onForward: () -> Unit,
    onNext: () -> Unit,
    onSpeed: () -> Unit,
    onAudio: () -> Unit,
    onSubtitle: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(PlayerDimens.BottomBar)
            .padding(start = 8.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconAction(DvIcon.Rewind, 24, onRewind, contentDescription = "快退 10 秒")
        Spacer(Modifier.width(8.dp))
        IconAction(
            if (paused) DvIcon.Play else DvIcon.Pause,
            if (paused) 26 else 24,
            onToggle,
            contentDescription = if (paused) "播放" else "暂停",
        )
        Spacer(Modifier.width(8.dp))
        IconAction(DvIcon.Forward, 24, onForward, contentDescription = "快进 10 秒")

        Spacer(Modifier.weight(1f))

        if (hasNext) {
            IconAction(DvIcon.Next, 20, onNext, contentDescription = "下一集")
        }
        SpeedAction(speed, onSpeed)
        IconAction(DvIcon.Audio, 20, onAudio, contentDescription = "音轨", tint = white70)
        IconAction(DvIcon.Subtitle, 22, onSubtitle, contentDescription = "字幕", tint = white70)
    }
}

/** 倍速用「1.0×」而不是时钟图标：一眼能看出当前是不是非 1 倍。 */
@Composable
private fun SpeedAction(speed: Float, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = Modifier
            .height(40.dp)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .padding(horizontal = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = if (speed % 1f == 0f) "${speed.toInt()}.0×" else "%.1f×".format(speed),
            color = if (speed != 1f) PlayerDimens.Accent else white70,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

/** 规格行的一格。 */
@Composable
fun SpecChip(text: String, accent: Boolean = false) {
    Text(
        text = text,
        color = if (accent) PlayerDimens.Accent else white90,
        fontSize = 10.sp,
        modifier = Modifier
            .background(if (accent) Color(0x33FFB020) else Color(0x66000000), RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 2.dp),
    )
}

/**
 * 三层进度条：已看（主色）/ 已缓冲（亮白）/ 未看（暗白）。
 *
 * 18dp 的命中区，线只有 2dp；点轨道任意位置就跳，拖动时只回调比例，
 * 由调用方决定是否立刻 seek（网络流应该松手才 seek）。
 */
@Composable
fun PlayerProgress(
    positionMs: Long,
    bufferedMs: Long,
    durationMs: Long,
    onSeeking: (Float) -> Unit,
    onSeekStart: () -> Unit = {},
    onSeekEnd: () -> Unit = {},
    modifier: Modifier = Modifier,
    height: Int = 18,
) {
    val total = durationMs.coerceAtLeast(1)
    val played = (positionMs.toFloat() / total).coerceIn(0f, 1f)
    val buffered = (bufferedMs.toFloat() / total).coerceIn(played, 1f)

    Canvas(
        modifier = modifier
            .fillMaxWidth()
            .height(height.dp)
            .pointerInput(total) {
                detectDragGestures(
                    onDragStart = { offset ->
                        onSeekStart()
                        onSeeking((offset.x / size.width).coerceIn(0f, 1f))
                    },
                    onDrag = { change, _ ->
                        onSeeking((change.position.x / size.width).coerceIn(0f, 1f))
                    },
                    onDragEnd = { onSeekEnd() },
                    onDragCancel = { onSeekEnd() },
                )
            },
    ) {
        val cy = size.height / 2f
        val line = 2.dp.toPx()
        val radius = CornerRadius(line / 2f)
        drawRoundRect(
            color = white22,
            topLeft = Offset(0f, cy - line / 2f),
            size = Size(size.width, line),
            cornerRadius = radius,
        )
        drawRoundRect(
            color = white55,
            topLeft = Offset(0f, cy - line / 2f),
            size = Size(size.width * buffered, line),
            cornerRadius = radius,
        )
        drawRoundRect(
            color = PlayerDimens.Accent,
            topLeft = Offset(0f, cy - line / 2f),
            size = Size(size.width * played, line),
            cornerRadius = radius,
        )
        val knobX = (size.width * played).coerceIn(5.dp.toPx(), size.width - 5.dp.toPx())
        drawCircle(color = Color.White, radius = 4.5.dp.toPx(), center = Offset(knobX, cy))
    }
}

/**
 * 播放页底部控制层：片名 / 规格 / 时间进度 + 按钮行。
 *
 * 整块只画一次背景——横屏半透明渐变压在画面上，竖屏用页面底色紧贴视频。
 * 拆成「元信息」和「按钮」两个控件各自画渐变时，接缝处会露出色差。
 */
@Composable
fun PlayerBottomChrome(
    model: PlayerUiModel,
    positionMs: Long,
    paused: Boolean,
    /** true：横屏叠在视频上；false：竖屏紧贴视频下沿。 */
    overlay: Boolean,
    onSeeking: (Float) -> Unit,
    onSeekStart: () -> Unit,
    onSeekEnd: () -> Unit,
    onRewind: () -> Unit,
    onToggle: () -> Unit,
    onForward: () -> Unit,
    onNext: () -> Unit,
    onSpeed: () -> Unit,
    onAudio: () -> Unit,
    onSubtitle: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val titleSize = if (overlay) 12.sp else 14.sp
    val timeSize = if (overlay) 10.sp else 11.sp

    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(
                if (overlay) {
                    Brush.verticalGradient(
                        0f to Color.Transparent,
                        0.4f to Color(0x99000000),
                        1f to Color(0xE6000000),
                    )
                } else {
                    // 竖屏和页面底色完全一致，避免出现「控制层 / 简介」两块色差。
                    SolidColor(Color.Black)
                },
            ),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = PlayerDimens.Edge, end = PlayerDimens.Edge, top = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = model.title,
                color = white90,
                fontSize = titleSize,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.width(6.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                model.chips.forEach { SpecChip(it.text, it.accent) }
            }
        }
        Spacer(Modifier.height(4.dp))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = PlayerDimens.Edge, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = formatTime(positionMs),
                color = white90,
                fontSize = timeSize,
                fontWeight = FontWeight.Medium,
            )
            PlayerProgress(
                positionMs = positionMs,
                bufferedMs = model.bufferedMs,
                durationMs = model.durationMs,
                onSeeking = onSeeking,
                onSeekStart = onSeekStart,
                onSeekEnd = onSeekEnd,
                modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
            )
            Text(
                text = formatTime(model.durationMs),
                color = white70,
                fontSize = timeSize,
            )
        }
        PlayerBottomBar(
            paused = paused,
            speed = model.speed,
            hasNext = model.hasNext,
            onRewind = onRewind,
            onToggle = onToggle,
            onForward = onForward,
            onNext = onNext,
            onSpeed = onSpeed,
            onAudio = onAudio,
            onSubtitle = onSubtitle,
        )
    }
}

/** 竖屏视频下方：简介 + 选集横滑（横屏没有这块，收在菜单里）。 */
@Composable
fun PlayerPortraitDetails(
    model: PlayerUiModel,
    onPickEpisode: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth().padding(horizontal = PlayerDimens.Edge)) {
        model.overview?.let { overview ->
            Spacer(Modifier.height(10.dp))
            Text(
                text = "简介",
                color = white55,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = overview,
                color = white70,
                fontSize = 12.sp,
                lineHeight = 17.sp,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }

        if (model.episodes.isNotEmpty()) {
            Spacer(Modifier.height(14.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = "选集",
                    color = white90,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    text = "共 ${model.episodes.size} 集",
                    color = white55,
                    fontSize = 10.sp,
                )
            }
            Spacer(Modifier.height(8.dp))
            LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                items(model.episodes.size) { index ->
                    val episode = model.episodes[index]
                    val current = episode.current
                    Box(
                        modifier = Modifier
                            .size(width = 52.dp, height = 32.dp)
                            .background(
                                if (current) Color(0x33FFB020) else Color(0x14FFFFFF),
                                RoundedCornerShape(6.dp),
                            )
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                                onClick = { onPickEpisode(index) },
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = "${index + 1}",
                            color = if (current) PlayerDimens.Accent else white70,
                            fontSize = 12.sp,
                            fontWeight = if (current) FontWeight.SemiBold else FontWeight.Normal,
                        )
                    }
                }
            }
        }
        Spacer(Modifier.height(4.dp))
    }
}

/** 画面两侧的常驻小按钮：锁屏 / 静音。 */
@Composable
fun PlayerSideActions(
    locked: Boolean,
    muted: Boolean,
    onToggleLock: () -> Unit,
    onToggleMute: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier = modifier.fillMaxWidth().height(64.dp)) {
        Box(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .padding(start = 10.dp)
                .size(36.dp)
                .background(glass, RoundedCornerShape(18.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onToggleLock,
                ),
            contentAlignment = Alignment.Center,
        ) {
            DvIcon(
                DvIcon.Lock,
                tint = if (locked) PlayerDimens.Accent else white70,
                sizeDp = 18,
            )
        }
        Box(
            modifier = Modifier
                .align(Alignment.CenterEnd)
                .padding(end = 10.dp)
                .size(36.dp)
                .background(glass, RoundedCornerShape(18.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onToggleMute,
                ),
            contentAlignment = Alignment.Center,
        ) {
            DvIcon(
                if (muted) DvIcon.Audio else DvIcon.Volume,
                tint = if (muted) PlayerDimens.Accent else white70,
                sizeDp = 17,
            )
        }
    }
}

/** 拖动 / 长按时的顶部小气泡。 */
@Composable
fun PlayerHintBubble(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        color = white90,
        fontSize = 11.sp,
        modifier = modifier
            .background(glass, RoundedCornerShape(6.dp))
            .padding(horizontal = 10.dp, vertical = 5.dp),
    )
}

/** 占位画面：静态截图和没有视频时用。接内核后换成 SurfaceView。 */
@Composable
fun PlayerVideoPlaceholder(label: String, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
            Brush.linearGradient(
                listOf(Color(0xFF4E4231), Color(0xFF2C2721), Color(0xFF141317)),
            ),
        ),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            color = Color(0x12FFFFFF),
            fontSize = 11.sp,
        )
    }
}
