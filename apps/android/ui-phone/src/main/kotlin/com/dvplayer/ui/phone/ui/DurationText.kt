package com.dvplayer.ui.phone.ui

/**
 * 片长 / 剩余时长的中文写法：「1 小时 39 分钟」。
 *
 * 照 macOS 的 `MediaText.runtime`：
 * - 不满一小时只写「39 分钟」；
 * - 整整一小时不补「0 分钟」；
 * - 秒数按最近的分钟取整（(秒 + 30) / 60），和桌面版一致。
 *
 * 播放页的进度、剩余时间码不走这里（那是时间点，用 01:39 更好读）。
 */
fun runtimeLabel(seconds: Long?): String? {
    if (seconds == null || seconds <= 0) return null
    val minutes = ((seconds + 30) / 60).toInt()
    if (minutes >= 60) {
        val hours = minutes / 60
        val rest = minutes % 60
        return if (rest > 0) "$hours 小时 $rest 分钟" else "$hours 小时"
    }
    return "$minutes 分钟"
}

/** [runtimeLabel] 的 Int 版本（详情 / 记录里的字段是 Int）。 */
fun runtimeLabel(seconds: Int?): String? = runtimeLabel(seconds?.toLong())
