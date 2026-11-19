# Windows 壳

计划：.NET 10 + WPF + WPF-UI，`HwndHost` 托管 mpv 子 HWND，`vo=gpu-next`。

## 状态

- **A4 已通过**（2026-11-19，Win11 真机）：官方 mpv 构建 + 子 HWND 嵌播 P7 FEL，
  20 秒 0 掉帧，日志 `dolbyvision` + `[el_pair]`。验证脚本见 `scripts/windows/`。
- **A5 待做**：WPF `HwndHost` 的 DPI、全屏、多显示器。

## A4 留下的两个结论

1. DPI：150% 缩放下，宿主进程不声明 DPI-aware 就会裁切（实测 2160×1440@144DPI）。
   WPF 里对应的是在 `HwndHost` 处理 `WM_DPICHANGED`，拿 `SuggestedRect`
   自己 `SetWindowPos` 子 HWND。
2. 输入：`--wid` 只解决画面，键盘/鼠标事件不会自动转发进子 HWND，
   壳要自己转发（A5 一起做）。

## A5 骨架要点

- `HwndHost` 子类，`BuildWindowCore` 里创建宿主 HWND（而不是让 mpv 建窗口），
  再用 `--wid` 交给 mpv；或直接用 libmpv 的 `wid` 选项 + render API。
  首版走前者：`mpv.exe` 进程 + `--wid`，与 A4 一致。
- 监听 `WM_DPICHANGED`、`WM_SIZE`，同步 mpv 子窗口的客户区尺寸。
- `WndProc` 转发 `WM_KEYDOWN/UP`、`WM_MOUSEMOVE`、`WM_LBUTTONDOWN/UP`、
  `WM_MOUSEWHEEL`。
- 全屏：`WindowStyle=None` + `WindowState=Maximized`，不要用独占全屏。
