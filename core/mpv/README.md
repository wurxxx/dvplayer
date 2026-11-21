# core/mpv（已放弃）

原计划：桌面端共享的 libmpv 封装（C++），Windows 走 `wid`、macOS 走 render API。

现在两端都改成 **mpv 子进程 + JSON IPC**，让 mpv 自己建 VO 和 swapchain：

- Windows：ADR-0009（官方 `mpv.exe` + `--wid` + 命名管道）
- macOS：ADR-0010（`prefix-vk` 的 mpv + Vulkan/macvk，壳贴透明浮层，unix socket）

因此这个模块不再实现，目录只留作历史记录。播放器代码分别在
`apps/windows/DvPlayer/Player/` 与 `apps/macos/DvPlayer/Sources/DvPlayer/Player/`。
