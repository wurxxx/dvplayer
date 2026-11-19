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
