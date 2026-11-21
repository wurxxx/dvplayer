//! 本地文件源：把一个目录（或单个视频 / ISO）当成一个媒体库。
//!
//! 为什么放在核心里：卡片墙、详情、选集、进度这些界面两端都只认
//! [`MediaSource`] 这套模型。本地目录源如果写在界面里，Windows 和 macOS
//! 就要各写一遍目录扫描、文件名解析、季集推断，最后两边的「第几集」还对不上。
//!
//! 库里没有刮削信息，标题从文件名推：`某剧/S01E02.mkv` 是剧的第二集，
//! `电影名 (2023)/电影名.mkv` 是 2023 年的电影。海报找同名的
//! `<文件名>.jpg` / `poster.jpg` / `folder.jpg` / `cover.jpg`。
//!
//! 进度和「继续观看」存本地 JSON（`dataDir/local-progress.json`），
//! 因为本地文件没有服务器可以回写。

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::error::{percent_encode, MediaError, Result};
use crate::models::{
    Genre, ImageSource, ListQuery, MediaDetail, MediaItem, MediaKind, MediaLibrary, Paged,
    PlayRecord, PlaySource,
};
use crate::sources::fnos::parse_episode_number;
use crate::sources::MediaSource;

/// 认作视频的扩展名。ISO 也算，播放时由界面决定走不走原盘流程。
const VIDEO_EXTS: &[&str] = &[
    "mkv", "mp4", "m4v", "ts", "m2ts", "m2t", "avi", "mov", "wmv", "flv", "webm", "rmvb", "rm",
    "mpg", "mpeg", "iso", "vob", "mts",
];

const IMAGE_EXTS: &[&str] = &["jpg", "jpeg", "png", "webp"];

/// 一部剧最多往下找几层（剧 / 季 / 集三层就够，再深多半是花絮）。
const MAX_DEPTH: usize = 4;

/// 本地源的媒体库 id。聚合层会再加源前缀，界面拿到的始终是 `源:local`。
const LIBRARY_ID: &str = "local";

pub struct LocalSource {
    id: String,
    name: String,
    root: PathBuf,
    /// 进度文件放这里；留空就只记在内存里（重启丢失）。
    data_dir: Option<PathBuf>,
    index: Index,
}

#[derive(Default)]
struct Index {
    films: Vec<Film>,
    shows: Vec<Show>,
}

struct Film {
    /// 相对根的路径，`/` 分隔。
    rel: String,
    title: String,
    year: Option<i32>,
}

struct Show {
    rel: String,
    title: String,
    year: Option<i32>,
    seasons: Vec<Season>,
}

struct Season {
    number: i32,
    episodes: Vec<Episode>,
}

struct Episode {
    /// 相对根的路径。
    rel: String,
    number: i32,
    title: String,
}

impl LocalSource {
    pub fn new(id: String, name: String, root: String, data_dir: String) -> Self {
        let root = PathBuf::from(root);
        let data_dir = if data_dir.trim().is_empty() {
            None
        } else {
            Some(PathBuf::from(data_dir))
        };
        let index = scan(&root);
        Self {
            id,
            name,
            root,
            data_dir,
            index,
        }
    }

    // —— 条目查找 ——

    fn film_by_id(&self, id: &str) -> Option<&Film> {
        let rel = id.strip_prefix("f/")?;
        let rel = &decode_id(rel);
        self.index.films.iter().find(|f| &f.rel == rel)
    }

    fn show_by_id(&self, id: &str) -> Option<&Show> {
        if id.contains('@') {
            return None;
        }
        let rel = id.strip_prefix("d/")?;
        let rel = &decode_id(rel);
        self.index.shows.iter().find(|s| &s.rel == rel)
    }

    /// 季 id 形如 `d/<剧路径>@<季号>`。
    fn season_by_id(&self, id: &str) -> Option<(&Show, &Season)> {
        let body = id.strip_prefix("d/")?;
        let (show_rel, number) = body.rsplit_once('@')?;
        let show_rel = decode_id(show_rel);
        let number: i32 = number.parse().ok()?;
        let show = self.index.shows.iter().find(|s| s.rel == show_rel)?;
        let season = show.seasons.iter().find(|s| s.number == number)?;
        Some((show, season))
    }

    fn episode_by_id(&self, id: &str) -> Option<(&Show, &Season, &Episode)> {
        let rel = decode_id(id.strip_prefix("f/")?);
        for show in &self.index.shows {
            for season in &show.seasons {
                for episode in &season.episodes {
                    if episode.rel == rel {
                        return Some((show, season, episode));
                    }
                }
            }
        }
        None
    }

    /// 详情页 / 续播要播的那一集：第一集没看完的；全看完了就第一集。
    fn next_episode<'a>(&self, show: &'a Show) -> Option<&'a Episode> {
        let all = show.seasons.iter().flat_map(|s| s.episodes.iter());
        let mut first = None;
        for episode in all {
            if first.is_none() {
                first = Some(episode);
            }
            if !self.is_finished(&episode.rel) {
                return Some(episode);
            }
        }
        first
    }

    fn is_finished(&self, rel: &str) -> bool {
        let progress = self.load_progress();
        match progress.items.get(&format!("f/{}", encode_id(rel))) {
            Some(entry) if entry.duration > 0 => {
                entry.position as f64 / entry.duration as f64 >= 0.95
            }
            _ => false,
        }
    }

    // —— 进度 ——

    fn progress_file(&self) -> Option<PathBuf> {
        // 文件名不能叫 local-progress.json：两端「直接打开原盘」的续播点
        // 用的是那个名字（结构也不一样），放同一个文件会互相覆盖。
        self.data_dir
            .as_ref()
            .map(|dir| dir.join("local-library-progress.json"))
    }

    fn load_progress(&self) -> ProgressFile {
        let Some(path) = self.progress_file() else {
            return ProgressFile::default();
        };
        let Ok(bytes) = fs::read(&path) else {
            return ProgressFile::default();
        };
        serde_json::from_slice(&bytes).unwrap_or_default()
    }

    fn save_progress(&self, progress: &ProgressFile) {
        let Some(path) = self.progress_file() else {
            return;
        };
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let Ok(text) = serde_json::to_vec_pretty(progress) else {
            return;
        };
        // 先写临时文件再换名：中途断电不会留下半个 JSON。
        let tmp = path.with_extension("json.tmp");
        if fs::write(&tmp, text).is_ok() {
            let _ = fs::rename(&tmp, &path);
        }
    }

    fn position_of(&self, item_id: &str) -> (u64, u64) {
        let progress = self.load_progress();
        let entry = progress.items.get(item_id);
        (
            entry.map(|e| e.position).unwrap_or(0),
            entry.map(|e| e.duration).unwrap_or(0),
        )
    }

    /// 写一条进度；`meta` 带上标题、所属剧等，`records()` 直接用。
    fn put_progress(&self, item_id: &str, position: u64, duration: u64) {
        let mut progress = self.load_progress();
        let meta = self.meta_of(item_id);
        let at = now();
        let entry = progress.items.entry(item_id.to_string()).or_default();
        entry.position = position;
        entry.duration = duration.max(entry.duration);
        entry.at = at;
        if let Some(meta) = meta {
            entry.title = meta.title;
            entry.series = meta.series;
            entry.parent = meta.parent;
            entry.season = meta.season;
            entry.episode = meta.episode;
            entry.poster = meta.poster;
        }
        self.save_progress(&progress);
    }

    /// 条目的展示信息（进度表里冗余一份，读记录时不用再扫盘）。
    fn meta_of(&self, item_id: &str) -> Option<Meta> {
        if let Some(film) = self.film_by_id(item_id) {
            return Some(Meta {
                title: Some(film.title.clone()),
                series: None,
                parent: None,
                season: None,
                episode: None,
                poster: self.poster_path(&film.rel),
            });
        }

        if let Some((show, season, episode)) = self.episode_by_id(item_id) {
            let parent = Some(format!(
                "d/{}@{}",
                encode_id(&show.rel),
                season.number
            ));
            return Some(Meta {
                title: Some(format!("第 {} 集 · {}", episode.number, episode.title)),
                series: Some(show.title.clone()),
                parent,
                season: Some(season.number),
                episode: Some(episode.number),
                poster: self.poster_path(&episode.rel),
            });
        }

        None
    }

    // —— 展示用的转换 ——

    /// rel → 绝对路径。root 本身就是那个文件时，rel 就是文件名。
    fn path_of(&self, rel: &str) -> PathBuf {
        if self.root.is_file() {
            self.root.clone()
        } else {
            self.root.join(rel)
        }
    }

    fn poster_path(&self, rel: &str) -> Option<String> {
        poster_for(&self.root, &self.path_of(rel)).map(|p| qualify_img(&p))
    }

    fn film_item(&self, film: &Film) -> MediaItem {
        let id = format!("f/{}", encode_id(&film.rel));
        let (position, duration) = self.position_of(&id);
        let progress = self.load_progress();
        let last_played = progress.items.get(&id).map(|e| e.at);
        let runtime = if duration > 0 { Some(duration) } else { None };

        MediaItem {
            id,
            title: film.title.clone(),
            kind: MediaKind::Movie,
            source_id: self.id.clone(),
            poster_path: self.poster_path(&film.rel),
            parent_id: None,
            parent_title: None,
            year: film.year,
            runtime_seconds: runtime,
            progress: if duration == 0 {
                0.0
            } else {
                (position as f64 / duration as f64).clamp(0.0, 1.0)
            },
            is_favorite: false,
            overview: None,
            resolution: resolution_label(&film.rel),
            last_played,
            season_number: None,
            episode_number: None,
            episode_count: None,
            local_episode_count: None,
            season_count: None,
            rating: None,
            release_date: film.year.map(|y| format!("{y}-01-01")),
            status: None,
            backdrop_path: None,
            single_child_id: None,
        }
    }

    fn show_item(&self, show: &Show) -> MediaItem {
        let episodes: Vec<&Episode> = show
            .seasons
            .iter()
            .flat_map(|s| s.episodes.iter())
            .collect();
        let watched = episodes
            .iter()
            .filter(|e| self.is_finished(&e.rel))
            .count();
        let progress = if episodes.is_empty() {
            0.0
        } else {
            watched as f64 / episodes.len() as f64
        };

        let last_played = self
            .load_progress()
            .items
            .values()
            .filter(|e| e.series.as_deref() == Some(show.title.as_str()))
            .map(|e| e.at)
            .max();

        MediaItem {
            id: format!("d/{}", encode_id(&show.rel)),
            title: show.title.clone(),
            kind: MediaKind::Series,
            source_id: self.id.clone(),
            poster_path: show
                .seasons
                .iter()
                .flat_map(|s| s.episodes.iter())
                .find_map(|e| self.poster_path(&e.rel)),
            parent_id: None,
            parent_title: None,
            year: show.year,
            runtime_seconds: None,
            progress,
            is_favorite: false,
            overview: None,
            resolution: None,
            last_played,
            season_number: None,
            episode_number: None,
            episode_count: Some(episodes.len() as i32),
            local_episode_count: Some(episodes.len() as i32),
            season_count: Some(show.seasons.len() as i32),
            rating: None,
            release_date: show.year.map(|y| format!("{y}-01-01")),
            status: None,
            backdrop_path: None,
            single_child_id: (show.seasons.len() == 1)
                .then(|| format!("d/{}@{}", encode_id(&show.rel), show.seasons[0].number)),
        }
    }

    fn season_item(&self, show: &Show, season: &Season) -> MediaItem {
        let watched = season
            .episodes
            .iter()
            .filter(|e| self.is_finished(&e.rel))
            .count();
        MediaItem {
            id: format!("d/{}@{}", encode_id(&show.rel), season.number),
            title: format!("第 {} 季", season.number),
            kind: MediaKind::Season,
            source_id: self.id.clone(),
            poster_path: show
                .seasons
                .iter()
                .flat_map(|s| s.episodes.iter())
                .find_map(|e| self.poster_path(&e.rel)),
            parent_id: Some(format!("d/{}", encode_id(&show.rel))),
            parent_title: Some(show.title.clone()),
            year: show.year,
            runtime_seconds: None,
            progress: if season.episodes.is_empty() {
                0.0
            } else {
                watched as f64 / season.episodes.len() as f64
            },
            is_favorite: false,
            overview: None,
            resolution: None,
            last_played: None,
            season_number: Some(season.number),
            episode_number: None,
            episode_count: Some(season.episodes.len() as i32),
            local_episode_count: Some(season.episodes.len() as i32),
            season_count: None,
            rating: None,
            release_date: None,
            status: None,
            backdrop_path: None,
            single_child_id: None,
        }
    }

    fn episode_item(&self, show: &Show, season: &Season, episode: &Episode) -> MediaItem {
        let id = format!("f/{}", encode_id(&episode.rel));
        let (position, duration) = self.position_of(&id);
        let progress = self.load_progress();
        let last_played = progress.items.get(&id).map(|e| e.at);

        MediaItem {
            id,
            title: episode.title.clone(),
            kind: MediaKind::Episode,
            source_id: self.id.clone(),
            poster_path: self.poster_path(&episode.rel),
            parent_id: Some(format!("d/{}@{}", encode_id(&show.rel), season.number)),
            parent_title: Some(show.title.clone()),
            year: show.year,
            runtime_seconds: (duration > 0).then_some(duration),
            progress: if duration == 0 {
                0.0
            } else {
                (position as f64 / duration as f64).clamp(0.0, 1.0)
            },
            is_favorite: false,
            overview: None,
            resolution: resolution_label(&episode.rel),
            last_played,
            season_number: Some(season.number),
            episode_number: Some(episode.number),
            episode_count: Some(season.episodes.len() as i32),
            local_episode_count: Some(season.episodes.len() as i32),
            season_count: Some(show.seasons.len() as i32),
            rating: None,
            release_date: None,
            status: None,
            backdrop_path: None,
            single_child_id: None,
        }
    }

    /// 播放地址。本地源不用 HTTP，直接给绝对路径，mpv 能开。
    fn play_episode(&self, show: &Show, episode: &Episode) -> Result<PlaySource> {
        self.play_file(&episode.rel, Some(show), Some(episode))
    }

    fn play_file(
        &self,
        rel: &str,
        show: Option<&Show>,
        episode: Option<&Episode>,
    ) -> Result<PlaySource> {
        let path = self.path_of(rel);
        if !path.is_file() {
            return Err(MediaError::Other(format!("文件不存在：{}", path.display())));
        }

        let id = format!("f/{}", encode_id(rel));
        let (position, duration) = self.position_of(&id);
        let title = match (show, episode) {
            (Some(show), Some(episode)) => format!("{} · 第 {} 集", show.title, episode.number),
            _ => clean_title(&file_stem(&path)),
        };
        let poster = self.poster_path(rel);

        Ok(PlaySource {
            item_id: id,
            title,
            url: path.to_string_lossy().into_owned(),
            headers: Vec::new(),
            is_direct: true,
            disc: is_iso(&path),
            media_guid: String::new(),
            video_guid: None,
            audio_guid: None,
            subtitle_guid: None,
            position_seconds: position,
            duration_seconds: duration,
            overview: None,
            poster_path: poster,
            resolution: resolution_label(rel),
            color_range: None,
            dolby_vision: false,
            video_codec: None,
            audio_codec: None,
            audio_streams: Vec::new(),
            subtitle_streams: Vec::new(),
        })
    }
}

impl MediaSource for LocalSource {
    fn kind(&self) -> &'static str {
        "local"
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn login(&mut self) -> Result<()> {
        if !self.root.exists() {
            return Err(MediaError::Other(format!(
                "找不到这个路径：{}",
                self.root.display()
            )));
        }
        self.index = scan(&self.root);
        if self.index.films.is_empty() && self.index.shows.is_empty() {
            return Err(MediaError::Other(format!(
                "这个目录里没有认得的视频文件：{}",
                self.root.display()
            )));
        }
        Ok(())
    }

    fn libraries(&self) -> Result<Vec<MediaLibrary>> {
        Ok(vec![MediaLibrary {
            id: LIBRARY_ID.to_string(),
            title: self.name.clone(),
            source_id: self.id.clone(),
            poster_path: None,
            category: "local".into(),
        }])
    }

    fn items(
        &self,
        _library_id: &str,
        page: i32,
        page_size: i32,
        query: &ListQuery,
    ) -> Result<Paged<MediaItem>> {
        let all = query.kinds.is_empty();
        let want_movie = all || query.kinds.iter().any(|k| k == "movie");
        let want_tv = all
            || query
                .kinds
                .iter()
                .any(|k| k == "tv" || k == "series" || k == "episode");

        let mut list = Vec::new();
        if want_movie {
            list.extend(self.index.films.iter().map(|f| self.film_item(f)));
        }
        if want_tv {
            list.extend(self.index.shows.iter().map(|s| self.show_item(s)));
        }

        // 默认按标题；「最近」按播放时间。其它排序值先当标题。
        match query.sort.as_deref() {
            Some("last_played") | Some("recent") => {
                list.sort_by(|a, b| b.last_played.unwrap_or(0).cmp(&a.last_played.unwrap_or(0)))
            }
            Some("year") => list.sort_by(|a, b| b.year.unwrap_or(0).cmp(&a.year.unwrap_or(0))),
            _ => list.sort_by(|a, b| a.title.cmp(&b.title)),
        }
        if query.descending && !matches!(query.sort.as_deref(), Some("last_played") | Some("recent") | Some("year")) {
            list.reverse();
        }

        let total = list.len() as i64;
        let page = page.max(1);
        let page_size = page_size.max(1);
        let start = (page as usize - 1) * page_size as usize;
        let items = list.into_iter().skip(start).take(page_size as usize).collect();

        Ok(Paged {
            items,
            total,
            page,
            page_size,
        })
    }

    fn children(
        &self,
        parent_id: &str,
        page: i32,
        page_size: i32,
        _query: &ListQuery,
    ) -> Result<Paged<MediaItem>> {
        let mut items = Vec::new();

        if let Some(show) = self.show_by_id(parent_id) {
            if show.seasons.len() > 1 {
                items.extend(show.seasons.iter().map(|s| self.season_item(show, s)));
            } else if let Some(season) = show.seasons.first() {
                items.extend(
                    season
                        .episodes
                        .iter()
                        .map(|e| self.episode_item(show, season, e)),
                );
            }
        } else if let Some((show, season)) = self.season_by_id(parent_id) {
            items.extend(
                season
                    .episodes
                    .iter()
                    .map(|e| self.episode_item(show, season, e)),
            );
        }

        let total = items.len() as i64;
        let start = ((page.max(1) - 1) as usize) * page_size.max(1) as usize;
        let items = items
            .into_iter()
            .skip(start)
            .take(page_size.max(1) as usize)
            .collect();
        Ok(Paged {
            items,
            total,
            page,
            page_size,
        })
    }

    fn genres(&self, _scope_id: &str) -> Result<Vec<Genre>> {
        Ok(Vec::new())
    }

    fn search(&self, query: &str) -> Result<Vec<MediaItem>> {
        let needle = query.trim().to_lowercase();
        if needle.is_empty() {
            return Ok(Vec::new());
        }

        let mut out = Vec::new();
        for film in &self.index.films {
            if film.title.to_lowercase().contains(&needle) {
                out.push(self.film_item(film));
            }
        }
        for show in &self.index.shows {
            if show.title.to_lowercase().contains(&needle) {
                out.push(self.show_item(show));
                continue;
            }
            for season in &show.seasons {
                for episode in &season.episodes {
                    if episode.title.to_lowercase().contains(&needle) {
                        out.push(self.episode_item(show, season, episode));
                    }
                }
            }
        }
        Ok(out)
    }

    fn detail(&self, item_id: &str) -> Result<MediaDetail> {
        if let Some(film) = self.film_by_id(item_id) {
            let (_, duration) = self.position_of(item_id);
            return Ok(MediaDetail {
                id: item_id.to_string(),
                title: film.title.clone(),
                kind: MediaKind::Movie,
                original_title: None,
                overview: None,
                poster_path: self.poster_path(&film.rel),
                backdrop_path: None,
                logo_path: None,
                rating: None,
                release_date: film.year.map(|y| format!("{y}-01-01")),
                runtime_seconds: (duration > 0).then_some(duration),
                season_count: None,
                local_season_count: None,
                episode_count: None,
                local_episode_count: None,
                status: None,
                resolution: resolution_label(&film.rel),
                audio_type: None,
                color_range: None,
                play_item_id: Some(item_id.to_string()),
                single_child_id: None,
                is_favorite: None,
                is_watched: self.is_finished(&film.rel).then_some(true),
            });
        }

        if let Some((show, season)) = self.season_by_id(item_id) {
            let play = self
                .next_episode(show)
                .map(|e| format!("f/{}", encode_id(&e.rel)));
            return Ok(MediaDetail {
                id: item_id.to_string(),
                title: format!("{} · 第 {} 季", show.title, season.number),
                kind: MediaKind::Season,
                original_title: None,
                overview: None,
                poster_path: None,
                backdrop_path: None,
                logo_path: None,
                rating: None,
                release_date: None,
                runtime_seconds: None,
                season_count: None,
                local_season_count: None,
                episode_count: Some(season.episodes.len() as i32),
                local_episode_count: Some(season.episodes.len() as i32),
                status: None,
                resolution: None,
                audio_type: None,
                color_range: None,
                play_item_id: play,
                single_child_id: None,
                is_favorite: None,
                is_watched: None,
            });
        }

        if let Some(show) = self.show_by_id(item_id) {
            let episodes = show.seasons.iter().flat_map(|s| s.episodes.iter()).count();
            let play = self
                .next_episode(show)
                .map(|e| format!("f/{}", encode_id(&e.rel)));
            return Ok(MediaDetail {
                id: item_id.to_string(),
                title: show.title.clone(),
                kind: MediaKind::Series,
                original_title: None,
                overview: None,
                poster_path: show
                    .seasons
                    .iter()
                    .flat_map(|s| s.episodes.iter())
                    .find_map(|e| self.poster_path(&e.rel)),
                backdrop_path: None,
                logo_path: None,
                rating: None,
                release_date: show.year.map(|y| format!("{y}-01-01")),
                runtime_seconds: None,
                season_count: Some(show.seasons.len() as i32),
                local_season_count: Some(show.seasons.len() as i32),
                episode_count: Some(episodes as i32),
                local_episode_count: Some(episodes as i32),
                status: None,
                resolution: None,
                audio_type: None,
                color_range: None,
                play_item_id: play,
                single_child_id: (show.seasons.len() == 1)
                    .then(|| format!("d/{}@{}", encode_id(&show.rel), show.seasons[0].number)),
                is_favorite: None,
                is_watched: None,
            });
        }

        Err(MediaError::Other(format!("本地源没有这个条目：{item_id}")))
    }

    fn records(&self) -> Result<Vec<PlayRecord>> {
        let progress = self.load_progress();
        let mut out: Vec<PlayRecord> = progress
            .items
            .iter()
            .map(|(id, entry)| PlayRecord {
                item_id: id.clone(),
                title: entry
                    .title
                    .clone()
                    .unwrap_or_else(|| id.clone()),
                source_id: self.id.clone(),
                series_title: entry.series.clone(),
                parent_id: entry.parent.clone(),
                season_number: entry.season,
                episode_number: entry.episode,
                poster_path: entry.poster.clone(),
                position_seconds: entry.position,
                duration_seconds: entry.duration,
                last_played: Some(entry.at),
            })
            .collect();

        out.sort_by(|a, b| b.last_played.unwrap_or(0).cmp(&a.last_played.unwrap_or(0)));
        Ok(out)
    }

    fn report_progress(&self, item_id: &str, position: i64, duration: i64) -> Result<()> {
        self.put_progress(item_id, position.max(0) as u64, duration.max(0) as u64);
        Ok(())
    }

    fn set_watched(&self, item_id: &str, watched: bool) -> Result<()> {
        let (_, duration) = self.position_of(item_id);
        if watched {
            // 还不知道时长（没播过）就记个 1 秒，至少能进「看过」。
            self.put_progress(item_id, duration.max(1), duration.max(1));
        } else {
            self.put_progress(item_id, 0, duration.max(1));
        }
        Ok(())
    }

    fn remove_play_record(&self, item_id: &str) -> Result<()> {
        let mut progress = self.load_progress();
        progress.items.remove(item_id);
        self.save_progress(&progress);
        Ok(())
    }

    fn play_source(&self, item_id: &str) -> Result<PlaySource> {
        if let Some(film) = self.film_by_id(item_id) {
            return self.play_file(&film.rel, None, None);
        }
        if let Some((show, season)) = self.season_by_id(item_id) {
            // 播这一季里第一集没看完的，别跳到别的季去。
            let episode = season
                .episodes
                .iter()
                .find(|e| !self.is_finished(&e.rel))
                .or_else(|| season.episodes.first())
                .ok_or_else(|| MediaError::Other("这一季里没有视频".into()))?;
            return self.play_episode(show, episode);
        }
        if let Some(show) = self.show_by_id(item_id) {
            let episode = self
                .next_episode(show)
                .ok_or_else(|| MediaError::Other("这部剧里没有视频".into()))?;
            return self.play_episode(show, episode);
        }
        if let Some((show, _season, episode)) = self.episode_by_id(item_id) {
            return self.play_episode(show, episode);
        }

        Err(MediaError::Other(format!("本地源播不了这个条目：{item_id}")))
    }

    fn image_source(&self, path: &str) -> Result<ImageSource> {
        let rel = decode_id(path.strip_prefix("img/").unwrap_or(path));
        let full = self.path_of(&rel);
        if !full.is_file() {
            return Err(MediaError::Other(format!("图片不存在：{}", full.display())));
        }
        Ok(ImageSource {
            url: file_url(&full),
            headers: Vec::new(),
        })
    }
}

// —— 进度文件 ——

#[derive(Default, Serialize, Deserialize)]
struct ProgressFile {
    #[serde(default)]
    items: BTreeMap<String, ProgressEntry>,
}

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ProgressEntry {
    position: u64,
    duration: u64,
    /// unix 秒。
    at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    series: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    parent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    season: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    episode: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    poster: Option<String>,
}

struct Meta {
    title: Option<String>,
    series: Option<String>,
    parent: Option<String>,
    season: Option<i32>,
    episode: Option<i32>,
    poster: Option<String>,
}

// —— 扫描 ——

/// 读一层目录，顺带拿到「是不是目录」。
///
/// 不逐个 `Path::is_dir()`：那会对每个文件发一次 stat，SMB / NFS 上一个 579 集的
/// 剧目录要几百次往返；`DirEntry::file_type()` 直接用 readdir 返回的类型。
fn read_children(dir: &Path) -> Vec<(PathBuf, bool)> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut children: Vec<(PathBuf, bool)> = entries
        .filter_map(|e| e.ok())
        .map(|e| {
            let is_dir = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
            (e.path(), is_dir)
        })
        .filter(|(path, _)| !is_hidden(path))
        .collect();
    children.sort_by(|a, b| a.0.cmp(&b.0));
    children
}

fn scan(root: &Path) -> Index {
    let mut index = Index::default();

    if root.is_file() {
        if let Some(film) = film_from_file(root, root, None) {
            index.films.push(film);
        }
        return index;
    }

    let children = read_children(root);
    if children.is_empty() {
        return index;
    }

    // 网络挂载（SMB / NFS / WebDAV）上每次 readdir 都是一次往返，串行扫十几个
    // 剧目录能拖到几十秒。顶层目录并发扫，结果按原顺序放回去。
    for entry in scan_top_entries(root, &children) {
        match entry {
            Some(TopEntry::Show(show)) => index.shows.push(show),
            Some(TopEntry::Film(film)) => index.films.push(film),
            None => {}
        }
    }

    index
}

enum TopEntry {
    Show(Show),
    Film(Film),
}

/// 顶层并发扫描，最多 8 个线程（本地盘也能顺带加速）。
fn scan_top_entries(
    root: &Path,
    children: &[(PathBuf, bool)],
) -> Vec<Option<TopEntry>> {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;

    let mut slots: Vec<Option<TopEntry>> = Vec::new();
    slots.resize_with(children.len(), || None);

    let workers = children.len().clamp(1, 8);
    if workers == 1 {
        for (i, (path, is_dir)) in children.iter().enumerate() {
            slots[i] = top_entry(root, path, *is_dir);
        }
        return slots;
    }

    let cursor = AtomicUsize::new(0);
    let done: Mutex<Vec<(usize, TopEntry)>> = Mutex::new(Vec::new());

    std::thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| loop {
                let i = cursor.fetch_add(1, Ordering::Relaxed);
                let Some((path, is_dir)) = children.get(i) else { break };
                if let Some(entry) = top_entry(root, path, *is_dir) {
                    // 扫描没有顺序依赖，锁只保护结果列表。
                    if let Ok(mut list) = done.lock() {
                        list.push((i, entry));
                    }
                }
            });
        }
    });

    let mut collected = done.into_inner().unwrap_or_default();
    collected.sort_by_key(|(i, _)| *i);
    for (i, entry) in collected {
        slots[i] = Some(entry);
    }
    slots
}

fn top_entry(root: &Path, path: &Path, is_dir: bool) -> Option<TopEntry> {
    if is_dir {
        let videos = collect_videos(path, MAX_DEPTH);
        if videos.is_empty() {
            return None;
        }
        if looks_like_show(path, &videos) {
            Some(TopEntry::Show(build_show(root, path)))
        } else {
            film_from_dir(root, path, &videos).map(TopEntry::Film)
        }
    } else if is_video(path) {
        film_from_file(root, path, None).map(TopEntry::Film)
    } else {
        None
    }
}

fn film_from_file(root: &Path, path: &Path, title_override: Option<&str>) -> Option<Film> {
    if !is_video(path) {
        return None;
    }
    let stem = file_stem(path);
    let title = title_override
        .map(|t| t.to_string())
        .unwrap_or_else(|| clean_title(&stem));
    // root 本身就是这个文件时，相对路径是空的，用文件名当 rel。
    let mut rel = rel_of(root, path);
    if rel.is_empty() {
        rel = file_name(path);
    }
    Some(Film {
        rel,
        title,
        year: year_of(&stem),
    })
}

/// 只有一两个文件的目录当电影：标题优先用视频文件名，其次用目录名。
fn film_from_dir(root: &Path, dir: &Path, videos: &[PathBuf]) -> Option<Film> {
    let biggest = videos
        .iter()
        .max_by_key(|p| fs::metadata(p).map(|m| m.len()).unwrap_or(0))?;
    let dir_name = dir
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let stem = file_stem(biggest);
    let cleaned = clean_title(&stem);
    let title = if cleaned.is_empty() {
        clean_title(&dir_name)
    } else {
        cleaned
    };

    Some(Film {
        rel: rel_of(root, biggest),
        title,
        year: year_of(&stem).or_else(|| year_of(&dir_name)),
    })
}

fn build_show(root: &Path, dir: &Path) -> Show {
    let dir_name = dir
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut seasons: Vec<Season> = Vec::new();
    let mut loose: Vec<PathBuf> = Vec::new();

    for (child, is_dir) in read_children(dir) {
        if is_dir {
            if let Some(number) = parse_season_dir(&file_name(&child)) {
                let mut found = collect_videos(&child, MAX_DEPTH);
                found.sort();
                seasons.push(Season {
                    number,
                    episodes: build_episodes(root, &found),
                });
            } else {
                loose.extend(collect_videos(&child, MAX_DEPTH));
            }
        } else if is_video(&child) {
            loose.push(child);
        }
    }

    // 剧目录根层 / 非季子目录里的视频都算第一季。
    if !loose.is_empty() {
        loose.sort();
        let extra = build_episodes(root, &loose);
        if let Some(first) = seasons.iter_mut().find(|s| s.number == 1) {
            first.episodes.extend(extra);
            first.episodes.sort_by_key(|e| e.number);
        } else {
            seasons.push(Season {
                number: 1,
                episodes: extra,
            });
        }
    }

    seasons.sort_by_key(|s| s.number);
    // 空季（目录里没视频）不显示。
    seasons.retain(|s| !s.episodes.is_empty());

    Show {
        rel: rel_of(root, dir),
        title: clean_title(&dir_name),
        year: year_of(&dir_name),
        seasons,
    }
}

fn build_episodes(root: &Path, videos: &[PathBuf]) -> Vec<Episode> {
    let mut list: Vec<Episode> = videos
        .iter()
        .enumerate()
        .map(|(index, path)| {
            let stem = file_stem(path);
            Episode {
                rel: rel_of(root, path),
                // 文件名里认不出集号，就按排序位置编号，至少顺序不会乱。
                number: parse_episode_number(&stem).unwrap_or(index as i32 + 1),
                title: clean_title(&stem),
            }
        })
        .collect();

    list.sort_by_key(|e| e.number);
    list
}

/// 收集目录下（含子目录）的视频，跳过隐藏项和 BDMV 里的 `STREAM`（原盘应打成 ISO）。
fn collect_videos(dir: &Path, depth: usize) -> Vec<PathBuf> {
    if depth == 0 {
        return Vec::new();
    }
    let mut out = Vec::new();

    for (child, is_dir) in read_children(dir) {
        if is_dir {
            // 解开的蓝光目录：`BDMV/STREAM` 里是一堆 m2ts，按 ISO 处理更合适，
            // 这里不展开，避免一个原盘变成几千个「集」。
            if file_name(&child).eq_ignore_ascii_case("BDMV") {
                continue;
            }
            out.extend(collect_videos(&child, depth - 1));
        } else if is_video(&child) {
            out.push(child);
        }
    }
    out
}

/// 目录像「剧」而不是「电影」：有季子目录、有两个以上视频，或唯一视频带集号。
fn looks_like_show(dir: &Path, videos: &[PathBuf]) -> bool {
    if videos.len() >= 2 {
        return true;
    }
    if read_children(dir)
        .iter()
        .any(|(path, is_dir)| *is_dir && parse_season_dir(&file_name(path)).is_some())
    {
        return true;
    }
    videos
        .iter()
        .any(|p| parse_episode_number(&file_stem(p)).is_some())
}

// —— 文件名解析 ——

/// `Season 01` / `S01` / `第 1 季` / `第一季` → 季号。
fn parse_season_dir(name: &str) -> Option<i32> {
    let lower = name.to_lowercase();

    if let Some(rest) = lower.strip_prefix("season") {
        let digits: String = rest.chars().filter(|c| c.is_ascii_digit()).collect();
        if let Ok(number) = digits.parse::<i32>() {
            if (1..=99).contains(&number) {
                return Some(number);
            }
        }
    }

    // S01 / s1（要求开头是 s + 数字，别再让标题里的 s 混进来）
    if let Some(rest) = lower.strip_prefix('s') {
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        if digits.len() == rest.chars().take_while(|c| c.is_ascii_digit()).count()
            && !digits.is_empty()
        {
            if let Ok(number) = digits.parse::<i32>() {
                if (1..=99).contains(&number) {
                    return Some(number);
                }
            }
        }
    }

    // 第 1 季 / 第一季
    if let Some(rest) = name.strip_prefix('第') {
        if let Some(body) = rest.split(['季', '期']).next() {
            let body = body.trim();
            if let Ok(number) = body.parse::<i32>() {
                return (1..=99).contains(&number).then_some(number);
            }
            if let Some(number) = chinese_number(body) {
                return (1..=99).contains(&number).then_some(number);
            }
        }
    }

    None
}

fn chinese_number(text: &str) -> Option<i32> {
    let digits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
    let chars: Vec<char> = text.chars().collect();
    if chars.len() == 1 {
        let first = chars[0];
        return digits
            .iter()
            .position(|c| *c == first)
            .map(|n| n as i32)
            .or_else(|| (first == '十').then_some(10));
    }
    // 十一 ~ 十九
    if chars.first() == Some(&'十') {
        return chars
            .get(1)
            .and_then(|c| digits.iter().position(|d| d == c))
            .map(|n| 10 + n as i32);
    }
    None
}

/// 从文件名里挑年份：`(2023)`、`（2023）`、`.2023.`、` 2023 `。
fn year_of(text: &str) -> Option<i32> {
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i + 4 <= chars.len() {
        if chars[i..i + 4].iter().all(|c| c.is_ascii_digit()) {
            let raw: String = chars[i..i + 4].iter().collect();
            let before_ok = i == 0
                || !chars[i - 1].is_ascii_alphanumeric();
            let after_ok = i + 4 == chars.len()
                || !chars[i + 4].is_ascii_alphanumeric();
            if before_ok && after_ok {
                if let Ok(year) = raw.parse::<i32>() {
                    if (1900..=2100).contains(&year) {
                        return Some(year);
                    }
                }
            }
        }
        i += 1;
    }
    None
}

/// 发布名清理：`Some.Movie.2023.2160p.BluRay.x265.mkv` → `Some Movie`。
/// 中文标题原样保留，只把点、下划线换成空格并去掉技术词。
fn clean_title(raw: &str) -> String {
    let replaced: String = raw
        .chars()
        .map(|c| match c {
            '.' | '_' => ' ',
            '【' | '】' | '[' | ']' => ' ',
            _ => c,
        })
        .collect();

    let keep: Vec<&str> = replaced
        .split_whitespace()
        .filter(|word| !is_release_word(word))
        .collect();

    let mut text = keep.join(" ");
    // 去掉结尾的年份括号残留，如「电影 (2023)」→「电影」。
    text = text.trim().to_string();
    for pattern in [" (", "（"] {
        if let Some(index) = text.rfind(pattern) {
            let tail = &text[index..];
            if tail.contains(')') || tail.contains('）') {
                let inner: String = tail
                    .chars()
                    .filter(|c| c.is_ascii_digit())
                    .collect();
                if inner.len() == 4 {
                    text.truncate(index);
                }
            }
        }
    }
    text.trim().to_string()
}

fn is_release_word(word: &str) -> bool {
    const WORDS: &[&str] = &[
        "2160p", "1080p", "720p", "480p", "4k", "8k", "uhd", "bluray", "blu-ray", "bdrip",
        "remux", "webrip", "web-dl", "webdl", "web", "hdtv", "dvdrip", "hdr", "hdr10", "hdr10+",
        "dv", "dovi", "sdr", "x264", "x265", "h264", "h265", "hevc", "avc", "10bit", "8bit",
        "aac", "ac3", "eac3", "ddp", "dd", "dts", "dtshd", "truehd", "atmos", "flac", "proper",
        "repack", "internal", "extended", "uncut", "remastered", "imax", "hmax", "60fps",
    ];
    let lower = word.to_lowercase();
    if WORDS.contains(&lower.as_str()) {
        return true;
    }
    // `DDP5.1`、`x265-ABC` 这类合成词。
    lower.starts_with("ddp")
        || lower.starts_with("aac")
        || lower.starts_with("x26")
        || lower.starts_with("h26")
        || lower.starts_with("dts")
}

// —— 路径小工具 ——

fn is_video(path: &Path) -> bool {
    ext_of(path)
        .map(|ext| VIDEO_EXTS.contains(&ext.as_str()))
        .unwrap_or(false)
}

fn is_iso(path: &Path) -> bool {
    ext_of(path)
        .map(|ext| ext == "iso")
        .unwrap_or(false)
}

fn ext_of(path: &Path) -> Option<String> {
    path.extension()
        .map(|e| e.to_string_lossy().to_lowercase())
}

fn file_stem(path: &Path) -> String {
    path.file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn is_hidden(path: &Path) -> bool {
    file_name(path).starts_with('.')
}

/// `root` 到 `path` 的相对路径，统一用 `/`。
fn rel_of(root: &Path, path: &Path) -> String {
    let rel = path.strip_prefix(root).unwrap_or(path);
    rel.to_string_lossy().replace('\\', "/")
}

/// 找不到同名海报时返回 None，界面回退到渐变占位。
fn poster_for(root: &Path, video: &Path) -> Option<String> {
    let dir = video.parent()?;
    let stem = file_stem(video);

    let candidates = [stem.as_str(), "poster", "folder", "cover", "fanart", "backdrop"];
    for name in candidates {
        if name.is_empty() {
            continue;
        }
        for ext in IMAGE_EXTS {
            let path = dir.join(format!("{name}.{ext}"));
            if path.is_file() {
                return Some(rel_of(root, &path));
            }
        }
    }
    None
}

/// 海报路径对外统一加 `img/` 前缀，`image_source` 靠它区分「是不是本地图」。
fn qualify_img(rel: &str) -> String {
    format!("img/{}", encode_id(rel))
}

/// 条目 id 里只用 `/` 分隔路径，冒号会被聚合层当源分隔符，所以转义掉。
fn encode_id(rel: &str) -> String {
    rel.replace('%', "%25").replace(':', "%3A").replace('@', "%40")
}

fn decode_id(id: &str) -> String {
    id.replace("%3A", ":").replace("%40", "@").replace("%25", "%")
}

/// `file://` + 百分号编码，中文路径也能被两端的图片加载器打开。
fn file_url(path: &Path) -> String {
    let mut text = path.to_string_lossy().replace('\\', "/");
    if !text.starts_with('/') {
        text.insert(0, '/');
    }
    let mut out = String::from("file://");
    for part in text.split('/').filter(|p| !p.is_empty()) {
        out.push('/');
        out.push_str(&percent_encode(part));
    }
    if out == "file://" {
        out.push('/');
    }
    out
}

fn resolution_label(rel: &str) -> Option<String> {
    let lower = rel.to_lowercase();
    if lower.contains("2160p") || lower.contains("4k") {
        Some("4K".into())
    } else if lower.contains("1080p") {
        Some("1080p".into())
    } else if lower.contains("720p") {
        Some("720p".into())
    } else {
        None
    }
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "dvplayer-local-{}-{}",
            tag,
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn touch(path: &Path) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, b"x").unwrap();
    }

    fn make_source(root: &Path) -> LocalSource {
        let mut source = LocalSource::new(
            "local-1".into(),
            "本地文件".into(),
            root.to_string_lossy().into_owned(),
            root.join(".data").to_string_lossy().into_owned(),
        );
        source.login().unwrap();
        source
    }

    #[test]
    fn season_and_episode_numbers() {
        assert_eq!(parse_season_dir("Season 01"), Some(1));
        assert_eq!(parse_season_dir("S02"), Some(2));
        assert_eq!(parse_season_dir("第 3 季"), Some(3));
        assert_eq!(parse_season_dir("第二季"), Some(2));
        assert_eq!(parse_season_dir("第十一季"), Some(11));
        assert_eq!(parse_season_dir("Extras"), None);
    }

    #[test]
    fn title_cleaning_and_year() {
        assert_eq!(clean_title("Some.Movie.2023.2160p.BluRay.x265"), "Some Movie 2023");
        assert_eq!(year_of("Some.Movie.2023.2160p"), Some(2023));
        assert_eq!(year_of("电影 (2021)"), Some(2021));
        assert_eq!(year_of("1080p"), None);
    }

    #[test]
    fn scans_movies_and_shows() {
        let root = temp_root("scan");
        touch(&root.join("电影A (2021)/电影A.2021.1080p.mkv"));
        touch(&root.join("某剧/Season 01/S01E02.mkv"));
        touch(&root.join("某剧/Season 01/S01E01.mkv"));
        touch(&root.join("某剧/Season 02/S02E01.mkv"));

        let source = make_source(&root);
        let page = source
            .items(LIBRARY_ID, 1, 60, &ListQuery::default())
            .unwrap();
        assert_eq!(page.total, 2);

        let movie = page
            .items
            .iter()
            .find(|i| i.kind == MediaKind::Movie)
            .unwrap();
        assert_eq!(movie.year, Some(2021));
        assert!(movie.title.contains("电影A"));

        let show = page
            .items
            .iter()
            .find(|i| i.kind == MediaKind::Series)
            .unwrap();
        assert_eq!(show.season_count, Some(2));
        assert_eq!(show.episode_count, Some(3));

        // 两季 → children 先给季。
        let seasons = source
            .children(&show.id, 1, 60, &ListQuery::default())
            .unwrap();
        assert_eq!(seasons.total, 2);
        assert_eq!(seasons.items[0].season_number, Some(1));

        let episodes = source
            .children(&seasons.items[0].id, 1, 60, &ListQuery::default())
            .unwrap();
        assert_eq!(episodes.total, 2);
        assert_eq!(episodes.items[0].episode_number, Some(1));
        assert_eq!(episodes.items[1].episode_number, Some(2));

        // 播第二集时能拿到正确文件。
        let play = source.play_source(&episodes.items[1].id).unwrap();
        assert!(play.url.ends_with("S01E02.mkv"), "{}", play.url);
        assert!(!play.disc);

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn single_season_skips_the_season_level() {
        let root = temp_root("single");
        touch(&root.join("一部剧/S01E01.mkv"));
        touch(&root.join("一部剧/S01E02.mkv"));

        let source = make_source(&root);
        let page = source
            .items(LIBRARY_ID, 1, 60, &ListQuery::default())
            .unwrap();
        let show = &page.items[0];
        assert_eq!(show.single_child_id.is_some(), true);

        let children = source
            .children(&show.id, 1, 60, &ListQuery::default())
            .unwrap();
        assert_eq!(children.total, 2);
        assert_eq!(children.items[0].kind, MediaKind::Episode);

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn progress_is_persisted_and_listed_as_records() {
        let root = temp_root("progress");
        touch(&root.join("某剧/S01E01.mkv"));

        let source = make_source(&root);
        let page = source
            .items(LIBRARY_ID, 1, 60, &ListQuery::default())
            .unwrap();
        let show = &page.items[0];
        let episodes = source
            .children(&show.id, 1, 60, &ListQuery::default())
            .unwrap();
        let episode_id = episodes.items[0].id.clone();

        source.report_progress(&episode_id, 120, 1440).unwrap();

        let records = source.records().unwrap();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].item_id, episode_id);
        assert_eq!(records[0].position_seconds, 120);
        assert_eq!(records[0].series_title.as_deref(), Some("某剧"));

        // 重新建一个源（模拟重启）也能读到。
        let again = make_source(&root);
        let play = again.play_source(&episode_id).unwrap();
        assert_eq!(play.position_seconds, 120);

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn iso_is_a_movie_with_disc_flag() {
        let root = temp_root("iso");
        touch(&root.join("原盘.iso"));

        let source = make_source(&root);
        let page = source
            .items(LIBRARY_ID, 1, 60, &ListQuery::default())
            .unwrap();
        assert_eq!(page.total, 1);
        assert_eq!(page.items[0].kind, MediaKind::Movie);

        let play = source.play_source(&page.items[0].id).unwrap();
        assert!(play.disc);
    }

    #[test]
    fn local_poster_is_found_next_to_the_video() {
        let root = temp_root("poster");
        touch(&root.join("电影.mkv"));
        touch(&root.join("电影.jpg"));

        let source = make_source(&root);
        let page = source
            .items(LIBRARY_ID, 1, 60, &ListQuery::default())
            .unwrap();
        let poster = page.items[0].poster_path.clone().unwrap();
        assert!(poster.starts_with("img/"));

        let image = source.image_source(&poster).unwrap();
        assert!(image.url.starts_with("file://"));

        let _ = fs::remove_dir_all(&root);
    }
}
