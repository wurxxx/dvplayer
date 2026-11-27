package com.dvplayer.ui.phone.player

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import android.app.Activity
import android.content.Context
import android.media.AudioManager
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * 手机播放页。
 *
 * 布局约定（UI-DESIGN §5）：
 * - 横竖屏同一套：整屏播放器，视频按自身比例居中（竖屏短剧不裁边）。
 * - 顶栏 / 底栏 / 两侧按钮全部悬浮，贴屏幕边；竖屏再把系统栏 inset 让出来。
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
    /** 底栏右下角的横竖屏切换。 */
    onRotate: () -> Unit = {},
    initialPanel: PlayerPanel = PlayerPanel.None,
    initialMenuOpen: Boolean = false,
    /** 截图 / 演示时关掉 3 秒自动淡出。 */
    autoHide: Boolean = true,
    /**
     * 真内核的播放状态。为 null 时用 [model] 的静态值（预览 / 截图），
     * 传入后位置、时长、暂停、倍速、音轨都以它为准。
     */
    playback: PlayerPlaybackState? = null,
    onSeek: (Long) -> Unit = {},
    onTogglePause: () -> Unit = {},
    onSetSpeed: (Float) -> Unit = {},
    onSelectAudio: (String) -> Unit = {},
    onSelectSubtitle: (String) -> Unit = {},
    /** 选集面板里点了某一集：带上这一集的条目 id 去换片。 */
    onPlayEpisode: ((String) -> Unit)? = null,
    /** 换内核（重建 session）。为 null 表示只改本地状态（Demo）。 */
    onSwitchEngine: ((String) -> Unit)? = null,
    /** 定时关闭到点：暂停并退出播放页。 */
    onSleepTimerFired: () -> Unit = {},
    /**
     * 画中画里：控制层全部隐藏，只留画面（PiP 小窗点不到这些按钮，
     * 露出来只会挡住画面）。
     */
    inPip: Boolean = false,
    /** 底色。接 SurfaceView 时传 Transparent，让下层视频 surface 透出来。 */
    background: Color = Color.Black,
    video: @Composable () -> Unit = { PlayerVideoPlaceholder("") },
) {
    val configuration = LocalConfiguration.current
    val landscape = configuration.screenWidthDp > configuration.screenHeightDp

    var locked by remember { mutableStateOf(false) }
    var chromeVisible by remember { mutableStateOf(true) }
    var panel by remember { mutableStateOf(initialPanel) }
    var menuOpen by remember { mutableStateOf(initialMenuOpen) }
    var scrubbing by remember { mutableStateOf(false) }
    var seekPreviewMs by remember(model) { mutableStateOf(model.positionMs) }
    var boosting by remember { mutableStateOf(false) }
    // 长按 2× 前的速度，松手恢复。
    var speedBeforeBoost by remember { mutableStateOf(1f) }
    var lockHint by remember { mutableStateOf(false) }
    var toast by remember { mutableStateOf<String?>(null) }
    var levelOsd by remember { mutableStateOf<String?>(null) }
    // 连续手势里 levelOsd 的值常常不变（音量卡在同一档），只靠字符串变化
    // 重启计时会让气泡在手势中途提前消失；用计数器单独触发。
    var levelOsdTick by remember { mutableIntStateOf(0) }
    // 画面比例：适应 / 填充 / 拉伸 / 16:9 / 4:3。
    var aspectMode by remember { mutableStateOf(PlayerAspect.Fit) }
    // 定时关闭：分钟数，0 = 关。
    var sleepMinutes by remember { mutableIntStateOf(0) }
    var sleepLeftSeconds by remember { mutableIntStateOf(0) }

    // Demo 模式下自己模拟状态；接了内核就全部用 playback 的值。
    var demoPaused by remember(model) { mutableStateOf(model.paused) }
    var demoPosition by remember(model) { mutableStateOf(model.positionMs) }
    var pendingSeekMs by remember { mutableStateOf<Long?>(null) }

    val durationMs = playback?.durationMs?.takeIf { it > 0 } ?: model.durationMs
    // keep-open 播完停在最后一帧时，内核的 pause 仍是 false；界面上要当暂停，
    // 否则按钮显示「暂停」，点了却什么都没发生。
    val ended = playback?.ended == true
    val paused = ended || (playback?.paused ?: demoPaused)
    val shownPosition = when {
        scrubbing -> seekPreviewMs
        else -> pendingSeekMs ?: playback?.positionMs ?: demoPosition
    }

    fun commitSeek(target: Long) {
        val ms = target.coerceIn(0, durationMs.coerceAtLeast(0))
        if (playback != null) {
            pendingSeekMs = ms
            onSeek(ms)
        } else {
            demoPosition = ms
        }
    }

    fun switchPause() {
        // 播完后第一次点播放 = 从头重播。
        if (ended) {
            commitSeek(0)
            if (playback?.paused == true) onTogglePause()
        } else if (playback != null) {
            onTogglePause()
        } else {
            demoPaused = !demoPaused
        }
    }

    // 左侧上下滑调亮度（窗口级，不改系统设置）；右侧上下滑调媒体音量。
    val context = LocalContext.current
    val activity = remember(context) { context as? Activity }
    val audio = remember(context) {
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }
    val maxVolume = remember(audio) { audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC) }
    var brightness by remember {
        mutableFloatStateOf(
            runCatching {
                val system = Settings.System.getInt(
                    context.contentResolver,
                    Settings.System.SCREEN_BRIGHTNESS,
                    -1,
                )
                if (system in 1..255) system / 255f else 0.5f
            }.getOrDefault(0.5f),
        )
    }
    var volume by remember { mutableIntStateOf(audio.getStreamVolume(AudioManager.STREAM_MUSIC)) }

    fun applyBrightness(value: Float) {
        activity?.window?.let { window ->
            val params = window.attributes
            params.screenBrightness = value
            window.attributes = params
        }
    }

    fun applyVolume(value: Int) {
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, value, 0)
    }
    // 内核名：接了内核就以内核报的为准（切内核后 session 重建会更新），
    // 否则用规格行里的值（预览 / 截图）。
    val engine = playback?.engine
        ?: model.chips.firstOrNull { it.accent }?.text
        ?: "mpv"

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

    // 定时关闭倒计时：到 0 暂停并退出。播放中才走，暂停时不计时。
    LaunchedEffect(sleepMinutes, paused) {
        if (sleepMinutes <= 0) return@LaunchedEffect
        if (paused) return@LaunchedEffect
        while (sleepLeftSeconds > 0 && !paused) {
            delay(1_000)
            sleepLeftSeconds--
        }
        if (sleepLeftSeconds <= 0 && sleepMinutes > 0) {
            sleepMinutes = 0
            if (playback != null) onTogglePause()
            onSleepTimerFired()
        }
    }

    LaunchedEffect(levelOsdTick) {
        if (levelOsdTick > 0) {
            delay(1200)
            levelOsd = null
        }
    }

    LaunchedEffect(lockHint) {
        if (lockHint) {
            delay(1800)
            lockHint = false
        }
    }

    // seek 后内核的位置事件约 200ms 到；等它追上来再松开预览，避免进度回跳。
    LaunchedEffect(pendingSeekMs, playback?.positionMs) {
        val target = pendingSeekMs ?: return@LaunchedEffect
        val actual = playback?.positionMs
        if (actual != null && abs(actual - target) < 1_500) {
            pendingSeekMs = null
        } else {
            delay(1_200)
            pendingSeekMs = null
        }
    }

    LaunchedEffect(panel, menuOpen) {
        if (panel != PlayerPanel.None || menuOpen) {
            chromeVisible = true
        }
    }

    // 接了内核就用内核的真实轨道（含 id 与选中态）；Demo 才用本地下标。
    val audioTracks = playback?.audios?.takeIf { it.isNotEmpty() } ?: model.audios
    val subtitleTracks = playback?.subtitles?.takeIf { it.isNotEmpty() } ?: model.subtitles
    val shownAudios = if (playback != null && playback.audios.isNotEmpty()) {
        audioTracks
    } else {
        audioTracks.mapIndexed { index, track -> track.copy(selected = index == selectedAudio) }
    }
    val shownSubtitles = if (playback != null && playback.subtitles.isNotEmpty()) {
        subtitleTracks
    } else {
        subtitleTracks.mapIndexed { index, track -> track.copy(selected = index == selectedSubtitle) }
    }

    // 规格行：第一个 chip 是「内核 · HW/SW」，第二个是视频编码，后面接源给的
    // 动态范围 / 分辨率 / 帧率 / 码率。没接内核时就用模型里现成的。
    val liveChips = if (playback == null) {
        model.chips
    } else {
        buildList {
            val engineName = playback.engine ?: model.chips.firstOrNull()?.text
            val decode = when (playback.hardwareDecode) {
                true -> "HW"
                false -> "SW"
                null -> null
            }
            add(
                PlayerChip(
                    text = listOfNotNull(engineName?.takeIf { it.isNotBlank() }, decode)
                        .joinToString("·")
                        .ifBlank { "mpv" },
                    accent = true,
                ),
            )
            playback.videoCodec?.let { shortCodecName(it) }?.let { add(PlayerChip(it)) }
            addAll(model.chips.drop(1))
        }
    }

    // 时长 / 倍速 / 缓冲用内核的值。
    val shownModel = model.copy(
        durationMs = durationMs,
        bufferedMs = playback?.bufferedMs ?: model.bufferedMs,
        speed = playback?.speed ?: model.speed,
        chips = liveChips,
    )

    /** 画面手势：点击唤出 / 收起、双击暂停、长按 2×、左右滑 seek。 */
    val gestures = Modifier
        .pointerInput(locked) {
            if (!locked) {
                detectTapGestures(
                    onTap = { chromeVisible = !chromeVisible },
                    onDoubleTap = {
                        switchPause()
                        chromeVisible = true
                    },
                    onLongPress = {
                        if (!boosting) {
                            speedBeforeBoost = playback?.speed ?: model.speed
                            boosting = true
                            // 真内核：长按期间 2×，松手恢复。
                            if (playback != null) onSetSpeed(2f)
                        }
                    },
                    onPress = {
                        tryAwaitRelease()
                        if (boosting) {
                            boosting = false
                            if (playback != null) onSetSpeed(speedBeforeBoost)
                        }
                    },
                )
            }
        }
        .pointerInput(locked, durationMs) {
            if (locked) return@pointerInput
            // 0 = 未定方向，1 = seek，2 = 亮度，3 = 音量
            var mode = 0
            var startX = 0f
            var totalX = 0f
            var totalY = 0f
            var basePosition = 0L
            var baseBrightness = brightness
            var baseVolume = volume

            detectDragGestures(
                onDragStart = { offset ->
                    startX = offset.x
                    totalX = 0f
                    totalY = 0f
                    mode = 0
                    basePosition = shownPosition
                    baseBrightness = brightness
                    baseVolume = volume
                },
                onDrag = { _, amount ->
                    totalX += amount.x
                    totalY += amount.y
                    if (mode == 0) {
                        if (abs(totalX) > abs(totalY)) {
                            if (abs(totalX) > 8f) {
                                mode = 1
                                scrubbing = true
                                chromeVisible = true
                            }
                        } else if (abs(totalY) > 8f) {
                            mode = if (startX < size.width / 2f) 2 else 3
                        }
                    }
                    when (mode) {
                        1 -> {
                            val next = basePosition +
                                (totalX / size.width * durationMs).toLong()
                            seekPreviewMs = next.coerceIn(0, durationMs)
                        }
                        2 -> {
                            brightness = (baseBrightness - totalY / size.height * 1.1f)
                                .coerceIn(0.02f, 1f)
                            applyBrightness(brightness)
                            levelOsd = "亮度 ${(brightness * 100).roundToInt()}%"
                            levelOsdTick++
                        }
                        3 -> {
                            val next = (baseVolume - totalY / size.height * maxVolume * 1.6f)
                                .roundToInt()
                                .coerceIn(0, maxVolume)
                            if (next != volume) {
                                volume = next
                                applyVolume(next)
                            }
                            levelOsd = "音量 ${(next * 100 / maxVolume.coerceAtLeast(1))}%"
                            levelOsdTick++
                        }
                    }
                },
                onDragEnd = {
                    if (mode == 1) {
                        commitSeek(seekPreviewMs)
                        scrubbing = false
                    }
                    mode = 0
                },
                onDragCancel = {
                    if (mode == 1) {
                        commitSeek(seekPreviewMs)
                        scrubbing = false
                    }
                    mode = 0
                },
            )
        }

    BoxWithConstraints(modifier = Modifier.fillMaxSize().background(background)) {
        // 视频区的目标比例：强制比例优先，否则用视频自身比例。
        val targetAspect = aspectMode.forcedAspect ?: model.videoAspect
        val containerAspect = maxWidth / maxHeight
        val videoWidth: Dp
        val videoHeight: Dp
        when (aspectMode) {
            // 填充 / 拉伸：视频区就是整屏，超出部分由 Surface 自己裁或拉伸。
            PlayerAspect.Fill, PlayerAspect.Stretch -> {
                videoWidth = maxWidth
                videoHeight = maxHeight
            }

            else -> {
                if (targetAspect > containerAspect) {
                    videoWidth = maxWidth
                    videoHeight = maxWidth / targetAspect
                } else {
                    videoHeight = maxHeight
                    videoWidth = maxHeight * targetAspect
                }
            }
        }
        // 填充模式裁掉溢出部分；拉伸模式让内容变形铺满。
        val videoModifier = when (aspectMode) {
            PlayerAspect.Fill -> Modifier.fillMaxSize().clipToBounds()
            PlayerAspect.Stretch -> Modifier.fillMaxSize()
            else -> Modifier.fillMaxSize()
        }
        Box(
            modifier = Modifier
                .align(Alignment.Center)
                .size(videoWidth, videoHeight)
                .then(videoModifier),
        ) {
            video()
        }
        // 手势盖满整屏：画面外的黑边也能点出控制层、滑动调亮度音量。
        Box(modifier = Modifier.fillMaxSize().then(gestures))

        if (!locked && chromeVisible && !inPip) {
            PlayerTopBar(
                title = model.title,
                onBack = onBack,
                onPip = onPip,
                onFullscreen = onToggleFullscreen,
                onSettings = { menuOpen = true },
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding(),
            )
            PlayerSideActions(
                locked = locked,
                onToggleLock = {
                    locked = true
                    chromeVisible = false
                },
                onRotate = onRotate,
                modifier = Modifier.align(Alignment.Center),
            )
            PlayerBottomChrome(
                model = shownModel,
                positionMs = shownPosition,
                paused = paused,
                overlay = true,
                // 竖屏只留进度 + 按钮：片名在顶栏，规格收在媒体信息里。
                compact = !landscape,
                onSeeking = { ratio -> seekPreviewMs = (ratio * durationMs).toLong() },
                onSeekStart = {
                    seekPreviewMs = shownPosition
                    scrubbing = true
                },
                onSeekEnd = {
                    commitSeek(seekPreviewMs)
                    scrubbing = false
                },
                onRewind = { commitSeek(shownPosition - 10_000) },
                onToggle = {
                    switchPause()
                    chromeVisible = true
                },
                onForward = { commitSeek(shownPosition + 10_000) },
                onEpisodes = { panel = PlayerPanel.Episodes },
                onSpeed = {
                    val current = playback?.speed ?: model.speed
                    val next = when (current) {
                        1f -> 1.25f
                        1.25f -> 1.5f
                        1.5f -> 2f
                        2f -> 0.5f
                        else -> 1f
                    }
                    if (playback != null) onSetSpeed(next) else toast = "倍速：${next}×"
                },
                onAudio = { panel = PlayerPanel.Audio },
                onSubtitle = { panel = PlayerPanel.Subtitle },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding(),
            )
        }

        // —— 覆盖层 ——
        if (scrubbing && !inPip) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
                PlayerHintBubble(
                    text = "${formatTime(seekPreviewMs)} / ${formatTime(durationMs)}",
                    modifier = Modifier
                        .statusBarsPadding()
                        .padding(top = 48.dp),
                )
            }
        }

        levelOsd?.let { text ->
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                PlayerHintBubble(text)
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
                    val next = if (engine.contains("mpv", ignoreCase = true)) "Media3" else "mpv"
                    menuOpen = false
                    if (onSwitchEngine != null) {
                        onSwitchEngine(next)
                        toast = "正在切到 $next…"
                    } else {
                        toast = "播放内核：$next（预览模式）"
                    }
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
                    aspectMode = aspectMode.next()
                    menuOpen = false
                    toast = "画面比例：${aspectMode.label}"
                },
                ratioLabel = aspectMode.label,
                sleepLeftSeconds = sleepLeftSeconds,
                onSleep = {
                    // 关 → 15 → 30 → 60 → 90 → 关
                    sleepMinutes = when (sleepMinutes) {
                        0 -> 15
                        15 -> 30
                        30 -> 60
                        60 -> 90
                        else -> 0
                    }
                    sleepLeftSeconds = sleepMinutes * 60
                    menuOpen = false
                    toast = if (sleepMinutes == 0) "定时关闭：关" else "定时关闭：$sleepMinutes 分钟"
                },
            )
        }

        if (panel != PlayerPanel.None && panel != PlayerPanel.Info) {
            PlayerBottomSheet(
                panel = panel,
                model = shownModel.copy(audios = shownAudios, subtitles = shownSubtitles),
                wide = landscape,
                onDismiss = { panel = PlayerPanel.None },
                onPickAudio = {
                    val track = shownAudios.getOrNull(it)
                    if (track != null) {
                        if (playback != null && track.id.isNotEmpty()) {
                            onSelectAudio(track.id)
                        } else {
                            selectedAudio = it
                        }
                        toast = "音轨：${track.title}"
                    }
                    panel = PlayerPanel.None
                },
                onPickSubtitle = {
                    val track = shownSubtitles.getOrNull(it)
                    if (track != null) {
                        if (playback != null && track.id.isNotEmpty()) {
                            onSelectSubtitle(track.id)
                        } else {
                            selectedSubtitle = it
                        }
                        toast = "字幕：${track.title}"
                    }
                    panel = PlayerPanel.None
                },
                onPickEpisode = { index ->
                    panel = PlayerPanel.None
                    val episodeId = shownModel.episodes.getOrNull(index)?.id
                    if (episodeId != null && onPlayEpisode != null) {
                        onPlayEpisode.invoke(episodeId)
                    } else {
                        toast = "第 ${index + 1} 集（等下版接内核）"
                    }
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
