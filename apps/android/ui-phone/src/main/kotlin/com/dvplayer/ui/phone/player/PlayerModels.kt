package com.dvplayer.ui.phone.player

/**
 * 播放页的展示模型。
 *
 * 这一层刻意不依赖 `:core` 的 `PlaySource` / `MediaDetail`：界面要能脱离设备和网络
 * 单独预览（`@Preview`、`--es mode` 静态截图），也方便先把布局定下来再接真实数据。
 * 接核心时由 `PlayerViewModel` 做一次映射，UI 不改。
 */
data class PlayerChip(val text: String, val accent: Boolean = false)

/** 一条音轨 / 字幕。 */
data class PlayerTrack(
    val title: String,
    val detail: String,
    val selected: Boolean = false,
)

/** 媒体信息面板的「视频」一页。 */
data class VideoSheet(
    val codec: String,
    val resolution: String,
    val colorRange: String,
    val frameRate: String,
    val bitRate: String,
    val bitDepth: String,
    val engine: String,
    /** 源没给、但界面需要知道时写在这里，例如「源未提供色彩范围」。 */
    val warning: String? = null,
)

/** 媒体信息面板的「源」一页。 */
data class SourceSheet(
    val name: String,
    val kind: String,
    val direct: Boolean,
    val headers: Int,
    val resumeAtMs: Long? = null,
)

data class PlayerEpisode(
    val title: String,
    val duration: String,
    val current: Boolean = false,
)

data class PlayerUiModel(
    val title: String,
    /** 顶栏副标题：源 · 季集。 */
    val subtitle: String? = null,
    /** 竖屏下方的简介；源没给就为空。 */
    val overview: String? = null,
    /** 规格行：内核 / 动态范围 / 分辨率 / 帧率 / 码率。 */
    val chips: List<PlayerChip> = emptyList(),
    val positionMs: Long,
    val durationMs: Long,
    val bufferedMs: Long = 0,
    val paused: Boolean = false,
    val speed: Float = 1f,
    val videoAspect: Float = 16f / 9f,
    val hasNext: Boolean = false,
    val episodes: List<PlayerEpisode> = emptyList(),
    val video: VideoSheet,
    val audios: List<PlayerTrack>,
    val subtitles: List<PlayerTrack>,
    val source: SourceSheet,
) {
    val progress: Float
        get() = if (durationMs <= 0) 0f
        else (positionMs.toFloat() / durationMs).coerceIn(0f, 1f)
}

/** `1:04:07` / `04:07`。 */
fun formatTime(ms: Long): String {
    val total = (ms.coerceAtLeast(0) / 1000).toInt()
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
}

/** 静态截图 / 预览用的假数据。同一个结构以后由核心填充。 */
object PlayerDemo {

    /** 横屏：Dolby Vision P7 的电影。 */
    val film = PlayerUiModel(
        title = "小人物 2",
        subtitle = "本地冒烟 · 4K",
        overview = "一名保险经纪人在一次失败的谈判后，被卷进一场跨城的暴力追债。他只剩下一天时间，把家人从漩涡里拉出来。",
        chips = listOf(
            PlayerChip("mpv", accent = true),
            PlayerChip("DV P7"),
            PlayerChip("4K"),
            PlayerChip("23.98 fps"),
            PlayerChip("74.8 Mbps"),
        ),
        positionMs = 19 * 60_000L + 38_000L,
        durationMs = 89 * 60_000L + 24_000L,
        bufferedMs = 40 * 60_000L,
        paused = false,
        videoAspect = 2.39f,
        hasNext = false,
        video = VideoSheet(
            codec = "HEVC Main 10",
            resolution = "3840 × 2160",
            colorRange = "Dolby Vision P7 · FEL",
            frameRate = "23.98 fps",
            bitRate = "74.8 Mbps",
            bitDepth = "10 bit",
            engine = "mpv（DV 整形）",
        ),
        audios = listOf(
            PlayerTrack("国语", "DTS-HD MA 5.1", selected = true),
            PlayerTrack("英语", "AAC 2.0"),
        ),
        subtitles = listOf(
            PlayerTrack("简体中文", "PGS（图形）", selected = true),
            PlayerTrack("英语", "SRT · 外挂"),
        ),
        source = SourceSheet(
            name = "本地冒烟",
            kind = "local",
            direct = true,
            headers = 0,
            resumeAtMs = 19 * 60_000L + 38_000L,
        ),
    )

    /** 竖屏：带选集的剧集。 */
    val episode = PlayerUiModel(
        title = "漫长的季节 · 第 3 集",
        subtitle = "Emby · 第 1 季",
        overview = "桦林钢厂的老工人接连失踪，厂办司机王响追着线索，一路撞进十八年前的旧案。",
        chips = listOf(
            PlayerChip("Media3", accent = true),
            PlayerChip("HDR10"),
            PlayerChip("1080p"),
            PlayerChip("25 fps"),
        ),
        positionMs = 12 * 60_000L + 4_000L,
        durationMs = 46 * 60_000L,
        bufferedMs = 24 * 60_000L,
        paused = false,
        videoAspect = 16f / 9f,
        hasNext = true,
        episodes = (1..12).map {
            PlayerEpisode(
                title = "第 $it 集",
                duration = "46 分钟",
                current = it == 3,
            )
        },
        video = VideoSheet(
            codec = "HEVC Main 10",
            resolution = "1920 × 1080",
            colorRange = "HDR10",
            frameRate = "25 fps",
            bitRate = "18.2 Mbps",
            bitDepth = "10 bit",
            engine = "Media3（HDR10+ 动态元数据）",
            warning = "源未提供「色彩范围」，动态范围取实际输出",
        ),
        audios = listOf(
            PlayerTrack("国语", "AAC 2.0", selected = true),
        ),
        subtitles = listOf(
            PlayerTrack("简体中文", "SRT", selected = true),
            PlayerTrack("英语", "SRT · 外挂"),
        ),
        source = SourceSheet(
            name = "客厅 Emby",
            kind = "emby",
            direct = false,
            headers = 2,
            resumeAtMs = 12 * 60_000L + 4_000L,
        ),
    )
}
