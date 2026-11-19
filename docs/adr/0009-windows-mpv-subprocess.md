# ADR-0009：Windows 用 mpv 子进程 + JSON IPC

- 状态：已接受（修正 ADR-0001 的一个备选方案判断）
- 日期：2026-11-19

## 背景

ADR-0001 定的是「mpv 自管窗口、零 fork」，但当时把 **独立 mpv 进程 + IPC** 列进了
放弃项，理由是「进程/窗口管理复杂，macOS 体验差」。

做到 M1 的播放闭环时，实际的取舍变了：

- Windows 只需要给 mpv 一个父 HWND（`--wid`），**不需要**自己持有 libmpv 句柄；
- 链 libmpv 就要一起解决 MSVC 工具链、C++ 运行时、DLL 与 `.lib` 分发，
  而 mpv 的 DV/FEL 能力全在官方 exe 里，链接与否没有任何区别；
- mpv 子进程可以单独升级（换一个 `mpv.exe`），出问题也能单独降级；
- 进程管理在 .NET 里是现成的：Job Object 绑住子进程，壳退出/崩溃一起回收；
  窗口管理是 `HwndHost` + 一个 `WM_SIZE` 转发，M0 的 A5 已经验过。

macOS 不适用：`--wid` 不可靠（ADR-0003），那边仍然要链 libmpv 走 render API，
所以 ADR-0001 的技术结论没变，变的只是 Windows 的实现手段。

## 决策

Windows 播放器 = **官方 mpv.exe 子进程**：

```text
DvPlayer.exe
  └── mpv.exe --wid=<HwndHost 的 HWND>
              --input-ipc-server=\\.\pipe\dvplayer-<pid>-<n>
              --vo=gpu-next --hwdec=auto-safe --osc=no
```

- 播放参数、请求头、续播起点都由壳拼进命令行（`--http-header-fields-add`、`--start`）；
- 控制与状态走 JSON IPC：`set_property` / `observe_property` / `cycle`；
- 子进程放进 Job Object，壳异常退出时一起结束；
- 失败要能降级：`DVPLAYER_MPV` → exe 同级 `mpv\mpv.exe` → 默认路径。

## 后果

- 好：不维护 C++ 工具链；mpv 版本与壳解耦；崩溃隔离（mpv 挂了壳还能给提示）；
- 坏：多一个进程；启动多几十毫秒；IPC 要自己做事件分发；
- 需要接受：`wid` 的 airspace 限制仍在（XAML 画不到视频上面），控制条放在视频外；
- `core/mpv`（C++ 封装）只服务 macOS 路线，Windows 不再用它。

## 相关

- ADR-0001：桌面嵌入的总体路线（本 ADR 只改 Windows 的落地手段）
- ADR-0003：macOS 用 render API
- `apps/windows/DvPlayer/Player/MpvProcess.cs`、`MpvIpc.cs`、`MpvHost.cs`、`ChildProcessJob.cs`
