# M2 · macOS 客户端

> 状态：壳、浏览链路、播放页都可用（2026-11-21）；HDR10 只验过管线，DV 未做。
> 产物：`apps/macos/DvPlayer`（Swift Package + `build.sh` 出 `.app`）。

## 1. 范围

和 Windows 端一样的界面与行为，播放内核换成本机的 libmpv：

| 层 | 选型 | 说明 |
| --- | --- | --- |
| UI | SwiftUI + AppKit | 视觉规范沿用 [UI-DESIGN.md](UI-DESIGN.md)，色板 / 字号 / 组件一致 |
| 业务 | 共享核心 `core/media` | C ABI + JSON，和 Windows 是同一份 Rust 库 |
| 视频 | libmpv render API + `NSOpenGLView` | 见 [m0-render](../apps/macos/m0-render/)；v1 只做 HDR10，无 DV |
| 窗口 | 单窗口 + 无标题栏 | 侧栏 216 + 内容区，和 Windows 同骨架；窗口按钮自己画 |

`--wid` 在 macOS 上不可靠（ADR-0009），所以播放页走 render API：壳画出视频帧，
控件直接叠在 SwiftUI 层上，不像 Windows 那样需要两个窗口。

## 2. 已完成（浏览链路）

- 共享核心绑定：`Sources/DvCore/Core.swift`（串行队列 + `async/await`，JSON 解成强类型）
- 配置：`~/Library/Application Support/DvPlayer/settings.json`
- 侧栏：服务器 / 记录 / 搜索 / 设置 + 服务器列表（连上绿点 / 未连红点）+ 左下角只显示版本（「媒体库」不单列菜单）
- 服务器页：添加 / 编辑 / 删除源（删除走深色确认卡片，和 Windows 同一套视觉），
  连接状态与媒体库数量
- 源首页：和 Windows 一样三个页签——媒体（Hero 轮播 7 秒自动翻、悬停出箭头、
  没有横版图时海报放大模糊 + 我的媒体 + 继续观看 + 每库一行）/ 搜索（只搜当前源）/
  收藏（这个源收藏的视频）
- 网格：类别（全部 / 剧集 / 电影 / 风格 / 文件夹）、排序 + 升降序、风格标签、
  页内搜索、分页；右侧常显一条自绘滚动条（可点可拖，见下面的坑）
- 详情页：整块横版图铺满、渐变淡到页面底色、动作按钮（播放 / 重头看 / 收藏 /
  标记看过）、分季选集（296×166 横卡 + 悬停播放遮罩 + 进度条）、
  演职人员（96 宽头像卡，点开看作品，可继续往下钻详情）、豆瓣链接、
  媒体信息（视频、每条音轨、每条字幕各一张卡，横向排开）
- 音轨 / 字幕：播放旁按 Windows 的规则出现（音轨 > 1 条、字幕 > 0 条），
  点开是深色弹层，选完记进 `TrackPrefs`（和 Windows 一样只在内存里，
  键是这一集的 id），播放页照这份选 `aid` / `sid`
- 横向行：触控板横滑 + 悬停出左右箭头，按整屏翻、垂直居中，
  内容一屏放得下就不出箭头（`HorizontalRow`）
- 记录页：通用（继续观看按剧分组 + 视频收藏）/ 观看 / 收藏
- 搜索页：跨源搜索
- 设置页：续播、分辨率角标、自动连接、核心版本与配置路径

## 3. 踩过的坑

- **`ScrollView` 会画一层白底**：`NSScrollView` 自己画的背景在深色主题下也不受控。
  `ScrollStyle.swift` 用一个探针 NSView 向上找到它，改 `drawsBackground = false`、
  并隐藏系统滚动条。**在 `layout()` 里无条件改会触发布局死循环**（页面直接画不出来），
  只在值真的不同时写，并靠 `viewDidMoveToWindow` + 两拍延迟重试。
- **系统滚动条不出现，不怪样式**：SwiftUI `ScrollView` 里 `documentView.bounds.height`
  不是内容真实高度（实测 1224×38，而网格有一千多高），所以 `NSScrollView` 一直认为
  不用滚，`hasVerticalScroller = true` / `autohidesScrollers = false` 也没用。
  网格页的滚动条改成自绘：内容高度 / 偏移用 `GeometryReader` + `PreferenceKey` 量，
  右侧画一条圆角滑块，点击 / 拖动时直接改 `clipView` 的滚动位置。
- **SwiftUI `TextField` 只认自己那一小块**：搜索框的放大镜图标和左右内边距
  （`padding` / `frame` 多出来的部分）点了没反应，`onTapGesture` 挂在背景上
  对合成点击也不生效。搜索框统一换成 `NSSearchField`（`SearchField`），
  整块都能点进去；子类覆写 `acceptsFirstMouse` 让窗口失焦时第一下点击也能直接输入。
- **核心 dylib 的 install name 是 cargo 的构建目录**，运行期不存在。
  `build.sh` 打进 `.app/Contents/Frameworks` 并改成 `@rpath/...`。
- **截图**：没有屏幕录制权限，`screencapture` 拿不到画面；`cacheDisplay` / `dataWithPDF`
  对 SwiftUI 的 layer-backed 视图是空的。只有 `CALayer.render` 能截出内容
  （记得把坐标系翻回来）。长页面用 `DVPLAYER_SCROLL=end` 先滚到底再截。
  路径给 `.jpg` 就按 1x 出 JPEG（约 160KB）——2x PNG 常有 2–5MB，
  手机上加载容易超时看不到。
- **`DVPLAYER_CLICKTEST` 只能测 AppKit 控件**：合成 `NSEvent` 能让 `NSSearchField`
  拿到焦点，但点不动 SwiftUI 的 Button / `onTapGesture`（收藏按钮也点不动），
  所以「卡片可点」这类自检改成 `DVPLAYER_PICK_TRACK="subtitle:1"`：等详情读完，
  按点击的同一条逻辑切轨，再截图核对勾选和顶部文案。
- **集号会漏**：飞牛这一季就丢了第 6 集的 `episodeNumber`。直接按「顺序补号」会和
  第 1 集撞成两个 E01，现在用「没被占用的最小号码」补。分页补集时要把已经用掉的
  集号传进 `makeRows(_:used:)`，否则第二页会再从 1 补出一个 E01。
- **中文字幕不能只看语言字段**：飞牛适配器把 `language` 映射成了「中文」，
  而字幕轨 `title` 常常还是英文的 `Simplified Chinese` / `Traditional Chinese`，
  mpv 那边又可能给 `cmn-Hans`。判断中文要同时看 language 前缀（`zh` / `chi` / `cmn` / `yue`…）、
  `hans` / `hant`、以及标题里的 `Chinese` / `简` / `繁`。
- **详情页慢在两次 `/item/list`**：`detail` 只要 15–20ms，演职 20ms；季列表 0.5–2s、
  第一页集 0.5–3s，服务端波动很大且和 `page_size` 不完全成正比。所以别等全部数据
  再上屏：详情一到就画头部，集列表先取一页（`episodePageSize = 80`）铺出来，剩下的
  后台按页补进 `episodes`；同一部片 120 秒内再进直接走 `DetailCache`（0ms），
  收藏 / 标记看过会主动失效。
- **横向行会吃掉纵向滚轮**：`NSScrollView` 收到滚轮就不再往外传，鼠标停在海报行上
  整页就滚不动（Windows 版的老毛病）。`WheelBridge.swift` 用本地事件监听把纵向的
  转给外层页面滚动，横向的照旧交给行自己。
- **`.hiddenTitleBar` + fullSizeContentView 的系统红绿灯靠不住**：macOS 26 里窗口不在
  前台时会淡成灰点，深色侧栏上基本看不见；换成标准标题栏又会多出一条窗口边，
  不是满窗效果。最后的做法：保留满窗、把系统红绿灯藏掉，
  由 `ShellView` 的 `WindowControls` 自己画三个圆点（关闭 / 最小化 / 缩放），
  始终有颜色，悬停浮出符号。没人能手动点按钮时用 `DVPLAYER_WINDOWTEST=1` 自检：
  程序会合成鼠标事件依次点这三个圆点，日志里能确认 `mini=true`、窗口 frame
  变化、以及点关闭后进程正常退出。
- **确认框不要用 `.alert`**：系统弹窗的按钮、间距都不受控。删除这类操作统一走
  `ConfirmDialogView`（`AppState.askConfirm` 触发，`ShellView` 盖在整窗上），
  和 Windows 的 `ConfirmDialog` 用同一套卡片、红色危险按钮。
- **截图拍不到弹层**：popover / 菜单是独立窗口。截图时把其它可见窗口的图层
  叠上去（内容视图是翻转坐标系，要再翻一次）。

## 4. 播放页

### 4.1 管线

和 Windows 的「mpv 自己开窗口 + 壳贴上去」不同，macOS 走 render API（ADR-0009）：

```
core.playSource() ──► PlaySource(url, headers, position, duration, 轨道)
        │
        ├─► DVMpvView (ObjC++, Sources/MpvKit)
        │     mpv_create → mpv_initialize → mpv_render_context_create(OPENGL)
        │     事件线程 mpv_wait_event → 属性观察 → 主线程回调
        │     drawRect: mpv_render_context_render(FBO) → flushBuffer
        │
        └─► PlayerView (SwiftUI，NSHostingView 叠在 NSOpenGLView 上)
              顶栏片名 / 左上自绘三圆点 / 右侧截图·选集 /
              底部 chips + 控制条 / 选集面板 / 媒体信息面板 / 3 秒淡出
```

- `PlayerSession`：起播、切集、EOF 接下一集、进度回写（10 秒一次）、
  轨道解析与中文默认、规格 chips、截图、浮层自动隐藏。
- `PlayerWindowController`：单播放窗、自绘红黄绿、键盘、全屏、顶部 30px 拖窗区。
- `PlaylistLoader`：继续观看只有一条记录，要顺着 `parentId`（或剧名）把整季找回来；
  先播记录本身，选集后台补上（播放中 core 被拉流挤到 11–22 秒，不能挡起播）。
- 入口：详情页「播放 / 重头看 / 选集卡」、记录页与库首页的「继续观看」卡片。

### 4.2 打包

`build.sh` 把 `prefix/lib` 里 libmpv 和它的依赖（libass / libav* / libplacebo / libsw*）
一起拷进 `Contents/Frameworks`。这些 dylib 的 install name 是本机绝对路径，
统一改写成 `@rpath/<真实文件名>`：`libavcodec.63.dylib` 是软链，真实文件叫
`libavcodec.63.1.102.dylib`，所以引用名要用 `realpath` 映射到真实名，否则
dyld 找不到。改完用 `DYLD_PRINT_LIBRARIES=1` 确认没有一条来自 `prefix/lib`。

### 4.3 自检参数

| 环境变量 | 作用 |
| --- | --- |
| `DVPLAYER_PLAY=<itemId>` | 等核心连上后直接开播放窗 |
| `DVPLAYER_PLAY_CONTAINER=<剧集 id>` | 先列这一季的集，再带 playlist 打开（模拟详情页） |
| `DVPLAYER_PLAY_RECORD=1` | 从第一条观看记录续播（模拟「继续观看」，选集由 `PlaylistLoader` 补） |
| `DVPLAYER_PLAY_SEEK=<秒>` | 起播 2.5 秒后跳转 |
| `DVPLAYER_PLAY_UI=episodes\|info\|audio:N\|subtitle:N\|pause\|fullscreen\|close` | 拨浮层 / 切轨（N 是轨序号，字幕 -1 为关闭） |
| `DVPLAYER_PLAY_FRAME=<png>` | 读回 GL 前台缓冲存 PNG——截图工具拍不到 `NSOpenGLView`，这个才是屏幕上的画面 |
| `DVPLAYER_PLAY_SHOT=<png>` / `DVPLAYER_PLAY_SHOT_DELAY=` | 截播放窗的 SwiftUI 浮层 |
| `DVPLAYER_PLAY_SECONDS=<秒>` | 到点打印 `[PlayTest]` 状态（位置 / 时长 / 轨道 / playlist） |
| `DVPLAYER_MPV_LOG=1` | 打 mpv 日志与 GL 帧计数（`[gl] draws=`） |

日志前缀：`[Play] open / load / loaded / tracks / select / eof / report`、`[PlayTest]`、`[gl]`。

### 4.4 播放页的坑

- **`keep-open` 播完会停在暂停态**：续播点正好在片尾时 `loadfile` 同一文件，
  `pause` 不会自己复位，起播就卡住不动。`MPV_EVENT_FILE_LOADED` 里显式
  `pause=no` 一次；「片尾续播点」另有一条兜底：起播 3 秒内 EOF 且起点在片尾，
  直接从 0 重放。
- **EOF 后 `time-pos` 会复位**：关窗 / `stop()` 里再上报一次 `position` 会把刚写好的
  「已看完」覆盖成 1 秒。EOF 之后不再按 position 上报，只在 `!eof` 时回写。
- **起播立刻上报会把时长写成 0**：`lastReportAt` 从 `.distantPast` 起步时，
  第一个位置回调就触发上报，而 `duration` 还没下来。改成从起播时刻计时，
  并且 `total <= 0` 时干脆不写。
- **`CALayer.render` 拍不到 `NSOpenGLView`**：播放窗截图里视频区是黑的，
  浮层正常。验画面用 `DVMpvView -captureFrameTo:`（`glReadPixels` 读回前台缓冲）。
- **播放窗截图会被主窗口盖住**：`capture` 会把其它可见窗口当弹层叠上去。
  现在只叠 `level != .normal` 或 `NSPanel` 的窗口（popover / 菜单）。
- **坐标系翻转的判据**：主窗口的 `contentView` 是 SwiftUI hosting（flipped，要翻一次），
  播放窗是普通 `NSView` 容器（不用翻）。按 `view.isFlipped` 判断，不能只看
  `target === view`。
- **选集面板要落到当前集**：`ScrollViewReader` + `onAppear` / `onChange(of: itemId)`
  滚到正在播的那一集；列表用 `PlayerEpisode.list(from:season:)` 排号（和详情页
  `makeRows` 同一套「漏号用最小未占用号补」规则），否则飞牛的倒序会让 E70 排在最前。
- **全屏要求窗口是 key**：从终端 / 自检启动时 app 不在前台，`toggleFullScreen` 不生效
  （日志里 `key=false`）。正常点击时窗口是 key，不受影响；自检这条只能人工看。

## 5. 下一步

1. **DV**：Profile 5 的 RPU 整形（和 Windows 一样走 `--vf=format` + tone-map，
   或等 core 的 dovi 解析接进来）；macOS 目前只保证 HDR10 管线（`target-colorspace-hint`）。
2. **HDR 真屏验收**：这台机器是 SDR 屏，只能验 `video-params` 与渲染链路，
   真正的 PQ 输出要在 HDR 显示器上看一次。
3. 播放页细节对齐：顶栏右侧的倍速 / 静音指示（Windows 有，macOS 现在只在底部）、
   进度条缓冲段。

## 6. 旧的下一步（已完成）

1. ~~播放页~~：`NSOpenGLView` + `mpv_render_context`，`--keep-open`、`--start`、
   音轨 / 字幕按 `aid` / `sid` 应用；浮层控件照 Windows。
2. ~~进度回写、播完接下一集 / 关窗~~：切集一律从头、记录停在片尾的从 0 开始。
3. ~~详情页音轨 / 字幕选择~~：`TrackPrefs` 两端同名同规则。
4. ~~键盘~~：空格 / ←→ / 上下键 / Esc，和 Windows 对齐。
