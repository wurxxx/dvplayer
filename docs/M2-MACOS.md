# M2 · macOS 客户端

> 状态：壳、浏览链路、播放页都可用（2026-11-21）；播放走进程内 libmpv +
> render API（[ADR-0011](adr/0011-macos-libmpv-inprocess.md)），DV 路径与 Windows 同一条；
> 锁屏状态下已端到端跑通，画面待解锁后目视验收。
> 产物：`apps/macos/DvPlayer`（Swift Package + `build.sh` 出 `.app`）。

## 1. 范围

和 Windows 端一样的界面与行为，播放内核是本机编的 libmpv（gpu-next + OpenGL）：

| 层 | 选型 | 说明 |
| --- | --- | --- |
| UI | SwiftUI + AppKit | 视觉规范沿用 [UI-DESIGN.md](UI-DESIGN.md)，色板 / 字号 / 组件一致 |
| 业务 | 共享核心 `core/media` | C ABI + JSON，和 Windows 是同一份 Rust 库 |
| 视频 | 进程内 libmpv + render API | gpu-next 画进应用自己的 `NSOpenGLView`，Dolby Vision 整形与 FEL 合成走这里（ADR-0011） |
| 窗口 | 单窗口 + 无标题栏 | 侧栏 216 + 内容区，和 Windows 同骨架；窗口按钮自己画 |

`--wid` 在 macOS 上不可靠；render API 从 mpv 2026-11-22 起能用 gpu-next，
所以播放页是**单窗口**：视频画进应用自己的 `NSOpenGLView`，控制浮层叠在上面。

## 2. 已完成（浏览链路）

- 共享核心绑定：`Sources/DvCore/Core.swift`（串行队列 + `async/await`，JSON 解成强类型）
- 配置：`~/Library/Application Support/DvPlayer/settings.json`
- 侧栏：服务器 / 记录 / 搜索 / 设置 + 服务器列表（连上绿点 / 未连红点）+ 左下角只显示版本（「媒体库」不单列菜单）
- 服务器页：添加 / 编辑 / 删除源（删除走深色确认卡片，和 Windows 同一套视觉），
  连接状态与媒体库数量
- 源首页：和 Windows 一样三个页签——媒体（Hero 轮播 7 秒自动翻、悬停出箭头、
  没有横版图时海报放大模糊 + 我的媒体 + 继续观看 + 每库一行）/ 搜索（只搜当前源）/
  收藏（这个源收藏的视频）
- 源首页每个库那一行默认按「添加时间」倒序：预览显式传 `added` + 降序
  （`create_time DESC` / Emby `DateCreated`），和点进库里的默认排序一致，
  不依赖各家服务器的默认顺序。
- 网格：类别（全部 / 剧集 / 电影 / 风格 / 文件夹）、排序 + 升降序、风格标签、
  页内搜索、分页；右侧常显一条自绘滚动条（可点可拖，见下面的坑）
- 卡片副标题的片长用中文可读格式：「电影 · 2 小时 12 分钟」/「45 分钟」，
  和 Windows 的 `MediaText.Runtime` 一致；播放页进度 / 剩余时间仍然用时间码
- 详情页：整块横版图铺满、渐变淡到页面底色、动作按钮（播放 / 重头看 / 收藏 /
  标记看过）、分季选集（296×166 横卡 + 悬停播放遮罩 + 进度条）、
  演职人员（96 宽头像卡，点开看作品，可继续往下钻详情）、链接（豆瓣，源里有
  TMDB / IMDb id 时再加这两个）、
  媒体信息（视频、每条音轨、每条字幕各一张卡，横向排开）、
  存储位置（放在媒体信息之后；电影 / 单集给完整文件路径，剧集 / 季给所在目录，
  可选中复制）
- 音轨 / 字幕：播放旁按 Windows 的规则出现（音轨 > 1 条、字幕 > 0 条），
  点开是深色弹层，选完记进 `TrackPrefs`（和 Windows 一样只在内存里，
  键是这一集的 id），播放页照这份选 `aid` / `sid`
- 横向行：触控板横滑 + 悬停出左右箭头，按整屏翻、垂直居中，
  内容一屏放得下就不出箭头（`HorizontalRow`）
- 记录页：通用（继续观看按媒体源分栏，标题是源名 +「N 条」，状态点在左；下面是视频收藏一行）/ 观看 / 收藏
- 本地文件夹源：「服务器」页 → 添加 → 类型「本地文件夹」→ 选目录 →
  目录里的视频 / ISO 成为媒体库条目（见 `LOCAL-SOURCE.md`）；ISO 条目 `disc=true`。
- 原盘：ISO 条目 → `hdiutil` 挂载 → 读 `BDMV/PLAYLIST/*.mpls` → 直接播默认
  标题（最长的正片），其它标题在播放器右侧「标题」面板切（正片在前、花絮按
  标题号），和选集同一套 UI；播完直接关窗，不自动接花絮。
  随包的 mpv 没有 libbluray，所以播放不是 `bd://`，而是把 mpls 里的
  `(m2ts, IN_time, 时长)` 拼成一份 mpv EDL 播；切标题重新生成 EDL 再重启 mpv，
  盘不卸载；关播放窗时卸载 ISO。进度回写核心（本地源）。
  自检：`DVPLAYER_DISC=<iso>` + `DVPLAYER_DISC_TITLE=N`（不建源直接开 ISO）、
  `DVPLAYER_PLAY_UI=episodes,next` 切到下一个标题。
- 搜索页：跨源搜索；结果卡片直接进详情（全局 `AppState.detailItemId` 路由，切侧栏自动收起）。
  输入框保留上次关键词（`settings.searchKeyword`），切页 / 重启回来自动再搜一次；
  输入防抖会取消上一条待执行的搜索，不会每敲一个字并发一次请求。
- 记录页：「观看」的播放按钮直接 `PlayerLauncher.play(record:)`，收藏卡片进详情
- 设置页：续播、分辨率角标、自动连接、播放缓冲、核心版本与配置路径
- Emby 源播放实测（2026-11-21）：Monta HD（Emby 4.9.3、https + openresty 反代、
  HTTP 代理）直链 `Static=true` 在 mac 上正常出画，mpv 解出 4K HEVC + 2 条音轨；
  每 10 秒 `Progress`、关窗 `Stopped` 都能落盘（服务器 `PlaybackPositionTicks`
  跟着变）。这条链路原本被 FFmpeg 缺 TLS 挡住了，见 §4.7。

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

视频和控件在同一个窗口里（[ADR-0011](adr/0011-macos-libmpv-inprocess.md)）：

```
core.playSource() ──► PlaySource(url, headers, position, duration, 轨道)
        │
        ├─► MpvEngine（进程内 libmpv，render API）
        │     vo=libmpv，renderer=gpu-next，GL 上下文由 MpvVideoView 提供
        │     事件走 mpv_wait_event 线程回调，不再有 IPC
        │
        └─► PlayerWindowController（NSWindow）
              ├─ MpvVideoView（NSOpenGLView）：mpv 渲染到自己的 GL framebuffer
              └─ PlayerView（SwiftUI）：顶栏 / 控制条 / 选集 / 媒体信息 / 3 秒淡出
                 透明，盖在视频上
```

- `MpvClient`：`mpv_create` + 选项 + `mpv_initialize`；事件线程跑
  `mpv_wait_event`，属性事件和命令回复按 id 分发、切回主线程；渲染上下文在
  渲染队列上建（`MPV_RENDER_API_TYPE_OPENGL`），每次 `render` 到 FBO 0 后
  `flushBuffer`。
- `MpvEngine`：订阅属性（`time-pos` / `duration` / `pause` /
  `eof-reached` / `speed` / `volume` / `mute` / `track-list` / `aid` / `sid` /
  `paused-for-cache`），
  暴露 loadfile / seek / 音量 / 静音 / 倍速 / 选轨 / 截图 / `shutdown`。
- 打开 / 切集先铺不透明黑底（片名 +「正在打开…」+ 转圈）。起播时 mpv 先
  `pause=yes`，`vo-configured` 就绪后 unpause，声音和画面一起开始；首帧看
  `video-frame-info`，`time-pos > 起播点 + 0.5`（片头跳过后从跳到的位置算）
  兜底，`file-loaded` 不再直接收黑底。播放中卡住（`paused-for-cache`）只在
  画面中间浮一个「正在缓冲…」小胶囊，不盖画面、不藏控制条。
- 打开阶段三个窗口圆点（关闭 / 最小化 / 全屏）照常显示，顶部 30px 拖窗区
  也不被黑底挡住；单击黑底只把窗口选中，不切暂停。黑底上双击走**最大化 /
  还原**（`actions.zoom()`），和 Windows 一致；进假全屏会把三个圆点收掉，
  打开阶段不能这么干。
- 选集超过 30 集时标题下有 `1-30 / 31-60 …` 段按钮（复用 `FlowChips`，放不下自动
  换行、行间距 8 pt，不用横向滚动）：点一下先补页、再把横向选集行滚到那一段第 1 集。滚动用 `Components.swift` 的
  `RowJumpBridge` 直接设行内 `NSScrollView` 的横向偏移——SwiftUI 的 `scrollTo`
  在卡片刚插进 `HStack` 的那一轮会静默失效。回归：`DVPLAYER_DETAIL=<id>
  DVPLAYER_RANGE=31 DVPLAYER_SCROLL_Y=430 DVPLAYER_SHOT=…`，日志应有
  `[Detail] range jump 31-60 -> E31`，截图里集行从 E31 开始。
- 打开失败（取地址失败 / 播放器退出）时窗口不关：黑底上显示原因和
  「重试 / 关闭」。重试会按原参数重跑；mpv 核心已经销毁时先换一个新实例。
  自检：`DVPLAYER_PLAY=bogus DVPLAYER_PLAY_RETRY=1`，日志应出现 `[Play] retry`
  且错误面板仍在。
- 服务器图标：服务器卡片和侧栏名字左边都显示源自己的图标（飞牛官方牛头 / Emby
  官方绿菱形 / Jellyfin 官方紫青三角 / 本地文件夹 / SMB 共享 / NFS 硬盘 / WebDAV 云）。
  图标文件是仓库 `assets/sources/` 下同一份（`scripts/make-source-icons.py` 生成，
  两端共用），`build.sh` 拷进 `Contents/Resources/sources/`，代码走
  `SourceIcon`。侧栏的连接状态点叠在图标右下角。
- Emby / Jellyfin 的报错按源类型显示：两者共用同一份适配器，现在 `EmbySource`
  带 `label`，Jellyfin 源报「Jellyfin：…」，不再自称 Emby。
- 网络服务器的 HTTP 代理存在 `SourceConfig.proxy`：核心接口请求走
  `http_client`，海报走 `PosterStore` 里按代理缓存的 `URLSession`
  （`connectionProxyDictionary`），播放通过 mpv 的 `http-proxy` 属性设置。
  空代理 = 直连。
- `PlayerSession`：起播、切集、EOF 接下一集、进度回写（10 秒一次）、
  轨道解析与中文默认、规格 chips、截图、浮层自动隐藏。
- `PlayerWindowController`：单窗口 + 假全屏 + 键盘 / 滚轮。
- `PlaylistLoader`：继续观看只有一条记录，要顺着 `parentId`（或剧名）把整季找回来；
  先播记录本身，选集后台补上（播放中 core 被拉流挤到 11–22 秒，不能挡起播）。
- 入口：详情页「播放 / 重头看 / 选集卡」、记录页与库首页的「继续观看」卡片。

### 4.2 窗口与全屏

- 单窗口：`MpvVideoView` 在底层，SwiftUI 控制层用 `NSHostingView` 盖在上面，
  没有跨窗口同步。
- 缩放 / 全屏：`MpvVideoView` 的 `layout` 里重建 GL viewport，mpv 按新尺寸重排
  字幕与 OSD；窗口拖动只移动一个窗口，画面天然同帧。
- 窗口按钮：自绘三个圆点，缩放走 `zoom()`（屏幕可见区域最大化，单独记一个
  `zoomSavedFrame`，不和全屏的 `savedFrame` 混用）。
- **假全屏**：窗口铺满 `screen.frame`，同时 `NSApp.presentationOptions =
  [.autoHideMenuBar, .autoHideDock]`；退出时恢复 `[]` 和原 frame。
- 关闭窗：`windowWillClose` 里先摘事件监听，再 `session.stop()` →
  `MpvEngine.shutdown()`（销毁渲染上下文 → `mpv_terminate_destroy`；
  事件线程先 `mpv_wakeup` 再等它退出，避免与 `mpv_wait_event` 并发）。

### 4.3 打包

两层脚本，和 Windows 的 `build.sh` / `build-release.ps1` 对应：

| 脚本 | 产物 | 用途 |
| --- | --- | --- |
| `apps/macos/DvPlayer/build.sh` | `build/DvPlayer.app` | 日常开发，编完就地能双击跑 |
| `apps/macos/packaging/build-release.sh` | `out/release/DvPlayer-<版本>-macos-<arch>.{dmg,zip}` | 发布：DMG 安装镜像 + 便携 zip |

`build.sh` 往 `.app` 里带的东西：

| 来源 | 内容 |
| --- | --- |
| `prefix/lib` | libmpv + libass / libav* / libsw* / libplacebo（进程内播放，ADR-0011） |
| Homebrew 的 fribidi / harfbuzz / fontconfig / freetype / jpeg | 上面那几个的依赖，一起拷进去 |
| `core/target/release/libdvplayer_media.dylib` | 共享核心 |
| `assets/branding/` + `assets/sources/` | 应用图标、侧栏品牌图、各协议源图标 |

- 所有 dylib 的 install name 都是本机绝对路径，统一改写成 `@rpath/<真实文件名>`
  （`libavcodec.63.dylib` 是软链，真实文件叫 `libavcodec.63.1.102.dylib`，
  用 `realpath` 映射），再补 `@executable_path/../Frameworks` 的 rpath。
- 成品 ~39MB，`otool -L` 全过一遍没有 `prefix*` / 本机路径残留。
- **签名必须自内向外**：先 `Contents/Frameworks/*.dylib`，再整个 `.app`。
  直接签 `.app` 会报 `code object is not signed at all`（内层还没签）。
  默认 ad-hoc（`codesign --sign -`），没有公证证书，别人首次打开要右键「打开」。
  有证书时 `SIGN_IDENTITY="Developer ID Application: xxx"`，公证自己跑 `notarytool`。
- zip 用 `ditto` 而不是 `zip`，否则会破坏代码签名；包名统一成 `DV Player.app`
  （和 Finder / Dock 显示名一致）。

### 4.4 自检参数

| 环境变量 | 作用 |
| --- | --- |
| `DVPLAYER_PAGE=records\|search\|sources\|settings` | 启动直接落在某页（见 `AppState`） |
| `DVPLAYER_LIBRARY=<库 id>` | 直接打开某个库的网格（配合 `DVPLAYER_CAT` 截图） |
| `DVPLAYER_CAT=全部\|剧集\|电影\|风格\|文件夹` | 网格页直接落到某个类别 |
| `DVPLAYER_RECORD_TAB=favorites\|watch` | 记录页直接停在「收藏」/「观看」分段，截图回归用 |
| `DVPLAYER_PLAY=<itemId>` | 等核心连上后直接开播放窗 |
| `DVPLAYER_PLAY_CONTAINER=<剧集 id>` | 先列这一季的集，再带 playlist 打开（模拟详情页） |
| `DVPLAYER_PLAY_RECORD=1` | 从第一条观看记录续播（模拟「继续观看」，选集由 `PlaylistLoader` 补） |
| `DVPLAYER_PLAY_RECORD_WAIT=<秒>` | 续播时等选集补完再打印状态（飞牛 `/item/list` 慢，默认不等） |
| `DVPLAYER_PLAY_SEEK=<秒>` | 起播 2.5 秒后跳转 |
| `DVPLAYER_PLAY_UI=episodes\|info\|audio:N\|subtitle:N\|pause\|fullscreen\|close` | 拨浮层 / 切轨（N 是轨序号，字幕 -1 为关闭） |
| `DVPLAYER_PLAY_UI=aspect:fit\|fill\|stretch\|ratio16x9\|ratio4x3` | 切画面比例 |
| `DVPLAYER_PLAY_UI=sleep:15` / `sleepepisode` / `nosleep` | 设定时关闭（分钟，可带小数） |
| `DVPLAYER_PLAY_UI=mark:intro\|outro\|clear` | 按当前位置标记片头结束 / 片尾开始 / 清除 |
| `DVPLAYER_PLAY_UI=skipoutro` | 触发「跳过片尾」（seek 到片长 − 0.4 秒） |
| `DVPLAYER_PLAY_UI=danmaku:on\|off` | 开关弹幕（凭据打包时内置；没有凭据的开发构建不联网） |
| `DVPLAYER_PLAY_UI=audioout` | 打印音频输出设备列表与当前直通状态 |
| `DVPLAYER_PLAY_UI=audiotoggle` | 切一次音频直通 + HDR 直通（走 set_property + 落盘） |
| `DVPLAYER_PLAY_UI=audiodevice:N` | 选第 N 个音频输出设备 |
| `DVPLAYER_PLAY_UI=speed:1.5` / `mute` | 改倍速 / 静音（验证顶栏状态），多项用逗号连起来 |
| `DVPLAYER_PLAY_UI=seek:<秒>` | 精确定位（配合 `pause` 做同帧对比，`fel-ab.sh` 在用） |
| `DVPLAYER_VF=<vf>` | 注入 mpv 的 `vf` 链（`fel-ab.sh` 用 `format=enhancement-layer=no` 关增强层做对照） |
| `DVPLAYER_BUFFER_MB=<MB>` | 临时覆盖播放缓冲（自检时压小才看得到未缓冲段） |
| `DVPLAYER_PLAY_UI=danmakufile:<ass>` | 直接挂一份本地弹幕 ASS（不联网，自检用） |
| `DVPLAYER_PLAY_UI=subsearch` | 打开字幕面板并搜索 |
| `DVPLAYER_PLAY_UI=subload:N` / `subauto` | 下载第 N 条 / 自动下载第一条 |
| `DVPLAYER_DANDANPLAY_BASE` / `DVPLAYER_OPENSUBTITLES_BASE` | 指向本地假服务器做离线联调 |
| `DVPLAYER_PLAY_FRAME=<png>` | 从应用自己的 GL framebuffer 抓一帧（含 gpu-next 的 DV 整形；mpv 的 `screenshot-to-file` 在 render API 下会退回软件路径、颜色不对） |
| `DVPLAYER_PLAY_SHOT=<png>` / `DVPLAYER_PLAY_SHOT_DELAY=` | 截播放窗的 SwiftUI 浮层 |
| `DVPLAYER_PLAY_SECONDS=<秒>` | 到点打印 `[PlayTest]` 状态（位置 / 时长 / 轨道 / playlist） |
| `DVPLAYER_OPENING_HOLD=1` | 假装首帧一直没来，验证打开遮罩一直不透明 |
| `DVPLAYER_BUFFERING_HOLD=1` | 出画后强制显示「正在缓冲…」小胶囊 |

日志前缀：`[Play] open / load / loaded / tracks / select / eof / report`、`[PlayTest]`。
mpv 自己的日志**总是**写在 `NSTemporaryDirectory()/dvplayer-mpv.log`（`.app` 里
没有终端，出问题先看这个），不需要额外开关。

### 4.5 画面比例 / 定时关闭 / 片头片尾 / 音频输出

- **画面比例**：`PlayerSession.aspect`（`fit` / `fill` / `stretch` / `16:9` / `4:3`）
  → `MpvEngine.setAspect` 发 `keepaspect` / `panscan` / `video-aspect-override`。
  `video-aspect-override` 是逐文件的，每次 `file-loaded` 都重套一次；选择存
  `AppSettings.videoAspect`。
  **适应窗口**还会按视频的显示宽高比改窗口：mpv 推 `video-params/aspect`，
  `PlayerWindowController.fitWindowToVideo` 以当前窗口高度为基准算出宽度
  （竖屏短剧就是竖窗口），夹进屏幕可见区域并居中，画面铺满、不留黑边；
  全屏 / 最大化 / 手动改过窗口时不抢尺寸，退出全屏或最大化还原后再适配。
  浮层宽度 < 640 时底部只留传输 + 进度 + 「更多」（静音 / 音量 ±10 / 音轨 / 字幕 /
  倍速作为子菜单进「更多」），不做第二行；chips 横向可滚动。
- **顶栏状态**：右上角显示倍速（非 1×）和静音图标，和 Windows 顶栏对齐。
- **动态范围徽标**：`MpvEngine` 观察 `current-tracks/video` 的
  `dolby-vision-profile` 与 `video-params` 的 `transfer`，chips 显示
  `DV P5/P7/P8` / `HDR10` / `HLG` / `SDR`（实际输出，服务端值只做兜底）。
  P7 再按 RPU 判 FEL / MEL：`PlayerSession.probeDolbyVisionIfNeeded` 在
  `dvProfile == 7` 时调核心 `dv_probe_dovi`（只读码流前缀 8 MB，解析
  `disable_residual_flag`），按条目缓存，徽标拼成 `DV P7 (FEL)` /
  `DV P7 (MEL)`；探不到或失败就退回 `DV P7`，不影响播放。
- **进度条三层**：`PlayerView.seekBar` 自绘（不再用 `Slider`），
  已观看 = `Theme.accent`、已缓冲 = 白 55%、未观看 = 白 22%；
  `MpvEngine` 观察 `demuxer-cache-time`，`PlayerSession.bufferedPosition`
  取值（seek 后重置到目标位置）。点击 / 拖动用 `DragGesture(minimumDistance: 0)`，
  松手才 `setScrubbing(false)` 真 seek。
- **缓冲大小可配**：设置 → 播放 →「播放缓冲」，`AppSettings.bufferSizeMb`
  （可选，缺省 512）映射成 `--demuxer-max-bytes`，回看缓冲取一半；
  `DVPLAYER_BUFFER_MB` 可临时覆盖（自检压到 8 看未缓冲段）。
  这个字段必须是可选值：老配置没有这个键，非可选会让整个 settings.json 解不出来。
- **定时关闭**：`sleepDeadline` / `sleepEndOfEpisode` 两个状态；`tick()`（1 秒）里
  检查，到点提示后关窗（`requestClose`，进度照常回写）；「本集结束后」在
  `handleEOF` 里关窗、不接下一集。剩余时间进 chips（`定时 12:34`）。
- **片头片尾**：`SkipMarkers.swift` 的 `SkipMarkerStore` 按剧名（电影按条目 id）存
  `~/Library/Application Support/DvPlayer/skip-markers.json`。`onLoaded` 里
  `skipIntroIfNeeded()`（只有起播点早于片头结束才跳）；`handlePosition` 里进入
  片尾区间置 `showSkipOutro`，浮层右下角出「跳过片尾」，点了 seek 到片长 − 0.4 秒，
  由 EOF 走正常的接下一集 / 关窗逻辑。
- **音频输出 / 音频直通 / HDR 直通**（和 Windows B13 对齐）：播放页「更多 →
  音频输出」列出 mpv 的 `audio-device-list`（当前设备打勾，`auto` 显示成
  「系统默认（自动选择）」），下面两个开关切 `audio-spdif` 与
  `target-colorspace-hint`。三项都落 `settings.json`（`audioDevice` /
  `audioPassthrough` / `hdrPassthrough`），`MpvEngine` 起 mpv 时当命令行参数带上，
  换集重启保持。mpv 的观察值会回写状态（拒绝或归一化时界面跟着变），
  切换后 `[Play] audio device=… passthrough=… hdr=… devices=N` 落日志。
  自检：`DVPLAYER_PLAY_UI=audioout` 打印设备列表，`audiotoggle` 切两个开关，
  `audiodevice:<序号>` 选设备。

### 4.6 弹幕与在线字幕

弹幕凭据是**内置**的：设置页只剩「打开播放页时默认开弹幕」一个开关，
用户什么都不用填。`在线字幕（OpenSubtitles）` 仍是自己填的一张卡
（API Key + 可选用户名 / 密码 + 搜索语言）：输入直接写回 `settings.json`
（清空即视为没填），卡片底部一行小字显示「已配置 / 还没填全」。

**音轨 / 字幕菜单的文案**

- 字幕菜单只写「语言 · 标题」：`TrackPrefs.subtitleLabel` 把 `chi` / `eng` 翻成
  中文名，把 `HDMV PGS_SUBTITLE`、`subrip` 这类容器 / 编码标题和纯序号（`1`、`2`）
  当作没有标题；只有语言就只显示语言，两个都没有时用「字幕 N」，重名再追加序号
  （`中文 1`）。mpv 只给容器标题时，按轨序从服务器的 `MediaInfo.subtitles` 补语言
  （原盘 / remux 的 `track-list` 常常 `lang` 为空）。
- 播放器菜单读 mpv 的 `track-list`，详情页 / 媒体信息卡读服务器的
  `MediaInfo.subtitles`，两边共用同一个函数。

**弹幕（弹弹play）**

- 按「剧名 + 集号」匹配：`/api/v2/search/episodes?anime=&episode=` → episodeId，
  再取 `/api/v2/comment/{episodeId}?withRelated=true&chConvert=1`。
  电影没有集号：按片名再搜一次，只认 `type == "movie"`、片名去掉空白标点后
  完全一致的条目；宁可没有也不挂错（同名 TV 动画也会出现在结果里）。
  好莱坞动画（《疯狂动物城 2》《功夫熊猫》这类）在弹弹play 库里没有条目。
  这条接口**只回 JSON**（`{"comments":[{"p":"time,mode,color,uid","m":"text"}]}`），
  老版本是 XML；`DanmakuParser` 两种都认（先看开头是不是 `{`）。
  `p` 的段数也不同：XML 8 段（字号在 [2]、颜色在 [3]），JSON 4 段（颜色在 [2]、
  没有字号）。只认 XML 的时候解析结果是 0 条，表现成「这一集没有弹幕」。
- v2 鉴权要三个头：`X-AppId`、`X-Timestamp`、`X-Signature`，签名是
  `Base64(SHA256(AppId + Timestamp + Path + AppSecret))`（Path 不含 query）。
- 弹幕转 ASS（滚动 9 秒 / 顶部 / 底部 4 秒，按行错开避免重叠），
  写到 `~/Library/Caches/DvPlayer/danmaku/DVPlayer-danmaku-<episodeId>.ass`，
  再用 `sub-add` 挂上、`secondary-sid` 让弹幕和正片字幕**同时**显示。
  弹幕轨不进字幕菜单：按 `external-filename` 过滤掉。
- `settings.json` 里只剩 `danmakuEnabled`（默认关）。凭据不在这里：打包时由
  `apps/macos/DvPlayer/build.sh` 从本地密钥文件（默认
  `~/.config/dvplayer/danmaku.env`，或环境变量 `DVPLAYER_DANMAKU_APP_ID` /
  `DVPLAYER_DANMAKU_APP_SECRET`）写进 `Info.plist` 的 `DVDanmakuAppId` /
  `DVDanmakuAppSecret`，运行时 `DanmakuCredential` 从 bundle 读。
  仓库、`settings.json` 里都没有，用户也不用申请。
  直接 `swift build` 的二进制没有 bundle，读不到凭据 → 弹幕安静关闭（日志一行）。
- 切集重新匹配；上一集晚到的绑定回调用 `loadGeneration` 丢掉。

**在线字幕（OpenSubtitles）**

- `openSubtitlesApiKey` 必填；`openSubtitlesUsername` / `openSubtitlesPassword`
  可选，配了会先 `/login` 换 token，下载时带 `Authorization: Bearer`。
- 搜索 `/subtitles`：剧集带 `type=episode` + `season_number` / `episode_number`
  （季号从选集角标的 `S01E02` 取），电影只带标题；语言默认 `zh-cn,zh-tw,en`
  （`subtitleLanguages` 可改）。
- 选中一条 → `POST /downloads` 拿临时链接 → 下载到
  `~/Library/Caches/DvPlayer/subtitles/` → `sub-add select` 直接选上。
- 面板是右侧 380 宽的 `字幕搜索`：语言 + 发行名 + 下载数；没配 key 时面板里
  直接写明缺什么，不弹窗。

**Trakt（观看记录）**

- 设备码登录：`POST /oauth/device/code` 拿 8 位码 → 轮询 `/oauth/device/token`
  （400 = 还没确认，410 = 过期，418 = 拒绝）。token 存
  `~/Library/Application Support/DvPlayer/trakt.json`（0600）。
  refresh token 是单次的（一次换一个），所以 `TraktClient` 用 actor 串行刷新。
- 应用凭据：`build.sh` 从 `~/.config/dvplayer/trakt.env`
  （`TRAKT_CLIENT_ID` / `TRAKT_CLIENT_SECRET`）注入 `Info.plist`
  （`DVTraktClientId` / `DVTraktClientSecret`）；设置页里填的值优先，
  没内置凭据的构建会显示两个输入框。
- 匹配优先用库里的外部 id：`MediaDetail.tmdbId` / `imdbId`（Emby / Jellyfin
  的 `ProviderIds`，列表和详情都取）→ `GET /search/tmdb/{id}?type=movie|show`
  或 `/search/imdb/{id}?type=...`，缓存键 `movie|tmdb|253` 这种。没有 id、或 id
  查不到时才回落「片名 + 年份」搜 `/search/movie|show`：标题完全一致优先；中文
  片名在 Trakt 上显示成原名（「千与千寻」→ Spirited Away），标题对不上时取年份
  差 ≤1 的第一条；本地没有年份、搜索结果又只有一条才采用。结果缓存到
  `trakt-matches.json`。宁可没有也不挂错。飞牛详情接口不返回 id（列表的
  `imdb_id` 也常为空），这类源只能走标题。
- 播放页：出画 5 秒后 `scrobble/start`，暂停 / 继续发 `pause` / `start`，
  关窗或播完发 `stop`（播完按 100% 报，Trakt 才会记成已看）；剧集带
  `season` + `number`，电影只带 `movie`。
- 从库页 / 继续观看直接起播时没有详情页带下来的剧名 / id：电影退回条目自己的
  标题，再查一次条目详情补年份和 id（`traktMeta()`），这种入口也会上报。
- 详情页「Trakt」按钮：评分 1–10、加入收藏（collection）、加入待看（watchlist），
  打开时先读一次当前状态。按钮只在包里有应用凭据时出现。详情页的链接区在豆瓣
  后面按 id 补「TMDB」（`themoviedb.org/{movie|tv}/{id}`）和「IMDb」
  （`imdb.com/title/{id}/`），没有 id 的源不摆。
- 发布包内置 Client ID，设置页只剩「连接 Trakt」/ 状态 / 自动同步开关；
  直接 `swift build` 或没配 `trakt.env` 的构建才显示自建应用的输入框。

### 4.7 播放页的坑

- **`--no-config` 之外还必须 `--idle=yes`**：壳是先起进程、再通过 IPC `loadfile`，
  命令行上没有文件名，不带 `--idle=yes` 时 mpv 直接打印用法退出（IPC 连不上）。
- **`loadfile` 的 options 在 IPC 里不能用逗号串**：`start=96.000,pause=no`
  会报 `The loadfile option must be an integer`。改成先 `set_property start`
  再 `loadfile <url> replace`。
- **这个构建禁了 lua，没有 `osc` / `no-osc` 选项**：传了会 `Error parsing option`
  直接退出。不留 OSC 是因为浮层就是我们的 OSC。
- **`keep-open` 播完会停在暂停态**：续播点正好在片尾时 `loadfile` 同一文件，
  `pause` 不会自己复位，起播就卡住不动。`file-loaded` 里显式 `pause=no` 一次；
  「片尾续播点」另有一条兜底：起播 3 秒内 EOF 且起点在片尾，直接从 0 重放。
- **EOF 后 `time-pos` 会复位**：关窗 / `stop()` 里再上报一次 `position` 会把刚写好的
  「已看完」覆盖成 1 秒。EOF 之后不再按 position 上报，只在 `!eof` 时回写。
- **起播立刻上报会把时长写成 0**：`lastReportAt` 从 `.distantPast` 起步时，
  第一个位置回调就触发上报，而 `duration` 还没下来。改成从起播时刻计时，
  并且 `total <= 0` 时干脆不写。
- **`duration` 会留上一集的值**：`file-loaded` 比新的 `duration` 属性先到，
  切集时要先把 `duration` 清 0，否则日志和记录会写上一集的长度。
- **播放窗截图会被主窗口盖住**：`capture` 会把其它可见窗口当弹层叠上去。
  现在只叠 `level != .normal` 或 `NSPanel` 的窗口（popover / 菜单）。
  播放窗自己就是 `level = normal + 1`，所以它不会被别的普通窗口压住。
- **选集面板要落到当前集**：`ScrollViewReader` + `onAppear` / `onChange(of: itemId)`
  滚到正在播的那一集；列表用 `PlayerEpisode.list(from:season:)` 排号（和详情页
  `makeRows` 同一套「漏号用最小未占用号补」规则），否则飞牛的倒序会让 E70 排在最前。
- **`sub-add` 在 JSON IPC 里不返回轨道 id**：命令回复是 `null`，只能加完再查
  `track-list`，按 `external-filename` 找到刚加的那条，再设 `secondary-sid`。
- **没有主字幕时 `sub-add auto` 会抢主字幕**：弹幕加进去后要把 `sid` 设回 `no`，
  否则 `sid` 和 `secondary-sid` 指向同一条，画面叠两遍。
- **弹幕 ASS 的文本要转义**：`{}` 是样式指令、`\` 是转义符，弹幕里换成全角字符；
  换行换成空格。颜色是 ASS 的 `&HAABBGGRR`，弹弹play 给的是 `0xRRGGBB`。
- **FFmpeg 必须显式开 TLS**：`build-deps-macos.sh` 里用了 `--disable-autodetect`，
  只开 `--enable-videotoolbox` / `--enable-audiotoolbox` 时 FFmpeg 没有任何 TLS 后端，
  `--list-protocols` 里没有 `https://`，mpv 报
  `No protocol handler found to open URL`，内网 `http://` 的飞牛正常、Emby / Jellyfin
  这类 https 源全挂。加 `--enable-securetransport` 重编后 `https://` / `tls://` 都在。
- **关窗时的进度上报要同步等**：`NSApp.terminate` / 关窗会直接结束进程，原来
  `report(...)` 里的 `Task` 常常还没跑到网络请求就被带走，服务器位置停在旧值
  （日志有 `stopped=true` 但 Emby 的 `PlaybackPositionTicks` 不变）。现在
  `requestClose()` / `stop()` 走 `Core.reportBlocking`：核心队列 `async` + 信号量等
  最多 2 秒，主线程阻塞在这条独立串行队列上不会死锁。
- **Emby 的进度只在 `Stopped` 落盘**：`Sessions/Playing/Progress` 返回 204 但不改
  `UserData`，必须发 `Sessions/Playing/Stopped`（关窗 / 播完）。这套由 `core/media`
  统一处理，mac 和 Windows 走同一条路径。
- **经代理 seek 到中段会长时间卡住**：Monta HD 的 https 源在反代后面，
  `--start=90` 之类的中段请求会 504 / 长时间没有数据，自检里表现为
  `loading=true`、`pos` 不动。从头播（start=0）正常，起播本身也要 30～40 秒。

## 5. 下一步

1. **DV 目视验收**：产品路径已经是 gpu-next + render API（ADR-0011），
   `./scripts/fel-ab.sh samples/p7-fel.mkv 8` 同帧开关增强层的 PSNR 约 49、
   `>2` 像素约 1%，说明 EL 进了 shader；剩下的只是拿 HDR 屏做一次目视。
2. **解锁后的播放页观感**：单窗口出画、控制层覆盖、拖动 / 缩放 / 假全屏的手感。
3. **HDR 真屏验收**：这台机器是 SDR 屏，只能验 `video-params` 与渲染链路，
   真正的 PQ 输出要在 HDR 显示器上看一次。
4. ~~音频输出 / 直通 / HDR 开关~~ **已完成**（2026-11-21，与 Windows B13 对齐）：
   「更多 → 音频输出」列设备、两个开关切 `audio-spdif` / `target-colorspace-hint`，
   落 `settings.json`；真机听感与 HDR 真屏仍待设备（§5 第 3 项）。
5. **公证与 Sparkle**：`.app` 未签名、未做自动更新。

## 6. 旧的下一步（已完成）

1. ~~播放页~~：`NSOpenGLView` + `mpv_render_context`，`--keep-open`、`--start`、
   音轨 / 字幕按 `aid` / `sid` 应用；浮层控件照 Windows。
2. ~~进度回写、播完接下一集 / 关窗~~：切集一律从头、记录停在片尾的从 0 开始。
3. ~~详情页音轨 / 字幕选择~~：`TrackPrefs` 两端同名同规则。
4. ~~键盘~~：空格 / ←→ / 上下键 / Esc，和 Windows 对齐。
