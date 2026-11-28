package com.dvplayer.app

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.dvplayer.ui.phone.PhoneApp

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 手机端界面是竖屏布局：固定竖屏。播放页会按片源临时转横屏，
        // 退出时回到这里也要转回来，否则会停在横屏。
        requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        // 内容页是 edge-to-edge：背景自己铺满，系统栏透明，键盘 insets 才拿得到。
        // 播放页是另一个 Activity，仍是原来的全屏窗口配置。
        WindowCompat.setDecorFitsSystemWindows(window, false)
        // 有刘海/挖孔时也让内容铺到屏幕边缘，否则全屏后两侧会留一条黑边。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        enterFullscreen()
        setContent {
            PhoneApp(
                onPlay = { itemId, seriesId ->
                    startActivity(
                        Intent(this, PlaybackActivity::class.java)
                            .putExtra("item", itemId)
                            .putExtra("series", seriesId),
                    )
                },
            )
        }
    }

    /**
     * 每次回到前台都重新隐藏一次。
     *
     * 从播放页返回、弹过输入法、插拔耳机都可能让系统栏自己冒出来；只在 onCreate
     * 里隐藏一次会漏这些场景，页面就变回「有状态栏」的样子了。
     */
    override fun onResume() {
        super.onResume()
        // 从横屏播放页退回来：屏幕方向还停在横屏，这里恢复竖屏。
        requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterFullscreen()
    }

    private fun enterFullscreen() {
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        // 从边缘上滑可以临时唤出系统栏，几秒后自己缩回去，不至于把人困在全屏里。
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.systemBars())
    }
}
