package com.dvplayer.player.media3

import android.content.Context
import android.net.Uri
import android.util.Log
import android.view.SurfaceView
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener

/**
 * Media3（ExoPlayer）内核的最小封装，和 [com.dvplayer.player.mpv.MpvPlayer] 对齐。
 *
 * Media3 的价值在 HDR：平台 MediaCodec 从 SEI 里解析出 HDR10+（ST2094-40）动态
 * 元数据，随 output buffer 交给 SurfaceFlinger / HWC。mpv 走 EGL 没有公开的写入
 * 接口，所以 HDR10+ 只能在这个内核里真正生效。
 *
 * 注意：ExoPlayer 的 [Format] 里没有 HDR10+ 的动态载荷（那是每帧的），要验证
 * 解码器输出格式请用 [Hdr10PlusProbe]。
 */
@UnstableApi
class Media3Player(context: Context) : AutoCloseable {

    private val player: ExoPlayer = ExoPlayer.Builder(context).build()

    /** 视频轨的 [Format]（含 colorInfo），用于验证页显示。 */
    var videoFormat: Format? = null
        private set

    var onEvent: ((String) -> Unit)? = null

    init {
        player.addAnalyticsListener(object : AnalyticsListener {
            override fun onVideoInputFormatChanged(
                eventTime: AnalyticsListener.EventTime,
                format: Format,
                decoderReuseEvaluation: androidx.media3.exoplayer.DecoderReuseEvaluation?,
            ) {
                videoFormat = format
                Log.i(TAG, "video format: $format")
                onEvent?.invoke("video format: ${format.codecs} ${format.width}x${format.height}")
            }

            override fun onPlayerError(eventTime: AnalyticsListener.EventTime, error: PlaybackException) {
                Log.e(TAG, "playback error", error)
                onEvent?.invoke("error: ${error.errorCodeName}")
            }

            override fun onRenderedFirstFrame(eventTime: AnalyticsListener.EventTime, output: Any, renderTimeMs: Long) {
                Log.i(TAG, "first frame rendered")
                onEvent?.invoke("first frame")
            }
        })
    }

    fun attach(surfaceView: SurfaceView) {
        player.setVideoSurfaceView(surfaceView)
    }

    fun play(url: String) {
        player.setMediaItem(MediaItem.fromUri(Uri.parse(url)))
        player.prepare()
        player.playWhenReady = true
    }

    fun playWhenReady(ready: Boolean) {
        player.playWhenReady = ready
    }

    fun currentPositionMs(): Long = player.currentPosition

    fun isPlaying(): Boolean = player.isPlaying

    fun videoSize(): String {
        val v = player.videoSize
        return "${v.width}x${v.height}"
    }

    override fun close() {
        player.release()
    }

    private companion object {
        const val TAG = "DvMedia3"
    }
}
