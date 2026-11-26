# ADR-0016：Android 播放器 native 层用 C++ / CMake

- 状态：已接受
- 日期：2026-11-27

## 背景

A4 要把 libmpv 渲染到一个 `Surface` 上。这一步需要同时碰三样东西：

- libmpv 的 render API（`mpv_render_context_*`，纯 C 接口，头文件在 `include/mpv/`）；
- EGL / OpenGL ES（NDK 提供 `EGL/egl.h`、`GLES2/gl2.h`）；
- JNI + `ANativeWindow_fromSurface`。

仓库里现有的 native 只有 `core/media-jni`，是 Rust（`cargo ndk`）编的。
Rust 也能做这件事，但要手写 mpv render API、EGL、GLES 的 FFI 绑定，代码量是 C++
的两三倍，而且没有任何现成 crate 覆盖 mpv 的 render API。

## 决策

1. `:player-mpv` 的 native 层用 **C++17 + CMake**（Gradle `externalNativeBuild`），
   产物是 `libdvplayer_mpv.so`，链接 `libmpv.so`（`IMPORTED` target）。
2. mpv 头文件（`client.h` / `render.h` / `render_gl.h`，mpv `1eb941f` 原样，
   LGPL-2.1+）随仓库走，放在 `player-mpv/src/main/cpp/include/mpv/`，由
   `build-mpv.sh --stage` 同步；`libmpv.so` 本身不进仓库，由
   `scripts/android/build-mpv.sh` 生成。版本必须 ≥ `ad9d850`——那是 libmpv
   拿到 gpu-next 渲染后端的起点，之前的 v0.42.0 只有老 gpu，会剥掉 DV 映射。
3. 线代模型：**渲染线程独占** `EGLDisplay` / `EGLContext` / `EGLSurface` 与
   `mpv_render_context`。`attach` / `detach` 只把 `Surface` 投递给渲染线程，
   不跨线程 `eglMakeCurrent`。
4. 开 `MPV_RENDER_PARAM_ADVANCED_CONTROL`，每帧渲染后调
   `mpv_render_context_report_swap()`，否则 mpv 的帧调度会停摆。
5. 只发 **`arm64-v8a`**。x86_64 仅在本机模拟器调试时按需编，不进 APK。

## 后果

- 仓库里有两套 native 构建链：Rust（`cargo ndk`，给数据层）和 CMake（给播放器）。
  这是有意的分工——数据层的绑定是多函数 C ABI，Rust 划算；渲染层是 GL 状态机，
  C++ 直接。
- Gradle 构建前必须先有 `build/android-mpv/<arch>/prefix/lib/libmpv.so`，
  否则 CMake 配置阶段直接失败（错误信息里写了该跑哪个脚本）。
- 只发 arm64 后，Android 9 上那台 x86_64 模拟器装不了 APK；模拟器回归需要
  arm64 系统镜像或直接用真机。
- **踩过的坑**：GL 就绪前调用 `loadfile`，mpv 会判定「没有视频输出」而只播音频，
  之后即使 render context 建好也不会自动补上视频。`play()` 因此在 GL 未就绪时
  暂存 URL，等 `mpv_render_context_create` 成功后再真正 `loadfile`。
