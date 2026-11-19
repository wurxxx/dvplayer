# DVPlayer

跨平台原生播放器（macOS / Windows / Android / Android TV），桌面端目标是把
Dolby Vision Profile 7 双层（BL + EL + RPU）完整重建，包括 FEL。

当前阶段：**M0 技术验证**。进度见 [docs/M0.md](docs/M0.md)。

## 目录

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

## 快速开始

```bash
./scripts/build-deps-macos.sh   # 首次：构建 mpv/FFmpeg/libplacebo 到 prefix/
./scripts/preflight.sh
```

工具链齐全后：

```bash
./scripts/split-el.sh /path/to/p7-fel.mkv
./scripts/fel-ab.sh /path/to/p7-fel.mkv 60
```
