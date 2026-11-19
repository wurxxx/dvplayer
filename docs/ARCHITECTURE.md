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
