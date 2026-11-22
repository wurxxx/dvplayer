# Windows 上的 A4 验证脚本

## 远程驱动（SSH，当前在用）

笔记本装了 Win32-OpenSSH 10.4，`sshd` 开机自启，Mac 的 ed25519 公钥已经写进
`C:\ProgramData\ssh\administrators_authorized_keys`（`ssh-setup.bat` 干的）。

```bash
sh scripts/windows/wssh.sh 'Get-Date'     # 远程跑 PowerShell，base64 传参、UTF-8 输出
scp -i ~/.ssh/dvplayer_win a.zip wucl@192.168.194.3:D:/dvplayer/
```

SSH 会话在 session 0，GUI 起在那里你看不见。要跑带窗口的东西，用计划任务在
交互会话里起：

```powershell
schtasks /create /tn verify-a5 /tr "powershell -NoProfile -File D:\dvplayer\setup\verify-a5.ps1" /sc once /st 00:00 /it /f
schtasks /run /tn verify-a5
```

| 脚本 | 作用 |
| --- | --- |
| `ssh-setup.bat` | 装 OpenSSH MSI、开机自启、放行 22、写入 Mac 公钥（一次双击） |
| `wssh.sh` | Mac 侧跑远程 PowerShell |
| `run-a5.ps1` | 计划任务：启动 exe、播样本、抓屏、拷 mpv.log、退出 |
| `verify-a5.ps1` | 计划任务：抓 HWND/矩形/DPI、按 F11、改尺寸、三张截图 |
| `verify-ipc.ps1` | 计划任务：连 mpv 命名管道读时间/时长/暂停/DV 轨道，改暂停、跳转，按 Space，截图 |
| `verify-window.ps1` | 计划任务：`PrintWindow` 抓窗口自身（不受屏幕位置影响） |
| `decode-check.ps1` | 计划任务：纯解码吞吐（`--untimed --vo=null`）+ 实时播放日志 |
| `decode-ipc.ps1` | 计划任务：壳 + IPC，读分辨率/硬解/色彩元数据（`DVPLAYER_FILE` 指定样本） |
| `decode-render.ps1` | 计划任务：真实 gpu-next 窗口 + `--untimed`，测渲染吞吐 |
| `decode-tune.ps1` | 计划任务：缩放器对比（`--scale=bilinear` / `lanczos`） |
| `probe-hdr10plus.ps1` | 计划任务：播放 HDR10+ 样本并抓 gpu-next 日志 |

> PowerShell 5.1 按 ANSI 解析无 BOM 的 `.ps1`，中文注释会把引号弄坏。
> 这些脚本一律写成纯 ASCII。

## 下面的 A4 脚本可以单独跑，不依赖 Mac

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
