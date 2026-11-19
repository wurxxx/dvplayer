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

/// 实际交给播放器的地址。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaySource {
    pub url: String,
    #[serde(default)]
    pub is_direct: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subtitle_url: Option<String>,
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
