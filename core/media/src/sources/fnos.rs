use md5::{Digest, Md5};
use reqwest::blocking::Client;
use reqwest::Method;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use crate::error::{compact_json, percent_decode, percent_encode, ApiEnvelope, MediaError, Result};
use crate::models::{
    Person,
    AudioInfo, MediaInfo, SubtitleInfo, VideoInfo,
    AudioTrack, Genre, HttpHeader, ImageSource, ListQuery, MediaDetail, MediaItem, MediaKind,
    MediaLibrary, Paged, PlayRecord, PlaySource, SubtitleTrack,
};
use crate::sources::{
    job_label, language_label, pick_bool, pick_f64, pick_i32, pick_i64, pick_str, MediaSource,
};

const API_PREFIX: &str = "/v/api/v1";
const SIGN_SALT: &str = "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh";
const SIGN_API_KEY: &str = "16CCEB3D-AB42-077D-36A1-F355324E4237";

fn md5_hex(value: &str) -> String {
    let mut hasher = Md5::new();
    hasher.update(value.as_bytes());
    format!("{:x}", hasher.finalize())
}

/// 界面的排序字段 → 飞牛的 `sort_column`。
fn fnos_sort_column(sort: &str) -> Option<&'static str> {
    match sort {
        "name" => Some("sort_title"),
        "added" => Some("create_time"),
        "release" => Some("release_date"),
        "rating" => Some("vote_average"),
        _ => None,
    }
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
    /// item_guid → media_guid。`play_source` 时记下，回写进度要用。
    /// 换片源不重启客户端也没关系：缓存没有时现查一次 `play/info`。
    media_cache: std::sync::Mutex<std::collections::HashMap<String, String>>,
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
            media_cache: std::sync::Mutex::new(std::collections::HashMap::new()),
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

        let env: ApiEnvelope<Option<Vec<LibraryDto>>> =
            self.send(Method::GET, "/mediadb/list", &BTreeMap::new(), None)?;

        // 空库时飞牛给 `data: null`，不能当成解析失败。
        let list = env.data.flatten().unwrap_or_default();

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

    pub fn items(
        &self,
        library_id: &str,
        page: i32,
        page_size: i32,
        query: &ListQuery,
    ) -> Result<Paged<MediaItem>> {
        self.list_items("guid", library_id, page, page_size, query)
    }

    pub fn children(
        &self,
        parent_id: &str,
        page: i32,
        page_size: i32,
        query: &ListQuery,
    ) -> Result<Paged<MediaItem>> {
        self.list_items("parent_guid", parent_id, page, page_size, query)
    }

    /// 这个库里实际出现过的风格（`/tag/list` 给 id，`/tag/genres` 给名字）。
    pub fn genres(&self, scope_id: &str) -> Result<Vec<Genre>> {
        #[derive(Deserialize)]
        struct GenreDto {
            id: i64,
            value: String,
        }

        #[derive(Deserialize)]
        struct TagListDto {
            #[serde(default)]
            genres: Option<Vec<i64>>,
        }

        let all: ApiEnvelope<Option<Vec<GenreDto>>> =
            self.send(Method::GET, "/tag/genres", &BTreeMap::new(), None)?;

        let mut params = BTreeMap::new();
        params.insert("guid".to_string(), scope_id.to_string());
        let list: ApiEnvelope<TagListDto> = self.send(Method::GET, "/tag/list", &params, None)?;

        let names: std::collections::HashMap<i64, String> = all
            .data
            .flatten()
            .unwrap_or_default()
            .into_iter()
            .map(|g| (g.id, g.value))
            .collect();

        let Some(tags) = list.data else {
            return Ok(Vec::new());
        };

        Ok(tags
            .genres
            .unwrap_or_default()
            .into_iter()
            .filter_map(|id| {
                names.get(&id).map(|title| Genre {
                    id: id.to_string(),
                    title: title.clone(),
                })
            })
            .collect())
    }

    fn list_items(
        &self,
        key: &str,
        id: &str,
        page: i32,
        page_size: i32,
        query: &ListQuery,
    ) -> Result<Paged<MediaItem>> {
        #[derive(Deserialize)]
        struct ListDto {
            #[serde(default)]
            total: i64,
            #[serde(default)]
            list: Option<Vec<ItemDto>>,
        }

        let mut body = serde_json::Map::new();
        body.insert(key.into(), serde_json::Value::String(id.into()));
        body.insert("page".into(), serde_json::Value::from(page));
        body.insert("page_size".into(), serde_json::Value::from(page_size));

        // 类型过滤：界面的「剧集 / 电影 / 文件夹」。
        let types: Vec<&str> = match query.kinds.as_slice() {
            [] => Vec::new(),
            kinds => kinds
                .iter()
                .flat_map(|kind| match kind.as_str() {
                    "tv" => vec!["TV"],
                    "movie" => vec!["Movie"],
                    "folder" => vec!["Directory"],
                    _ => Vec::new(),
                })
                .collect(),
        };

        // 风格是 TMDB genre id，接口要数字，传不进去就不带这个条件。
        let genre = query.genre.as_deref().and_then(|g| g.parse::<i64>().ok());

        if !types.is_empty() || genre.is_some() {
            let mut tags = serde_json::Map::new();
            if !types.is_empty() {
                tags.insert("type".into(), serde_json::json!(types));
            }
            if let Some(id) = genre {
                tags.insert("genres".into(), serde_json::Value::from(id));
            }
            body.insert("tags".into(), serde_json::Value::Object(tags));
        }

        if let Some(column) = query.sort.as_deref().and_then(fnos_sort_column) {
            body.insert("sort_column".into(), serde_json::Value::from(column));
            body.insert(
                "sort_type".into(),
                serde_json::Value::from(if query.descending { "DESC" } else { "ASC" }),
            );
        }

        let body = compact_json(&body)?;

        let env: ApiEnvelope<ListDto> =
            self.send(Method::POST, "/item/list", &BTreeMap::new(), Some(&body))?;

        let data = env.data.ok_or_else(|| MediaError::Api {
            code: env.code,
            msg: env.msg.unwrap_or_else(|| "no data".into()),
        })?;

        Ok(Paged {
            total: data.total,
            items: data
                .list
                .unwrap_or_default()
                .into_iter()
                .map(|d| self.map_item(d))
                .collect(),
            page,
            page_size,
        })
    }

    /// 飞牛的搜索接口：`GET /v/api/v1/search/list?q=<关键词>`，返回平铺的条目。
    pub fn search(&self, query: &str) -> Result<Vec<MediaItem>> {
        let q = query.trim();
        if q.is_empty() {
            return Ok(Vec::new());
        }

        let mut params = BTreeMap::new();
        params.insert("q".to_string(), q.to_string());

        let env: ApiEnvelope<Option<Vec<ItemDto>>> =
            self.send(Method::GET, "/search/list", &params, None)?;

        Ok(env
            .data
            .flatten()
            .unwrap_or_default()
            .into_iter()
            .map(|d| self.map_item(d))
            .collect())
    }

    pub fn records(&self) -> Result<Vec<PlayRecord>> {
        let env: ApiEnvelope<Option<Vec<ItemDto>>> =
            self.send(Method::GET, "/play/list", &BTreeMap::new(), None)?;

        let list = env.data.flatten().unwrap_or_default();
        Ok(list
            .into_iter()
            .map(|d| {
                let duration = d.duration.max(0) as u64;
                PlayRecord {
                    item_id: d.guid,
                    title: d.title.clone(),
                    source_id: self.id.clone(),
                    series_title: d.tv_title.clone().filter(|s| !s.is_empty()).or_else(|| {
                        if parse_episode_number(&d.title).is_some() {
                            d.parent_title.clone().filter(|s| !s.is_empty())
                        } else {
                            None
                        }
                    }),
                    season_number: d.season_number.filter(|v| *v > 0),
                    episode_number: d
                        .episode_number
                        .filter(|v| *v > 0)
                        .or_else(|| parse_episode_number(&d.title)),
                    poster_path: d.poster.or_else(|| d.poster_list.and_then(|p| p.into_iter().next())),
                    // 飞牛把「看到第几秒」放在 ts，watched 只表示是否看完。
                    position_seconds: d.ts.max(0) as u64,
                    duration_seconds: duration,
                    last_played: if d.watched_ts > 0 { Some(d.watched_ts) } else { None },
                }
            })
            .collect())
    }

    /// 回写进度。飞牛的格式是 `POST /play/record {item_guid, media_guid, ts}`，
    /// 其中 `ts` 就是「看到第几秒」（和 `play/list` 里读出来的是同一个字段）。
    ///
    /// `duration` 目前用不上（服务端自己知道片长），保留参数是为了让 C ABI
    /// 对 Emby / Jellyfin 也够用——它们上报要带 `RunTimeTicks`。
    /// 收藏 / 取消收藏。飞牛的 body 固定是 `{"item_guid": ...}`。
    pub fn set_favorite(&self, item_id: &str, favorite: bool) -> Result<()> {
        let method = if favorite { Method::PUT } else { Method::DELETE };
        self.write_ok(method, "/item/favorite", item_id)
    }

    /// 收藏列表：`POST /favorite/list`，返回结构和 `item/list` 一样。
    pub fn favorites(&self, page: i32, page_size: i32) -> Result<Paged<MediaItem>> {
        #[derive(Deserialize)]
        struct ListDto {
            #[serde(default)]
            total: i64,
            #[serde(default)]
            list: Option<Vec<ItemDto>>,
        }

        let body = compact_json(&serde_json::json!({
            "page": page,
            "page_size": page_size,
        }))?;

        let env: ApiEnvelope<ListDto> = self.send(
            Method::POST,
            "/favorite/list",
            &BTreeMap::new(),
            Some(&body),
        )?;

        let data = env.data.ok_or_else(|| MediaError::Api {
            code: env.code,
            msg: env.msg.unwrap_or_else(|| "no data".into()),
        })?;

        Ok(Paged {
            total: data.total,
            items: data
                .list
                .unwrap_or_default()
                .into_iter()
                .map(|d| self.map_item(d))
                .collect(),
            page,
            page_size,
        })
    }

    /// 标记已观看 / 未观看。走 `/item/watched`，不碰播放进度。
    pub fn set_watched(&self, item_id: &str, watched: bool) -> Result<()> {
        let method = if watched { Method::POST } else { Method::DELETE };
        self.write_ok(method, "/item/watched", item_id)
    }

    /// 移除观看记录：`DELETE /play/record`，继续观看里就不再出现。
    pub fn remove_play_record(&self, item_id: &str) -> Result<()> {
        self.write_ok(Method::DELETE, "/play/record", item_id)
    }

    /// 只关心 `code == 0` 的写接口。
    fn write_ok(&self, method: Method, path: &str, item_id: &str) -> Result<()> {
        let body = compact_json(&serde_json::json!({ "item_guid": item_id }))?;
        let env: ApiEnvelope<serde_json::Value> =
            self.send(method, path, &BTreeMap::new(), Some(&body))?;

        if env.code != 0 {
            return Err(MediaError::Api {
                code: env.code,
                msg: env.msg.unwrap_or_default(),
            });
        }
        Ok(())
    }

    pub fn report_progress(&self, item_id: &str, position: i64, _duration: i64) -> Result<()> {
        let media_guid = self.media_guid_for(item_id)?;

        let body = compact_json(&serde_json::json!({
            "item_guid": item_id,
            "media_guid": media_guid,
            "ts": position.max(0),
        }))?;

        let env: ApiEnvelope<serde_json::Value> =
            self.send(Method::POST, "/play/record", &BTreeMap::new(), Some(&body))?;

        if env.code != 0 {
            return Err(MediaError::Api {
                code: env.code,
                msg: env.msg.unwrap_or_default(),
            });
        }
        Ok(())
    }

    /// 拿条目对应的 media_guid：先用 `play_source` 记下的缓存，
    /// 没有就现查 `play/info`（比如客户端重启后直接播历史记录）。
    fn media_guid_for(&self, item_id: &str) -> Result<String> {
        if let Some(cached) = self
            .media_cache
            .lock()
            .ok()
            .and_then(|m| m.get(item_id).cloned())
            .filter(|v| !v.is_empty())
        {
            return Ok(cached);
        }

        #[derive(Deserialize)]
        struct InfoDto {
            #[serde(default)]
            media_guid: String,
        }

        let body = compact_json(&serde_json::json!({ "item_guid": item_id }))?;
        let env: ApiEnvelope<InfoDto> =
            self.send(Method::POST, "/play/info", &BTreeMap::new(), Some(&body))?;

        match env.data {
            Some(d) if !d.media_guid.is_empty() => Ok(d.media_guid),
            _ => Err(MediaError::Api {
                code: env.code,
                msg: env.msg.unwrap_or_else(|| "没有可播放的媒体文件".into()),
            }),
        }
    }

    fn map_item(&self, d: ItemDto) -> MediaItem {
        let kind = MediaKind::from_raw(d.item_type.as_deref().unwrap_or(""));

        // 刮削好的条目服务器会直接给集号；没刮削的目录只能从文件名里认。
        // 这一步放在核心里，四端看到的结果才一致。
        let episode_number = d
            .episode_number
            .filter(|v| *v > 0)
            .or_else(|| parse_episode_number(&d.title));
        let episode_count = d.number_of_episodes.filter(|v| *v > 0).or_else(|| {
            // 「（76集）」只有剧集/目录级别的标题才有意义。
            matches!(kind, MediaKind::Folder | MediaKind::Series)
                .then(|| parse_episode_count(&d.title))
                .flatten()
        });

        let resolution = first_string(
            d.media_stream
                .as_ref()
                .and_then(|m| m.resolutions.as_ref()),
        );

        let progress = if d.duration > 0 && d.ts > 0 {
            (d.ts as f64 / d.duration as f64).clamp(0.0, 1.0)
        } else if d.watched > 0 {
            1.0
        } else {
            0.0
        };

        MediaItem {
            id: d.guid,
            title: d.title,
            kind,
            source_id: self.id.clone(),
            poster_path: d
                .poster
                .filter(|s| !s.is_empty())
                .or_else(|| d.poster_list.and_then(|p| p.into_iter().next()))
                .filter(|s| !s.is_empty()),
            parent_id: d.parent_guid.filter(|s| !s.is_empty()),
            parent_title: d.parent_title.filter(|s| !s.is_empty()),
            year: d
                .release_date
                .as_deref()
                .and_then(|s| s.get(..4))
                .and_then(|s| s.parse().ok()),
            runtime_seconds: (d.duration > 0).then_some(d.duration as u64),
            progress,
            is_favorite: d.is_favorite > 0,
            overview: empty_to_none(d.overview.unwrap_or_default()),
            resolution,
            last_played: (d.watched_ts > 0).then_some(d.watched_ts),

            season_number: d.season_number.filter(|v| *v > 0),
            episode_number,
            episode_count,
            local_episode_count: d.local_number_of_episodes.filter(|v| *v > 0),
            season_count: d.number_of_seasons.filter(|v| *v > 0),
            rating: d.vote_average.as_ref().and_then(json_number),
            release_date: empty_to_none(d.release_date.unwrap_or_default()),
            status: empty_to_none(d.status.unwrap_or_default()),
            backdrop_path: empty_to_none(d.backdrops.unwrap_or_default()),
            single_child_id: d.single_child_guid.filter(|s| !s.is_empty()),
        }
    }

    /// 条目详情：列表接口没有的简介、背景图、季集数。
    ///
    /// 注意飞牛对 `Episode` 的 `/item/<guid>` 返回空对象，调用方要按
    /// 「字段可能为空」处理；剧集的完整信息用 `children(series)` 已经够。
    pub fn item_detail(&self, item_id: &str) -> Result<MediaDetail> {
        // 飞牛大量字段会直接给 null（不只省略），所以字符串一律 Option，
        // 否则 serde 会整条解析失败。
        #[derive(Deserialize, Default)]
        struct DetailDto {
            #[serde(default)]
            guid: Option<String>,
            #[serde(default)]
            title: Option<String>,
            #[serde(default)]
            original_title: Option<String>,
            #[serde(default, rename = "type")]
            item_type: Option<String>,
            #[serde(default)]
            overview: Option<String>,
            #[serde(default)]
            posters: Option<String>,
            #[serde(default)]
            poster: Option<String>,
            /// 目录（Directory）没有 `posters`，只有 `poster_list` 数组。
            #[serde(default)]
            poster_list: Option<Vec<String>>,
            #[serde(default)]
            backdrops: Option<String>,
            #[serde(default)]
            logos: Option<String>,
            #[serde(default)]
            vote_average: Option<serde_json::Value>,
            #[serde(default)]
            release_date: Option<String>,
            #[serde(default)]
            runtime: Option<i32>,
            #[serde(default)]
            duration: Option<i64>,
            #[serde(default)]
            number_of_seasons: Option<i32>,
            #[serde(default)]
            number_of_episodes: Option<i32>,
            #[serde(default)]
            local_number_of_seasons: Option<i32>,
            #[serde(default)]
            local_number_of_episodes: Option<i32>,
            #[serde(default)]
            status: Option<String>,
            #[serde(default)]
            play_item_guid: Option<String>,
            #[serde(default)]
            single_child_guid: Option<String>,
            #[serde(default)]
            media_stream: Option<MediaStreamDto>,
            #[serde(default)]
            is_favorite: i32,
            #[serde(default)]
            is_watched: i32,
        }

        let path = format!("/item/{}", item_id);
        let env: ApiEnvelope<serde_json::Value> =
            self.send(Method::GET, &path, &BTreeMap::new(), None)?;

        let value = env.data.unwrap_or(serde_json::Value::Null);

        let d: DetailDto = serde_json::from_value(value).unwrap_or_default();
        let title = d.title.clone().unwrap_or_default();
        let episode_count = d
            .number_of_episodes
            .filter(|v| *v > 0)
            .or_else(|| parse_episode_count(&title));

        Ok(MediaDetail {
            id: d
                .guid
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| item_id.to_string()),
            title,
            kind: MediaKind::from_raw(d.item_type.as_deref().unwrap_or("")),
            original_title: empty_to_none(d.original_title.unwrap_or_default()),
            overview: empty_to_none(d.overview.unwrap_or_default()),
            poster_path: empty_to_none(d.posters.unwrap_or_default())
                .or_else(|| empty_to_none(d.poster.unwrap_or_default()))
                .or_else(|| {
                    d.poster_list
                        .and_then(|list| list.into_iter().find(|s| !s.is_empty()))
                }),
            backdrop_path: empty_to_none(d.backdrops.unwrap_or_default()),
            logo_path: empty_to_none(d.logos.unwrap_or_default()),
            rating: d.vote_average.as_ref().and_then(json_number),
            release_date: empty_to_none(d.release_date.unwrap_or_default()),
            runtime_seconds: match (d.runtime, d.duration) {
                (Some(m), _) if m > 0 => Some(m as u64 * 60),
                (_, Some(sec)) if sec > 0 => Some(sec as u64),
                _ => None,
            },
            season_count: d.number_of_seasons.filter(|v| *v > 0),
            local_season_count: d.local_number_of_seasons.filter(|v| *v > 0),
            episode_count,
            local_episode_count: d.local_number_of_episodes.filter(|v| *v > 0),
            status: empty_to_none(d.status.unwrap_or_default()),
            resolution: first_string(
                d.media_stream.as_ref().and_then(|m| m.resolutions.as_ref()),
            ),
            audio_type: first_string(
                d.media_stream.as_ref().and_then(|m| m.audio_type.as_ref()),
            ),
            color_range: first_string(
                d.media_stream
                    .as_ref()
                    .and_then(|m| m.color_range_type.as_ref()),
            ),
            play_item_id: empty_to_none(d.play_item_guid.unwrap_or_default()),
            single_child_id: empty_to_none(d.single_child_guid.unwrap_or_default()),
            is_favorite: Some(d.is_favorite > 0),
            is_watched: Some(d.is_watched > 0),
        })
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

        if let Ok(mut cache) = self.media_cache.lock() {
            cache.insert(item_id.to_string(), info.media_guid.clone());
        }

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

    /// 详情页「媒体信息」：`/play/info` 拿 media_guid，再 `/stream` 取轨道明细。
    ///
    /// 飞牛给的字段没有 Emby 全，取不到的项留空，界面自动跳过。
    pub fn media_info(&self, item_id: &str) -> Result<MediaInfo> {
        #[derive(Deserialize, Default)]
        struct InfoDto {
            #[serde(default)]
            media_guid: String,
        }

        // 播放过一次就有缓存，详情页不用再问一遍服务器。
        let cached = self
            .media_cache
            .lock()
            .ok()
            .and_then(|c| c.get(item_id).cloned())
            .unwrap_or_default();

        let media_guid = if cached.is_empty() {
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

            if let Ok(mut cache) = self.media_cache.lock() {
                cache.insert(item_id.to_string(), info.media_guid.clone());
            }

            info.media_guid
        } else {
            cached
        };

        // 新版接口（界面「文件媒体信息」用的就是它）：GET /stream/list/<media_guid>，
        // 字段是 ffprobe 那套 snake_case；老服务器没有这个端点时退回 POST /stream。
        let list_path = format!("/stream/list/{}", media_guid);
        let data = match self.send::<serde_json::Value>(
            Method::GET,
            &list_path,
            &BTreeMap::new(),
            None,
        ) {
            Ok(env) => env.data,
            Err(_) => None,
        };

        let data = match data {
            Some(value) if !value.is_null() => value,
            _ => {
                let stream_body = compact_json(&serde_json::json!({
                    "media_guid": media_guid,
                    "ip": "00000000-0000-4000-8000-000000000000",
                    "header": { "User-Agent": ["DVPlayer"] }
                }))?;
                let raw: ApiEnvelope<serde_json::Value> = self.send(
                    Method::POST,
                    "/stream",
                    &BTreeMap::new(),
                    Some(&stream_body),
                )?;
                raw.data
                    .ok_or_else(|| MediaError::Other("服务器没有返回媒体信息".into()))?
            }
        };

        let video = data.get("video_stream").map(|v| {
            let resolution = pick_str(v, &["resolution_type"]);
            let color = pick_str(v, &["color_range_type", "color_range"])
                .or_else(|| Some("SDR".into()));

            // 卡片标题：`1080p SDR`，和服务器自己的「文件媒体信息」一致。
            let title = [resolution.clone(), color.clone()]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(" ");

            VideoInfo {
                title: (!title.is_empty()).then_some(title),
                codec: pick_str(v, &["codec_name", "codec"]).map(|c| c.to_uppercase()),
                width: pick_i32(v, &["width"]),
                height: pick_i32(v, &["height"]),
                frame_rate: pick_f64(v, &["avg_frame_rate", "frame_rate", "r_frame_rate"]),
                bit_rate: pick_i64(v, &["bps", "bit_rate", "bitrate"]),
                color_range: color,
                profile: pick_str(v, &["profile"]),
                level: pick_f64(v, &["level"]),
                aspect_ratio: pick_str(v, &["display_aspect_ratio", "aspect_ratio"]),
                // 飞牛给的是 `progressive=1`，取反才是交错。
                interlaced: pick_bool(v, &["progressive"]).map(|p| !p).or_else(|| {
                    pick_bool(v, &["is_interlaced", "interlaced", "field_order"])
                }),
                bit_depth: pick_i32(v, &["bit_depth", "bits_per_raw_sample"]),
                pixel_format: pick_str(v, &["pix_fmt", "pixel_format"]),
                dolby_vision: pick_i32(v, &["dv_profile"]).unwrap_or(0) > 0,
            }
        });

        let audios = data
            .get("audio_streams")
            .and_then(|v| v.as_array())
            .map(|list| {
                list.iter()
                    .map(|a| AudioInfo {
                        title: pick_str(a, &["title"]),
                        // 飞牛没识别出语言时写 `und`，界面显示「--」更清楚。
                        language: pick_str(a, &["language"])
                            .and_then(|l| language_label(&l)),
                        codec: pick_str(a, &["codec_name", "codec"]).map(|c| c.to_uppercase()),
                        profile: pick_str(a, &["profile"]),
                        layout: pick_str(a, &["channel_layout"]),
                        bit_rate: pick_i64(a, &["bps", "bit_rate", "bitrate"]),
                        channels: pick_i32(a, &["channels"]),
                        sample_rate: pick_i32(a, &["sample_rate"]),
                        is_default: pick_i32(a, &["is_default"]).unwrap_or(0) > 0,
                        is_external: pick_i32(a, &["is_external"]).unwrap_or(0) > 0,
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();

        let subtitles = data
            .get("subtitle_streams")
            .and_then(|v| v.as_array())
            .map(|list| {
                list.iter()
                    .map(|t| SubtitleInfo {
                        title: pick_str(t, &["title"]),
                        language: pick_str(t, &["language"])
                            .and_then(|l| language_label(&l)),
                        codec: pick_str(t, &["codec_name", "codec"]).map(|c| c.to_uppercase()),
                        format: pick_str(t, &["format"]),
                        is_default: pick_i32(t, &["is_default"]).unwrap_or(0) > 0,
                        is_bitmap: pick_i32(t, &["is_bitmap"]).unwrap_or(0) > 0,
                        is_external: pick_i32(t, &["is_external"]).unwrap_or(0) > 0,
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();

        Ok(MediaInfo {
            video,
            audios,
            subtitles,
        })
    }

    /// 演职人员：`POST /person/list/<guid>`。
    ///
    /// 这个端点各版本行为不一致（有的要空 body、有的要 GET），按顺序试一遍，
    /// 第一个给出非空列表的为准；全空就是服务器没刮到人。
    pub fn people(&self, item_id: &str) -> Result<Vec<Person>> {
        let path = format!("/person/list/{}", item_id);
        let empty_body = compact_json(&serde_json::json!({}))?;
        let guid_body = compact_json(&serde_json::json!({ "item_guid": item_id }))?;

        // 端点有效时可能只回 `{"list":[],"total":0}`——那也算拿到答案，别再换姿势问。
        let attempts = [
            (Method::POST, path.as_str(), None),
            (Method::POST, path.as_str(), Some(empty_body.as_str())),
            (Method::POST, "/person/list", Some(guid_body.as_str())),
        ];

        let mut data = serde_json::Value::Null;

        for (method, target, body) in attempts {
            let Ok(env) = self.send::<serde_json::Value>(
                method.clone(),
                target,
                &BTreeMap::new(),
                body,
            ) else {
                continue;
            };

            if let Some(value) = env.data.filter(|v| !v.is_null()) {
                data = value;
                break;
            }
        }

        let Some(list) = list_of(&data) else {
            return Ok(Vec::new());
        };

        Ok(list
            .iter()
            .filter_map(|p| {
                let name = pick_str(p, &["name", "person_name", "title"])?;
                let image = pick_str(
                    p,
                    &["profile_path", "poster", "avatar", "image", "thumb", "poster_path"],
                )
                    // 外部完整地址走不了 sys/img，丢掉。
                    .filter(|path| !path.starts_with("http"));

                Some(Person {
                    id: pick_str(p, &["guid", "person_guid", "id"]).unwrap_or_default(),
                    name,
                    role: pick_str(p, &["character", "role", "actor_role"]),
                    job: pick_str(p, &["job", "type", "position", "department"])
                        .and_then(|job| job_label(&job)),
                    image_path: image,
                })
            })
            .collect())
    }

    /// 演员作品：`GET /item/list?person_guid=<guid>`（和库列表同一个端点，
    /// 只是多带一个 person_guid 过滤）。
    /// 某个人的作品：`POST /person/item/list`。
    ///
    /// 飞牛网页的人物页（`/v/person/<guid>`）就是调这个：body 带 `person_guid`、
    /// 分页和 `job` 过滤。之前用的 `POST /item/list` + person_guid 会把过滤条件
    /// 忽略掉——随便点谁都返回整库的前 500 条。
    pub fn person_works(&self, person_id: &str) -> Result<Vec<MediaItem>> {
        #[derive(Deserialize, Default)]
        struct ListDto {
            #[serde(default)]
            list: Option<Vec<ItemDto>>,
        }

        // 演职人员卡上可能是演员 / 导演 / 编剧，按顺序试，最后不带过滤兜一次。
        for job in [Some("Actor"), Some("Director"), Some("Writer"), None] {
            let mut body = serde_json::json!({
                "person_guid": person_id,
                "page": 1,
                "page_size": 200,
                "sort_column": "update_time",
                "sort_type": "desc",
            });

            if let Some(job) = job {
                body["job"] = serde_json::Value::from(job);
            }

            let body = compact_json(&body)?;
            let env: ApiEnvelope<serde_json::Value> =
                self.send(Method::POST, "/person/item/list", &BTreeMap::new(), Some(&body))?;

            let raw = env.data.unwrap_or(serde_json::Value::Null);

            let data: ListDto = serde_json::from_value(raw).unwrap_or_default();
            let items: Vec<MediaItem> = data
                .list
                .unwrap_or_default()
                .into_iter()
                .map(|d| self.map_item(d))
                .collect();

            if !items.is_empty() {
                return Ok(items);
            }
        }

        Ok(Vec::new())
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

        let envelope: ApiEnvelope<T> =
            serde_json::from_str(&text).map_err(|e| MediaError::Api {
                code: status.as_u16() as i64,
                msg: format!(
                    "parse error at {}:{} ({}) | {}",
                    e.line(),
                    e.column(),
                    e,
                    truncate(&text, 160)
                ),
            })?;

        Ok(envelope)
    }
}

/// 按**字符**截断：`&s[..n]` 切在 UTF-8 字符中间会 panic（中文响应很常见）。
fn truncate(value: &str, max: usize) -> String {
    match value.char_indices().nth(max) {
        Some((idx, _)) => format!("{}…", &value[..idx]),
        None => value.to_string(),
    }
}

/// 飞牛的评分字段有时是 `"0"`、有时是 `8.046...`，统一成 f64。
fn json_number(value: &serde_json::Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str().and_then(|s| s.parse().ok()))
        .filter(|v| *v > 0.0)
}

fn empty_to_none(value: String) -> Option<String> {
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

/// 从标题里认集号：`S01E76`、`第 76 集`、`EP06`。
///
/// 刮削好的剧集由服务器给 `episode_number`，这里只是给没刮削的目录兜底；
/// 放在核心里，四端（桌面 / Android / TV）看到的集号才一致。
pub(crate) fn parse_episode_number(title: &str) -> Option<i32> {
    parse_sxxexx(title)
        .or_else(|| parse_between(title, '第', '集'))
        .or_else(|| parse_ep_prefix(title))
}

/// 从标题里认总集数，只认括号里的：`异能寻生机（76集）`。
///
/// 「第 76 集」是单集标题，不能当总集数，所以必须有括号。
pub(crate) fn parse_episode_count(title: &str) -> Option<i32> {
    let chars: Vec<char> = title.chars().collect();

    for (i, &c) in chars.iter().enumerate() {
        if c != '集' {
            continue;
        }

        // 往前跳过空格，再取连续数字。
        let mut start = i;
        while start > 0 && chars[start - 1].is_whitespace() {
            start -= 1;
        }

        let end = start;
        while start > 0 && chars[start - 1].is_ascii_digit() {
            start -= 1;
        }

        if start == end || start == 0 {
            continue;
        }

        // 数字前面必须是左括号。
        if !matches!(chars[start - 1], '（' | '(') {
            continue;
        }

        let digits: String = chars[start..end].iter().collect();
        if let Ok(count) = digits.parse::<i32>() {
            if count > 0 && count <= 2000 {
                return Some(count);
            }
        }
    }

    None
}

/// `S01E76` / `s1e7`
fn parse_sxxexx(title: &str) -> Option<i32> {
    let bytes = title.as_bytes();

    for (i, &byte) in bytes.iter().enumerate() {
        if byte != b'S' && byte != b's' {
            continue;
        }

        let mut j = i + 1;
        let mut season_len = 0;
        while j < bytes.len() && bytes[j].is_ascii_digit() && season_len < 2 {
            j += 1;
            season_len += 1;
        }

        if season_len == 0 || j >= bytes.len() || (bytes[j] != b'E' && bytes[j] != b'e') {
            continue;
        }

        j += 1;
        let mut episode = String::new();
        while j < bytes.len() && bytes[j].is_ascii_digit() && episode.len() < 4 {
            episode.push(bytes[j] as char);
            j += 1;
        }

        if let Ok(number) = episode.parse::<i32>() {
            if number > 0 {
                return Some(number);
            }
        }
    }

    None
}

/// `第 76 集`
fn parse_between(title: &str, start: char, end: char) -> Option<i32> {
    let offset = title.find(start)?;
    let rest = &title[offset + start.len_utf8()..];
    let tail = rest.find(end)?;
    let digits: String = rest[..tail].chars().filter(|c| !c.is_whitespace()).collect();

    digits.parse::<i32>().ok().filter(|n| *n > 0)
}

/// `EP06`
fn parse_ep_prefix(title: &str) -> Option<i32> {
    let lower = title.to_ascii_lowercase();
    let offset = lower.rfind("ep")?;
    let rest = &title[offset + 2..];
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();

    digits.parse::<i32>().ok().filter(|n| *n > 0)
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
    /// 所属剧名，单集才有值。
    #[serde(default)]
    tv_title: Option<String>,
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

    // —— 刮削信息（TV / Movie 才有，Directory 多为空）——
    #[serde(default)]
    overview: Option<String>,
    #[serde(default)]
    backdrops: Option<String>,
    /// 评分：飞牛有时给字符串 "0"，有时给数字，用 Value 兜住。
    #[serde(default)]
    vote_average: Option<serde_json::Value>,
    #[serde(default)]
    release_date: Option<String>,
    // 服务器可能给 null，所以一律用 Option。
    #[serde(default)]
    number_of_seasons: Option<i32>,
    #[serde(default)]
    number_of_episodes: Option<i32>,
    #[serde(default)]
    local_number_of_episodes: Option<i32>,
    #[serde(default)]
    single_child_guid: Option<String>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    season_number: Option<i32>,
    #[serde(default)]
    episode_number: Option<i32>,
}

/// 列表和详情里的 `media_stream`。
///
/// 飞牛这几个字段的形状不稳定：`resolutions` 是数组，`audio_type` 在列表里
/// 可能是 `null`、也可能直接是字符串，详情里又是数组。用 `Value` 兜住，
/// 取值统一走 [`first_string`]。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct MediaStreamDto {
    #[serde(default)]
    pub resolutions: Option<serde_json::Value>,
    #[serde(default)]
    pub audio_type: Option<serde_json::Value>,
    #[serde(default)]
    pub color_range_type: Option<serde_json::Value>,
}

/// 演员列表：直接是数组，或包在 `list` / `persons` 里。
fn list_of(data: &serde_json::Value) -> Option<Vec<serde_json::Value>> {
    data.as_array()
        .cloned()
        .or_else(|| data.get("list").and_then(|v| v.as_array()).cloned())
        .or_else(|| data.get("persons").and_then(|v| v.as_array()).cloned())
        .or_else(|| data.get("data").and_then(|v| v.as_array()).cloned())
}

/// 从「字符串或字符串数组」里取第一个非空值。
pub(crate) fn first_string(value: Option<&serde_json::Value>) -> Option<String> {
    let value = value?;

    if let Some(text) = value.as_str() {
        return (!text.is_empty()).then(|| text.to_string());
    }

    value
        .as_array()?
        .iter()
        .filter_map(|item| item.as_str())
        .find(|text| !text.is_empty())
        .map(|text| text.to_string())
}

impl MediaSource for FnOsSource {
    fn kind(&self) -> &'static str {
        "fnos"
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn login(&mut self) -> Result<()> {
        FnOsSource::login(self)
    }

    fn libraries(&self) -> Result<Vec<MediaLibrary>> {
        FnOsSource::libraries(self)
    }

    fn items(
        &self,
        library_id: &str,
        page: i32,
        page_size: i32,
        query: &ListQuery,
    ) -> Result<Paged<MediaItem>> {
        FnOsSource::items(self, library_id, page, page_size, query)
    }

    fn children(
        &self,
        parent_id: &str,
        page: i32,
        page_size: i32,
        query: &ListQuery,
    ) -> Result<Paged<MediaItem>> {
        FnOsSource::children(self, parent_id, page, page_size, query)
    }

    fn genres(&self, scope_id: &str) -> Result<Vec<Genre>> {
        FnOsSource::genres(self, scope_id)
    }

    fn search(&self, query: &str) -> Result<Vec<MediaItem>> {
        FnOsSource::search(self, query)
    }

    fn detail(&self, item_id: &str) -> Result<MediaDetail> {
        FnOsSource::item_detail(self, item_id)
    }

    fn records(&self) -> Result<Vec<PlayRecord>> {
        FnOsSource::records(self)
    }

    fn report_progress(&self, item_id: &str, position: i64, duration: i64) -> Result<()> {
        FnOsSource::report_progress(self, item_id, position, duration)
    }

    fn set_favorite(&self, item_id: &str, favorite: bool) -> Result<()> {
        FnOsSource::set_favorite(self, item_id, favorite)
    }

    fn favorites(&self, page: i32, page_size: i32) -> Result<Paged<MediaItem>> {
        FnOsSource::favorites(self, page, page_size)
    }

    fn set_watched(&self, item_id: &str, watched: bool) -> Result<()> {
        FnOsSource::set_watched(self, item_id, watched)
    }

    fn remove_play_record(&self, item_id: &str) -> Result<()> {
        FnOsSource::remove_play_record(self, item_id)
    }

    fn play_source(&self, item_id: &str) -> Result<PlaySource> {
        FnOsSource::play_source(self, item_id)
    }

    fn media_info(&self, item_id: &str) -> Result<MediaInfo> {
        FnOsSource::media_info(self, item_id)
    }

    fn people(&self, item_id: &str) -> Result<Vec<Person>> {
        FnOsSource::people(self, item_id)
    }

    fn person_works(&self, person_id: &str) -> Result<Vec<MediaItem>> {
        FnOsSource::person_works(self, person_id)
    }

    fn image_source(&self, path: &str) -> Result<ImageSource> {
        FnOsSource::image_source(self, path)
    }
}
