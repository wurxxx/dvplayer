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

### 2. dlltool 要换成 llvm 版

`windows-sys` 用 `raw-dylib`，rustc 调 `dlltool.exe` 生成 import library。
工具链自带的 `self-contained\dlltool.exe` 是 GNU 版，内部会去调用 `as.exe`，
而 self-contained 里没有 `as.exe`，于是报 `CreateProcess 失败`。

把 llvm-mingw 的 `llvm-dlltool.exe` 复制过去覆盖（原文件先备份）：

```powershell
$sc = 'D:\dvplayer\tools\rust\toolchains\stable-x86_64-pc-windows-gnu\lib\rustlib\x86_64-pc-windows-gnu\bin\self-contained'
Copy-Item "$sc\dlltool.exe" "$sc\dlltool-gnu.exe" -Force
Copy-Item 'D:\dvplayer\tools\llvm-mingw\bin\llvm-dlltool.exe' "$sc\dlltool.exe" -Force
```

注意：升级 Rust 工具链会覆盖这个文件，升级后要重新替换。

### 3. 没有 TLS 后端

`reqwest` 暂时没启用 TLS（`default-features = false, features = ["blocking", "json"]`）：
飞牛和 Emby 在内网基本都是 http。等需要 https 时再开 `native-tls`
（Windows 用 SChannel，不需要 C 编译器）。

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

程序依次打开首页 / 媒体库 / 播放记录 / 设置，各渲染一张 PNG 后退出。
走 `RenderTargetBitmap`，不依赖桌面合成，锁屏或 SSH 会话里也能用。

## 相关

- `docs/adr/0008-rust-shared-core.md`：为什么用 Rust + C ABI
- `docs/FNOS-API.md`：飞牛接口与签名
