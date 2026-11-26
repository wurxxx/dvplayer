# Android / Android TV

Kotlin + Compose。手机（Material3）与 TV（tv-material）两个壳，共享一套状态层与两个
播放内核（mpv 默认 + Media3 第二）。

- 方案与里程碑：[docs/M2-ANDROID.md](../../docs/M2-ANDROID.md)
- 双壳：[ADR-0013](../../docs/adr/0013-android-two-shells.md)
- 双内核：[ADR-0014](../../docs/adr/0014-android-dual-engine.md)
- 存储：[ADR-0015](../../docs/adr/0015-android-vfs.md)

状态（2026-11-27）：**A0 环境、A2 骨架、A1 设备能力采集、A4 最小出画、A5 HDR
通路已落地**。两个 APK 能构建，`:core` 通过 `libdvplayer_media_jni.so` 加载 JNI
自检；libmpv 由 `build-mpv.sh` 产出单一 `libmpv.so`；`:player-mpv` 用 CMake 把
Surface 经 EGL + mpv render API 画出来——HBY 5502（Android 9）与 OnePlus 10 Pro
（Android 16）上都以 720p H.264 + `mediacodec-copy` 出画，时间码正常推进。HDR 片源
会按 `primaries`/`gamma` 重建 `EGLSurface`（BT2020_PQ / HLG）并写 buffer
dataspace，OnePlus 上 SurfaceFlinger 已按 `BT2020_PQ` 走 HWC 直出。播放控制
（暂停 / seek / 切轨 / 字幕）还没接，属于 A4 的后半段。

## 模块

已经建好的七个模块（其余按 A3+ 补）：

```
app-phone/      手机入口、权限、PiP        applicationId com.dvplayer.app
app-tv/         TV 入口、LEANBACK_LAUNCHER applicationId com.dvplayer.app.tv
ui-phone/       手机屏幕（Material3）
ui-tv/          TV 屏幕（tv-material）
design/         色板 / 圆角 / Theme（两个壳共用）
core/           设备能力采集 + JNI 声明（version() 自检）
player-mpv/     libmpv 渲染层（C++ / CMake / EGL）
build-logic/    约定插件：compileSdk / minSdk / JDK 17 / Compose / ABI 过滤
```

后续：`feature/`、`player/`、`player-media3/`、`player-disc/`、`data/`。

## 构建

需要 JDK 17、Android SDK 36、NDK r28、`cargo-ndk`、`meson` / `ninja`。桌面端用的
JDK 11 不适用于 Android。

```bash
source scripts/android/env.sh        # JAVA_HOME 17 / SDK / NDK / PATH
scripts/android/build-native.sh      # cargo ndk（默认 arm64-v8a，release）
scripts/android/build-mpv.sh --stage # libmpv.so，顺带放进 core/src/main/jniLibs

cd apps/android
./gradlew :app-phone:assembleDebug :app-tv:assembleDebug

# 16KB 页 + .so 未压缩校验
cd ../..
scripts/android/check-apk.sh apps/android/app-phone/build/outputs/apk/debug/app-phone-debug.apk
```

`:player-mpv` 走 `externalNativeBuild(CMake)`，CMake 脚本要读
`build/android-mpv/<arch>/prefix/lib/libmpv.so`，所以 **gradle 之前必须先跑
`build-mpv.sh`**，否则配置阶段就会报找不到 `libmpv.so`。

`core/src/main/jniLibs/` 不进仓库。重来一遍用 `build-mpv.sh --clean`；依赖源码和
产物都在 `build/android-mpv/`，`prefix/.done/` 里是各依赖的完成标记。
`ARCHES=x86_64` 还能编，但只在本机模拟器调试时有用，默认不编也不打包。

`env.sh` 默认把 Gradle 依赖走阿里云镜像（`DVPLAYER_MAVEN_MIRROR`）；想完全走官方
仓库就 `DVPLAYER_MAVEN_MIRROR= source scripts/android/env.sh`。`local.properties`
里的 `sdk.dir` 不进仓库，换机器时自己建一份或依赖 `ANDROID_HOME`。

## 基线

| 项 | 值 | 说明 |
| --- | --- | --- |
| minSdk | 26 | |
| compileSdk / targetSdk | 36 | |
| ABI | `arm64-v8a` | 只发 64 位 ARM；32 位与 x86_64 都不打包 |
| NDK | r28（28.2.13676358） | 产物按 16KB 页对齐 |
| JDK | 17 | AGP 8 要求 |
| AGP / Gradle | 8.13.2 / 8.13 | |
| Kotlin | 2.2.21 | Compose 编译器插件同版本 |
| Compose BOM | 2026.06.01 | 更新的 BOM 要求 compileSdk 37 / AGP 9.1 |
| 许可 | mpv 按 LGPL 构建（`-Dgpl=false`），不改源码 | |

## native 库命名

Android 侧是 `libdvplayer_media_jni.so`（crate `dvplayer-media-jni`），
不叫 `libdvplayer_media.so`：桌面端的 `core/media` 已经占了那个 lib 名，
两个 crate 在同一个 `target/` 下会撞输出文件。A3 接真正的 C ABI 后如果
要改名，再统一调整。

## libmpv 的形态

- 依赖（FFmpeg / libplacebo / libass / libbluray / freetype / fontconfig /
  harfbuzz / fribidi / libunibreak / libudfread）全部静态，只对外一个
  `libmpv.so`。FFmpeg 若按共享库编会得到 `libavcodec.so.62` 这种带版本 soname
  的文件名，Android 打包进 APK 后 `dlopen` 找不到。
- `NEEDED` 只应该有 `libm / libc / libdl / libandroid / libmediandk /
  libOpenSLES / libEGL`。出现 `libc++_shared.so` 就说明 C++ 没静态链进去，
  `dlopen` 会报 `cannot locate symbol _ZNSt6__ndk1...`。
- mpv 按 LGPL 编（`-Dgpl=false`，FFmpeg `--disable-gpl --disable-version3`），
  不链 `libsmbclient`；见 [ADR-0014](../../docs/adr/0014-android-dual-engine.md)。

## 播放器的 native 层

`player-mpv` 是 C++（不是 Rust），原因和取舍见
[ADR-0016](../../docs/adr/0016-android-player-native.md)：

- libmpv 的 render API 是 C 接口，EGL/GLES 头由 NDK 提供，C++ 直接 include 就能用；
- `include/mpv/` 里的 `client.h` / `render.h` / `render_gl.h` 是 mpv 0.42.0 的原样拷贝
  （LGPL-2.1+），这样 CMake 不依赖 `build/android-mpv/` 里的头文件；
- 渲染线程独占 EGLDisplay / EGLContext / EGLSurface 与 `mpv_render_context`，
  `attach` / `detach` 只投递 Surface，避免跨线程 `eglMakeCurrent`；
- 一个容易踩的坑：**GL 就绪前 `loadfile`，mpv 会认为没有视频输出、只播音频**，
  所以 `play()` 在 GL 未就绪时先暂存 URL，等 render context 建好再加载。
