# DVPlayer

跨平台原生播放器（macOS / Windows / Android / Android TV）。三个目标：

1. **格式覆盖**：主流编码与 HDR 格式都能解、能正确呈现——HEVC / H.264 / AV1 / VP9、
   Dolby Vision（P5 / P7 / P8，其中 P7 双层 BL+EL+RPU 完整重建）、HDR10 / HDR10+ / HLG、
   DTS-HD / TrueHD / Atmos 直通、PGS / ASS 字幕；设备做不到的明确降级，不装支持。
2. **资源库整合**：飞牛影视、Emby、Jellyfin、Plex，以及 SMB / NFS / WebDAV 目录，
   统一接入、统一浏览、统一播放。
3. **聚合搜索**：一次搜索覆盖所有已接入的源，播放记录与续播点合并展示。

当前阶段：**M1 — Windows Alpha 进行中**。底层能力见 [docs/M0.md](docs/M0.md)（已完成），
产品进度见 [docs/M1.md](docs/M1.md)。

## 能力现状

- 格式：Windows 上已验 4K120 / 8K60 硬解、HDR10 / HDR10+ / HLG 元数据、
  DV P7 FEL 完整重建；矩阵与边界见 [docs/DECODE.md](docs/DECODE.md) 和 [docs/M0.md](docs/M0.md)
- 媒体库：飞牛影视已打通（登录、媒体库、剧集 / 季 / 集、未刮削目录、详情页、海报）；
  Emby / Jellyfin 适配器已写完（共用一份实现），还差真实服务器联调；
  Plex / 目录源排在后面
- 聚合：`MediaHub` 已落地——多个源同时连、条目 id 统一成 `<sourceId>:<itemId>`、
  媒体库与播放记录合并展示；合并搜索与跨源去重还没做，
  设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §1.2
- 适配器文档：[docs/FNOS-API.md](docs/FNOS-API.md)、[docs/EMBY-API.md](docs/EMBY-API.md)
- 播放：Windows 用 mpv 子进程挂 `wid`，`gpu-next` + `d3d11va`，DV P7 FEL 走官方构建
- 续播：进度回写到服务器，详情页「继续观看 第 N 集」
- 共享核心：`core/media`（Rust + C ABI），媒体库逻辑只写一次，四端复用

## 目录

```
docs/            计划、架构、ADR、M0 / M1 记录
deps/            依赖钉版本
scripts/         preflight / 拆层 / FEL A-B / Windows 构建与验证
core/media/      共享媒体库核心（Rust，C ABI）
core/mpv/        libmpv 封装（C++，占位，macOS 路线用）
core/dovi/       libdovi 封装（占位）：RPU / EL 类型
apps/windows/DvPlayer/         正式壳：媒体库客户端（.NET 10 + WPF-UI）
apps/windows/DvPlayer.Windows/ M0 验证壳：HwndHost / IPC / DV 徽标（保留参考）
apps/macos/      SwiftUI + AppKit（M0 验证程序 m0-render）
apps/android/    Kotlin + Compose for TV（未开始）
samples/         测试片源（不入库）
out/             运行产物（不入库）
```

## 快速开始

### Windows 客户端

见 [docs/BUILD-WINDOWS.md](docs/BUILD-WINDOWS.md)：

```powershell
scripts\windows\build-core.ps1                       # Rust 核心 → dvplayer_media.dll
dotnet build apps\windows\DvPlayer -c Release        # WPF 壳
```

首次启动在「设置」里填服务器地址、用户名、密码，之后自动登录。

### macOS（M0 验证环境）

```bash
./scripts/build-deps-macos.sh   # 首次：构建 mpv/FFmpeg/libplacebo 到 prefix/
./scripts/preflight.sh
```

工具链齐全后：

```bash
./scripts/split-el.sh /path/to/p7-fel.mkv
./scripts/fel-ab.sh /path/to/p7-fel.mkv 60
```
