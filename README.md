# DVPlayer

跨平台原生播放器（macOS / Windows / Android / Android TV）。三个目标：

1. **格式覆盖**：主流编码与 HDR 格式都能解、能正确呈现——HEVC / H.264 / AV1 / VP9、
   Dolby Vision（P5 / P7 / P8，其中 P7 双层 BL+EL+RPU 完整重建）、HDR10 / HDR10+ / HLG、
   DTS-HD / TrueHD / Atmos 直通、PGS / ASS 字幕；设备做不到的明确降级，不装支持。
2. **资源库整合**：飞牛影视、Emby、Jellyfin、Plex，以及 SMB / NFS / WebDAV 目录，
   统一接入、统一浏览、统一播放。
3. **聚合搜索**：一次搜索覆盖所有已接入的源，播放记录与续播点合并展示。

当前阶段：**M2 — 桌面端持续迭代**：macOS / Windows 已发布 0.1.6，浏览、播放、Trakt、
更新检查都已可用；剩 Jellyfin 12.x 真机、Plex 适配器，以及需要 HDR 屏 /
AVR 的目视与听感验收；Android / TV 进行中。底层能力见 [docs/M0.md](docs/M0.md)，
产品进度与剩余工作见 [docs/PLAN.md](docs/PLAN.md) §4–§5、[docs/M1.md](docs/M1.md)。

## 能力现状

- 格式：Windows 上已验 4K120 / 8K60 硬解、HDR10 / HDR10+ / HLG 元数据、
  DV P7 FEL 完整重建；矩阵与边界见 [docs/DECODE.md](docs/DECODE.md) 和 [docs/M0.md](docs/M0.md)
- 媒体库：飞牛影视已打通（登录、媒体库、剧集 / 季 / 集、未刮削目录、详情页、海报）；
  Emby 已实测（4.9.3 实例，含播放直链与进度回写），Jellyfin 独立适配器、
  10.8.12 全链路实测（12.x 待真机）；本地文件夹与 SMB / NFS / WebDAV 目录源已接
  （系统挂载后复用本地扫描）；Plex 未开始
- 聚合：`MediaHub` 已落地——多个源同时连、条目 id 统一成 `<sourceId>:<itemId>`、
  媒体库与播放记录合并展示；搜索各源并发、跨源去重，选源在详情页「资源」里做，
  设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §1.2
- 适配器文档：[docs/FNOS-API.md](docs/FNOS-API.md)、[docs/EMBY-API.md](docs/EMBY-API.md)
- 播放：Windows 用 mpv 子进程挂 `wid`，`gpu-next` + `d3d11va`，DV P7 FEL 走官方构建；
  macOS 用进程内 libmpv + render API（`gpu-next` + OpenGL）画进自己的窗口，控制浮层
  叠在同一窗口里，DV 走同一条整形路径
  （[ADR-0011](docs/adr/0011-macos-libmpv-inprocess.md)）
- 两端对齐的功能：断点续播、自动接下一集、蓝光原盘、进度条三层 + 缓冲大小、
  弹幕 / 片头片尾 / 定时关闭 / 画面比例 / 字幕搜索、窄窗单行控制条、
  Trakt 观看记录（评分 / 收藏 / 待看）、启动检查更新
- 续播：进度回写到服务器，详情页「继续观看 第 N 集」；电影在别的源或 Trakt 上
  进度更远时，按较长的那条续播
- 共享核心：`core/media`（Rust + C ABI），媒体库逻辑只写一次，四端复用

## 目录

```
docs/            计划、架构、ADR、M0 / M1 记录
deps/            依赖钉版本
scripts/         preflight / 拆层 / FEL A-B / Windows 构建与验证
core/media/      共享媒体库核心（Rust，C ABI）
core/mpv/        libmpv 封装（C++，已放弃：两端都改 mpv 子进程，见 ADR-0009 / 0010）
core/dovi/       libdovi 封装（占位）：RPU / EL 类型
apps/windows/DvPlayer/         正式壳：媒体库客户端（.NET 10 + WPF-UI）
apps/windows/DvPlayer.Windows/ M0 验证壳：HwndHost / IPC / DV 徽标（保留参考）
apps/macos/      SwiftUI + AppKit：正式客户端 DvPlayer + M0 验证程序 m0-render（留档）
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

### macOS 客户端

```bash
cd core && ~/.cargo/bin/cargo build -p dvplayer-media --release && cd ..

./scripts/build-deps-macos.sh   # 首次：FFmpeg / libass / libplacebo / mpv 到 prefix/

cd apps/macos/DvPlayer && ./build.sh && open build/DvPlayer.app
```

`build.sh` 会把 mpv、libplacebo、共享核心和它们的 Homebrew 依赖一起打进
`.app/Contents/Frameworks`，换台机器也能直接跑（不用装 Homebrew）。
详见 [docs/M2-MACOS.md](docs/M2-MACOS.md)。

弹幕（弹弹play）的 AppId / AppSecret 不打进仓库，也不在设置里填：打包时从
`~/.config/dvplayer/danmaku.env` 注入产物，详见 [docs/SECRETS.md](docs/SECRETS.md)。

DV / FEL 的验证脚本（走产品同一份 mpv + render API）：

```bash
./scripts/split-el.sh /path/to/p7-fel.mkv
./scripts/fel-ab.sh /path/to/p7-fel.mkv 60
```
