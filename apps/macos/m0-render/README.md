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

- **旧版**（mpv 0.42.0，2026-11-19 构建）不能证明 DV：那时 render API 只有
  legacy `gpu`，没有 gpu-next。**这个限制已经解除**——mpv 在 2026-11-22 合入
  `ad9d850`（add a gpu-next render backend）/ `eb565a2`（renderer selection）后，
  render API 可以用 gpu-next，跑在 OpenGL 上。
  详见 `.opencode/drag-notes.md`。
- 这个程序本身没有截图 / 颜色断言代码，只打印属性。「P5 是紫色」是当时
  **人眼看屏幕**得出的结论，不是测量。
- 不能替代 Windows 的 D3D11 路径验证。
- 没有 HDR 显示器时，只能验证渲染是否正常，不能目视验收 HDR10。

## P5 是紫色（旧版 mpv 下，已修复）

> 2026-11-23 更新：新版 mpv（`1eb941f` 及之后）用 `MPV_RENDER_PARAM_RENDERER`
> 选 `gpu-next` 后，P5 颜色正确。下面这段描述的是**旧版 legacy `gpu`** 的行为。

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
想看 P5 的正确颜色，用产品播放器（进程内 libmpv + render API，gpu-next 负责 DV 整形）：

```bash
cd apps/macos/DvPlayer && ./build.sh
DVPLAYER_LOCAL=../../samples/p5.mkv ./build/DvPlayer.app/Contents/MacOS/DvPlayer
```

P7/P8.1 的 DV 整形同样在 gpu-next 上验（`fel-ab.sh`，或 Windows 的 A4）。
