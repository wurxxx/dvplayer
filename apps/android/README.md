# Android / Android TV

Kotlin + Compose。手机（Material3）与 TV（tv-material）两个壳，共享一套状态层与两个
播放内核（mpv 默认 + Media3 第二）。

- 方案与里程碑：[docs/M2-ANDROID.md](../../docs/M2-ANDROID.md)
- 双壳：[ADR-0013](../../docs/adr/0013-android-two-shells.md)
- 双内核：[ADR-0014](../../docs/adr/0014-android-dual-engine.md)
- 存储：[ADR-0015](../../docs/adr/0015-android-vfs.md)

状态（2026-11-26）：**A0–A10 主体已落地并在真机实测**。两个 APK 能构建，
`:core` 通过 `libdvplayer_media_jni.so` 加载 JNI 自检；libmpv 由
`build-mpv.sh` 产出单一 `libmpv.so`；`:player-mpv` 用 CMake 把 Surface 经
EGL + mpv render API 画出来——HBY 5502（Android 9）与 OnePlus 10 Pro
（Android 16）上都以 720p H.264 + `mediacodec-copy` 出画。HDR 片源按
`primaries`/`gamma` 重建 `EGLSurface`（BT2020_PQ / HLG）并写 buffer dataspace，
24p 自动切 120Hz；PQ 静态元数据走 EGL surface 扩展，HDR10+ 交 Media3
（`hdr10-plus-info`）。DV P5 用 gpu-next + libplacebo DOVI 整形，颜色与 Mac
参考帧一致。

这一轮补的工程化项：

- **TLS**：FFmpeg 静态链 mbedTLS 3.6.4，https 可播；mpv 默认
  `tls-verify=no`（系统 CA 不在 mbedTLS 默认路径），`--es tls_verify 1`
  可开校验，配 `--es tls_ca` 指定 CA。
- **起播帧率**：mp4 load 前用 `FrameRateProbe` 读容器帧率，mkv 由 mpv
  起播后 50ms 轮询 `container-fps`；起播丢帧从 6–7 降到 1。
- **单测 + CI**：路由顺序 / 帧率匹配 / DV 探测 / Range / `.sup` 切分 / 续播
  与回退都有纯 JVM 测试；`.github/workflows/android.yml` 跑单测与两个 APK，
  libmpv 按脚本哈希缓存。
- **凭据**：SMB / WebDAV 密码进 Android Keystore（AES-256-GCM），日志不打印。
- **播放控制**：路由 / 续播 / 切内核 / 回退收进 `:player` 的
  `PlaybackController`。

验证页可用 `--es engine mpv|media3|codec` 切换内核，
见 [`docs/M2-ANDROID.md`](../../docs/M2-ANDROID.md)。样片生成器见
[`scripts/android/gen-hdr-sample.py`](../../scripts/android/gen-hdr-sample.py)，
HDR10+ SEI 注入见
[`scripts/android/gen-hdr10plus-sample.sh`](../../scripts/android/gen-hdr10plus-sample.sh)。
正式播放页还没接，属于 M2-B / 后续。

## 模块

已经建好的八个模块（其余按 A3+ 补）：

```
app-phone/      手机入口、权限、PiP        applicationId com.dvplayer.app
app-tv/         TV 入口、LEANBACK_LAUNCHER applicationId com.dvplayer.app.tv
ui-phone/       手机屏幕（Material3）
ui-tv/          TV 屏幕（tv-material）
design/         色板 / 圆角 / Theme（两个壳共用）
core/           设备能力采集 + JNI 声明（version() 自检）
player-mpv/     libmpv 渲染层（C++ / CMake / EGL）
player-media3/  Media3 内核（ExoPlayer + HDR10+ 探针）
build-logic/    约定插件：compileSdk / minSdk / JDK 17 / Compose / ABI 过滤
```

后续：`feature/`、`player/`、`player-disc/`、`data/`。

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

## 测试

```bash
cd apps/android
./gradlew :player:testDebugUnitTest :core:testDebugUnitTest \
          :player-media3:testDebugUnitTest
```

纯 JVM，不需要设备与 native：路由顺序、帧率匹配、DV 配置记录、HTTP Range、
`.sup` 分段、续播 / 回退 / 切内核都在这里。CI 见
[`.github/workflows/android.yml`](../../.github/workflows/android.yml)。

真机上的 SMB 凭据加密验证：

```bash
SMB_USER=... SMB_PASS=... tests/android/verify-credentials.sh
```

脚本会先带密码列一次目录、检查 SharedPreferences 里没有明文，再不传密码列一次。

SMB 登录本身出问题（`Authentication failed` / 方言 / 签名）时，先在 Mac 的
JVM 上跑门控测试，区分「密码错」和「smbj 与这台 Samba 不兼容」：

```bash
cd apps/android
SMB_LIVE=1 SMB_USER=... SMB_PASS=... \
  ./gradlew :core:testDebugUnitTest --tests '*SmbLiveTest*'
```

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
- mpv 按 LGPL 编（`-Dgpl=false`，FFmpeg `--disable-gpl`），不链 `libsmbclient`；
  见 [ADR-0014](../../docs/adr/0014-android-dual-engine.md)。Android 的 https
  用静态 mbedTLS（Apache-2.0），FFmpeg 因此要 `--enable-version3`，这份
  `libmpv.so` 按 **LGPLv3** 分发（桌面端用系统 TLS，仍是 2.1）。
- mbedTLS 用 release 的 `mbedtls-3.6.4.tar.bz2`；GitHub 的 `archive/` 包缺
  `framework/` 子模块，CMake 会直接报错。

## 播放器的 native 层

`player-mpv` 是 C++（不是 Rust），原因和取舍见
[ADR-0016](../../docs/adr/0016-android-player-native.md)：

- libmpv 的 render API 是 C 接口，EGL/GLES 头由 NDK 提供，C++ 直接 include 就能用；
- `include/mpv/` 里的 `client.h` / `render.h` / `render_gl.h` 是 mpv `1eb941f`
  （v0.42.0-226，与桌面端同一 commit）的原样拷贝（LGPL-2.1+），由
  `build-mpv.sh --stage` 自动同步——升级 mpv 时不要手改，否则会缺新枚举
  （比如 `MPV_RENDER_PARAM_RENDERER`）；
- 渲染线程独占 EGLDisplay / EGLContext / EGLSurface 与 `mpv_render_context`，
  `attach` / `detach` 只投递 Surface，避免跨线程 `eglMakeCurrent`；
- 一个容易踩的坑：**GL 就绪前 `loadfile`，mpv 会认为没有视频输出、只播音频**，
  所以 `play()` 在 GL 未就绪时先暂存 URL，等 render context 建好再加载。
