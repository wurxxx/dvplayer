package com.dvplayer.player

import android.view.Surface

/**
 * 两个内核（mpv / Media3）共用的播放器契约（A4「引擎契约」）。
 *
 * 壳层只依赖这个接口，A7 的「按能力路由 / 切换内核 / 重播」才有一个统一的落点。
 * 约定：
 * - 所有方法可以从主线程调用；实现内部自己排队，不阻塞调用方。
 * - [state] / [tracks] / [chapters] 是快照，随时可读。
 * - 时间单位统一毫秒。
 */
interface PlayerEngine : AutoCloseable {

    val id: EngineId

    /** 把 Surface 交给内核；可以重复调用（Surface 重建）。 */
    fun attach(surface: Surface, width: Int, height: Int)

    fun detach()

    /** 起播一个地址（本地路径或 URL）。 */
    fun load(url: String)

    fun play()

    fun pause()

    fun togglePause()

    fun seekTo(positionMs: Long)

    fun setSpeed(speed: Float)

    /**
     * 内核输出音量，1f 为原始音量。只用于 duck（导航播报 / 来电时压低），
     * 系统媒体音量仍由 AudioManager 管，两者相乘。
     */
    fun setVolume(scale: Float)

    /** 加载外部字幕并选中（mpv: sub-add；Media3: 重新装载字幕配置）。 */
    fun addSubtitle(path: String)

    fun selectTrack(kind: TrackKind, id: String)

    fun state(): PlaybackState

    fun tracks(): List<TrackInfo>

    fun chapters(): List<ChapterInfo>

    /**
     * 内核报的视频尺寸（宽 x 高）；还没解出来时返回 null。
     * 播放页拿它决定横屏 / 竖屏，Media3 自己会报，mpv 读容器属性。
     */
    fun videoSize(): Pair<Int, Int>? = null

    /**
     * 当前是不是硬件解码（规格行的 HW / SW）。
     * 内核还没解出画面、或这个内核没有这个概念时返回 null。
     */
    fun hardwareDecode(): Boolean? = null

    fun setListener(listener: Listener?)

    fun interface Listener {
        /** 状态 / 轨道有变化时回调；实现可以按自己的节奏推送。 */
        fun onPlayerEvent(event: PlayerEvent)
    }
}

enum class EngineId { MPV, MEDIA3 }

enum class TrackKind { VIDEO, AUDIO, SUB }

data class TrackInfo(
    val id: String,
    val kind: TrackKind,
    val title: String,
    val language: String? = null,
    val codec: String? = null,
    val selected: Boolean = false,
    val external: Boolean = false,
)

data class ChapterInfo(
    val index: Int,
    val title: String,
    val startMs: Long,
)

data class PlaybackState(
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val paused: Boolean = true,
    val speed: Float = 1f,
    val ended: Boolean = false,
) {
    val hasMedia: Boolean get() = durationMs > 0
}

sealed interface PlayerEvent {
    data class State(val state: PlaybackState) : PlayerEvent
    data class Tracks(val tracks: List<TrackInfo>) : PlayerEvent
    data class Error(val message: String) : PlayerEvent
    data class Log(val line: String) : PlayerEvent
}
