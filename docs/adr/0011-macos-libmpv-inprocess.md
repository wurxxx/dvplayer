# ADR-0011：macOS 播放层改回进程内 libmpv + render API（单窗口）

- 状态：已接受（取代 ADR-0010）
- 日期：2026-11-23

## 背景

ADR-0010 把 macOS 播放器改成「mpv 子进程 + 透明浮层窗」，原因是当时 render API
只有 legacy `gpu` 后端，DV 整形（`pl_shader_dovi_reshape()`）只在 `vo_gpu_next`
里，而 gpu-next 只能用 mpv 自己的窗口。

这个方案的代价是**两个窗口**：视频在 mpv 的窗口里，控制条在我们透明的浮层里。
用户反馈拖动窗口时画面明显滞后，不如单窗口顺滑。试过的补救：

- 拖动时把拖拽转交给 mpv 窗口（`postMouseDown` + 低频 Timer）——视频跟得上，
  但控制条要藏起来，松手才回来
- 高频 `syncGeometry`——两个窗口永远慢一拍（实测 20–30ms 追赶）

根因是结构性的：两个独立窗口没法同帧移动。

## 决策

**macOS 播放层改成进程内 libmpv + render API + 单窗口。**

mpv 在 2026-11-22 合入三个提交，让 render API 可以用 gpu-next：

| 提交 | 内容 |
| --- | --- |
| `ad9d850` | `libmpv: add a gpu-next render backend` |
| `eb565a2` | `libmpv: add renderer selection to the render API` |
| `3e8aa53` | `libmpv: use the gpu-next renderer by default in the render API` |

`libmpv_gpu_next.c` 用 `mppl_video_*`（vo_gpu_next 同一个渲染器），跑在
**OpenGL** 上，**不需要 Vulkan**。`prefix/lib` 的 libplacebo 是
`-Dvulkan=disabled` 编的，正好匹配。

### 结构

```text
PlayerWindow (NSWindow)
└── container (NSView, wantsLayer)
    ├── MpvVideoView (NSOpenGLView)   ← 最底层，mpv 画在这里
    │   └── glQueue (串行渲染队列)
    │       ├── mpv_render_context_render → FBO 0
    │       ├── flushBuffer
    │       └── mpv_render_context_report_swap
    └── NSHostingView(PlayerView)      ← 控制条 / 面板，透明，盖在上面
```

### 关键约束

- **渲染必须在后台队列**：IINA 的 `ViewLayer.swift` 注释明确说，主线程渲染会让
  浮动控制条拖动发涩。实测用 `CAOpenGLLayer`（draw 在主线程事务里）时，
  拖动 0.9 秒内一帧都没画。
- **一次只排一个渲染任务**：mpv 出帧比显示器快，排队只会让延迟累积。
- **`MpvEngine` 对外接口不变**：`PlayerSession`（1857 行）一行没改。

## 后果

好处：

- 拖动 / 缩放 / 全屏只移动一个窗口，画面天然同步（实测拖动 133 次/秒、
  零掉帧、拖动期间保持源帧率 24fps）
- 不再需要 `geometry` 同步、`ontop` 层级、拖拽转交、窗口查找
- 和 Windows 的 libmpv 嵌入同构，两边行为一致
- 打包不再需要 `prefix-vk`（Vulkan / MoltenVK / ICD），依赖更少

代价：

- App 编译期链接 libmpv，`build.sh` 要把它和依赖（libplacebo / libass /
  ffmpeg 系列 / 5 个 Homebrew 库）一起拷进 `Contents/Frameworks`
- mpv 版本被 pin 到 `1eb941f`（`prefix/.mpv-commit`），升级要重新验证 DV 色彩
- `NSOpenGLView` 在 layer-backed 容器里要手动调 `prepareOpenGL`，
  而且它的内容 `layer.render` 抓不到（窗口截图里视频区是黑的，但实际显示正常）

## 相关

- ADR-0003（macOS 播放实现，已被 ADR-0010 取代）
- ADR-0006（Vulkan 验证路径，DV 验证仍然有效，但不再是产品路径）
- ADR-0010（子进程 + 浮层，已被本 ADR 取代）
- `.opencode/drag-notes.md`（完整调研记录、framebuffer 验证数据、踩过的坑）
