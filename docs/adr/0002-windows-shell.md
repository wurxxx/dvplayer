# ADR-0002 Windows 壳：.NET 10 + WPF + WPF-UI

- 状态：已接受
- 日期：2026-11-19

## 背景

Windows 端需要把 mpv 的子 HWND 嵌进原生窗口布局，同时要一个足够现代的 UI。

## 决策

- 运行时：.NET 10
- 框架：WPF（`HwndHost` 托管视频子窗口）
- 样式：WPF-UI 4.x（Fluent 2 控件、Mica、NavigationView、对话框）+
  官方 Fluent 资源

## 理由

- `HwndHost` 是 WPF 原生能力，专为托管子 HWND 设计，和 `wid` 方案天然匹配。
- WinUI 3 被排除：WinUI 3 窗口内的 `WS_CHILD` 子窗口收不到鼠标/键盘
  （microsoft-ui-xaml#9912），与 `wid` 冲突。
- WPF-UI 提供足够的现代外观，避免从零写控件模板。

## 后果

- airspace 限制：XAML 不能覆盖视频区域，控制条放视频外。
- 动画流畅度不如 WinUI 3 的 composition，需要克制使用阴影/模糊。
- 视频区只是一个矩形洞，设计的重点放在媒体库、详情页、设置页。
