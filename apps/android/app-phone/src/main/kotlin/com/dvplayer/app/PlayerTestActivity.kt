package com.dvplayer.app

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowInsets
import android.widget.FrameLayout
import android.widget.TextView
import com.dvplayer.player.mpv.MpvPlayer

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
    private val handler = Handler(Looper.getMainLooper())

    private val url: String
        get() = intent.getStringExtra("url") ?: DEFAULT_URL

    private val refresh = object : Runnable {
        override fun run() {
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
        return buildString {
            appendLine("${p("width")}×${p("height")} · ${p("video-params/pixelformat")} · hwdec ${p("hwdec-current")}")
            appendLine("prim ${p("video-params/primaries")} · trc ${p("video-params/gamma")} · light ${p("video-params/light")}")
            appendLine("sig-peak ${p("video-params/sig-peak")} · min-luma ${p("video-params/min-luma")} · max-luma ${p("video-params/max-luma")}")
            appendLine("fps ${p("estimated-vf-fps")} · drops ${p("frame-drop-count")}")
            append(url)
        }
    }

    private companion object {
        const val TAG = "DvPlayerTest"
        const val DEFAULT_URL = "/data/user/0/com.dvplayer.app/files/dv-test.mp4"
    }
}
