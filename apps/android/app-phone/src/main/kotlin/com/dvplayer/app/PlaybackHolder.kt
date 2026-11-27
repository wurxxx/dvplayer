package com.dvplayer.app

import android.content.Context
import android.util.Log
import com.dvplayer.core.PlaySource
import com.dvplayer.player.EngineId
import com.dvplayer.player.MediaSessionController
import com.dvplayer.player.PlaybackForegroundService
import com.dvplayer.ui.phone.player.PlayerPlaybackState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * 进程级的播放持有者：让播放不跟着 Activity 走。
 *
 * 之前的做法是 `PlaybackSession` 活在 Compose 的 `remember` 里，Activity 一被
 * 回收（旋转、进后台、系统回收）就 `close()`，播放立刻停。这里把 session
 * 提到单例上：
 *
 * - 播放页只负责把 Surface 交进来 / 拿走，不再创建内核
 * - Activity 销毁时只 detach Surface，音频继续；回到前台重新 attach 就恢复出画
 * - 顺带接上 [MediaSessionController]（通知栏 / 锁屏 / 蓝牙按键都能控制）和
 *   前台服务（后台不被杀）
 * - 真正「退出播放」由用户点关闭 / 返回触发，这时才 [close]
 *
 * 单例只在主线程访问；内核自己管线程。
 */
object PlaybackHolder {

    private const val TAG = "DvPlaybackHolder"

    /** 当前会话；null 表示没在播。 */
    private var session: PlaybackSession? = null

    /** 当前会话的标识，用来判断 Activity 重进时是不是同一部片。 */
    private var currentUrl: String? = null

    /** 通知 / 锁屏控制。跟着 session 一起建。 */
    private var mediaSession: MediaSessionController? = null

    private var scope: CoroutineScope? = null
    private var ticker: Job? = null

    /** 最近一次的内核状态；Activity 重建时先用它渲染，避免闪一下 0:00。 */
    var lastState: PlayerPlaybackState? = null
        private set

    /** 当前会话的播放状态流；没有会话时为 null。 */
    val state: StateFlow<PlayerPlaybackState>?
        get() = session?.state

    val videoAspect: StateFlow<Float?>?
        get() = session?.videoAspect

    val isActive: Boolean
        get() = session != null

    /**
     * 打开一个播放会话。同一个 url + 同一个内核时直接复用（Activity 重建、
     * 旋转都不会打断播放）；换片 / 换内核才重建。
     */
    fun open(
        context: Context,
        source: PlaySource,
        engineId: EngineId,
        dvProfile: Int?,
        startPositionMs: Long,
    ): PlaybackSession {
        val appContext = context.applicationContext
        session?.let { existing ->
            if (currentUrl == source.url && existing.engineId == engineId) {
                Log.i(TAG, "复用已有会话：${source.url}")
                return existing
            }
            Log.i(TAG, "换片 / 换内核，关闭旧会话")
            close()
        }

        Log.i(TAG, "新建会话：${source.url} · $engineId")
        val created = PlaybackSession(
            appContext,
            source,
            engineId,
            dvProfile,
            startPositionMs,
            preferredAudioIndex = com.dvplayer.ui.phone.data.TrackPrefs.audioIndex(appContext),
            preferredSubtitleIndex = com.dvplayer.ui.phone.data.TrackPrefs.subtitleIndex(appContext),
        )
        session = created
        currentUrl = source.url

        // 通知栏 / 锁屏控制 + 前台服务。
        runCatching {
            val controller = MediaSessionController(appContext, created.engine, source.title)
            mediaSession = controller
            PlaybackForegroundService.start(appContext, controller.notification())
            startTicker(appContext, created, controller)
        }.onFailure { Log.w(TAG, "媒体会话 / 前台服务启动失败：${it.message}") }

        return created
    }

    /** 每次拿到内核状态就同步给通知栏；顺带缓存给 Activity 重建用。 */
    private fun startTicker(
        context: Context,
        session: PlaybackSession,
        controller: MediaSessionController,
    ) {
        ticker?.cancel()
        val newScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        scope = newScope
        ticker = newScope.launch {
            session.state.collect { s ->
                lastState = s
                controller.update(
                    MediaSessionController.PlaybackStateSnapshot(
                        positionMs = s.positionMs,
                        durationMs = s.durationMs,
                        paused = s.paused,
                        speed = s.speed,
                    ),
                )
            }
        }
    }

    /** Activity 销毁：只断开画面，播放继续。 */
    fun detachSurface() {
        session?.detach()
    }

    /** 用户真正退出播放：存进度、停服务、释放内核。 */
    fun close() {
        ticker?.cancel()
        ticker = null
        scope?.cancel()
        scope = null
        mediaSession = null
        session?.close()
        session = null
        currentUrl = null
        lastState = null
        runCatching { PlaybackForegroundService.stop(AppContextHolder.get()) }
    }
}

/**
 * 前台服务停止需要一个 Context，而 [PlaybackHolder.close] 可能从任何地方调用。
 * 由 Activity 在启动时塞进来。
 */
object AppContextHolder {
    private var context: Context? = null

    fun set(context: Context) {
        this.context = context.applicationContext
    }

    fun get(): Context = requireNotNull(context) { "AppContextHolder 未初始化" }
}
