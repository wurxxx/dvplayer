# 架构

## 1. 分层

```
┌──────────────────────────────────────────────┐
│ UI 壳                                        │
│ WPF / SwiftUI / Compose（手机 / TV）         │
├──────────────────────────────────────────────┤
│ 播放服务层                                   │
│ Windows：mpv 子进程 + JSON IPC               │
│ macOS：进程内 libmpv render API              │
│ Android：mpv render API（默认）+ Media3      │
│ 壳只做浮层与状态                             │
├──────────────────────────────────────────────┤
│ 内核                                         │
│ mpv 0.42 · FFmpeg 9 · libplacebo 7.387       │
│ Media3（Android 第二引擎）                   │
│ libdovi（RPU / EL 解析）                     │
├──────────────────────────────────────────────┤
│ 输出                                         │
│ GPU surface（D3D11 / OpenGL / SurfaceView）  │
│ 音频（WASAPI / CoreAudio / AudioTrack）      │
└──────────────────────────────────────────────┘
```

## 1.1 媒体源适配（多服务器）

正式产品是聚合客户端（飞牛影视 + Emby 合并搜索、播放记录、续播），
所以「哪台服务器」必须是可插拔的，不能长在界面里。

```
UI / 播放器 / 聚合层
        │  只认 MediaLibrary / MediaItem / PlayRecord / PlaySource
        ▼
  core/media  ── trait MediaSource ──┬── FnOsSource（飞牛原生 API，已实现）
  (Rust，C ABI)                      ├── EmbySource（下一步）
                                     └── …
```

约定：

| 位置 | 规则 |
| --- | --- |
| `sources/mod.rs` | `MediaSource` trait + `create(config)` 工厂，新增服务器只加一个分支 |
| `models.rs` | 各服务器差异在适配器内部消化，对外只有一套模型 |
| `ffi.rs` | `SourceHandle` 持有 `Box<dyn MediaSource>`，C ABI 不随服务器变化 |
| `PlaySource` | 播放器只吃「URL + 请求头 + 续播秒数 + 轨道」，不关心谁给的 |
| 界面 | 源类型来自 `dv_source_kinds()`，不写死字符串 |

新增一个服务器的步骤：实现 `MediaSource`（10 个方法：登录、媒体库、条目列表、子项、
详情、播放源、进度、播放记录、图片、能力表）→ 在 `create()` 加一行
→ 在 `SUPPORTED_KINDS` 注册。界面和播放器不需要改动。

层级怎么解释也归核心管，否则四端会各写一套：

| 服务器原样 | 核心给界面的 | 谁负责 |
| --- | --- | --- |
| `TV → Season → Episode` | 同样的三层，`kind` 分别是 series / season / episode | 适配器直接映射 |
| `Directory → Video`（未刮削） | **一部剧**：`kind=folder`，子项是集，`episode_number` 从文件名解析 | `fnos.rs` 的 `parse_episode_number` |
| 标题里的 `（76集）` | `episode_count` | `parse_episode_count`（只认括号） |

界面只做两件事：`folder` 当「剧集」显示、集号为空时按顺序补号。
Emby 接入时它自己的 `Season`/`Episode` 已经在协议里，映射即可，不用再猜文件名。

### 1.2 聚合层（已落地，M1）

单源能播之后，产品价值在「一个界面看所有片源」。聚合层同样放在核心，
否则四端会各写一套合并逻辑。

```
UI
 └── MediaHub（core/media 内，持有 0..N 个 MediaSource）
       ├── search(keyword)        各源并发，合并去重
       ├── records()              各源合并，按 lastPlayed 倒序
       ├── resolve(itemId)        按 "<sourceId>:<itemId>" 找到源并取播放源
       └── libraries()            各源库列表，按用户排序分组
```

规则：

| 主题 | 规则 |
| --- | --- |
| 身份 | `ItemId = "<sourceId>:<itemId>"`，源内 id 只在自己的适配器里有意义 |
| 去重 | 标题归一（去发布组/季集后缀）+ 年份 + 类型；剧集再比集数，不做模糊合并 |
| 选择 | 同一片多源：**有进度 > 用户设的源优先级 > 分辨率/码率高** |
| 搜索 | 各源并发，超时/失败的源单独标灰，不拖垮整次搜索 |
| 进度 | 只在**播放的那个源**回写，不做跨源同步（M4 再谈） |
| 缓存 | 库列表与图片本地缓存（图片已做），带 TTL 和手动清理 |
| 失败隔离 | 一个源挂了不影响其他源；设置页显示每个源的健康状态 |

实现方式（已落地）：`core/media/src/hub.rs` 的 `MediaHub`（持有 `Vec<Entry>`），
C ABI 多一组 `dv_hub_*`；界面（`AppServices`）只持有一个 hub，设置页逐个接源、
显示每个源的状态并能删除。适配器内部只认裸 id，进出 hub 时统一加/去前缀，
图片路径同样处理。

两个实现细节：

- **库重名**：两个源都有叫「影视」的库时，`libraries()` 给标题追加源名
  （`影视 · 飞牛`），否则界面上按下的是哪个库都说不清；
  `MediaLibrary.sourceId` 统一成入口 id，和设置页的连接列表对齐。
- **失败隔离**：`collect` 逐个源跑，失败只记最后一个错误；全失败才报错。
  同一个源里某次请求失败不会影响其它源。

**搜索**走各源自己的接口：飞牛是 `GET /v/api/v1/search/list?q=`（见
[FNOS-API §4.2.1](FNOS-API.md)），Emby / Jellyfin 是
`/Users/{uid}/Items?SearchTerm=`，本地 / 挂载目录按文件名匹配。

`Hub::search` 的实现（2026-11-21 落地）：

| 步骤 | 规则 |
| --- | --- |
| 并发 | 每源一条线程，一个源卡住不拖慢整次搜索 |
| 提升 | 命中的是集 / 季时按 `parentId` 换成整部剧再参与去重 |
| 去重键 | `normalize_key(title)`（去发布标签、标点、结尾年份）+ 年份 + 归一类型（Movie/Video/Unknown→Movie；Series/Season/Episode→Series）+ 集数（两边都有且不同才不合并） |
| 主源 | 组内按「有进度 > 源顺序 > 分辨率（4K>1440p>1080p>720p）」排，第一项为主条目，其余进 `MediaItem.sources` |
| 排序 | 有进度的组提前，其余保持源返回顺序（稳定），最多 120 条 |
| 失败 | 失败的源进 `SearchResult.failed`（源名 + 错误），界面单独标出；全失败才报错 |

结果的结构是 `SearchResult { items, failed }`（`dv_hub_search`），
`MediaItem.sources` 里的每一项是 `ItemSource { itemId, sourceId, sourceName, resolution, progress }`。
界面在卡片左上角标「N 源」，点开进详情，**选源在详情页的「资源」里做**，
搜索页不弹选源框。

详情页的资源列表单独走 `dv_hub_item_sources(itemId)`：核心用详情标题各源再搜一遍，
按同一套去重键找回同一部片，返回排好序的 `Vec<ItemSource>`；第一项标「推荐」，
正在看的那条标「当前」。单集 / 单季不列资源（那是一部剧内部的层级）。
只有单一来源时也照样列出那一行——用户要一眼看到这部片在哪个库，
所以两端都不按「两个源以上」隐藏。
这样从媒体库、记录、播放页进详情都能看到其它源，不依赖搜索页带过来的数据。

## 2. 播放内核接入（现状）

| 平台 | 接入方式 | 代码 |
| --- | --- | --- |
| Windows | 起官方 `mpv.exe`：`--wid=<子窗口>`，控制走 `--input-ipc-server=<命名管道>` 的 JSON IPC，进程用 Job Object 绑在壳上 | `apps/windows/DvPlayer/Player/`（`MpvProcess` / `MpvIpc` / `MpvHost`） |
| macOS | 进程内 libmpv（render API + gpu-next / OpenGL）画进自己的窗口，SwiftUI 控制浮层叠在同一窗口里；控制直接调 C API，单窗口（ADR-0011） | `apps/macos/DvPlayer/Sources/DvPlayer/Player/`（`MpvEngine` / `PlayerSession` / `PlayerWindow`） |
| Android / TV | mpv 进程内（render API + EGL，默认）+ Media3（第二引擎，按能力路由，ADR-0014） | 手机端已接（`:player-mpv` / `:player-media3`），TV 未接 |

Windows 用子进程（[ADR-0009](adr/0009-windows-mpv-subprocess.md)）：让 mpv 自己建 VO
和 swapchain 才拿得到 `gpu-next`（Dolby Vision 整形与 FEL 都在这里）。

macOS 一开始也走子进程（该方案已废弃），后来改为进程内 libmpv + render API
（[ADR-0011](adr/0011-macos-libmpv-inprocess.md)）：mpv 从 2026-11-22 起在 render API
上也支持 gpu-next 后端，DV 整形不再是子进程独有的能力。这样包更小、控制也不用绕 IPC。
`core/mpv` 的 C++ 封装不再需要。

### 2.0 打开播放窗的过渡（两端一致）

播放窗是「视频层 + 控制浮层」：Windows 是两个窗口（视频子 HWND + 透明浮层窗），
macOS 是同一个窗口里的视频画布 + SwiftUI 控制层（ADR-0011）。视频层要先就位 /
拿首帧，浮层如果一出现就画控制条，前面那几百毫秒就是「一条控制条悬在桌面上」。

所以两端都按同一套节奏：

| 阶段 | 表现 |
| --- | --- |
| 窗口出现 | 整窗淡入 180ms（Windows `Window.Opacity` / macOS `alphaValue`） |
| 解析播放源 / 起 mpv | 浮层铺一层**不透明黑**，中间是片名 +「正在打开…」，控制条不显示 |
| 声画起播 | mpv 带 `--pause=yes` 起播：音频比首帧早约 0.5 秒，先不放开播放 |
| VO 就绪 | `vo-configured` 变 true 后 unpause，声音和画面从这一刻一起开始 |
| 首帧到达 | 黑底淡出 140ms，控制条淡入 180ms |
| 兜底 | 4 秒还没等到 VO 就绪就先 unpause；黑底仍等首帧 / 位置。控制通道连不上直接报错重试 |

首帧的判定：两端都看 `video-frame-info`（VO 真正交出一帧；Windows 走 IPC 事件，
macOS 读同名属性），位置 `time-pos > 起播点 + 0.5` 作为兜底。
切集走同一条路径：先盖黑底，新文件同样先暂停、VO 就绪再放开。
黑底在浮层里面画，所以视频窗口还没就位时也看不到桌面。

### 2.1 播放控制契约（两端语义一致）

Windows 走 mpv 的 JSON IPC（命名管道）；macOS 进程内直接调 libmpv 的 C API
（`mpv_set_property` / `mpv_command` / `mpv_observe_property`），事件名与 JSON IPC
的约定保持一致，`MpvEngine` 对上层不分叉。等价关系：

| 用途 | 命令 |
| --- | --- |
| 打开 | `set_property http-header-fields`、`set_property start`、`loadfile <url> replace` |
| 播放控制 | `set_property pause \| seek \| speed \| volume \| mute` |
| 选轨 | `set_property aid \| sid`（关字幕传 `no`） |
| 状态 | `observe_property`：`time-pos`、`duration`、`pause`、`eof-reached`、`speed`、`volume`、`mute`、`track-list`、`aid`、`sid` |
| 事件 | `file-loaded`、`end-file`、`property-change` |
| 窗口尺寸 | Windows 走 `wm_size` 同步子 HWND；macOS 重建 GL viewport |

原则：Windows 一条连接既发命令又收事件，命令带 `request_id`、回复按 id 分发；
macOS 的回调里直接取属性值。两端都切回 UI 线程，属性用观察而不是轮询。

### 2.2 格式覆盖与降级策略

「什么都能放」靠的是内核能力 + 明确的降级路径，不是自己实现解码器：

| 环节 | 做法 | 现状 |
| --- | --- | --- |
| 硬解 | `hwdec=auto-safe`（D3D11VA / QSV / VideoToolbox / MediaCodec），失败自动软解，选择结果写日志 | Windows 已验 4K120 / 8K60；macOS 参数已带，画面待目视；Android 走 mpv `hwdec=mediacodec` / Media3 MediaCodec，待验 |
| HDR | `target-colorspace-hint=yes`：HDR 屏直通、SDR 屏 tone-map；元数据（HDR10 / HDR10+ / HLG）由内核识别 | Windows 开关已接、识别已验，真屏待验；macOS 开关已接（`hdrPassthrough`），真屏待验；Android 由壳设 dataspace / colorMode，待验 |
| DV | 交给 `gpu-next`：P7 双层合成、P5/P8 整形；拿不到增强层时只播 BL | Windows P7 FEL 已验；macOS P5 目视正常、P7 FEL 同帧 A/B 已验；Android mpv 走 P5/P8 整形、P7 只播 BL，待验 |
| 音频 | 默认解码混音；设置里可切直通（`audio-spdif=ac3,eac3,dts,dts-hd,truehd`），失败回落解码 | 两端都已接开关与设备选择（`audioDevice` / `audioPassthrough`，起 mpv 时带成参数），听感待 AVR 实测；Android mpv 的 audiotrack 直通待验，Media3 走 FFmpeg 音频扩展 |
| 字幕 | PGS / ASS / SRT 走内核；Android 由 mpv 的 libass 渲染（含 MKV 内嵌字体），Media3 侧 ASS 只显示基础文本 | ASS / SRT 两端已验证，PGS 未单独验；Android 未验 |

原则：**UI 显示的是实际行为，不是文件声称的格式**。播放页要给一条「源 → 输出」的信息
（例如 `DV P7 (FEL) → HDR10 直通`、`DV P7 → 本机只播 BL`），
避免"看起来支持、其实降级了"。

## 3. 线程模型

| 线程 | 职责 |
| --- | --- |
| mpv 核心线程（两端） | 解复用、解码、渲染（gpu-next） |
| Windows：IPC 读线程 | 逐行读 mpv 的 JSON，切分事件交给 UI 线程 |
| macOS：事件线程 | `mpv_wait_event` 循环，属性事件 / 命令回复切回主线程 |
| macOS：渲染队列 | 串行执行 `mpv_render_context_render`（GL 上下文 current 的那条线程） |
| UI 线程 | 接收事件，更新界面；Windows 还要同步子 HWND 的尺寸 |

## 4. Windows

- 视频在一个独立的无边框黑窗（`PlayerSurfaceWindow`）里，`MpvHost`（HwndHost）托管；
  `mpv --wid=<HostHandle>`。
- `vo=gpu-next`、`gpu-api=d3d11`、`gpu-context=d3d11`。
- Airspace：XAML 画不到子 HWND 上面，所以控制条是**另一个逐像素透明的窗口**
  （`PlayWindow`，`AllowsTransparency`），两层由播放窗同步矩形与 z 序；
  打开 / 切集时浮层铺不透明黑底，首帧到了再淡出（§2.0）。
- 全屏：resize 两个窗口，不重挂父窗口；F11 / 双击进入，Esc 分层退出。
- 进程生命周期：mpv 放进 Job Object，壳崩溃时子进程一起结束，不留后台播放。
- DPI：手动同步子 HWND 位置与尺寸。

## 5. macOS

- libmpv 跑在应用进程内，用 render API（`MPV_RENDER_API_TYPE_OPENGL`）画进自己的
  `NSOpenGLView`，gpu-next + OpenGL（ADR-0011）。
- 单窗口：控制浮层和视频在同一个 `NSWindow` 里，浮层是叠在上面的 SwiftUI 层，
  不需要用 `set_property geometry` 去跟另一个窗口对齐。
- 控制直接调 libmpv 的 C API（`libmpv` 的事件循环在进程内），不走 IPC。
- 全屏是「假全屏」：窗口铺满屏幕 + 隐藏菜单栏 / Dock，不用系统 fullscreen space。
- Dolby Vision P5/P7 由 gpu-next 的 `pl_shader_dovi_reshape()` 处理；HDR10 走
  `target-colorspace-hint`，SDR 屏上是固定 tone-map。

## 6. Android / TV

双引擎、两个壳，决策见 [ADR-0013](adr/0013-android-two-shells.md) /
[ADR-0014](adr/0014-android-dual-engine.md) / [ADR-0015](adr/0015-android-vfs.md)，
实现计划与里程碑见 [M2-ANDROID.md](M2-ANDROID.md)。

- **双内核**：mpv 进程内（render API + EGL，默认）+ Media3（第二引擎）。
  引擎契约在 `:player`，视频 Surface 由壳的 `SurfaceView` 提供；
  切换 = 停一个、按当前位置重开另一个，约 1 秒空档。
- **默认路由 mpv**，三条硬例外走 Media3：HDR/DV 且设备支持、需要直通且 mpv 不支持、
  `DeviceProfile` 判定性能不达标。`DeviceProfile` 由能力探测页生成并缓存。
- **HDR 输出由壳接**：`ANativeWindow_setBuffersDataSpace(BT2020_PQ)`、
  `window.colorMode`、TV 上 `preferredDisplayModeId`；盒子合成器只认 tunneled HDR 时
  mpv 拿不到 HDR，归入能力例外。
- **原盘**：mpv 原生 libbluray，本地 / SAF 的 ISO、BDMV 直接播；NAS 原盘先下载到缓存。
  Media3 不参与原盘。
- **字幕**：mpv 自带 libass（含 MKV 内嵌字体）；Media3 侧 SRT/PGS 原生，
  ASS 只显示基础文本。没有单独的 libass NDK。
- **存储**：Kotlin VFS（smbj / libnfs / OkHttp）+ `core/media` 虚拟源；
  NFS 仅 AUTH_SYS。播放走 Media3 `DataSource` 或 mpv 自定义 stream。
- **两个 application 模块**：`:app-phone`（Material3）与 `:app-tv`（tv-material），
  共享 `:feature` / `:player` / `:data`，不共享屏幕布局。

## 7. 徽标

| 条件 | 徽标 |
| --- | --- |
| profile 7 + EL 有残差 | `DV P7 (FEL)` |
| profile 7 + EL 无残差 | `DV P7 (MEL)` |
| profile 5 | `DV P5` |
| profile 8.x | `DV P8.x` |
| HDR10+ | `HDR10+` |
| HDR10 | `HDR10` |
| Android 设备解码 | `DV`（不标层类型） |

数据来源：mpv 只暴露 `dolby-vision-profile`；FEL/MEL 由 `core/dovi` 用 libdovi
解析第一个 RPU 的 `disable_residual_flag` 判定，在 `file-loaded` 时缓存为自定义属性。
