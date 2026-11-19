# Windows 上的 A4 验证脚本

用官方 Windows mpv 构建（shinchiro `mpv-x86_64`）验证 Dolby Vision Profile 7 FEL
能不能在 `--wid` 子窗口里正确起播。不需要自己编译：官方构建已经带
`sh_dovi_compose_nlq`（FEL 合成）和 gpu-next/D3D11。

## 目录布局

把脚本放到样本同级的目录，mpv 解压成子目录 `mpv\`：

```
D:\dvplayer\
  a4-check.bat          # 本目录
  a4-wid.ps1            # 本目录
  shot.lua              # 本目录
  mpv\mpv.exe           # mpv-x86_64-*.7z 解压到 mpv\
  samples\p7-fel.mkv
```

## 跑什么

1. `a4-check.bat`：mpv 自管窗口，播 7–11 秒，第 8 秒截图。
   验证 DV 链路本身（splitter、EL 配对、gpu-next）。
2. `a4-wid.ps1`：WinForms 父窗口 + `mpv --wid`，播 20 秒。
   验证外部 HWND 托管，这是 A4 的断言部分。

```powershell
powershell -ExecutionPolicy Bypass -File D:\dvplayer\a4-wid.ps1
# 样本不在 samples\ 下时：
powershell -ExecutionPolicy Bypass -File D:\dvplayer\a4-wid.ps1 -Root D:\dvplayer
```

## 日志里该出现的行

```
[mkv] Dolby Vision Profile 7 splitter: BL stream 0, virtual EL stream 1 (dependent_track).
[vf] [el_pair] 3840x2160 yuv420p10 dolbyvision/bt.2020/pq/limited/display ...
VO: [gpu-next] 3840x2160 yuv420p10
```

再加第二个 `Opening decoder hevc`（EL 独立解码，1920×1080）。

## DPI 的坑（A5 的输入）

第一次跑 `--wid` 时画面被裁切、不居中。原因不是 mpv：PowerShell 进程默认
不是 DPI-aware，150% 缩放下 Windows 虚拟化客户区坐标，mpv 却按物理像素渲染。
修法是三件事一起做：

- 建窗口**之前**调 `SetProcessDPIAware()`（WinForms 只有 `Application.SetHighDpiMode`
  在高 DPI 模式下才可靠，直接 P/Invoke 最稳）；
- `AutoScaleMode = None`，别再让 WinForms 缩放一次；
- 用 `ClientSize`（客户区）而不是 `Width/Height`（含标题栏）。

WPF 壳里等价的做法是在 `HwndHost` 里处理 `WM_DPICHANGED`，拿到
`SuggestedRect` 后自己 `SetWindowPos` 子 HWND，不能只依赖 WPF 的布局系统。

## 已知情况

- 这台机器（Intel Iris Xe，D3D11 FL 12_1）走纯软解：日志里两次
  `DR failed - disabling`、`No hardware decoding requested`，4K24 仍然实时。
  想省电可以加 `--hwdec=auto-safe` 试 QSV。
- 截图模板不带 `%n` 时文件名是 `a4.png`，不是 `a4-0001.png`；已存在时 mpv
  会报 `Can't save screenshot, file ... already exists!`。
- 样本是 16:9 容器 + 内嵌 2.39 黑边，所以画面上下有黑边是正常的；
  `crop=3840x2160+0+0` 说明播放器没有裁切。
