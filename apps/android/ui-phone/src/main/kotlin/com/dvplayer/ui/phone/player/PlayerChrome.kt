package com.dvplayer.ui.phone.player

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dvplayer.design.DvColors
import com.dvplayer.design.DvType
import com.dvplayer.design.DvOnImage
import com.dvplayer.ui.phone.ui.LocalStillLoader

/** 播放页的固定尺寸（UI-DESIGN §5：顶栏 40dp / 底栏 48dp）。 */
object PlayerDimens {
    val TopBar = 40.dp
    val BottomBar = 40.dp
    val Edge = 12.dp
    val Accent = DvColors.Accent
}

private val white90 = Color(0xFFF5F5F8)
private val white70 = DvOnImage.Secondary
private val white55 = DvOnImage.Tertiary
private val white22 = Color(0x38FFFFFF)
private val glass = Color(0xCC000000)

/** 无涟漪的图标按钮；播放页的点击区 40dp，视觉大小另给。 */
@Composable
fun IconAction(
    icon: DvIcon,
    iconSize: Int,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = Color.White,
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
            // 透明：只留图标，不铺底色。
            .padding(start = 6.dp, end = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconAction(DvIcon.Close, 20, onBack, contentDescription = "关闭")
        Spacer(Modifier.width(4.dp))
        Text(
            text = title,
            color = Color.White,
            fontSize = DvType.CardTitle.fontSize,
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
    hasEpisodes: Boolean,
    onRewind: () -> Unit,
    onToggle: () -> Unit,
    onForward: () -> Unit,
    onEpisodes: () -> Unit,
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

        PlayerToolActions(speed, hasEpisodes, onEpisodes, onSpeed, onAudio, onSubtitle)
    }
}

/**
 * 选集 / 倍速 / 音轨 / 字幕，接在播放键右边。
 *
 * 选集只在有分集时出现：电影没有集，摆一个点了是空面板的按钮没意义。
 */
@Composable
private fun PlayerToolActions(
    speed: Float,
    hasEpisodes: Boolean,
    onEpisodes: () -> Unit,
    onSpeed: () -> Unit,
    onAudio: () -> Unit,
    onSubtitle: () -> Unit,
) {
    if (hasEpisodes) {
        IconAction(DvIcon.Episodes, 20, onEpisodes, contentDescription = "选集")
    }
    SpeedAction(speed, onSpeed)
    IconAction(DvIcon.Audio, 20, onAudio, contentDescription = "音轨")
    IconAction(DvIcon.Subtitle, 22, onSubtitle, contentDescription = "字幕")
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
        // 1.25× 这类档位用两位，别被四舍五入成 1.3×。
        val text = when {
            speed % 1f == 0f -> "${speed.toInt()}.0×"
            (speed * 10f) % 1f == 0f -> "%.1f×".format(speed)
            else -> "%.2f×".format(speed)
        }
        Text(
            text = text,
            color = Color.White,
            fontSize = DvType.Micro.fontSize,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

/** 规格行的一格。 */
@Composable
fun SpecChip(text: String, accent: Boolean = false) {
    Text(
        text = text,
        color = Color.White,
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
    height: Int = 20,
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
        // 命中区留高，线画在靠下：视觉上贴近按钮，手指也好点。
        val cy = size.height * 0.7f
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
    /** true：叠在视频画面内；false：视频下方（占布局）。 */
    overlay: Boolean,
    /** 竖屏悬浮时只留进度 + 按钮，片名在顶栏、规格在视频下方。 */
    compact: Boolean = false,
    onSeeking: (Float) -> Unit,
    onSeekStart: () -> Unit,
    onSeekEnd: () -> Unit,
    onRewind: () -> Unit,
    onToggle: () -> Unit,
    onForward: () -> Unit,
    onEpisodes: () -> Unit,
    onSpeed: () -> Unit,
    onAudio: () -> Unit,
    onSubtitle: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val titleSize = if (overlay) 12.sp else 14.sp
    val timeSize = if (overlay) 10.sp else 11.sp

    // 透明：叠在画面上，不铺底色。
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(top = if (compact) 4.dp else 0.dp),
    ) {
        // 规格行：横屏贴在底部控制条上方，竖屏贴在视频下方（控制层的最上面）。
        if (model.chips.isNotEmpty()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        start = PlayerDimens.Edge,
                        end = PlayerDimens.Edge,
                        top = if (overlay) 8.dp else 0.dp,
                    ),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                model.chips.forEach { SpecChip(it.text, it.accent) }
            }
            Spacer(Modifier.height(4.dp))
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = PlayerDimens.Edge, vertical = 0.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = formatTime(positionMs),
                color = Color.White,
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
                color = Color.White,
                fontSize = timeSize,
            )
        }
        if (compact) {
            // 竖屏：快退 / 播放 / 快进和选集、倍速、音轨、字幕同一行（和横屏一致）。
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(PlayerDimens.BottomBar)
                    .padding(horizontal = 8.dp),
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
                PlayerToolActions(
                    speed = model.speed,
                    hasEpisodes = model.episodes.isNotEmpty(),
                    onEpisodes = onEpisodes,
                    onSpeed = onSpeed,
                    onAudio = onAudio,
                    onSubtitle = onSubtitle,
                )
            }
        } else {
            PlayerBottomBar(
                paused = paused,
                speed = model.speed,
                hasEpisodes = model.episodes.isNotEmpty(),
                onRewind = onRewind,
                onToggle = onToggle,
                onForward = onForward,
                onEpisodes = onEpisodes,
                onSpeed = onSpeed,
                onAudio = onAudio,
                onSubtitle = onSubtitle,
            )
        }
    }
}

/**
 * 选集卡片条：16:9 剧照 + 集号 + 分集名，当前集白框高亮。
 *
 * 剧照由 [PlayerEpisode.stillPath] 提供（走播放 Activity 给的加载器）；
 * 没有剧照 / 还没加载出来时画一个带集号的深色占位，不让卡片变成一块空白。
 */
@Composable
fun EpisodeStrip(
    episodes: List<PlayerEpisode>,
    onPickEpisode: (Int) -> Unit,
    modifier: Modifier = Modifier,
    cardWidth: Dp = 152.dp,
) {
    val currentIndex = episodes.indexOfFirst { it.current }
    val state = rememberLazyListState(
        // 当前集左侧留一张：打开面板就能看到前后集。
        initialFirstVisibleItemIndex = (currentIndex - 1).coerceAtLeast(0),
    )
    LazyRow(
        state = state,
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        items(episodes.size) { index ->
            EpisodeCard(
                episode = episodes[index],
                index = index,
                width = cardWidth,
                onClick = { onPickEpisode(index) },
            )
        }
    }
}

@Composable
private fun EpisodeCard(
    episode: PlayerEpisode,
    index: Int,
    width: Dp,
    onClick: () -> Unit,
) {
    val current = episode.current
    // 剧照要现取：路径交给播放 Activity 提供的加载器（复用 PhoneRepository 的缓存）。
    val loader = LocalStillLoader.current
    var still by remember(episode.stillPath) { mutableStateOf<android.graphics.Bitmap?>(null) }
    LaunchedEffect(episode.stillPath, loader) {
        val path = episode.stillPath?.takeIf { it.isNotBlank() }
        still = if (path != null) loader?.invoke(path) else null
    }
    Column(
        modifier = Modifier
            .width(width)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            ),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .clip(RoundedCornerShape(7.dp))
                .background(stillBrush(index))
                .border(
                    width = if (current) 1.5.dp else 0.5.dp,
                    color = if (current) Color.White else Color(0x1FFFFFFF),
                    shape = RoundedCornerShape(7.dp),
                ),
        ) {
            // 有真剧照就铺上；没有时用一角柔光占位。
            still?.let {
                Image(
                    bitmap = it.asImageBitmap(),
                    contentDescription = null,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Crop,
                )
            } ?: Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        Brush.radialGradient(
                            0f to Color(0x33FFFFFF),
                            1f to Color.Transparent,
                        ),
                    ),
            )
            Box(
                modifier = Modifier
                    .align(Alignment.Center)
                    .size(26.dp)
                    .background(Color(0x2EFFFFFF), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                DvIcon(DvIcon.Play, tint = Color(0xB3FFFFFF), sizeDp = 14)
            }
            // 底部压暗，托住时长角标。
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            0f to Color.Transparent,
                            1f to Color(0xA6000000),
                        ),
                    ),
            )
            Text(
                text = episode.duration,
                color = DvOnImage.Secondary,
                fontSize = DvType.Badge.fontSize,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(horizontal = 5.dp, vertical = 4.dp),
            )
            if (current) {
                Text(
                    text = "播放中",
                    color = Color.White,
                    fontSize = DvType.Badge.fontSize,
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .padding(5.dp)
                        .background(Color(0xB3000000), RoundedCornerShape(3.dp))
                        .padding(horizontal = 4.dp, vertical = 2.dp),
                )
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(
            text = episode.title,
            color = if (current) Color.White else white90,
            fontSize = DvType.Caption.fontSize,
            fontWeight = if (current) FontWeight.SemiBold else FontWeight.Medium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = episode.subtitle ?: episode.duration,
            color = if (current) white70 else white55,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** 占位剧照：一组偏冷的暗色，按集号轮换，避免整条同色。 */
private fun stillBrush(index: Int): Brush {
    val palette = listOf(
        Color(0xFF3A4A63) to Color(0xFF0F1620),
        Color(0xFF5A4030) to Color(0xFF1A120C),
        Color(0xFF2E4A40) to Color(0xFF0D1A15),
        Color(0xFF4A2F3F) to Color(0xFF1A0E15),
        Color(0xFF3F3B58) to Color(0xFF14121F),
    )
    val (start, end) = palette[index % palette.size]
    return Brush.linearGradient(listOf(start, end))
}

/** 竖屏视频下方：简介 + 选集卡片条（横屏没有这块，收在菜单里）。 */
@Composable
fun PlayerPortraitDetails(
    model: PlayerUiModel,
    onPickEpisode: (Int) -> Unit,
    modifier: Modifier = Modifier,
    /** 选集面板打开时把页面里这条收起来，避免和弹层重复。 */
    showEpisodes: Boolean = true,
) {
    Column(modifier = modifier.fillMaxWidth()) {
        model.overview?.let { overview ->
            Spacer(Modifier.height(10.dp))
            Text(
                text = "简介",
                color = white55,
                fontSize = DvType.Micro.fontSize,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.padding(horizontal = PlayerDimens.Edge),
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = overview,
                color = white70,
                fontSize = DvType.Caption.fontSize,
                lineHeight = 17.sp,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = PlayerDimens.Edge),
            )
        }

        if (showEpisodes && model.episodes.isNotEmpty()) {
            Spacer(Modifier.height(14.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(horizontal = PlayerDimens.Edge),
            ) {
                Text(
                    text = "选集",
                    color = white90,
                    fontSize = DvType.Caption.fontSize,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    text = "共 ${model.episodes.size} 集",
                    color = white55,
                )
            }
            Spacer(Modifier.height(8.dp))
            EpisodeStrip(
                episodes = model.episodes,
                onPickEpisode = onPickEpisode,
                cardWidth = 132.dp,
            )
        }
        Spacer(Modifier.height(4.dp))
    }
}

/** 画面两侧的常驻小按钮：锁屏 / 横竖屏切换。 */
@Composable
fun PlayerSideActions(
    locked: Boolean,
    onToggleLock: () -> Unit,
    onRotate: () -> Unit,
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
                tint = if (locked) PlayerDimens.Accent else Color.White,
                sizeDp = 18,
            )
        }
        Box(
            modifier = Modifier
                .align(Alignment.CenterEnd)
                .padding(end = 10.dp)
                .size(40.dp)
                .background(glass, RoundedCornerShape(20.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onRotate,
                ),
            contentAlignment = Alignment.Center,
        ) {
            DvIcon(
                DvIcon.Rotate,
                tint = Color.White,
                sizeDp = 22,
            )
        }
    }
}

/** 拖动 / 长按时的顶部小气泡。 */
@Composable
fun PlayerHintBubble(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        color = Color.White,
        fontSize = DvType.Micro.fontSize,
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
            fontSize = DvType.Micro.fontSize,
        )
    }
}
