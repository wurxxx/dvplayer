# ADR-0012：Windows 加一条进程内 libmpv 后端（保留子进程为默认）

- 状态：已接受（实现完成，真机 DV P7 FEL 已验证；**体积收益实测只有约 6 MB**）
- 日期：2026-11-24（2026-11-25 补真机与体积实测）

## 背景

ADR-0009 定了 Windows 用 `mpv.exe` 子进程 + JSON IPC，理由是「不需要自己持有
libmpv 句柄」「可以单独升级 mpv」「进程管理是现成的」。

这条路径一直工作正常，DV P7 FEL 在真机上验过（`docs/M0.md` 的 A4/A5）。
但它带来一个副作用：**发布包必须带完整的 `mpv.exe`**，而这个官方构建是静态
链接的单文件，把 ffmpeg 全部解码器、libass、libplacebo、全部滤镜都编进去了，
116 MB。

当时 `DvPlayer-0.1.1-win-x64-portable.zip` 的构成（未压缩）：

| 部分 | 大小 |
| --- | --- |
| `mpv\mpv.exe` | 116.2 MB |
| .NET 运行时（self-contained） | ~85 MB |
| 其余（WPF、语言资源等） | ~71 MB |
| 合计 | 272.6 MB（zip 后 112.7 MB） |

`mpv.exe` 一个人就占了 43%。

## 决策

**保留子进程后端为默认，新增一条进程内 `libmpv` 后端，用环境变量切换。**

```text
DVPLAYER_MPV_BACKEND=libmpv   →  进程内 libmpv-2.dll
（不设）                       →  子进程 mpv.exe（默认，已验证）
```

实现上用 `IMpvEngine` / `IMpvControl` 两个接口把播放层和 `PlayWindow` 隔开，
两个后端各自实现，`PlayWindow` 一行都不用改。

关键点：**仍然用 `wid` 选项，不用 render API。**

`wid` 让 mpv 自己把画面画进壳的 HWND，和子进程的 `--wid` 是同一套 gpu-next
VO 代码路径。所以 DV P7 的拆层、EL 合成、DV 整形逻辑完全一致，只是"谁来装
这份 mpv"不同。用 render API 的话要自己建 D3D11 设备、管交换链、处理 resize，
代码量翻倍，而且 `target-colorspace-hint` 还得手工接——收益为零，风险很高。

## 为什么不直接替换成默认

1. **崩溃隔离消失**：mpv 和壳同进程，mpv 崩了整个 App 一起死。子进程方案里
   崩的只是 `mpv.exe`，壳还在，用户能重试。
2. **体积并不省**（见下），没有必须替换的理由。
3. 现版本能用，默认路径保持已验证的那条。

## 体积实测（2026-11-25，真机）

原先的估算「112 MB → 45 MB」**不成立**：它假设 `mpv-dev` 里的 `libmpv-2.dll`
是共享链接的。实际 shinchiro 的 dev 包同样是静态链接（`libmpv-2.dll`
116.1 MB，和 `mpv.exe` 的 116.2 MB 一样大）。

| 指标 | process 后端 | libmpv 后端 | 差 |
| --- | --- | --- | --- |
| payload 未压缩 | 265.7 MB / 284 文件 | 259.9 MB / 272 文件 | −5.8 MB |
| portable zip | 110.1 MB | 107.2 MB | −2.9 MB |

（zip 是同一版本、同一台机器上分别重新打的；安装包没有为 libmpv 单独重打。）

省下的只是 `mpv\` 目录里用不上的 doc / installer / bat 和 `d3dcompiler_43.dll`
（libmpv 已静态链接）。**结论：换后端不是瘦身手段。**

## 真机验证（2026-11-25，Win11 / Intel Iris Xe / 144 DPI）

用 `--Backend libmpv` 打的包，`DVPLAYER_MPV_BACKEND=libmpv` 播
`src-423cdf2e:f/p7-fel.mkv`（`samples/p7-fel.mkv`），`mpv.log` 原文：

| 证据 | 日志 |
| --- | --- |
| P7 拆层 | `Dolby Vision Profile 7 splitter: BL stream 0, virtual EL stream 1 (dependent_track)` |
| 硬解 + DV 格式 | `Decoder format: 3840x2160 d3d11[p010] dolbyvision/bt.2020/pq/limited` |
| EL 配对 | `[vf] [el_pair] 3840x2160 d3d11[p010] dolbyvision/...` |
| 合成 shader | `sh_dovi_compose_nlq` |
| 输出 | `VO: [gpu-next] 3840x2160 d3d11[p010]` |
| 首帧 | `opening finish reason=first-frame pos=0.0 launch=0.0 after=1.5s` |
| 截帧 | 色彩正常（不是 IPTPQc2 当 YCbCr 的紫色） |
| 关窗 | 任务返回 0，`DvPlayer` / `mpv` 进程无残留 |

顺手补的一个缺陷：进程内后端原先没有 `log-file`，mpv 的日志（`[el_pair]`、
`dolbyvision`、滤镜信息）根本不落盘，DV 回归没法验。现在
`LibMpvProcess` 设 `log-file=<LOCALAPPDATA>\dvplayer\mpv.log`（和子进程同一个
文件），壳自己那几行写 `mpv-shell.log`，避免两个写句柄互相顶掉。

## 待验证

- [x] 进程内后端在 Windows 真机上编译通过
- [x] DV P7 FEL 播放：`[el_pair]` 出现、`dolbyvision` 色彩、截帧正常
- [x] 关窗不泄漏 mpv（进程干净退出）
- [x] 打包体积实测（见上，收益约 0）
- [ ] 换集：本地样本只有单文件电影，缺剧集源
- [ ] 长时间播放的内存稳定性（同进程，mpv 的内存增长会算在壳头上）

## 真正的瘦身路线

体积的大头是「一份静态链接的全功能 mpv」（116 MB，占 zip 的 43%）。两条路：

1. **自建 shared 构建**：ffmpeg `--enable-shared` + mpv `-Dlibmpv=true`
   共享链接，只留用得到的解码器 / 滤镜。参照 macOS 那边自建的 mpv 全栈，
   `.app` 一共才 42 MB。要在 Windows 上搭交叉编译（MSYS2/mingw），1-2 天。
2. **框架依赖发布**：不打包 .NET 运行时，payload 直接少约 138 MB（zip 约
   55 MB），代价是用户要先装 .NET Desktop Runtime，不再是解压即用。
