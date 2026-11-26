package com.dvplayer.player

import android.content.Context

/**
 * 续播位置（A4「进度」）。按片源地址存最后一次播放位置。
 *
 * 只存本地状态，够验证「退出再进从原位置继续」；正式的记录同步走 A3 的库数据层。
 */
class PlaybackMemory(context: Context) {

    private val prefs =
        context.applicationContext.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)

    fun position(url: String): Long = prefs.getLong(key(url), 0L)

    fun save(url: String, positionMs: Long, durationMs: Long) {
        if (durationMs <= 0) return
        // 播到片尾附近就把记录清掉，下次从头开始。
        if (positionMs >= durationMs - END_MARGIN_MS) {
            prefs.edit().remove(key(url)).apply()
        } else {
            prefs.edit().putLong(key(url), positionMs).apply()
        }
    }

    fun clear(url: String) {
        prefs.edit().remove(key(url)).apply()
    }

    private fun key(url: String): String = "pos:$url"

    private companion object {
        const val PREF_NAME = "dvplayer_playback"
        const val END_MARGIN_MS = 5_000L
    }
}
