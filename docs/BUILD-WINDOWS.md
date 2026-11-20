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

## 无桌面环境的 UI 回归

```powershell
DvPlayer.exe --screenshot D:\dvplayer\tmp\ui
```

程序依次打开服务器首页 / 服务器 / 记录 / 搜索 / 设置，各渲染一张 PNG 后退出。
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
| `--window <宽>x<高>` | 换窗口尺寸（受会话屏幕限制），验证自适应网格 |
| `--delay <秒>` | 每页再多等几秒（媒体库页默认 9 秒等 Hero 大图） |
| `--hover` | 媒体库页把 Hero 左右箭头显示出来，检查位置与样式 |
| `--scroll <像素>` | 把服务器首页往下滚再截，检查分组标题与横向海报行 |
| `--timing` | 把首页各阶段耗时写到 `%TEMP%\dvplayer\startup.log`，排查加载慢用 |
| `--favorites` | 媒体库页切到「收藏」分段再截，检查空态与顶栏 |
| `--inline-search <关键词>` | 媒体库页切到页内搜索并填好关键词 |
| `--edit-source` | 服务器页打开第一个源的编辑表单 |
| `--series <id>[,<id>...]` | 额外截剧集详情页（`series.png` / `series-N.png`） |
| `--series-season <n>` | 详情页默认展开第 n 季（验证季切换） |
| `--play <id> --play-seconds <n>` | 直接播放 n 秒后自动退出（验证播放与进度回写） |

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

> 注意：PowerShell 5.1 按 ANSI 读 `.ps1`，带中文的脚本必须存成 **UTF-8 with BOM**，
> 否则解析直接报「字符串缺少终止符」。仓库里的 `run-session2.ps1` 已经带 BOM。

## 相关

- `docs/adr/0008-rust-shared-core.md`：为什么用 Rust + C ABI
- `docs/FNOS-API.md`：飞牛接口与签名
