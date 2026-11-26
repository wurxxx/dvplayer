//! Android 侧的 JNI 入口。
//!
//! 约定与 C ABI（`dvplayer_media::ffi`）一致：
//! - 所有返回 JSON 的函数返回 UTF-8 字符串，失败也是 `{"ok":false,"error":"..."}`；
//! - 句柄在 Kotlin 侧是 `Long`（就是 `*mut SourceHandle` / `*mut HubHandle`）；
//! - 字符串参数可以是 null，对应 C 的空指针。
//!
//! 这里不重写业务逻辑，只是把 `jlong`/`jstring` 换成 C ABI 的指针再转发一次，
//! 保证 Android 和桌面端走的是同一份核心。

use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr;

use jni::objects::{GlobalRef, JObject, JString, JValue};
use jni::sys::{jint, jlong, jstring};
use jni::{JNIEnv, JavaVM};

use dvplayer_media::ffi as core;

/// C 字符串 → Kotlin String，并顺手 `dv_string_free`。
///
/// 用 unsafe 是因为 `ptr` 由核心给出；核心保证非空时是可释放的 C 字符串。
unsafe fn take(env: &mut JNIEnv, ptr: *mut c_char) -> jstring {
    if ptr.is_null() {
        // Kotlin 侧声明的是非空 String：给一个合法的错误 JSON，别回 null。
        return env
            .new_string(r#"{"ok":false,"error":"null pointer from core"}"#)
            .map(|s| s.into_raw())
            .unwrap_or(ptr::null_mut());
    }
    let text = CStr::from_ptr(ptr).to_string_lossy().into_owned();
    core::dv_string_free(ptr);
    match env.new_string(text) {
        Ok(s) => s.into_raw(),
        Err(_) => env
            .new_string(r#"{"ok":false,"error":"jni new_string failed"}"#)
            .map(|s| s.into_raw())
            .unwrap_or(ptr::null_mut()),
    }
}

/// Kotlin String? → CString（null → None）。
fn read(env: &mut JNIEnv, s: &JString) -> Option<CString> {
    if s.as_raw().is_null() {
        return None;
    }
    let java = env.get_string(s).ok()?;
    CString::new(String::from(java)).ok()
}

/// `Option<CString>` → 可空 C 指针。
fn cstr(value: &Option<CString>) -> *const c_char {
    value.as_ref().map_or(ptr::null(), |c| c.as_ptr())
}

/// `com.dvplayer.core.Native.version()`
///
/// 只证明「Gradle → jniLibs → System.loadLibrary → Rust」这条链是通的；
/// 核心本身的版本看 `coreVersion()`。
#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_version<'local>(
    env: JNIEnv<'local>,
    _this: JObject<'local>,
) -> jstring {
    let value = format!("dvplayer-media-jni {}", env!("CARGO_PKG_VERSION"));
    match env.new_string(value) {
        Ok(string) => string.into_raw(),
        // 只有 JVM 侧内存耗尽才会失败；返回 null，Kotlin 侧会被当成「未加载」。
        Err(_) => std::ptr::null_mut(),
    }
}

// —— 单源 ——

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_sourceKinds<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
) -> jstring {
    unsafe { take(&mut env, core::dv_source_kinds()) }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_sourceCreate<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    config: JString<'l>,
) -> jlong {
    let json = read(&mut env, &config);
    core::dv_source_create(cstr(&json)) as jlong
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_sourceFree(
    _env: JNIEnv,
    _this: JObject,
    handle: jlong,
) {
    core::dv_source_free(handle as *mut core::SourceHandle)
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_connect<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
) -> jstring {
    unsafe { take(&mut env, core::dv_connect(handle as *mut core::SourceHandle)) }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_libraries<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
) -> jstring {
    unsafe { take(&mut env, core::dv_libraries(handle as *mut core::SourceHandle)) }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_items<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    library_id: JString<'l>,
    page: jint,
    page_size: jint,
    query: JString<'l>,
) -> jstring {
    let lib = read(&mut env, &library_id);
    let q = read(&mut env, &query);
    unsafe {
        take(
            &mut env,
            core::dv_items(
                handle as *mut core::SourceHandle,
                cstr(&lib),
                page,
                page_size,
                cstr(&q),
            ),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_children<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    parent_id: JString<'l>,
    page: jint,
    page_size: jint,
    query: JString<'l>,
) -> jstring {
    let parent = read(&mut env, &parent_id);
    let q = read(&mut env, &query);
    unsafe {
        take(
            &mut env,
            core::dv_children(
                handle as *mut core::SourceHandle,
                cstr(&parent),
                page,
                page_size,
                cstr(&q),
            ),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_records<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
) -> jstring {
    unsafe { take(&mut env, core::dv_records(handle as *mut core::SourceHandle)) }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_reportProgress<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    item_id: JString<'l>,
    position: jlong,
    duration: jlong,
) -> jstring {
    let id = read(&mut env, &item_id);
    unsafe {
        take(
            &mut env,
            core::dv_report_progress(
                handle as *mut core::SourceHandle,
                cstr(&id),
                position,
                duration,
            ),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_reportStopped<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    item_id: JString<'l>,
    position: jlong,
    duration: jlong,
) -> jstring {
    let id = read(&mut env, &item_id);
    unsafe {
        take(
            &mut env,
            core::dv_report_stopped(
                handle as *mut core::SourceHandle,
                cstr(&id),
                position,
                duration,
            ),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_itemDetail<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    item_id: JString<'l>,
) -> jstring {
    let id = read(&mut env, &item_id);
    unsafe {
        take(
            &mut env,
            core::dv_item_detail(handle as *mut core::SourceHandle, cstr(&id)),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_playSource<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    item_id: JString<'l>,
) -> jstring {
    let id = read(&mut env, &item_id);
    unsafe {
        take(
            &mut env,
            core::dv_play_source(handle as *mut core::SourceHandle, cstr(&id)),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_imageSource<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    path: JString<'l>,
) -> jstring {
    let p = read(&mut env, &path);
    unsafe {
        take(
            &mut env,
            core::dv_image_source(handle as *mut core::SourceHandle, cstr(&p)),
        )
    }
}

/// DV P7 的 FEL / MEL 判定：不需要 hub，只有本地文件时也能跑。
#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_probeDovi<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    url: JString<'l>,
    headers: JString<'l>,
    proxy: JString<'l>,
) -> jstring {
    let u = read(&mut env, &url);
    let h = read(&mut env, &headers);
    let p = read(&mut env, &proxy);
    unsafe { take(&mut env, core::dv_probe_dovi(cstr(&u), cstr(&h), cstr(&p))) }
}

// —— 聚合层 ——

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubNew(
    _env: JNIEnv,
    _this: JObject,
) -> jlong {
    core::dv_hub_new() as jlong
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubFree(
    _env: JNIEnv,
    _this: JObject,
    handle: jlong,
) {
    core::dv_hub_free(handle as *mut core::HubHandle)
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubAdd<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    config: JString<'l>,
) -> jstring {
    let json = read(&mut env, &config);
    unsafe {
        take(
            &mut env,
            core::dv_hub_add(handle as *mut core::HubHandle, cstr(&json)),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubAddMany<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    configs: JString<'l>,
) -> jstring {
    let json = read(&mut env, &configs);
    unsafe {
        take(
            &mut env,
            core::dv_hub_add_many(handle as *mut core::HubHandle, cstr(&json)),
        )
    }
}

/// 流式建连的回调盒：JVM 引用必须活到 `dv_hub_add_many_stream` 返回。
struct JvmCallback {
    vm: JavaVM,
    target: GlobalRef,
}

/// 核心从建连线程回调进来：这里不能碰 JNIEnv 之外的东西，也不能 panic。
extern "C" fn emit_source(text: *const c_char, user: *mut c_void) {
    if text.is_null() || user.is_null() {
        return;
    }
    let cb = unsafe { &*(user as *const JvmCallback) };
    let Ok(mut env) = cb.vm.attach_current_thread() else {
        return;
    };
    let json = unsafe { CStr::from_ptr(text) }.to_string_lossy();
    let Ok(value) = env.new_string(json) else {
        return;
    };
    // 回调方自己负责切线程；签名固定是 (String) -> Unit。
    let _ = env.call_method(
        cb.target.as_obj(),
        "onSource",
        "(Ljava/lang/String;)V",
        &[JValue::Object(&JObject::from(value))],
    );
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubAddManyStream<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    configs: JString<'l>,
    listener: JObject<'l>,
) -> jstring {
    let json = read(&mut env, &configs);
    let Ok(vm) = env.get_java_vm() else {
        return unsafe {
            take(
                &mut env,
                CString::new(r#"{"ok":false,"error":"no JVM"}"#)
                    .unwrap()
                    .into_raw(),
            )
        };
    };
    let Ok(target) = env.new_global_ref(&listener) else {
        return unsafe {
            take(
                &mut env,
                CString::new(r#"{"ok":false,"error":"listener ref"}"#)
                    .unwrap()
                    .into_raw(),
            )
        };
    };

    // Box 在这里持有到调用返回：核心保证所有回调都在返回前完成。
    let callback = Box::new(JvmCallback { vm, target });
    let user = (&*callback) as *const JvmCallback as *mut c_void;

    let out = core::dv_hub_add_many_stream(
        handle as *mut core::HubHandle,
        cstr(&json),
        Some(emit_source),
        user,
    );
    drop(callback);
    unsafe { take(&mut env, out) }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubSources<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
) -> jstring {
    unsafe { take(&mut env, core::dv_hub_sources(handle as *const core::HubHandle)) }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubLibraries<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
) -> jstring {
    unsafe { take(&mut env, core::dv_hub_libraries(handle as *const core::HubHandle)) }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubItems<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    library_id: JString<'l>,
    page: jint,
    page_size: jint,
    query: JString<'l>,
) -> jstring {
    let lib = read(&mut env, &library_id);
    let q = read(&mut env, &query);
    unsafe {
        take(
            &mut env,
            core::dv_hub_items(
                handle as *const core::HubHandle,
                cstr(&lib),
                page,
                page_size,
                cstr(&q),
            ),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubSearch<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    query: JString<'l>,
) -> jstring {
    let q = read(&mut env, &query);
    unsafe {
        take(
            &mut env,
            core::dv_hub_search(handle as *const core::HubHandle, cstr(&q)),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubItemSources<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    item_id: JString<'l>,
) -> jstring {
    let id = read(&mut env, &item_id);
    unsafe {
        take(
            &mut env,
            core::dv_hub_item_sources(handle as *const core::HubHandle, cstr(&id)),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubChildren<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    parent_id: JString<'l>,
    page: jint,
    page_size: jint,
    query: JString<'l>,
) -> jstring {
    let parent = read(&mut env, &parent_id);
    let q = read(&mut env, &query);
    unsafe {
        take(
            &mut env,
            core::dv_hub_children(
                handle as *const core::HubHandle,
                cstr(&parent),
                page,
                page_size,
                cstr(&q),
            ),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubGenres<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    scope_id: JString<'l>,
) -> jstring {
    let scope = read(&mut env, &scope_id);
    unsafe {
        take(
            &mut env,
            core::dv_hub_genres(handle as *const core::HubHandle, cstr(&scope)),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubDetail<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    item_id: JString<'l>,
) -> jstring {
    let id = read(&mut env, &item_id);
    unsafe {
        take(
            &mut env,
            core::dv_hub_detail(handle as *const core::HubHandle, cstr(&id)),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubPersonWorks<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    person_id: JString<'l>,
) -> jstring {
    let id = read(&mut env, &person_id);
    unsafe {
        take(
            &mut env,
            core::dv_hub_person_works(handle as *const core::HubHandle, cstr(&id)),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubPeople<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    item_id: JString<'l>,
) -> jstring {
    let id = read(&mut env, &item_id);
    unsafe {
        take(
            &mut env,
            core::dv_hub_people(handle as *const core::HubHandle, cstr(&id)),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubMediaInfo<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    item_id: JString<'l>,
) -> jstring {
    let id = read(&mut env, &item_id);
    unsafe {
        take(
            &mut env,
            core::dv_hub_media_info(handle as *const core::HubHandle, cstr(&id)),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubPlaySource<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    item_id: JString<'l>,
) -> jstring {
    let id = read(&mut env, &item_id);
    unsafe {
        take(
            &mut env,
            core::dv_hub_play_source(handle as *const core::HubHandle, cstr(&id)),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubReportProgress<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    item_id: JString<'l>,
    position: jlong,
    duration: jlong,
) -> jstring {
    let id = read(&mut env, &item_id);
    unsafe {
        take(
            &mut env,
            core::dv_hub_report_progress(
                handle as *const core::HubHandle,
                cstr(&id),
                position,
                duration,
            ),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubReportStopped<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    item_id: JString<'l>,
    position: jlong,
    duration: jlong,
) -> jstring {
    let id = read(&mut env, &item_id);
    unsafe {
        take(
            &mut env,
            core::dv_hub_report_stopped(
                handle as *const core::HubHandle,
                cstr(&id),
                position,
                duration,
            ),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubSetFavorite<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    item_id: JString<'l>,
    favorite: jint,
) -> jstring {
    let id = read(&mut env, &item_id);
    unsafe {
        take(
            &mut env,
            core::dv_hub_set_favorite(handle as *const core::HubHandle, cstr(&id), favorite),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubSetWatched<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    item_id: JString<'l>,
    watched: jint,
) -> jstring {
    let id = read(&mut env, &item_id);
    unsafe {
        take(
            &mut env,
            core::dv_hub_set_watched(handle as *const core::HubHandle, cstr(&id), watched),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubRemoveRecord<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    item_id: JString<'l>,
) -> jstring {
    let id = read(&mut env, &item_id);
    unsafe {
        take(
            &mut env,
            core::dv_hub_remove_record(handle as *const core::HubHandle, cstr(&id)),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubFavorites<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    page: jint,
    page_size: jint,
) -> jstring {
    unsafe {
        take(
            &mut env,
            core::dv_hub_favorites(handle as *const core::HubHandle, page, page_size),
        )
    }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubRecords<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
) -> jstring {
    unsafe { take(&mut env, core::dv_hub_records(handle as *const core::HubHandle)) }
}

#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_hubImageSource<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
    handle: jlong,
    path: JString<'l>,
) -> jstring {
    let p = read(&mut env, &path);
    unsafe {
        take(
            &mut env,
            core::dv_hub_image_source(handle as *const core::HubHandle, cstr(&p)),
        )
    }
}

/// `dv_version` 的 JNI 版本（和 `Native.version()` 对齐，便于统一排查）。
#[no_mangle]
pub extern "system" fn Java_com_dvplayer_core_Native_coreVersion<'l>(
    mut env: JNIEnv<'l>,
    _this: JObject<'l>,
) -> jstring {
    unsafe { take(&mut env, core::dv_version()) }
}
