package com.dvplayer.ui.phone.ui

/**
 * 标题清洗，规则照 macOS 的 `MediaText.clean` 加一点文件名的处理：
 *
 * - 点 / 下划线 / 方括号当作分隔符；
 * - 丢掉发布标签（`2160p`、`BluRay`、`x265`…）；
 * - 去掉结尾的 `(2014)` 之类年份；
 *
 * 源没刮削时 `title` 就是一整串文件名（`露露洛洛.Bear's.school.S02.2014.1080p...`），
 * 直接摆到 hero 上看不得。刮削好的标题不含这些词，清洗前后保持不变。
 */
fun cleanTitle(raw: String?): String {
    val text = raw?.trim().orEmpty()
    if (text.isEmpty()) return ""

    // macOS 的两条通用规则：去掉「 - S01」这种尾巴、去掉「（57 集）」。
    var base = text
        .replace(Regex("\\s+-\\s+[A-Za-z0-9@]+$"), "")
        .replace(Regex("\\s*[（(]\\s*\\d{1,4}\\s*集\\s*[)）]"), "")
        .trim()
    if (base.isEmpty()) base = text

    // 普通标题原样返回：只有「一看就是文件名」的串才去拆点、丢发布标签。
    // 否则「流浪地球2.0」会被拆成「流浪地球2 0」。
    val releaseWord = base.split(Regex("\\s+")).any { isReleaseWord(it) }
    val dotCount = base.count { it == '.' }
    if (!releaseWord && dotCount < 2) return base

    val replaced = buildString(base.length) {
        for (c in base) {
            append(
                when (c) {
                    '.', '_', '【', '】', '[', ']' -> ' '
                    else -> c
                },
            )
        }
    }

    val words = replaced.split(Regex("\\s+")).filter { it.isNotBlank() && !isReleaseWord(it) }
    if (words.isEmpty()) return base

    // 季 / 集号后面都是发布尾巴（`S02 2014 KKTV`）；剧名本身不会带一个独立的 Sxx。
    val seasonAt = words.indexOfFirst { SEASON_START.matches(it) }
    val head = if (seasonAt > 0) words.take(seasonAt) else words

    var cleaned = head.joinToString(" ").trim()

    // 结尾孤零零的四位年份：「某剧 2014」→「某剧」。
    val last = cleaned.substringAfterLast(' ')
    if (last.length == 4 && last.all { it.isDigit() } && last.toInt() in 1900..2100) {
        cleaned = cleaned.substringBeforeLast(' ', missingDelimiterValue = "")
    }

    // 「电影 (2014)」这种结尾年份括号。
    val open = maxOf(cleaned.lastIndexOf(" ("), cleaned.lastIndexOf("（"))
    if (open > 0) {
        val tail = cleaned.substring(open)
        if (tail.contains(')') || tail.contains('）')) {
            val digits = tail.count { it.isDigit() }
            if (digits == 4) cleaned = cleaned.substring(0, open).trim()
        }
    }

    return cleaned.ifBlank { base }
}

private fun isReleaseWord(word: String): Boolean {
    val lower = word.lowercase()
    if (lower in RELEASE_WORDS) return true
    return lower.startsWith("ddp") ||
        lower.startsWith("aac") ||
        lower.startsWith("x26") ||
        lower.startsWith("h26") ||
        lower.startsWith("dts")
}

private val SEASON_START = Regex("^[Ss]\\d{1,2}([Ee]\\d{1,4})?$")

private val RELEASE_WORDS = setOf(
    "2160p", "1080p", "720p", "480p", "4k", "8k", "uhd", "bluray", "blu-ray", "bdrip",
    "remux", "webrip", "web-dl", "webdl", "web", "hdtv", "dvdrip", "hdr", "hdr10", "hdr10+",
    "dv", "dovi", "sdr", "x264", "x265", "h264", "h265", "hevc", "avc", "10bit", "8bit",
    "aac", "ac3", "eac3", "ddp", "dd", "dts", "dtshd", "truehd", "atmos", "flac", "proper",
    "repack", "internal", "extended", "uncut", "remastered", "imax", "hmax", "60fps",
)
