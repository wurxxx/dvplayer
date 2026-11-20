//! 聚合层：把多个媒体源合并成「一个界面」。
//!
//! 为什么要放在核心里：Android / TV / macOS 也要同样的合并规则，写在 UI 里等于
//! 每个端抄一遍（ARCHITECTURE §1.2）。
//!
//! 身份规则：对外所有 id 都是 `<sourceId>:<rawId>`，图片路径同理
//! （`<sourceId>:/4e/05/poster.webp`）。适配器内部只认自己的裸 id，
//! 进出聚合层时统一加/去前缀，界面拿到的 id 始终可以跨源唯一定位。

use std::collections::HashMap;

use crate::error::{MediaError, Result};
use crate::models::{
    Person,
    MediaInfo,
    Genre, ImageSource, ListQuery, MediaDetail, MediaItem, MediaLibrary, Paged, PlayRecord,
    PlaySource,
};
use crate::sources::{create, MediaSource, SourceConfig};

/// 分隔符：源的 id 来自配置（guid / uuid），不会含冒号。
const SEP: char = ':';

pub struct MediaHub {
    entries: Vec<Entry>,
}

struct Entry {
    id: String,
    source: Box<dyn MediaSource>,
}

/// 合并前先记下是哪个源给的库，重名时要用源名区分。
struct QualifiedLibrary {
    entry_id: String,
    source_name: String,
    library: MediaLibrary,
}

impl Default for MediaHub {
    fn default() -> Self {
        Self::new()
    }
}

impl MediaHub {
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }

    /// 直接挂一个适配器（测试与将来的「本地目录源」用）。
    pub fn add_source(&mut self, id: &str, mut source: Box<dyn MediaSource>) -> Result<()> {
        source.login()?;
        self.entries.push(Entry {
            id: id.to_string(),
            source,
        });
        Ok(())
    }

    /// 添加并登录一个源。单个源失败不影响其它源，由调用方决定怎么提示。
    pub fn add(&mut self, config: &SourceConfig) -> Result<()> {
        let source = create(config).ok_or_else(|| MediaError::Other(format!(
            "不支持的源类型：{}",
            config.kind
        )))?;

        self.add_source(&config.id, source)
    }

    /// 已连接的源（id, 名称, 类型），设置页用它显示健康状态。
    pub fn sources(&self) -> Vec<SourceInfo> {
        self.entries
            .iter()
            .map(|e| SourceInfo {
                id: e.id.clone(),
                name: e.source.name().to_string(),
                kind: e.source.kind().to_string(),
            })
            .collect()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// 所有源的媒体库；某个源失败就跳过它，全失败才报错。
    ///
    /// 两个源都叫「影视」时，标题后追加源名，否则界面上分不清按下的是哪个。
    pub fn libraries(&self) -> Result<Vec<MediaLibrary>> {
        let mut list = self.collect(
            |entry| entry.source.libraries(),
            |entry, library| QualifiedLibrary {
                entry_id: entry.id.clone(),
                source_name: entry.source.name().to_string(),
                library,
            },
        )?;

        let mut counts: HashMap<String, usize> = HashMap::new();
        for item in &list {
            *counts.entry(item.library.title.clone()).or_default() += 1;
        }

        Ok(list
            .drain(..)
            .map(|QualifiedLibrary { entry_id, source_name, mut library }| {
                let title = library.title.clone();
                if counts.get(&title).copied().unwrap_or(0) > 1 {
                    library.title = format!("{title} · {source_name}");
                }

                library.id = qualify(&entry_id, &library.id);
                // 聚合层的「源」是入口 id，与设置页的 Connections 对齐。
                library.source_id = entry_id;
                library.poster_path = qualify_opt(&library.source_id, library.poster_path.take());
                library
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
        let (entry, raw) = self.route(library_id)?;
        let mut paged = entry.source.items(raw, page, page_size, query)?;
        qualify_items(&entry.id, &mut paged.items);
        Ok(paged)
    }

    /// 某个库可用的风格列表，id 与 [`ListQuery::genre`] 对得上。
    pub fn genres(&self, scope_id: &str) -> Result<Vec<Genre>> {
        let (entry, raw) = self.route(scope_id)?;
        entry.source.genres(raw)
    }

    /// 跨源关键词搜索。各源结果合并后截断，避免界面一次塞太多。
    pub fn search(&self, query: &str) -> Result<Vec<MediaItem>> {
        let mut list = self.collect(
            |entry| entry.source.search(query),
            |entry, mut item| {
                qualify_items(&entry.id, std::slice::from_mut(&mut item));
                item
            },
        )?;

        list.truncate(120);
        Ok(list)
    }

    pub fn children(
        &self,
        parent_id: &str,
        page: i32,
        page_size: i32,
        query: &ListQuery,
    ) -> Result<Paged<MediaItem>> {
        let (entry, raw) = self.route(parent_id)?;
        let mut paged = entry.source.children(raw, page, page_size, query)?;
        qualify_items(&entry.id, &mut paged.items);
        Ok(paged)
    }

    pub fn detail(&self, item_id: &str) -> Result<MediaDetail> {
        let (entry, raw) = self.route(item_id)?;
        let mut detail = entry.source.detail(raw)?;

        detail.id = qualify(&entry.id, &detail.id);
        detail.poster_path = qualify_opt(&entry.id, detail.poster_path);
        detail.backdrop_path = qualify_opt(&entry.id, detail.backdrop_path);
        detail.logo_path = qualify_opt(&entry.id, detail.logo_path);
        detail.play_item_id = qualify_opt(&entry.id, detail.play_item_id);

        Ok(detail)
    }

    /// 详情页「媒体信息」。条目 id 可能带源前缀，这里去掉再交给适配器。
    pub fn media_info(&self, item_id: &str) -> Result<MediaInfo> {
        let (entry, raw) = self.route(item_id)?;
        entry.source.media_info(raw)
    }

    /// 某个演职人员的作品。
    pub fn person_works(&self, person_id: &str) -> Result<Vec<MediaItem>> {
        let (entry, raw) = self.route(person_id)?;
        let mut items = entry.source.person_works(raw)?;

        for item in &mut items {
            item.poster_path = qualify_opt(&entry.id, item.poster_path.take());
        }

        Ok(items)
    }

    /// 演职人员；头像路径也要加源前缀，界面才知道去哪取图。
    pub fn people(&self, item_id: &str) -> Result<Vec<Person>> {
        let (entry, raw) = self.route(item_id)?;
        let mut people = entry.source.people(raw)?;

        for person in &mut people {
            person.image_path = qualify_opt(&entry.id, person.image_path.take());
            if !person.id.is_empty() {
                person.id = qualify(&entry.id, &person.id);
            }
        }

        Ok(people)
    }

    pub fn play_source(&self, item_id: &str) -> Result<PlaySource> {
        let (entry, raw) = self.route(item_id)?;
        let mut play = entry.source.play_source(raw)?;

        play.item_id = qualify(&entry.id, &play.item_id);
        play.poster_path = qualify_opt(&entry.id, play.poster_path);

        Ok(play)
    }

    /// 进度只回写到**播放的那个源**，不做跨源同步（ARCHITECTURE §1.2）。
    pub fn report_progress(&self, item_id: &str, position: i64, duration: i64) -> Result<()> {
        let (entry, raw) = self.route(item_id)?;
        entry.source.report_progress(raw, position, duration)
    }

    /// 收藏 / 取消收藏。
    pub fn set_favorite(&self, item_id: &str, favorite: bool) -> Result<()> {
        let (entry, raw) = self.route(item_id)?;
        entry.source.set_favorite(raw, favorite)
    }

    /// 标记已观看 / 未观看。
    pub fn set_watched(&self, item_id: &str, watched: bool) -> Result<()> {
        let (entry, raw) = self.route(item_id)?;
        entry.source.set_watched(raw, watched)
    }

    /// 移除观看记录。
    pub fn remove_play_record(&self, item_id: &str) -> Result<()> {
        let (entry, raw) = self.route(item_id)?;
        entry.source.remove_play_record(raw)
    }

    /// 合并所有源的收藏列表。
    pub fn favorites(&self, page: i32, page_size: i32) -> Result<Paged<MediaItem>> {
        let mut items = Vec::new();
        let mut total = 0i64;
        let mut last_error = None;

        for entry in &self.entries {
            match entry.source.favorites(page, page_size) {
                Ok(paged) => {
                    total += paged.total;
                    let mut list = paged.items;
                    qualify_items(&entry.id, &mut list);
                    items.extend(list);
                }
                Err(err) => last_error = Some(err),
            }
        }

        if items.is_empty() {
            if let Some(err) = last_error {
                return Err(err);
            }
        }

        Ok(Paged {
            items,
            total,
            page,
            page_size,
        })
    }

    /// 合并所有源的播放记录，按最近播放倒序。
    pub fn records(&self) -> Result<Vec<PlayRecord>> {
        let mut merged = self.collect(
            |entry| entry.source.records(),
            |entry, mut record| {
                record.item_id = qualify(&entry.id, &record.item_id);
                record.poster_path = qualify_opt(&entry.id, record.poster_path);
                record
            },
        )?;

        merged.sort_by(|a, b| b.last_played.unwrap_or(0).cmp(&a.last_played.unwrap_or(0)));
        Ok(merged)
    }

    pub fn image_source(&self, path: &str) -> Result<ImageSource> {
        let (entry, raw) = self.route(path)?;
        entry.source.image_source(raw)
    }

    // —— 内部 ——

    fn route<'a>(&'a self, qualified: &'a str) -> Result<(&'a Entry, &'a str)> {
        let (source_id, raw) = split(qualified)?;
        let entry = self
            .entries
            .iter()
            .find(|e| e.id == source_id)
            .ok_or_else(|| MediaError::Other(format!("没有这个媒体源：{source_id}")))?;

        Ok((entry, raw))
    }

    /// 对每个源跑一次，把结果按 `map` 转成对外形状；跳过失败的源。
    fn collect<T, U, F, M>(&self, fetch: F, map: M) -> Result<Vec<U>>
    where
        F: Fn(&Entry) -> Result<Vec<T>>,
        M: Fn(&Entry, T) -> U,
    {
        let mut out = Vec::new();
        let mut last_error = None;

        for entry in &self.entries {
            match fetch(entry) {
                Ok(list) => out.extend(list.into_iter().map(|item| map(entry, item))),
                Err(err) => last_error = Some(err),
            }
        }

        if out.is_empty() {
            if let Some(err) = last_error {
                return Err(err);
            }
        }

        Ok(out)
    }
}

/// 已连接的源。
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceInfo {
    pub id: String,
    pub name: String,
    pub kind: String,
}

fn qualify(source_id: &str, id: &str) -> String {
    if id.is_empty() {
        return String::new();
    }
    format!("{source_id}{SEP}{id}")
}

fn qualify_opt(source_id: &str, value: Option<String>) -> Option<String> {
    value.map(|v| qualify(source_id, &v))
}

fn split(qualified: &str) -> Result<(&str, &str)> {
    qualified
        .split_once(SEP)
        .filter(|(source, raw)| !source.is_empty() && !raw.is_empty())
        .ok_or_else(|| MediaError::Other(format!("条目 id 缺少源前缀：{qualified}")))
}

fn qualify_items(source_id: &str, items: &mut [MediaItem]) {
    for item in items {
        item.id = qualify(source_id, &item.id);
        item.parent_id = qualify_opt(source_id, item.parent_id.take());
        item.poster_path = qualify_opt(source_id, item.poster_path.take());
        item.backdrop_path = qualify_opt(source_id, item.backdrop_path.take());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qualify_and_split_roundtrip() {
        assert_eq!(qualify("fnos-1", "abc"), "fnos-1:abc");
        assert_eq!(split("fnos-1:abc").unwrap(), ("fnos-1", "abc"));
        // 图片路径带前导斜杠也照样切第一个冒号。
        assert_eq!(
            split("fnos-1:/4e/05/poster.webp").unwrap(),
            ("fnos-1", "/4e/05/poster.webp")
        );
        assert!(split("abc").is_err());
        assert!(split(":abc").is_err());
        assert!(split("fnos-1:").is_err());
        assert_eq!(qualify("fnos-1", ""), "");
    }


    // —— 用一个假源验证「进出带前缀」这件事，不碰网络 ——

    struct Mock {
        tag: &'static str,
    }

    impl Mock {
        fn boxed(tag: &'static str) -> Box<dyn MediaSource> {
            Box::new(Self { tag })
        }
    }

    impl MediaSource for Mock {
        fn kind(&self) -> &'static str {
            "mock"
        }

        fn name(&self) -> &str {
            self.tag
        }

        fn login(&mut self) -> Result<()> {
            Ok(())
        }

        fn libraries(&self) -> Result<Vec<MediaLibrary>> {
            Ok(vec![MediaLibrary {
                id: format!("lib-{}", self.tag),
                title: "影视".to_string(),
                source_id: self.tag.to_string(),
                poster_path: Some("/p.webp".into()),
                category: "Movie".into(),
            }])
        }

        fn items(
            &self,
            library_id: &str,
            page: i32,
            page_size: i32,
            _query: &ListQuery,
        ) -> Result<Paged<MediaItem>> {
            Ok(Paged {
                items: vec![self.item("1", library_id)],
                total: 1,
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
            Ok(Paged {
                items: vec![self.item("2", parent_id)],
                total: 1,
                page,
                page_size,
            })
        }

        fn search(&self, _query: &str) -> Result<Vec<MediaItem>> {
            Ok(Vec::new())
        }

        fn detail(&self, item_id: &str) -> Result<MediaDetail> {
            Ok(MediaDetail {
                id: item_id.to_string(),
                title: format!("{}-{item_id}", self.tag),
                kind: crate::models::MediaKind::Series,
                original_title: None,
                overview: None,
                poster_path: Some("/p.webp".into()),
                backdrop_path: Some("/b.webp".into()),
                logo_path: None,
                rating: None,
                release_date: None,
                runtime_seconds: None,
                season_count: None,
                local_season_count: None,
                episode_count: None,
                local_episode_count: None,
                status: None,
                resolution: None,
                audio_type: None,
                color_range: None,
                play_item_id: Some("3".into()),
                single_child_id: None,
                is_favorite: None,
                is_watched: None,
            })
        }

        fn records(&self) -> Result<Vec<PlayRecord>> {
            // 两个源给出不同的最近播放时间，合并后应倒序。
            let last = if self.tag == "a" { 100 } else { 200 };
            Ok(vec![PlayRecord {
                item_id: "9".into(),
                title: format!("{}-9", self.tag),
                source_id: self.tag.to_string(),
                series_title: None,
                season_number: None,
                episode_number: None,
                poster_path: Some("/p.webp".into()),
                position_seconds: 10,
                duration_seconds: 100,
                last_played: Some(last),
            }])
        }

        fn report_progress(&self, _item_id: &str, _position: i64, _duration: i64) -> Result<()> {
            Ok(())
        }

        fn play_source(&self, item_id: &str) -> Result<PlaySource> {
            Ok(PlaySource {
                item_id: item_id.to_string(),
                title: String::new(),
                url: format!("http://{}/{item_id}", self.tag),
                headers: Vec::new(),
                is_direct: true,
                media_guid: String::new(),
                video_guid: None,
                audio_guid: None,
                subtitle_guid: None,
                position_seconds: 0,
                duration_seconds: 0,
                overview: None,
                poster_path: Some("/p.webp".into()),
                resolution: None,
                color_range: None,
                dolby_vision: false,
                video_codec: None,
                audio_codec: None,
                audio_streams: Vec::new(),
                subtitle_streams: Vec::new(),
            })
        }

        fn image_source(&self, path: &str) -> Result<ImageSource> {
            Ok(ImageSource {
                url: format!("http://{}{path}", self.tag),
                headers: Vec::new(),
            })
        }
    }

    impl Mock {
        fn item(&self, id: &str, parent: &str) -> MediaItem {
            MediaItem {
                id: id.to_string(),
                title: format!("{}-{id}", self.tag),
                kind: crate::models::MediaKind::Video,
                source_id: self.tag.to_string(),
                poster_path: Some("/x.webp".into()),
                parent_id: Some(parent.to_string()),
                parent_title: None,
                year: None,
                runtime_seconds: None,
                progress: 0.0,
                is_favorite: false,
                overview: None,
                resolution: None,
                last_played: None,
                season_number: None,
                episode_number: None,
                episode_count: None,
                local_episode_count: None,
                season_count: None,
                rating: None,
                release_date: None,
                status: None,
                backdrop_path: None,
                single_child_id: None,
            }
        }
    }

    fn two_sources() -> MediaHub {
        let mut hub = MediaHub::new();
        hub.add_source("a", Mock::boxed("a")).unwrap();
        hub.add_source("b", Mock::boxed("b")).unwrap();
        hub
    }

    #[test]
    fn libraries_are_merged_and_prefixed() {
        let libs = two_sources().libraries().unwrap();
        assert_eq!(libs.len(), 2);
        assert_eq!(libs[0].id, "a:lib-a");
        assert_eq!(libs[0].source_id, "a");
        assert_eq!(libs[0].poster_path.as_deref(), Some("a:/p.webp"));
        assert_eq!(libs[1].id, "b:lib-b");
    }

    #[test]
    fn duplicate_library_titles_get_the_source_name() {
        // 两个源都叫「影视」，标题必须能区分，否则胶囊按错了都不知道。
        let libs = two_sources().libraries().unwrap();
        assert_eq!(libs[0].title, "影视 · a");
        assert_eq!(libs[1].title, "影视 · b");
    }

    #[test]
    fn items_go_back_to_the_right_source() {
        let hub = two_sources();

        let page = hub.items("b:lib-b", 1, 60, &ListQuery::default()).unwrap();
        assert_eq!(page.items[0].id, "b:1");
        assert_eq!(page.items[0].parent_id.as_deref(), Some("b:lib-b"));
        assert_eq!(page.items[0].poster_path.as_deref(), Some("b:/x.webp"));

        let kids = hub.children("a:1", 1, 60, &ListQuery::default()).unwrap();
        assert_eq!(kids.items[0].id, "a:2");
        assert_eq!(kids.items[0].parent_id.as_deref(), Some("a:1"));
    }

    #[test]
    fn detail_and_play_source_carry_prefix() {
        let hub = two_sources();

        let detail = hub.detail("a:1").unwrap();
        assert_eq!(detail.id, "a:1");
        assert_eq!(detail.poster_path.as_deref(), Some("a:/p.webp"));
        assert_eq!(detail.play_item_id.as_deref(), Some("a:3"));

        let play = hub.play_source("b:2").unwrap();
        assert_eq!(play.item_id, "b:2");
        assert_eq!(play.url, "http://b/2");
        assert_eq!(play.poster_path.as_deref(), Some("b:/p.webp"));
    }

    #[test]
    fn records_are_merged_newest_first() {
        let records = two_sources().records().unwrap();
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].item_id, "b:9");
        assert_eq!(records[1].item_id, "a:9");
    }

    #[test]
    fn image_source_keeps_the_raw_path() {
        let image = two_sources().image_source("b:/p.webp").unwrap();
        assert_eq!(image.url, "http://b/p.webp");
    }

    #[test]
    fn unknown_source_is_reported() {
        let hub = MediaHub::new();
        let err = hub.detail("nope:x").unwrap_err().to_string();
        assert!(err.contains("没有这个媒体源"), "{err}");
    }
}
