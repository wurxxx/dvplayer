package com.dvplayer.ui.phone.data

import android.content.Context

/**
 * 音轨 / 字幕偏好。
 *
 * 详情页选一次，播放页起播时自动应用（PlaybackSession 在拿到轨道列表后选上）。
 * -1 表示没选过，交给播放器自己决定。
 */
object TrackPrefs {
    private const val FILE = "dv_tracks"
    private const val KEY_AUDIO = "audio_index"
    private const val KEY_SUB = "subtitle_index"

    /** 字幕「关闭」：-1 是没选过（播放器默认），-2 才是用户明确关掉。 */
    const val SUBTITLE_OFF = -2

    private fun prefs(context: Context) =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun audioIndex(context: Context): Int = prefs(context).getInt(KEY_AUDIO, -1)

    fun setAudioIndex(context: Context, index: Int) {
        prefs(context).edit().putInt(KEY_AUDIO, index).apply()
    }

    fun subtitleIndex(context: Context): Int = prefs(context).getInt(KEY_SUB, -1)

    fun setSubtitleIndex(context: Context, index: Int) {
        prefs(context).edit().putInt(KEY_SUB, index).apply()
    }
}
