# Build the Windows release artifacts:
#   - portable zip  (out\release\DvPlayer-<version>-win-x64-portable.zip)
#   - Inno Setup installer (out\release\DvPlayer-<version>-win-x64-setup.exe)
#
# Both use the same self-contained win-x64 publish payload, including
# dvplayer_media.dll and the bundled mpv.
#
# 版本号同时写在三个地方，发布时一起改：
#   apps\windows\DvPlayer\DvPlayer.csproj  <Version>   （Windows 关于 / 侧栏显示）
#   core\Cargo.toml [workspace.package] version        （共享核心，macOS 侧栏也用它）
#   apps\macos\DvPlayer\Info.plist CFBundleShortVersionString
# 这里传的 -Version 决定产物文件名，并覆盖程序集版本；核心版本要去改 Cargo.toml 再编。
#
# Usage (PowerShell):
#   powershell -ExecutionPolicy Bypass -File apps\windows\packaging\build-release.ps1
#   ... -Version 0.1.1
#   ... -SkipInstaller        # portable zip only
#   ... -SkipPortable         # installer only
#   ... -SkipPublish          # reuse out\release\payload

param(
    [string]$Version = '0.1.0',
    [string]$Configuration = 'Release',
    [string]$MpvDir = 'D:\dvplayer\mpv',
    [string]$OutputDir = '',
    <#
      播放后端：
        process  mpv.exe 子进程（默认，DV P7 FEL 已在真机验证）
        libmpv   libmpv-2.dll 进程内（包体积约 45 MB，需要真机回归 DV）
    #>
    [ValidateSet('process', 'libmpv')]
    [string]$Backend = 'process',
    [switch]$SkipPublish,
    [switch]$SkipPortable,
    [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'

$packaging = $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $packaging))
$out = if ($OutputDir) { $OutputDir } else { Join-Path $repo 'out\release' }
$payload = Join-Path $out 'payload'
$proj = Join-Path $repo 'apps\windows\DvPlayer\DvPlayer.csproj'

Write-Host "== DVPlayer release $Version =="

function Remove-WithRetry([string]$path) {
    for ($i = 0; $i -lt 12; $i++) {
        try {
            Remove-Item $path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            Start-Sleep -Milliseconds 1500
        }
    }
    Remove-Item $path -Recurse -Force
}

# 弹幕（弹弹play）凭据：打包时写进 exe 的程序集元数据，用户不用填。
# 优先级：环境变量 > 本地密钥文件（默认 ~\.config\dvplayer\danmaku.env，
# 可用 DVPLAYER_DANMAKU_ENV 换路径）。文件格式：
#   DANMAKU_APP_ID=xxx
#   DANMAKU_APP_SECRET=yyy
$danmakuEnv = if ($env:DVPLAYER_DANMAKU_ENV) {
    $env:DVPLAYER_DANMAKU_ENV
} else {
    Join-Path $env:USERPROFILE '.config\dvplayer\danmaku.env'
}
$danmakuFile = @{}
if (Test-Path $danmakuEnv) {
    Get-Content $danmakuEnv -Encoding UTF8 |
        Where-Object { $_ -match '^\s*[A-Za-z_]+\s*=' } |
        ForEach-Object {
            $name, $value = $_.Split('=', 2)
            $danmakuFile[$name.Trim()] = $value.Trim()
        }
}
$danmakuAppId = if ($env:DVPLAYER_DANMAKU_APP_ID) {
    $env:DVPLAYER_DANMAKU_APP_ID
} else {
    $danmakuFile['DANMAKU_APP_ID']
}
$danmakuAppSecret = if ($env:DVPLAYER_DANMAKU_APP_SECRET) {
    $env:DVPLAYER_DANMAKU_APP_SECRET
} else {
    $danmakuFile['DANMAKU_APP_SECRET']
}
$danmakuArgs = @()
if ($danmakuAppId -and $danmakuAppSecret) {
    Write-Host ("-- 弹幕凭据：已注入（AppId {0}…）" -f `
        $danmakuAppId.Substring(0, [Math]::Min(4, $danmakuAppId.Length)))
    $danmakuArgs = @("-p:DanmakuAppId=$danmakuAppId", "-p:DanmakuAppSecret=$danmakuAppSecret")
} else {
    Write-Warning "-- 弹幕凭据：没有找到 $danmakuEnv，这个包不带弹幕"
}

if (-not $SkipPublish) {
    if (Test-Path $payload) { Remove-WithRetry $payload }
    New-Item -ItemType Directory -Force $payload | Out-Null
    dotnet publish $proj -c $Configuration -r win-x64 --self-contained true `
        -p:Version=$Version -p:DebugType=none -o $payload @danmakuArgs
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
}
if (-not (Test-Path (Join-Path $payload 'DvPlayer.exe'))) {
    throw "payload missing DvPlayer.exe: $payload"
}

# Shared Rust core (dvplayer_media.dll, built by scripts/windows/build-core.ps1).
$core = Join-Path $repo 'core\target\x86_64-pc-windows-gnu\release\dvplayer_media.dll'
if (Test-Path $core) {
    Copy-Item $core $payload -Force
} elseif (-not (Test-Path (Join-Path $payload 'dvplayer_media.dll'))) {
    throw 'dvplayer_media.dll not found. Run scripts\windows\build-core.ps1 first.'
}

# mpv: ship it beside the exe so the package works on a clean machine.
#
# 两个后端，用 -Backend 选（默认 process，和线上版本一致）：
#   process  mpv.exe --wid（子进程）        → mpv\ 目录，约 116 MB
#   libmpv   libmpv-2.dll（进程内，C API）  → 根目录几个 dll，约 45 MB
#
# 进程内后端的 dll 列表由 mpv 官方构建决定，shinchiro 的包解压后就是
# libmpv-2.dll + 一堆 lib*.dll，全部平铺在 exe 旁边即可。
$payloadMpv = Join-Path $payload 'mpv'
if ($Backend -eq 'libmpv') {
    $lib = Join-Path $MpvDir 'libmpv-2.dll'
    if (-not (Test-Path $lib)) {
        throw "libmpv-2.dll not found in $MpvDir. Pass -MpvDir <dir> pointing at a shinchiro build."
    }

    # libmpv 依赖的 dll 一并拷到根目录（DLL 搜索路径优先 exe 所在目录）。
    Copy-Item (Join-Path $MpvDir '*.dll') $payload -Force

    # mpv.exe 不需要，但 mpv.com / d3dcompiler 之类也不要带。
    Write-Host 'backend: libmpv (in-process)'
} else {
    if (-not (Test-Path (Join-Path $payloadMpv 'mpv.exe'))) {
        if (-not (Test-Path (Join-Path $MpvDir 'mpv.exe'))) {
            throw "mpv.exe not found in $MpvDir. Pass -MpvDir <dir>."
        }
        New-Item -ItemType Directory -Force $payloadMpv | Out-Null
        Copy-Item (Join-Path $MpvDir '*') $payloadMpv -Recurse -Force
    }
    Write-Host 'backend: process (mpv.exe --wid)'
}

$readme = @"
DVPlayer $Version - Windows 便携版
=====================================

1. 把整个目录解压到任意位置（不要只复制 DvPlayer.exe，mpv\ 和 dll 都要）。
2. 双击 DvPlayer.exe 运行。
3. 配置、播放记录和日志在 %LOCALAPPDATA%\dvplayer\。

mpv\ 是播放引擎（含 DV P7 FEL 合成），不要删除或改名。
"@
[IO.File]::WriteAllText((Join-Path $payload 'README-portable.txt'), $readme,
    (New-Object System.Text.UTF8Encoding -ArgumentList $false))

# ---------------------------------------------------------------- portable zip
if (-not $SkipPortable) {
    $zip = Join-Path $out "DvPlayer-${Version}-win-x64-portable.zip"
    if (Test-Path $zip) { Remove-WithRetry $zip }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $payload, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
    Write-Host "portable: $zip"
}

# ---------------------------------------------------------------- installer
if (-not $SkipInstaller) {
    $iscc = $null
    foreach ($candidate in @(
            (Join-Path $repo 'tools\innosetup\ISCC.exe'),
            'D:\dvplayer\tools\innosetup\ISCC.exe',
            'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
            'C:\Program Files\Inno Setup 6\ISCC.exe')) {
        if (Test-Path $candidate) { $iscc = $candidate; break }
    }

    if (-not $iscc) {
        Write-Host 'downloading Inno Setup...'
        # The download page now links to GitHub releases. Use a domestic
        # mirror by default; override with DVPLAYER_GH_PROXY (empty = direct).
        $page = Invoke-WebRequest -UseBasicParsing -Uri 'https://jrsoftware.org/isdl.php' -TimeoutSec 30
        $match = [regex]::Match($page.Content, 'https://github\.com/[^"]+innosetup-6\.[\d.]+\.exe')
        if (-not $match.Success) {
            $url = 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_4/innosetup-6.7.4.exe'
        } else {
            $url = $match.Value
        }

        $mirror = $env:DVPLAYER_GH_PROXY
        if ($null -eq $mirror) { $mirror = 'https://ghfast.top/' }
        $accelerated = if ($mirror -and $url -match '^https://github\.com/') { $mirror + $url } else { $url }

        $setup = Join-Path $env:TEMP ("innosetup-" + [guid]::NewGuid().ToString('N') + '.exe')
        & curl.exe -L --fail --retry 2 --max-time 600 -o $setup $accelerated
        if ($LASTEXITCODE -ne 0 -and $accelerated -ne $url) {
            Write-Warning 'mirror failed, retrying GitHub directly'
            & curl.exe -L --fail --retry 2 --max-time 600 -o $setup $url
        }
        if ($LASTEXITCODE -ne 0) { throw "Inno Setup download failed: $url" }

        $target = Join-Path $repo 'tools\innosetup'
        Start-Process -FilePath $setup -Wait -ArgumentList @(
            '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', "/DIR=$target")
        Remove-Item $setup -Force -ErrorAction SilentlyContinue
        $iscc = Join-Path $target 'ISCC.exe'
    }
    if (-not (Test-Path $iscc)) { throw "ISCC.exe not found after install: $iscc" }

    $iss = Join-Path $packaging 'DvPlayer.iss'
    $parts = @($Version.Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    $versionInfo = ($parts[0..3] -join '.')
    & $iscc `
        "/DAppVersion=$Version" `
        "/DVersionInfo=$versionInfo" `
        "/DSourceDir=$payload" `
        "/DOutputDir=$out" `
        $iss
    if ($LASTEXITCODE -ne 0) { throw 'ISCC failed' }
    Write-Host "installer: $(Join-Path $out "DvPlayer-${Version}-win-x64-setup.exe")"
}

Write-Host ''
Write-Host "output: $out"
Get-ChildItem $out -File | Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } |
    Format-Table | Out-String | Write-Host
