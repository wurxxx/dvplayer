# m0-render

最小 libmpv render API 验证程序，用于 M0 的 A3：

- 证明 `MPV_RENDER_API_TYPE_OPENGL` + `NSOpenGLView` 能正确出画；
- 打印 `video-params/*`、drop 计数、draw 次数；
- 为后续 macOS 壳提供可复用的最小骨架。

## 构建

```bash
./build.sh
```

依赖 `prefix/` 里的 libmpv（先跑 `scripts/build-deps-macos.sh`）。

## 运行

```bash
./m0-render /path/to/sample.mkv 15
```

| 参数 / 环境变量 | 说明 |
| --- | --- |
| 第 2 个参数 | 运行秒数，默认 10 |
| `HWDEC` | `no`（默认）或 `videotoolbox` |
| `MPV_MSGLVL` | mpv 日志级别，默认 `all=info`，排查时用 `all=v` |

`q` 退出，空格暂停。输出里的 `[probe]` 段是观察到的属性，其余是 mpv 日志。

## 实测（2026-11-19，RX 560 / SDR 屏）

`samples/p5.mkv`（4K24 HEVC 10bit，DV Profile 5）：

```
video-params/pixelformat     yuv420p10        （HWDEC=videotoolbox 时为 videotoolbox）
video-params/colormatrix     dolbyvision
video-params/primaries       bt.2020
video-params/gamma           pq
video-params/sig-peak        4.929080
decoder-frame-drop-count     0
[done] 15.0s draws=344
```

## 踩过的坑（改之前先看）

| 坑 | 表现 | 处理 |
| --- | --- | --- |
| 像素格式不是 core 3.2 | `GLSL version too old`、scaler 全禁用 | 加 `NSOpenGLPFAOpenGLProfile` + `Version3_2Core` |
| advanced control | `Video source: 0x0`，`vo-configured=no`，draws 只有 3 次 | `MPV_RENDER_PARAM_ADVANCED_CONTROL=0` |
| 跨线程读属性 | `mpv_get_property_string` 卡死 | 用 `mpv_observe_property` + `MPV_EVENT_PROPERTY_CHANGE` |
| 找 DV profile 属性 | `${dolby-vision-profile}` 报错 | 0.42 没这个属性，看 `video-params/colormatrix` |

## 它不能证明什么

- 不能证明 DV：render API 只有 legacy `gpu`，没有 gpu-next。
  本机 mpv 0.42 连 OpenGL 的 GPU context 都没有（`--vo=gpu` 直接失败），
  macOS 想走 gpu-next 只能上 Vulkan。
- 不能替代 Windows 的 D3D11 路径验证。
- 没有 HDR 显示器时，只能验证渲染是否正常，不能目视验收 HDR10。
