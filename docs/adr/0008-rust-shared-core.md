# ADR-0008：媒体库核心用 Rust 共享，三端只做界面

- 状态：已定
- 日期：2026-11-19

## 背景

媒体库功能（飞牛影视 / Emby 的登录、签名、分页、播放记录、合并搜索）
在 macOS、Windows、Android、Android TV 上都要有。

如果每个端各写一遍：

- 飞牛的 authx 签名要维护四份，改一次要同步四处；
- 分页、去重、进度合并的规则会在四端漂移；
- 出问题要逐个端复现。

`docs/PLAN.md` 的 M4 已经定了「Rust 共享媒体库 / 元数据 / 续播，收敛三端逻辑」，
这里把它提前到媒体库功能的第一天。

## 决策

1. 新建 Rust crate `core/media`，负责：
   - 各源适配（`FnOsSource`、`EmbySource`）
   - authx 签名、token 管理
   - 统一模型与聚合（合并、去重、排序、搜索）
   - 播放进度合并
2. 所有能力通过 **C ABI** 暴露（`#[no_mangle] extern "C"`），
   数据用 **JSON 字符串**交换，调用方负责释放。
3. 各端只保留薄封装：

   | 平台 | 绑定 | UI |
   | --- | --- | --- |
   | Windows | C# P/Invoke → `dvplayer_media.dll` | WPF + WPF-UI |
   | macOS | Swift C 互操作 → `libdvplayer_media.a` | SwiftUI |
   | Android / TV | JNI 或 C ABI → `libdvplayer_media.so` | Compose |

4. Rust 侧用同步 API（内部阻塞 HTTP），调用方在自己的后台线程调用：
   C# `Task.Run`、Kotlin `Dispatchers.IO`、Swift `Task.detached`。
5. 播放器不共享：Windows/macOS 用 mpv，Android 用 Media3（ADR-0004）。

## 接口约定

统一响应：

```json
{ "ok": true, "data": { } }
{ "ok": false, "error": "invalid sign", "code": 5000 }
```

模型字段一律 `camelCase`，与 `docs/FNOS-API.md` 对齐：

```json
// MediaItem
{ "id":"...", "title":"...", "kind":"movie|series|season|episode|folder|video",
  "posterPath":"...", "parentId":null, "runtimeSeconds":127,
  "progress":0.0, "sourceId":"fnos-1", "resolution":"2160p" }
```

## 构建

```bash
# Windows（在 Windows 上）
cargo build -p dvplayer-media --release --target x86_64-pc-windows-msvc

# macOS
cargo build -p dvplayer-media --release --target x86_64-apple-darwin

# Android
cargo ndk -t arm64-v8a -t armeabi-v7a -o ../../apps/android/app/src/main/jniLibs build -p dvplayer-media --release
```

## 后果

- 多一层 FFI，调试时先看 Rust 日志；
- C# 侧不再实现签名与分页，只做 JSON → ViewModel；
- 新增一个源（Jellyfin/Plex）只改 Rust 一处。
