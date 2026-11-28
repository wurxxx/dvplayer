package com.dvplayer.app

import android.content.Context
import android.os.Looper
import android.os.Handler
import android.util.Log
import android.view.Surface
import android.view.SurfaceView
import com.dvplayer.core.PlaySource
import com.dvplayer.player.EngineId
import com.dvplayer.player.PlaybackMemory
import com.dvplayer.player.PlayerEngine
import com.dvplayer.player.PlayerEvent
import com.dvplayer.player.TrackInfo
import com.dvplayer.player.TrackKind
import com.dvplayer.player.media3.Media3Player
import com.dvplayer.player.mpv.MpvPlayer
import com.dvplayer.ui.phone.data.TrackPrefs
import com.dvplayer.ui.phone.player.PlayerPlaybackState
import com.dvplayer.ui.phone.player.PlayerTrack
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * 播放页和内核之间的一层薄壳。
 *
 * 只做三件事：创建内核、把 [PlayerEngine] 的事件翻成界面状态、
 * 退出时把进度写回 [PlaybackMemory]。UI 不直接碰 `:player`。
 */
class PlaybackSession(
    context: Context,
    private val source: PlaySource,
    /** 当前内核；切内核时整个 session 会被重建。 */
    val engineId: EngineId,
    dvProfile: Int?,
    /** 续播位置（0 表示从头）。 */
    startPositionMs: Long,
    /** 详情页选过的音轨 / 字幕序号；-1 = 不指定。 */
    private val preferredAudioIndex: Int = -1,
    private val preferredSubtitleIndex: Int = -1,
) : AutoCloseable {

    private companion object {
        const val TAG = "DvTracks"
    }

    private val memory = PlaybackMemory(context.applicationContext)

    /**
     * 音频焦点 + 耳机拔出。播放页通常已经持有一个，这里默认自己建一个，
     * 方便 `PlaybackSession` 单独使用（验证页 / 测试）。
     */
    private val audioControl: PlaybackAudioControl = PlaybackAudioControl(
        context,
        onPause = { engine.pause() },
        onResume = { engine.play() },
        onVolumeScale = { engine.setVolume(it) },
    )

    /** 内核实例。`PlaybackHolder` 要把同一个实例交给通知栏控制。 */
    val engine: PlayerEngine = when (engineId) {
        EngineId.MEDIA3 -> Media3Player(context.applicationContext)
        EngineId.MPV -> MpvPlayer()
    }

    private val _state = MutableStateFlow(
        PlayerPlaybackState(
            positionMs = startPositionMs,
            durationMs = 0,
            paused = true,
            engine = if (engineId == EngineId.MPV) "mpv" else "Media3",
        ),
    )
    val state: StateFlow<PlayerPlaybackState> = _state

    /** Media3 报告的真实视频比例；mpv 在自己的 FBO 里做黑边，不需要。 */
    private val _videoAspect = MutableStateFlow<Float?>(null)
    val videoAspect: StateFlow<Float?> = _videoAspect

    /**
     * 起播位置。mpv 在文件打开前 seek 会被丢掉，所以等第一次拿到时长再 seek。
     */
    private var pendingSeekMs = startPositionMs

    /** 详情页的音轨 / 字幕偏好只在第一次拿到轨道列表时应用。 */
    private var appliedPreferredTracks = false

    /** 语言码 / 标题里能不能认出中文（各家服务器给 zh / chi / zho / 简体中文 都有）。 */
    private fun isChinese(language: String?, title: String?): Boolean {
        val code = language.orEmpty().trim().lowercase()
        if (code.startsWith("zh") || code in setOf("chi", "zho", "chs", "cht")) return true
        val text = title.orEmpty()
        return text.contains("中文") || text.contains("简体") || text.contains("繁体") ||
            text.contains("Chinese", ignoreCase = true)
    }

    /** 简中优先：zh-CN / chs / 简体 / 简英双语 这类。 */
    private fun isSimplified(track: TrackInfo): Boolean {
        val code = track.language.orEmpty().lowercase()
        val text = track.title
        if (code in setOf("zh-tw", "zh-hk", "zh-hant") || code == "cht") return false
        if (text.contains("繁")) return false
        return true
    }

    /** 按详情页存的序号取轨道；音轨越界时退回第一条（保证有声音），字幕越界就不选。 */
    private fun pickPreferred(tracks: List<TrackInfo>, index: Int, fallbackFirst: Boolean): TrackInfo? {
        if (index < 0 || tracks.isEmpty()) return null
        return tracks.getOrNull(index) ?: if (fallbackFirst) tracks.first() else null
    }

    /** mpv 在 seek / EOF 时 `duration` 会短暂变 0，用最后一次有效值兜住。 */
    private var lastDurationMs = 0L
    private var lastPositionMs = startPositionMs

    init {
        if (engine is MpvPlayer) {
            // 播完停在最后一帧：否则 mpv 会 unload 文件，duration 归零、画面变黑。
            engine.setProperty("keep-open", "yes")
            // P5 的硬解会丢 RPU（画面发绿），交给内核切软解。
            engine.setDolbyVisionProfile(dvProfile)
            if (source.headers.isNotEmpty()) {
                val fields = source.headers.joinToString(",") { "${it.name}: ${it.value}" }
                engine.setProperty("http-header-fields", fields)
            }
        }
        // ExoPlayer 必须拿到 View 才能把解码帧送进 Surface；mpv 用 attach(surface)。
        (engine as? Media3Player)?.onVideoSize = { w, h ->
            if (w > 0 && h > 0) _videoAspect.value = w.toFloat() / h
        }
        engine.setListener(::onEvent)
        engine.load(source.url)
        audioControl.start()
        engine.play()
    }

    fun attach(surface: Surface, width: Int, height: Int) {
        engine.attach(surface, width, height)
    }

    /** Media3 专用：把 SurfaceView 交给 ExoPlayer（mpv 走 [attach]）。 */
    fun attachView(view: SurfaceView) {
        (engine as? Media3Player)?.attachView(view)
    }

    fun detach() = engine.detach()

    fun seekTo(positionMs: Long) {
        // keep-open 播完后再 seek 回来，mpv 会重新进入播放；但要显式取消暂停，
        // 否则停在第一帧不动（eof 时 pause 可能已被内核置位）。
        val wasEnded = _state.value.ended
        engine.seekTo(positionMs)
        if (wasEnded) engine.play()
    }

    fun togglePause() {
        engine.togglePause()
        // 让焦点逻辑知道这次是用户自己的意图，别被后续焦点事件反着改。
        audioControl.setWantsPlay(engine.state().paused.not())
    }

    fun play() {
        engine.play()
        audioControl.setWantsPlay(true)
    }

    fun pause() {
        engine.pause()
        audioControl.setWantsPlay(false)
    }

    fun setSpeed(speed: Float) = engine.setSpeed(speed)

    fun selectTrack(kind: TrackKind, id: String) = engine.selectTrack(kind, id)

    /** 写回本地续播位置（退出、进后台时调用）。 */
    fun save() {
        val now = engine.state()
        if (now.durationMs > 0) {
            memory.save(source.url, now.positionMs, now.durationMs)
        }
    }

    override fun close() {
        save()
        audioControl.release()
        engine.close()
    }

    private fun onEvent(event: PlayerEvent) {
        when (event) {
            is PlayerEvent.State -> {
                val s = event.state
                if (pendingSeekMs > 0 && s.durationMs > 0) {
                    engine.seekTo(pendingSeekMs)
                    pendingSeekMs = 0
                }
                val duration = if (s.durationMs > 0) s.durationMs else lastDurationMs
                lastDurationMs = duration
                // 只有「时长和位置同时为 0」才当成未知（mpv 在 seek / EOF 的那一瞬间），
                // 保留上一次的值避免进度条闪回片头。
                // 不能只看 duration：Media3 起播时 duration 还是 TIME_UNSET，但位置
                // 已经在推进，一律兜底会把真实位置丢掉，UI 就永远停在 00:00。
                val unknown = s.durationMs <= 0 && s.positionMs <= 0
                val position = if (unknown) lastPositionMs else s.positionMs
                lastPositionMs = position
                _state.value = _state.value.copy(
                    positionMs = position,
                    durationMs = duration,
                    paused = s.paused,
                    speed = s.speed,
                    ended = s.ended,
                )

                // 解码方式一般不中途变：还没报过就问一次，拿到就写进状态（规格行 HW/SW）。
                if (_state.value.hardwareDecode == null) {
                    engine.hardwareDecode()?.let { hw ->
                        _state.value = _state.value.copy(hardwareDecode = hw)
                    }
                }

                // mpv 不像 Media3 那样主动报视频尺寸：解出画面后补一次，播放页用它选方向。
                if (_videoAspect.value == null) {
                    engine.videoSize()?.let { (w, h) ->
                        if (w > 0 && h > 0) _videoAspect.value = w.toFloat() / h
                    }
                }
            }

            is PlayerEvent.Tracks -> {
                val audios = event.tracks.filter { it.kind == TrackKind.AUDIO }
                val subtitles = event.tracks.filter { it.kind == TrackKind.SUB }
                val video = event.tracks.firstOrNull { it.kind == TrackKind.VIDEO }

                // 详情页里选的音轨 / 字幕：拿到轨道后自动套上，只做一次。
                // 先按序号取；序号对不上（外挂轨看得到但播放器没列）再按语言找同一条。
                if (!appliedPreferredTracks && (audios.isNotEmpty() || subtitles.isNotEmpty())) {
                    appliedPreferredTracks = true
                    val audio = pickPreferred(audios, preferredAudioIndex, fallbackFirst = true)
                    // -2 = 详情页里选了「关闭字幕」，起播就明确关掉（MPV 的 sid=no）。
                    val subtitlesOff = preferredSubtitleIndex == TrackPrefs.SUBTITLE_OFF
                    // 没在详情页选过时：多字幕的片自动挑中文字幕（简中优先于繁中）。
                    val autoSubtitle = if (preferredSubtitleIndex == -1 && subtitles.size > 1) {
                        subtitles.firstOrNull { isChinese(it.language, it.title) && isSimplified(it) }
                            ?: subtitles.firstOrNull { isChinese(it.language, it.title) }
                    } else {
                        null
                    }
                    val subtitle = pickPreferred(subtitles, preferredSubtitleIndex, fallbackFirst = false)
                        ?: autoSubtitle
                    if (audio != null || subtitle != null || subtitlesOff) {
                        // 引擎的选轨要落在主线程（Media3 的 TrackSelectionOverride 就是）。
                        Handler(Looper.getMainLooper()).post {
                            audio?.let {
                                Log.i(TAG, "应用音轨偏好：${it.title} (${it.id})")
                                engine.selectTrack(TrackKind.AUDIO, it.id)
                            }
                            if (subtitlesOff) {
                                Log.i(TAG, "应用字幕偏好：关闭字幕")
                                engine.selectTrack(TrackKind.SUB, "no")
                            } else {
                                subtitle?.let {
                                    Log.i(TAG, "应用字幕偏好：${it.title} (${it.id})")
                                    engine.selectTrack(TrackKind.SUB, it.id)
                                }
                            }
                        }
                    } else {
                        Log.i(TAG, "没有可应用的轨道偏好（音轨 $preferredAudioIndex，字幕 $preferredSubtitleIndex）")
                    }
                }

                _state.value = _state.value.copy(
                    audios = audios.map { it.toUi("音轨 ${it.id}") },
                    subtitles = subtitles.map { it.toUi("字幕 ${it.id}") },
                    videoCodec = video?.codec ?: _state.value.videoCodec,
                )
            }

            is PlayerEvent.Error -> Unit
            is PlayerEvent.Log -> Unit
        }
    }

    private fun TrackInfo.toUi(fallback: String): PlayerTrack = PlayerTrack(
        title = languageName(language) ?: title.ifBlank { fallback },
        detail = listOfNotNull(codec, if (external) "外挂" else null)
            .distinct()
            .joinToString(" ")
            .ifBlank { "未提供" },
        selected = selected,
        id = id,
    )

    private fun languageName(code: String?): String? = when (code?.lowercase()) {
        "chi", "zh", "zho", "chs", "cht" -> "中文"
        "eng", "en" -> "英语"
        "jpn", "ja" -> "日语"
        "kor", "ko" -> "韩语"
        "und", null -> null
        else -> code
    }
}
