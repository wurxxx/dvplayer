package com.dvplayer.player.mpv

import android.util.Log
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
class MpvPlayer(private val verbose: Boolean = false) : PlayerEngine {

    override val id: EngineId = EngineId.MPV

    private companion object {
        const val TAG = "DvMpv"
    }

    private var handle: Long = MpvNative.create(verbose)

    @Volatile
    private var listener: PlayerEngine.Listener? = null

    /**
     * 起播后尽快读到 `container-fps` 并回调一次。MediaExtractor 对 mkv 不填
     * `KEY_FRAME_RATE`（帧率在 EBML 的 DefaultDuration 里），`FrameRateProbe`
     * 读不到，所以用 50ms 轮询补这条路径；越早切显示模式，起播丢帧越少。
     */
    @Volatile
    var onFrameRate: ((Double) -> Unit)? = null

    private var fpsThread: Thread? = null

    @Volatile
    private var running = true

    private var poller: Thread? = null

    /** 起播前请求、等文件打开后再执行的字幕。 */
    @Volatile
    private var pendingSubtitle: String? = null

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
    /** DV 配置（A7 路由探出来的）。P5 必须软解，见 [load]。 */
    private var dvProfile: Int? = null

    /**
     * A5：P5 的像素是 IPTPQc2，要靠 RPU 才能还原颜色；mediacodec 硬解不吐
     * `AV_FRAME_DATA_DOVI_METADATA`，libplacebo 拿不到 RPU 就会把画面渲染成绿紫。
     * 所以 P5 强制软解。P8/P7 的 BL 本身就是 HDR10，硬解只是少一层动态元数据，
     * 颜色不受影响。
     */
    fun setDolbyVisionProfile(profile: Int?) {
        dvProfile = profile
    }

    /**
     * TLS 证书校验（可选）。默认在 native 层设成 `tls-verify=no`——Android
     * 的系统 CA 不在 mbedTLS 的默认路径里，开校验会让所有 https 直接失败。
     *
     * 打开校验时把 CA bundle / 自签证书传给 mpv；必须在 [load] 之前调用
     * （`tls-verify` / `tls-ca-file` 是流打开时读的选项）。
     */
    fun setTlsVerification(verify: Boolean, caFile: String? = null) {
        setProperty("tls-verify", if (verify) "yes" else "no")
        if (!caFile.isNullOrEmpty()) setProperty("tls-ca-file", caFile)
        Log.i(TAG, "TLS 校验=${if (verify) "开" else "关"}${caFile?.let { " CA=$it" } ?: ""}")
    }

    override fun load(url: String) {
        if (handle == 0L) return
        if (dvProfile == 5 && getProperty("hwdec") != "no") {
            val err = setProperty("hwdec", "no")
            Log.i(TAG, "DV P5：切软解（硬解丢 RPU）-> ${err ?: "ok"}")
        }
        MpvNative.play(handle, url)
        startFrameRateProbe()
    }

    private fun startFrameRateProbe() {
        if (fpsThread != null) return
        fpsThread = Thread({
            for (i in 0 until 60) {          // 最多约 3 秒
                if (!running) break
                val fps = getProperty("container-fps")?.toDoubleOrNull()
                if (fps != null && fps > 1.0) {
                    onFrameRate?.invoke(fps)
                    break
                }
                try {
                    Thread.sleep(50)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }, "mpv-fps").apply {
            isDaemon = true
            start()
        }
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

    /** mpv 的 `volume` 是 0–100 的百分比，1f 对应 100。 */
    override fun setVolume(scale: Float) {
        setProperty("volume", (scale.coerceIn(0f, 1f) * 100f).toString())
    }

    /**
     * 加载外部字幕。`loadfile` 之后立刻 `sub-add` 会赶在文件打开之前，mpv 会
     * 拒绝（"no file"）；所以还没拿到时长时先挂起，等 [pollLoop] 看到片长再补。
     */
    override fun addSubtitle(path: String) {
        if (state().durationMs <= 0) {
            pendingSubtitle = path
        } else {
            command("sub-add", path, "select")
        }
    }

    override fun videoSize(): Pair<Int, Int>? {
        val w = getProperty("width")?.trim()?.toIntOrNull() ?: return null
        val h = getProperty("height")?.trim()?.toIntOrNull() ?: return null
        return if (w > 0 && h > 0) w to h else null
    }

    /** `hwdec-current` 是 mpv 当前真正在用的解码方式；"no" 就是软解。 */
    override fun hardwareDecode(): Boolean? {
        val mode = getProperty("hwdec-current")?.trim().orEmpty()
        if (mode.isEmpty()) return null
        return mode != "no"
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
        // 每 5 秒打一条「实际解码帧 / 丢帧 / 位置」：低端机上判断软解够不够快，
        // 只看 CPU 占用看不出是掉帧还是音画不同步。
        var lastLogAt = 0L
        var lastDrops = 0L
        while (running && handle != 0L) {
            val state = state()
            val now = System.currentTimeMillis()
            if (now - lastLogAt >= 5_000) {
                lastLogAt = now
                val drops = getProperty("frame-drop-count")?.toLongOrNull() ?: 0L
                val decoded = getProperty("decoder-frame-drop-count")?.toLongOrNull() ?: 0L
                Log.i(
                    TAG,
                    "pos ${state.positionMs}ms · 渲染丢帧 ${drops - lastDrops} · 解码丢帧 $decoded" +
                        " · hwdec ${getProperty("hwdec-current") ?: "?"}" +
                        " · ${getProperty("video-params/w")}x${getProperty("video-params/h")}",
                )
                lastDrops = drops
            }
            // 文件打开后再补上起播前请求的外挂字幕。
            val pending = pendingSubtitle
            if (pending != null && state.durationMs > 0) {
                pendingSubtitle = null
                command("sub-add", pending, "select")
            }
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

    /** [verbose] 打开 libmpv 的 v 级日志（照进 logcat 的 `DvMpv`）。 */
    external fun create(verbose: Boolean): Long

    external fun attach(handle: Long, surface: Surface, width: Int, height: Int)

    external fun play(handle: Long, url: String)

    external fun detach(handle: Long)

    external fun command(handle: Long, args: Array<String>): String?

    external fun setProperty(handle: Long, name: String, value: String): String?

    external fun getProperty(handle: Long, name: String): String?

    external fun setHdrPassthrough(handle: Long, enabled: Boolean)

    external fun destroy(handle: Long)
}
