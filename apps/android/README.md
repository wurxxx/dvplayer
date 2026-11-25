# Android / Android TV

Kotlin + Compose。手机（Material3）与 TV（tv-material）两个壳，共享一套状态层与两个
播放内核（mpv 默认 + Media3 第二）。

- 方案与里程碑：[docs/M2-ANDROID.md](../../docs/M2-ANDROID.md)
- 双壳：[ADR-0013](../../docs/adr/0013-android-two-shells.md)
- 双内核：[ADR-0014](../../docs/adr/0014-android-dual-engine.md)
- 存储：[ADR-0015](../../docs/adr/0015-android-vfs.md)

状态（2026-11-26）：**A0 环境 + A2 骨架已落地**。两个 APK 能构建，`:core` 通过
`libdvplayer_media_jni.so` 加载 JNI 自检；libmpv 构建链还没接通。

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

cd apps/android
./gradlew :app-phone:assembleDebug :app-tv:assembleDebug

# 16KB 页 + .so 未压缩校验
cd ../..
scripts/android/check-apk.sh apps/android/app-phone/build/outputs/apk/debug/app-phone-debug.apk
```

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
