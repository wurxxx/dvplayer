package com.dvplayer.player

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * 播放前台服务（A10「通知与后台」）。
 *
 * 播放器对象仍然在播放页里，这里只负责把那条 MediaStyle 通知提升为前台通知，
 * 让系统在退到后台 / 锁屏后不急着杀进程。通知内容由 [MediaSessionController]
 * 更新（同一个 id），前台状态不受影响。
 *
 * 正式播放页接入后台播放时，应该把 MediaSession / 播放器一起搬进服务；
 * 这一步只是把「进程保活 + 通知」的骨架先立起来。
 */
class PlaybackForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent?.getParcelableExtra(EXTRA_NOTIFICATION, Notification::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra(EXTRA_NOTIFICATION)
        }
        if (notification == null) {
            Log.w(TAG, "没有通知，停止服务")
            stopSelf()
            return START_NOT_STICKY
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                MediaSessionController.NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(MediaSessionController.NOTIFICATION_ID, notification)
        }
        Log.i(TAG, "前台服务已启动")
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        Log.i(TAG, "前台服务已停止")
        super.onDestroy()
    }

    companion object {
        private const val TAG = "DvPlaybackService"
        private const val EXTRA_NOTIFICATION = "notification"

        fun start(context: Context, notification: Notification) {
            val intent = Intent(context, PlaybackForegroundService::class.java)
                .putExtra(EXTRA_NOTIFICATION, notification)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, PlaybackForegroundService::class.java))
        }
    }
}
