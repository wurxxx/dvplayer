# Windows 壳

.NET 10 + WPF + WPF-UI，`HwndHost` 托管 mpv 子 HWND，`vo=gpu-next`。

## 状态

- **A4 已通过**（2026-11-19，Win11 真机）：官方 mpv 构建 + 子 HWND 嵌播 P7 FEL，
  20 秒 0 掉帧，日志 `dolbyvision` + `[el_pair]`。验证脚本见 `scripts/windows/`。
- **A5 骨架已写**：`DvPlayer.Windows/`（WPF + WPF-UI + `HwndHost` + `--wid`），
  还没在 Windows 上编译过，构建步骤见该目录的 README。

## A4 留下的两个结论

1. DPI：150% 缩放下，宿主进程不声明 DPI-aware 就会裁切（实测 2160×1440@144DPI）。
   WPF 里对应的是 `app.manifest` 声明 `PerMonitorV2`，再由 `HwndHost` 在
   `WM_DPICHANGED` / `WM_SIZE` 时把客户区尺寸推给 mpv 的子窗口。
2. 输入：`--wid` 只解决画面，键盘/鼠标事件不会自动转发进子 HWND。
   正式壳走 mpv IPC（`--input-ipc-server`），由 WPF 发命令，不依赖焦点转发。

## 目录

```
DvPlayer.Windows/          A5 骨架工程（.NET 10 / WPF / WPF-UI）
  MainWindow.xaml          外壳：FluentWindow + TitleBar + 播放区
  Player/MpvHost.cs        子 HWND + DPI/尺寸同步
  Player/MpvProcess.cs     启动 mpv.exe（--wid），日志落盘
  app.manifest             PerMonitorV2
```
