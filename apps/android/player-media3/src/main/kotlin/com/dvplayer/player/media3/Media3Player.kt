package com.dvplayer.player.media3

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import android.view.SurfaceView
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import com.dvplayer.player.ChapterInfo
import com.dvplayer.player.EngineId
import com.dvplayer.player.PlaybackState
import com.dvplayer.player.PlayerEngine
import com.dvplayer.player.PlayerEvent
import com.dvplayer.player.TrackInfo
import com.dvplayer.player.TrackKind
import java.io.File

/**
 * Media3（ExoPlayer）内核，实现 [PlayerEngine] 契约（A6）。
 *
 * Media3 的价值在 HDR：平台 MediaCodec 从 SEI 里解析出 HDR10+（ST2094-40）动态
 * 元数据，随 output buffer 交给 SurfaceFlinger / HWC。mpv 走 EGL 没有公开的写入
 * 接口，所以 HDR10+ 只能在这个内核里真正生效。
 *
 * 状态推送用主线程 250ms 轮询（ExoPlayer 要求在主线程访问），和 mpv 侧的
 * 200ms 轮询行为一致。
 */
@UnstableApi
class Media3Player(context: Context) : PlayerEngine {

    override val id: EngineId = EngineId.MEDIA3

    private val player: ExoPlayer = ExoPlayer.Builder(context).build()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var listener: PlayerEngine.Listener? = null
    private var surfaceView: SurfaceView? = null
    private var currentUrl: String? = null
    private val subtitles = mutableListOf<MediaItem.SubtitleConfiguration>()
    private var lastState: PlaybackState? = null
    private var lastTracks: List<TrackInfo> = emptyList()
    private var polling = false

    /** reload 后等轨道就绪再恢复的音轨 id。 */
    private var pendingAudioRestore: String? = null

    /** 视频轨的 [Format]（含 colorInfo），用于验证页显示。 */
    var videoFormat: Format? = null
        private set

    private val tick = object : Runnable {
        override fun run() {
            if (!polling) return
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
            mainHandler.postDelayed(this, 250)
        }
    }

    init {
        player.addListener(object : Player.Listener {
            override fun onPlayerError(error: PlaybackException) {
                Log.e(TAG, "playback error", error)
                listener?.onPlayerEvent(PlayerEvent.Error(error.errorCodeName))
            }

            override fun onTracksChanged(tracks: Tracks) {
                // reload 之后新轨道就绪，这时才能按新 group 恢复音轨选择。
                val pending = pendingAudioRestore ?: return
                pendingAudioRestore = null
                selectTrack(TrackKind.AUDIO, pending)
            }
        })
        player.addAnalyticsListener(object : AnalyticsListener {
            override fun onVideoInputFormatChanged(
                eventTime: AnalyticsListener.EventTime,
                format: Format,
                decoderReuseEvaluation: DecoderReuseEvaluation?,
            ) {
                videoFormat = format
                Log.i(TAG, "video format: $format")
            }

            override fun onRenderedFirstFrame(
                eventTime: AnalyticsListener.EventTime,
                output: Any,
                renderTimeMs: Long,
            ) {
                Log.i(TAG, "first frame rendered")
            }
        })
    }

    override fun attach(surface: Surface, width: Int, height: Int) {
        // ExoPlayer 需要 View 才能正确处理屏幕旋转 / 尺寸变化；这里由
        // [attachView] 传入 SurfaceView，保持与 mpv 的 attach 语义一致。
        Log.i(TAG, "attach surface ${width}x$height（用 attachView 接管画面）")
    }

    /** SurfaceView 交给 ExoPlayer；它自己管理 Surface 生命周期。 */
    fun attachView(view: SurfaceView) {
        surfaceView = view
        player.setVideoSurfaceView(view)
    }

    override fun detach() {
        surfaceView?.let { player.clearVideoSurfaceView(it) }
        surfaceView = null
    }

    override fun load(url: String) {
        currentUrl = url
        subtitles.clear()
        chapters = if (url.contains("://")) emptyList() else Mp4Chapters.parse(File(url))
        player.setMediaItem(buildItem(url))
        player.prepare()
        player.playWhenReady = true
    }

    override fun play() {
        player.play()
    }

    override fun pause() {
        player.pause()
    }

    override fun togglePause() {
        if (player.playWhenReady) player.pause() else player.play()
    }

    override fun seekTo(positionMs: Long) {
        player.seekTo(positionMs.coerceAtLeast(0))
    }

    override fun setSpeed(speed: Float) {
        player.setPlaybackSpeed(speed)
    }

    override fun addSubtitle(path: String) {
        subtitles += MediaItem.SubtitleConfiguration.Builder(uriOf(path))
            .setMimeType(subtitleMime(path))
            .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
            .build()
        reloadKeepingPosition()
    }

    override fun selectTrack(kind: TrackKind, trackId: String) {
        val parts = trackId.split(':')
        val groupIndex = parts.getOrNull(1)?.toIntOrNull() ?: return
        val trackIndex = parts.getOrNull(2)?.toIntOrNull() ?: return
        val group = player.currentTracks.groups.getOrNull(groupIndex) ?: return
        val expected = when (kind) {
            TrackKind.VIDEO -> C.TRACK_TYPE_VIDEO
            TrackKind.AUDIO -> C.TRACK_TYPE_AUDIO
            TrackKind.SUB -> C.TRACK_TYPE_TEXT
        }
        if (group.type != expected) return
        val override = TrackSelectionOverride(group.mediaTrackGroup, trackIndex)
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setOverrideForType(override)
            .build()
    }

    override fun state(): PlaybackState {
        val duration = player.duration
        return PlaybackState(
            positionMs = player.currentPosition.coerceAtLeast(0),
            durationMs = if (duration == C.TIME_UNSET || duration < 0) 0 else duration,
            paused = !player.playWhenReady,
            speed = player.playbackParameters.speed,
            ended = player.playbackState == Player.STATE_ENDED,
        )
    }

    override fun tracks(): List<TrackInfo> {
        val out = mutableListOf<TrackInfo>()
        player.currentTracks.groups.forEachIndexed { groupIndex, group ->
            val kind = when (group.type) {
                C.TRACK_TYPE_VIDEO -> TrackKind.VIDEO
                C.TRACK_TYPE_AUDIO -> TrackKind.AUDIO
                C.TRACK_TYPE_TEXT -> TrackKind.SUB
                else -> return@forEachIndexed
            }
            for (trackIndex in 0 until group.length) {
                val format = group.getTrackFormat(trackIndex)
                out += TrackInfo(
                    id = "${group.type}:$groupIndex:$trackIndex",
                    kind = kind,
                    title = format.label
                        ?: format.language
                        ?: "${kindLabel(kind)} $trackIndex",
                    language = format.language,
                    codec = format.codecs,
                    selected = group.isTrackSelected(trackIndex),
                    external = false,
                )
            }
        }
        return out
    }

    /**
     * ExoPlayer 1.11 不解析 MP4 章节，这里自己读 `moov/udta/chpl`（见 [Mp4Chapters]）。
     * 网络 URL 暂不解析。
     */
    override fun chapters(): List<ChapterInfo> = chapters

    /** 本地文件的章节缓存；`load` 时刷新。 */
    private var chapters: List<ChapterInfo> = emptyList()

    override fun setListener(listener: PlayerEngine.Listener?) {
        this.listener = listener
        if (listener != null && !polling) {
            polling = true
            mainHandler.post(tick)
        }
    }

    override fun close() {
        polling = false
        mainHandler.removeCallbacks(tick)
        subtitles.clear()
        player.release()
    }

    private fun reloadKeepingPosition() {
        val url = currentUrl ?: return
        val position = player.currentPosition
        val wasPlaying = player.playWhenReady
        // reload 会回到默认轨道，记下当前音轨，prepare 之后恢复。
        val audio = tracks().firstOrNull { it.kind == TrackKind.AUDIO && it.selected }
        player.setMediaItem(buildItem(url), position)
        player.prepare()
        player.playWhenReady = wasPlaying
        if (audio != null) {
            // 轨道还没就绪，等 onTracksChanged 再恢复。
            pendingAudioRestore = audio.id
        }
    }

    private fun buildItem(url: String): MediaItem =
        MediaItem.Builder()
            .setUri(uriOf(url))
            .apply { if (subtitles.isNotEmpty()) setSubtitleConfigurations(subtitles) }
            .build()

    private fun uriOf(path: String): Uri =
        if (path.contains("://")) Uri.parse(path) else Uri.fromFile(File(path))

    private fun subtitleMime(path: String): String = when (path.substringAfterLast('.').lowercase()) {
        "srt" -> MimeTypes.APPLICATION_SUBRIP
        "ass", "ssa" -> MimeTypes.TEXT_SSA
        "vtt" -> MimeTypes.TEXT_VTT
        "ttml", "xml" -> MimeTypes.APPLICATION_TTML
        else -> MimeTypes.APPLICATION_SUBRIP
    }

    private fun kindLabel(kind: TrackKind): String = when (kind) {
        TrackKind.VIDEO -> "视频"
        TrackKind.AUDIO -> "音轨"
        TrackKind.SUB -> "字幕"
    }

    private companion object {
        const val TAG = "DvMedia3"
    }
}
