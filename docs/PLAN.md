# DVPlayer 项目计划

> 状态：M0 完成（仅 A6 Android 真机待设备）；M1（Windows Alpha）已发布 0.1.6，
> 剩 Jellyfin 12.x 真机与 Plex；macOS 壳已发布 0.1.6（画面 / HDR 真屏待设备，
> 签名公证未做）；Android / TV 进入 M2：底层能力与数据层 JNI 已落地（双内核、原盘入口、
> VFS、DV P5 颜色闭环，41 个 `dv_*`），手机端界面已有，TV 界面未做
> （见 [M2-ANDROID.md](M2-ANDROID.md) §9.1）。最后更新：2026-11-28，剩余工作见 §5。

## 1. 目标

做一个跨 macOS、Windows、Android、Android TV 的原生播放器，三条并列主线：

1. **格式覆盖**——市面上绝大部分编码与 HDR 格式都能解、能正确呈现：
   HEVC / H.264 / AV1 / VP9、Dolby Vision（P5 / P7 / P8）、HDR10 / HDR10+ / HLG、
   DTS-HD / TrueHD / Atmos 直通、PGS / ASS 字幕。
   设备做不到的要**明确降级并说明**（例如"这台机器只能播 BL"），不能黑屏、花屏或假装支持。
2. **资源库整合**——飞牛影视、Emby、Jellyfin、Plex，以及 SMB / NFS / WebDAV 目录，
   统一接入、统一浏览、统一播放。新增一种源只写一个适配器，界面不动（ADR-0008）。
3. **聚合搜索与统一进度**——一次搜索覆盖所有已接入的源，播放记录与续播点合并展示，
   同一部片在多个源里出现时按规则去重、选最优的一路播。

Dolby Vision P7 FEL 仍是桌面端的硬指标（它是格式覆盖里最难的一格），但不再是唯一目标。

> 2026-11-19 调整：原目标只写「DV P7 FEL 完整重建」，是单点突破的思路；
> 实际产品要解决的是「什么都能放 + 片源都在一个界面里」，因此扩成上面三条。

### 1.1 资源库接入范围

| 源 | 协议 | 状态 | 备注 |
| --- | --- | --- | --- |
| 飞牛影视（fnOS Media） | 原生 `/v/api/v1` + authx 签名 | **已接入** | 见 [FNOS-API.md](FNOS-API.md) |
| Emby | `/Users/*` + `X-Emby-Token` | **已接入**（4.9.3 实例全链路实测） | 见 [EMBY-API.md](EMBY-API.md) |
| Jellyfin | `/Items?userId=` 等官方端点 + `Authorization` | **已接入**（10.8.12 全链路实测；12.x 按官方 OpenAPI 写，未跑真机） | 独立适配器 `sources/jellyfin.rs`，见 [JELLYFIN-API.md](JELLYFIN-API.md) |
| Plex | `/library/*` + `X-Plex-Token` | 未开始 | 需要独立适配器 |
| 本地文件夹 | 直接读路径 | **已接入** | 目录 / ISO 进媒体库，不刮削，按 `SxxExx` / `第 N 集` 认集号，见 [LOCAL-SOURCE.md](LOCAL-SOURCE.md) |
| SMB / NFS / WebDAV | 系统挂载 + 本地扫描 | **已接入**（macOS 实测 SMB 全链路；Windows 已编译通过，SMB 表单与失败回显已验） | 无刮削，按 `SxxExx` / `第 N 集` 认集号；挂载后复用本地文件夹源，见 [LOCAL-SOURCE.md](LOCAL-SOURCE.md) §6 |

同一部片出现在多个源时怎么选、搜索怎么合并，见
[ARCHITECTURE.md](ARCHITECTURE.md) §1.2。

## 2. 已定技术路线

| 平台 | UI | 视频面 | 播放内核 | 格式能力 |
| --- | --- | --- | --- | --- |
| Windows | .NET 10 + WPF + WPF-UI | mpv 子 HWND（`wid`），mpv 自管 swapchain | 官方 `mpv.exe` 子进程 + JSON IPC（ADR-0009，`vo=gpu-next`） | DV P7 FEL 完整；HDR10 / HDR10+ / HLG；硬解看 GPU（已验 4K120 / 8K60） |
| macOS | SwiftUI + AppKit | 应用自己的 `NSOpenGLView`，控制层叠在同一窗口 | 进程内 libmpv + render API（ADR-0011，gpu-next 跑在 OpenGL 上） | gpu-next：DV P5/P7 整形、HDR10 识别，HDR 输出未接（默认 tone-map 到 SDR）；解码走 VideoToolbox；见 [M2-MACOS.md](M2-MACOS.md) |
| Android / TV | Kotlin + Compose（手机 Material3 / TV tv-material） | SurfaceView（壳持有） | mpv 进程内 render API（默认）+ Media3（第二引擎，ADR-0014） | 设备解码器决定；DV P5 走 mpv 整形，P7 只播 BL；直通按设备 |

关键结论（详见 ADR）：

- 桌面端**零 fork**，不维护 libmpv 私有补丁。
- Windows 走 `wid` 子窗口 + 官方 `mpv.exe`（ADR-0009）；进程内 libmpv 后端留作备选（ADR-0012）。
- macOS 的 `--wid` 不可靠；render API 从 mpv 2026-11-22 起能用 gpu-next（FEL 所在），
  所以是进程内 libmpv + render API + 单窗口，不需要额外的 GPU 驱动（ADR-0011）。
- WinUI 3 被排除：WinUI 3 窗口内的子 HWND 收不到输入（microsoft-ui-xaml#9912），
  与 `wid` 方案冲突。

## 3. 依赖

| 依赖 | 版本 | 用途 |
| --- | --- | --- |
| mpv | 0.42.x | 桌面播放内核，gpu-next 提供 P7 增强层 |
| FFmpeg | 9.0.x | `dovi_split` 拆 BL/EL；DV stream group |
| libplacebo | 7.387.x | FEL 残差重建（`pl_frame.enhancement_layer`） |
| libdovi | 最新稳定 | RPU 解析、FEL/MEL 判定 |
| libass | 最新稳定 | ASS 特效字幕 |
| Media3 | 当前稳定线 | Android 第二引擎，HDR / 直通路径 |
| libmpv（Android） | 0.42.x | Android 默认播放内核（LGPL 构建） |
| libbluray | 1.5.x | 原盘 title / 章节（mpv 与 `player-disc` 共用） |

版本钉在 `deps/pins.env`。M0 已经开始 vendored 构建（`scripts/build-deps-macos.sh`
把 FFmpeg / libplacebo / libass / mpv 全部装进项目内 `prefix/`），不依赖系统库。

## 4. 里程碑

| 里程碑 | 范围 | 状态 |
| --- | --- | --- |
| M0 技术验证 | FEL 重建 / Windows `wid` / macOS render API / 解码与蓝光 | **完成**，A6（Android 真机）待设备 |
| M1 Windows Alpha | 多源接入（飞牛 + Emby/Jellyfin + 本地/文件协议源）、聚合搜索、播放与续播、打包、更新检查 | **已发布 0.1.6**：功能已落地，Emby 联调已通过，安装版 / 绿色版由 CI 出包并附到 Release，启动检查更新已接；剩 Jellyfin 12.x 真机与 Plex；清单见 [M1.md](M1.md) |
| M2 Android / TV | 双壳、双内核（mpv 默认 + Media3 按能力路由）、原盘、VFS、TV 焦点 | **底层已落地**：双内核路由、原盘入口、VFS（SMB / NFS / WebDAV）、DV P5 颜色闭环、数据层 JNI（41 个 `dv_*`，`verify-core.sh` 19 步）；手机端库 / 首页 / 详情 / 搜索 / 设置已接通并做了平板断点（§7.9.3），播放页已接内核，TV 界面未做，清单见 [M2-ANDROID.md](M2-ANDROID.md) §9.1 |
| M3 macOS | 进程内 libmpv + render API 全链路、DV / HDR10 或 SDR 回退、签名公证 | **已发布 0.1.6**：浏览、播放、五项功能、Trakt、更新检查已可用（[M2-MACOS.md](M2-MACOS.md)）；画面目视、HDR 真屏、签名 / 公证待做 |
| M4 共性层 | 跨端播放记录同步、元数据缓存 | **部分**：本机跨源续播（电影取较长进度）与 Trakt playback 读取已完成；播放记录 / 收藏跨端合并未做 |

### 解码与呈现能力矩阵（横跨 M1–M3，不是独立里程碑）

格式覆盖是一条贯穿三端的线，用矩阵驱动，验证记录写在 [DECODE.md](DECODE.md)：

| 能力 | Windows | macOS | Android / TV |
| --- | --- | --- | --- |
| HEVC / H.264 硬解 | **已验**（4K/8K、120 fps） | 待验（VideoToolbox 参数已带） | 待验 |
| AV1 / VP9 | 待验（mpv 支持，缺样片） | 待验 | 待验 |
| DV P7（FEL） | **已验**（官方 mpv 自带 FEL 合成；徽标 `DV P7 (FEL/MEL)`） | 结构性已验（`fel-ab.sh` 同帧开关 EL：PSNR≈49、`>2` 像素≈1%）；HDR 屏目视待做；徽标 `DV P7 (FEL/MEL)` | 回退 BL |
| DV P5 / P8 | 部分验（P5 颜色待修，见 M0 §5.3） | **已验**：产品路径抓帧肤色正常（`samples/p5.mkv` 11s，gpu-next render API） | 待验 |
| HDR10 / HDR10+ / HLG 识别 | **已验**（元数据正确） | 待验（`video-params` 已可读） | 待验 |
| HDR 直通到 HDR 屏 | 开关已接（`target-colorspace-hint`），真屏待验 | 开关已接（`target-colorspace-hint`），真屏待验 | 待验 |
| 音频直通（DTS-HD / TrueHD / Atmos） | 已接开关与设备选择（`audio-spdif`），听感待 AVR 实测 | 已接开关与设备选择（`audio-spdif` / `audio-device`），听感待 AVR 实测 | 未做 |
| PGS / ASS 字幕 | ASS / SRT 已验证；PGS 未单独验 | ASS / SRT 已验证；PGS 未单独验 | mpv 自带 libass（含内嵌字体）；Media3 侧 ASS 只显示基础文本，均未验 |

### M0 — 技术验证（完成）

证明三件事：

1. FEL 真的被重建（截帧 A/B + PSNR），不是只播 BL。
2. Windows 的 `wid` 子窗口路径能起播、能拿到 FEL。
3. macOS 的 render API 路径能出画，DV 整形后来在 gpu-next render API 上补齐（ADR-0011）。

验收标准与执行记录见 [M0.md](M0.md)。

### M1 — Windows Alpha（基本完成）

对应主线 2 与 3 的第一版：飞牛 + Emby / Jellyfin + 目录源、跨源合并搜索、
合并播放记录与续播；播放/暂停/seek/轨道/字幕/音频设备与直通/HDR 开关/全屏/快捷键；
Windows 绿色版 / Inno Setup 安装版打包（CI 出包）；更新检查（查 Release + 打开下载页）。Plex 排在最后。

共享层见 ADR-0008：媒体库逻辑在 `core/media`（Rust），三端只做界面。

进度（详见 [M1.md](M1.md)）：

- 已完成：飞牛接入、库 → 剧集 → 季 → 集、剧集详情页、未刮削目录当剧集、
  mpv 播放与硬解、进度回写与续播、播放记录、图片缓存、基本键位；
- 已完成：Emby / Jellyfin 适配器、多源聚合与合并搜索（跨源去重 + 详情页「资源」选源）、
  音轨/字幕面板、本地与文件协议源（SMB / NFS / WebDAV）、蓝光原盘（ISO / BDMV）、
  音频输出设备 / 音频直通 / HDR 直通开关与 F11 全屏、进度条三层与缓冲大小；
- 已完成：更新检查（0.1.6）：启动后查 GitHub Releases、侧栏版本号下提示、「关于」页
  检查 / 打开发布页；CI 在 tag 上自动出 macOS + Windows 包并附到 Release；
- 已完成：Jellyfin 10.8.12 在两端全链路实测（Emby 另在 4.9.3 实例实测）；
- 未完成：Jellyfin 12.x 真机（新端点分支按官方 OpenAPI 写）、Plex 适配器。

### M2 — Android / TV Alpha

双壳（`:app-phone` / `:app-tv`）、双内核（mpv 默认 + Media3 按能力路由）、
原盘（mpv 原生 libbluray）、Kotlin VFS（SMB / NFS / WebDAV）、TV 焦点。
手机先行，TV 冒烟关卡通过后再开大屏 UI。详见 [M2-ANDROID.md](M2-ANDROID.md)。

### M3 — macOS

进程内 libmpv + render API 全链路（ADR-0011）、DV / HDR10 或 SDR 回退、签名 / 公证。

现状：浏览、播放、五项功能（弹幕 / 片头片尾 / 定时关闭 / 画面比例 / 字幕搜索）、
Trakt、更新检查与 Windows 对齐，见 [M2-MACOS.md](M2-MACOS.md)；未完成的是
**HDR 屏目视验收**、HDR 真屏与直通听感、签名 / 公证（更新只到「检查 + 打开下载页」，
没有 Sparkle 静默安装）。

### M4 — 共性层

跨端同步（播放记录、收藏、续播点）、元数据缓存与服务端聚合搜索。
「Rust 共享媒体库」已经提前在 M1 落地（ADR-0008），这里不再重复。

## 5. 剩余工作（2026-11-26 盘点）

分两类：**缺外部条件**（代码已就绪，等凭据 / 设备 / 真机）和**纯开发**。

### 5.1 缺外部条件

| 项 | 卡在哪 |
| --- | --- |
| Jellyfin 12.x | 10.8.12 已在 macOS / Windows 全链路实测（登录、库、详情、继续观看、收藏、直链、图片）；12.x 的新端点分支只按官方 OpenAPI 写过，缺实例跑真机（[JELLYFIN-API.md](JELLYFIN-API.md) §4） |
| 弹幕（弹弹play） | 凭据内置（打包时注入，见 [SECRETS.md](SECRETS.md)），用户不用申请；签名、XML → ASS、`sub-add` + `secondary-sid` 同屏已用本地假服务器验过，真实接口待内置凭据后回归 |
| 在线字幕（OpenSubtitles） | 需要 API Key。两端设置页已有 API Key / 可选账号的输入入口，搜索 / 下载 / `sub-add select` 已用本地假服务器验过 |
| HDR 直通到 HDR 屏 | 缺 HDR 显示器。Windows 开关已接（`target-colorspace-hint`），只能证明元数据解析正确 |
| 音频直通听感 | 缺 AVR / 支持 DTS-HD 的接收端。Windows 已接 `audio-spdif` 与设备选择 |
| macOS 播放画面 | 本机只能验渲染链路与音轨状态；DV / HDR 的实际观感需带屏真机目视一次 |
| PGS 字幕 | 缺 PGS 样片；走内核渲染，未单独验证 |
| AV1 / VP9 | 缺样片；mpv 的 d3d11va / VideoToolbox 都支持，未测性能与硬解命中；Android 侧同缺（NE2210 上 AV1 只有 `c2.android.av1-dav1d` 软解） |
| Android 真机 | 这次复测在开发机上只剩 x86_64 模拟器（SwiftShader 每几分钟崩一次）。HDR 直出、120Hz 帧率匹配、AV1 软解性能、PiP / 前台服务长跑都要真机回归（[M2-ANDROID.md](M2-ANDROID.md) §9.1） |
| DV 电视 / TV 盒子 + AVR | 缺设备。P5 / P8 在真实 HDR 屏上的观感、tunneling、HDMI → AVR 直通、遥控器键位都没验（§9.1） |
| 未加密蓝光原盘样片 | 缺一张 ISO / BDMV；A8 只验了合成结构的路由，真实播放列表 / 章节 / 无缝分支未验（[M2-ANDROID.md](M2-ANDROID.md) §7.7） |

### 5.2 纯开发

| 项 | 说明 |
| --- | --- |
| ~~Windows 自动更新~~ | **已完成**（0.1.6）：启动 / 「关于」页查 GitHub Releases，有新版在侧栏提示；按钮打开下载页。静默安装（`.appinstaller` 或自建 feed）仍未做 |
| macOS 签名 / 公证 | `.app` 未签名、未公证，首次打开要手动放行；更新只到「检查 + 打开下载页」，不做 Sparkle 静默安装（§4 M3） |
| Plex 适配器 | `/library/*` + `X-Plex-Token`，与 Emby 差异大，单独一个适配器（M1 B15） |
| Android / TV | 底层与数据层已落地（双内核、原盘入口、VFS、DV P5 颜色闭环、41 个 `dv_*` 的 JNI），手机端库 / 详情 / 搜索 / 设置已接通（§7.9.3），播放页已接内核；**还缺 TV 界面**；再往后是原盘边读边播（B5，可选）、SMB 共享名枚举、`VfsEntry` 接核心虚拟源、TLS 自签名开关、Android 16 局域网权限、播放器搬进前台服务，见 [M2-ANDROID.md](M2-ANDROID.md) §9.1 |
| M4 跨端同步 | 播放记录 / 收藏 / 续播点跨源、跨端合并；现在只回写播放的那个源 |

## 6. 非目标（v1）

- Linux、iOS
- DV 编码 / 制作
- 服务端转码
- 跨端媒体库同步（推迟到 M4）

## 7. 风险登记

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| render API 的 gpu-next 后端依赖 mpv 版本 | 升级 mpv 可能丢 DV/FEL | pin 到 `1eb941f`，升级后跑 `fel-ab.sh` 回归（PSNR / 像素差） |
| libplacebo / FFmpeg soname 变动 | 升级即崩 | vendored 固定版本，不依赖系统库 |
| mpv 自己的窗口在 macOS 上没有 OpenGL 后端 | 让 mpv 开窗的路不可行 | 不走 mpv 自己的 VO：GL 上下文由应用提供，用 render API（ADR-0011） |
| Android DV 碎片化 | 同 APK 行为不一致 | 运行时探测 + BL 回退 + 明确提示 |
| libmpv Android 构建链 | 头号排期风险，CI 全量编译拖慢迭代 | 钉版本、缓存产物、预编译 fallback |
| Android HDR 输出（mpv） | 默认内核可能是 SDR 输出 | 壳侧设 dataspace / colorMode；盒子补不齐就路由 Media3 |
| mpv 音频直通未验证 | 默认引擎可能不能直通 | 实测；不支持就路由 Media3，不打私有补丁 |
| 双引擎 QA | 组合爆炸 | `DeviceProfile` + 同一样片跑两套能力矩阵 |
| 包体积 +25–35MB/ABI | 下载 / 安装成本 | ABI splits |
| 原盘 AACS / AACS2 | 加密盘打不开 | 扫描阶段识别并明确拒绝；引导先解密 |
| VFS 仅 Android / NFS 仅 AUTH_SYS | 与桌面收敛要重写；企业 Kerberos 不可用 | 接口边界清楚；能力矩阵标注 |
| 编解码专利 + Dolby 授权 | 商业分发风险 | 商业版走 Dolby 官方 SDK 或法务评估 |
| Intel Mac 无 HDR 显示器 | macOS HDR 无法目视验收 | 外接 HDR 屏或先验 SDR 映射 |

## 8. 决策记录

| 编号 | 决策 |
| --- | --- |
| ADR-0001 | 桌面嵌入：mpv 自管窗口，零 fork |
| ADR-0002 | Windows 壳：.NET 10 + WPF + WPF-UI |
| ADR-0003 | macOS v1：render API + HDR10，不含 DV（已被 ADR-0011 取代） |
| ADR-0004 | Android：Media3 主 + libass NDK（部分被 ADR-0014 取代） |
| ADR-0005 | 徽标：DV P7 (FEL/MEL) 明确区分 |
| ADR-0007 | 正式壳是媒体库聚合客户端（M0 壳只做验证） |
| ADR-0008 | 共享媒体库核心：Rust + C ABI，四端复用 |
| ADR-0009 | Windows 改用 mpv 子进程 + JSON IPC（修正 ADR-0001 的备选判断） |
| ADR-0011 | macOS 改用进程内 libmpv + render API + 单窗口（取代 ADR-0003，拿到 DV） |
| ADR-0012 | Windows 加一条进程内 libmpv 后端（保留子进程为默认） |
| ADR-0013 | Android 拆两个壳，共享一套核心 |
| ADR-0014 | Android 双内核：默认 mpv，按设备能力兜底 |
| ADR-0015 | Android 存储：Kotlin VFS + 核心虚拟源 |

## 9. 目录结构

```
docs/            计划、架构、ADR、M0 / M1 记录
deps/            依赖钉版本
scripts/         preflight / 拆层 / FEL A-B / Windows 构建与验证
core/media/      共享媒体库核心（Rust，C ABI）：飞牛 / Emby 适配器
core/mpv/        libmpv 封装（C++，已放弃：两端都改 mpv 子进程，见 ADR-0009 / 0010）
core/dovi/       libdovi 封装（占位）：RPU / EL 类型
apps/windows/DvPlayer/         正式壳：媒体库客户端（.NET 10 + WPF-UI）
apps/windows/DvPlayer.Windows/ M0 验证壳：HwndHost / IPC / DV 徽标（保留参考）
apps/macos/      SwiftUI + AppKit（M0 验证程序 m0-render）
apps/android/    Kotlin + Compose（手机 Material3 / TV tv-material），双内核，未开始
samples/         测试片源（不入库）
out/             运行产物（不入库）
```
