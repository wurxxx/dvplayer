# ADR-0001 桌面嵌入：mpv 自管窗口，零 fork

- 状态：已接受
- 日期：2026-11-19

## 背景

mpv 0.42 的 Dolby Vision P7 增强层（FEL）实现在 `vo_gpu_next` 上。
libmpv 的 render API 仍然只有 legacy `gpu` 后端（上游 issue #10810 未解决，
PR #16818 与 RFC #18607 都未合并）。用 render API 嵌入会丢掉 DV：P5 颜色错误、
P7 只剩 BL。

## 决策

不维护 libmpv fork：

- **Windows**：给 mpv 一个子 HWND（`wid`），由 mpv 自己创建 VO 和 swapchain，
  走 `vo=gpu-next` 拿到 FEL。
- **macOS**：`--wid` 不可靠，使用上游 render API（legacy `gpu`），
  v1 不承诺 DV，只做 HDR10。

## 后续

- 2026-11-19：Windows 的落地手段改为「官方 mpv.exe 子进程 + `--wid` + JSON IPC」，
  见 [ADR-0009](0009-windows-mpv-subprocess.md)。总体路线（mpv 自管窗口、零 fork、
  macOS 走 render API）不变。

## 后果

- Windows 上 XAML 无法叠加在视频子窗口上（airspace），控制条必须放在视频外；
  覆盖层留到 v2（layered window 或 mpv OSD）。
- macOS 没有 DV，也没有 Metal 路径；HDR10 需要实机验证。
- 两个平台的实现路径不同，C++ 封装要同时支持 `WindowBinding` 和 `RenderApi`。

## 备选方案

| 方案 | 放弃原因 |
| --- | --- |
| 上游 render API | 只有 legacy gpu，DV 不正确 |
| 自编 libmpv + gpu-next 渲染后端 | 需要长期维护未合并补丁 |
| 独立 mpv 进程 + IPC | 当时判断「进程/窗口管理复杂，macOS 体验差」；**Windows 后来改用这条，见 ADR-0009** |
