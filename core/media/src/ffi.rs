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
use crate::models::{Envelope, ImageSource, MediaItem, MediaLibrary, Paged, PlayRecord, PlaySource};
use crate::sources::FnOsSource;

/// 句柄只持有飞牛源；后续 Emby 用同一入口按 `kind` 分发。
pub struct SourceHandle {
    inner: FnOsSource,
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

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct SourceConfig {
    id: String,
    name: String,
    kind: String,
    base: String,
    username: String,
    password: String,
}

/// 创建源。config 是 JSON：
/// {"id":"fnos-1","name":"飞牛影视","kind":"fnos","base":"http://host:8005","username":"","password":""}
#[no_mangle]
pub extern "C" fn dv_source_create(config: *const c_char) -> *mut SourceHandle {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(json) = read_cstr(config) else {
            return ptr::null_mut();
        };

        let parsed: SourceConfig = match serde_json::from_str(&json) {
            Ok(v) => v,
            Err(_) => return ptr::null_mut(),
        };

        if !parsed.kind.eq_ignore_ascii_case("fnos") {
            return ptr::null_mut();
        }

        let source = FnOsSource::new(
            parsed.id,
            parsed.name,
            parsed.base,
            parsed.username,
            parsed.password,
        );

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
            Ok(()) => reply(Ok(serde_json::json!({ "name": h.inner.name }))),
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
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_mut() }) else {
            return reply::<Paged<MediaItem>>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(library_id) else {
            return reply::<Paged<MediaItem>>(Err(MediaError::Other("null library id".into())));
        };
        reply(h.inner.items(&id, page, page_size))
    })
}

#[no_mangle]
pub extern "C" fn dv_children(
    handle: *mut SourceHandle,
    parent_id: *const c_char,
    page: i32,
    page_size: i32,
) -> *mut c_char {
    guard(|| {
        let Some(h) = (unsafe { handle.as_mut() }) else {
            return reply::<Paged<MediaItem>>(Err(MediaError::Other("null handle".into())));
        };
        let Some(id) = read_cstr(parent_id) else {
            return reply::<Paged<MediaItem>>(Err(MediaError::Other("null parent id".into())));
        };
        reply(h.inner.children(&id, page, page_size))
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

/// 版本号，便于各端确认加载的是新库。
#[no_mangle]
pub extern "C" fn dv_version() -> *mut c_char {
    write_json(&Envelope::ok(env!("CARGO_PKG_VERSION")))
}

// 让编译器检查反序列化辅助没被误删（各端 DTO 不需要，保留占位）。
#[allow(dead_code)]
fn _assert_deserialize<T: DeserializeOwned>() {}
