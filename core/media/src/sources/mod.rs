//! 媒体源适配器。
//!
//! 每个服务器（飞牛、Emby、Jellyfin…）实现 [`MediaSource`]，对外只暴露一套模型
//! （见 `crate::models`）。上层的界面、播放器、聚合逻辑都只认这套模型，
//! 换服务器不用改界面。

pub mod emby;
pub mod fnos;

pub use emby::EmbySource;
pub use fnos::FnOsSource;

use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::models::{
    Genre, ImageSource, ListQuery, MediaDetail, MediaItem, MediaLibrary, Paged, PlayRecord,
    PlaySource,
};

/// 一个媒体源的连接参数。序列化后就是 `dv_source_create` 的入参。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceConfig {
    pub id: String,
    pub name: String,
    /// 适配器类型，见 [`SUPPORTED_KINDS`]。
    pub kind: String,
    pub base: String,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
}

/// 当前实现的适配器类型。界面的「添加源」下拉框直接用它。
pub const SUPPORTED_KINDS: &[&str] = &["fnos", "emby", "jellyfin"];

/// 媒体源的最小接口。
///
/// 约定：
/// - `login` 负责拿到并保存凭据（token / session key），其它方法都假定已登录；
/// - 所有方法都可能被 UI 线程池并发调用，实现必须是 `Send + Sync`；
/// - 失败用 [`MediaError`](crate::error::MediaError)，不要 panic。
pub trait MediaSource: Send + Sync {
    /// 适配器类型，和 [`SourceConfig::kind`] 一致。
    fn kind(&self) -> &'static str;

    /// 用户在界面上看到的名称。
    fn name(&self) -> &str;

    fn login(&mut self) -> Result<()>;

    fn libraries(&self) -> Result<Vec<MediaLibrary>>;

    /// 媒体库第一层条目。`query` 带筛选与排序，默认值等于「全部、服务器默认顺序」。
    fn items(
        &self,
        library_id: &str,
        page: i32,
        page_size: i32,
        query: &ListQuery,
    ) -> Result<Paged<MediaItem>>;

    /// 某个条目下的子条目（剧集 → 季 → 集）。
    fn children(
        &self,
        parent_id: &str,
        page: i32,
        page_size: i32,
        query: &ListQuery,
    ) -> Result<Paged<MediaItem>>;

    /// 这个库里可用的风格列表。没有概念的源返回空。
    fn genres(&self, _scope_id: &str) -> Result<Vec<Genre>> {
        Ok(Vec::new())
    }

    /// 关键词搜索。返回的是平铺的条目（可能是集/文件），由上层按父级归并。
    fn search(&self, query: &str) -> Result<Vec<MediaItem>>;

    /// 条目详情：背景图、简介、季集数等列表接口没有的信息。
    fn detail(&self, item_id: &str) -> Result<MediaDetail>;

    /// 继续观看列表，按最近播放排序。
    fn records(&self) -> Result<Vec<PlayRecord>>;

    /// 上报进度（秒）。
    fn report_progress(&self, item_id: &str, position: i64, duration: i64) -> Result<()>;

    /// 取播放源：直链、请求头、续播点、轨道。
    fn play_source(&self, item_id: &str) -> Result<PlaySource>;

    /// 取图片地址与鉴权头。
    fn image_source(&self, path: &str) -> Result<ImageSource>;
}

/// 按 `kind` 造一个适配器。新增服务器时只在这里加一个分支。
pub fn create(config: &SourceConfig) -> Option<Box<dyn MediaSource>> {
    let kind = config.kind.trim().to_ascii_lowercase();
    match kind.as_str() {
        "fnos" | "feiniu" => Some(Box::new(FnOsSource::new(
            config.id.clone(),
            config.name.clone(),
            config.base.clone(),
            config.username.clone(),
            config.password.clone(),
        ))),
        "emby" | "jellyfin" => Some(Box::new(EmbySource::new(
            config.id.clone(),
            config.name.clone(),
            config.base.clone(),
            config.username.clone(),
            config.password.clone(),
        ))),
        _ => None,
    }
}
