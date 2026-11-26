package com.dvplayer.ui.phone.player

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

/**
 * 手机播放页。
 *
 * 布局约定（UI-DESIGN §5）：
 * - 顶栏 40dp / 底栏 48dp，落在画面外；画面内只叠「片名 / 规格 / 进度」。
 * - 横屏沉浸：上下贴边；竖屏：顶栏 + 视频 + 信息块 + 底栏。
 * - 3 秒无操作控制层淡出；锁屏后只剩画面，长按解锁。
 * - 手势在视频区域：左右滑 seek、双击暂停、长按 2×；点击唤出 / 收起。
 *
 * 现在视频是占位渐变；接内核时把 [video] 换成 SurfaceView 的 `AndroidView` 即可，
 * 控制层和状态都不用动。
 */
@Composable
fun PlayerScreen(
    model: PlayerUiModel,
    onBack: () -> Unit = {},
    onPip: () -> Unit = {},
    onToggleFullscreen: () -> Unit = {},
    initialPanel: PlayerPanel = PlayerPanel.None,
    initialMenuOpen: Boolean = false,
    forceLandscape: Boolean? = null,
    /** 截图 / 演示时关掉 3 秒自动淡出。 */
    autoHide: Boolean = true,
    video: @Composable () -> Unit = { PlayerVideoPlaceholder("") },
) {
    val configuration = LocalConfiguration.current
    val landscape = forceLandscape
        ?: (configuration.screenWidthDp > configuration.screenHeightDp)

    var paused by remember(model) { mutableStateOf(model.paused) }
    var positionMs by remember(model) { mutableStateOf(model.positionMs) }
    var muted by remember { mutableStateOf(false) }
    var locked by remember { mutableStateOf(false) }
    var chromeVisible by remember { mutableStateOf(true) }
    var panel by remember { mutableStateOf(initialPanel) }
    var menuOpen by remember { mutableStateOf(initialMenuOpen) }
    var scrubbing by remember { mutableStateOf(false) }
    var seekPreviewMs by remember { mutableStateOf(model.positionMs) }
    var boosting by remember { mutableStateOf(false) }
    var lockHint by remember { mutableStateOf(false) }
    var toast by remember { mutableStateOf<String?>(null) }
    var engine by remember(model) {
        mutableStateOf(model.chips.firstOrNull { it.accent }?.text ?: "mpv")
    }
    var selectedAudio by remember(model) {
        mutableStateOf(model.audios.indexOfFirst { it.selected }.coerceAtLeast(0))
    }
    var selectedSubtitle by remember(model) {
        mutableStateOf(model.subtitles.indexOfFirst { it.selected }.coerceAtLeast(0))
    }

    // 3 秒无操作淡出；面板 / 菜单 / 拖动期间不淡出。
    LaunchedEffect(chromeVisible, panel, menuOpen, locked, scrubbing, autoHide) {
        if (autoHide && chromeVisible && panel == PlayerPanel.None && !menuOpen && !locked && !scrubbing) {
            delay(3000)
            chromeVisible = false
        }
    }

    LaunchedEffect(toast) {
        if (toast != null) {
            delay(1800)
            toast = null
        }
    }

    LaunchedEffect(lockHint) {
        if (lockHint) {
            delay(1800)
            lockHint = false
        }
    }

    LaunchedEffect(panel, menuOpen) {
        if (panel != PlayerPanel.None || menuOpen) {
            chromeVisible = true
        }
    }

    val shownAudios = model.audios.mapIndexed { index, track ->
        track.copy(selected = index == selectedAudio)
    }
    val shownSubtitles = model.subtitles.mapIndexed { index, track ->
        track.copy(selected = index == selectedSubtitle)
    }

    /** 画面手势：点击唤出 / 收起、双击暂停、长按 2×、左右滑 seek。 */
    val gestures = Modifier
        .pointerInput(locked) {
            if (!locked) {
                detectTapGestures(
                    onTap = { chromeVisible = !chromeVisible },
                    onDoubleTap = {
                        paused = !paused
                        chromeVisible = true
                    },
                    onLongPress = { boosting = true },
                    onPress = {
                        tryAwaitRelease()
                        boosting = false
                    },
                )
            }
        }
        .pointerInput(locked) {
            if (!locked) {
                detectHorizontalDragGestures(
                    onDragStart = { offset ->
                        scrubbing = true
                        seekPreviewMs =
                            (offset.x / size.width * model.durationMs).toLong().coerceIn(0, model.durationMs)
                        positionMs = seekPreviewMs
                        chromeVisible = true
                    },
                    onHorizontalDrag = { change, _ ->
                        seekPreviewMs =
                            (change.position.x / size.width * model.durationMs).toLong()
                                .coerceIn(0, model.durationMs)
                        positionMs = seekPreviewMs
                    },
                    onDragEnd = { scrubbing = false },
                    onDragCancel = { scrubbing = false },
                )
            }
        }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        if (landscape) {
            // —— 横屏：视频铺满，控制层上下贴边 ——
            Box(modifier = Modifier.fillMaxSize()) { video() }
            Box(modifier = Modifier.fillMaxSize().then(gestures))

            if (!locked && chromeVisible) {
                PlayerTopBar(
                    title = model.title,
                    onBack = onBack,
                    onPip = onPip,
                    onFullscreen = onToggleFullscreen,
                    onSettings = { menuOpen = true },
                    modifier = Modifier.align(Alignment.TopCenter),
                )
                PlayerSideActions(
                    locked = locked,
                    muted = muted,
                    onToggleLock = {
                        locked = true
                        chromeVisible = false
                    },
                    onToggleMute = { muted = !muted },
                    modifier = Modifier.align(Alignment.Center),
                )
                PlayerBottomChrome(
                    model = model,
                    positionMs = positionMs,
                    paused = paused,
                    overlay = true,
                    onSeeking = { ratio -> positionMs = (ratio * model.durationMs).toLong() },
                    onSeekStart = { scrubbing = true },
                    onSeekEnd = { scrubbing = false },
                    onRewind = { positionMs = (positionMs - 10_000).coerceAtLeast(0) },
                    onToggle = {
                        paused = !paused
                        chromeVisible = true
                    },
                    onForward = {
                        positionMs = (positionMs + 10_000).coerceAtMost(model.durationMs)
                    },
                    onNext = { toast = "下一集（等下版接内核）" },
                    onSpeed = { toast = "倍速：等下版接内核" },
                    onAudio = { panel = PlayerPanel.Audio },
                    onSubtitle = { panel = PlayerPanel.Subtitle },
                    modifier = Modifier.align(Alignment.BottomCenter),
                )
            }
        } else {
            // —— 竖屏：顶栏 / 视频 / 信息块 / 底栏 ——
            Column(modifier = Modifier.fillMaxSize()) {
                PlayerTopBar(
                    title = model.title,
                    onBack = onBack,
                    onPip = onPip,
                    onFullscreen = onToggleFullscreen,
                    onSettings = { menuOpen = true },
                    modifier = Modifier.statusBarsPadding(),
                )
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(model.videoAspect),
                ) {
                    video()
                    Box(modifier = Modifier.fillMaxSize().then(gestures))
                    if (!locked) {
                        PlayerSideActions(
                            locked = locked,
                            muted = muted,
                            onToggleLock = {
                                locked = true
                                chromeVisible = false
                            },
                            onToggleMute = { muted = !muted },
                            modifier = Modifier.align(Alignment.Center),
                        )
                    }
                    // 竖屏也把控制条放进画面里，淡出时只剩视频。
                    if (!locked && chromeVisible) {
                        PlayerBottomChrome(
                            model = model,
                            positionMs = positionMs,
                            paused = paused,
                            overlay = true,
                            compact = true,
                            onSeeking = { ratio -> positionMs = (ratio * model.durationMs).toLong() },
                            onSeekStart = { scrubbing = true },
                            onSeekEnd = { scrubbing = false },
                            onRewind = { positionMs = (positionMs - 10_000).coerceAtLeast(0) },
                            onToggle = { paused = !paused },
                            onForward = {
                                positionMs = (positionMs + 10_000).coerceAtMost(model.durationMs)
                            },
                            onNext = { toast = "下一集（等下版接内核）" },
                            onSpeed = { toast = "倍速：等下版接内核" },
                            onAudio = { panel = PlayerPanel.Audio },
                            onSubtitle = { panel = PlayerPanel.Subtitle },
                            modifier = Modifier.align(Alignment.BottomCenter),
                        )
                    }
                }
                PlayerChipsRow(model)
                PlayerPortraitDetails(
                    model = model,
                    onPickEpisode = { panel = PlayerPanel.Episodes },
                )
                Spacer(Modifier.weight(1f))
            }
        }

        // —— 覆盖层 ——
        if (scrubbing) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
                PlayerHintBubble(
                    text = "${formatTime(seekPreviewMs)} / ${formatTime(model.durationMs)}",
                    modifier = Modifier.padding(top = if (landscape) 56.dp else 96.dp),
                )
            }
        }

        if (boosting) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                PlayerHintBubble("2× 快进中")
            }
        }

        if (locked) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .pointerInput(Unit) {
                        detectTapGestures(
                            onTap = { lockHint = true },
                            onLongPress = {
                                locked = false
                                chromeVisible = true
                            },
                        )
                    },
                contentAlignment = Alignment.Center,
            ) {
                if (lockHint) {
                    PlayerHintBubble("已锁定 · 长按解锁")
                }
            }
        }

        toast?.let { text ->
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
                PlayerHintBubble(
                    text = text,
                    modifier = Modifier.padding(bottom = 72.dp),
                )
            }
        }

        // 菜单打开时，点画面任意处先关菜单；压暗一层，明确是模态。
        if (menuOpen) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color(0x40000000))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) { menuOpen = false },
            )
        }

        // 齿轮菜单：锚在右上，不挡画面主体。
        AnimatedVisibility(
            visible = menuOpen,
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(
                    top = if (landscape) 44.dp else 88.dp,
                    end = 8.dp,
                ),
        ) {
            PlayerSettingsMenu(
                model = model,
                onDismiss = { menuOpen = false },
                onToggleEngine = {
                    engine = if (engine.contains("mpv", ignoreCase = true)) "Media3" else "mpv"
                    menuOpen = false
                    toast = "播放内核：$engine（下次起播生效）"
                },
                onInfo = {
                    menuOpen = false
                    panel = PlayerPanel.Info
                },
                onEpisodes = {
                    menuOpen = false
                    panel = PlayerPanel.Episodes
                },
                onRatio = {
                    menuOpen = false
                    toast = "画面比例：适应窗口"
                },
                onSleep = {
                    menuOpen = false
                    toast = "定时关闭：关"
                },
            )
        }

        if (panel != PlayerPanel.None && panel != PlayerPanel.Info) {
            PlayerBottomSheet(
                panel = panel,
                model = model.copy(audios = shownAudios, subtitles = shownSubtitles),
                onDismiss = { panel = PlayerPanel.None },
                onPickAudio = {
                    selectedAudio = it
                    panel = PlayerPanel.None
                    toast = "音轨：${model.audios[it].title}"
                },
                onPickSubtitle = {
                    selectedSubtitle = it
                    panel = PlayerPanel.None
                    toast = "字幕：${model.subtitles[it].title}"
                },
                onPickEpisode = {
                    panel = PlayerPanel.None
                    toast = "第 ${it + 1} 集（等下版接内核）"
                },
            )
        }

        if (panel == PlayerPanel.Info) {
            PlayerInfoPanel(
                model = model.copy(audios = shownAudios, subtitles = shownSubtitles),
                onDismiss = { panel = PlayerPanel.None },
                onPickAudio = { selectedAudio = it },
                onPickSubtitle = { selectedSubtitle = it },
                statusBarInset = !landscape,
            )
        }
    }
}
