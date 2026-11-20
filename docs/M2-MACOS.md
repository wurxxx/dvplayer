# M2 · macOS 客户端

> 状态：壳与浏览链路可用（2026-11-20）；播放页未开始。
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
- 侧栏：服务器 / 记录 / 搜索 / 设置 + 服务器列表 + 连接状态（「媒体库」不单列菜单）
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

## 4. 下一步

1. **播放页**：`NSOpenGLView` + `mpv_render_context`，`--keep-open`、`--start`、
   音轨 / 字幕按 `aid` / `sid` 应用；浮层控件照 Windows（顶栏 48、右侧截图 / 选集、
   底部规格 chips + 控制条、3 秒淡出、单击暂停、双击全屏、Esc 退出）。
2. 播放页与库的进度回写、播完接下一集 / 关窗（和 Windows 同一套规则：
   切集一律从头、记录停在片尾的从 0 开始）。
3. 详情页里的音轨 / 字幕选择（`MediaInfo` 已读到，等播放页一起接 `TrackPrefs` 等价物）。
4. 键盘：空格 / ←→ / 上下键 / Esc，和 Windows 对齐。
