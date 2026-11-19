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
}

/// 各源的播放记录。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlayRecord {
    pub item_id: String,
    pub title: String,
    pub source_id: String,
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
