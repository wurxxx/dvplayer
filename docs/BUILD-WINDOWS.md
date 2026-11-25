# Windows 构建环境（Rust 共享核心）

`core/media` 产出 `dvplayer_media.dll`，WPF 外壳通过 P/Invoke 调用。
本文记录在 Windows 上把它编出来的完整环境，以及踩过的坑。

## 工具链布局

全部装在 `D:\dvplayer\tools`，不碰用户目录、不需要管理员权限：

```
D:\dvplayer\tools\
  rust\        rustup 的 RUSTUP_HOME
  cargo\       CARGO_HOME（含 config.toml 镜像配置）
  llvm-mingw\  llvm-mingw 20261117（只用它的 llvm-dlltool）
  dotnet\      .NET 10 SDK
```

## 安装

```powershell
# 1. rustup（windows-gnu 工具链，不需要 Visual Studio）
$env:RUSTUP_HOME = 'D:\dvplayer\tools\rust'
$env:CARGO_HOME  = 'D:\dvplayer\tools\cargo'
$env:RUSTUP_DIST_SERVER  = 'https://rsproxy.cn'
$env:RUSTUP_UPDATE_ROOT  = 'https://rsproxy.cn/rustup'
D:\dvplayer\tools\rustup-init.exe -y --profile minimal `
    --default-toolchain stable-x86_64-pc-windows-gnu --no-modify-path
```

`cargo` 的 crate 索引也走 rsproxy（`D:\dvplayer\tools\cargo\config.toml`）：

```toml
[source.crates-io]
replace-with = "rsproxy-sparse"

[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"

[net]
retry = 5
```

## 三个坑

### 1. PATH 里不能有 gcc

Rust 1.82+ 的 `x86_64-pc-windows-gnu` 自带 `rust-lld` 和 self-contained 的
mingw-w64 运行库（`lib\rustlib\x86_64-pc-windows-gnu\lib\self-contained`），
不需要装 MinGW / VS。

但只要 PATH 里出现 `x86_64-w64-mingw32-gcc.exe`，rustc 就会改用它当 linker，
然后因为找不到 `-lmsvcrt`、`-lmingw32` 这类库而链接失败。
**构建时的 PATH 只保留 `cargo\bin` 和系统目录。**

### 2. dlltool 要用 llvm 版，并且单独放一个目录

`windows-sys` 用 `raw-dylib`，rustc 需要 `dlltool.exe` 生成 import library。
直接换会踩两个坑：

- 工具链自带的 GNU `dlltool` 会调 `as.exe`，而 self-contained 里没有；
- 把 `llvm-dlltool.exe` 单独复制进 self-contained 也不行——它依赖
  `libLLVM-23.dll`、`libc++.dll` 这些同目录运行时，只复制 exe 会报
  0xC0000135（找不到 DLL）。

做法是建一个独立目录，放 dlltool 和它的运行时：

```powershell
$d = 'D:\dvplayer\tools\dlltool'
New-Item -ItemType Directory -Force $d | Out-Null
Copy-Item 'D:\dvplayer\tools\llvm-mingw\bin\llvm-dlltool.exe' "$d\llvm-dlltool.exe" -Force
Copy-Item 'D:\dvplayer\tools\llvm-mingw\bin\*.dll' $d -Force
Copy-Item "$d\llvm-dlltool.exe" "$d\dlltool.exe" -Force
& "$d\dlltool.exe" --help    # 能打出 usage 就对了
```

`scripts\windows\build-core.ps1` 会把这个目录放进 PATH。

**不要把 `llvm-mingw\bin` 整个加进 PATH**：那里有 `gcc.exe`，rustc 会改用它
当 linker，然后报 `unable to find library -lgcc`。

升级 Rust 工具链不影响这个目录；换 llvm-mingw 版本时同步更新里面的 dll。

### 3. TLS 用 native-tls

`reqwest` 开了 `native-tls`：Windows 走 SChannel、macOS 走 Security.framework，
都不需要 OpenSSL 或额外 C 工具链。内网 http 照常可用，公网 `https://`
反代的 Emby / Jellyfin 也能连。

代价是会把 `schannel → windows-sys` 拉进来，**第一次编译（或升级依赖后）需要
dlltool**，见上一节。

## 构建

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\build-core.ps1
```

产物：`core\target\x86_64-pc-windows-gnu\release\dvplayer_media.dll`。

`apps/windows/DvPlayer/DvPlayer.csproj` 有一个 `CopyMediaCore` target，
`dotnet build` 时会把它拷到输出目录；找不到就发一条 warning。

exe 的图标来自 `Assets/DvPlayer.ico`（`ApplicationIcon`），侧栏左上角的品牌图用
同一份设计的 `Assets/DvPlayer-256.png`，都由 `python3 scripts/make-icon.py` 生成：
琥珀圆角块 + 摄像机，16–32 px 用简化成三角形的版本。换配色只需改脚本里的
`AMBER_*` / `INK` 再跑一次（会同时更新 `assets/branding/` 下给 macOS 用的那份）。

## 发布打包

`apps/windows/packaging/build-release.ps1` 用**同一份自包含 win-x64 发布目录**
产出两个包：

| 产物 | 说明 |
| --- | --- |
| `out\release\DvPlayer-<版本>-win-x64-portable.zip` | 绿色版，解压即用；`mpv\` 与 `dvplayer_media.dll` 都在里面 |
| `out\release\DvPlayer-<版本>-win-x64-setup.exe` | Inno Setup 安装版；写 Program Files、开始菜单 / 可选桌面快捷方式、带卸载项 |

```powershell
# 先确保共享核心和 mpv 就位
powershell -ExecutionPolicy Bypass -File scripts\windows\build-core.ps1

# 默认 0.1.0，同时出绿色版和安装版
powershell -ExecutionPolicy Bypass -File apps\windows\packaging\build-release.ps1
```

常用参数：`-Version 0.1.1`、`-MpvDir <目录>`（默认 `D:\dvplayer\mpv`）、
`-SkipPublish`（复用 `out\release\payload`）、`-SkipPortable` / `-SkipInstaller`。
第一次出安装版时如果找不到 `ISCC.exe`，脚本会下载 Inno Setup 静默装到
`tools\innosetup`（需要联网；本机若已装 `C:\Program Files (x86)\Inno Setup 6`
会直接复用）。安装包现在托管在 GitHub Releases，脚本默认给链接加
`https://ghfast.top/` 加速；镜像不通会回退直连。要换镜像就设
`DVPLAYER_GH_PROXY`（例如 `https://gh-proxy.com/`），设为空字符串则直连。

静默安装 / 卸载（自动化验证用）：

```powershell
DvPlayer-0.1.0-win-x64-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART `
    /DIR=D:\dvplayer\out\test-installed /LOG=D:\dvplayer\test-install.log
# 跑一遍 UI 自检
& D:\dvplayer\out\test-installed\DvPlayer.exe --screenshot D:\dvplayer\out\test-installed\shots
# 卸载
& D:\dvplayer\out\test-installed\unins000.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
```

绿色版：把 zip 解到空目录，直接 `DvPlayer.exe --screenshot <目录>`；不要只复制
exe，`mpv\`、`*.dll`、`runtimeconfig.json` 都要在。

## 无桌面环境的 UI 回归

```powershell
DvPlayer.exe --screenshot D:\dvplayer\tmp\ui
```

程序依次打开服务器首页 / 服务器 / 记录 / 搜索 / 设置，各渲染一张 PNG 后退出。
详情页各阶段耗时写进 `%LOCALAPPDATA%\dvplayer\player.log`：`detailMs`（详情）、
`childrenMs`（季列表）、`episodes first`（第一页集）、`episodes append`（后台补页）。
走 `RenderTargetBitmap`，不依赖桌面合成，锁屏或 SSH 会话里也能用。

常用参数：

| 参数 | 作用 |
| --- | --- |
| `--screenshot <dir> [页面...]` | 只截指定页（`libraries` / `sources` / `records` / `search` / `settings`） |
| `--search-text <关键词>` | 搜索页带一个查询启动，用来截结果网格 |
| `--browse` | 巡检完再进第一个媒体库的网格，多截一张 `library-browse.png` |
| `--browse-cat <all\|tv\|movie\|genre\|folder>` | 网格切到某个类别再截图（风格会带风格标签行） |
| `--browse-sort <added\|name\|release\|rating>` | 网格换一种排序 |
| `--browse-scroll <像素>` | 把网格滚到接近底部，验证自动续页（状态行会显示「已加载 N」） |
| `--menu` | 打开网格第一张卡片的右键菜单，单独渲染 `card-menu.png`（Popup 抓不到整窗） |
| `--menu-continue` | 打开「继续观看」第一张卡片的右键菜单，单独渲染 `continue-menu.png` |
| `--menu-records` | 记录页切到「观看」并打开第一张卡片的右键菜单，单独渲染 `records-watch-menu.png` |
| `--menu-fav` | 记录页临时收藏一条，渲染 `records-favorites.png` 与 `records-favorite-menu.png`，截完自动取消收藏 |
| `--menu-click` | 配合 `--menu`：点一下菜单第一项（收藏）验证 Click 链路，会临时收藏该条目再取消 |
| `--window <宽>x<高>` | 换窗口尺寸（受会话屏幕限制），验证自适应网格 |
| `--delay <秒>` | 每页再多等几秒（媒体库页默认 9 秒等 Hero 大图） |
| `--hover` | 媒体库页把 Hero 左右箭头显示出来，检查位置与样式 |
| `--scroll <像素>` | 把服务器首页往下滚再截，检查分组标题与横向海报行 |
| `--timing` | 把首页各阶段耗时写到 `%TEMP%\dvplayer\startup.log`，排查加载慢用 |
| `--window-test` | 单独自检窗口按钮：依次点最小化 / 最大化 / 关闭，结果写 `%TEMP%\dvplayer\window-test.log` |
| `--dialog-shot <dir>` | 把深色确认框渲染成 `confirm.png`，检查它和页面是不是一套 |
| `--dialog-test` | 自动点一次「删除」和一次「取消」，验证 `Ask` 的返回值写进 `%TEMP%\dvplayer\dialog-test.log` |
| `--ui-test <dir>` | 把「搜索框 + 深色滚动条」单独渲染到 `ui-test.png`，并写 `ui-test.log`（`search focus=` / `scroll visible=`），验证点整块能聚焦、滚动条不是系统浅色条 |
| `--favorites` | 媒体库页 / 记录页切到「收藏」分段再截，检查空态与海报网格 |
| `--inline-search <关键词>` | 媒体库页切到页内搜索并填好关键词 |
| `--edit-source` | 服务器页打开第一个源的编辑表单 |
| `--series <id>[,<id>...]` | 额外截剧集详情页（`series.png` / `series-N.png`）；传 `first` 自动挑一个有集的条目。同一个 id 写两遍可以验证详情缓存（日志出现 `detail cache hit`，且不再有第二次 `episodes first`） |
| `--series-season <n>` | 详情页默认展开第 n 季（验证季切换） |
| `--series-scroll <像素>` | 详情页往下滚 N 像素（集行在首屏下沿之外时用） |
| `--detail-bottom` | 详情页滚到底，看「链接 / 媒体信息」两块 |
| `--row-arrows` | 把横向行两侧的翻页箭头强制显示（截不到鼠标悬停） |
| `--season-menu` | 单独渲染季下拉菜单 `series-season-menu.png` |
| `--person-first` | 从详情页点第一个演员进作品页，额外截 `person.png` |
| `--person-index <n>` | 配合 `--person-first`：取第 n 个有 id 的演职人员（0 起） |
| `--play <id> --play-seconds <n>` | 直接播放 n 秒后自动退出（验证播放与进度回写） |
| `--play-shot <dir>` | 播放页巡检：依次截图 `play.png` / `play-episodes.png` / `play-audio.png` / `play-more.png` / `play-info.png`（浮层、选集、两个菜单、媒体信息），另有 `play-screen.png` / `play-episodes-screen.png` 是从桌面抓的真实画面（含视频） |
| `--records-general-fav` | 配合 `--screenshot <目录> records`：停在「通用」，临时收藏第一条记录后截图，验证收藏数据晚到时不会盖到继续观看上（截 `records-general-fav.png`，最后自动取消） |
| `--play-opening-shot <png>` | 配合 `--play` / `--play-record`：窗口刚弹出、视频还没出画时截一张，确认打开阶段是不透明黑底 + 片名 +「正在打开…」，没有控制条、也不透出桌面 |
| `--play-end` | 配合 `--play-shot`：跳到片尾前 4 秒，20 秒后截 `play-next.png`，验证播完自动接下一集 |
| `--play-input` | 配合 `--play-shot`：用真实鼠标事件验证点画面暂停 / 拖顶栏移动 / 拖右边缘改大小，结果写进 `player.log`，最后截 `desktop-input.png` |
| `--play-pick N` | 配合 `--play-shot` / `--play-series`：打开后像点右侧选集面板那样切到第 N 集（0 起），日志里 `mpv start ... start=0 resume=N` 说明切集是从头开始，`pick state ...` 给出切完的位置（应该是几秒，不是片尾） |
| `--play-record N` | 配合 `--play-shot`：拿观看记录第 N 条（默认第一条）走「继续观看」的真实路径。窗口先出来再解析播放源，日志里 `play open shown ... ms=` 应在一百多毫秒、`play open resolved` 之后紧接着 `mpv start`；选集是后台补的，`playlist attached ... n=N` 说明侧栏补进来了（`--play-wait <秒>` 可以多等一会儿再截图）。最后截 `desktop-record.png` / `play-record.png` / `play-record-episodes.png`；再加 `--play-end` 会跳到片尾，验证续播的剧集也能自动接下一集 |
| `--play-spam` | 配合 `--play-record`：同时触发两次续播，验证防重闸门只开一个窗口（日志 `play spam opened=1`，且只有一次 `playlist page=1`） |
| `--playlist <容器 id>` | 只量选集加载耗时、不起播放器：日志里 `playlist page=1 ... ms=` 是服务端 `/item/list` 的真实耗时（不占带宽时约 2–3 秒，边播边取会被拉流挤到十几秒，所以播放器把选集放在后台补） |
| `--play-min` | 配合 `--play-shot`：播放窗最小化 → 还原 → 最大化 → 还原 → 主窗口最小化 → 还原，每步从桌面截一张（`desktop-min.png` / `desktop-restore.png` / `desktop-max.png` / `desktop-main-min.png` / `desktop-main-restore.png`），验证浮层不会飘在桌面上 |
| `--play first` | 配合 `--play-series`：直接播这个剧的第一集，不用先查集 id |
| `--play-series <剧 id>` | 给播放页的「选集」拼列表（剧 → 第一个季 → 集），片名也用它拼 |

## 需要出画面的验证（mpv / D3D11）

`--screenshot` 不需要桌面，但**播放**需要：D3D11 的 swapchain 只在已登录的
桌面会话（Session 2）里可用，SSH 属于 Session 0，直接启动会报
`Failed to create swapchain: 0x887A0022`。用交互式计划任务启动即可：

```powershell
.\scripts\windows\run-session2.ps1 `
  -Exe D:\dvplayer\apps\windows\DvPlayer\bin\Release\net10.0-windows\DvPlayer.exe `
  -Arguments "--play <guid> --play-seconds 20"
```

脚本注册一个 `-LogonType Interactive` 的计划任务、启动、等进程退出，
最后打印 `LastTaskResult`（0 = 正常）。

> 播放页巡检同样要走这个脚本，例如：
>
> ```powershell
> .\scripts\windows\run-session2.ps1 `
>   -Exe D:\dvplayer\apps\windows\DvPlayer\bin\Release\net10.0-windows\DvPlayer.exe `
>   -Arguments "--play first --play-series fnos-1:<剧 id> --play-shot D:\dvplayer\tmp\play"
> ```
>
> 播放页现在是两个窗口：视频在 `PlayerSurfaceWindow`（黑窗），控制条是
> `PlayWindow`（透明浮层，Owner 是视频窗）。`RenderTargetBitmap` 只截得到浮层，
> 所以巡检会额外从桌面 BitBlt 几张：`desktop-open.png`（刚打开，控制条该在）、
> `desktop-early.png`、`desktop.png`（主窗口拿回前台之后）、`desktop-input.png`。
> 桌面抓图要求进程在 Session 2 里跑。

> 注意：PowerShell 5.1 按 ANSI 读 `.ps1`，带中文的脚本必须存成 **UTF-8 with BOM**，
> 否则解析直接报「字符串缺少终止符」。仓库里的 `run-session2.ps1` 已经带 BOM。

## GitHub Actions（CI 打包）

`.github/workflows/windows.yml` 在 `windows-2025` runner 上出同样的两个产物
（zip / setup），和 macOS 共用一个 Release：打 `v*` tag 时两个 workflow 都会
把文件附上去。

和本机打包机的差别只有三处：

| | 打包机 | CI |
| --- | --- | --- |
| Rust 目标 | `x86_64-pc-windows-gnu`（`scripts\windows\build-core.ps1`） | `x86_64-pc-windows-msvc`（runner 自带） |
| mpv | `D:\dvplayer\mpv` | 下载钉死的 shinchiro 构建（`MPV_RELEASE_TAG` / `MPV_ASSET`） |
| Inno Setup | `tools\innosetup` 或系统安装 | 脚本自己下载（`DVPLAYER_GH_PROXY=''` 直连） |

`build-release.ps1` 的 `-CoreDll <路径>` 或 `DVPLAYER_CORE_DLL` 环境变量可以
显式指定核心 dll；不传就按 gnu → msvc → host target 的顺序找。

弹幕凭据走仓库 Secrets：`DVPLAYER_DANMAKU_APP_ID` / `DVPLAYER_DANMAKU_APP_SECRET`
（Settings → Secrets and variables → Actions）。没配也能出包，只是包里不带弹幕。

CI 的「启动冒烟测试」是 `continue-on-error`：runner 在 Session 0，没有真实桌面，
WPF 图形栈偶尔起不来，这一项挂了不该把产物扣下——发版前在打包机上跑的截图巡检
才是准的。

## 相关

- `docs/adr/0008-rust-shared-core.md`：为什么用 Rust + C ABI
- `docs/FNOS-API.md`：飞牛接口与签名
