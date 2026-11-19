# DVPlayer 项目计划

> 状态：M0 进行中。最后更新：2026-11-19。

## 1. 目标

做一个跨 macOS、Windows、Android、Android TV 的原生播放器。

桌面端的核心差异点是 **Dolby Vision Profile 7 双层（BL + EL + RPU）的完整重建**，
包含 FEL（Full Enhancement Layer）——不是丢掉 EL 只播 BL，也不是转 P8.1。

## 2. 已定技术路线

| 平台 | UI | 视频面 | 播放内核 | DV 能力 |
| --- | --- | --- | --- | --- |
| Windows | .NET 10 + WPF + WPF-UI | mpv 子 HWND（`wid`），mpv 自管 swapchain | libmpv（`vo=gpu-next`） | P7 FEL 完整 |
| macOS | SwiftUI + AppKit | libmpv render API + NSOpenGLView | libmpv（legacy `gpu`） | v1 仅 HDR10 |
| Android / TV | Kotlin + Compose for TV | SurfaceView / SurfaceTexture | Media3 (ExoPlayer) | 依赖设备，P7 回退 |

关键结论（详见 ADR）：

- 桌面端**零 fork**，不维护 libmpv 私有补丁。
- Windows 走 `wid` 子窗口，因为 mpv 0.42 的 gpu-next（FEL 所在）只在播放器自己的 VO 路径上，
  libmpv 的 render API 仍然只有 legacy `gpu` 后端。
- macOS 的 `--wid` 不可靠，因此 macOS 走 render API，代价是拿不到 DV，v1 只做 HDR10。
- WinUI 3 被排除：WinUI 3 窗口内的子 HWND 收不到输入（microsoft-ui-xaml#9912），
  与 `wid` 方案冲突。

## 3. 依赖

| 依赖 | 版本 | 用途 |
| --- | --- | --- |
| mpv | 0.42.x | 桌面播放内核，gpu-next 提供 P7 增强层 |
| FFmpeg | 9.0.x | `dovi_split` 拆 BL/EL；DV stream group |
| libplacebo | 7.387.x | FEL 残差重建（`pl_frame.enhancement_layer`） |
| libdovi | 最新稳定 | RPU 解析、FEL/MEL 判定 |
| libass | 最新稳定 | ASS 特效字幕 |
| Media3 | 当前稳定线 | Android / TV 播放内核 |

版本钉在 `deps/pins.env`。M0 已经开始 vendored 构建（`scripts/build-deps-macos.sh`
把 FFmpeg / libplacebo / libass / mpv 全部装进项目内 `prefix/`），不依赖系统库。

## 4. 里程碑

### M0 — 技术验证（进行中）

证明三件事：

1. FEL 真的被重建（截帧 A/B + PSNR），不是只播 BL。
2. Windows 的 `wid` 子窗口路径能起播、能拿到 FEL。
3. macOS 的 render API 能正确输出（HDR10 或退 SDR）。

验收标准与执行记录见 [M0.md](M0.md)。

### M1 — Windows Alpha

媒体库客户端：飞牛影视 / Emby 双源、合并搜索、播放记录与续播；
播放/暂停/seek/轨道/字幕/音频设备与直通/HDR 开关/全屏/快捷键；
MSIX 打包与自动更新。

共享层见 ADR-0008：媒体库逻辑在 `core/media`（Rust），三端只做界面。

### M2 — Android / TV Alpha

Media3 管线、DV 探测与回退、TV 焦点与 Leanback、下载与续播、libass NDK。

### M3 — macOS

render API 全链路、HDR10 或 SDR 回退、公证与 Sparkle。

### M4 — 共性层

Rust 共享媒体库 / 元数据 / 续播，收敛三端逻辑。

## 5. 非目标（v1）

- Linux、iOS
- DV 编码 / 制作
- 服务端转码
- 跨端媒体库同步（推迟到 M4）

## 6. 风险登记

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| libmpv render API 无 gpu-next | 桌面嵌入拿不到 DV/FEL | Windows 用 `wid`；macOS 接受 v1 无 DV |
| libplacebo / FFmpeg soname 变动 | 升级即崩 | vendored 固定版本，不依赖系统库 |
| macOS 无 Metal 后端 | HDR/EDR 效果受限 | v1 只做 HDR10，DV 延后 |
| Android DV 碎片化 | 同 APK 行为不一致 | 运行时探测 + BL 回退 + 明确提示 |
| 编解码专利 + Dolby 授权 | 商业分发风险 | 商业版走 Dolby 官方 SDK 或法务评估 |
| Intel Mac 无 HDR 显示器 | macOS HDR 无法目视验收 | 外接 HDR 屏或先验 SDR 映射 |

## 7. 决策记录

| 编号 | 决策 |
| --- | --- |
| ADR-0001 | 桌面嵌入：mpv 自管窗口，零 fork |
| ADR-0002 | Windows 壳：.NET 10 + WPF + WPF-UI |
| ADR-0003 | macOS v1：render API + HDR10，不含 DV |
| ADR-0004 | Android：Media3 主 + libass NDK |
| ADR-0005 | 徽标：DV P7 (FEL/MEL) 明确区分 |

## 8. 目录结构

```
docs/            计划、架构、ADR、M0 记录
deps/            依赖钉版本
scripts/         preflight / 拆层 / FEL A-B / 构建
core/mpv/        libmpv 封装（C++），桌面共享
core/dovi/       libdovi 封装：RPU / EL 类型
apps/windows/    .NET 10 + WPF
apps/macos/      SwiftUI + AppKit
apps/android/    Kotlin + Compose for TV
samples/         测试片源（不入库）
out/             运行产物（不入库）
```
