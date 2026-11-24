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

## 播放后端（两套，可切换）

默认走**子进程**，这条路径在真机上验证过 DV P7 FEL：

| 后端 | 实现 | 包体积 | 切换 |
| --- | --- | --- | --- |
| `process`（默认） | `mpv.exe --wid` + 命名管道 IPC | ~112 MB（mpv.exe 116 MB） | — |
| `libmpv` | `libmpv-2.dll` 进程内 + C API | ~45 MB | `DVPLAYER_MPV_BACKEND=libmpv` |

两个后端共用同一份 `MpvLaunch` 和选项集（`Player/MpvProcess.cs` 的 `BuildArgs`
与 `Player/LibMpvProcess.cs` 的 `ApplyOptions` 逐条对应），行为差异只在
"谁来装 mpv"。

| 文件 | 作用 |
| --- | --- |
| `Player/IMpvEngine.cs` | 播放引擎 / 控制通道的抽象，`PlayWindow` 只认接口 |
| `Player/MpvBackend.cs` | 按环境变量选后端，默认 `process` |
| `Player/LibMpv.cs` | libmpv 的 P/Invoke 声明（只声明用到的部分） |
| `Player/LibMpvClient.cs` | 进程内事件泵，属性转成 `JsonElement`（和 IPC 同形状） |
| `Player/LibMpvProcess.cs` | 进程内后端，把命令行选项逐条搬到 `mpv_set_option_string` |

**为什么 `libmpv` 不是默认**：mpv 和壳同进程，mpv 崩了整个 App 一起死；
而且 DV 链路需要在真机上重新回归（`[el_pair]`、`dolbyvision`、0 掉帧）。
`wid` 选项让 mpv 自己画进 HWND，和子进程方案走同一套 gpu-next VO 代码，
所以 DV 处理路径理论上一致，但**没有验证过就不能当默认**。

发布打包用 `-Backend` 选：

```powershell
apps\windows\packaging\build-release.ps1 -Backend libmpv
```
