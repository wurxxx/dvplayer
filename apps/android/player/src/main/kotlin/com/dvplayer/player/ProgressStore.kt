package com.dvplayer.player

/**
 * 播放进度的存储契约。正式实现是 [PlaybackMemory]（SharedPreferences），
 * 单测里换成内存实现，不用构造 `Context`。
 */
interface ProgressStore {
    fun position(url: String): Long
    fun save(url: String, positionMs: Long, durationMs: Long)
}
