//! C ABI：各端（C# / Swift / Kotlin）通过它调用共享核心。
//!
//! 约定：
//! - 所有返回 `*mut c_char` 的函数返回 UTF-8 JSON，调用方负责 `dv_string_free`；
//! - 所有指针参数可以为空（返回 ok=false 的 JSON，而不是崩溃）；
//! - 统一响应 `{"ok":true,"data":...}` / `{"ok":false,"error":"..."}`。

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use serde::de::DeserializeOwned;
use serde::Serialize;

use crate::error::MediaError;
use crate::hub::MediaHub;
use crate::models::{
    Person,
    MediaInfo,
    Envelope, Genre, ImageSource, ItemSource, ListQuery, MediaDetail, MediaItem, MediaLibrary,
    Paged, PlayRecord, PlaySource,
};
use crate::sources::{self, MediaSource, SourceConfig};

/// 句柄持有一个多态媒体源。具体是飞牛还是 Emby 由 `kind` 决定，
/// 上层（C# / Swift / Kotlin）看到的接口完全一样。
pub struct SourceHandle {
    inner: Box<dyn MediaSource>,
}

fn read_cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(|s| s.to_string())
}

fn write_json<T: Serialize>(value: &Envelope<T>) -> *mut c_char {
    let text = serde_json::to_string(value).unwrap_or_else(|_| {
        r#"{"ok":false,"error":"serialize failed"}"#.to_string()
    });
    CString::new(text)
        .map(|c| c.into_raw())
        .unwrap_or(ptr::null_mut())
}

fn reply<T: Serialize>(result: Result<T, MediaError>) -> *mut c_char {
    let envelope = match result {
        Ok(data) => Envelope::ok(data),
        Err(MediaError::Api { code, msg }) => Envelope::err(msg, Some(code)),
        Err(err) => Envelope::err(err.to_string(), None),
    };
    write_json(&envelope)
}

fn guard<F>(f: F) -> *mut c_char
where
    F: FnOnce() -> *mut c_char,
{
    catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|_| {
        let envelope: Envelope<()> = Envelope::err("rust panic", None);
        write_json(&envelope)
    })
}

/// 支持的适配器类型，返回 `["fnos"]`。界面用它填「添加源」的下拉框。
#[no_mangle]
pub extern "C" fn dv_source_kinds() -> *mut c_char {
    guard(|| reply(Ok(sources::SUPPORTED_KINDS)))
}

/// 创建源。config 是 JSON：
/// {"id":"fnos-1","name":"飞牛影视","kind":"fnos","base":"http://host:8005","username":"","password":""}
///
/// `kind` 不认识时返回空指针（调用方按「不支持的类型」提示）。
#[no_mangle]
pub extern "C" fn dv_source_create(config: *const c_char) -> *mut SourceHandle {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(json) = read_cstr(config) else {
            return ptr::null_mut();
        };

        let Ok(parsed) = serde_json::from_str::<SourceConfig>(&json) else {
            return ptr::null_mut();
        };

        let Some(source) = sources::create(&parsed) else {
            return ptr::null_mut();
        };

        Box::into_raw(Box::new(SourceHandle { inner: source }))
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn dv_source_free(handle: *mut SourceHandle) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

#[no_mangle]
pub extern "C" fn dv_string_free(text: *mut c_char) {
    if !text.is_null() {
        unsafe {
            drop(CString::from_raw(text));
        }
    }
}

/// 登录。成功返回 {"ok":true,"data":{"name":"..."}}。
#[no_mangle]
pub extern "C" fn dv_connect(handle: *mut SourceHandle) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_mut() }) else {
            return reply::<()>(Err(MediaError::Other("null handle".into())));
        };

        match h.inner.login() {
            Ok(()) => reply(Ok(serde_json::json!({
                "name": h.inner.name(),
                "kind": h.inner.kind(),
            }))),
            Err(e) => reply::<()>(Err(e)),
        }
    })
}

#[no_mangle]
pub extern "C" fn dv_libraries(handle: *mut SourceHandle) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_mut() }) else {
            return reply::<Vec<MediaLibrary>>(Err(MediaError::Other("null handle".into())));
        };
        reply(h.inner.libraries())
    })
}

#[no_mangle]
pub extern "C" fn dv_items(
    handle: *mut SourceHandle,
    library_id: *const c_char,
    page: i32,
    page_size: i32,
    query: *const c_char,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_mut() }) else {
            return reply::<Paged<MediaItem>>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(library_id) else {
            return reply::<Paged<MediaItem>>(Err(MediaError::Other("null library id".into())));
        };
        let opts = read_query(query);
        reply(h.inner.items(&id, page, page_size, &opts))
    })
}

#[no_mangle]
pub extern "C" fn dv_children(
    handle: *mut SourceHandle,
    parent_id: *const c_char,
    page: i32,
    page_size: i32,
    query: *const c_char,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_mut() }) else {
            return reply::<Paged<MediaItem>>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(parent_id) else {
            return reply::<Paged<MediaItem>>(Err(MediaError::Other("null parent id".into())));
        };
        let opts = read_query(query);
        reply(h.inner.children(&id, page, page_size, &opts))
    })
}

#[no_mangle]
pub extern "C" fn dv_records(handle: *mut SourceHandle) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_mut() }) else {
            return reply::<Vec<PlayRecord>>(Err(MediaError::Other("null handle".into())));
        };
        reply(h.inner.records())
    })
}

#[no_mangle]
pub extern "C" fn dv_report_progress(
    handle: *mut SourceHandle,
    item_id: *const c_char,
    position: i64,
    duration: i64,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_mut() }) else {
            return reply::<()>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(item_id) else {
            return reply::<()>(Err(MediaError::Other("null item id".into())));
        };
        reply(h.inner.report_progress(&id, position, duration))
    })
}

#[no_mangle]
pub extern "C" fn dv_report_stopped(
    handle: *mut SourceHandle,
    item_id: *const c_char,
    position: i64,
    duration: i64,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_mut() }) else {
            return reply::<()>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(item_id) else {
            return reply::<()>(Err(MediaError::Other("null item id".into())));
        };
        reply(h.inner.report_stopped(&id, position, duration))
    })
}

/// 判定 Dolby Vision P7 是 FEL 还是 MEL。
///
/// `url` 是播放直链（http(s)）或本地路径；`headers_json` 是
/// `[{"name":..,"value":..}]`，网络源带上鉴权头；`proxy` 是用户设的 HTTP 代理。
/// 只读码流前缀（8 MB），找到 RPU 就返回，找不到返回 ok=false。
#[no_mangle]
pub extern "C" fn dv_probe_dovi(
    url: *const c_char,
    headers_json: *const c_char,
    proxy: *const c_char,
) -> *mut c_char {
    guard(|| {
        let Some(url) = read_cstr(url) else {
            return reply::<crate::dovi::DoviInfo>(Err(MediaError::Other("null url".into())));
        };
        let headers: Vec<crate::models::HttpHeader> = read_cstr(headers_json)
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        let proxy = read_cstr(proxy).unwrap_or_default();

        reply(crate::dovi::probe(&url, &headers, &proxy))
    })
}

/// 条目详情：背景图、简介、季集数、播放入口。
#[no_mangle]
pub extern "C" fn dv_item_detail(handle: *mut SourceHandle, item_id: *const c_char) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_mut() }) else {
            return reply::<MediaDetail>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(item_id) else {
            return reply::<MediaDetail>(Err(MediaError::Other("null item id".into())));
        };
        reply(h.inner.detail(&id))
    })
}

/// 取播放源：直链 + 必须的请求头 + 续播点 + 音轨/字幕轨。
#[no_mangle]
pub extern "C" fn dv_play_source(handle: *mut SourceHandle, item_id: *const c_char) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_mut() }) else {
            return reply::<PlaySource>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(item_id) else {
            return reply::<PlaySource>(Err(MediaError::Other("null item id".into())));
        };
        reply(h.inner.play_source(&id))
    })
}

/// 图片（海报）地址与鉴权头。
#[no_mangle]
pub extern "C" fn dv_image_source(handle: *mut SourceHandle, path: *const c_char) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_mut() }) else {
            return reply::<ImageSource>(Err(MediaError::Other("null handle".into())));
        };
        let Some(p) = read_cstr(path) else {
            return reply::<ImageSource>(Err(MediaError::Other("null image path".into())));
        };
        reply(h.inner.image_source(&p))
    })
}

// —— 聚合层（多源合并）——
//
// 界面只跟 hub 打交道：id 都是 `<sourceId>:<itemId>`，图片路径同理。
// 读写函数都用 `*const`：海报是并发加载的，不能同时造出多个 `&mut`。

/// 聚合句柄：持有 0..N 个已登录的媒体源。
pub struct HubHandle {
    inner: MediaHub,
}

/// 新建一个空的聚合句柄（还没有源）。
#[no_mangle]
pub extern "C" fn dv_hub_new() -> *mut HubHandle {
    catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(HubHandle {
            inner: MediaHub::new(),
        }))
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn dv_hub_free(handle: *mut HubHandle) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

/// 添加并登录一个源。config 同 `dv_source_create`。
///
/// 单个源失败不影响已经加进来的源；调用方按返回值决定提示。
#[no_mangle]
pub extern "C" fn dv_hub_add(handle: *mut HubHandle, config: *const c_char) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_mut() }) else {
            return reply::<()>(Err(MediaError::Other("null handle".into())));
        };

        let Some(json) = read_cstr(config) else {
            return reply::<()>(Err(MediaError::Other("null config".into())));
        };

        let parsed: SourceConfig = match serde_json::from_str(&json) {
            Ok(parsed) => parsed,
            Err(err) => {
                return reply::<()>(Err(MediaError::Other(format!("config 解析失败：{err}"))));
            }
        };

        match h.inner.add(&parsed) {
            Ok(()) => reply(Ok(serde_json::json!({
                "id": parsed.id,
                "name": parsed.name,
                "kind": parsed.kind,
            }))),
            Err(err) => reply::<()>(Err(err)),
        }
    })
}

/// 并行添加并登录多个源。config 是 `SourceConfig` 的 JSON 数组。
///
/// 每个源一个线程建连，全部结束后按数组顺序返回结果（`ok` / `error` / `ms`）。
/// 单个源失败不影响其它源。
#[no_mangle]
pub extern "C" fn dv_hub_add_many(handle: *mut HubHandle, configs: *const c_char) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_mut() }) else {
            return reply::<Vec<crate::hub::SourceConnect>>(Err(MediaError::Other(
                "null handle".into(),
            )));
        };

        let Some(json) = read_cstr(configs) else {
            return reply::<Vec<crate::hub::SourceConnect>>(Err(MediaError::Other(
                "null configs".into(),
            )));
        };

        let parsed: Vec<SourceConfig> = match serde_json::from_str(&json) {
            Ok(parsed) => parsed,
            Err(err) => {
                return reply::<Vec<crate::hub::SourceConnect>>(Err(MediaError::Other(
                    format!("configs 解析失败：{err}"),
                )));
            }
        };

        reply(Ok(h.inner.add_many(&parsed)))
    })
}

/// 已连接的源，用于设置页显示状态。
#[no_mangle]
pub extern "C" fn dv_hub_sources(handle: *const HubHandle) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<crate::hub::SourceInfo>(Err(MediaError::Other("null handle".into())));
        };
        reply(Ok(h.inner.sources()))
    })
}

/// 筛选参数是可选 JSON；空指针或解析失败都退回默认值。
fn read_query(ptr: *const c_char) -> ListQuery {
    read_cstr(ptr)
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

#[no_mangle]
pub extern "C" fn dv_hub_libraries(handle: *const HubHandle) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<Vec<MediaLibrary>>(Err(MediaError::Other("null handle".into())));
        };
        reply(h.inner.libraries())
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_items(
    handle: *const HubHandle,
    library_id: *const c_char,
    page: i32,
    page_size: i32,
    query: *const c_char,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<Paged<MediaItem>>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(library_id) else {
            return reply::<Paged<MediaItem>>(Err(MediaError::Other("null library id".into())));
        };
        let opts = read_query(query);
        reply(h.inner.items(&id, page, page_size, &opts))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_search(handle: *const HubHandle, query: *const c_char) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<Vec<MediaItem>>(Err(MediaError::Other("null handle".into())));
        };
        let Some(q) = read_cstr(query) else {
            return reply::<Vec<MediaItem>>(Err(MediaError::Other("null query".into())));
        };
        reply(h.inner.search(&q))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_item_sources(
    handle: *const HubHandle,
    item_id: *const c_char,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<Vec<ItemSource>>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(item_id) else {
            return reply::<Vec<ItemSource>>(Err(MediaError::Other("null item id".into())));
        };
        reply(h.inner.item_sources(&id))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_children(
    handle: *const HubHandle,
    parent_id: *const c_char,
    page: i32,
    page_size: i32,
    query: *const c_char,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<Paged<MediaItem>>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(parent_id) else {
            return reply::<Paged<MediaItem>>(Err(MediaError::Other("null parent id".into())));
        };
        let opts = read_query(query);
        reply(h.inner.children(&id, page, page_size, &opts))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_genres(handle: *const HubHandle, scope_id: *const c_char) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<Vec<Genre>>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(scope_id) else {
            return reply::<Vec<Genre>>(Err(MediaError::Other("null scope id".into())));
        };
        reply(h.inner.genres(&id))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_detail(handle: *const HubHandle, item_id: *const c_char) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<MediaDetail>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(item_id) else {
            return reply::<MediaDetail>(Err(MediaError::Other("null item id".into())));
        };
        reply(h.inner.detail(&id))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_person_works(
    handle: *const HubHandle,
    person_id: *const c_char,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<Vec<MediaItem>>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(person_id) else {
            return reply::<Vec<MediaItem>>(Err(MediaError::Other("null person id".into())));
        };
        reply(h.inner.person_works(&id))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_people(
    handle: *const HubHandle,
    item_id: *const c_char,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<Vec<Person>>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(item_id) else {
            return reply::<Vec<Person>>(Err(MediaError::Other("null item id".into())));
        };
        reply(h.inner.people(&id))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_media_info(
    handle: *const HubHandle,
    item_id: *const c_char,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<MediaInfo>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(item_id) else {
            return reply::<MediaInfo>(Err(MediaError::Other("null item id".into())));
        };
        reply(h.inner.media_info(&id))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_play_source(
    handle: *const HubHandle,
    item_id: *const c_char,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<PlaySource>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(item_id) else {
            return reply::<PlaySource>(Err(MediaError::Other("null item id".into())));
        };
        reply(h.inner.play_source(&id))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_report_progress(
    handle: *const HubHandle,
    item_id: *const c_char,
    position: i64,
    duration: i64,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<()>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(item_id) else {
            return reply::<()>(Err(MediaError::Other("null item id".into())));
        };
        reply(h.inner.report_progress(&id, position, duration))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_report_stopped(
    handle: *const HubHandle,
    item_id: *const c_char,
    position: i64,
    duration: i64,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<()>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(item_id) else {
            return reply::<()>(Err(MediaError::Other("null item id".into())));
        };
        reply(h.inner.report_stopped(&id, position, duration))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_set_favorite(
    handle: *const HubHandle,
    item_id: *const c_char,
    favorite: i32,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<()>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(item_id) else {
            return reply::<()>(Err(MediaError::Other("null item id".into())));
        };
        reply(h.inner.set_favorite(&id, favorite != 0))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_set_watched(
    handle: *const HubHandle,
    item_id: *const c_char,
    watched: i32,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<()>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(item_id) else {
            return reply::<()>(Err(MediaError::Other("null item id".into())));
        };
        reply(h.inner.set_watched(&id, watched != 0))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_remove_record(
    handle: *const HubHandle,
    item_id: *const c_char,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<()>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(item_id) else {
            return reply::<()>(Err(MediaError::Other("null item id".into())));
        };
        reply(h.inner.remove_play_record(&id))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_favorites(
    handle: *const HubHandle,
    page: i32,
    page_size: i32,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<Paged<MediaItem>>(Err(MediaError::Other("null handle".into())));
        };
        reply(h.inner.favorites(page, page_size))
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_records(handle: *const HubHandle) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<Vec<PlayRecord>>(Err(MediaError::Other("null handle".into())));
        };
        reply(h.inner.records())
    })
}

#[no_mangle]
pub extern "C" fn dv_hub_image_source(
    handle: *const HubHandle,
    path: *const c_char,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_ref() }) else {
            return reply::<ImageSource>(Err(MediaError::Other("null handle".into())));
        };
        let Some(p) = read_cstr(path) else {
            return reply::<ImageSource>(Err(MediaError::Other("null image path".into())));
        };
        reply(h.inner.image_source(&p))
    })
}

/// 版本号，便于各端确认加载的是新库。
#[no_mangle]
pub extern "C" fn dv_version() -> *mut c_char {
    write_json(&Envelope::ok(env!("CARGO_PKG_VERSION")))
}

// 让编译器检查反序列化辅助没被误删（各端 DTO 不需要，保留占位）。
#[allow(dead_code)]
fn _assert_deserialize<T: DeserializeOwned>() {}
