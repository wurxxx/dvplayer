package com.dvplayer.app

import android.app.Activity
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
import android.view.WindowInsets
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import com.dvplayer.player.EngineId
import com.dvplayer.player.PlaybackMemory
import com.dvplayer.player.PlayerEngine
import com.dvplayer.player.TrackKind
import com.dvplayer.player.media3.Hdr10PlusProbe
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
    private lateinit var controlsBox: LinearLayout
    private var started = false
    private var matchedFps = 0.0
    private var probeResult: String? = null
    private var speedIndex = 0
    private var tickCount = 0
    private var resumeApplied = false
    private lateinit var memory: PlaybackMemory
    private val handler = Handler(Looper.getMainLooper())

    private val enginePlayer: PlayerEngine?
        get() = player ?: media3

    private val url: String
        get() = intent.getStringExtra("url") ?: DEFAULT_URL

    /** 外部字幕路径：`--es sub /path/to.ass`，默认是内置测试 srt。 */
    private val subtitleUrl: String
        get() = intent.getStringExtra("sub") ?: SUBTITLE_URL

    private val engine: String
        get() = intent.getStringExtra("engine") ?: "mpv"

    private val refresh = object : Runnable {
        override fun run() {
            status.text = when (engine) {
                "media3" -> media3Status()
                "codec" -> probeResult ?: "解码中…"
                else -> {
                    maybeMatchFrameRate()
                    statusLine()
                }
            }
            maybeResume()
            if (++tickCount % 3 == 0) maybeSave()
            handler.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        memory = PlaybackMemory(this)
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

        Log.i(TAG, "engine=$engine url=$url")
    }

    override fun onResume() {
        super.onResume()
        handler.post(refresh)
    }

    override fun onPause() {
        handler.removeCallbacks(refresh)
        maybeSave()
        super.onPause()
    }

    override fun surfaceCreated(holder: SurfaceHolder) = attach(holder)

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) =
        attach(holder)

    private fun attach(holder: SurfaceHolder) {
        when (engine) {
            "media3" -> {
                media3?.attachView(surfaceView)
                if (!started) {
                    started = true
                    media3?.load(url)
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
        return box
    }

    /** 首次拿到片长后跳到上次的位置。 */
    private fun maybeResume() {
        if (resumeApplied) return
        val player = enginePlayer ?: return
        val state = player.state()
        if (state.durationMs <= 0) return
        resumeApplied = true
        val saved = memory.position(url)
        if (saved > 3_000 && saved < state.durationMs - 5_000) {
            player.seekTo(saved)
            Log.i(TAG, "续播：$saved ms")
        }
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
                    "${it.kind.name.lowercase()}:${it.title}${if (it.selected) "*" else ""}"
                },
            )
        }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        player?.detach()
        media3?.detach()
    }

    override fun onDestroy() {
        handler.removeCallbacks(refresh)
        player?.close()
        media3?.close()
        super.onDestroy()
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
            if (format != null) {
                appendLine("codec ${format.codecs} · ${format.width}×${format.height}")
                appendLine("color ${format.colorInfo}")
            }
            append(playbackLine())
            append(url)
        }
    }

    private fun statusLine(): String {
        val mpv = player ?: return "mpv 未初始化"
        fun p(name: String) = mpv.getProperty(name) ?: "-"
        val mode = currentDisplay.mode
        return buildString {
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
            .firstOrNull { it > 1.0 } ?: return
        if (matchedFps > 0 && abs(fps - matchedFps) < 0.01) return

        val display = currentDisplay
        val current = display.mode
        val sameSize = display.supportedModes.filter {
            it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight
        }
        if (sameSize.isEmpty()) return

        val best = sameSize
            .map { it to it.refreshRate / fps }
            .filter { (_, ratio) -> ratio >= 0.999 && abs(ratio - round(ratio)) < 0.01 }
            .minByOrNull { (_, ratio) -> ratio }
            ?.first
            ?: sameSize.maxByOrNull { it.refreshRate }
            ?: return

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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            surfaceView.holder.surface?.setFrameRate(
                fps.toFloat(),
                Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE,
            )
        }
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
