# DVPlayer 项目计划

> 状态：M0 完成（仅 A6 待真机）；M1（Windows Alpha）收尾；M2（macOS 壳）浏览链路已通，播放页未开始。最后更新：2026-11-20。

## 1. 目标

做一个跨 macOS、Windows、Android、Android TV 的原生播放器，三条并列主线：

1. **格式覆盖**——市面上绝大部分编码与 HDR 格式都能解、能正确呈现：
   HEVC / H.264 / AV1 / VP9、Dolby Vision（P5 / P7 / P8）、HDR10 / HDR10+ / HLG、
   DTS-HD / TrueHD / Atmos 直通、PGS / ASS 字幕。
   设备做不到的要**明确降级并说明**（例如"这台机器只能播 BL"），不能黑屏、花屏或假装支持。
2. **资源库整合**——飞牛影视、Emby、Jellyfin、Plex，以及 SMB / NFS / WebDAV 目录，
   统一接入、统一浏览、统一播放。新增一种源只写一个适配器，界面不动（ADR-0008）。
3. **聚合搜索与统一进度**——一次搜索覆盖所有已接入的源，播放记录与续播点合并展示，
   同一部片在多个源里出现时按规则去重、选最优的一路播。

Dolby Vision P7 FEL 仍是桌面端的硬指标（它是格式覆盖里最难的一格），但不再是唯一目标。

> 2026-11-19 调整：原目标只写「DV P7 FEL 完整重建」，是单点突破的思路；
> 实际产品要解决的是「什么都能放 + 片源都在一个界面里」，因此扩成上面三条。

### 1.1 资源库接入范围

| 源 | 协议 | 状态 | 备注 |
| --- | --- | --- | --- |
| 飞牛影视（fnOS Media） | 原生 `/v/api/v1` + authx 签名 | **已接入** | 见 [FNOS-API.md](FNOS-API.md) |
| Emby | `/Users/*` + `X-Emby-Token` | **适配器已完成，待联调** | 见 [EMBY-API.md](EMBY-API.md) |
| Jellyfin | 与 Emby 同源 | **适配器已完成，待联调** | 与 Emby 共用 `emby.rs`，只多认一个 `Authorization` 头 |
| Plex | `/library/*` + `X-Plex-Token` | 未开始 | 需要独立适配器 |
| SMB / NFS / WebDAV | 系统挂载 + 本地扫描 | **已接入**（macOS 实测 SMB 全链路；Windows 已编译通过，SMB 表单与失败回显已验） | 无刮削，按 `SxxExx` / `第 N 集` 认集号；挂载后复用本地文件夹源，见 [LOCAL-SOURCE.md](LOCAL-SOURCE.md) §6 |

同一部片出现在多个源时怎么选、搜索怎么合并，见
[ARCHITECTURE.md](ARCHITECTURE.md) §1.2。

## 2. 已定技术路线

| 平台 | UI | 视频面 | 播放内核 | 格式能力 |
| --- | --- | --- | --- | --- |
| Windows | .NET 10 + WPF + WPF-UI | mpv 子 HWND（`wid`），mpv 自管 swapchain | 官方 `mpv.exe` 子进程 + JSON IPC（ADR-0009，`vo=gpu-next`） | DV P7 FEL 完整；HDR10 / HDR10+ / HLG；硬解看 GPU（已验 4K120 / 8K60） |
| macOS | SwiftUI + AppKit | mpv 自己的窗口（cocoa-cb + Vulkan），壳贴透明浮层 | `mpv` 子进程 + JSON IPC（ADR-0010，行内 Vulkan loader + MoltenVK） | gpu-next：DV P5/P7、HDR10；解码走 VideoToolbox；进度见 [M2-MACOS.md](M2-MACOS.md) |
| Android / TV | Kotlin + Compose for TV | SurfaceView / SurfaceTexture | Media3 (ExoPlayer) | 取决于设备解码器；DV 按机型，P7 回退 BL 并标注 |

关键结论（详见 ADR）：

- 桌面端**零 fork**，不维护 libmpv 私有补丁。
- Windows 走 `wid` 子窗口，因为 mpv 0.42 的 gpu-next（FEL 所在）只在播放器自己的 VO 路径上，
  libmpv 的 render API 仍然只有 legacy `gpu` 后端。
- macOS 的 `--wid` 不可靠，render API 又只有 legacy `gpu`，所以改成「mpv 自己开窗口 +
  透明浮层窗」，Vulkan/MoltenVK 随包分发（ADR-0010）。
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

| 里程碑 | 范围 | 状态 |
| --- | --- | --- |
| M0 技术验证 | FEL 重建 / Windows `wid` / macOS render API / 解码与蓝光 | **完成**，A6（Android 真机）待设备 |
| M1 Windows Alpha | 多源接入（飞牛 + Emby）、聚合搜索、播放与续播、打包 | **进行中**，清单见 [M1.md](M1.md) |
| M2 Android / TV | Media3 管线、格式矩阵（DV 探测与回退）、TV 焦点 | 未开始 |
| M3 macOS | render 全链路、HDR10 呈现、公证与 Sparkle | 未开始（M0 已验到出画） |
| M4 共性层 | 跨端播放记录同步、元数据缓存 | 未开始（共享核心已提前在 M1 落地） |

### 解码与呈现能力矩阵（横跨 M1–M3，不是独立里程碑）

格式覆盖是一条贯穿三端的线，用矩阵驱动，验证记录写在 [DECODE.md](DECODE.md)：

| 能力 | Windows | macOS | Android / TV |
| --- | --- | --- | --- |
| HEVC / H.264 硬解 | **已验**（4K/8K、120 fps） | 待验 | 待验 |
| AV1 / VP9 | 待验 | 待验 | 待验 |
| DV P7（FEL） | **已验** | 不支持（v1） | 回退 BL |
| DV P5 / P8 | 部分验（P5 颜色待修，见 M0 §5.3） | 不支持 | 待验 |
| HDR10 / HDR10+ / HLG 识别 | **已验**（元数据正确） | 待验 | 待验 |
| HDR 直通到 HDR 屏 | 待验（本机 SDR 屏） | 待验 | 待验 |
| 音频直通（DTS-HD / TrueHD / Atmos） | 未做 | 未做 | 未做 |
| PGS / ASS 字幕 | 未验 | 未验 | libass NDK 未做 |

### M0 — 技术验证（完成）

证明三件事：

1. FEL 真的被重建（截帧 A/B + PSNR），不是只播 BL。
2. Windows 的 `wid` 子窗口路径能起播、能拿到 FEL。
3. macOS 的 Vulkan 路径能正确输出（P5 颜色、HDR10 或退 SDR）。

验收标准与执行记录见 [M0.md](M0.md)。

### M1 — Windows Alpha（进行中）

对应主线 2 与 3 的第一版：飞牛 + Emby 双源、跨源合并搜索、合并播放记录与续播；
播放/暂停/seek/轨道/字幕/音频设备与直通/HDR 开关/全屏/快捷键；
MSIX 打包与自动更新。Jellyfin / Plex / 目录源排在 Emby 之后。

共享层见 ADR-0008：媒体库逻辑在 `core/media`（Rust），三端只做界面。

进度（详见 [M1.md](M1.md)）：

- 已完成：飞牛接入、库 → 剧集 → 季 → 集、剧集详情页、未刮削目录当剧集、
  mpv 播放与硬解、进度回写与续播、播放记录、图片缓存、基本键位；
- 未开始：Emby 适配器、多源聚合与合并搜索、音轨/字幕面板、
  音频直通/HDR/全屏、MSIX 打包与自动更新。

### M2 — Android / TV Alpha

Media3 管线、DV 探测与回退、TV 焦点与 Leanback、下载与续播、libass NDK。

### M3 — macOS

mpv 子进程 + 浮层窗全链路（ADR-0010）、DV / HDR10 或 SDR 回退、公证与 Sparkle。

### M4 — 共性层

跨端同步（播放记录、收藏、续播点）、元数据缓存与服务端聚合搜索。
「Rust 共享媒体库」已经提前在 M1 落地（ADR-0008），这里不再重复。

## 5. 非目标（v1）

- Linux、iOS
- DV 编码 / 制作
- 服务端转码
- 跨端媒体库同步（推迟到 M4）

## 6. 风险登记

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| libmpv render API 无 gpu-next | 进程内嵌入拿不到 DV/FEL | 两端都改用 mpv 子进程 + IPC，让 mpv 自己建 VO（ADR-0009 / ADR-0010） |
| libplacebo / FFmpeg soname 变动 | 升级即崩 | vendored 固定版本，不依赖系统库 |
| macOS 无 OpenGL 的 GPU context | 进程内渲染不可行 | 走 Vulkan/macvk + gpu-next（ADR-0010） |
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
| ADR-0006 | macOS Vulkan 验证路径 |
| ADR-0007 | 正式壳是媒体库聚合客户端（M0 壳只做验证） |
| ADR-0008 | 共享媒体库核心：Rust + C ABI，四端复用 |
| ADR-0009 | Windows 改用 mpv 子进程 + JSON IPC（修正 ADR-0001 的备选判断） |
| ADR-0010 | macOS 改用 mpv 子进程 + 透明浮层窗（取代 ADR-0003，拿到 DV） |

## 8. 目录结构

```
docs/            计划、架构、ADR、M0 / M1 记录
deps/            依赖钉版本
scripts/         preflight / 拆层 / FEL A-B / Windows 构建与验证
core/media/      共享媒体库核心（Rust，C ABI）：飞牛 / Emby 适配器
core/mpv/        libmpv 封装（C++，已放弃：两端都改 mpv 子进程，见 ADR-0009 / 0010）
core/dovi/       libdovi 封装（占位）：RPU / EL 类型
apps/windows/DvPlayer/         正式壳：媒体库客户端（.NET 10 + WPF-UI）
apps/windows/DvPlayer.Windows/ M0 验证壳：HwndHost / IPC / DV 徽标（保留参考）
apps/macos/      SwiftUI + AppKit（M0 验证程序 m0-render）
apps/android/    Kotlin + Compose for TV（未开始）
samples/         测试片源（不入库）
out/             运行产物（不入库）
```
