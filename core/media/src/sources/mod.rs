//! 媒体源适配器。
//!
//! 每个服务器（飞牛、Emby、Jellyfin…）实现 [`MediaSource`]，对外只暴露一套模型
//! （见 `crate::models`）。上层的界面、播放器、聚合逻辑都只认这套模型，
//! 换服务器不用改界面。

pub mod emby;
pub mod fnos;
pub mod local;

pub use emby::EmbySource;
pub use fnos::FnOsSource;
pub use local::LocalSource;

use serde::{Deserialize, Serialize};

use crate::error::{MediaError, Result};
use crate::models::{
    Genre, ImageSource, ListQuery, MediaDetail, MediaInfo, MediaItem, MediaLibrary, Paged,
    Person, PlayRecord, PlaySource,
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
    /// 本地源的进度 / 缓存放这里（两端传 Application Support 目录）。
    #[serde(default)]
    pub data_dir: String,
    /// 网络服务器的 HTTP 代理，例如 `http://127.0.0.1:7890`；空表示直连。
    /// 这个源的接口、海报下载和播放请求都走它。
    #[serde(default)]
    pub proxy: String,
}

/// 当前实现的适配器类型。界面的「添加源」下拉框直接用它。
pub const SUPPORTED_KINDS: &[&str] = &["fnos", "emby", "jellyfin", "local"];

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

    /// 收藏 / 取消收藏。不支持这个概念的源返回错误。
    fn set_favorite(&self, _item_id: &str, _favorite: bool) -> Result<()> {
        Err(MediaError::Other("这个服务器不支持收藏".into()))
    }

    /// 收藏列表。没有收藏概念的源返回空页。
    fn favorites(&self, page: i32, page_size: i32) -> Result<Paged<MediaItem>> {
        Ok(Paged::empty(page, page_size))
    }

    /// 标记已观看 / 未观看。
    fn set_watched(&self, _item_id: &str, _watched: bool) -> Result<()> {
        Err(MediaError::Other("这个服务器不支持标记观看状态".into()))
    }

    /// 移除观看记录（从「继续观看」里清掉，不影响已看标记）。
    fn remove_play_record(&self, _item_id: &str) -> Result<()> {
        Err(MediaError::Other("这个服务器不支持移除观看记录".into()))
    }

    /// 条目详情：背景图、简介、季集数等列表接口没有的信息。
    fn detail(&self, item_id: &str) -> Result<MediaDetail>;

    /// 继续观看列表，按最近播放排序。
    fn records(&self) -> Result<Vec<PlayRecord>>;

    /// 上报进度（秒）。
    fn report_progress(&self, item_id: &str, position: i64, duration: i64) -> Result<()>;

    /// 取播放源：直链、请求头、续播点、轨道。
    fn play_source(&self, item_id: &str) -> Result<PlaySource>;

    /// 某个演职员参与过的作品。
    fn person_works(&self, _person_id: &str) -> Result<Vec<MediaItem>> {
        Ok(Vec::new())
    }

    /// 演职人员（演员 / 导演 / 编剧）。没有这个概念就返回空列表。
    fn people(&self, _item_id: &str) -> Result<Vec<Person>> {
        Ok(Vec::new())
    }

    /// 详情页「媒体信息」：编码、分辨率、比特率、音轨明细。
    ///
    /// 拿不到就返回错误，界面把这一块整段藏起来——宁可没有，也不要一排空行。
    fn media_info(&self, _item_id: &str) -> Result<MediaInfo> {
        Err(MediaError::Other("这个服务器不支持媒体信息".into()))
    }

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
            config.proxy.clone(),
        ))),
        "emby" | "jellyfin" => Some(Box::new(EmbySource::new(
            config.id.clone(),
            config.name.clone(),
            if kind == "jellyfin" { "Jellyfin" } else { "Emby" }.to_string(),
            config.base.clone(),
            config.username.clone(),
            config.password.clone(),
            config.proxy.clone(),
        ))),
        "local" | "folder" => Some(Box::new(LocalSource::new(
            config.id.clone(),
            config.name.clone(),
            config.base.clone(),
            config.data_dir.clone(),
        ))),
        _ => None,
    }
}

/// 统一构造 HTTP 客户端：设了代理的服务器，接口请求全走代理。
pub(crate) fn http_client(proxy: &str) -> reqwest::blocking::Client {
    let mut builder =
        reqwest::blocking::Client::builder().timeout(std::time::Duration::from_secs(30));
    if let Some(proxy) = normalize_proxy(proxy) {
        match reqwest::Proxy::all(&proxy) {
            Ok(configured) => builder = builder.proxy(configured),
            Err(err) => {
                // 代理写错不拦着直连：至少还能用，设置页会照原样存着。
                eprintln!("代理地址无效，已忽略：{proxy}（{err}）");
            }
        }
    }

    builder
        .build()
        .unwrap_or_else(|_| reqwest::blocking::Client::new())
}

/// 代理地址允许只写 `127.0.0.1:7890`，补成 `http://`。
pub(crate) fn normalize_proxy(raw: &str) -> Option<String> {
    let value = raw.trim();
    if value.is_empty() {
        return None;
    }

    Some(if value.contains("://") {
        value.to_string()
    } else {
        format!("http://{value}")
    })
}

// —— 条目标签的中文化 ——
//
// 服务器给的是英文职位和 ISO 639 语言代码，界面统一显示中文；
// 认不出来的原样返回，别把有用信息吞掉。

/// `Actor` / `Director` … → 演员 / 导演 / 编剧。
pub(crate) fn job_label(raw: &str) -> Option<String> {
    let value = raw.trim();
    if value.is_empty() {
        return None;
    }

    let label = match value.to_ascii_lowercase().as_str() {
        "actor" | "actress" | "cast" => "演员",
        "director" | "directing" => "导演",
        "writer" | "screenplay" | "writing" => "编剧",
        "producer" | "production" => "制片",
        "gueststar" => "客串",
        "composer" | "sound" => "音乐",
        "editor" | "editing" => "剪辑",
        "camera" | "cinematography" => "摄影",
        _ => return Some(value.to_string()),
    };

    Some(label.into())
}

/// `chi` / `eng` / `jpn` … → 中文 / 英语 / 日语；`und` 视为没识别出来。
pub(crate) fn language_label(raw: &str) -> Option<String> {
    let value = raw.trim();
    if value.is_empty() {
        return None;
    }

    let label = match value.to_ascii_lowercase().as_str() {
        "und" | "unknown" | "unk" => return None,
        "chi" | "zho" | "zh" | "chs" | "cht" => "中文",
        "eng" | "en" => "英语",
        "jpn" | "ja" => "日语",
        "kor" | "ko" => "韩语",
        "fra" | "fre" | "fr" => "法语",
        "deu" | "ger" | "de" => "德语",
        "spa" | "es" => "西班牙语",
        "rus" | "ru" => "俄语",
        "ita" | "it" => "意大利语",
        "por" | "pt" => "葡萄牙语",
        "tha" | "th" => "泰语",
        "hin" | "hi" => "印地语",
        "ara" | "ar" => "阿拉伯语",
        "cmn" => "中文",
        _ => return Some(value.to_string()),
    };

    Some(label.into())
}

// —— ffprobe 风格字段的宽松读取 ——
//
// 各家服务器的流信息字段名和类型都不统一（`bit_rate` 有时是数字有时是字符串，
// 帧率有 `frame_rate` / `avg_frame_rate` 两种写法），这里按候选键名挨个试，
// 类型对不上就跳过，交给界面显示「没有这一项」。

/// 取第一个非空的字符串字段；数字转成字符串。
pub(crate) fn pick_str(v: &serde_json::Value, keys: &[&str]) -> Option<String> {
    keys.iter().filter_map(|k| v.get(*k)).find_map(|value| match value {
        serde_json::Value::String(s) => {
            let trimmed = s.trim();
            if trimmed.is_empty() || trimmed == "0" {
                None
            } else {
                Some(trimmed.to_string())
            }
        }
        serde_json::Value::Number(n) => Some(n.to_string()),
        _ => None,
    })
}

pub(crate) fn pick_i64(v: &serde_json::Value, keys: &[&str]) -> Option<i64> {
    keys.iter().filter_map(|k| v.get(*k)).find_map(|value| match value {
        serde_json::Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        serde_json::Value::String(s) => s.trim().parse::<i64>().ok(),
        _ => None,
    })
}

pub(crate) fn pick_i32(v: &serde_json::Value, keys: &[&str]) -> Option<i32> {
    pick_i64(v, keys).and_then(|n| i32::try_from(n).ok()).filter(|n| *n > 0)
}

pub(crate) fn pick_f64(v: &serde_json::Value, keys: &[&str]) -> Option<f64> {
    keys.iter().filter_map(|k| v.get(*k)).find_map(|value| match value {
        serde_json::Value::Number(n) => n.as_f64(),
        serde_json::Value::String(s) => parse_rate(s),
        _ => None,
    })
}

/// `"30000/1001"`、`"29.97"` 都能认。
pub(crate) fn parse_rate(raw: &str) -> Option<f64> {
    let raw = raw.trim();
    // 飞牛写成 `"30 fps"`，Emby 是纯数字。
    let raw = raw
        .strip_suffix("fps")
        .or_else(|| raw.strip_suffix("FPS"))
        .unwrap_or(raw)
        .trim();
    if raw.is_empty() || raw == "0" || raw == "0/0" {
        return None;
    }

    match raw.split_once('/') {
        Some((num, den)) => {
            let num: f64 = num.trim().parse().ok()?;
            let den: f64 = den.trim().parse().ok()?;
            (den != 0.0).then_some(num / den)
        }
        None => raw.parse().ok(),
    }
}

pub(crate) fn pick_bool(v: &serde_json::Value, keys: &[&str]) -> Option<bool> {
    keys.iter().filter_map(|k| v.get(*k)).find_map(|value| match value {
        serde_json::Value::Bool(b) => Some(*b),
        serde_json::Value::Number(n) => Some(n.as_i64().unwrap_or(0) != 0),
        serde_json::Value::String(s) => match s.trim().to_ascii_lowercase().as_str() {
            "" => None,
            "0" | "false" | "no" | "progressive" => Some(false),
            _ => Some(true),
        },
        _ => None,
    })
}

#[cfg(test)]
mod proxy_tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    #[test]
    fn normalizes_proxy_address() {
        assert_eq!(normalize_proxy(""), None);
        assert_eq!(normalize_proxy("   "), None);
        assert_eq!(
            normalize_proxy("127.0.0.1:7890").as_deref(),
            Some("http://127.0.0.1:7890")
        );
        assert_eq!(
            normalize_proxy("http://10.0.0.2:8080").as_deref(),
            Some("http://10.0.0.2:8080")
        );
    }

    #[test]
    fn http_client_sends_requests_through_proxy() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(std::time::Duration::from_secs(10)))
                .unwrap();
            let mut buf = [0u8; 2048];
            let n = socket.read(&mut buf).unwrap();
            let text = String::from_utf8_lossy(&buf[..n]).to_string();
            let _ = socket.write_all(
                b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            );
            text
        });

        let client = http_client(&format!("127.0.0.1:{port}"));
        let _ = client.get("http://media.invalid/probe").send();

        let request = handle.join().unwrap();
        assert!(
            request.starts_with("GET http://media.invalid/probe "),
            "代理没有收到绝对地址请求：{request}"
        );
    }
}
