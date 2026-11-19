# DvPlayer.Windows（A5 骨架）

.NET 10 + WPF + WPF-UI 的外壳，视频区是 `Player/MpvHost`（一个 `HwndHost`），
里面跑**官方 Windows mpv**（`--wid`），所以 DV P7 FEL 的拆层/合成/整形能力
和 A4 验证过的完全一致，不需要私有补丁。

```
MainWindow.xaml        FluentWindow + TitleBar + 播放区 + 底部控制条
Player/MpvHost.cs      创建子 HWND 交给 mpv；同步尺寸；PerMonitorV2 DPI
Player/MpvProcess.cs   启动 mpv.exe、收日志到 %LOCALAPPDATA%\dvplayer\mpv.log
app.manifest           dpiAwareness = PerMonitorV2（A4 的教训）
```

## 先决条件（Windows）

1. **.NET 10 SDK**：`dotnet --list-sdks` 里要有 `10.x`。
2. **mpv**：shinchiro 的 `mpv-x86_64-*.7z`，解压成 `mpv\mpv.exe`。
3. 样本：`D:\dvplayer\samples\p7-fel.mkv`（或启动后拖进来）。

mpv 的查找顺序：`DVPLAYER_MPV` 环境变量 → exe 旁边的 `mpv\mpv.exe` →
`D:\dvplayer\mpv\mpv.exe`。

## 构建与运行

发布包 `dvplayer-a5.zip` 已经带好 `packages\`（WPF-UI 4.3.0 + Abstractions 的 nupkg）和
`NuGet.config`，restore **不需要联网**。解压到 `D:\dvplayer`（保持 `apps\windows\` 这层路径）：

```powershell
cd D:\dvplayer\apps\windows\DvPlayer.Windows
dotnet --list-sdks          # 应该有 10.0.x
dotnet build -c Release
.\bin\Release\net10.0-windows\DvPlayer.Windows.exe
```

mpv 不用复制：`MpvProcess` 会按 `DVPLAYER_MPV` → exe 旁边 `mpv\mpv.exe` →
`D:\dvplayer\mpv\mpv.exe` 的顺序找。样本默认是
`D:\dvplayer\samples\p7-fel.mkv`，启动后自动播；拖别的文件进去也能播。

> ⚠️ 这份骨架是在 macOS 上写的，**没有编译过**（本机没有 .NET SDK）。
> 第一次在 Windows 上跑如果报编译错误，把错误贴回来，我照着改。

## A5 要验什么

| 项 | 做法 | 预期 |
| --- | --- | --- |
| DPI | 150% 缩放 / 跨屏拖到不同缩放的显示器 | 画面铺满、不裁切；mpv 子窗口跟着变 |
| 全屏 | F11 / Esc | 无黑边残留、无闪黑、鼠标不动时控制条可隐藏（待做） |
| 多显示器 | 拖到第二块屏 | 不黑屏，UI 尺寸正确 |
| 起播 | 自动播 `D:\dvplayer\samples\p7-fel.mkv` | 日志 `[el_pair]` + `VO: [gpu-next]`，0 掉帧 |

## 已知待做

- 控制条还没做自动隐藏、进度条、音轨/字幕选择；这些不是 A5 的判据。
- 键盘快捷键现在靠 mpv 自己的默认绑定（点视频后焦点在 mpv 子窗口）。
  正式的壳建议走 mpv IPC（`--input-ipc-server=\\.\pipe\...`），
  由 WPF 发命令，避免依赖焦点转发。
- `--hwdec=auto-safe` 已经加上；A4 时是纯软解，4K24 也能实时。
