package com.dvplayer.player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build

/**
 * 媒体会话 + 通知（A4「会话 / 通知」）。
 *
 * 用平台的 `MediaSession`（不引额外依赖），把播放状态挂上去，锁屏 / 蓝牙 /
 * 通知上的按钮都走同一个回调，转到 [PlayerEngine]。
 *
 * 通知上的按钮用动态广播接收器处理，因为播放器对象在壳层，不另外起前台服务；
 * A10 接后台播放时再把它挪进 Service。
 */
class MediaSessionController(
    private val context: Context,
    private val engine: PlayerEngine,
    private val title: String,
) {

    private val session = MediaSession(context, "DVPlayer")
    private var lastTitle: String = title
    private var lastPaused: Boolean? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                ACTION_TOGGLE -> engine.togglePause()
                ACTION_FORWARD -> engine.seekTo(engine.state().positionMs + 10_000)
                ACTION_REWIND -> engine.seekTo((engine.state().positionMs - 10_000).coerceAtLeast(0))
            }
        }
    }

    init {
        ensureChannel()
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = engine.play()
            override fun onPause() = engine.pause()
            override fun onSeekTo(pos: Long) = engine.seekTo(pos)
            override fun onSkipToNext() = engine.seekTo(engine.state().positionMs + 10_000)
            override fun onSkipToPrevious() =
                engine.seekTo((engine.state().positionMs - 10_000).coerceAtLeast(0))
        })
        session.isActive = true

        val filter = IntentFilter().apply {
            addAction(ACTION_TOGGLE)
            addAction(ACTION_FORWARD)
            addAction(ACTION_REWIND)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
    }

    /** 每秒调一次，把位置和播放态同步给系统。 */
    fun update(state: PlaybackStateSnapshot) {
        val mediaState = PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_SEEK_TO or
                    PlaybackState.ACTION_SKIP_TO_NEXT or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS,
            )
            .setState(
                if (state.paused) PlaybackState.STATE_PAUSED else PlaybackState.STATE_PLAYING,
                state.positionMs,
                state.speed.coerceAtLeast(0.1f),
            )
            .build()
        session.setPlaybackState(mediaState)
        session.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, lastTitle)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, state.durationMs)
                .build(),
        )
        if (lastPaused != state.paused) {
            lastPaused = state.paused
            notify(state.paused)
        }
    }

    fun setTitle(title: String) {
        lastTitle = title
    }

    override fun toString(): String = "MediaSessionController($title)"

    private fun notify(paused: Boolean) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val toggleIntent = PendingIntent.getBroadcast(
            context,
            1,
            Intent(ACTION_TOGGLE).setPackage(context.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val contentIntent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.let {
                PendingIntent.getActivity(
                    context,
                    2,
                    it,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            }

        val icon = if (paused) android.R.drawable.ic_media_play else android.R.drawable.ic_media_pause
        val action = Notification.Action.Builder(
            Icon.createWithResource(context, icon),
            if (paused) "播放" else "暂停",
            toggleIntent,
        ).build()
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(lastTitle)
            .setContentText(if (paused) "已暂停" else "正在播放")
            .setContentIntent(contentIntent)
            .setOngoing(!paused)
            .setOnlyAlertOnce(true)
            .addAction(action)
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(session.sessionToken)
                    .setShowActionsInCompactView(0),
            )
            .build()
        manager.notify(NOTIFICATION_ID, notification)
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "播放控制", NotificationManager.IMPORTANCE_LOW),
        )
    }

    fun release() {
        runCatching { context.unregisterReceiver(receiver) }
        session.isActive = false
        session.release()
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }

    /** 避免 :player 直接依赖 PlaybackState（名字冲突），单独传快照。 */
    data class PlaybackStateSnapshot(
        val positionMs: Long,
        val durationMs: Long,
        val paused: Boolean,
        val speed: Float,
    )

    companion object {
        private const val CHANNEL_ID = "dvplayer_playback"
        private const val NOTIFICATION_ID = 1001
        private const val ACTION_TOGGLE = "com.dvplayer.player.TOGGLE"
        private const val ACTION_FORWARD = "com.dvplayer.player.FORWARD"
        private const val ACTION_REWIND = "com.dvplayer.player.REWIND"

        fun snapshot(state: com.dvplayer.player.PlaybackState) = PlaybackStateSnapshot(
            state.positionMs,
            state.durationMs,
            state.paused,
            state.speed,
        )
    }
}
