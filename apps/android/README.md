# Android / Android TV

Kotlin + Compose。手机（Material3）与 TV（tv-material）两个壳，共享一套状态层与两个
播放内核（mpv 默认 + Media3 第二）。

- 方案与里程碑：[docs/M2-ANDROID.md](../../docs/M2-ANDROID.md)
- 双壳：[ADR-0013](../../docs/adr/0013-android-two-shells.md)
- 双内核：[ADR-0014](../../docs/adr/0014-android-dual-engine.md)
- 存储：[ADR-0015](../../docs/adr/0015-android-vfs.md)

状态：**未开始**（2026-11-25 方案定稿）。

## 模块

```
app-phone/      手机入口、权限、PiP
app-tv/         TV 入口、LEANBACK_LAUNCHER、banner
ui-phone/       手机屏幕（Material3）
ui-tv/          TV 屏幕（tv-material）
feature/        共享 ViewModel / UiState
player/         引擎契约、路由、音频焦点、MediaSession、诊断
player-media3/  Media3 适配
player-mpv/     libmpv JNI + EGL 渲染
player-disc/    libbluray JNI（title / 章节）
data/           hub 生命周期、源配置、图片
design/         设计令牌
core/           JNI 声明 + 模型
build-logic/    约定插件
```

## 构建

需要 JDK 17、Android SDK 36、NDK r28、`cargo-ndk`。桌面端用的 JDK 11 不适用于 Android。

```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
./gradlew :app-phone:assembleDebug
./gradlew :app-tv:assembleDebug

# 共享核心
cargo ndk -t arm64-v8a -t x86_64 -o core/src/main/jniLibs build -p dvplayer-media-jni --release
```

## 基线

| 项 | 值 |
| --- | --- |
| minSdk | 26 |
| compileSdk / targetSdk | 36 |
| ABI | `arm64-v8a`（模拟器 `x86_64`） |
| 内存页 | 16KB |
| 许可 | mpv 按 LGPL 构建（`-Dgpl=false`），不改源码 |
