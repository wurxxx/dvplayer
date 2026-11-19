# DVPlayer

跨平台原生播放器（macOS / Windows / Android / Android TV），桌面端目标是把
Dolby Vision Profile 7 双层（BL + EL + RPU）完整重建，包括 FEL。

当前阶段：**M1 — Windows Alpha 进行中**。底层能力见 [docs/M0.md](docs/M0.md)（已完成），
产品进度见 [docs/M1.md](docs/M1.md)。

## 能力现状

- 媒体库：飞牛影视已打通（登录、媒体库、剧集 / 季 / 集、未刮削目录、详情页、海报）；
  Emby 适配器待接（`MediaSource` trait 已就位，加一个文件即可）
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
