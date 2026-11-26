package com.dvplayer.app

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.SubtitleView
import com.dvplayer.player.EngineId
import com.dvplayer.player.EngineRouter
import com.dvplayer.player.FrameRateMatcher
import com.dvplayer.player.MediaSessionController
import com.dvplayer.player.PlaybackForegroundService
import com.dvplayer.player.PlaybackMemory
import com.dvplayer.player.PlayerEngine
import com.dvplayer.player.TrackKind
import com.dvplayer.player.Hdr10PlusProbe
import com.dvplayer.player.media3.Media3Player
import com.dvplayer.player.mpv.MpvPlayer
import kotlin.math.abs
import kotlin.math.round

/**
 * A4 / A5 / A6 的验证页：SurfaceView → 播放内核。
 *
 * 用 adb 直接起：
 *   adb shell am start -n com.dvplayer.app/.PlayerTestActivity \
 *       --es url /data/user/0/com.dvplayer.app/files/dv-test.mp4 \
 *       --es engine mpv|media3|codec
 *
 * `mpv`（默认）走 mpv render API，`media3` 走 ExoPlayer，`codec` 是直连
 * MediaCodec 的 HDR10+ 探针（看 output format 里有没有 `hdr10-plus-info`）。
 */
@OptIn(UnstableApi::class)
class PlayerTestActivity : Activity(), SurfaceHolder.Callback {

    private var player: MpvPlayer? = null
    private var media3: Media3Player? = null
    private lateinit var surfaceView: SurfaceView
    private lateinit var status: TextView
    private var subtitleView: SubtitleView? = null
    private lateinit var controlsBox: LinearLayout
    private var started = false
    private var matchedFps = 0.0
    private var probeResult: String? = null
    private var speedIndex = 0
    private var tickCount = 0
    private var resumeApplied = false
    private var askedNotification = false
    /** 进入本页前的显示模式，退出时恢复（帧率匹配不能把系统一直锁在 120Hz）。 */
    private var originalModeId = 0
    private var originalRefreshRate = 0f
    private var session: MediaSessionController? = null
    private lateinit var memory: PlaybackMemory
    private val handler = Handler(Looper.getMainLooper())

    private val enginePlayer: PlayerEngine?
        get() = player ?: media3

    private val url: String
        get() = intent.getStringExtra("url") ?: DEFAULT_URL

    /** 外部字幕路径：`--es sub /path/to.ass`，默认是内置测试 srt。 */
    private val subtitleUrl: String
        get() = intent.getStringExtra("sub") ?: SUBTITLE_URL

    /** 实际使用的内核。手动 `--es engine` 优先；`--es auto 1` 时由 EngineRouter 决定。 */
    private var engine: String = "mpv"

    /** 自动路由的结论，显示在状态行上便于核对。 */
    private var routeReason: String? = null

    private val refresh = object : Runnable {
        override fun run() {
            status.text = when (engine) {
                "media3" -> {
                    maybeMatchFrameRate(media3?.videoFormat?.frameRate?.toDouble())
                    media3Status()
                }
                "codec" -> probeResult ?: "解码中…"
                else -> {
                    maybeMatchFrameRate()
                    statusLine()
                }
            }
            enginePlayer?.let { player ->
                session?.update(MediaSessionController.snapshot(player.state()))
            }
            maybeResume()
            if (++tickCount % 3 == 0) maybeSave()
            handler.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        memory = PlaybackMemory(this)
        runCatching {
            val mode = currentDisplay.mode
            originalModeId = mode.modeId
            originalRefreshRate = mode.refreshRate
        }
        engine = resolveEngine()
        when (engine) {
            "media3" -> {
                media3 = Media3Player(this)
            }
            "codec" -> Unit  // 只做 MediaCodec 探针
            else -> {
                val mpv = MpvPlayer()
                if (!mpv.isValid) {
                    finish()
                    return
                }
                player = mpv
                // 调试用：--es hwdec no 可以走软解，验证 HDR10+ 动态元数据（硬解 copy 拿不到 SEI）。
                intent.getStringExtra("hwdec")?.let {
                    Log.i(TAG, "hwdec -> $it ${mpv.setProperty("hwdec", it) ?: "ok"}")
                }
                // A5 的 SDR 回退：--es force_sdr 1 让 mpv 做 tone mapping，surface 固定 sRGB。
                if (intent.getStringExtra("force_sdr") == "1") {
                    mpv.setHdrPassthrough(false)
                    routeReason = "SDR tone mapping（force_sdr）"
                    Log.i(TAG, "force_sdr -> mpv tone mapping")
                }
                Log.i(TAG, "mpv version: ${mpv.getProperty("mpv-version")}")
            }
        }

        surfaceView = SurfaceView(this)
        surfaceView.holder.addCallback(this)

        status = TextView(this).apply {
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 11f
            setBackgroundColor(0x99000000.toInt())
            setPadding(24, 24, 24, 24)
        }

        val root = FrameLayout(this)
        root.addView(
            surfaceView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        // PGS 是位图字幕，必须由 SubtitleView 渲染；mpv 侧由 libass 画在画面里。
        if (engine == "media3") {
            subtitleView = SubtitleView(this).apply {
                setApplyEmbeddedStyles(true)
                setApplyEmbeddedFontSizes(true)
            }
            root.addView(
                subtitleView,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                ),
            )
        }
        root.addView(status, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.START))
        if (engine != "codec") {
            controlsBox = controls()
            root.addView(controlsBox, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.END))
        }
        setContentView(root)

        // Android 15+ 强制 edge-to-edge，状态栏会压在画面上，这里把文字让开。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            root.setOnApplyWindowInsetsListener { _, insets ->
                val top = insets.getInsets(WindowInsets.Type.systemBars()).top
                status.setPadding(24, 24 + top, 24, 24)
                if (engine != "codec") controlsBox.setPadding(16, 16 + top, 16, 16)
                insets
            }
        }

        enginePlayer?.let {
            val controller = MediaSessionController(this, it, url.substringAfterLast('/'))
            session = controller
            runCatching {
                PlaybackForegroundService.start(this, controller.notification())
            }.onFailure { e -> Log.w(TAG, "前台服务启动失败", e) }
            Log.i(TAG, "媒体会话就绪")
        }

        Log.i(TAG, "engine=$engine url=$url")
    }

    /**
     * 决定这次用哪个内核。`--es engine` 明确指定时照办；`--es auto 1` 交给
     * [EngineRouter]（要解十几帧 SEI，放后台线程，4 秒超时回退 mpv）。
     */
    private fun resolveEngine(): String {
        intent.getStringExtra("engine")?.let {
            Log.i(TAG, "engine 由参数指定：$it")
            return it
        }
        if (intent.getStringExtra("auto") != "1") return "mpv"

        var decision: EngineRouter.Decision? = null
        val thread = Thread {
            decision = EngineRouter(this).choose(url)
        }
        thread.start()
        thread.join(4_000)
        val d = decision ?: EngineRouter.Decision(EngineId.MPV, "路由超时，回退 mpv")
        routeReason = d.reason
        Log.i(TAG, "路由 -> ${d.engine}：${d.reason}")
        return if (d.engine == EngineId.MEDIA3) "media3" else "mpv"
    }

    override fun onResume() {
        super.onResume()
        if (!askedNotification && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            askedNotification = true
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 100)
        }
        // 切换内核（startActivity + finish）时，新实例可能在旧实例退场期间
        // 收到一次 onPause；如果在这里 removeCallbacks，状态刷新就永久停了。
        // 验证页的轮询成本很低，暂停也不停，只在 onDestroy 里收。
        handler.removeCallbacks(refresh)
        handler.post(refresh)
    }

    override fun onPause() {
        maybeSave()
        super.onPause()
    }

    override fun onStop() {
        // 窗口还在的时候才能改显示模式；onDestroy 里改已经晚了。
        restoreDisplayMode()
        super.onStop()
    }

    /** A10：PiP。验证页只做最小参数，正式播放页按片源宽高比给 aspectRatio。 */
    private fun enterPip() {
        if (intent.getStringExtra("no_pip") == "1") return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return
        val params = PictureInPictureParams.Builder().build()
        if (!enterPictureInPictureMode(params)) {
            Log.w(TAG, "进入 PiP 失败")
        } else {
            Log.i(TAG, "进入 PiP")
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        status.visibility = if (isInPictureInPictureMode) View.GONE else View.VISIBLE
        if (engine != "codec") {
            controlsBox.visibility = if (isInPictureInPictureMode) View.GONE else View.VISIBLE
        }
        Log.i(TAG, "PiP 模式：$isInPictureInPictureMode")
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // 按 Home 时自动进 PiP，和正式播放页的行为一致。
        if (started) enterPip()
    }

    override fun surfaceCreated(holder: SurfaceHolder) = attach(holder)

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) =
        attach(holder)

    private fun attach(holder: SurfaceHolder) {
        when (engine) {
            "media3" -> {
                media3?.attachView(surfaceView)
                media3?.onCues = { cues -> subtitleView?.setCues(cues.cues) }
                if (!started) {
                    started = true
                    media3?.load(url)
                    if (intent.getStringExtra("sub") != null) media3?.addSubtitle(subtitleUrl)
                }
            }
            "codec" -> {
                if (!started) {
                    started = true
                    runProbe(holder.surface)
                }
            }
            else -> {
                val mpv = player ?: return
                val frame = holder.surfaceFrame
                mpv.attach(holder.surface, frame.width(), frame.height())
                if (!started) {
                    started = true
                    // Surface 的 GL 初始化在渲染线程里异步做；mpv 会自己排队。
                    mpv.load(url)
                    handler.postDelayed({ Log.i(TAG, "章节：${mpv.chapters()}") }, 3000)
                }
            }
        }
    }

    /** 验证用的控制条：暂停 / seek / 倍速 / 切轨 / 外部字幕。 */
    private fun controls(): LinearLayout {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(16, 16, 16, 16)
        }
        fun add(label: String, action: () -> Unit) {
            box.addView(
                Button(this).apply {
                    text = label
                    textSize = 12f
                    minWidth = 0
                    minimumWidth = 0
                    setOnClickListener { action() }
                },
                LinearLayout.LayoutParams(-2, -2).apply { bottomMargin = 6 },
            )
        }
        add("⏯ 播放/暂停") {
            val player = enginePlayer ?: return@add
            Log.i(TAG, "togglePause，之前 pause=${player.state().paused}")
            player.togglePause()
        }
        add("-10s") { seekBy(-10_000) }
        add("+10s") { seekBy(10_000) }
        add("倍速") { cycleSpeed() }
        add("音轨") { cycleTrack(TrackKind.AUDIO) }
        add("字幕") { cycleTrack(TrackKind.SUB) }
        add("载入字幕") { enginePlayer?.addSubtitle(subtitleUrl) }
        add("下一章") { nextChapter() }
        if (engine == "mpv" || engine == "media3") add("切内核") { switchEngine() }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
        ) {
            add("PiP") { enterPip() }
        }
        return box
    }

    /** 首次拿到片长后恢复位置：切内核用显式参数，正常进入用续播记录。 */
    private fun maybeResume() {
        if (resumeApplied) return
        val player = enginePlayer ?: return
        val state = player.state()
        if (state.durationMs <= 0) return
        resumeApplied = true

        val explicit = intent.getLongExtra("seek_to", -1L)
        if (explicit >= 0) {
            player.seekTo(explicit)
            intent.getFloatExtra("speed", 0f).takeIf { it > 0f }?.let { player.setSpeed(it) }
            if (intent.getBooleanExtra("paused", false)) player.pause() else player.play()
            Log.i(TAG, "切换后恢复：${explicit}ms speed=${player.state().speed} paused=${player.state().paused}")
            return
        }

        val saved = memory.position(url)
        if (saved > 3_000 && saved < state.durationMs - 5_000) {
            player.seekTo(saved)
            Log.i(TAG, "续播：$saved ms")
        }
    }

    /**
     * A7「切换不丢位置」：记下当前位置/倍速/暂停态，换一个内核重新起同一个片源。
     * 用 startActivity + finish 而不是手动拆装，验证页的 Surface / 字幕视图
     * 都按目标内核重建，不会残留上一个内核的状态。
     */
    private fun switchEngine() {
        val from = enginePlayer ?: return
        val state = from.state()
        val target = if (engine == "media3") "mpv" else "media3"
        maybeSave()
        // 不要复制原 intent：am start 带进来的 FLAG_ACTIVITY_NEW_TASK 会让新
        // activity 走独立任务，紧接着 finish() 会把整个任务收掉。重建一份干净的。
        val next = Intent(this, PlayerTestActivity::class.java).apply {
            putExtra("url", url)
            putExtra("engine", target)
            intent.getStringExtra("sub")?.let { putExtra("sub", it) }
            intent.getStringExtra("hwdec")?.let { putExtra("hwdec", it) }
            intent.getStringExtra("force_sdr")?.let { putExtra("force_sdr", it) }
            putExtra("seek_to", state.positionMs)
            putExtra("speed", state.speed)
            putExtra("paused", state.paused)
        }
        Log.i(TAG, "切换内核 $engine -> $target @ ${state.positionMs}ms")
        startActivity(next)
        finish()
    }

    private fun maybeSave() {
        val player = enginePlayer ?: return
        val state = player.state()
        if (state.durationMs > 0) memory.save(url, state.positionMs, state.durationMs)
    }

    private fun nextChapter() {
        val player = enginePlayer ?: return
        val chapters = player.chapters()
        if (chapters.isEmpty()) {
            Log.i(TAG, "没有章节信息")
            return
        }
        val position = player.state().positionMs
        val next = chapters.firstOrNull { it.startMs > position + 500 } ?: chapters.first()
        player.seekTo(next.startMs)
        Log.i(TAG, "章节 -> ${next.title}（${next.startMs}ms）")
    }

    private fun seekBy(deltaMs: Long) {
        val player = enginePlayer ?: return
        val target = (player.state().positionMs + deltaMs).coerceAtLeast(0)
        player.seekTo(target)
        Log.i(TAG, "seek -> $target ms")
    }

    private fun cycleSpeed() {
        speedIndex = (speedIndex + 1) % SPEEDS.size
        val speed = SPEEDS[speedIndex]
        enginePlayer?.setSpeed(speed)
        Log.i(TAG, "speed -> $speed")
    }

    private fun cycleTrack(kind: TrackKind) {
        val player = enginePlayer ?: return
        val tracks = player.tracks().filter { it.kind == kind }
        if (tracks.isEmpty()) {
            Log.i(TAG, "没有可切换的 $kind 轨道")
            return
        }
        val current = tracks.indexOfFirst { it.selected }
        val next = tracks[(current + 1).mod(tracks.size)]
        player.selectTrack(kind, next.id)
        Log.i(TAG, "选择 $kind -> ${next.title}（${next.id}）")
    }

    /** 通用状态行：位置 / 时长 / 播放态 / 倍速 / 轨道。 */
    private fun playbackLine(): String {
        val player = enginePlayer ?: return ""
        val state = player.state()
        val tracks = player.tracks()
        return buildString {
            appendLine(
                "pos ${state.positionMs / 1000.0}s / ${state.durationMs / 1000.0}s · " +
                    "${if (state.paused) "暂停" else "播放"} · ${state.speed}x",
            )
            appendLine(
                "轨道 " + tracks.joinToString(" · ") {
                    val mime = it.codec?.takeIf { c -> c.contains("/") }?.let { c -> "[$c]" } ?: ""
                    "${it.kind.name.lowercase()}:${it.title}$mime${if (it.selected) "*" else ""}"
                },
            )
        }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        player?.detach()
        media3?.detach()
    }

    override fun onDestroy() {
        restoreDisplayMode()
        handler.removeCallbacks(refresh)
        session?.release()
        session = null
        PlaybackForegroundService.stop(this)
        // mpv 的 destroy 要 join 渲染线程 + 等 mpv 退出，偶尔会卡住十几秒；
        // 放在后台线程，别把主线程（和新 activity）一起堵死。
        val mpv = player
        val m3 = media3
        player = null
        media3 = null
        if (mpv != null || m3 != null) {
            Thread({
                runCatching { m3?.close() }
                runCatching { mpv?.close() }
                Log.i(TAG, "播放内核已释放")
            }, "engine-close").start()
        }
        super.onDestroy()
    }

    /** 退出时把显示模式还给系统。 */
    private fun restoreDisplayMode() {
        if (matchedFps <= 0.0 || originalModeId == 0) return
        matchedFps = 0.0
        runCatching {
            val attrs = window.attributes
            // 0 = 交还给系统默认模式；设回「进入前的 mode」在 ColorOS 上不生效。
            attrs.preferredDisplayModeId = 0
            @Suppress("DEPRECATION")
            attrs.preferredRefreshRate = 0f
            window.attributes = attrs
            setSurfaceFrameRate(0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
            Log.i(TAG, "恢复显示模式（交还系统，原 ${originalModeId} @ ${originalRefreshRate}Hz）")
        }
    }

    /**
     * 改动 Surface 的期望帧率。退到后台 / 进 PiP / 销毁时 Surface 可能已经被系统
     * 释放，`setFrameRate` 会抛 `IllegalStateException: Surface has already been
     * released`，所以先看 `isValid` 再兜一层异常——帧率提示只是锦上添花，
     * 不能因为它把进程带崩。
     */
    private fun setSurfaceFrameRate(fps: Float, compatibility: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        runCatching {
            val surface = surfaceView.holder.surface
            if (surface != null && surface.isValid) {
                surface.setFrameRate(fps, compatibility)
            }
        }.onFailure { Log.w(TAG, "setFrameRate($fps) 失败：${it.message}") }
    }

    /** 直连 MediaCodec 的 HDR10+ 探针，顺带把帧送到 SurfaceView。 */
    private fun runProbe(surface: Surface) {
        Thread({
            val result = Hdr10PlusProbe.probe(url, surface)
            probeResult = if (result == null) {
                "探针失败"
            } else {
                buildString {
                    appendLine("codec ${result.mime} · ${result.frames} 帧")
                    appendLine("HDR10+ ${if (result.hasHdr10Plus) "有" else "无"}（${result.hdr10PlusBytes} 字节）")
                    appendLine(result.outputFormat)
                    append(url)
                }
            }
            handler.post { status.text = probeResult }
        }, "hdr10plus-probe").start()
    }

    private fun media3Status(): String {
        val player = media3 ?: return "media3 未初始化"
        val format = player.videoFormat
        return buildString {
            appendLine("engine media3")
            routeReason?.let { appendLine("路由 $it") }
            if (format != null) {
                appendLine("codec ${format.codecs} · ${format.width}×${format.height}")
                appendLine("color ${format.colorInfo}")
            }
            appendLine(player.debugCue)
            append(playbackLine())
            append(url)
        }
    }

    private fun statusLine(): String {
        val mpv = player ?: return "mpv 未初始化"
        fun p(name: String) = mpv.getProperty(name) ?: "-"
        val mode = currentDisplay.mode
        return buildString {
            routeReason?.let { appendLine("路由 $it") }
            appendLine("${p("width")}×${p("height")} · ${p("video-params/pixelformat")} · hwdec ${p("hwdec-current")}")
            appendLine("prim ${p("video-params/primaries")} · trc ${p("video-params/gamma")} · light ${p("video-params/light")}")
            appendLine("sig-peak ${p("video-params/sig-peak")} · min-luma ${p("video-params/min-luma")} · max-luma ${p("video-params/max-luma")}")
            val sceneMax = p("video-params/scene-max-r")
            if (sceneMax != "-") {
                appendLine("HDR10+ maxRGB ${sceneMax}/${p("video-params/scene-max-g")}/${p("video-params/scene-max-b")} · avg ${p("video-params/scene-avg")}")
            }
            appendLine("fps ${p("estimated-vf-fps")} · drops ${p("frame-drop-count")} · mode ${mode.modeId}@${"%.2f".format(mode.refreshRate)}Hz")
            append(playbackLine())
            append(url)
        }
    }

    /**
     * 按片源帧率切显示模式：优先选「刷新率是片源帧率整数倍」的模式，且倍数最小。
     * 24p 在 120Hz 上是 5 倍——每帧重复 5 次刷新，属于最干净的整数倍 pulldown。
     * 找不到整数倍时退回最高刷新率。
     */
    private fun maybeMatchFrameRate() {
        val mpv = player ?: return
        val fps = listOf("container-fps", "estimated-vf-fps")
            .mapNotNull { mpv.getProperty(it)?.toDoubleOrNull() }
            .firstOrNull { it > 1.0 }
        maybeMatchFrameRate(fps)
    }

    private fun maybeMatchFrameRate(fps: Double?) {
        if (fps == null || fps <= 1.0) return
        if (matchedFps > 0 && abs(fps - matchedFps) < 0.01) return

        val display = currentDisplay
        val sameSize = FrameRateMatcher.sameSizeModes(display)
        if (sameSize.isEmpty()) return
        val best = FrameRateMatcher.bestMode(sameSize, fps) ?: return

        matchedFps = fps

        val attrs = window.attributes
        if (attrs.preferredDisplayModeId != best.modeId ||
            attrs.preferredRefreshRate != best.refreshRate
        ) {
            attrs.preferredDisplayModeId = best.modeId
            @Suppress("DEPRECATION")
            attrs.preferredRefreshRate = best.refreshRate
            window.attributes = attrs
        }
        setSurfaceFrameRate(fps.toFloat(), Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
        Log.i(
            TAG,
            "帧率匹配：source=${fps}fps -> mode ${best.modeId} @ ${best.refreshRate}Hz" +
                "（×${"%.3f".format(best.refreshRate / fps)}）",
        )
    }

    private val currentDisplay: Display
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay
        }

    private companion object {
        const val TAG = "DvPlayerTest"
        const val DEFAULT_URL = "/data/user/0/com.dvplayer.app/files/dv-test.mp4"
        const val SUBTITLE_URL = "/data/user/0/com.dvplayer.app/files/test.srt"
        val SPEEDS = floatArrayOf(1f, 1.25f, 1.5f, 2f, 0.5f)
    }
}
