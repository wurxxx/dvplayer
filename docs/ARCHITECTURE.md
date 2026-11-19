# 架构

## 1. 分层

```
┌──────────────────────────────────────────────┐
│ UI 壳                                         │
│  WPF (Win) / SwiftUI (macOS) / Compose (TV)  │
├──────────────────────────────────────────────┤
│ 播放服务层                                    │
│  C++ PlayerCore + C ABI（Windows）            │
│  Objective-C++ 桥（macOS）                    │
│  Media3 Player（Android）                     │
├──────────────────────────────────────────────┤
│ 内核                                          │
│  libmpv 0.42（桌面） / Media3（Android）       │
│  FFmpeg 9 · libplacebo 7.387 · libdovi        │
├──────────────────────────────────────────────┤
│ 输出                                          │
│  GPU surface（D3D11 / OpenGL / SurfaceView）  │
│  音频（WASAPI / CoreAudio / AudioTrack）      │
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

搜索还没实现——飞牛没有条目搜索接口，需要在客户端建索引（见 PLAN §1.1），
等 Emby 接入后一起做。

## 2. 播放内核接入（现状）

| 平台 | 接入方式 | 代码 |
| --- | --- | --- |
| Windows | 起官方 `mpv.exe`：`--wid=<子窗口>`，控制走 `--input-ipc-server=<命名管道>` 的 JSON IPC，进程用 Job Object 绑在壳上 | `apps/windows/DvPlayer/Player/`（`MpvProcess` / `MpvIpc` / `MpvHost`） |
| macOS | 链 libmpv 用 render API（ADR-0003），M0 已在 `m0-render` 上验到出画 | `apps/macos/m0-render/` |
| Android / TV | Media3，进程内 | 未开始 |

Windows 为什么用子进程而不是链 libmpv：见 [ADR-0009](adr/0009-windows-mpv-subprocess.md)。
要点是 `--wid` 只要求一个父 HWND，子进程照样让 mpv 自己建 VO 和 swapchain，
拿得到 `gpu-next` 的 FEL；换 mpv 版本只是换个 exe，不碰 MSVC 工具链与 C++ 运行时。
`core/mpv` 的 C++ 封装因此只留给 macOS。

### 2.1 macOS 的 libmpv 接口（未落地，仅设计）

```cpp
enum class SurfaceMode { WindowBinding, RenderApi };

struct Config {
  SurfaceMode mode;
  std::string vo;        // "gpu-next" | "gpu"
  std::string gpu_api;   // "d3d11" | "opengl"
  void*       native;    // HWND（Windows）；macOS 传 nullptr
  bool        hdr_passthrough = true;
};

class PlayerCore {
public:
  static std::unique_ptr<PlayerCore> create(const Config&);

  void open(const std::string& url);
  void command(std::string_view name, const std::vector<std::string>& args);
  void set(std::string_view prop, const mpv_node& v);
  mpv_node get(std::string_view prop);

  // macOS render 路径
  void render(int fbo, int w, int h, bool flip_y);
  void report_swap();

  void set_event_handler(std::function<void(const mpv_event*)>);
  void set_render_update_handler(std::function<void()>);
};
```

原则：事件线程独立跑 `mpv_wait_event`，UI 只收结构化事件；属性用
`mpv_observe_property`，不轮询；`mpv_node` 不裸传给 .NET，序列化成 JSON。

### 2.2 格式覆盖与降级策略

「什么都能放」靠的是内核能力 + 明确的降级路径，不是自己实现解码器：

| 环节 | 做法 | 现状 |
| --- | --- | --- |
| 硬解 | `hwdec=auto-safe`（D3D11VA / QSV / VideoToolbox / MediaCodec），失败自动软解，选择结果写日志 | Windows 已验 4K120 / 8K60 |
| HDR | `target-colorspace-hint=yes`：HDR 屏直通、SDR 屏 tone-map；元数据（HDR10 / HDR10+ / HLG）由内核识别 | 识别已验，直通待 HDR 屏 |
| DV | 交给 `gpu-next`：P7 双层合成、P5/P8 整形；拿不到增强层时只播 BL | P7 FEL 已验，P5 颜色待修 |
| 音频 | 默认解码混音；设置里可切直通（`audio-spdif=ac3,eac3,dts,dts-hd,truehd`），失败回落解码 | 未做 |
| 字幕 | PGS / ASS / SRT 走内核；Android 用 libass NDK 自绘 | 桌面未验，Android 未做 |

原则：**UI 显示的是实际行为，不是文件声称的格式**。播放页要给一条「源 → 输出」的信息
（例如 `DV P7 (FEL) → HDR10 直通`、`DV P7 → 本机只播 BL`），
避免"看起来支持、其实降级了"。

## 3. 线程模型

| 线程 | 职责 |
| --- | --- |
| mpv 进程（Windows） | 自己解复用、解码、渲染；壳通过 JSON IPC `observe_property` 收事件 |
| IPC 读线程 | 逐行读 mpv 的 JSON，切分事件交给 UI 线程 |
| UI 线程 | 接收事件，更新界面 |
| 渲染线程 | Windows 由 mpv 自己驱动；macOS 由 `CADisplayLink` 驱动 `mpv_render_context_render` |

macOS 注意：`mpv_render_context_set_update_callback` 里只做
`dispatch_async` 到主线程置 `needsDisplay`，不要在回调线程直接渲染。

## 4. Windows

- 顶层窗口 + 视频子 HWND，`HwndHost`（`MpvHost`）托管；`mpv --wid=<HostHandle>`。
- `vo=gpu-next`、`gpu-api=d3d11`、`gpu-context=d3d11`、`target-colorspace-hint=yes`。
- Airspace：XAML 画不到子 HWND 上面。控制条放视频外；临时提示用 mpv OSD；
  浮层窗口留到 v2。
- 全屏：resize 顶层窗口 + 子 HWND，不要重挂父窗口（M0 验证壳已实现，产品壳未接）。
- 进程生命周期：mpv 放进 Job Object，壳崩溃时子进程一起结束，不留后台播放。
- DPI：手动同步子 HWND 位置与尺寸。

## 5. macOS

- SwiftUI + `NSViewRepresentable` 包 `NSOpenGLView`，CGL 3.2 core。
- `mpv_render_context_create` 用 `MPV_RENDER_API_TYPE_OPENGL`。
- `MPV_RENDER_PARAM_OPENGL_FBO` + `FLIP_Y`。
- `hwdec=videotoolbox`；VideoToolbox 的矩形纹理路径是已知坑，M0 要压测 4K60。
- v1 不接 Metal、不接 MoltenVK。
- HDR10 走 `target-colorspace-hint`；不行就退固定 SDR tone-map 并在 UI 明示。

## 6. Android / TV

- Media3 + `SurfaceView`，TV 开 tunneling。
- 运行时用 `MediaCodecInfo` 探测 DV profile；探不到播 BL 轨并标 HDR10。
- ASS 字幕：NDK 编 libass 自绘。不给 TV 挂 libmpv 软解。
- 一个 module，两个 launcher activity；`androidx.tv:tv-material` 做 TV 皮肤。

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
