package com.dvplayer.player.mpv

import android.view.Surface
import com.dvplayer.player.ChapterInfo
import com.dvplayer.player.EngineId
import com.dvplayer.player.PlaybackState
import com.dvplayer.player.PlayerEngine
import com.dvplayer.player.PlayerEvent
import com.dvplayer.player.TrackInfo
import com.dvplayer.player.TrackKind

/**
 * mpv 内核，实现 [PlayerEngine] 契约（A4）。
 *
 * `command` / `setProperty` / `getProperty` 内部走 libmpv 的命令队列，可以从主线程
 * 调用；`attach` / `detach` 只是投递 Surface，也是非阻塞的。
 *
 * 状态推送用 200ms 的轮询线程读 mpv 属性（libmpv 的属性读取本身是线程安全的），
 * 比再往 native 里加一套事件回调简单，也足够驱动进度条。
 */
class MpvPlayer : PlayerEngine {

    override val id: EngineId = EngineId.MPV

    private var handle: Long = MpvNative.create()

    @Volatile
    private var listener: PlayerEngine.Listener? = null

    @Volatile
    private var running = true

    private var poller: Thread? = null

    val isValid: Boolean get() = handle != 0L

    override fun attach(surface: Surface, width: Int, height: Int) {
        if (handle != 0L) MpvNative.attach(handle, surface, width, height)
    }

    override fun detach() {
        if (handle != 0L) MpvNative.detach(handle)
    }

    fun command(vararg args: String): String? =
        if (handle == 0L) "player 已释放" else MpvNative.command(handle, Array(args.size) { args[it] })

    fun setProperty(name: String, value: String): String? =
        if (handle == 0L) "player 已释放" else MpvNative.setProperty(handle, name, value)

    fun getProperty(name: String): String? =
        if (handle == 0L) null else MpvNative.getProperty(handle, name)

    /**
     * HDR 直出开关（A5）。`false` 时 mpv 在 gpu VO 里做 HDR→SDR tone mapping，
     * EGLSurface 固定 sRGB；`true`（默认）把 PQ / HLG 交给显示端。
     */
    fun setHdrPassthrough(enabled: Boolean) {
        if (handle != 0L) MpvNative.setHdrPassthrough(handle, enabled)
    }

    /** GL 就绪前的调用会被 native 侧暂存，等 render context 建好再真正加载。 */
    override fun load(url: String) {
        if (handle != 0L) MpvNative.play(handle, url)
    }

    override fun play() {
        setProperty("pause", "no")
    }

    override fun pause() {
        setProperty("pause", "yes")
    }

    override fun togglePause() {
        val paused = getProperty("pause") != "no"
        setProperty("pause", if (paused) "no" else "yes")
    }

    override fun seekTo(positionMs: Long) {
        command("seek", "%.3f".format(positionMs / 1000.0), "absolute")
    }

    override fun setSpeed(speed: Float) {
        setProperty("speed", speed.toString())
    }

    override fun addSubtitle(path: String) {
        command("sub-add", path, "select")
    }

    override fun selectTrack(kind: TrackKind, trackId: String) {
        val name = when (kind) {
            TrackKind.VIDEO -> "vid"
            TrackKind.AUDIO -> "aid"
            TrackKind.SUB -> "sid"
        }
        setProperty(name, trackId)
    }

    override fun state(): PlaybackState {
        val position = propSeconds("time-pos")
        val duration = propSeconds("duration")
        return PlaybackState(
            positionMs = (position * 1000).toLong(),
            durationMs = (duration * 1000).toLong(),
            paused = getProperty("pause") != "no",
            speed = getProperty("speed")?.toFloatOrNull()?.takeIf { it > 0f } ?: 1f,
            ended = getProperty("eof-reached") == "yes",
        )
    }

    override fun tracks(): List<TrackInfo> {
        val count = getProperty("track-list/count")?.toIntOrNull() ?: return emptyList()
        return (0 until count).mapNotNull { i ->
            val type = getProperty("track-list/$i/type") ?: return@mapNotNull null
            val kind = when (type) {
                "video" -> TrackKind.VIDEO
                "audio" -> TrackKind.AUDIO
                "sub" -> TrackKind.SUB
                else -> return@mapNotNull null
            }
            val trackId = getProperty("track-list/$i/id") ?: return@mapNotNull null
            TrackInfo(
                id = trackId,
                kind = kind,
                title = getProperty("track-list/$i/title")
                    ?.takeIf { it.isNotBlank() }
                    ?: kindLabel(kind, trackId),
                language = getProperty("track-list/$i/lang")?.takeIf { it.isNotBlank() },
                codec = getProperty("track-list/$i/codec")?.takeIf { it.isNotBlank() },
                selected = getProperty("track-list/$i/selected") == "yes",
                external = getProperty("track-list/$i/external") == "yes",
            )
        }
    }

    override fun chapters(): List<ChapterInfo> {
        val count = getProperty("chapter-list/count")?.toIntOrNull() ?: return emptyList()
        return (0 until count).map { i ->
            ChapterInfo(
                index = i,
                title = getProperty("chapter-list/$i/title")?.takeIf { it.isNotBlank() } ?: "章节 ${i + 1}",
                startMs = (propSeconds("chapter-list/$i/time") * 1000).toLong(),
            )
        }
    }

    override fun setListener(listener: PlayerEngine.Listener?) {
        this.listener = listener
        if (listener != null && poller == null) {
            poller = Thread(::pollLoop, "mpv-state").apply {
                isDaemon = true
                start()
            }
        }
    }

    override fun close() {
        running = false
        poller?.interrupt()
        poller = null
        val h = handle
        handle = 0L
        if (h != 0L) MpvNative.destroy(h)
    }

    private fun pollLoop() {
        var lastState: PlaybackState? = null
        var lastTracks: List<TrackInfo> = emptyList()
        while (running && handle != 0L) {
            val state = state()
            if (state != lastState) {
                lastState = state
                listener?.onPlayerEvent(PlayerEvent.State(state))
            }
            val tracks = tracks()
            if (tracks != lastTracks) {
                lastTracks = tracks
                listener?.onPlayerEvent(PlayerEvent.Tracks(tracks))
            }
            try {
                Thread.sleep(200)
            } catch (_: InterruptedException) {
                break
            }
        }
    }

    /** mpv 的浮点属性可能是 `nan`，统一吞掉。 */
    private fun propSeconds(name: String): Double =
        getProperty(name)?.toDoubleOrNull()?.takeIf { !it.isNaN() } ?: 0.0

    private fun kindLabel(kind: TrackKind, id: String): String = when (kind) {
        TrackKind.VIDEO -> "视频 $id"
        TrackKind.AUDIO -> "音轨 $id"
        TrackKind.SUB -> "字幕 $id"
    }
}

internal object MpvNative {
    init {
        System.loadLibrary("dvplayer_mpv")
    }

    external fun create(): Long

    external fun attach(handle: Long, surface: Surface, width: Int, height: Int)

    external fun play(handle: Long, url: String)

    external fun detach(handle: Long)

    external fun command(handle: Long, args: Array<String>): String?

    external fun setProperty(handle: Long, name: String, value: String): String?

    external fun getProperty(handle: Long, name: String): String?

    external fun setHdrPassthrough(handle: Long, enabled: Boolean)

    external fun destroy(handle: Long)
}
