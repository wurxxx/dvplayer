# 构建共享媒体库核心 dvplayer_media.dll（Windows）。
#
# 要点：
#  - 用 rustup 的 stable-x86_64-pc-windows-gnu 工具链，装到 D:\dvplayer\tools；
#  - PATH 里不要放任何 gcc，否则 rustc 会选 gcc 当 linker 并且找不到 mingw 的库；
#    Rust 1.82+ 的 windows-gnu 自带 rust-lld + self-contained 的 mingw 库。
#  - 但 rustc 生成 raw-dylib 的 import library 时要 dlltool；Rust 自带的
#    self-contained\dlltool.exe（GNU 版）会调用 as.exe 而失败，所以替换成
#    llvm-mingw 的 llvm-dlltool.exe。
#
# 一次性准备（见 docs/BUILD-WINDOWS.md）：
#   rustup-init2.exe -y --profile minimal --default-toolchain stable-x86_64-pc-windows-gnu
#   替换 <toolchain>\lib\rustlib\x86_64-pc-windows-gnu\bin\self-contained\dlltool.exe
#
# 用法： powershell -ExecutionPolicy Bypass -File scripts\windows\build-core.ps1
$ErrorActionPreference = 'Stop'

$cargoHome = 'D:\dvplayer\tools\cargo'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$core = Join-Path $repo 'core'

$env:CARGO_HOME = $cargoHome
$env:RUSTUP_HOME = 'D:\dvplayer\tools\rust'

# dlltool：新增依赖（如 native-tls → schannel → windows-sys）触发重编时，
# rustc 要调用它生成 raw-dylib 的 import library。
#
# 用独立目录 D:\dvplayer	ools\dlltool：里面是 llvm-dlltool.exe（改名 dlltool.exe）
# 和它的运行时 dll。**不能**把 llvm-mingw\bin 整个放进 PATH——那里有 gcc.exe，
# rustc 会改用它当 linker，然后找不到 -lgcc。见 docs/BUILD-WINDOWS.md §2。
$dlltool = 'D:\dvplayer\tools\dlltool'
$env:PATH = "$cargoHome\bin;$dlltool;$env:SystemRoot\System32;$env:SystemRoot"

& "$cargoHome\bin\cargo.exe" build --manifest-path (Join-Path $core 'Cargo.toml') `
    -p dvplayer-media --release --target x86_64-pc-windows-gnu | Out-Host

$dll = Join-Path $core 'target\x86_64-pc-windows-gnu\release\dvplayer_media.dll'
if (-not (Test-Path $dll)) { throw "build failed: $dll not found" }
"built: $dll"
