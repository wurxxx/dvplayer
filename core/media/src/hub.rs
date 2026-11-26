//! 聚合层：把多个媒体源合并成「一个界面」。
//!
//! 为什么要放在核心里：Android / TV / macOS 也要同样的合并规则，写在 UI 里等于
//! 每个端抄一遍（ARCHITECTURE §1.2）。
//!
//! 身份规则：对外所有 id 都是 `<sourceId>:<rawId>`，图片路径同理
//! （`<sourceId>:/4e/05/poster.webp`）。适配器内部只认自己的裸 id，
//! 进出聚合层时统一加/去前缀，界面拿到的 id 始终可以跨源唯一定位。

use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde::Serialize;

use crate::error::{MediaError, Result};
use crate::models::{
    Person,
    MediaInfo,
    Genre, ImageSource, ItemSource, ListQuery, MediaDetail, MediaItem, MediaKind, MediaLibrary,
    Paged, PlayRecord, PlaySource, SearchResult, SourceFailure,
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

/// 并行建连的一个结果。界面用它显示每个源连没连上、花了多久。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceConnect {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// 建连（含登录）耗时，毫秒。
    pub ms: u64,
    /// 网络往返延迟（毫秒）。本地目录没有，探测失败也没有。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latency_ms: Option<u64>,
}

/// 一个源建连的结果：适配器（成功时）+ 给界面的状态。失败时带错误文本。
type LoginOutcome = (
    SourceConfig,
    std::result::Result<Box<dyn MediaSource>, String>,
    SourceConnect,
);

/// 创建 + 登录一个源，顺带测一次延迟。跑在建连线程里，不碰任何共享结构。
fn login_one(config: SourceConfig) -> LoginOutcome {
    let started = Instant::now();
    let result = match create(&config) {
        Some(mut source) => source
            .login()
            .map(|()| source)
            .map_err(|err| err.to_string()),
        None => Err(format!("不支持的源类型：{}", config.kind)),
    };
    // 登录成功后再测一次往返：连接池已热，量到的是真正的延迟，
    // 而不是 DNS / TLS 握手的开销。
    let latency = if result.is_ok() {
        probe_latency(&config)
    } else {
        None
    };

    let info = match &result {
        Ok(_) => SourceConnect {
            id: config.id.clone(),
            name: config.name.clone(),
            kind: config.kind.clone(),
            ok: true,
            error: None,
            ms: started.elapsed().as_millis() as u64,
            latency_ms: latency,
        },
        Err(error) => SourceConnect {
            id: config.id.clone(),
            name: config.name.clone(),
            kind: config.kind.clone(),
            ok: false,
            error: Some(error.clone()),
            ms: started.elapsed().as_millis() as u64,
            latency_ms: None,
        },
    };

    (config, result, info)
}

/// 并行建连多个源，**不碰聚合层**：每连好一个就把适配器交给 `on_result`。
///
/// FFI 用它来实现「谁连完谁先挂」：回调里短暂持有 `Mutex<MediaHub>` 推一条，
/// 慢源不会挡住其它源的查询——以前整个 `dv_hub_add_many_stream` 期间都持有
/// 那把锁，首页明明有一个源已经连上，也要等最慢的那个超时才出内容。
///
/// `on_result` 从多个建连线程同时进来，实现方自己保证线程安全。
/// 返回结果保持 `configs` 的顺序。
pub fn connect_many<F>(configs: &[SourceConfig], on_result: F) -> Vec<SourceConnect>
where
    F: Fn(SourceConfig, std::result::Result<Box<dyn MediaSource>, String>, SourceConnect) + Sync,
{
    let on_result = &on_result;
    let (tx, rx) = std::sync::mpsc::channel::<(usize, SourceConnect)>();
    let mut slots: Vec<Option<SourceConnect>> = (0..configs.len()).map(|_| None).collect();

    std::thread::scope(|scope| {
        let mut handles = Vec::with_capacity(configs.len());
        for (index, config) in configs.iter().cloned().enumerate() {
            let tx = tx.clone();
            let worker = config.clone();
            handles.push((index, config, scope.spawn(move || {
                let (config, result, info) = login_one(worker);
                on_result(config, result, info.clone());
                let _ = tx.send((index, info));
            })));
        }
        drop(tx);

        for (index, info) in rx {
            slots[index] = Some(info);
        }

        for (index, config, handle) in handles {
            if handle.join().is_err() && slots[index].is_none() {
                let info = SourceConnect {
                    id: config.id.clone(),
                    name: config.name.clone(),
                    kind: config.kind.clone(),
                    ok: false,
                    error: Some("建连线程异常退出".to_string()),
                    ms: 0,
                    latency_ms: None,
                };
                on_result(config, Err("建连线程异常退出".to_string()), info.clone());
                slots[index] = Some(info);
            }
        }
    });

    slots.into_iter().flatten().collect()
}

/// 合并前先记下是哪个源给的库，重名时要用源名区分。
struct QualifiedLibrary {
    entry_id: String,
    source_name: String,
    library: MediaLibrary,
}

/// 测一次已登录源的网络延迟：先预热建立连接，再计时一次请求。
///
/// 只测走 HTTP 的源（本地目录没有「延迟」）；3 秒超时、拿不到响应就返回 None。
/// 用与适配器相同的客户端构造，所以源的代理设置同样生效。
fn probe_latency(config: &SourceConfig) -> Option<u64> {
    if !matches!(
        config.kind.as_str(),
        "fnos" | "feiniu" | "emby" | "jellyfin" | "webdav"
    ) {
        return None;
    }

    let url = config.base.trim().trim_end_matches('/');
    if url.is_empty() {
        return None;
    }

    let client = crate::sources::http_client(&config.proxy);
    let timeout = Duration::from_secs(3);

    // 第一次可能要走 DNS + TCP + TLS，结果不计时。
    let _ = client.get(url).timeout(timeout).send();

    let started = Instant::now();
    match client.get(url).timeout(timeout).send() {
        Ok(_) => Some(started.elapsed().as_millis() as u64),
        Err(_) => None,
    }
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

    /// 把已经登录好的适配器挂进来。
    ///
    /// FFI 走的是「谁连完谁先挂」：`connect_many` 每交出一个源就短暂加锁调它一次，
    /// 慢源不会再挡住其它源的 `libraries()` / `items()`。
    pub fn push_source(&mut self, id: &str, source: Box<dyn MediaSource>) {
        self.entries.push(Entry {
            id: id.to_string(),
            source,
        });
    }

    /// 并行建连多个源，不回报中间状态（一次性拿全部结果）。
    pub fn add_many(&mut self, configs: &[SourceConfig]) -> Vec<SourceConnect> {
        self.add_many_stream(configs, |_| {})
    }

    /// 并行建连多个源：每个源一个线程去创建 + 登录，**谁先连完谁先挂进聚合层**。
    /// 登录是网络等待，串行时 3 个服务器就要等 3 份时间。
    ///
    /// `on_done` 在**每个源刚连完时**立即调用（哪个快哪个先到），界面不用等
    /// 最慢的那个才更新状态。线程里只碰自己的适配器，`entries` 只由本线程写，
    /// 所以不用加锁；慢源还没连完，先连上的源已经可以查了。
    ///
    /// 失败的源带 `error` 返回，不影响其它源；`ms` 是建连（含登录）耗时。
    /// 返回结果保持 `configs` 的顺序。
    pub fn add_many_stream<F>(&mut self, configs: &[SourceConfig], on_done: F) -> Vec<SourceConnect>
    where
        F: Fn(SourceConnect) + Sync,
    {
        let on_done = &on_done;
        let (tx, rx) = std::sync::mpsc::channel::<(usize, LoginOutcome)>();
        let mut slots: Vec<Option<SourceConnect>> = (0..configs.len()).map(|_| None).collect();

        std::thread::scope(|scope| {
            let mut handles = Vec::with_capacity(configs.len());
            for (index, config) in configs.iter().cloned().enumerate() {
                let tx = tx.clone();
                let worker = config.clone();
                handles.push((index, config, scope.spawn(move || {
                    let done = login_one(worker);
                    on_done(done.2.clone());
                    let _ = tx.send((index, done));
                })));
            }
            drop(tx);

            // 谁先连完谁先到：先到的源立刻挂进来，后面的查询不用等慢源。
            for (index, (config, result, info)) in rx {
                if let Ok(source) = result {
                    self.push_source(&config.id, source);
                }
                slots[index] = Some(info);
            }

            // 建连线程 panic 的源补一条失败结果（以前靠 join 的 Err 分支）。
            for (index, config, handle) in handles {
                if handle.join().is_err() && slots[index].is_none() {
                    let info = SourceConnect {
                        id: config.id,
                        name: config.name,
                        kind: config.kind,
                        ok: false,
                        error: Some("建连线程异常退出".to_string()),
                        ms: 0,
                        latency_ms: None,
                    };
                    on_done(info.clone());
                    slots[index] = Some(info);
                }
            }
        });

        slots.into_iter().flatten().collect()
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

    /// 跨源关键词搜索：各源并发，按「标题 + 年份 + 类型（剧再比集数）」去重，
    /// 同一部片只留一条，其余来源挂在 `sources` 里供界面切换。
    ///
    /// 选主源：有进度 > 用户设的源顺序（`entries` 顺序）> 分辨率。
    /// 某个源失败只进 `failed`，不影响其它源；全失败才返回错误。
    pub fn search(&self, query: &str) -> Result<SearchResult> {
        let mut failed = Vec::new();
        let mut groups: Vec<Group> = Vec::new();

        // 并发跑，一个源卡住不拖慢整次搜索。
        let labels: Vec<(usize, String, String)> = self
            .entries
            .iter()
            .enumerate()
            .map(|(priority, entry)| {
                (priority, entry.id.clone(), entry.source.name().to_string())
            })
            .collect();

        let results = std::thread::scope(|scope| {
            let handles: Vec<_> = self
                .entries
                .iter()
                .map(|entry| scope.spawn(move || entry.source.search(query)))
                .collect();

            handles
                .into_iter()
                .map(|handle| handle.join())
                .collect::<Vec<_>>()
        });

        for (joined, (priority, source_id, source_name)) in results.into_iter().zip(labels) {
            match joined {
                Ok(Ok(items)) => {
                    for mut item in items {
                        // 命中的是集 / 季：按父级归并成一部剧。
                        promote_episode(&mut item);
                        qualify_items(&source_id, std::slice::from_mut(&mut item));

                        let candidate = Candidate {
                            source_id: source_id.clone(),
                            source_name: source_name.clone(),
                            priority,
                            item,
                        };
                        let key = GroupKey::of(&candidate.item);
                        let found = groups.iter_mut().position(|group| group.key.absorb(&key));
                        match found {
                            Some(index) => groups[index].push(candidate),
                            None => groups.push(Group::new(key, candidate)),
                        }
                    }
                }
                Ok(Err(err)) => failed.push(SourceFailure {
                    source_id,
                    source_name,
                    error: err.to_string(),
                }),
                // 某个源的搜索线程 panic 了：不能当成「没有结果」，
                // 否则用户看到的是「本服务器没有这部片」。
                Err(_) => failed.push(SourceFailure {
                    source_id,
                    source_name,
                    error: "搜索时源内部错误".to_string(),
                }),
            }
        }

        if groups.is_empty() && !failed.is_empty() {
            let message = failed
                .iter()
                .map(|f| format!("{}：{}", f.source_name, f.error))
                .collect::<Vec<_>>()
                .join("；");
            return Err(MediaError::Other(format!("所有源都搜索失败：{message}")));
        }

        // 组内选主；组间有进度的在前，其余保持源返回顺序（稳定排序）。
        for group in &mut groups {
            group.sort();
        }
        groups.sort_by(|a, b| b.has_progress().cmp(&a.has_progress()));

        let items = groups
            .into_iter()
            .map(Group::finish)
            .take(120)
            .collect();

        Ok(SearchResult { items, failed })
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

    /// 详情页「资源」列表：同一部片在所有源里的条目。
    ///
    /// 从搜索页之外的入口（媒体库、记录、播放页下一集）进详情时，界面手里只有
    /// 一个条目 id；这里用详情标题各源再搜一遍，按搜索去重的同一套规则归组，
    /// 把同一部片的其它源找出来。排序同搜索：有进度 > 源顺序 > 分辨率。
    pub fn item_sources(&self, item_id: &str) -> Result<Vec<ItemSource>> {
        let (entry, raw) = self.route(item_id)?;
        let detail = entry.source.detail(raw)?;

        // 单集 / 单季不进「资源」：那是一部剧内部的层级，不是同一部片的另一个源。
        if matches!(detail.kind, MediaKind::Episode | MediaKind::Season) {
            return Ok(Vec::new());
        }

        let key = GroupKey {
            title: crate::text::normalize_key(&detail.title),
            year: detail
                .release_date
                .as_deref()
                .and_then(crate::text::year_of),
            kind: group_kind(detail.kind),
            episodes: detail.episode_count.or(detail.local_episode_count),
        };

        let mut rows: Vec<(usize, ItemSource)> = Vec::new();

        // 先放各源搜到的那一条（带真实进度）。一个源只留一条：搜索里已经把
        // 同源的剧 / 季合并了，这里再按 source_id 兜一层，资源列表不会出现
        // 同一个服务器两次。
        if let Ok(found) = self.search(&detail.title) {
            for item in found.items {
                if !key.matches(&GroupKey::of(&item)) {
                    continue;
                }
                for source in item.sources {
                    if rows.iter().any(|(_, row)| row.source_id == source.source_id) {
                        continue;
                    }
                    let priority = self
                        .entries
                        .iter()
                        .position(|e| e.id == source.source_id)
                        .unwrap_or(usize::MAX);
                    rows.push((priority, source));
                }
            }
        }

        // 当前详情所在的源用详情自己的 id：同一部剧的季 / 另一条重复条目
        // 不能顶掉用户正在看的这一条。
        let own_id = qualify(&entry.id, &detail.id);
        let own_progress = rows
            .iter()
            .find(|(_, row)| row.item_id == own_id)
            .map(|(_, row)| row.progress)
            .unwrap_or(0.0);
        rows.retain(|(_, row)| row.source_id != entry.id);

        let priority = self
            .entries
            .iter()
            .position(|e| e.id == entry.id)
            .unwrap_or(0);
        rows.push((
            priority,
            ItemSource {
                item_id: own_id,
                source_id: entry.id.clone(),
                source_name: entry.source.name().to_string(),
                resolution: detail.resolution.clone(),
                progress: own_progress,
            },
        ));

        rows.sort_by(|a, b| {
            let a_watched = a.1.progress > 0.0;
            let b_watched = b.1.progress > 0.0;
            b_watched
                .cmp(&a_watched)
                .then(a.0.cmp(&b.0))
                .then(resolution_rank(&b.1.resolution).cmp(&resolution_rank(&a.1.resolution)))
        });

        Ok(rows.into_iter().map(|(_, row)| row).collect())
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

        // 和列表/搜索一样把 id、parent_id、海报都加源前缀：壳点「演员作品」时
        // 直接把这个 id 交给 detail()，没有前缀会在路由处报「缺少源前缀」。
        qualify_items(&entry.id, &mut items);

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

    /// 播放结束 / 关窗：给服务端一次「停了」的信号（Emby 靠它落 UserData）。
    pub fn report_stopped(&self, item_id: &str, position: i64, duration: i64) -> Result<()> {
        let (entry, raw) = self.route(item_id)?;
        entry.source.report_stopped(raw, position, duration)
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
                // 续播要拿 parent_id 去列选集：不加前缀核心不认，壳侧还得自己补。
                record.parent_id = qualify_opt(&entry.id, record.parent_id);
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

// —— 搜索结果去重 ——

/// 一次搜索里，同一个源给的一条候选。
struct Candidate {
    item: MediaItem,
    source_id: String,
    source_name: String,
    /// 源在配置里的顺序，小的优先。
    priority: usize,
}

/// 去重键：标题归一 + 年份 + 类型 + 剧集数。
struct GroupKey {
    title: String,
    year: Option<i32>,
    kind: MediaKind,
    episodes: Option<i32>,
}

impl GroupKey {
    fn of(item: &MediaItem) -> Self {
        Self {
            title: crate::text::normalize_key(&item.title),
            year: item.year,
            kind: group_kind(item.kind),
            episodes: item.episode_count.or(item.local_episode_count),
        }
    }

    /// 年份 / 集数只有两边都给了且不同才算不同片；缺一边就按同一部合并。
    fn matches(&self, other: &Self) -> bool {
        self.title == other.title
            && self.kind == other.kind
            && compatible(self.year, other.year)
            && compatible(self.episodes, other.episodes)
    }

    /// 作为「组键」比较时用：缺的一边先用候选补齐，再判断。
    /// 以前年份缺失等于永远匹配，先到的无年份条目会把同名的不同年份电影全吞进来；
    /// 补齐后，后面遇到明确不同年份的片子会新开一组。
    ///
    /// 判完才写回：`position(|g| g.key.absorb(&key))` 会对沿途每个分组都试一遍，
    /// 失败也把候选的年份/集数留在组键上，后面本该合并的条目就会新开一组（结果重复）。
    fn absorb(&mut self, other: &Self) -> bool {
        if self.title != other.title || self.kind != other.kind {
            return false;
        }

        let year = if self.year.is_none() { other.year } else { self.year };
        if !compatible(year, other.year) {
            return false;
        }

        let episodes = if self.episodes.is_none() {
            other.episodes
        } else {
            self.episodes
        };
        if !compatible(episodes, other.episodes) {
            return false;
        }

        self.year = year;
        self.episodes = episodes;
        true
    }
}

fn compatible<T: PartialEq>(a: Option<T>, b: Option<T>) -> bool {
    match (a, b) {
        (Some(x), Some(y)) => x == y,
        _ => true,
    }
}

/// 电影 / 视频文件 / 未知都算「电影」；剧 / 季 / 集都算「剧」。
/// 不同源对同一部片的叫法不一样（Emby 给 Movie，本地文件给 Video），不归一就合不起来。
fn group_kind(kind: MediaKind) -> MediaKind {
    match kind {
        MediaKind::Movie | MediaKind::Video | MediaKind::Unknown => MediaKind::Movie,
        MediaKind::Series | MediaKind::Season | MediaKind::Episode => MediaKind::Series,
        other => other,
    }
}

/// 命中一集时按父级展示成一部剧（搜索页不该出现同一部剧的十几集）。
fn promote_episode(item: &mut MediaItem) {
    if !matches!(item.kind, MediaKind::Episode | MediaKind::Season) {
        return;
    }
    let Some(parent) = item.parent_id.clone() else {
        return;
    };

    item.id = parent;
    if let Some(title) = item.parent_title.take().filter(|t| !t.trim().is_empty()) {
        item.title = title;
    }
    item.kind = MediaKind::Series;
    item.season_number = None;
    item.episode_number = None;
    item.parent_id = None;
}

/// 同一个源给了多条时留哪条：有进度 > 条目层级更靠上（剧 > 季 > 集）>
/// 分辨率更高。都打平就保留先到的那条（服务器返回的顺序）。
fn preferred(candidate: &Candidate, existing: &Candidate) -> bool {
    let candidate_watched = candidate.item.progress > 0.0;
    let existing_watched = existing.item.progress > 0.0;
    if candidate_watched != existing_watched {
        return candidate_watched;
    }

    let candidate_kind = kind_rank(candidate.item.kind);
    let existing_kind = kind_rank(existing.item.kind);
    if candidate_kind != existing_kind {
        return candidate_kind > existing_kind;
    }

    resolution_rank(&candidate.item.resolution) > resolution_rank(&existing.item.resolution)
}

/// 条目层级：剧 / 电影 > 季 > 集 / 视频。同一个源同时给剧和它的季时留剧。
fn kind_rank(kind: MediaKind) -> u8 {
    match kind {
        MediaKind::Series | MediaKind::Movie => 3,
        MediaKind::Season => 2,
        MediaKind::Episode | MediaKind::Video => 1,
        _ => 0,
    }
}

/// 分辨率粗排：4K > 1440p > 1080p > 720p。
fn resolution_rank(resolution: &Option<String>) -> u8 {
    let Some(text) = resolution else {
        return 0;
    };
    let lower = text.to_lowercase();
    if lower.contains("4320") || lower.contains("8k") {
        5
    } else if lower.contains("2160") || lower.contains("4k") {
        4
    } else if lower.contains("1440") {
        3
    } else if lower.contains("1080") {
        2
    } else if lower.contains("720") {
        1
    } else {
        0
    }
}

/// 同一部片的所有来源，第一条是主条目。
struct Group {
    key: GroupKey,
    candidates: Vec<Candidate>,
}

impl Group {
    fn new(key: GroupKey, candidate: Candidate) -> Self {
        Self {
            key,
            candidates: vec![candidate],
        }
    }

    fn push(&mut self, candidate: Candidate) {
        // 同一个源可能把同一部片给了多次：飞牛的搜索会同时返回剧和它的季
        // （两条 id 不同，标题 / 年份 / 集数都一样）。一个源只能算一个来源，
        // 否则界面会显示「2 源」，资源列表里同一个服务器出现两次。
        if let Some(existing) = self
            .candidates
            .iter_mut()
            .find(|existing| existing.source_id == candidate.source_id)
        {
            if preferred(&candidate, existing) {
                *existing = candidate;
            }
            return;
        }

        self.candidates.push(candidate);
    }

    fn sort(&mut self) {
        self.candidates.sort_by(|a, b| {
            let a_watched = a.item.progress > 0.0;
            let b_watched = b.item.progress > 0.0;
            b_watched
                .cmp(&a_watched)
                .then(a.priority.cmp(&b.priority))
                .then(
                    resolution_rank(&b.item.resolution)
                        .cmp(&resolution_rank(&a.item.resolution)),
                )
        });
    }

    fn has_progress(&self) -> bool {
        self.candidates.iter().any(|c| c.item.progress > 0.0)
    }

    fn finish(mut self) -> MediaItem {
        let primary = self.candidates.remove(0);
        let sources = std::iter::once(&primary)
            .chain(self.candidates.iter())
            .map(|candidate| ItemSource {
                item_id: candidate.item.id.clone(),
                source_id: candidate.source_id.clone(),
                source_name: candidate.source_name.clone(),
                resolution: candidate.item.resolution.clone(),
                progress: candidate.item.progress,
            })
            .collect();

        let mut item = primary.item;
        item.sources = sources;
        item
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(title: &str, year: Option<i32>, episodes: Option<i32>) -> GroupKey {
        GroupKey {
            title: crate::text::normalize_key(title),
            year,
            kind: MediaKind::Series,
            episodes,
        }
    }

    #[test]
    fn absorb_does_not_pollute_group_on_failed_match() {
        // 组里已有「10 集」，候选是另一个年份、12 集：不该合并。
        let mut group = key("running man", None, Some(10));
        let candidate = key("running man", Some(2023), Some(12));
        assert!(!group.absorb(&candidate));

        // 上次失败不能把 2023 留在组键上：同一年、10 集的条目仍应合并。
        let later = key("running man", Some(2023), Some(10));
        assert!(group.absorb(&later));
        assert_eq!(group.year, Some(2023));
        assert_eq!(group.episodes, Some(10));
    }

    #[test]
    fn absorb_keeps_conflicting_year_apart() {
        let mut group = key("same name", Some(2023), None);
        assert!(!group.absorb(&key("same name", Some(2024), None)));
        assert_eq!(group.year, Some(2023));
    }

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
        hits: Vec<MediaItem>,
        fail_search: bool,
    }

    impl Mock {
        fn boxed(tag: &'static str) -> Box<dyn MediaSource> {
            Box::new(Self {
                tag,
                hits: Vec::new(),
                fail_search: false,
            })
        }

        fn with_hits(tag: &'static str, hits: Vec<MediaItem>) -> Box<dyn MediaSource> {
            Box::new(Self {
                tag,
                hits,
                fail_search: false,
            })
        }

        fn failing(tag: &'static str) -> Box<dyn MediaSource> {
            Box::new(Self {
                tag,
                hits: Vec::new(),
                fail_search: true,
            })
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
            if self.fail_search {
                return Err(MediaError::Other("搜索接口 500".into()));
            }
            Ok(self.hits.clone())
        }

        fn detail(&self, item_id: &str) -> Result<MediaDetail> {
            // 有 hit 时按 hit 的字段回，方便测「详情 → 资源列表」这条链路。
            let hit = self.hits.iter().find(|hit| hit.id == item_id);
            Ok(MediaDetail {
                id: item_id.to_string(),
                title: hit
                    .map(|hit| hit.title.clone())
                    .unwrap_or_else(|| format!("{}-{item_id}", self.tag)),
                kind: hit
                    .map(|hit| hit.kind)
                    .unwrap_or(crate::models::MediaKind::Series),
                episode_count: hit.and_then(|hit| hit.episode_count),
                local_episode_count: hit.and_then(|hit| hit.local_episode_count),
                resolution: hit.and_then(|hit| hit.resolution.clone()),
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
                status: None,
                audio_type: None,
                color_range: None,
                play_item_id: Some("3".into()),
                single_child_id: None,
                is_favorite: None,
                is_watched: None,
                tmdb_id: None,
                imdb_id: None,
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
                parent_id: None,
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
                disc: false,
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
                proxy: String::new(),
            })
        }

        fn image_source(&self, path: &str) -> Result<ImageSource> {
            Ok(ImageSource {
                url: format!("http://{}{path}", self.tag),
                headers: Vec::new(),
                proxy: String::new(),
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
                sources: Vec::new(),
            }
        }
    }

    fn hit(
        tag: &str,
        id: &str,
        title: &str,
        kind: crate::models::MediaKind,
        year: Option<i32>,
        progress: f64,
    ) -> MediaItem {
        MediaItem {
            id: id.to_string(),
            title: title.to_string(),
            kind,
            source_id: tag.to_string(),
            poster_path: None,
            parent_id: None,
            parent_title: None,
            year,
            runtime_seconds: None,
            progress,
            is_favorite: false,
            overview: None,
            resolution: Some("1080p".into()),
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
            sources: Vec::new(),
        }
    }

    fn hub_with(
        a: Vec<MediaItem>,
        b: Vec<MediaItem>,
    ) -> MediaHub {
        let mut hub = MediaHub::new();
        hub.add_source("a", Mock::with_hits("a", a)).unwrap();
        hub.add_source("b", Mock::with_hits("b", b)).unwrap();
        hub
    }

    #[test]
    fn search_merges_the_same_movie_across_sources() {
        let hub = hub_with(
            vec![hit("a", "1", "Some Movie", crate::models::MediaKind::Movie, Some(2023), 0.0)],
            vec![hit("b", "2", "some.movie.2023.2160p", crate::models::MediaKind::Movie, Some(2023), 0.0)],
        );

        let result = hub.search("some").unwrap();
        assert_eq!(result.items.len(), 1);
        let item = &result.items[0];
        // 源顺序在前的是主条目。
        assert_eq!(item.id, "a:1");
        assert_eq!(item.sources.len(), 2);
        assert_eq!(item.sources[0].item_id, "a:1");
        assert_eq!(item.sources[1].item_id, "b:2");
        assert_eq!(item.sources[1].source_name, "b");
    }

    #[test]
    fn search_prefers_the_source_with_progress() {
        let hub = hub_with(
            vec![hit("a", "1", "Some Movie", crate::models::MediaKind::Movie, Some(2023), 0.0)],
            vec![hit("b", "2", "Some Movie", crate::models::MediaKind::Movie, Some(2023), 0.5)],
        );

        let result = hub.search("some").unwrap();
        assert_eq!(result.items[0].id, "b:2");
        assert_eq!(result.items[0].sources[0].source_id, "b");
        assert_eq!(result.items[0].sources[1].source_id, "a");
    }

    #[test]
    fn search_keeps_different_years_apart() {
        let hub = hub_with(
            vec![hit("a", "1", "Some Movie", crate::models::MediaKind::Movie, Some(2023), 0.0)],
            vec![hit("b", "2", "Some Movie", crate::models::MediaKind::Movie, Some(2024), 0.0)],
        );

        assert_eq!(hub.search("some").unwrap().items.len(), 2);
    }

    #[test]
    fn search_promotes_episodes_to_their_series() {
        let mut episode = hit(
            "a",
            "e1",
            "第 3 集",
            crate::models::MediaKind::Episode,
            None,
            0.0,
        );
        episode.parent_id = Some("show-1".into());
        episode.parent_title = Some("某部剧".into());

        let mut other = hit(
            "b",
            "s-9",
            "某部剧",
            crate::models::MediaKind::Series,
            None,
            0.0,
        );
        other.episode_count = Some(24);

        let hub = hub_with(vec![episode], vec![other]);
        let result = hub.search("某部剧").unwrap();

        assert_eq!(result.items.len(), 1);
        assert_eq!(result.items[0].id, "a:show-1");
        assert_eq!(result.items[0].kind, crate::models::MediaKind::Series);
        assert_eq!(result.items[0].sources.len(), 2);
    }

    #[test]
    fn search_counts_one_source_once_when_it_returns_series_and_its_season() {
        // 飞牛搜索「赘婿无双」会同时给剧和它的季：两条 id 不同、标题和集数一样。
        let mut series = hit(
            "a",
            "s1",
            "赘婿无双",
            crate::models::MediaKind::Series,
            Some(2023),
            0.0,
        );
        series.local_episode_count = Some(69);
        let mut season = hit(
            "a",
            "s2",
            "赘婿无双",
            crate::models::MediaKind::Season,
            None,
            0.0,
        );
        season.local_episode_count = Some(69);

        // 季先到也一样：同一个源只能留一条，而且留剧而不是季。
        let hub = hub_with(vec![season, series], vec![]);
        let result = hub.search("赘婿无双").unwrap();

        assert_eq!(result.items.len(), 1);
        let item = &result.items[0];
        assert_eq!(item.kind, crate::models::MediaKind::Series);
        assert_eq!(item.sources.len(), 1);
        assert_eq!(item.sources[0].item_id, "a:s1");
        assert_eq!(item.sources[0].source_name, "a");
    }

    #[test]
    fn item_sources_has_one_row_per_source() {
        let mut series = hit(
            "a",
            "s1",
            "赘婿无双",
            crate::models::MediaKind::Series,
            Some(2023),
            0.0,
        );
        series.local_episode_count = Some(69);
        let mut season = hit(
            "a",
            "s2",
            "赘婿无双",
            crate::models::MediaKind::Season,
            None,
            0.0,
        );
        season.local_episode_count = Some(69);

        let hub = hub_with(vec![series, season], vec![]);
        let rows = hub.item_sources("a:s1").unwrap();

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].item_id, "a:s1");
        assert_eq!(rows[0].source_id, "a");
    }

    #[test]
    fn item_sources_lists_the_same_movie_on_every_source() {
        let hub = hub_with(
            vec![hit("a", "1", "Some Movie", crate::models::MediaKind::Movie, Some(2023), 0.0)],
            vec![hit("b", "2", "some.movie.2023.2160p", crate::models::MediaKind::Movie, Some(2023), 0.0)],
        );

        let rows = hub.item_sources("a:1").unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].item_id, "a:1");
        assert_eq!(rows[1].item_id, "b:2");
        assert_eq!(rows[1].source_name, "b");
    }

    #[test]
    fn item_sources_still_has_the_entry_when_search_misses_it() {
        let hub = hub_with(
            vec![hit("a", "1", "Some Movie", crate::models::MediaKind::Movie, Some(2023), 0.0)],
            vec![hit("b", "2", "Other Movie", crate::models::MediaKind::Movie, Some(2024), 0.0)],
        );

        let rows = hub.item_sources("a:1").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].item_id, "a:1");
    }

    #[test]
    fn item_sources_skips_a_single_episode() {
        let hub = hub_with(
            vec![hit("a", "e1", "第 3 集", crate::models::MediaKind::Episode, None, 0.0)],
            Vec::new(),
        );

        assert!(hub.item_sources("a:e1").unwrap().is_empty());
    }

    #[test]
    fn search_reports_failed_sources_without_dropping_the_rest() {
        let mut hub = MediaHub::new();
        hub.add_source("a", Mock::with_hits("a", vec![hit(
            "a",
            "1",
            "Some Movie",
            crate::models::MediaKind::Movie,
            Some(2023),
            0.0,
        )]))
        .unwrap();
        hub.add_source("b", Mock::failing("b")).unwrap();

        let result = hub.search("some").unwrap();
        assert_eq!(result.items.len(), 1);
        assert_eq!(result.failed.len(), 1);
        assert_eq!(result.failed[0].source_id, "b");
        assert!(result.failed[0].error.contains("500"));
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
