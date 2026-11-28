package com.dvplayer.player

import android.media.MediaExtractor
import android.media.MediaFormat

/**
 * 起播前读容器里的视频帧率。
 *
 * `FrameRateMatcher` 原来只能在 mpv 加载后读 `container-fps`，第一次轮询已经
 * 是起播 1 秒后——显示模式还没切，头几帧就丢在默认刷新率上了。这里在 `load`
 * 之前用 `MediaExtractor` 读一次容器元数据（不解码），把模式先钉住。
 *
 * 只覆盖本地普通文件：HTTP / SMB 桥接地址交给加载后的轮询，原盘没有普通视频轨。
 */
object FrameRateProbe {

    fun probe(path: String): Double? = runCatching {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(path)
            for (i in 0 until ex.trackCount) {
                val format = ex.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/")) continue
                return@runCatching frameRate(format)
            }
            null
        } finally {
            ex.release()
        }
    }.getOrNull()

    private fun frameRate(format: MediaFormat): Double? {
        if (!format.containsKey(MediaFormat.KEY_FRAME_RATE)) return null
        return runCatching {
            format.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble()
        }.getOrElse {
            runCatching { format.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble() }.getOrNull()
        }
    }
}
