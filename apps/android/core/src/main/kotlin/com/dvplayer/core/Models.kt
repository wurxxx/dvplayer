package com.dvplayer.core

import kotlinx.serialization.Serializable

/**
 * 与 `core/media`（Rust）一一对应的模型。
 *
 * 命名规则和桌面端一致：Rust 侧 `#[serde(rename_all = "camelCase")]`，
 * 所以 Kotlin 属性名就是 JSON 键名，不需要 `@SerialName`。
 * 加字段时两边要同时改——这些结构是 C ABI 的实际契约。
 */

/** 统一响应外壳。 */
@Serializable
data class CoreEnvelope<T>(
    val ok: Boolean,
    val data: T? = null,
    val error: String? = null,
    val code: Long? = null,
)

/** `dv_source_create` / `dv_hub_add` 的入参。 */
@Serializable
data class SourceConfig(
    val id: String,
    val name: String,
    /** `fnos` / `emby` / `jellyfin` / `local`。 */
    val kind: String,
    val base: String,
    val username: String = "",
    val password: String = "",
    /** 本地源的进度 / 缓存放这里。 */
    val dataDir: String = "",
    val proxy: String = "",
)

/** 已连接的源。 */
@Serializable
data class SourceInfo(
    val id: String,
    val name: String,
    val kind: String,
)

/** 并行建连的单个结果。 */
@Serializable
data class SourceConnection(
    val id: String,
    val name: String,
    val kind: String,
    val ok: Boolean,
    val error: String? = null,
    /** 建连（含登录）耗时。 */
    val ms: Long = 0,
    /** 网络往返延迟；本地目录与探测失败时没有。 */
    val latencyMs: Long? = null,
)

@Serializable
data class MediaLibrary(
    val id: String,
    val title: String,
    val sourceId: String,
    val posterPath: String? = null,
    val category: String = "",
)

/**
 * 统一媒体条目。
 *
 * `kind` 保留为字符串（`movie` / `series` / `season` / `episode` / `folder` / `video` /
 * `unknown`），这样服务端以后加新类型不会把反序列化炸掉。
 */
@Serializable
data class MediaItem(
    val id: String,
    val title: String,
    val kind: String,
    val sourceId: String,
    val posterPath: String? = null,
    val parentId: String? = null,
    val parentTitle: String? = null,
    val year: Int? = null,
    val runtimeSeconds: Long? = null,
    /** 已看进度 0..1。 */
    val progress: Double = 0.0,
    val isFavorite: Boolean = false,
    val overview: String? = null,
    val resolution: String? = null,
    /** 上次观看（unix 秒）。 */
    val lastPlayed: Long? = null,
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    val episodeCount: Int? = null,
    val localEpisodeCount: Int? = null,
    val seasonCount: Int? = null,
    val rating: Double? = null,
    val releaseDate: String? = null,
    val status: String? = null,
    val backdropPath: String? = null,
    val singleChildId: String? = null,
    /** 同一部片在各源的条目；只有聚合搜索会填。 */
    val sources: List<ItemSource> = emptyList(),
) {
    val isPlayable: Boolean
        get() = kind == "movie" || kind == "episode" || kind == "video"
}

@Serializable
data class ItemSource(
    val itemId: String,
    val sourceId: String,
    val sourceName: String,
    val resolution: String? = null,
    val progress: Double = 0.0,
)

/** 聚合搜索：去重后的条目 + 没响应的源。 */
@Serializable
data class SearchResult(
    val items: List<MediaItem> = emptyList(),
    val failed: List<SourceFailure> = emptyList(),
)

/** 搜索时超时 / 报错的源。 */
@Serializable
data class SourceFailure(
    val sourceId: String,
    val sourceName: String,
    val error: String,
)

@Serializable
data class Page<T>(
    val items: List<T> = emptyList(),
    val total: Long = 0,
    val page: Int = 1,
    val pageSize: Int = 0,
) {
    val hasMore: Boolean get() = page.toLong() * pageSize.toLong() < total
}

/** 列表筛选 / 排序；字段都是可选的。 */
@Serializable
data class ListQuery(
    val kinds: List<String> = emptyList(),
    val genre: String? = null,
    /** `name` / `added` / `release` / `rating`。 */
    val sort: String? = null,
    val descending: Boolean = false,
)

@Serializable
data class PlayRecord(
    val itemId: String,
    val title: String,
    val sourceId: String,
    val seriesTitle: String? = null,
    val parentId: String? = null,
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    val posterPath: String? = null,
    val positionSeconds: Long = 0,
    val durationSeconds: Long = 0,
    val lastPlayed: Long? = null,
) {
    val progress: Double
        get() = if (durationSeconds == 0L) 0.0
        else (positionSeconds.toDouble() / durationSeconds).coerceIn(0.0, 1.0)
}

@Serializable
data class HttpHeader(val name: String, val value: String)

@Serializable
data class AudioTrack(
    val guid: String,
    val language: String? = null,
    val codec: String? = null,
    val profile: String? = null,
    val channels: Int = 0,
    val isDefault: Boolean = false,
)

@Serializable
data class SubtitleTrack(
    val guid: String,
    val language: String? = null,
    val codec: String? = null,
    val format: String? = null,
    val isExternal: Boolean = false,
    val isBitmap: Boolean = false,
    /** 外挂字幕的下载地址（服务端拼好）；请求头用 [PlaySource.headers]。 */
    val url: String? = null,
)

/** 实际交给播放器的地址：URL + 必须带上的头。 */
@Serializable
data class PlaySource(
    val itemId: String,
    val title: String = "",
    val url: String,
    val headers: List<HttpHeader> = emptyList(),
    val isDirect: Boolean = false,
    /** 原盘（ISO / 蓝光目录）：界面要走挂载或 libbluray。 */
    val disc: Boolean = false,
    val mediaGuid: String = "",
    val videoGuid: String? = null,
    val audioGuid: String? = null,
    val subtitleGuid: String? = null,
    val positionSeconds: Long = 0,
    val durationSeconds: Long = 0,
    val overview: String? = null,
    val posterPath: String? = null,
    val resolution: String? = null,
    /** HDR10 / HDR10+ / HLG / DV；空表示 SDR。 */
    val colorRange: String? = null,
    val dolbyVision: Boolean = false,
    val videoCodec: String? = null,
    val audioCodec: String? = null,
    val audioStreams: List<AudioTrack> = emptyList(),
    val subtitleStreams: List<SubtitleTrack> = emptyList(),
    val proxy: String = "",
)

@Serializable
data class ImageSource(
    val url: String,
    val headers: List<HttpHeader> = emptyList(),
    val proxy: String = "",
)

@Serializable
data class MediaDetail(
    val id: String,
    val title: String,
    val kind: String,
    val originalTitle: String? = null,
    val overview: String? = null,
    val posterPath: String? = null,
    val backdropPath: String? = null,
    val logoPath: String? = null,
    val rating: Double? = null,
    val releaseDate: String? = null,
    val runtimeSeconds: Long? = null,
    val seasonCount: Int? = null,
    val localSeasonCount: Int? = null,
    val episodeCount: Int? = null,
    val localEpisodeCount: Int? = null,
    val status: String? = null,
    val resolution: String? = null,
    val audioType: String? = null,
    val colorRange: String? = null,
    /** 「继续观看」该播哪个条目（剧集里是某一集）。 */
    val playItemId: String? = null,
    val singleChildId: String? = null,
    val isFavorite: Boolean? = null,
    val isWatched: Boolean? = null,
    val tmdbId: String? = null,
    val imdbId: String? = null,
)

@Serializable
data class Genre(val id: String, val title: String)

@Serializable
data class Person(
    val id: String = "",
    val name: String,
    val role: String? = null,
    val job: String? = null,
    val imagePath: String? = null,
)

@Serializable
data class MediaInfo(
    val path: String? = null,
    val video: VideoInfo? = null,
    val audios: List<AudioInfo> = emptyList(),
    val subtitles: List<SubtitleInfo> = emptyList(),
)

@Serializable
data class VideoInfo(
    val title: String? = null,
    val codec: String? = null,
    val width: Int? = null,
    val height: Int? = null,
    val frameRate: Double? = null,
    val bitRate: Long? = null,
    val colorRange: String? = null,
    val profile: String? = null,
    val level: Double? = null,
    val aspectRatio: String? = null,
    val interlaced: Boolean? = null,
    val bitDepth: Int? = null,
    val pixelFormat: String? = null,
    val dolbyVision: Boolean = false,
)

@Serializable
data class AudioInfo(
    val title: String? = null,
    val language: String? = null,
    val codec: String? = null,
    val profile: String? = null,
    val layout: String? = null,
    val bitRate: Long? = null,
    val channels: Int? = null,
    val sampleRate: Int? = null,
    val isDefault: Boolean = false,
    val isExternal: Boolean = false,
)

@Serializable
data class SubtitleInfo(
    val title: String? = null,
    val language: String? = null,
    val codec: String? = null,
    val format: String? = null,
    val isDefault: Boolean = false,
    val isBitmap: Boolean = false,
    val isExternal: Boolean = false,
)

/** `dv_probe_dovi` 的结果：P7 的增强层是 FEL 还是 MEL。 */
@Serializable
data class DoviInfo(
    val profile: Int,
    /** `fel` / `mel`。 */
    val elType: String,
    /** RPU 里的原始标志：`false` = FEL。 */
    val disableResidual: Boolean,
)
