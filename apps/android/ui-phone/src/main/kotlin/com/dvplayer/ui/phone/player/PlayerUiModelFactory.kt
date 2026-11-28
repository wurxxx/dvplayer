package com.dvplayer.ui.phone.player

import com.dvplayer.core.MediaDetail
import com.dvplayer.core.MediaInfo
import com.dvplayer.core.PlaySource

/**
 * 把共享核心的 [MediaDetail] / [PlaySource] / [MediaInfo] 映射成播放页的展示模型。
 *
 * 播放页本身不碰核心类型：所有「空字符串 / 缺字段」的处理集中在这里，
 * 界面只处理已经规整过的字符串。各家源（本地、飞牛、Emby、Jellyfin）字段
 * 完整度差别很大，映射时缺什么就如实写「未提供」，不要编。
 */
object PlayerUiModelFactory {

    fun from(
        detail: MediaDetail?,
        play: PlaySource,
        info: MediaInfo?,
        /** 源显示名（「客厅 Emby」）；拿不到就用 sourceId。 */
        sourceName: String,
        sourceKind: String,
        /** 顶栏副标题，如「第 1 季」；由调用方按条目拼。 */
        subtitle: String? = null,
        engine: String = "mpv",
        /** 菜单 / 媒体信息里对内核的补充，如「DV 整形」。 */
        engineNote: String? = null,
        episodes: List<PlayerEpisode> = emptyList(),
        hasNext: Boolean = false,
    ): PlayerUiModel {
        val video = info?.video
        val overview = play.overview?.ifBlank { null } ?: detail?.overview?.ifBlank { null }
        val durationMs = (play.durationSeconds.coerceAtLeast(0) * 1000)
            .takeIf { it > 0 }
            ?: (detail?.runtimeSeconds ?: 0) * 1000
        val positionMs = play.positionSeconds.coerceAtLeast(0) * 1000

        return PlayerUiModel(
            title = play.title.ifBlank { detail?.title.orEmpty().ifBlank { "未命名" } },
            subtitle = subtitle,
            overview = overview,
            chips = chips(engine, play, video),
            positionMs = positionMs.coerceAtMost(durationMs.coerceAtLeast(positionMs)),
            durationMs = durationMs,
            bufferedMs = 0,
            paused = false,
            speed = 1f,
            videoAspect = aspect(video),
            hasNext = hasNext,
            episodes = episodes,
            video = VideoSheet(
                codec = listOfNotNull(video?.codec, video?.profile).joinToString(" ")
                    .ifBlank { "未提供" },
                resolution = resolution(video) ?: "未提供",
                colorRange = colorRange(play, video) ?: "未提供",
                frameRate = frameRate(video?.frameRate) ?: "未提供",
                bitRate = bitRate(video?.bitRate) ?: "未提供",
                bitDepth = video?.bitDepth?.let { "$it bit" } ?: "未提供",
                engine = engineNote?.let { "$engine（$it）" } ?: engine,
                warning = if (colorRange(play, video) == null) {
                    "源未提供「色彩范围」，动态范围以设备实际输出为准"
                } else {
                    null
                },
            ),
            audios = audioTracks(play, info),
            subtitles = subtitleTracks(play, info),
            source = SourceSheet(
                name = sourceName,
                kind = sourceKind,
                direct = play.isDirect,
                headers = play.headers.size,
                resumeAtMs = positionMs.takeIf { it > 5_000 },
            ),
        )
    }

    // —— 规格行 ——

    private fun chips(engine: String, play: PlaySource, video: com.dvplayer.core.VideoInfo?): List<PlayerChip> =
        buildList {
            add(PlayerChip(engine, accent = true))
            colorRange(play, video)?.let { add(PlayerChip(shortColorRange(it))) }
            shortResolution(video)?.let { add(PlayerChip(it)) }
            frameRate(video?.frameRate)?.let { add(PlayerChip(it)) }
            bitRate(video?.bitRate)?.let { add(PlayerChip(it)) }
        }

    /** 动态范围优先取详细探测结果，其次播放源自带的标记。 */
    private fun colorRange(play: PlaySource, video: com.dvplayer.core.VideoInfo?): String? {
        val raw = video?.colorRange?.ifBlank { null }
            ?: play.colorRange?.ifBlank { null }
        if (raw != null) return raw
        return if (play.dolbyVision || video?.dolbyVision == true) "Dolby Vision" else null
    }

    private fun shortColorRange(raw: String): String = when {
        raw.contains("dolby", ignoreCase = true) -> "DV"
        raw.contains("hdr10+", ignoreCase = true) -> "HDR10+"
        raw.contains("hdr10", ignoreCase = true) -> "HDR10"
        raw.contains("hlg", ignoreCase = true) -> "HLG"
        raw.contains("sdr", ignoreCase = true) -> "SDR"
        else -> raw
    }

    private fun shortResolution(video: com.dvplayer.core.VideoInfo?): String? {
        val w = video?.width ?: return null
        val h = video?.height ?: return null
        return when {
            w >= 3600 -> "4K"
            w >= 2400 -> "2K"
            w >= 1800 -> "1080p"
            w >= 1200 -> "720p"
            else -> "${w}×${h}"
        }
    }

    private fun resolution(video: com.dvplayer.core.VideoInfo?): String? {
        val w = video?.width
        val h = video?.height
        return if (w != null && h != null) "$w × $h" else null
    }

    private fun frameRate(fps: Double?): String? {
        if (fps == null || fps <= 0) return null
        val text = "%.2f".format(fps).trimEnd('0').trimEnd('.')
        return "$text fps"
    }

    private fun bitRate(rate: Long?): String? {
        if (rate == null || rate <= 0) return null
        return "%.1f Mbps".format(rate / 1_000_000.0)
    }

    private fun aspect(video: com.dvplayer.core.VideoInfo?): Float {
        val w = video?.width ?: return 16f / 9f
        val h = video?.height ?: return 16f / 9f
        return if (w > 0 && h > 0) w.toFloat() / h.toFloat() else 16f / 9f
    }

    // —— 音轨 / 字幕 ——

    private fun audioTracks(play: PlaySource, info: MediaInfo?): List<PlayerTrack> {
        val detailed = info?.audios.orEmpty()
        if (detailed.isNotEmpty()) {
            val defaultIndex = detailed.indexOfFirst { it.isDefault }
                .let { if (it >= 0) it else 0 }
            return detailed.mapIndexed { index, track ->
                PlayerTrack(
                    title = languageLabel(track.language)
                        ?: track.title?.ifBlank { null }
                        ?: "音轨 ${index + 1}",
                    detail = listOfNotNull(
                        track.codec,
                        track.profile,
                        channelsLabel(track.channels),
                        track.layout,
                    ).distinct().joinToString(" ").ifBlank { "未提供" },
                    selected = index == defaultIndex,
                )
            }
        }

        val streams = play.audioStreams
        if (streams.isEmpty()) return emptyList()
        val chosen = play.audioGuid
        return streams.mapIndexed { index, track ->
            PlayerTrack(
                title = languageLabel(track.language) ?: "音轨 ${index + 1}",
                detail = listOfNotNull(
                    track.codec,
                    track.profile,
                    channelsLabel(track.channels),
                ).distinct().joinToString(" ").ifBlank { "未提供" },
                selected = when {
                    chosen != null -> track.guid == chosen
                    else -> track.isDefault || index == 0
                },
            )
        }
    }

    private fun subtitleTracks(play: PlaySource, info: MediaInfo?): List<PlayerTrack> {
        val detailed = info?.subtitles.orEmpty()
        val tracks = if (detailed.isNotEmpty()) {
            val defaultIndex = detailed.indexOfFirst { it.isDefault }
            detailed.mapIndexed { index, track ->
                PlayerTrack(
                    title = languageLabel(track.language)
                        ?: track.title?.ifBlank { null }
                        ?: "字幕 ${index + 1}",
                    detail = subtitleDetail(track.format, track.codec, track.isBitmap, track.isExternal),
                    selected = index == defaultIndex,
                )
            }
        } else {
            val streams = play.subtitleStreams
            val chosen = play.subtitleGuid
            streams.mapIndexed { index, track ->
                PlayerTrack(
                    title = languageLabel(track.language) ?: "字幕 ${index + 1}",
                    detail = subtitleDetail(track.format, track.codec, track.isBitmap, track.isExternal),
                    selected = chosen != null && track.guid == chosen,
                )
            }
        }

        // 字幕面板第一项永远是「关闭」；没有选中轨时它就是选中项。
        val hasSelected = tracks.any { it.selected }
        return listOf(
            PlayerTrack("关闭字幕", "不显示", selected = !hasSelected),
        ) + tracks
    }

    private fun subtitleDetail(format: String?, codec: String?, bitmap: Boolean, external: Boolean): String =
        buildList {
            add(format?.ifBlank { codec } ?: codec ?: "未提供")
            if (bitmap) add("图形")
            if (external) add("外挂")
        }.joinToString(" · ")

    private fun channelsLabel(channels: Int?): String? = when (channels) {
        null, 0 -> null
        1 -> "1.0"
        2 -> "2.0"
        6 -> "5.1"
        8 -> "7.1"
        else -> "${channels}ch"
    }

    private fun languageLabel(code: String?): String? {
        val key = code?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        return when (key.take(3)) {
            "chi", "zho", "zhs", "zht" -> "中文"
            "eng" -> "英语"
            "jpn" -> "日语"
            "kor" -> "韩语"
            "fra", "fre" -> "法语"
            "deu", "ger" -> "德语"
            "spa" -> "西班牙语"
            "rus" -> "俄语"
            "ita" -> "意大利语"
            "por" -> "葡萄牙语"
            "und" -> null
            else -> code
        }
    }
}
