package com.dvplayer.ui.phone.player

/**
 * 播放页的展示模型。
 *
 * 这一层刻意不依赖 `:core` 的 `PlaySource` / `MediaDetail`：界面要能脱离设备和网络
 * 单独预览（`@Preview`、`--es mode` 静态截图），也方便先把布局定下来再接真实数据。
 * 接核心时由 `PlayerViewModel` 做一次映射，UI 不改。
 */
data class PlayerChip(val text: String, val accent: Boolean = false)

/**
 * 画面比例模式。
 *
 * - [Fit]：按视频自身比例放进屏幕，多出的留黑（默认，横屏片上下留黑）
 * - [Fill]：裁边铺满屏幕（短剧竖屏用）
 * - [Stretch]：拉伸铺满，不裁边（变形画面 / 老片）
 * - [Ratio16x9] / [Ratio4x3]：强制某个比例
 */
enum class PlayerAspect(val label: String) {
    Fit("适应"),
    Fill("填充"),
    Stretch("拉伸"),
    Ratio16x9("16:9"),
    Ratio4x3("4:3");

    /** 该模式下视频区的目标宽高比；null 表示跟随视频自身。 */
    val forcedAspect: Float?
        get() = when (this) {
            Fit, Fill -> null
            Stretch -> null
            Ratio16x9 -> 16f / 9f
            Ratio4x3 -> 4f / 3f
        }

    fun next(): PlayerAspect = entries[(ordinal + 1) % entries.size]
}

/** 一条音轨 / 字幕。 */
data class PlayerTrack(
    val title: String,
    val detail: String,
    val selected: Boolean = false,
    /** 内核轨道 id（mpv 的 aid / Media3 的轨道 id）；空表示只有展示数据。 */
    val id: String = "",
)

/**
 * 真内核推给界面的播放状态。
 *
 * 传 null 时播放页用 [PlayerUiModel] 里的静态值（预览 / 截图）；
 * 传入后位置、时长、暂停、倍速都以这里为准。
 */
data class PlayerPlaybackState(
    val positionMs: Long,
    val durationMs: Long,
    val paused: Boolean,
    val speed: Float = 1f,
    val ended: Boolean = false,
    val bufferedMs: Long = 0,
    /** 内核名（mpv / Media3），覆盖规格行第一个 chip。 */
    val engine: String? = null,
    /** 是不是硬解；内核还没报时为 null（规格行不显示 HW/SW）。 */
    val hardwareDecode: Boolean? = null,
    /** 视频编码（hevc / h264 …），规格行接在内核后面。 */
    val videoCodec: String? = null,
    val audios: List<PlayerTrack> = emptyList(),
    val subtitles: List<PlayerTrack> = emptyList(),
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
    /** 条目 id：选集时用它换片；预览数据里为空。 */
    val id: String? = null,
    /** 「第 3 集」。 */
    val title: String,
    val duration: String,
    val current: Boolean = false,
    /** 分集名（「化天药阵」）；源没给就为空，卡片上退化成时长。 */
    val subtitle: String? = null,
    /**
     * 剧照路径（核心路径，不是 URL）。播放 Activity 用
     * `PhoneRepository.bitmap()` 换成位图；为空时卡片画一个深色占位。
     */
    val stillPath: String? = null,
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
        episodes = listOf(
            "桦林钢厂", "失踪的工人", "十八年前", "旧案重提",
            "王响的执念", "一辆出租车", "冬天的河", "沉默的证人",
            "破碎的时间线", "真相一角", "最后一个人", "漫长的季节",
        ).mapIndexed { index, name ->
            PlayerEpisode(
                title = "第 ${index + 1} 集",
                duration = "46 分钟",
                current = index == 2,
                subtitle = name,
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

/** 编码名压短：hevc → HEVC，avc1 → H.264（规格行放得下）。 */
fun shortCodecName(raw: String): String {
    val v = raw.trim().lowercase()
    return when {
        v.isEmpty() -> return raw
        "hevc" in v || "h265" in v || "h.265" in v -> "HEVC"
        "av01" in v || "av1" in v -> "AV1"
        "vp9" in v -> "VP9"
        "vp8" in v -> "VP8"
        "avc" in v || "h264" in v || "h.264" in v -> "H.264"
        else -> raw.trim().uppercase()
    }
}
