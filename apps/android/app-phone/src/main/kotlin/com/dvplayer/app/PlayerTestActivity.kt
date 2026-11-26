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
import android.widget.FrameLayout
import android.widget.TextView
import com.dvplayer.player.mpv.MpvPlayer
import kotlin.math.abs
import kotlin.math.round

/**
 * A4 / A5 的验证页：SurfaceView → [MpvPlayer] → mpv render API。
 *
 * 用 adb 直接起：
 *   adb shell am start -n com.dvplayer.app/.PlayerTestActivity \
 *       --es url /data/user/0/com.dvplayer.app/files/dv-test.mp4
 *
 * 页面会每秒刷一次 mpv 的视频参数（primaries / gamma / sig-peak / 丢帧），
 * A5 验 HDR 时主要看这几项。
 */
class PlayerTestActivity : Activity(), SurfaceHolder.Callback {

    private lateinit var player: MpvPlayer
    private lateinit var surfaceView: SurfaceView
    private lateinit var status: TextView
    private var started = false
    private var matchedFps = 0.0
    private val handler = Handler(Looper.getMainLooper())

    private val url: String
        get() = intent.getStringExtra("url") ?: DEFAULT_URL

    private val refresh = object : Runnable {
        override fun run() {
            maybeMatchFrameRate()
            status.text = statusLine()
            handler.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        player = MpvPlayer()
        if (!player.isValid) {
            finish()
            return
        }
        // 调试用：--es hwdec no 可以走软解，验证 HDR10+ 动态元数据（硬解 copy 拿不到 SEI）。
        intent.getStringExtra("hwdec")?.let {
            Log.i(TAG, "hwdec -> $it ${player.setProperty("hwdec", it) ?: "ok"}")
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
        setContentView(root)

        // Android 15+ 强制 edge-to-edge，状态栏会压在画面上，这里把文字让开。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            root.setOnApplyWindowInsetsListener { _, insets ->
                val top = insets.getInsets(WindowInsets.Type.systemBars()).top
                status.setPadding(24, 24 + top, 24, 24)
                insets
            }
        }

        Log.i(TAG, "mpv version: ${player.getProperty("mpv-version")}")
    }

    override fun onResume() {
        super.onResume()
        handler.post(refresh)
    }

    override fun onPause() {
        handler.removeCallbacks(refresh)
        super.onPause()
    }

    override fun surfaceCreated(holder: SurfaceHolder) = attach(holder)

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) =
        attach(holder)

    private fun attach(holder: SurfaceHolder) {
        val frame = holder.surfaceFrame
        player.attach(holder.surface, frame.width(), frame.height())
        if (!started) {
            started = true
            // Surface 的 GL 初始化在渲染线程里异步做；mpv 会自己排队。
            player.play(url)
        }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        player.detach()
    }

    override fun onDestroy() {
        handler.removeCallbacks(refresh)
        player.close()
        super.onDestroy()
    }

    private fun statusLine(): String {
        fun p(name: String) = player.getProperty(name) ?: "-"
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
            append(url)
        }
    }

    /**
     * 按片源帧率切显示模式：优先选「刷新率是片源帧率整数倍」的模式，且倍数最小。
     * 24p 在 120Hz 上是 5 倍——每帧重复 5 次刷新，属于最干净的整数倍 pulldown。
     * 找不到整数倍时退回最高刷新率。
     */
    private fun maybeMatchFrameRate() {
        val fps = listOf("container-fps", "estimated-vf-fps")
            .mapNotNull { player.getProperty(it)?.toDoubleOrNull() }
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
    }
}
