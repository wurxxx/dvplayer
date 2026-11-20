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
| 窗口 | 单窗口 + 隐藏标题栏 | 侧栏 216 + 内容区，和 Windows 同一个骨架 |

`--wid` 在 macOS 上不可靠（ADR-0009），所以播放页走 render API：壳画出视频帧，
控件直接叠在 SwiftUI 层上，不像 Windows 那样需要两个窗口。

## 2. 已完成（浏览链路）

- 共享核心绑定：`Sources/DvCore/Core.swift`（串行队列 + `async/await`，JSON 解成强类型）
- 配置：`~/Library/Application Support/DvPlayer/settings.json`
- 侧栏：服务器 / 记录 / 搜索 / 设置 + 服务器列表 + 连接状态（「媒体库」不单列菜单）
- 服务器页：添加 / 编辑 / 删除源，连接状态与媒体库数量
- 源首页：Hero 轮播（7 秒自动翻、悬停出箭头、没有横版图时海报放大模糊）、
  我的媒体、继续观看、每库一行
- 网格：类别（全部 / 剧集 / 电影 / 风格 / 文件夹）、排序 + 升降序、风格标签、
  页内搜索、分页
- 详情页：整块横版图铺满、渐变淡到页面底色、动作按钮（播放 / 重头看 / 收藏 /
  标记看过）、分季选集
- 记录页：通用（继续观看按剧分组 + 视频收藏）/ 观看 / 收藏
- 搜索页：跨源搜索
- 设置页：续播、分辨率角标、自动连接、核心版本与配置路径

## 3. 踩过的坑

- **`ScrollView` 会画一层白底**：`NSScrollView` 自己画的背景在深色主题下也不受控。
  `ScrollStyle.swift` 用一个探针 NSView 向上找到它，改 `drawsBackground = false`、
  并隐藏滚动条。**在 `layout()` 里无条件改会触发布局死循环**（页面直接画不出来），
  只在值真的不同时写，并靠 `viewDidMoveToWindow` + 两拍延迟重试。
- **核心 dylib 的 install name 是 cargo 的构建目录**，运行期不存在。
  `build.sh` 打进 `.app/Contents/Frameworks` 并改成 `@rpath/...`。
- **截图**：没有屏幕录制权限，`screencapture` 拿不到画面；`cacheDisplay` / `dataWithPDF`
  对 SwiftUI 的 layer-backed 视图是空的。只有 `CALayer.render` 能截出内容
  （记得把坐标系翻回来）。

## 4. 下一步

1. **播放页**：`NSOpenGLView` + `mpv_render_context`，`--keep-open`、`--start`、
   音轨 / 字幕按 `aid` / `sid` 应用；浮层控件照 Windows（顶栏 48、右侧截图 / 选集、
   底部规格 chips + 控制条、3 秒淡出、单击暂停、双击全屏、Esc 退出）。
2. 播放页与库的进度回写、播完接下一集 / 关窗（和 Windows 同一套规则：
   切集一律从头、记录停在片尾的从 0 开始）。
3. 详情页补齐：演职人员、媒体信息面板、音轨 / 字幕选择（`TrackPrefs` 等价物）。
4. 横向行悬停箭头（需要拿到 `NSScrollView` 做缓动滚动）。
5. 键盘：空格 / ←→ / 上下键 / Esc，和 Windows 对齐。
