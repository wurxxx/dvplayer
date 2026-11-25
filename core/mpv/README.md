# core/mpv（已放弃）

原计划：桌面端共享的 libmpv 封装（C++），Windows 走 `wid`、macOS 走 render API。

后来两端都改成 **mpv 子进程 + JSON IPC**，让 mpv 自己建 VO 和 swapchain：

- Windows：ADR-0009（官方 `mpv.exe` + `--wid` + 命名管道）
- macOS：当时也走子进程，该方案后来废弃

**2026-11-23 更新**：macOS 已改回**进程内 libmpv + render API + 单窗口**
（ADR-0011），因为 mpv 2026-11-22 起 render API 支持 gpu-next 后端，
DV 整形不再是子进程独有的能力。Windows 仍然是子进程 + `--wid`。

因此这个共享 C++ 模块不再实现，目录只留作历史记录。播放器代码分别在
`apps/windows/DvPlayer/Player/` 与 `apps/macos/DvPlayer/Sources/DvPlayer/Player/`。
