package com.dvplayer.app

import android.app.PictureInPictureParams
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.dvplayer.core.MediaDetail
import com.dvplayer.core.MediaHub
import com.dvplayer.core.SourceConfig
import com.dvplayer.core.PlaySource
import com.dvplayer.core.config.SourceStore
import com.dvplayer.design.DvTheme
import com.dvplayer.player.DolbyVisionProbe
import com.dvplayer.player.EngineId
import com.dvplayer.player.EngineRouter
import com.dvplayer.player.PlaybackMemory
import com.dvplayer.player.TrackKind
import com.dvplayer.ui.phone.data.PhoneRepoHolder
import com.dvplayer.ui.phone.player.PlayerDemo
import com.dvplayer.ui.phone.player.PlayerErrorScreen
import com.dvplayer.ui.phone.player.PlayerLoadingScreen
import com.dvplayer.ui.phone.player.PlayerEpisode
import com.dvplayer.ui.phone.player.PlayerPanel
import com.dvplayer.ui.phone.player.PlayerScreen
import com.dvplayer.ui.phone.ui.LocalStillLoader
import com.dvplayer.ui.phone.ui.runtimeLabel
import com.dvplayer.ui.phone.player.PlayerUiModel
import com.dvplayer.ui.phone.player.PlayerUiModelFactory
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 手机播放页。
 *
 * 两种进入方式：
 * - 演示（默认）：用 [PlayerDemo] 的假数据，用来验收布局。
 * - 真实条目：`--es item <sourceId:itemId>`，从 `SourceStore` 读源配置，登录后
 *   取 `detail / playSource / mediaInfo` 再映射成同一个 UI 模型。
 *
 *   adb shell am start -n com.dvplayer.app/.PlaybackActivity \
 *       --es item local-smoke:/path/to/movie.mkv
 *
 *   调试时还可以用 `--es config '<SourceConfig JSON>'` 临时加一个源（不落盘）。
 *
 * 布局验收参数：`--es mode landscape|portrait|info|menu|audio|subtitle|episodes`
 * 和 `--ez no_hide true`（关掉 3 秒自动淡出）。
 */
class PlaybackActivity : ComponentActivity() {

    private companion object {
        const val TAG = "DvPlayback"
    }

    /** 最近一次内核报出的视频宽高比，PiP 窗口按它定形状。 */
    private var videoAspect: Float = 16f / 9f

    /** 用户自己转过屏：之后不再被视频比例自动改回去。 */
    private var manualRotation = false

    /** 当前是不是已经进了 PiP（决定是否隐藏控制层）。Compose 要观察它。 */
    private val inPipState = androidx.compose.runtime.mutableStateOf(false)
    private var inPip: Boolean
        get() = inPipState.value
        set(value) {
            inPipState.value = value
        }

    /** 起播之后才允许按 Home 自动进 PiP，加载页 / 错误页不进。 */
    private var playbackReady = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppContextHolder.set(this)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        // Compose 的播放页根节点是透明的，黑底由窗口提供，SurfaceView 才能透出来。
        window.setBackgroundDrawable(ColorDrawable(Color.BLACK))

        val mode = intent.getStringExtra("mode").orEmpty()
        val landscape = when (mode) {
            "portrait" -> false
            "landscape" -> true
            else -> resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        }

        // 截图 / 验收时给一个确定的方向；正常进入跟随重力。
        requestedOrientation = when (mode) {
            "portrait" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            "landscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }

        applySystemBars(hide = true)

        // 面板可以单独指定，这样横屏（固定 landscape）也能截到面板。
        val panelName = intent.getStringExtra("panel") ?: mode
        val panel = when (panelName) {
            "info" -> PlayerPanel.Info
            "audio" -> PlayerPanel.Audio
            "subtitle" -> PlayerPanel.Subtitle
            "episodes" -> PlayerPanel.Episodes
            else -> PlayerPanel.None
        }
        // 横屏默认展示电影；要看剧集选集就加 `--es demo episode`。
        val demo = intent.getStringExtra("demo")
        val noHide = intent.getBooleanExtra("no_hide", false)
        val menuOpen = mode == "menu" || intent.getBooleanExtra("menu", false)
        val itemId = intent.getStringExtra("item")?.takeIf { it.isNotBlank() }

        setContent {
            DvTheme {
                // 剧照走主界面那个仓库的位图缓存；拿不到就退回占位色块。
                CompositionLocalProvider(
                    LocalStillLoader provides { path -> PhoneRepoHolder.repo?.bitmap(path) },
                ) {
                    if (itemId == null) {
                        PlayerScreen(
                            model = when (demo) {
                                "episode" -> PlayerDemo.episode
                                "film" -> PlayerDemo.film
                                else -> if (landscape) PlayerDemo.film else PlayerDemo.episode
                            },
                            onBack = { finish() },
                            onRotate = ::rotateScreen,
                            initialPanel = panel,
                            initialMenuOpen = menuOpen,
                            autoHide = !noHide,
                        )
                    } else {
                        RealPlayback(
                            itemId = itemId,
                            panel = panel,
                            menuOpen = menuOpen,
                            autoHide = !noHide,
                            onBack = { finish() },
                            onRotate = ::rotateScreen,
                        )
                    }
                }
            }
        }
    }

    /**
     * 返回键 = 退出播放。这里必须显式停播：播放器在 [PlaybackHolder] 上，
     * 只把 Activity 移走的话音频会一直在后台放。
     */
    @Deprecated("ComponentActivity 的 onBackPressed 在 API 33 之后走 OnBackPressedDispatcher")
    override fun onBackPressed() {
        PlaybackHolder.close()
        super.onBackPressed()
    }

    override fun onDestroy() {
        // 注意：这里不 close 播放器——旋转 / 进后台也会走到 onDestroy，
        // 关掉就变成「一切后台就停」。真正退出走关闭按钮或 [onBackPressed]。
        super.onDestroy()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        applySystemBars(hide = true)
    }

    /**
     * 进入画中画。
     *
     * 比例取内核报的视频比例：横屏片是宽窗口，竖屏短剧是窄窗口，
     * 系统给 PiP 的默认形状（近正方形）会把两种都裁掉。
     */
    private fun enterPip() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return
        if (inPip) return
        val aspect = videoAspect.takeIf { it > 0.1f && it < 10f } ?: (16f / 9f)
        // 用 16:9 / 4:3 / 9:16 这类常见比例近似，避免 Rational 化简出 1:1。
        val (num, den) = when {
            aspect >= 1.9f -> 21 to 9      // 2.35:1 这类宽银幕，PiP 窗口有上限
            aspect >= 1.6f -> 16 to 9
            aspect >= 1.4f -> 3 to 2
            aspect >= 1.2f -> 4 to 3
            aspect >= 1.0f -> 1 to 1
            aspect >= 0.7f -> 3 to 4
            else -> 9 to 16                 // 竖屏短剧
        }
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(num, den))
        // setAutoEnterEnabled 是 API 31 才有的（Android 12）。minSdk 26 上直接调
        // 会 NoSuchMethodError，所以必须按版本判断。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // 播放页是主动作，切 PiP 时不用系统弹说明。
            builder.setAutoEnterEnabled(true)
        }
        val params = builder.build()
        val ok = runCatching { enterPictureInPictureMode(params) }.getOrDefault(false)
        android.util.Log.i(TAG, "进入 PiP -> $ok（比例 ${"%.3f".format(aspect)}）")
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPip = isInPictureInPictureMode
        android.util.Log.i(TAG, "PiP 模式：$isInPictureInPictureMode")
        // PiP 里不显示系统栏，退出时按方向恢复。
        if (!isInPictureInPictureMode) {
            applySystemBars(hide = true)
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // 按 Home 自动进 PiP（加载中 / 错误页不进，避免把小窗留成黑屏）。
        if (playbackReady) enterPip()
    }

    private fun rotateScreen() {
        manualRotation = true
        requestedOrientation =
            if (resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) {
                ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            } else {
                ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            }
    }

    private fun applySystemBars(hide: Boolean) {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (hide) {
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
            controller.isAppearanceLightStatusBars = false
        }
    }

    /** 回到前台 / 弹过系统 UI 之后重新进沉浸，横竖屏都一样。 */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) applySystemBars(hide = true)
    }

    // —— 真实条目 ——

    private sealed interface Load {
        data object Loading : Load
        data class Ready(
            val model: PlayerUiModel,
            val play: PlaySource,
            val engine: EngineId,
            val dvProfile: Int?,
        ) : Load

        data class Failed(val message: String) : Load
    }

    @Composable
    private fun RealPlayback(
        itemId: String,
        panel: PlayerPanel,
        menuOpen: Boolean,
        autoHide: Boolean,
        onBack: () -> Unit,
        onRotate: () -> Unit,
    ) {
        // 选集：点了另一集就换 itemId 重新取播放源，不用退出播放页。
        var playingItemId by remember(itemId) { mutableStateOf(itemId) }
        val state by produceState<Load>(Load.Loading, playingItemId) {
            value = withContext(Dispatchers.IO) { load(playingItemId) }
        }

        when (val current = state) {
            Load.Loading -> PlayerLoadingScreen()
            is Load.Failed -> PlayerErrorScreen(current.message, onBack)
            is Load.Ready -> RealPlayerScreen(
                model = current.model,
                play = current.play,
                engineId = current.engine,
                dvProfile = current.dvProfile,
                panel = panel,
                menuOpen = menuOpen,
                autoHide = autoHide,
                onBack = {
                    // 用户主动退出播放：存进度并释放内核（和 Activity 被回收区分开）。
                    PlaybackHolder.close()
                    onBack()
                },
                onRotate = onRotate,
                onPip = ::enterPip,
                onPlayEpisode = { id ->
                    if (id != playingItemId) {
                        // 先停旧会话：新的一集要重新登录取直链，别让上一集继续响。
                        PlaybackHolder.close()
                        playingItemId = id
                    }
                },
            )
        }
    }

    /** 带真内核的播放页：SurfaceView 出画，进度 / 暂停 / 倍速 / 轨道都走内核。 */
    @Composable
    private fun RealPlayerScreen(
        model: PlayerUiModel,
        play: PlaySource,
        engineId: EngineId,
        dvProfile: Int?,
        panel: PlayerPanel,
        menuOpen: Boolean,
        autoHide: Boolean,
        onBack: () -> Unit,
        onRotate: () -> Unit,
        onPip: () -> Unit,
        onPlayEpisode: (String) -> Unit,
    ) {
        val context = LocalContext.current

        // 当前内核：菜单里切换会重建 session（同一个 play / 位置继续）。
        var currentEngine by remember(play.url) { mutableStateOf(engineId) }
        // 切内核重建 session 时，用这个把位置接上。
        var lastKnownPositionMs by remember(play.url) { mutableStateOf(0L) }

        // 续播：读本地记录，内核真正打开文件后再 seek。
        // 不能走 PlaybackController.resume：local 源首播的 durationSeconds 是 0，
        // 会被它当成「时长未知」直接放弃续播。
        val startMs = remember(play.url) {
            PlaybackMemory(context).position(play.url).takeIf { it > 3_000 } ?: 0L
        }
        // 用 State 包一层，让 remember 的 key 只跟内核走，读到的是最新位置。
        val resumePosition by rememberUpdatedState(lastKnownPositionMs)
        // 会话在 PlaybackHolder 上（进程级）：Activity 被回收 / 旋转都不中断播放，
        // 这里只是拿一个引用。
        val session = remember(play.url, currentEngine) {
            // 切内核时从当前位置接着播，不要跳回片头。
            val resumeMs = if (currentEngine == engineId) startMs else resumePosition
            PlaybackHolder.open(context, play, currentEngine, dvProfile, resumeMs)
        }

        // Activity 销毁只断开画面，播放继续（音频不断）。
        DisposableEffect(session) {
            onDispose { PlaybackHolder.detachSurface() }
        }

        // 进后台写回进度；进程被回收也有记录。
        val activity = context as? ComponentActivity
        DisposableEffect(activity) {
            val observer = LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_STOP) session.save()
            }
            activity?.lifecycle?.addObserver(observer)
            onDispose { activity?.lifecycle?.removeObserver(observer) }
        }

        val playback by session.state.collectAsState()
        val reportedAspect by session.videoAspect.collectAsState()
        LaunchedEffect(playback.positionMs) {
            if (playback.positionMs > 0) lastKnownPositionMs = playback.positionMs
        }

        // PiP 的窗口形状用内核报的真实比例；起播拿到时长后才允许按 Home 进 PiP。
        LaunchedEffect(reportedAspect, playback.durationMs) {
            reportedAspect?.let { if (it > 0.1f) videoAspect = it }
            playbackReady = playback.durationMs > 0
        }

        // 按画面比例自动选方向：竖屏短剧保持竖屏，16:9 电影转横屏。
        // 启动参数显式指定了 mode（截图 / 验收）或用户手动转过，就不动。
        LaunchedEffect(reportedAspect) {
            val aspect = reportedAspect ?: return@LaunchedEffect
            if (aspect <= 0.1f) return@LaunchedEffect
            if (intent.getStringExtra("mode").isNullOrEmpty() && !manualRotation) {
                android.util.Log.i(TAG, "按画面比例自动选方向：${"%.3f".format(aspect)}")
                requestedOrientation = if (aspect < 0.95f) {
                    ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                } else {
                    // 用固定 LANDSCAPE：SENSOR_LANDSCAPE 在机器平放 / 方向锁定时不会转。
                    ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                }
            }
        }

        // 播放中保持屏幕常亮；暂停 / 播完就放开，别让用户放着不动也耗电。
        val activityWindow = (context as? ComponentActivity)?.window
        LaunchedEffect(playback.paused, playback.ended) {
            if (activityWindow == null) return@LaunchedEffect
            if (!playback.paused && !playback.ended) {
                activityWindow.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                activityWindow.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
        DisposableEffect(activityWindow) {
            onDispose { activityWindow?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
        }

        val surfaceView = remember(session) {
            SurfaceView(context).apply {
                holder.addCallback(object : SurfaceHolder.Callback {
                    override fun surfaceCreated(holder: SurfaceHolder) {
                        session.attach(holder.surface, width, height)
                        // Media3 走 View 而不是裸 Surface；mpv 会忽略这一句。
                        session.attachView(this@apply)
                    }

                    override fun surfaceChanged(
                        holder: SurfaceHolder,
                        format: Int,
                        w: Int,
                        h: Int,
                    ) {
                        session.attach(holder.surface, w, h)
                    }

                    override fun surfaceDestroyed(holder: SurfaceHolder) {
                        session.detach()
                    }
                })
            }
        }

        PlayerScreen(
            // 内核报出真实画面比例后用它收窄视频区，非 16:9 的片不会被拉伸。
            model = model.copy(videoAspect = reportedAspect ?: model.videoAspect),
            onBack = onBack,
            onRotate = onRotate,
            onPip = onPip,
            onPlayEpisode = onPlayEpisode,
            inPip = inPipState.value,
            initialPanel = panel,
            initialMenuOpen = menuOpen,
            autoHide = autoHide,
            playback = playback,
            onSeek = session::seekTo,
            onTogglePause = session::togglePause,
            onSetSpeed = session::setSpeed,
            onSelectAudio = { session.selectTrack(TrackKind.AUDIO, it) },
            onSelectSubtitle = { session.selectTrack(TrackKind.SUB, it) },
            onSwitchEngine = { name ->
                currentEngine = if (name.contains("Media3", ignoreCase = true)) {
                    EngineId.MEDIA3
                } else {
                    EngineId.MPV
                }
            },
            onSleepTimerFired = onBack,
            // 根节点透明，黑底由窗口提供：SurfaceView 的视频才透得出来。
            background = androidx.compose.ui.graphics.Color.Transparent,
            video = {
                // AndroidView 的 factory 只跑一次：换集 / 换内核后 session 变了，
                // 必须把 View 一起换掉，否则新的 mpv 拿不到 Surface（日志里是
                // 「GL 未就绪，暂存」），画面停在上一集的最后一帧。
                key(session) {
                    AndroidView(
                        factory = { surfaceView },
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            },
        )
    }

    private fun load(itemId: String): Load {
        val hub = MediaHub.open() ?: return Load.Failed("核心不可用：MediaHub.open 返回 null")
        return try {
            hub.use { media ->
                val configs = resolveConfigs()
                if (configs.isEmpty()) {
                    return Load.Failed(
                        "还没有配置源。先用 --es config '<SourceConfig JSON>' 启动，\n" +
                            "或在设置页里添加源。",
                    )
                }

                val connections = media.addMany(configs)
                val okIds = connections.filter { it.ok }.map { it.id }.toSet()
                if (okIds.isEmpty()) {
                    val detail = connections.joinToString("\n") { "${it.name}：${it.error ?: "登录失败"}" }
                    return Load.Failed("所有源都连不上：\n$detail")
                }

                val sourceId = itemId.substringBefore(':', "")
                if (sourceId.isNotEmpty() && sourceId !in okIds) {
                    val failed = connections.firstOrNull { it.id == sourceId }
                    return Load.Failed("源 $sourceId 未连上：${failed?.error ?: "不在配置里"}")
                }

                val play = media.playSource(itemId)
                val detail = runCatching { media.detail(itemId) }.getOrNull()
                val info = runCatching { media.mediaInfo(itemId) }.getOrNull()
                // 剧集播放时 itemId 是某一集，父级（整部剧）由详情页随 intent 带进来；
                // 没有父级就是电影 / 单集视频，选集为空。
                val seriesId = intent.getStringExtra("series")?.takeIf { it.isNotBlank() }
                val episodes = runCatching {
                    loadEpisodes(media, seriesId, detail, itemId)
                }.getOrDefault(emptyList())
                val sources = runCatching { media.sources() }.getOrDefault(emptyList())
                val source = sources.firstOrNull { it.id == sourceId }

                val engineHint = intent.getStringExtra("engine")
                    ?.takeIf { it == "mpv" || it == "Media3" }
                val engineId = when {
                    engineHint == "mpv" -> EngineId.MPV
                    engineHint == "Media3" -> EngineId.MEDIA3
                    // 原盘只有 mpv 认识；其余走路由（HDR10+ → Media3）。
                    play.disc -> EngineId.MPV
                    else -> runCatching {
                        EngineRouter(this@PlaybackActivity).choose(play.url).engine
                    }.getOrDefault(EngineId.MPV)
                }
                // P5 硬解会丢 RPU：本地文件探一次 profile 交给内核切软解。
                val dvProfile = if (play.url.contains("://")) {
                    null
                } else {
                    runCatching { DolbyVisionProbe.probe(play.url)?.profile }.getOrNull()
                }

                Load.Ready(
                    model = PlayerUiModelFactory.from(
                        detail = detail,
                        play = play,
                        info = info,
                        sourceName = source?.name ?: sourceId.ifEmpty { "未知源" },
                        sourceKind = source?.kind ?: detail?.kind ?: "",
                        subtitle = subtitleOf(detail),
                        engine = if (engineId == EngineId.MPV) "mpv" else "Media3",
                        episodes = episodes,
                        hasNext = episodes.indexOfFirst { it.current }
                            .let { it in 0 until episodes.size - 1 },
                    ),
                    play = play,
                    engine = engineId,
                    dvProfile = dvProfile,
                )
            }
        } catch (err: Exception) {
            Load.Failed("${err.javaClass.simpleName}：${err.message ?: "未知错误"}")
        }
    }

    /**
     * 选集：剧集先拿季、再拿这一季的集；电影返回空表。
     * 和详情页走同一条路（DetailScreen 里的加载逻辑）。
     */
    private fun loadEpisodes(
        media: MediaHub,
        seriesId: String?,
        detail: MediaDetail?,
        itemId: String,
    ): List<PlayerEpisode> {
        val first = seriesId
            ?: detail?.singleChildId
            ?: detail?.id
            ?: return emptyList()
        // 剧名用来判断「分集名」是不是只是把剧名重复了一遍（飞牛这些源就是这么给的）。
        val seriesTitle = runCatching { media.detail(first).title }.getOrNull()
            ?: detail?.title
        val kids = media.children(first, pageSize = 200).items
        val list = if (kids.any { it.kind == "season" }) {
            media.children(kids.first().id, pageSize = 500).items
        } else {
            kids
        }
        return list
            .filter { it.kind == "episode" || it.isPlayable }
            .sortedBy { it.episodeNumber ?: Int.MAX_VALUE }
            .mapIndexed { index, ep ->
                PlayerEpisode(
                    id = ep.id,
                    title = "第 ${ep.episodeNumber ?: index + 1} 集",
                    duration = runtimeLabel(ep.runtimeSeconds).orEmpty(),
                    current = ep.id == itemId,
                    stillPath = ep.backdropPath ?: ep.posterPath,
                    // 去掉重复的剧名前缀；剩不下东西就不显示（卡片上退化成时长）。
                    subtitle = ep.title.trim()
                        .removePrefix(seriesTitle.orEmpty())
                        .trim(' ', '-', '：', ':', '·')
                        .takeIf { it.isNotBlank() },
                )
            }
    }

    /** `SourceStore` + 命令行临时源；同 id 时命令行优先。 */
    private fun resolveConfigs(): List<SourceConfig> {
        val stored = SourceStore(this).load()
        val extra = intent.getStringExtra("config")?.let { SourceStore.parse(it) }
        val merged = buildList {
            addAll(stored)
            extra?.let { injected ->
                removeAll { it.id == injected.id }
                add(injected)
            }
        }
        return merged.map {
            if (it.dataDir.isBlank()) it.copy(dataDir = filesDir.absolutePath) else it
        }
    }

    private fun subtitleOf(detail: com.dvplayer.core.MediaDetail?): String? {
        val season = detail?.seasonCount?.takeIf { it > 1 }?.let { "共 $it 季" }
        val year = detail?.releaseDate?.take(4)?.takeIf { it.length == 4 }
        return listOfNotNull(season, year).joinToString(" · ").ifBlank { null }
    }
}
