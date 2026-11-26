package com.dvplayer.app

import android.app.Activity
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.FrameLayout
import android.widget.TextView
import com.dvplayer.player.mpv.MpvPlayer

/**
 * A4 的最小出画验证页：SurfaceView → [MpvPlayer] → mpv render API。
 *
 * 用 adb 直接起：
 *   adb shell am start -n com.dvplayer.app/.PlayerTestActivity \
 *       --es url /sdcard/Download/dv-test.mp4
 */
class PlayerTestActivity : Activity(), SurfaceHolder.Callback {

    private lateinit var player: MpvPlayer
    private lateinit var surfaceView: SurfaceView
    private lateinit var status: TextView
    private var started = false

    private val url: String
        get() = intent.getStringExtra("url") ?: DEFAULT_URL

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
            text = "mpv · 等待 Surface\n$url"
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 12f
            setPadding(24, 24, 24, 24)
        }

        setContentView(
            FrameLayout(this).apply {
                addView(
                    surfaceView,
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT,
                    ),
                )
                addView(status, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.START))
            },
        )
        Log.i(TAG, "mpv version: ${player.getProperty("mpv-version")}")
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        attach(holder)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        attach(holder)
    }

    private fun attach(holder: SurfaceHolder) {
        val frame = holder.surfaceFrame
        player.attach(holder.surface, frame.width(), frame.height())
        status.text = "mpv · ${frame.width()}×${frame.height()}\n$url"
        if (!started) {
            started = true
            // Surface 的 GL 初始化在渲染线程里异步做，这里不用等，mpv 会自己排队。
            player.play(url)
        }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        player.detach()
    }

    override fun onDestroy() {
        player.close()
        super.onDestroy()
    }

    private companion object {
        const val TAG = "DvPlayerTest"
        const val DEFAULT_URL = "/sdcard/Download/dv-test.mp4"
    }
}
