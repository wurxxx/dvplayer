use serde::{Deserialize, Serialize};

/// 条目形态。各服务器叫法不同，统一到这里。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MediaKind {
    Unknown,
    Movie,
    Series,
    Season,
    Episode,
    Folder,
    Video,
}

impl MediaKind {
    /// 从各服务器的原始字符串映射。
    pub fn from_raw(raw: &str) -> Self {
        match raw {
            "Movie" | "movie" => Self::Movie,
            "TV" | "Series" | "series" => Self::Series,
            "Season" | "season" => Self::Season,
            "Episode" | "episode" => Self::Episode,
            "Directory" | "Folder" | "folder" => Self::Folder,
            "Video" | "video" => Self::Video,
            _ => Self::Unknown,
        }
    }
}

/// 一个媒体库（飞牛叫 mediadb，Emby 叫 library）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaLibrary {
    pub id: String,
    pub title: String,
    pub source_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub poster_path: Option<String>,
    #[serde(default)]
    pub category: String,
}

/// 统一媒体条目。图片只存相对路径，由各源决定怎么拼。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaItem {
    pub id: String,
    pub title: String,
    pub kind: MediaKind,
    pub source_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub poster_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub year: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub runtime_seconds: Option<u64>,
    /// 已看进度 0..1。
    #[serde(default)]
    pub progress: f64,
    #[serde(default)]
    pub is_favorite: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub overview: Option<String>,
    /// 服务器给的分辨率标签，如 2160p / 1080p。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    /// 上次观看（unix 秒）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_played: Option<i64>,

    // —— 剧集相关（电影/单集留空）——
    /// 季号，从 1 开始。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub season_number: Option<i32>,
    /// 集号，从 1 开始。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub episode_number: Option<i32>,
    /// 全剧集数（服务器给的总数，可能大于本地已有）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub episode_count: Option<i32>,
    /// 本地已有集数。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub local_episode_count: Option<i32>,
    /// 季数。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub season_count: Option<i32>,
    /// 评分（0..10）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rating: Option<f64>,
    /// 上映 / 首播日期（YYYY-MM-DD）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub release_date: Option<String>,
    /// 连载状态，如 "Returning Series"。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    /// 横版背景图（详情页顶部）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backdrop_path: Option<String>,
    /// 只有一季时，服务器直接给出那一季的 id，能少一层请求。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub single_child_id: Option<String>,
    /// 同一部片在各源的条目，按「有进度 > 源优先级 > 分辨率」排好；第一项是自己。
    /// 只有聚合搜索会填，列表 / 详情里是空数组。
    #[serde(default)]
    pub sources: Vec<ItemSource>,
}

/// 同一部片在某个源里的条目（搜索结果的多来源）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ItemSource {
    /// 带源前缀的条目 id，界面用它切源。
    pub item_id: String,
    pub source_id: String,
    pub source_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    #[serde(default)]
    pub progress: f64,
}

/// 搜索时没有响应的源。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceFailure {
    pub source_id: String,
    pub source_name: String,
    pub error: String,
}

/// 聚合搜索结果：去重后的条目 + 失败的源。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResult {
    pub items: Vec<MediaItem>,
    /// 总是序列化：Swift 合成的 Decodable 不会用属性默认值补缺失的键。
    #[serde(default)]
    pub failed: Vec<SourceFailure>,
}

/// 各源的播放记录。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlayRecord {
    pub item_id: String,
    /// 条目自己的标题；单集可能为空（飞牛只给剧名）。
    pub title: String,
    pub source_id: String,
    /// 所属剧名，单集记录用来补出「剧名 · 第 N 集」。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub series_title: Option<String>,
    /// 单集所属那一季的 id：续播时拿它一次请求就能拼出选集列表。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub season_number: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub episode_number: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub poster_path: Option<String>,
    pub position_seconds: u64,
    pub duration_seconds: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_played: Option<i64>,
}

impl PlayRecord {
    pub fn progress(&self) -> f64 {
        if self.duration_seconds == 0 {
            0.0
        } else {
            (self.position_seconds as f64 / self.duration_seconds as f64).clamp(0.0, 1.0)
        }
    }
}

/// 播放时需要带上的 HTTP 头（飞牛的 Authorization 就走这里）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HttpHeader {
    pub name: String,
    pub value: String,
}

/// 音轨。切换音轨时把 guid 带回 play/stream。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioTrack {
    pub guid: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    #[serde(default)]
    pub channels: i32,
    #[serde(default)]
    pub is_default: bool,
}

/// 字幕轨。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubtitleTrack {
    pub guid: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub format: Option<String>,
    #[serde(default)]
    pub is_external: bool,
    #[serde(default)]
    pub is_bitmap: bool,
}

/// 实际交给播放器的地址：URL + 必须带上的头。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaySource {
    pub item_id: String,
    #[serde(default)]
    pub title: String,
    pub url: String,
    #[serde(default)]
    pub headers: Vec<HttpHeader>,
    #[serde(default)]
    pub is_direct: bool,
    /// 原盘（ISO / 蓝光目录）：界面要走挂载或 libbluray，而不是直接丢给 mpv。
    #[serde(default)]
    pub disc: bool,
    pub media_guid: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub video_guid: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_guid: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subtitle_guid: Option<String>,
    /// 续播起点（秒）。
    #[serde(default)]
    pub position_seconds: u64,
    #[serde(default)]
    pub duration_seconds: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub overview: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub poster_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    /// HDR10 / HDR10+ / HLG / DV，空表示 SDR。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color_range: Option<String>,
    /// 是否 Dolby Vision（飞牛给 dv_profile > 0）。
    #[serde(default)]
    pub dolby_vision: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub video_codec: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_codec: Option<String>,
    #[serde(default)]
    pub audio_streams: Vec<AudioTrack>,
    #[serde(default)]
    pub subtitle_streams: Vec<SubtitleTrack>,
}

/// 一张图片的地址与鉴权头（海报走 Authorization，不能直接塞给 <img>）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageSource {
    pub url: String,
    #[serde(default)]
    pub headers: Vec<HttpHeader>,
}

/// 条目详情：列表接口不带的信息（背景图、简介、季集数、播放入口）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaDetail {
    pub id: String,
    pub title: String,
    pub kind: MediaKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub overview: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub poster_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backdrop_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub logo_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rating: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub release_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub runtime_seconds: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub season_count: Option<i32>,
    /// 本地已有季数（服务器可能只刮到第一季，TMDB 却写着 10 季）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub local_season_count: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub episode_count: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub local_episode_count: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color_range: Option<String>,
    /// 「继续观看」该播哪个条目（剧集里是某一集）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub play_item_id: Option<String>,
    /// 只有一季时，直接给出季 id，少一次请求。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub single_child_id: Option<String>,
    /// 详情页按钮的初始状态：是否已收藏 / 已看完。源不支持时是 None。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_favorite: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_watched: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Paged<T> {
    pub items: Vec<T>,
    pub total: i64,
    pub page: i32,
    pub page_size: i32,
}

impl<T> Paged<T> {
    pub fn empty(page: i32, page_size: i32) -> Self {
        Self { items: Vec::new(), total: 0, page, page_size }
    }

    pub fn has_more(&self) -> bool {
        (self.page as i64) * (self.page_size as i64) < self.total
    }
}

/// 列表的筛选与排序参数。界面只传抽象值（`tv` / `movie` / `folder`），
/// 各适配器自己翻译成服务器认识的类型名。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ListQuery {
    /// 只要这些类型：`tv` / `movie` / `folder`。空表示不按类型过滤。
    pub kinds: Vec<String>,
    /// 风格 / 类型标签，取值来自 [`Genre::id`]。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub genre: Option<String>,
    /// 排序字段：`name` / `added` / `release` / `rating`。
    /// 空表示用服务器默认顺序。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sort: Option<String>,
    /// 是否降序。
    #[serde(default)]
    pub descending: bool,
}

/// 一个可筛选的风格。飞牛是 TMDB genre（id 是数字），Emby 直接用名字。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Genre {
    pub id: String,
    pub title: String,
}

/// 演职人员。Emby 给 `Type`（Actor/Director/Writer），飞牛给中文职位。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Person {
    /// 演员自己的 id（取头像用），没有就空。
    #[serde(default)]
    pub id: String,
    pub name: String,
    /// 演的是谁（角色名）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    /// 导演 / 编剧 / 演员这类职位。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_path: Option<String>,
}

/// 详情页「媒体信息」：一路视频 + 若干音轨。
///
/// 字段全部可空：飞牛的 `/stream` 只给一部分，Emby 给全，缺的项界面直接不显示。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub video: Option<VideoInfo>,
    #[serde(default)]
    pub audios: Vec<AudioInfo>,
    /// 字幕轨。详情页和播放页的「选择字幕」都读这份，顺序和文件里的轨序一致。
    #[serde(default)]
    pub subtitles: Vec<SubtitleInfo>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubtitleInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub format: Option<String>,
    #[serde(default)]
    pub is_default: bool,
    /// 图形字幕（PGS / VobSub），mpv 不能改字号。
    #[serde(default)]
    pub is_bitmap: bool,
    #[serde(default)]
    pub is_external: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoInfo {
    /// 一行标题，例如 `1080p SDR`。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frame_rate: Option<f64>,
    /// 比特率，bit/s。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bit_rate: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color_range: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub level: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub aspect_ratio: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interlaced: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bit_depth: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pixel_format: Option<String>,
    #[serde(default)]
    pub dolby_vision: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    /// 声道布局，例如 `stereo` / `5.1`。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub layout: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bit_rate: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channels: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sample_rate: Option<i32>,
    #[serde(default)]
    pub is_default: bool,
    #[serde(default)]
    pub is_external: bool,
}

/// 统一响应外壳，FFI 全部返回它。
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Envelope<T> {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<i64>,
}

impl<T> Envelope<T> {
    pub fn ok(data: T) -> Self {
        Self { ok: true, data: Some(data), error: None, code: None }
    }

    pub fn err(message: impl Into<String>, code: Option<i64>) -> Self {
        Self { ok: false, data: None, error: Some(message.into()), code }
    }
}
