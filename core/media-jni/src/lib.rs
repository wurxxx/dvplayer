//! Android 侧的 JNI 入口。
//!
//! A0 只放一个自检函数，用来证明「Gradle → jniLibs → System.loadLibrary →
//! Rust」这条链是通的。A3 起这里会转发到 `core/media` 的 C ABI（41 个 `dv_*`）。

use jni::objects::JObject;
use jni::sys::jstring;
use jni::JNIEnv;

/// `com.dvplayer.core.Native.version()`
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
