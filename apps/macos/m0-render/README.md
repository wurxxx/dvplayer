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
| `MPV_EXTRA` | 额外 mpv 选项，`;` 分隔，如 `tone-mapping=clip;vf=format:colormatrix=bt.2020-ncl` |

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

## P5 是紫色（预期）

`samples/p5.mkv` 能正常解码、帧率也对，但画面偏紫红。

原因：Profile 5 的像素是 IPTPQc2（不是 YCbCr），正确显示需要 libplacebo 的
DV reshape（`pl_shader_dovi_reshape`），而这只在 gpu-next 里启用。
legacy `gpu` 在 `video/out/gpu/video.c` 里调 `mp_image_params_restore_dovi_mapping()`，
把 `repr.sys` 从 `DOLBYVISION` 换回 BT.2020-NCL——等于把 IPT 当 YCbCr 解。

P7 / P8.1 不受影响：它们的 BL 是真 HDR10，legacy `gpu` 可以正常 tone map，
只是增强层不参与。P5 没有 HDR10 回退，所以只有它错。

对照实验（强制成普通 YCbCr 后会更紫，说明不是 tone mapping 参数问题）：

```bash
MPV_EXTRA='vf=format:colormatrix=bt.2020-ncl' ./m0-render samples/p5.mkv 15
```

结论：**这个程序不用于验收色彩**，只验证渲染管线。
想看 P5 的正确颜色，用 Vulkan 验证路径（ADR-0006）：

```bash
./scripts/build-vk-macos.sh
./scripts/mpv-vk.sh samples/p5.mkv
```

P7/P8.1 的 DV 整形在 gpu-next 上验（`fel-ab.sh --vk`，或 Windows 的 A4）。
