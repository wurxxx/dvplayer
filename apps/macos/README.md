# macOS 壳

SwiftUI + AppKit，业务逻辑全部来自共享核心 `core/media`（Rust，C ABI）。
界面规范与 Windows 共用一套（[docs/UI-DESIGN.md](../../docs/UI-DESIGN.md)）。

| 目录 | 说明 |
| --- | --- |
| [DvPlayer](DvPlayer/) | 正式客户端（Swift Package，`./build.sh` 打成 `.app`） |
| [m0-render](m0-render/) | M0 的 libmpv render API 验证程序（Objective-C++）。只作历史验证留档，产品不走这条路 |

## 构建与运行

```bash
# 1) 共享核心（Rust）
cd core && ~/.cargo/bin/cargo build -p dvplayer-media --release && cd ..

# 2) 客户端
cd apps/macos/DvPlayer && ./build.sh && open build/DvPlayer.app
```

`build.sh` 会把 `libdvplayer_media.dylib` 一起打进 `DvPlayer.app/Contents/Frameworks`，
并把它的 install name 改成 `@rpath`（cargo 产物里记的是构建目录，运行期不存在）。

依赖里现成的东西：

- `core/target/release/libdvplayer_media.dylib`：媒体源适配 + 聚合 + 进度
- `prefix/lib`：libmpv 与 libass / libav* / libplacebo，
  `build.sh` 会整条依赖链一起打进 `.app/Contents/Frameworks`
  （进程内 libmpv render API，见 [ADR-0011](../../docs/adr/0011-macos-libmpv-inprocess.md)）

## 发布打包

```bash
apps/macos/packaging/build-release.sh              # 编译 + 出 dmg / zip
apps/macos/packaging/build-release.sh -SkipBuild   # 复用现有 .app
```

产物在 `out/release/`：

| 文件 | 说明 |
| --- | --- |
| `DvPlayer-<版本>-macos-<arch>.dmg` | 安装镜像，拖进 `/Applications` 即可 |
| `DvPlayer-<版本>-macos-<arch>.zip` | 便携版，解压直接双击 |

版本号取 `DvPlayer/Info.plist` 的 `CFBundleShortVersionString`（`-Version` 可覆盖产物名）。
默认 ad-hoc 签名、**没有公证**，别人首次打开要右键「打开」放行；
有开发者证书时传 `SIGN_IDENTITY="Developer ID Application: xxx"`，公证自己跑 `notarytool`。

### 两种架构都在 CI 上出包

本机是 Intel，交叉编译虽然能出 arm64 产物，但**跑不起来就无法验证**。
所以两种架构都交给 GitHub Actions：每种架构跑在原生 runner 上，
既能编译也能跑冒烟测试（打开首页 + 截图 + 退出）。

workflow：`.github/workflows/macos.yml`

| 架构 | runner 标签 | artifact 名 |
| --- | --- | --- |
| arm64（Apple Silicon） | `macos-15` | `macos-arm64` |
| x86_64（Intel） | `macos-15-intel` | `macos-x86_64` |

| 触发 | 产物 |
| --- | --- |
| Actions 页面手动 Run workflow（`arch` 可选 both / arm64 / x86_64） | 对应 artifact，保留 14 天 |
| 推送 `v*` tag | 两种架构都编，artifact + 自动附到该 Release |

runner 标签不是随便挑的（2026-11 查证）：

- `macos-14` 已于 **2026-11-02** 从 GitHub Actions 退役，写它直接失败；
- `macos-13` 已于 2025-12-04 退役；
- Intel 只剩 `macos-15-intel` / `macos-26-intel`，且 `macos-15-intel` 到
  **2027-08** 结束——之后 Actions 不再提供 x86_64 macOS。

前提：仓库要有 GitHub 副本（源码由 `actions/checkout` 拉取，**不**去拉 Gitee——
Gitee 官方文档说海外访问需要特殊 DNS，runner 在海外会随机失败）。

几点要知道：

- **私有仓库额度不够**：Actions 免费 2000 分钟/月，macOS runner 按 10 倍计费，
  等于只有 200 分钟。这套依赖栈首次编译约 40-60 分钟，两种架构就是两份，
  缓存失效就超标。所以需要**公开仓库**（公开仓库的 Actions 不计费）。
- **依赖栈很慢**：ffmpeg + libplacebo + libass + mpv 全从源码编。`prefix/` 有缓存
  （key 在 workflow 的 `DEPS_CACHE_KEY`，按架构分开），命中时几分钟完成；
  改了 mpv commit 或依赖版本就把那个数字加一。
- **产物必须全是目标架构**：workflow 会逐文件 `lipo -archs` 检查，混架构直接失败。
- **两种架构互不阻塞**：`fail-fast: false`，一边挂了另一边照常跑完。

本机构建仍按 `uname -m` 出对应架构的包（`build-release.sh` 的 `ARCH`）。

## 现在能做什么

- 窗口：没有标题栏、内容满窗，左上角三个圆点（关闭 / 最小化 / 缩放）
  由界面自己画，鼠标移上去浮出符号
- 「服务器」页添加 / 编辑 / 删除源（飞牛影视、Emby、Jellyfin），连上后自动跳该源的首页
- 首页：Hero 轮播、我的媒体、继续观看、每库一行
- 库 / 季 / 目录网格：类别、排序、风格、页内搜索、分页
- 详情页：整块横版图 + 信息叠加、播放 / 重头看 / 收藏 / 标记看过、
  音轨 / 字幕选择（多条音轨或有字幕才出现，弹层选完记在 `TrackPrefs`）、
  分季选集（296 宽横卡，悬停出播放遮罩）、演职人员（点开头像看作品）、
  豆瓣链接、媒体信息（视频 + 每条音轨 / 字幕各一张卡）
- 记录页：通用（继续观看分组 + 视频收藏）/ 观看 / 收藏
- 搜索页：跨源搜索
- 设置：续播、分辨率角标、自动连接；显示核心版本
- 播放页：进程内 libmpv（render API + gpu-next / OpenGL）画进自己的窗口，
  壳贴一层控制浮层（顶栏 / 控制条 / 选集 / 媒体信息 / 键盘 / 假全屏）；
  音轨、字幕、倍速、进度回写、播完接下一集 / 关窗，和 Windows 同一套行为；
  播放期间不让系统熄屏 / 休眠（暂停或播完就恢复，见下）

## 还没做

- HDR 真屏验收（这台是 SDR 屏）
- 顶栏右侧的倍速 / 静音指示、进度条缓冲段
- 公证与 Sparkle 自动更新（当前 ad-hoc 签名）

## 截图巡检

没有屏幕录制权限也能截自己的窗口（走 CALayer 渲染）：

```bash
DVPLAYER_SHOT=/tmp/home.png DVPLAYER_SHOT_DELAY=16 DVPLAYER_EXIT=1 \
  ./build/DvPlayer.app/Contents/MacOS/DvPlayer
```

| 环境变量 | 说明 |
| --- | --- |
| `DVPLAYER_SHOT` | 截图输出路径；以 `.jpg` 结尾出 JPEG（1x，约 160KB，手机上也秒开） |
| `DVPLAYER_SHOT_DELAY` | 打开后等几秒再截（网络慢就给大一点），默认 2.8 |
| `DVPLAYER_EXIT` | `1` = 截完退出，方便脚本跑 |
| `DVPLAYER_PAGE` | 直接落在某页：`sources` / `records` / `search` / `settings` |
| `DVPLAYER_DETAIL` | 直接打开某个条目（`<sourceId>:<itemId>`） |
| `DVPLAYER_LIBRARY` | 直接打开某个媒体库的网格 |
| `DVPLAYER_SCROLL` | `end` = 先把页面滚到底再截（长页面下半截） |
| `DVPLAYER_ARROWS` | `1` = 强制显示横向行的左右箭头（截图用，正常是悬停才出） |
| `DVPLAYER_SHOT_SCALE` | 渲染倍数；JPEG 默认 1x，PNG 默认屏幕倍数（Retina 是 2x） |
| `DVPLAYER_MENU` | `audio` / `subtitle` = 打开详情页后自动展开音轨 / 字幕弹层（截图用） |
| `DVPLAYER_TAB` | `search` / `favorites` = 源首页直接落在搜索 / 收藏页签（截图用） |
| `DVPLAYER_SEARCH` | 配合 `DVPLAYER_TAB=search`：预填关键词 |
| `DVPLAYER_CONFIRM` | `1` = 打开「服务器」页时把删除确认卡片弹出来（截图用） |
| `DVPLAYER_SHOT_FRAME` | `1` = 连窗口边框一起截（窗口没有标题栏，通常用不上） |
| `DVPLAYER_WINDOWTEST` | `1` = 依次点三个窗口按钮（最小化 / 缩放 / 关闭），结果打到日志，验证完自动退出 |
| `DVPLAYER_CLICKTEST` | `x,y`（窗口左上角原点）= 合成一次点击并敲 `abc`，日志里看 `firstResponder` / 输入框内容，排查「点不进去」用 |
| `DVPLAYER_TAP` | `x,y`（窗口左上角原点）= 先滚到 `DVPLAYER_SCROLL_Y` 再合成一次点击，不退出；验证卡片命中区（点画面进详情 / 点底部条续播）。多个坐标用分号隔开（`x,y;x2,y2`）依次点击，可以走完「进详情 → 返回」这类两步路径 |
| `DVPLAYER_TAP_WAIT` | 每次合成点击后等几秒再截下一张 / 下一次点击，默认 1.8。光标会闪，调它来截到光标可见的那一相 |
| `DVPLAYER_PROBE_SEARCH` | `1` = 打印搜索框的几何（占位文字矩形、光标位置、两者差值），验证光标对齐；比截图可靠，不撞闪烁相位 |
| `DVPLAYER_TYPE_SEARCH` | 配合 `DVPLAYER_PROBE_SEARCH`：投递这几个字符的真实键盘事件，验证控件可编辑、绑定能同步 |
| `DVPLAYER_CLICK_CLEAR` | `1` = 点搜索框右侧的清除按钮，日志看点击前后文字，验证按钮没被编辑区盖住 |
| `DVPLAYER_COMPOSE_SEARCH` | 模拟输入法组字（marked text），验证组字期间占位文字会隐藏、不和拼音重叠 |
| `DVPLAYER_PLAY` | `<itemId>` = 核心连上后直接开播放窗（远程验证播放 / 字幕用） |
| `DVPLAYER_PLAY_UI` | 逗号分隔的播放页动作，按顺序执行：`pause` / `next` / `prev` / `info` / `episodes` / `speed:2` / `mute` / `close` / `fullscreen` / `ontop` / `audio:N` / `subtitle:N` / `audioout` / `aspect:fit` / `sleep:HH:MM` / `danmaku` 等；`wait:N` 在两条之间停顿 N 秒（可带小数） |
| `DVPLAYER_PLAY_SHOT` | 截播放窗到该路径 |
| `DVPLAYER_LOCAL` | `<文件路径>` = 直接本地播放一个文件（不走媒体源，验证解码 / 渲染用） |

### 验证「播放时不熄屏」

`IOPMAssertion` 是系统级的，用 `pmset` 直接看，比截图可靠：

```bash
# 播放中（不设 DVPLAYER_EXIT，让它一直播；Ctrl+C 结束）
DVPLAYER_LOCAL=samples/p7-fel.mkv \
  ./build/DvPlayer.app/Contents/MacOS/DvPlayer &

pmset -g assertions | grep -E "PreventUserIdleDisplaySleep|PreventUserIdleSystemSleep"
#   两条都应该是 1，且下面「Listed by owning process」里有两行
#   pid NNN(DvPlayer) 的断言（一条 Display、一条 System）

# 暂停后应该都变回 0。剩下还有 1 的话看是哪一行：
# bluetoothd / coreaudiod 的请求与播放器无关，不要误判。
DVPLAYER_LOCAL=samples/p7-fel.mkv DVPLAYER_PLAY_UI="wait:6,pause" \
  ./build/DvPlayer.app/Contents/MacOS/DvPlayer &
sleep 12 && pmset -g assertions | grep -E "PreventUserIdle(Display|System)Sleep"
```

`DVPLAYER_PLAY_UI` 里的 `wait:N` 是异步串行的（不阻塞后面的截图 / 退出），
所以暂停后用 `sleep` 等 mpv 把 `pause` 回传再查。

配置在 `~/Library/Application Support/DvPlayer/settings.json`（和 Windows 同名字段）。
`scripts/seed-source.py` 是开发用的：从环境变量读账号密码写一份配置，
正常使用直接在「服务器」页里填。
