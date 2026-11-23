# ADR-0010：macOS 改用 mpv 子进程 + 透明浮层窗（支持 Dolby Vision）

- 状态：**已废弃**（被 ADR-0011 取代）
- 日期：2026-11-21

> **2026-11-23 更新**：mpv 在 2026-11-22 合入 `ad9d850`（add a gpu-next render
> backend）/ `eb565a2`（renderer selection），render API 现在能用 gpu-next，
> 跑在 OpenGL 上、不需要 Vulkan。本 ADR 的核心前提（「gpu-next 只能用 mpv
> 自己的窗口」）已经不成立，macOS 播放层已改回单窗口 + render API。
> 见 ADR-0011 与 `.opencode/drag-notes.md`。

## 背景

ADR-0003 选的是 libmpv render API + `NSOpenGLView`，代价是放弃 Dolby Vision：
render API 只有 legacy `gpu` 后端，而 DV 整形（`pl_shader_dovi_reshape()`）只在
`vo_gpu_next` 里。0.42 的 macOS 甚至没有 OpenGL 的 GPU context，`--vo=gpu` 直接起不来。

ADR-0006 已经在本机验过另一条路：`prefix-vk` 的 mpv（gpu-next + Vulkan/macvk）
能把 P5 的颜色显示正确。这条路的唯一问题是 **gpu-next 只能用 mpv 自己的窗口**
（cocoa-cb），壳拿不到帧。

## 决策

macOS 播放器 = **mpv 子进程 + 透明浮层窗口**，和 Windows 同一套骨架：

```text
DvPlayer.app
  └── Contents/Frameworks/mpv --vo=gpu-next --gpu-api=vulkan --gpu-context=macvk
                                --geometry=<浮层 frame> --input-ipc-server=<unix socket>
      │
      ├── 视频：mpv 自己的窗口（cocoa-cb + Vulkan/macvk + gpu-next）
      │         Dolby Vision / HDR10 / tone map 全在这里
      │
      └── 壳：NSWindow(isOpaque=false, level=normal+1) 盖在上面
              顶栏 / 控制条 / 选集 / 媒体信息都是 SwiftUI，透明处透出视频
              窗口 move / resize → 40ms 合并 → IPC set_property geometry
```

- 控制与状态走 JSON IPC（unix socket），协议和 Windows 的 `MpvIpc.cs` 相同；
- **假全屏**：视频在另一个进程的窗口里，进不了同一个 fullscreen space。
  两个窗口都铺满屏幕 + `NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]`；
- 浮层窗口 `level = normal + 1`，`--focus-on=never`，键盘 / 滚轮由浮层自己接管；
- `--vo=null` 留在代码里（`DVPLAYER_NO_VO=1`）：锁屏 / 无图形会话时只跑解码与 IPC，
  用来做端到端自检。

## 后果

- 好：DV P5/P7 走的是验证过的 gpu-next 路径；控制面与 Windows 完全同构；
  mpv 可以单独换版本，崩溃隔离；
- 坏：`.app` 要带 Vulkan loader + MoltenVK（48MB），打包脚本复杂一截；
- 坏：视频和壳是两个窗口，位置 / 大小 / 全屏 / 焦点都要自己同步，拖窗口时
  有几十毫秒的跟手延迟（靠 40ms 合并压到感知不到）；
- 需要接受：系统全屏 space 用不了，只能用假全屏；
- `core/mpv`（libmpv 封装）对 macOS 也不再需要，`Sources/MpvKit` 已删。

## 验证（2026-11-21）

锁屏状态下用 `DVPLAYER_NO_VO=1` 跑通全链路：起播、进度增长、轨道解析、
中文字幕自动选（`sid=1` 繁体中文）、EOF 接下一集、最后一集播完关窗且不覆盖进度、
记录续播 + 后台补 70 集。画面（mpv 窗口出画、浮层覆盖、geometry 跟随、P5 颜色）
要在屏幕解锁后再验。

## 相关

- ADR-0003：被本 ADR 取代的 macOS 方案（render API + HDR10）
- ADR-0006：`prefix-vk` 的 Vulkan 验证路径与 P5 实测
- ADR-0009：Windows 的同一思路（子进程 + IPC）
- `apps/macos/DvPlayer/Sources/DvPlayer/Player/MpvEngine.swift`、`MpvIPC.swift`、
  `PlayerWindow.swift`
