package com.dvplayer.core.vfs

/**
 * HTTP `Range` 头的解析（A9 桥接）。
 *
 * 单测价值在边界：后缀范围（`bytes=-65536`）、超出文件、开放结尾、
 * 非法单位、越界起点。播放器 seek 时会一次发很多个范围，解析错一个就会
 * 读到错误偏移、画面花屏或直接卡死。
 *
 * 解析结果区分三种：正常片段、要全量、不可满足（调用方回 416）。
 */
internal sealed interface ByteRange {
    /** 闭区间，`start <= end` 且都在文件内。 */
    data class Partial(val start: Long, val end: Long) : ByteRange

    /** 没有 Range 头、或单位不认识：回 200 全量。 */
    data object Full : ByteRange

    /** 合法的 `bytes=` 但落在文件外：回 416。 */
    data object Unsatisfiable : ByteRange
}

private val BYTES_RANGE = Regex("""^\s*bytes=(\d*)-(\d*)\s*$""", RegexOption.IGNORE_CASE)

internal fun parseByteRange(header: String?, size: Long): ByteRange {
    if (size <= 0) return ByteRange.Unsatisfiable
    if (header.isNullOrBlank()) return ByteRange.Full

    val match = BYTES_RANGE.matchEntire(header) ?: return ByteRange.Full
    val first = match.groupValues[1]
    val second = match.groupValues[2]
    if (first.isEmpty() && second.isEmpty()) return ByteRange.Full

    // 后缀形式 bytes=-N：最后 N 字节。
    if (first.isEmpty()) {
        val suffix = second.toLongOrNull() ?: return ByteRange.Unsatisfiable
        if (suffix <= 0) return ByteRange.Unsatisfiable
        val start = (size - suffix).coerceAtLeast(0)
        return ByteRange.Partial(start, size - 1)
    }

    val start = first.toLongOrNull() ?: return ByteRange.Unsatisfiable
    if (start >= size) return ByteRange.Unsatisfiable
    val requestedEnd = if (second.isEmpty()) size - 1 else {
        second.toLongOrNull() ?: return ByteRange.Unsatisfiable
    }
    if (requestedEnd < start) return ByteRange.Unsatisfiable
    return ByteRange.Partial(start, minOf(requestedEnd, size - 1))
}
