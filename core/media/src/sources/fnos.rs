use md5::{Digest, Md5};
use reqwest::blocking::Client;
use reqwest::Method;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use crate::error::{compact_json, percent_decode, percent_encode, ApiEnvelope, MediaError, Result};
use crate::models::{
    AudioTrack, HttpHeader, ImageSource, MediaItem, MediaKind, MediaLibrary, Paged, PlayRecord,
    PlaySource, SubtitleTrack,
};

const API_PREFIX: &str = "/v/api/v1";
const SIGN_SALT: &str = "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh";
const SIGN_API_KEY: &str = "16CCEB3D-AB42-077D-36A1-F355324E4237";

fn md5_hex(value: &str) -> String {
    let mut hasher = Md5::new();
    hasher.update(value.as_bytes());
    format!("{:x}", hasher.finalize())
}

/// authx 签名：md5(SALT_path_nonce_ts_bodyHash_APIKEY)
pub fn sign(
    path: &str,
    query: &BTreeMap<String, String>,
    body_json: Option<&str>,
    method: &str,
) -> String {
    let is_get = method.eq_ignore_ascii_case("GET");

    let body_hash = if is_get {
        let q = build_query(query);
        md5_hex(&percent_decode(&q))
    } else {
        md5_hex(body_json.unwrap_or(""))
    };

    let nonce = fastrand_u32(100000..1000000).to_string();
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
        .to_string();

    let sign = md5_hex(&format!(
        "{}_{}_{}_{}_{}_{}",
        SIGN_SALT, path, nonce, timestamp, body_hash, SIGN_API_KEY
    ));

    format!("nonce={}&timestamp={}&sign={}", nonce, timestamp, sign)
}

fn build_query(query: &BTreeMap<String, String>) -> String {
    query
        .iter()
        .map(|(k, v)| format!("{}={}", percent_encode(k), percent_encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

/// 不引入 rand crate 的轻量随机数（签名只要求 nonce 不重复）。
fn fastrand_u32(range: std::ops::Range<u32>) -> u32 {
    use std::cell::Cell;
    use std::time::{SystemTime, UNIX_EPOCH};

    thread_local! {
        static SEED: Cell<u64> = Cell::new(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_nanos() as u64)
                .unwrap_or(0x9E3779B97F4A7C15)
        );
    }

    SEED.with(|seed| {
        let mut x = seed.get();
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        seed.set(x);
        let span = range.end - range.start;
        range.start + (x % span as u64) as u32
    })
}

/// 飞牛影视适配器。
pub struct FnOsSource {
    pub id: String,
    pub name: String,
    pub base: String,
    username: String,
    password: String,
    token: Option<String>,
    http: Client,
}

impl FnOsSource {
    pub fn new(id: String, name: String, base: String, username: String, password: String) -> Self {
        Self {
            id,
            name,
            base: base.trim_end_matches('/').to_string(),
            username,
            password,
            token: None,
            http: Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .unwrap_or_else(|_| Client::new()),
        }
    }

    pub fn login(&mut self) -> Result<()> {
        #[derive(Deserialize)]
        struct LoginData {
            #[serde(default)]
            token: String,
        }

        let body = compact_json(&serde_json::json!({
            "username": self.username,
            "password": self.password,
        }))?;

        let env: ApiEnvelope<LoginData> = self.send(Method::POST, "/login", &BTreeMap::new(), Some(&body))?;

        match env.data {
            Some(d) if !d.token.is_empty() => {
                self.token = Some(d.token);
                Ok(())
            }
            _ => Err(MediaError::Api {
                code: env.code,
                msg: env.msg.unwrap_or_else(|| "login failed".into()),
            }),
        }
    }

    pub fn libraries(&self) -> Result<Vec<MediaLibrary>> {
        #[derive(Deserialize)]
        struct LibraryDto {
            #[serde(default)]
            guid: String,
            #[serde(default)]
            title: String,
            #[serde(default)]
            poster: Option<String>,
            #[serde(default)]
            posters: Option<Vec<String>>,
            #[serde(default)]
            category: Option<String>,
        }

        let env: ApiEnvelope<Vec<LibraryDto>> =
            self.send(Method::GET, "/mediadb/list", &BTreeMap::new(), None)?;

        let list = env.data.ok_or_else(|| MediaError::Api {
            code: env.code,
            msg: env.msg.unwrap_or_else(|| "no data".into()),
        })?;

        Ok(list
            .into_iter()
            .map(|l| MediaLibrary {
                id: l.guid,
                title: l.title,
                source_id: self.id.clone(),
                poster_path: l.poster.or_else(|| l.posters.and_then(|p| p.into_iter().next())),
                category: l.category.unwrap_or_default(),
            })
            .collect())
    }

    pub fn items(&self, library_id: &str, page: i32, page_size: i32) -> Result<Paged<MediaItem>> {
        self.list_items("guid", library_id, page, page_size)
    }

    pub fn children(&self, parent_id: &str, page: i32, page_size: i32) -> Result<Paged<MediaItem>> {
        self.list_items("parent_guid", parent_id, page, page_size)
    }

    fn list_items(&self, key: &str, id: &str, page: i32, page_size: i32) -> Result<Paged<MediaItem>> {
        #[derive(Deserialize)]
        struct ListDto {
            #[serde(default)]
            total: i64,
            #[serde(default)]
            list: Vec<ItemDto>,
        }

        let mut body = serde_json::Map::new();
        body.insert(key.into(), serde_json::Value::String(id.into()));
        body.insert("page".into(), serde_json::Value::from(page));
        body.insert("page_size".into(), serde_json::Value::from(page_size));
        let body = compact_json(&body)?;

        let env: ApiEnvelope<ListDto> =
            self.send(Method::POST, "/item/list", &BTreeMap::new(), Some(&body))?;

        let data = env.data.ok_or_else(|| MediaError::Api {
            code: env.code,
            msg: env.msg.unwrap_or_else(|| "no data".into()),
        })?;

        Ok(Paged {
            total: data.total,
            items: data.list.into_iter().map(|d| self.map_item(d)).collect(),
            page,
            page_size,
        })
    }

    pub fn records(&self) -> Result<Vec<PlayRecord>> {
        let env: ApiEnvelope<Vec<ItemDto>> =
            self.send(Method::GET, "/play/list", &BTreeMap::new(), None)?;

        let list = env.data.unwrap_or_default();
        Ok(list
            .into_iter()
            .map(|d| {
                let duration = d.duration.max(0) as u64;
                PlayRecord {
                    item_id: d.guid,
                    title: d.title,
                    source_id: self.id.clone(),
                    poster_path: d.poster.or_else(|| d.poster_list.and_then(|p| p.into_iter().next())),
                    // 飞牛把「看到第几秒」放在 ts，watched 只表示是否看完。
                    position_seconds: d.ts.max(0) as u64,
                    duration_seconds: duration,
                    last_played: if d.watched_ts > 0 { Some(d.watched_ts) } else { None },
                }
            })
            .collect())
    }

    pub fn report_progress(&self, item_id: &str, position: i64, duration: i64) -> Result<()> {
        let body = compact_json(&serde_json::json!({
            "position": position,
            "duration": duration,
        }))?;

        let path = format!("/item/{}/playing", item_id);
        let env: ApiEnvelope<serde_json::Value> =
            self.send(Method::POST, &path, &BTreeMap::new(), Some(&body))?;

        if env.code != 0 {
            return Err(MediaError::Api {
                code: env.code,
                msg: env.msg.unwrap_or_default(),
            });
        }
        Ok(())
    }

    fn map_item(&self, d: ItemDto) -> MediaItem {
        MediaItem {
            id: d.guid,
            title: d.title,
            kind: MediaKind::from_raw(d.item_type.as_deref().unwrap_or("")),
            source_id: self.id.clone(),
            poster_path: d.poster.or_else(|| d.poster_list.and_then(|p| p.into_iter().next())),
            parent_id: d.parent_guid.filter(|s| !s.is_empty()),
            parent_title: d.parent_title.filter(|s| !s.is_empty()),
            year: None,
            runtime_seconds: if d.duration > 0 {
                Some(d.duration as u64)
            } else {
                None
            },
            progress: if d.watched > 0 { 1.0 } else { 0.0 },
            is_favorite: d.is_favorite > 0,
            overview: None,
            resolution: d
                .media_stream
                .as_ref()
                .and_then(|m| m.resolutions.as_ref())
                .and_then(|r| r.first())
                .cloned(),
            last_played: if d.watched_ts > 0 { Some(d.watched_ts) } else { None },
        }
    }

    /// 取播放所需的一切：直链、续播点、音轨/字幕轨、HDR 信息。
    ///
    /// 飞牛的原生播放链路是两步：
    ///   1. `POST /play/info`（item_guid）→ 拿到 media_guid 与各轨 guid；
    ///   2. `POST /stream`（media_guid）→ 视频/音频/字幕轨详情；
    ///   3. 直链是 `GET /media/range/{media_guid}`，需要 `Authorization`，支持 Range。
    pub fn play_source(&self, item_id: &str) -> Result<PlaySource> {
        #[derive(Deserialize)]
        struct InfoDto {
            #[serde(default)]
            media_guid: String,
            #[serde(default)]
            video_guid: String,
            #[serde(default)]
            audio_guid: String,
            #[serde(default)]
            subtitle_guid: String,
            #[serde(default)]
            ts: i64,
            #[serde(default)]
            item: Option<DetailDto>,
            #[serde(default)]
            direct_link_audio_index: i32,
        }

        #[derive(Deserialize)]
        struct DetailDto {
            #[serde(default)]
            title: String,
            #[serde(default)]
            overview: String,
            #[serde(default)]
            posters: String,
            #[serde(default)]
            backdrops: String,
            #[serde(default)]
            duration: i64,
            #[serde(default)]
            media_stream: Option<StreamMetaDto>,
        }

        #[derive(Deserialize, Default)]
        struct StreamMetaDto {
            #[serde(default)]
            resolutions: Vec<String>,
            #[serde(default)]
            color_range_type: Vec<String>,
            #[serde(default)]
            audio_type: Vec<String>,
        }

        #[derive(Deserialize, Default)]
        struct StreamDto {
            #[serde(default)]
            video_stream: Option<VideoDto>,
            #[serde(default)]
            audio_streams: Vec<AudioDto>,
            #[serde(default)]
            subtitle_streams: Vec<SubtitleDto>,
        }

        #[derive(Deserialize, Default)]
        struct VideoDto {
            #[serde(default)]
            codec_name: String,
            #[serde(default)]
            resolution_type: String,
            #[serde(default)]
            color_range_type: String,
            #[serde(default)]
            dv_profile: i32,
        }

        #[derive(Deserialize, Default)]
        struct AudioDto {
            #[serde(default)]
            guid: String,
            #[serde(default)]
            language: String,
            #[serde(default)]
            codec_name: String,
            #[serde(default)]
            profile: String,
            #[serde(default)]
            channels: i32,
            #[serde(default)]
            is_default: i32,
        }

        #[derive(Deserialize, Default)]
        struct SubtitleDto {
            #[serde(default)]
            guid: String,
            #[serde(default)]
            language: String,
            #[serde(default)]
            codec_name: String,
            #[serde(default)]
            format: String,
            #[serde(default)]
            is_external: i32,
            #[serde(default)]
            is_bitmap: i32,
        }

        let body = compact_json(&serde_json::json!({ "item_guid": item_id }))?;
        let env: ApiEnvelope<InfoDto> =
            self.send(Method::POST, "/play/info", &BTreeMap::new(), Some(&body))?;
        let info = env.data.ok_or_else(|| MediaError::Api {
            code: env.code,
            msg: env.msg.unwrap_or_else(|| "no play info".into()),
        })?;

        if info.media_guid.is_empty() {
            return Err(MediaError::Other("该条目没有可播放的媒体文件".into()));
        }

        // 只有带文件才需要 /stream；失败时退回 play/info 里的信息。
        let stream_body = compact_json(&serde_json::json!({
            "media_guid": info.media_guid,
            "ip": "00000000-0000-4000-8000-000000000000",
            "header": { "User-Agent": ["DVPlayer"] }
        }))?;
        let stream: StreamDto = self
            .send::<StreamDto>(Method::POST, "/stream", &BTreeMap::new(), Some(&stream_body))
            .ok()
            .and_then(|e| e.data)
            .unwrap_or_default();

        let detail = info.item.unwrap_or_else(|| DetailDto {
            title: String::new(),
            overview: String::new(),
            posters: String::new(),
            backdrops: String::new(),
            duration: 0,
            media_stream: None,
        });

        let meta = detail.media_stream.unwrap_or_default();
        let video = stream.video_stream.unwrap_or_default();

        let color_range = if !video.color_range_type.is_empty() {
            Some(video.color_range_type.clone())
        } else {
            meta.color_range_type.first().cloned()
        };

        let resolution = if !video.resolution_type.is_empty() {
            Some(video.resolution_type.clone())
        } else {
            meta.resolutions.first().cloned()
        };

        let audio_streams: Vec<AudioTrack> = stream
            .audio_streams
            .into_iter()
            .map(|a| AudioTrack {
                guid: a.guid,
                language: empty_to_none(a.language),
                codec: empty_to_none(a.codec_name),
                profile: empty_to_none(a.profile),
                channels: a.channels,
                is_default: a.is_default > 0,
            })
            .collect();

        // 飞牛在 play/info 里给的是「上次用的音轨下标」，优先用它。
        let audio_streams = if info.direct_link_audio_index >= 0 {
            audio_streams
                .into_iter()
                .enumerate()
                .map(|(i, mut a)| {
                    a.is_default = i as i32 == info.direct_link_audio_index;
                    a
                })
                .collect()
        } else {
            audio_streams
        };

        let subtitle_streams: Vec<SubtitleTrack> = stream
            .subtitle_streams
            .into_iter()
            .map(|s| SubtitleTrack {
                guid: s.guid,
                language: empty_to_none(s.language),
                codec: empty_to_none(s.codec_name),
                format: empty_to_none(s.format),
                is_external: s.is_external > 0,
                is_bitmap: s.is_bitmap > 0,
            })
            .collect();

        let poster = if detail.posters.is_empty() {
            empty_to_none(detail.backdrops)
        } else {
            Some(detail.posters)
        };

        Ok(PlaySource {
            item_id: item_id.to_string(),
            title: detail.title,
            url: format!("{}/v/api/v1/media/range/{}", self.base, info.media_guid),
            headers: self.auth_headers(),
            is_direct: true,
            media_guid: info.media_guid,
            video_guid: empty_to_none(info.video_guid),
            audio_guid: empty_to_none(info.audio_guid),
            subtitle_guid: empty_to_none(info.subtitle_guid),
            position_seconds: info.ts.max(0) as u64,
            duration_seconds: detail.duration.max(0) as u64,
            overview: empty_to_none(detail.overview),
            poster_path: poster,
            resolution,
            color_range,
            dolby_vision: video.dv_profile > 0,
            video_codec: if video.codec_name.is_empty() {
                None
            } else {
                Some(video.codec_name)
            },
            audio_codec: meta.audio_type.first().cloned(),
            audio_streams,
            subtitle_streams,
        })
    }

    /// 海报地址：图片接口只认 Authorization 头，调用方要带着头去取字节。
    pub fn image_source(&self, path: &str) -> Result<ImageSource> {
        if path.is_empty() {
            return Err(MediaError::Other("empty image path".into()));
        }

        let normalized = if path.starts_with('/') {
            path.to_string()
        } else {
            format!("/{}", path)
        };

        Ok(ImageSource {
            url: format!("{}/v/api/v1/sys/img{}", self.base, normalized),
            headers: self.auth_headers(),
        })
    }

    fn auth_headers(&self) -> Vec<HttpHeader> {
        self.token
            .as_ref()
            .map(|t| {
                vec![HttpHeader {
                    name: "Authorization".into(),
                    value: t.clone(),
                }]
            })
            .unwrap_or_default()
    }

    fn send<T: for<'de> Deserialize<'de>>(
        &self,
        method: Method,
        path: &str,
        query: &BTreeMap<String, String>,
        body_json: Option<&str>,
    ) -> Result<ApiEnvelope<T>> {
        let full_path = format!("{}{}", API_PREFIX, path);
        let qs = build_query(query);
        let url = if qs.is_empty() {
            format!("{}{}", self.base, full_path)
        } else {
            format!("{}{}?{}", self.base, full_path, qs)
        };

        let mut request = self.http.request(method.clone(), &url);

        if let Some(token) = &self.token {
            request = request.header("Authorization", token);
            request = request.header(
                "authx",
                sign(&full_path, query, body_json, method.as_str()),
            );
        }

        if let Some(body) = body_json {
            request = request
                .header("Content-Type", "application/json")
                .body(body.to_string());
        }

        let response = request.send()?;
        let status = response.status();
        let text = response.text()?;

        let envelope: ApiEnvelope<T> = serde_json::from_str(&text).map_err(|_| MediaError::Api {
            code: status.as_u16() as i64,
            msg: format!("bad response: {}", truncate(&text, 200)),
        })?;

        Ok(envelope)
    }
}

fn truncate(value: &str, max: usize) -> String {
    if value.len() <= max {
        value.to_string()
    } else {
        format!("{}…", &value[..max])
    }
}

fn empty_to_none(value: String) -> Option<String> {
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

#[derive(Debug, Deserialize)]
struct ItemDto {
    #[serde(default)]
    guid: String,
    #[serde(default)]
    title: String,
    #[serde(default, rename = "type")]
    item_type: Option<String>,
    #[serde(default)]
    poster: Option<String>,
    #[serde(default)]
    poster_list: Option<Vec<String>>,
    #[serde(default)]
    parent_guid: Option<String>,
    #[serde(default)]
    parent_title: Option<String>,
    #[serde(default)]
    is_favorite: i32,
    #[serde(default)]
    watched: i32,
    #[serde(default)]
    watched_ts: i64,
    /// 总时长（秒）。
    #[serde(default)]
    duration: i64,
    /// 上次看到的位置（秒）。飞牛的续播进度放在这里。
    #[serde(default)]
    ts: i64,
    #[serde(default)]
    media_stream: Option<MediaStreamDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct MediaStreamDto {
    #[serde(default)]
    pub resolutions: Option<Vec<String>>,
    #[serde(default)]
    pub audio_type: Option<String>,
    #[serde(default)]
    pub color_range_type: Option<String>,
}
