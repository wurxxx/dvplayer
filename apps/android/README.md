# Android / Android TV

Kotlin + Compose。手机（Material3）与 TV（tv-material）两个壳，共享一套状态层与两个
播放内核（mpv 默认 + Media3 第二）。

- 方案与里程碑：[docs/M2-ANDROID.md](../../docs/M2-ANDROID.md)
- 双壳：[ADR-0013](../../docs/adr/0013-android-two-shells.md)
- 双内核：[ADR-0014](../../docs/adr/0014-android-dual-engine.md)
- 存储：[ADR-0015](../../docs/adr/0015-android-vfs.md)

状态（2026-11-26）：**A0 环境 + A2 骨架已落地**。两个 APK 能构建，`:core` 通过
`libdvplayer_media_jni.so` 加载 JNI 自检，并已在 Android 33 x86_64 模拟器上
安装、启动、显示 native 版本。libmpv 的 Android 构建链也已跑通：`build-mpv.sh`
产出单一 `libmpv.so`，在模拟器上 `dlopen` + `mpv_create` 成功；出画（Surface /
EGL）还没做，属于 A4。

## 模块

已经建好的六个模块（其余按 A3+ 补）：

```
app-phone/      手机入口、权限、PiP        applicationId com.dvplayer.app
app-tv/         TV 入口、LEANBACK_LAUNCHER applicationId com.dvplayer.app.tv
ui-phone/       手机屏幕（Material3）
ui-tv/          TV 屏幕（tv-material）
design/         色板 / 圆角 / Theme（两个壳共用）
core/           JNI 声明（A0 只有 version() 自检）
build-logic/    约定插件：compileSdk / minSdk / JDK 17 / Compose / ABI 过滤
```

后续：`feature/`、`player/`、`player-media3/`、`player-mpv/`、`player-disc/`、`data/`。

## 构建

需要 JDK 17、Android SDK 36、NDK r28、`cargo-ndk`、`meson` / `ninja`。桌面端用的
JDK 11 不适用于 Android。

```bash
source scripts/android/env.sh        # JAVA_HOME 17 / SDK / NDK / PATH
scripts/android/build-native.sh      # cargo ndk（默认 arm64-v8a + x86_64，release）
scripts/android/build-mpv.sh         # libmpv.so（默认 arm64 + x86_64，首次要编依赖）

cd apps/android
./gradlew :app-phone:assembleDebug :app-tv:assembleDebug

# 16KB 页 + .so 未压缩校验
cd ../..
scripts/android/check-apk.sh apps/android/app-phone/build/outputs/apk/debug/app-phone-debug.apk
```

`build-mpv.sh --stage` 会把 `libmpv.so` 一并拷进 `core/src/main/jniLibs/<abi>/`
（该目录不进仓库）。只验一个 ABI 用 `ARCHES=arm64`，重来一遍用 `--clean`。
依赖源码和产物都在 `build/android-mpv/`，`prefix/.done/` 里是各依赖的完成标记。

`env.sh` 默认把 Gradle 依赖走阿里云镜像（`DVPLAYER_MAVEN_MIRROR`）；想完全走官方
仓库就 `DVPLAYER_MAVEN_MIRROR= source scripts/android/env.sh`。`local.properties`
里的 `sdk.dir` 不进仓库，换机器时自己建一份或依赖 `ANDROID_HOME`。

## 基线

| 项 | 值 | 说明 |
| --- | --- | --- |
| minSdk | 26 | |
| compileSdk / targetSdk | 36 | |
| ABI | `arm64-v8a` + `x86_64` | 模拟器用 `x86_64`；32 位 ABI 不打包 |
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
