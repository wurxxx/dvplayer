package com.dvplayer.player.media3

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import android.view.Surface

/**
 * 直连平台解码器，确认它是否把 HDR10+（SMPTE ST 2094-40）的动态元数据放进
 * **输出格式**（`MediaFormat.KEY_HDR10_PLUS_INFO`，`"hdr10-plus-info"`）。
 *
 * 这是 mpv / EGL 拿不到的那一段：MediaCodec 从 HEVC SEI 里解析出 ST2094-40，
 * 挂在 output buffer / output format 上，显示端据此做逐帧 tone mapping。
 *
 * ExoPlayer 的 [androidx.media3.common.Format] 看不到它（那是每帧的），所以
 * 单独用这个探针验证，和 Media3 播放互不干扰。
 */
object Hdr10PlusProbe {

    private const val TAG = "DvHdr10Plus"

    data class Result(
        val mime: String,
        val hasHdr10Plus: Boolean,
        val hdr10PlusBytes: Int,
        val outputFormat: String,
        val frames: Int,
    )

    /**
     * 解码 [maxFrames] 帧。[surface] 非空时同时把帧送显示端（验证 HDR 出画）。
     * 失败或没有视频轨返回 null。
     */
    fun probe(
        url: String,
        surface: Surface? = null,
        maxFrames: Int = 30,
        timeoutMs: Long = 10_000,
    ): Result? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(url)
            var track = -1
            var inputFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) {
                    track = i
                    inputFormat = f
                    break
                }
            }
            if (track < 0 || inputFormat == null) {
                Log.w(TAG, "没有视频轨: $url")
                return null
            }
            extractor.selectTrack(track)

            val mime = inputFormat.getString(MediaFormat.KEY_MIME)!!
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(inputFormat, surface, null, 0)
            codec.start()
            Log.i(TAG, "input format: $inputFormat")

            var hasHdr10Plus = false
            var hdr10PlusBytes = 0
            var outputFormatDump = ""
            var frames = 0
            val info = MediaCodec.BufferInfo()
            val deadline = System.currentTimeMillis() + timeoutMs

            while (frames < maxFrames && System.currentTimeMillis() < deadline) {
                val inIndex = codec.dequeueInputBuffer(10_000)
                if (inIndex >= 0) {
                    val buffer = codec.getInputBuffer(inIndex)!!
                    val size = extractor.readSampleData(buffer, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(
                            inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                        )
                    } else {
                        codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }

                when (val outIndex = codec.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val out = codec.outputFormat
                        outputFormatDump = out.toString()
                        hasHdr10Plus = out.containsKey(MediaFormat.KEY_HDR10_PLUS_INFO)
                        if (hasHdr10Plus) {
                            hdr10PlusBytes =
                                out.getByteBuffer(MediaFormat.KEY_HDR10_PLUS_INFO)?.remaining() ?: 0
                        }
                        Log.i(TAG, "output format: $outputFormatDump")
                        Log.i(TAG, "hdr10-plus-info: $hasHdr10Plus ($hdr10PlusBytes bytes)")
                    }

                    MediaCodec.INFO_TRY_AGAIN_LATER, MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit

                    else -> if (outIndex >= 0) {
                        codec.releaseOutputBuffer(outIndex, surface != null)
                        frames++
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                    }
                }
            }

            return Result(mime, hasHdr10Plus, hdr10PlusBytes, outputFormatDump, frames)
        } catch (t: Throwable) {
            Log.e(TAG, "探针失败", t)
            return null
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            runCatching { extractor.release() }
        }
    }
}
