//! Emby 适配器。Jellyfin 与 Emby 同源（同一套 API、同一套字段），
//! 差别只在产品名与个别版本细节，因此共用这一份实现。
//!
//! 认证有两条路：
//! - 用户名 + 密码：`POST /Users/AuthenticateByName` 换 `AccessToken`；
//! - API Key：把用户名留空、密码填 Key（界面上以后可以单独放一个「API Key」框）。
//!
//! 所有请求都带 `X-Emby-Token`。播放走 `Static=true` 直连原文件，不转码——
//! 解码交给 mpv，服务端只当文件服务器（和飞牛一致）。

use std::sync::Mutex;

use reqwest::blocking::Client;
use reqwest::Method;
use serde::de::DeserializeOwned;
use serde::Deserialize;

use crate::error::{percent_encode, MediaError, Result};
use crate::models::{
    Person,
    AudioInfo, MediaInfo, SubtitleInfo, VideoInfo,
    AudioTrack, Genre, HttpHeader, ImageSource, ListQuery, MediaDetail, MediaItem, MediaKind,
    MediaLibrary, Paged, PlayRecord, PlaySource, SubtitleTrack,
};
use crate::sources::{job_label, language_label, login_error_context, redirect_note, subtitle_extension, MediaSource};

const TICKS_PER_SECOND: i64 = 10_000_000;
const CLIENT_VERSION: &str = "0.1.0";

/// 列表接口要的字段：不带 MediaStreams（单集几十条，翻页会很重）。
const LIST_FIELDS: &str = "Overview,ProductionYear,RunTimeTicks,UserData,ImageTags,\
BackdropImageTags,ParentId,SeriesId,SeriesName,IndexNumber,ParentIndexNumber,\
ChildCount,RecursiveItemCount,CommunityRating,Status,PremiereDate";

/// 详情 / 播放要的字段：多出原名、轨道、文件路径。
const DETAIL_FIELDS: &str = "Overview,ProductionYear,RunTimeTicks,UserData,ImageTags,\
BackdropImageTags,ParentId,SeriesId,SeriesName,IndexNumber,ParentIndexNumber,\
ChildCount,RecursiveItemCount,CommunityRating,OfficialRating,Status,PremiereDate,\
OriginalTitle,MediaStreams,MediaSources,Path,Container,PrimaryImageAspectRatio,People,\
ProviderIds";

pub struct EmbySource {
    pub id: String,
    pub name: String,
    /// 界面上显示的产品名（`Emby` / `Jellyfin`）：两者共用这份实现，
    /// 报错和提示里不能互相叫错名字。
    label: String,
    pub base: String,
    username: String,
    password: String,
    token: Option<String>,
    user_id: Option<String>,
    http: Client,
    /// 用户设的 HTTP 代理；空表示直连。
    proxy: String,
    /// 当前播放会话。Emby 的进度上报要 `MediaSourceId` + `PlaySessionId`，
    /// 每 10 秒一次不能都去查 PlaybackInfo，播放开始时记下来。
    play: Mutex<Option<PlaySession>>,
}

/// 一次播放会话：`Sessions/Playing` 系列接口的身份。
struct PlaySession {
    item_id: String,
    media_source_id: String,
    id: String,
    /// 已经发过 `Sessions/Playing`（服务端要求先注册会话再报进度）。
    started: bool,
}

impl EmbySource {
    pub fn new(
        id: String,
        name: String,
        label: String,
        base: String,
        username: String,
        password: String,
        proxy: String,
    ) -> Self {
        Self {
            id,
            name,
            label,
            base: base.trim_end_matches('/').to_string(),
            username,
            password,
            token: None,
            user_id: None,
            http: super::http_client(&proxy),
            proxy,
            play: Mutex::new(None),
        }
    }

    pub fn login(&mut self) -> Result<()> {
        if self.username.trim().is_empty() {
            // API Key 模式：把 Key 当 token 用，再查一次当前用户拿 UserId。
            let key = self.password.trim().to_string();
            if key.is_empty() {
                return Err(MediaError::Other(format!(
                    "{}：用户名或 API Key 至少填一个",
                    self.label
                )));
            }
            self.token = Some(key);
            self.user_id = Some(self.current_user_id()?);
            return Ok(());
        }

        #[derive(Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct LoginDto {
            #[serde(default)]
            access_token: String,
            #[serde(default)]
            user: Option<UserDto>,
        }

        let body = serde_json::json!({
            "Username": self.username,
            "Pw": self.password,
        });

        let url = self.url("/Users/AuthenticateByName", &[]);
        let client = self.client_header();
        let response = self
            .http
            .post(url.clone())
            .header("X-Emby-Authorization", client.clone())
            .header("Authorization", client)
            .header("Content-Type", "application/json")
            .body(body.to_string())
            .send()?;

        // 401 时把请求地址、状态码和最终地址一起写进错误：反代把 http 301 到
        // https 时，POST 会被改写成 GET，服务端回的就是「账号不对」。
        let status = response.status();
        let final_url = response.url().as_str().to_string();

        let text = match self.read_body(response) {
            Ok(text) => text,
            Err(err) => {
                return Err(login_error_context(
                    &self.label,
                    &url,
                    &final_url,
                    status.as_u16(),
                    err,
                ))
            }
        };

        let parsed: LoginDto = serde_json::from_str(&text).map_err(|e| MediaError::Api {
            code: 0,
            msg: format!(
                "{} 登录返回无法解析（HTTP {}）：{e}｜{}{}",
                self.label,
                status.as_u16(),
                truncate(&text, 160),
                redirect_note(&url, &final_url)
            ),
        })?;

        if parsed.access_token.is_empty() {
            return Err(MediaError::Other(format!(
                "{} 登录失败：没有拿到 AccessToken",
                self.label
            )));
        }

        self.token = Some(parsed.access_token);
        self.user_id = match parsed.user {
            Some(user) if !user.id.is_empty() => Some(user.id),
            _ => Some(self.current_user_id()?),
        };

        Ok(())
    }

    /// 当前用户 id：API Key 模式与登录后补查都走这里。
    fn current_user_id(&self) -> Result<String> {
        let user: UserDto = self.get("/Users/Me", &[])?;
        if user.id.is_empty() {
            return Err(MediaError::Other(format!("{}：拿不到用户 id", self.label)));
        }
        Ok(user.id)
    }

    fn user_id(&self) -> Result<&str> {
        self.user_id
            .as_deref()
            .ok_or_else(|| MediaError::Other(format!("{} 未登录", self.label)))
    }

    pub fn libraries(&self) -> Result<Vec<MediaLibrary>> {
        #[derive(Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct ViewsDto {
            #[serde(default)]
            items: Vec<ItemDto>,
        }

        let user = self.user_id()?;
        let views: ViewsDto = self.get(&format!("/Users/{user}/Views"), &[])?;

        Ok(views
            .items
            .into_iter()
            .map(|v| MediaLibrary {
                poster_path: has_image(&v, "Primary").then(|| format!("{}/Primary", v.id)),
                category: v.collection_type.unwrap_or_default(),
                id: v.id,
                title: v.name,
                source_id: self.id.clone(),
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
        self.list(library_id, page, page_size, query)
    }

    pub fn children(
        &self,
        parent_id: &str,
        page: i32,
        page_size: i32,
        query: &ListQuery,
    ) -> Result<Paged<MediaItem>> {
        self.list(parent_id, page, page_size, query)
    }

    /// Emby 的风格就是 `Genres` 名字，库内 `ParentId` 限定范围。
    pub fn genres(&self, scope_id: &str) -> Result<Vec<Genre>> {
        let query = vec![
            ("ParentId", scope_id.to_string()),
            ("Recursive", "true".into()),
            ("Fields", "ItemType".into()),
        ];

        let dto: ItemQueryDto = self.get("/Genres", &query)?;
        Ok(dto
            .items
            .iter()
            .filter(|d| !d.name.is_empty())
            .map(|d| Genre {
                id: d.name.clone(),
                title: d.name.clone(),
            })
            .collect())
    }

    /// Emby / Jellyfin 的搜索：`/Users/{uid}/Items?searchTerm=`，跨库递归。
    pub fn search(&self, query: &str) -> Result<Vec<MediaItem>> {
        let q = query.trim();
        if q.is_empty() {
            return Ok(Vec::new());
        }

        let user = self.user_id()?;
        let params = vec![
            ("SearchTerm", q.to_string()),
            ("Recursive", "true".into()),
            ("Limit", "60".into()),
            ("IncludeItemTypes", "Movie,Series,Episode".into()),
            ("Fields", LIST_FIELDS.into()),
            ("EnableImages", "true".into()),
            ("ImageTypeLimit", "1".into()),
            ("EnableImageTypes", "Primary,Backdrop".into()),
        ];

        let dto: ItemQueryDto = self.get(&format!("/Users/{user}/Items"), &params)?;
        Ok(dto.items.iter().map(|d| self.map_item(d)).collect())
    }

    fn list(
        &self,
        parent_id: &str,
        page: i32,
        page_size: i32,
        opts: &ListQuery,
    ) -> Result<Paged<MediaItem>> {
        let user = self.user_id()?;
        // 用 i64 算偏移：page/size 都是 i32，极端值相乘会溢出成负数。
        let start = (i64::from(page.max(1) - 1) * i64::from(page_size.max(1))).to_string();
        let limit = page_size.to_string();

        let include_types: Vec<&str> = match opts.kinds.as_slice() {
            [] => Vec::new(),
            kinds => kinds
                .iter()
                .flat_map(|kind| match kind.as_str() {
                    "tv" => vec!["Series"],
                    "movie" => vec!["Movie"],
                    "folder" => vec!["Folder", "BoxSet"],
                    _ => Vec::new(),
                })
                .collect(),
        };

        let sort_by = match opts.sort.as_deref() {
            Some("name") => "SortName",
            Some("added") => "DateCreated",
            Some("release") => "PremiereDate",
            Some("rating") => "CommunityRating",
            _ => "SortName",
        };

        let mut query = vec![
            ("ParentId", parent_id.to_string()),
            ("Recursive", "false".into()),
            ("StartIndex", start),
            ("Limit", limit),
            ("SortBy", sort_by.to_string()),
            (
                "SortOrder",
                if opts.descending { "Descending" } else { "Ascending" }.into(),
            ),
            ("Fields", LIST_FIELDS.into()),
            ("EnableImages", "true".into()),
            ("ImageTypeLimit", "1".into()),
            ("EnableImageTypes", "Primary,Backdrop".into()),
        ];

        if !include_types.is_empty() {
            query.push(("IncludeItemTypes", include_types.join(",")));
        }
        if let Some(genre) = opts.genre.as_deref().filter(|g| !g.is_empty()) {
            query.push(("Genres", genre.to_string()));
        }

        let dto: ItemQueryDto = self.get(&format!("/Users/{user}/Items"), &query)?;

        Ok(Paged {
            total: dto.total_record_count,
            items: dto.items.iter().map(|d| self.map_item(d)).collect(),
            page,
            page_size,
        })
    }

    pub fn detail(&self, item_id: &str) -> Result<MediaDetail> {
        let d = self.item(item_id)?;
        let item = self.map_item(&d);
        let playable = matches!(
            item.kind,
            MediaKind::Movie | MediaKind::Episode | MediaKind::Video
        );

        Ok(MediaDetail {
            id: item.id.clone(),
            title: item.title.clone(),
            kind: item.kind,
            original_title: d.original_title.clone(),
            overview: item.overview.clone(),
            poster_path: item.poster_path.clone(),
            backdrop_path: item.backdrop_path.clone(),
            logo_path: has_image(&d, "Logo").then(|| format!("{item_id}/Logo")),
            rating: item.rating,
            release_date: item.release_date.clone(),
            runtime_seconds: item.runtime_seconds,
            season_count: item.season_count,
            local_season_count: item.season_count,
            episode_count: item.episode_count,
            local_episode_count: item.local_episode_count,
            status: item.status.clone(),
            resolution: item.resolution.clone(),
            audio_type: None,
            color_range: None,
            play_item_id: playable.then(|| item.id.clone()),
            single_child_id: item.single_child_id,
            is_favorite: d.user_data.as_ref().map(|u| u.is_favorite),
            is_watched: d.user_data.as_ref().map(|u| u.played),
            tmdb_id: d
                .provider_ids
                .as_ref()
                .and_then(|p| p.tmdb.clone())
                .filter(|s| !s.is_empty()),
            imdb_id: d
                .provider_ids
                .as_ref()
                .and_then(|p| p.imdb.clone())
                .filter(|s| !s.is_empty()),
        })
    }

    pub fn records(&self) -> Result<Vec<PlayRecord>> {
        let user = self.user_id()?;

        // `/Items/Resume` 就是服务器维护的「继续观看」，按最近播放倒序。
        let query = vec![
            ("MediaTypes", "Video".into()),
            ("Limit", "30".into()),
            ("Fields", LIST_FIELDS.into()),
            ("EnableImages", "true".into()),
            ("ImageTypeLimit", "1".into()),
            ("EnableImageTypes", "Primary".into()),
        ];

        let dto: ItemQueryDto = self.get(&format!("/Users/{user}/Items/Resume"), &query)?;

        Ok(dto
            .items
            .iter()
            .filter_map(|d| {
                let item = self.map_item(d);
                let duration = item.runtime_seconds.unwrap_or(0);
                if duration == 0 {
                    return None;
                }

                let position = d
                    .user_data
                    .as_ref()
                    .map(|u| u.playback_position_ticks.max(0) as u64 / TICKS_PER_SECOND as u64)
                    .unwrap_or(0);

                Some(PlayRecord {
                    item_id: item.id,
                    title: item.title,
                    source_id: self.id.clone(),
                    series_title: d.series_name.clone().filter(|s| !s.is_empty()),
                    parent_id: d.parent_id.clone().filter(|s| !s.is_empty()),
                    season_number: d.parent_index_number.filter(|v| *v > 0),
                    episode_number: d.index_number.filter(|v| *v > 0),
                    poster_path: item.poster_path,
                    position_seconds: position.min(duration),
                    duration_seconds: duration,
                    last_played: d
                        .user_data
                        .as_ref()
                        .and_then(|u| u.last_played_date.as_deref())
                        .and_then(parse_iso8601_seconds),
                })
            })
            .collect())
    }

    /// 回写进度：走 `Sessions/Playing/Progress`，和 Emby 自己客户端一致。
    ///
    /// 有些服务端的反代没放行 `/Users/{id}/Items/{id}/UserData`（Monta HD 的
    /// Emby 4.9 就直接 404），所以失败时退回老写法。
    pub fn report_progress(&self, item_id: &str, position: i64, _duration: i64) -> Result<()> {
        self.report_session(item_id, position, false)
            .or_else(|_| self.write_user_data(item_id, position))
    }

    /// 播放结束 / 关窗：`Stopped` 之后服务端才把位置写进 UserData。
    pub fn report_stopped(&self, item_id: &str, position: i64, _duration: i64) -> Result<()> {
        self.report_session(item_id, position, true)
            .or_else(|_| self.write_user_data(item_id, position))
    }

    /// 老写法：直接改用户数据。适合没开 Sessions 路由的服务端。
    fn write_user_data(&self, item_id: &str, position: i64) -> Result<()> {
        let user = self.user_id()?;
        let body = serde_json::json!({
            "PlaybackPositionTicks": position.max(0) * TICKS_PER_SECOND,
        });

        self.post_empty(&format!("/Users/{user}/Items/{item_id}/UserData"), &body)
    }

    /// `Sessions/Playing` 系列要的播放会话；没播过就先查一次 PlaybackInfo。
    fn session_for(&self, item_id: &str) -> Result<(String, String)> {
        if let Ok(slot) = self.play.lock() {
            if let Some(play) = slot.as_ref() {
                if play.item_id == item_id {
                    return Ok((play.media_source_id.clone(), play.id.clone()));
                }
            }
        }

        let user = self.user_id()?;
        let info: PlaybackInfoDto = self
            .post_json(
                &format!("/Items/{item_id}/PlaybackInfo"),
                &serde_json::json!({ "UserId": user }),
            )
            .unwrap_or_default();
        let media_id = info
            .media_sources
            .first()
            .map(|m| m.id.clone())
            .unwrap_or_default();
        let id = new_session_id();

        if let Ok(mut slot) = self.play.lock() {
            *slot = Some(PlaySession {
                item_id: item_id.to_string(),
                media_source_id: media_id.clone(),
                id: id.clone(),
                started: false,
            });
        }

        Ok((media_id, id))
    }

    fn report_session(&self, item_id: &str, position: i64, stopped: bool) -> Result<()> {
        let (media_id, session_id) = self.session_for(item_id)?;
        let body = serde_json::json!({
            "ItemId": item_id,
            "MediaSourceId": media_id,
            "PlaySessionId": session_id,
            "PositionTicks": position.max(0) * TICKS_PER_SECOND,
            "IsPaused": false,
            "IsMuted": false,
            "PlayMethod": "DirectStream",
            "RepeatMode": "RepeatNone",
            "VolumeLevel": 100,
            "CanSeek": true,
            "PlaylistIndex": 0,
            "PlaylistLength": 0,
        });

        if stopped {
            let result = self.post_empty("/Sessions/Playing/Stopped", &body);
            if let Ok(mut slot) = self.play.lock() {
                *slot = None;
            }
            return result;
        }

        // 第一次先注册会话，服务端才会认后面的 Progress。
        let first = match self.play.lock() {
            Ok(mut slot) => match slot.as_mut() {
                Some(play) if play.item_id == item_id && !play.started => {
                    play.started = true;
                    true
                }
                _ => false,
            },
            Err(_) => false,
        };
        if first {
            // 先注册会话，服务端才认后面的 Progress；注册失败就别假装成功了。
            self.post_empty("/Sessions/Playing", &body)?;
        }

        self.post_empty("/Sessions/Playing/Progress", &body)
    }

    pub fn play_source(&self, item_id: &str) -> Result<PlaySource> {
        let item = self.item(item_id)?;
        let user = self.user_id()?;
        let info: PlaybackInfoDto = self
            .post_json(
                &format!("/Items/{item_id}/PlaybackInfo"),
                &serde_json::json!({ "UserId": user }),
            )
            .map_err(|err| {
                // 以前 `unwrap_or_default()` 把错误吞掉，返回一个没有 MediaSourceId、
                // 没有轨道、时长 0 的「成功」，播放器只能黑屏。
                MediaError::Other(format!("读取播放信息失败：{err}"))
            })?;

        let media = info.media_sources.first().cloned().unwrap_or_default();
        let media_id = media.id.clone();

        // 进度上报要用这个会话；换集时旧的自动作废。
        if let Ok(mut slot) = self.play.lock() {
            *slot = Some(PlaySession {
                item_id: item_id.to_string(),
                media_source_id: media_id.clone(),
                id: new_session_id(),
                started: false,
            });
        }

        // 静态直连：原文件不转码，容器与轨道都由 mpv 自己解。
        // token 走 `X-Emby-Token` 请求头（见 PlaySource.headers），
        // 不拼进 URL：URL 会进日志 / 错误文本，等于把 token 写进文件。
        let mut url = format!("{}/Videos/{item_id}/stream?Static=true", self.base);
        if !media_id.is_empty() {
            url.push_str(&format!("&MediaSourceId={}", percent_encode(&media_id)));
        }

        let streams = if media.media_streams.is_empty() {
            item.media_streams.clone().unwrap_or_default()
        } else {
            media.media_streams.clone()
        };

        let video = streams.iter().find(|s| s.kind == "Video").cloned();
        let resolution = video.as_ref().and_then(resolution_label);
        let color_range = video.as_ref().and_then(color_label);
        let dolby_vision = video
            .as_ref()
            .map(|v| {
                v.video_range_type
                    .as_deref()
                    .map(|r| r.eq_ignore_ascii_case("DOVI"))
                    .unwrap_or(false)
                    || v.dolby_vision_profile.unwrap_or(0) > 0
            })
            .unwrap_or(false);

        let audio_streams: Vec<AudioTrack> = streams
            .iter()
            .filter(|s| s.kind == "Audio")
            .map(|s| AudioTrack {
                guid: s.index.to_string(),
                language: s.language.clone().filter(|v| !v.is_empty()),
                codec: s.codec.clone().filter(|v| !v.is_empty()),
                profile: s.profile.clone().filter(|v| !v.is_empty()),
                channels: s.channels.unwrap_or(0),
                is_default: s.is_default,
            })
            .collect();

        // 外挂字幕要给播放器一个能直接下载的地址（带服务器自己的路径），
        // 内嵌字幕在视频流里，不需要单独下载。
        let subtitle_streams: Vec<SubtitleTrack> = streams
            .iter()
            .filter(|s| s.kind == "Subtitle")
            .map(|s| {
                let is_bitmap = !s.is_text_subtitle_stream.unwrap_or(s.is_external);
                let url = s.is_external.then(|| {
                    let source = if media_id.is_empty() {
                        "-"
                    } else {
                        media_id.as_str()
                    };
                    format!(
                        "{}/Videos/{item_id}/{}/Subtitles/{}/Stream.{}",
                        self.base,
                        percent_encode(source),
                        s.index,
                        subtitle_extension(s.codec.as_deref().unwrap_or_default(), is_bitmap)
                    )
                });
                SubtitleTrack {
                    guid: s.index.to_string(),
                    language: s.language.clone().filter(|v| !v.is_empty()),
                    codec: s.codec.clone().filter(|v| !v.is_empty()),
                    format: s.codec.clone().filter(|v| !v.is_empty()),
                    is_external: s.is_external,
                    is_bitmap,
                    url,
                }
            })
            .collect();

        let position = item
            .user_data
            .as_ref()
            .map(|u| (u.playback_position_ticks.max(0) / TICKS_PER_SECOND) as u64)
            .unwrap_or(0);

        let duration = media
            .run_time_ticks
            .or(item.run_time_ticks)
            .map(|t| (t.max(0) / TICKS_PER_SECOND) as u64)
            .unwrap_or(0);

        Ok(PlaySource {
            item_id: item_id.to_string(),
            title: item.name.clone(),
            url,
            headers: self.auth_headers(),
            is_direct: true,
            disc: false,
            media_guid: if media_id.is_empty() {
                item_id.to_string()
            } else {
                media_id
            },
            video_guid: video.as_ref().map(|v| v.index.to_string()),
            audio_guid: audio_streams
                .iter()
                .find(|a| a.is_default)
                .map(|a| a.guid.clone()),
            subtitle_guid: None,
            position_seconds: position,
            duration_seconds: duration,
            overview: item.overview.clone(),
            poster_path: has_image(&item, "Primary").then(|| format!("{item_id}/Primary")),
            resolution,
            color_range,
            dolby_vision,
            video_codec: video.as_ref().and_then(|v| v.codec.clone()),
            audio_codec: audio_streams.first().and_then(|a| a.codec.clone()),
            audio_streams,
            subtitle_streams,
            proxy: self.proxy.clone(),
        })
    }

    /// 演职人员：条目详情里的 `People` 字段。
    pub fn people(&self, item_id: &str) -> Result<Vec<Person>> {
        let item = self.item(item_id)?;

        Ok(item
            .people
            .unwrap_or_default()
            .into_iter()
            .filter(|p| !p.name.is_empty())
            .map(|p| Person {
                image_path: p
                    .primary_image_tag
                    .as_deref()
                    .filter(|t| !t.is_empty())
                    .map(|_| format!("{}/Primary", p.id)),
                id: p.id,
                name: p.name,
                role: p.role.filter(|r| !r.is_empty()),
                job: p.kind.as_deref().and_then(job_label),
            })
            .collect())
    }

    /// 某个演员参演的作品：`/Items?PersonIds=<id>&Recursive=true`。
    pub fn person_works(&self, person_id: &str) -> Result<Vec<MediaItem>> {
        let user = self.user_id()?;
        let query = vec![
            ("PersonIds", person_id.to_string()),
            ("Recursive", "true".to_string()),
            ("IncludeItemTypes", "Movie,Series".to_string()),
            ("Fields", LIST_FIELDS.to_string()),
            ("SortBy", "ProductionYear,SortName".to_string()),
            ("SortOrder", "Descending".to_string()),
            ("Limit", "200".to_string()),
        ];

        let page: ItemQueryDto = self.get(&format!("/Users/{user}/Items"), &query)?;

        Ok(page.items.iter().map(|d| self.map_item(d)).collect())
    }

    /// 详情页「媒体信息」：一次 `PlaybackInfo` 就带全部轨道属性。
    pub fn media_info(&self, item_id: &str) -> Result<MediaInfo> {
        let item = self.item(item_id)?;
        let user = self.user_id()?;
        let info: PlaybackInfoDto = self
            .post_json(
                &format!("/Items/{item_id}/PlaybackInfo"),
                &serde_json::json!({ "UserId": user }),
            )
            .unwrap_or_default();

        let media = info.media_sources.first().cloned().unwrap_or_default();
        let path = media
            .path
            .clone()
            .or_else(|| item.path.clone())
            .filter(|p| !p.trim().is_empty());
        let streams = if media.media_streams.is_empty() {
            item.media_streams.clone().unwrap_or_default()
        } else {
            media.media_streams.clone()
        };

        let video = streams.iter().find(|s| s.kind == "Video").map(|v| {
            let label = [
                resolution_label(v).unwrap_or_default(),
                color_label(v).unwrap_or_else(|| "SDR".into()),
            ]
            .into_iter()
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(" ");

            VideoInfo {
                title: (!label.is_empty()).then_some(label),
                codec: v.codec.clone().filter(|s| !s.is_empty()).map(|c| c.to_uppercase()),
                width: v.width,
                height: v.height,
                frame_rate: v.frame_rate.or(v.average_frame_rate),
                bit_rate: v.bit_rate,
                color_range: color_label(v).or_else(|| Some("SDR".into())),
                profile: v.profile.clone().filter(|s| !s.is_empty()),
                level: v.level,
                aspect_ratio: v.aspect_ratio.clone().filter(|s| !s.is_empty()),
                interlaced: Some(v.is_interlaced),
                bit_depth: v.bit_depth,
                pixel_format: v.pixel_format.clone().filter(|s| !s.is_empty()),
                dolby_vision: v.dolby_vision_profile.unwrap_or(0) > 0
                    || v.video_range_type
                        .as_deref()
                        .map(|r| r.eq_ignore_ascii_case("DOVI"))
                        .unwrap_or(false),
            }
        });

        let audios = streams
            .iter()
            .filter(|s| s.kind == "Audio")
            .map(|a| AudioInfo {
                title: a
                    .title
                    .clone()
                    .or_else(|| a.display_title.clone())
                    .filter(|s| !s.is_empty()),
                language: a
                    .language
                    .as_deref()
                    .and_then(language_label),
                codec: a.codec.clone().filter(|s| !s.is_empty()).map(|c| c.to_uppercase()),
                profile: a.profile.clone().filter(|s| !s.is_empty()),
                layout: a.channel_layout.clone().filter(|s| !s.is_empty()),
                bit_rate: a.bit_rate,
                channels: a.channels,
                sample_rate: a.sample_rate,
                is_default: a.is_default,
                is_external: a.is_external,
            })
            .collect();

        let subtitles = streams
            .iter()
            .filter(|s| s.kind == "Subtitle")
            .map(|t| SubtitleInfo {
                title: t
                    .title
                    .clone()
                    .or_else(|| t.display_title.clone())
                    .filter(|s| !s.is_empty()),
                language: t.language.as_deref().and_then(language_label),
                codec: t.codec.clone().filter(|s| !s.is_empty()).map(|c| c.to_uppercase()),
                format: None,
                is_default: t.is_default,
                is_bitmap: matches!(t.is_text_subtitle_stream, Some(false)),
                is_external: t.is_external,
            })
            .collect();

        Ok(MediaInfo {
            path,
            video,
            audios,
            subtitles,
        })
    }

    /// 图片：`path` 形如 `{itemId}/Primary`、`{itemId}/Backdrop/0`、`{itemId}/Logo`。
    pub fn image_source(&self, path: &str) -> Result<ImageSource> {
        let (item_id, kind) = path
            .split_once('/')
            .ok_or_else(|| {
                MediaError::Other(format!("{} 图片路径不合法：{path}", self.label))
            })?;

        let width = if kind.starts_with("Backdrop") { 1600 } else { 800 };

        Ok(ImageSource {
            url: format!(
                "{}/Items/{}/Images/{}?maxWidth={}&quality=90",
                self.base,
                percent_encode(item_id),
                kind,
                width
            ),
            headers: self.auth_headers(),
            proxy: self.proxy.clone(),
        })
    }

    fn item(&self, item_id: &str) -> Result<ItemDto> {
        let user = self.user_id()?;
        let query = vec![("Fields", DETAIL_FIELDS.to_string())];
        self.get(&format!("/Users/{user}/Items/{item_id}"), &query)
    }

    fn map_item(&self, d: &ItemDto) -> MediaItem {
        let kind = map_kind(&d.item_type);
        let user = d.user_data.as_ref();

        let duration = d.run_time_ticks.unwrap_or(0).max(0) / TICKS_PER_SECOND;
        let position = user
            .map(|u| u.playback_position_ticks.max(0) / TICKS_PER_SECOND)
            .unwrap_or(0);

        let progress = if duration > 0 {
            (position as f64 / duration as f64).clamp(0.0, 1.0)
        } else {
            user.and_then(|u| u.played_percentage)
                .map(|v| (v / 100.0).clamp(0.0, 1.0))
                .unwrap_or(0.0)
        };

        // Season 的标题常常是「第 1 季」或空，用季号补一个可读的名字。
        let title = if d.name.trim().is_empty() {
            match (kind, d.index_number) {
                (MediaKind::Season, Some(n)) => format!("第 {n} 季"),
                (MediaKind::Episode, Some(n)) => format!("第 {n} 集"),
                _ => "(未命名)".to_string(),
            }
        } else {
            d.name.clone()
        };

        MediaItem {
            id: d.id.clone(),
            title,
            kind,
            source_id: self.id.clone(),
            poster_path: has_image(d, "Primary").then(|| format!("{}/Primary", d.id)),
            parent_id: d.parent_id.clone().filter(|s| !s.is_empty()),
            parent_title: d
                .series_name
                .clone()
                .or_else(|| d.season_name.clone())
                .filter(|s| !s.is_empty()),
            year: d.production_year,
            runtime_seconds: (duration > 0).then_some(duration as u64),
            progress,
            is_favorite: user.map(|u| u.is_favorite).unwrap_or(false),
            overview: d.overview.clone().filter(|s| !s.is_empty()),
            resolution: None,
            last_played: user
                .and_then(|u| u.last_played_date.as_deref())
                .and_then(parse_iso8601_seconds),

            season_number: d.parent_index_number.filter(|v| *v > 0),
            episode_number: d.index_number.filter(|v| *v > 0),
            // 剧集自己的 RecursiveItemCount 是总集数，ChildCount 是季数。
            episode_count: matches!(kind, MediaKind::Series).then(|| d.recursive_item_count).flatten(),
            local_episode_count: matches!(kind, MediaKind::Series)
                .then(|| d.recursive_item_count)
                .flatten(),
            season_count: matches!(kind, MediaKind::Series).then(|| d.child_count).flatten(),
            rating: d.community_rating,
            release_date: d.premiere_date.as_deref().map(|s| s.chars().take(10).collect()),
            status: d.status.clone().filter(|s| !s.is_empty()),
            backdrop_path: has_backdrop(d).then(|| format!("{}/Backdrop/0", d.id)),
            single_child_id: None,
            sources: Vec::new(),
        }
    }

    fn auth_headers(&self) -> Vec<HttpHeader> {
        self.token
            .as_ref()
            .map(|t| {
                vec![HttpHeader {
                    name: "X-Emby-Token".into(),
                    value: t.clone(),
                }]
            })
            .unwrap_or_default()
    }

    /// 客户端标识头。Emby 客户端用 `X-Emby-Authorization`、Jellyfin 用
    /// `Authorization`，两个都带上；有 token 时顺便写进 Token 字段。
    fn client_header(&self) -> String {
        let mut header = format!(
            "MediaBrowser Client=\"DVPlayer\", Device=\"Windows\", DeviceId=\"{}\", Version=\"{}\"",
            self.id, CLIENT_VERSION
        );

        if let Some(token) = &self.token {
            header.push_str(&format!(", Token=\"{token}\""));
        }

        header
    }

    fn url(&self, path: &str, query: &[(&str, String)]) -> String {
        if query.is_empty() {
            return format!("{}{}", self.base, path);
        }

        let qs = query
            .iter()
            .map(|(k, v)| format!("{}={}", percent_encode(k), percent_encode(v)))
            .collect::<Vec<_>>()
            .join("&");

        format!("{}{}?{}", self.base, path, qs)
    }

    fn send(
        &self,
        method: Method,
        path: &str,
        query: &[(&str, String)],
        body: Option<&serde_json::Value>,
    ) -> Result<String> {
        let mut request = self.http.request(method, self.url(path, query));
        let client = self.client_header();

        request = request
            .header("X-Emby-Authorization", client.clone())
            .header("Authorization", client);

        if let Some(token) = &self.token {
            request = request.header("X-Emby-Token", token);
        }

        if let Some(body) = body {
            request = request
                .header("Content-Type", "application/json")
                .body(body.to_string());
        }

        let response = request.send()?;
        super::ensure_same_host(&response, &self.base)?;
        self.read_body(response)
    }

    fn read_body(&self, response: reqwest::blocking::Response) -> Result<String> {
        let status = response.status();
        let text = response.text()?;

        if !status.is_success() {
            // Emby 出错时给 `{"Error":"..."}`，Jellyfin 给 ProblemDetails。
            let message = serde_json::from_str::<serde_json::Value>(&text)
                .ok()
                .and_then(|v| {
                    v.get("Error")
                        .or_else(|| v.get("error"))
                        .or_else(|| v.get("Message"))
                        .and_then(|m| m.as_str())
                        .map(|s| s.to_string())
                })
                .unwrap_or_else(|| truncate(&text, 160));

            return Err(MediaError::Api {
                code: status.as_u16() as i64,
                msg: message,
            });
        }

        Ok(text)
    }

    fn get<T: DeserializeOwned>(&self, path: &str, query: &[(&str, String)]) -> Result<T> {
        let text = self.send(Method::GET, path, query, None)?;
        serde_json::from_str(&text).map_err(|e| MediaError::Api {
            code: 0,
            msg: format!("{} 返回无法解析：{e}｜{}", self.label, truncate(&text, 160)),
        })
    }

    fn post_json<T: DeserializeOwned>(
        &self,
        path: &str,
        body: &serde_json::Value,
    ) -> Result<T> {
        let text = self.send(Method::POST, path, &[], Some(body))?;
        serde_json::from_str(&text).map_err(|e| MediaError::Api {
            code: 0,
            msg: format!("{} 返回无法解析：{e}｜{}", self.label, truncate(&text, 160)),
        })
    }

    fn post_empty(&self, path: &str, body: &serde_json::Value) -> Result<()> {
        self.send(Method::POST, path, &[], Some(body)).map(|_| ())
    }

    /// 收藏 / 取消收藏。
    pub fn set_favorite(&self, item_id: &str, favorite: bool) -> Result<()> {
        let user = self.user_id()?;
        let method = if favorite { Method::POST } else { Method::DELETE };
        self.send(
            method,
            &format!("/Users/{user}/FavoriteItems/{item_id}"),
            &[],
            None,
        )
        .map(|_| ())
    }

    /// 收藏列表：`Filters=IsFavorite`，跨库递归。
    pub fn favorites(&self, page: i32, page_size: i32) -> Result<Paged<MediaItem>> {
        let user = self.user_id()?;
        let start = ((page.max(1) - 1) * page_size.max(1)).to_string();
        let query = vec![
            ("Recursive", "true".to_string()),
            ("Filters", "IsFavorite".to_string()),
            ("StartIndex", start),
            ("Limit", page_size.to_string()),
            ("Fields", LIST_FIELDS.to_string()),
            ("EnableImages", "true".to_string()),
            ("ImageTypeLimit", "1".to_string()),
            ("EnableImageTypes", "Primary,Backdrop".to_string()),
        ];

        let dto: ItemQueryDto = self.get(&format!("/Users/{user}/Items"), &query)?;
        Ok(Paged {
            total: dto.total_record_count,
            items: dto.items.iter().map(|d| self.map_item(d)).collect(),
            page,
            page_size,
        })
    }

    /// 标记已观看 / 未观看。
    pub fn set_watched(&self, item_id: &str, watched: bool) -> Result<()> {
        let user = self.user_id()?;
        let method = if watched { Method::POST } else { Method::DELETE };
        self.send(
            method,
            &format!("/Users/{user}/PlayedItems/{item_id}"),
            &[],
            None,
        )
        .map(|_| ())
    }

    /// 移除观看记录：只清续播点，不动已看标记。
    pub fn remove_play_record(&self, item_id: &str) -> Result<()> {
        let user = self.user_id()?;
        // 不送 `Played: false`：那会把已看完的集改回未看。
        // 只把进度清零，UserData 的其他字段保持原样。
        let body = serde_json::json!({
            "PlaybackPositionTicks": 0,
        });
        self.send(
            Method::POST,
            &format!("/Users/{user}/Items/{item_id}/UserData"),
            &[],
            Some(&body),
        )
        .map(|_| ())
    }
}

impl MediaSource for EmbySource {
    fn kind(&self) -> &'static str {
        "emby"
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn login(&mut self) -> Result<()> {
        EmbySource::login(self)
    }

    fn libraries(&self) -> Result<Vec<MediaLibrary>> {
        EmbySource::libraries(self)
    }

    fn items(
        &self,
        library_id: &str,
        page: i32,
        page_size: i32,
        query: &ListQuery,
    ) -> Result<Paged<MediaItem>> {
        EmbySource::items(self, library_id, page, page_size, query)
    }

    fn children(
        &self,
        parent_id: &str,
        page: i32,
        page_size: i32,
        query: &ListQuery,
    ) -> Result<Paged<MediaItem>> {
        EmbySource::children(self, parent_id, page, page_size, query)
    }

    fn genres(&self, scope_id: &str) -> Result<Vec<Genre>> {
        EmbySource::genres(self, scope_id)
    }

    fn search(&self, query: &str) -> Result<Vec<MediaItem>> {
        EmbySource::search(self, query)
    }

    fn detail(&self, item_id: &str) -> Result<MediaDetail> {
        EmbySource::detail(self, item_id)
    }

    fn records(&self) -> Result<Vec<PlayRecord>> {
        EmbySource::records(self)
    }

    fn report_progress(&self, item_id: &str, position: i64, duration: i64) -> Result<()> {
        EmbySource::report_progress(self, item_id, position, duration)
    }

    fn report_stopped(&self, item_id: &str, position: i64, duration: i64) -> Result<()> {
        EmbySource::report_stopped(self, item_id, position, duration)
    }

    fn set_favorite(&self, item_id: &str, favorite: bool) -> Result<()> {
        EmbySource::set_favorite(self, item_id, favorite)
    }

    fn favorites(&self, page: i32, page_size: i32) -> Result<Paged<MediaItem>> {
        EmbySource::favorites(self, page, page_size)
    }

    fn set_watched(&self, item_id: &str, watched: bool) -> Result<()> {
        EmbySource::set_watched(self, item_id, watched)
    }

    fn remove_play_record(&self, item_id: &str) -> Result<()> {
        EmbySource::remove_play_record(self, item_id)
    }

    fn play_source(&self, item_id: &str) -> Result<PlaySource> {
        EmbySource::play_source(self, item_id)
    }

    fn media_info(&self, item_id: &str) -> Result<MediaInfo> {
        EmbySource::media_info(self, item_id)
    }

    fn people(&self, item_id: &str) -> Result<Vec<Person>> {
        EmbySource::people(self, item_id)
    }

    fn person_works(&self, person_id: &str) -> Result<Vec<MediaItem>> {
        EmbySource::person_works(self, person_id)
    }

    fn image_source(&self, path: &str) -> Result<ImageSource> {
        EmbySource::image_source(self, path)
    }
}

// —— 响应结构 ——
//
// Emby 用 PascalCase；字段几乎都能缺省，所以一律 `default`，
// 少一个字段不至于整条解析失败。

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct UserDto {
    #[serde(default)]
    id: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ItemQueryDto {
    #[serde(default)]
    items: Vec<ItemDto>,
    #[serde(default)]
    total_record_count: i64,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ItemDto {
    #[serde(default)]
    id: String,
    /// 文件 / 目录路径（`Fields=Path`），详情页「位置」用。
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    name: String,
    #[serde(default, rename = "Type")]
    item_type: String,
    #[serde(default)]
    collection_type: Option<String>,
    #[serde(default)]
    original_title: Option<String>,
    #[serde(default)]
    overview: Option<String>,
    #[serde(default)]
    parent_id: Option<String>,
    #[serde(default)]
    series_name: Option<String>,
    #[serde(default)]
    season_name: Option<String>,
    #[serde(default)]
    index_number: Option<i32>,
    #[serde(default)]
    parent_index_number: Option<i32>,
    #[serde(default)]
    run_time_ticks: Option<i64>,
    #[serde(default)]
    production_year: Option<i32>,
    #[serde(default)]
    community_rating: Option<f64>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    premiere_date: Option<String>,
    #[serde(default)]
    child_count: Option<i32>,
    #[serde(default)]
    recursive_item_count: Option<i32>,
    #[serde(default)]
    user_data: Option<UserDataDto>,
    #[serde(default)]
    image_tags: Option<serde_json::Map<String, serde_json::Value>>,
    #[serde(default)]
    backdrop_image_tags: Option<Vec<String>>,
    #[serde(default)]
    media_streams: Option<Vec<StreamDto>>,
    #[serde(default)]
    people: Option<Vec<PersonDto>>,
    #[serde(default)]
    provider_ids: Option<ProviderIdsDto>,
}

/// 服务器刮削时记下的外部库 id（Emby / Jellyfin 都有）。
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ProviderIdsDto {
    #[serde(default)]
    tmdb: Option<String>,
    #[serde(default)]
    imdb: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct PersonDto {
    #[serde(default)]
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    role: Option<String>,
    #[serde(default, rename = "Type")]
    kind: Option<String>,
    #[serde(default)]
    primary_image_tag: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct UserDataDto {
    #[serde(default)]
    playback_position_ticks: i64,
    #[serde(default)]
    played: bool,
    #[serde(default)]
    is_favorite: bool,
    #[serde(default)]
    played_percentage: Option<f64>,
    #[serde(default)]
    last_played_date: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct PlaybackInfoDto {
    #[serde(default)]
    media_sources: Vec<MediaSourceDto>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct MediaSourceDto {
    #[serde(default)]
    id: String,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    run_time_ticks: Option<i64>,
    #[serde(default)]
    media_streams: Vec<StreamDto>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct StreamDto {
    #[serde(default)]
    index: i32,
    #[serde(default, rename = "Type")]
    kind: String,
    #[serde(default)]
    codec: Option<String>,
    #[serde(default)]
    language: Option<String>,
    #[serde(default)]
    channels: Option<i32>,
    #[serde(default)]
    profile: Option<String>,
    #[serde(default)]
    is_default: bool,
    #[serde(default)]
    is_external: bool,
    #[serde(default)]
    is_text_subtitle_stream: Option<bool>,
    #[serde(default)]
    height: Option<i32>,
    #[serde(default)]
    color_transfer: Option<String>,
    #[serde(default)]
    video_range_type: Option<String>,
    #[serde(default)]
    dolby_vision_profile: Option<i32>,
    // —— 详情页「媒体信息」要的字段，Emby / Jellyfin 都给全 ——
    #[serde(default)]
    width: Option<i32>,
    #[serde(default)]
    frame_rate: Option<f64>,
    #[serde(default)]
    average_frame_rate: Option<f64>,
    #[serde(default)]
    bit_rate: Option<i64>,
    #[serde(default)]
    level: Option<f64>,
    #[serde(default)]
    is_interlaced: bool,
    #[serde(default)]
    bit_depth: Option<i32>,
    #[serde(default)]
    pixel_format: Option<String>,
    #[serde(default)]
    aspect_ratio: Option<String>,
    #[serde(default)]
    sample_rate: Option<i32>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    display_title: Option<String>,
    #[serde(default)]
    channel_layout: Option<String>,
}

// —— 映射与解析 ——

fn map_kind(raw: &str) -> MediaKind {
    match raw {
        "Movie" => MediaKind::Movie,
        "Series" => MediaKind::Series,
        "Season" => MediaKind::Season,
        "Episode" => MediaKind::Episode,
        "Video" | "MusicVideo" | "Trailer" => MediaKind::Video,
        "Folder" | "BoxSet" | "CollectionFolder" | "PhotoAlbum" => MediaKind::Folder,
        _ => MediaKind::Unknown,
    }
}

fn has_image(item: &ItemDto, kind: &str) -> bool {
    item.image_tags
        .as_ref()
        .map(|tags| tags.contains_key(kind))
        .unwrap_or(false)
}

fn has_backdrop(item: &ItemDto) -> bool {
    item.backdrop_image_tags
        .as_ref()
        .map(|tags| !tags.is_empty())
        .unwrap_or(false)
}

fn resolution_label(video: &StreamDto) -> Option<String> {
    let height = video.height?;
    let label = match height {
        2000.. => "2160p",
        1000..=1999 => "1080p",
        700..=999 => "720p",
        500..=699 => "576p",
        _ => "480p",
    };
    Some(label.to_string())
}

/// HDR 标签：优先用服务器给的 `VideoRangeType`，没有再按色彩参数猜。
fn color_label(video: &StreamDto) -> Option<String> {
    if let Some(range) = video.video_range_type.as_deref().filter(|r| !r.is_empty()) {
        return match range {
            "DOVI" => Some("DV".into()),
            "HDR10" | "HDR10Plus" | "HLG" => Some(range.to_string()),
            "SDR" | "Unknown" => None,
            other => Some(other.to_string()),
        };
    }

    if video.dolby_vision_profile.unwrap_or(0) > 0 {
        return Some("DV".into());
    }

    let transfer = video.color_transfer.as_deref().unwrap_or_default();
    if transfer.eq_ignore_ascii_case("smpte2084") {
        return Some("HDR10".into());
    }
    if transfer.eq_ignore_ascii_case("arib-std-b67") {
        return Some("HLG".into());
    }

    None
}

/// Emby 的时间是 `2024-05-01T12:34:56.0000000Z`，只需要拆到秒。
fn parse_iso8601_seconds(value: &str) -> Option<i64> {
    let s = value.trim();
    if s.len() < 19 {
        return None;
    }

    let year: i64 = s.get(0..4)?.parse().ok()?;
    let month: i64 = s.get(5..7)?.parse().ok()?;
    let day: i64 = s.get(8..10)?.parse().ok()?;
    let hour: i64 = s.get(11..13)?.parse().ok()?;
    let minute: i64 = s.get(14..16)?.parse().ok()?;
    let second: i64 = s.get(17..19)?.parse().ok()?;

    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }

    // Howard Hinnant 的 days_from_civil。
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;

    Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
}

/// `PlaySessionId`：32 位十六进制，拿纳秒时间戳凑一个够用的。
fn new_session_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};

    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);

    format!("{nanos:032x}")
}

fn truncate(text: &str, limit: usize) -> String {
    if text.chars().count() <= limit {
        return text.to_string();
    }
    text.chars().take(limit).collect::<String>() + "…"
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source() -> EmbySource {
        EmbySource::new(
            "emby-1".into(),
            "Emby".into(),
            "Emby".into(),
            "http://127.0.0.1:8096".into(),
            String::new(),
            String::new(),
            String::new(),
        )
    }

    #[test]
    fn item_json_maps_to_the_shared_model() {
        let json = r#"{
            "Id": "abc123",
            "Name": "第 3 集",
            "Type": "Episode",
            "SeriesName": "某剧",
            "IndexNumber": 3,
            "ParentIndexNumber": 1,
            "RunTimeTicks": 1500000000,
            "ImageTags": { "Primary": "t1" },
            "BackdropImageTags": ["b1"],
            "UserData": {
                "PlaybackPositionTicks": 300000000,
                "IsFavorite": true,
                "LastPlayedDate": "2026-11-19T12:00:00.0000000Z"
            }
        }"#;

        let dto: ItemDto = serde_json::from_str(json).unwrap();
        let item = source().map_item(&dto);

        assert_eq!(item.id, "abc123");
        assert_eq!(item.kind, MediaKind::Episode);
        assert_eq!(item.season_number, Some(1));
        assert_eq!(item.episode_number, Some(3));
        assert_eq!(item.runtime_seconds, Some(150));
        assert!((item.progress - 0.2).abs() < 0.0001);
        assert!(item.is_favorite);
        assert_eq!(item.poster_path.as_deref(), Some("abc123/Primary"));
        assert_eq!(item.backdrop_path.as_deref(), Some("abc123/Backdrop/0"));
        assert_eq!(item.last_played, parse_iso8601_seconds("2026-11-19T12:00:00Z"));
        assert_eq!(item.parent_title.as_deref(), Some("某剧"));
    }

    #[test]
    fn series_counts_come_from_child_and_recursive_counts() {
        let json = r#"{
            "Id": "s1",
            "Name": "某剧",
            "Type": "Series",
            "ChildCount": 3,
            "RecursiveItemCount": 26
        }"#;

        let dto: ItemDto = serde_json::from_str(json).unwrap();
        let item = source().map_item(&dto);

        assert_eq!(item.season_count, Some(3));
        assert_eq!(item.episode_count, Some(26));
        assert_eq!(item.local_episode_count, Some(26));
    }

    #[test]
    fn hdr_and_dv_are_labelled_from_streams() {
        let hdr = StreamDto {
            kind: "Video".into(),
            height: Some(2160),
            video_range_type: Some("HDR10".into()),
            ..Default::default()
        };
        assert_eq!(resolution_label(&hdr).as_deref(), Some("2160p"));
        assert_eq!(color_label(&hdr).as_deref(), Some("HDR10"));

        let dv = StreamDto {
            kind: "Video".into(),
            video_range_type: Some("DOVI".into()),
            dolby_vision_profile: Some(8),
            ..Default::default()
        };
        assert_eq!(color_label(&dv).as_deref(), Some("DV"));

        let sdr = StreamDto {
            kind: "Video".into(),
            height: Some(1080),
            ..Default::default()
        };
        assert_eq!(color_label(&sdr), None);
    }

    #[test]
    fn ticks_and_dates_split_correctly() {
        assert_eq!(parse_iso8601_seconds("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            parse_iso8601_seconds("2024-02-29T23:59:59.0000000Z"),
            Some(1_709_251_199)
        );
        assert_eq!(parse_iso8601_seconds("nope"), None);
    }

    #[test]
    fn image_path_splits_into_item_and_kind() {
        let image = source().image_source("abc/Backdrop/0").unwrap();
        assert!(image.url.contains("/Items/abc/Images/Backdrop/0"));
        assert!(image.url.contains("maxWidth=1600"));
        assert!(source().image_source("abc").is_err());
    }
}
