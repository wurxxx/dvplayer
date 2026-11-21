# Build the Windows release artifacts:
#   - portable zip  (out\release\DvPlayer-<version>-win-x64-portable.zip)
#   - Inno Setup installer (out\release\DvPlayer-<version>-win-x64-setup.exe)
#
# Both use the same self-contained win-x64 publish payload, including
# dvplayer_media.dll and the bundled mpv.
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

if (-not $SkipPublish) {
    if (Test-Path $payload) { Remove-WithRetry $payload }
    New-Item -ItemType Directory -Force $payload | Out-Null
    dotnet publish $proj -c $Configuration -r win-x64 --self-contained true `
        -p:DebugType=none -o $payload
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
}
if (-not (Test-Path (Join-Path $payload 'DvPlayer.exe'))) {
    throw "payload missing DvPlayer.exe: $payload"
}

# Shared Rust core (same copy rule as the MSIX script).
$core = Join-Path $repo 'core\target\x86_64-pc-windows-gnu\release\dvplayer_media.dll'
if (Test-Path $core) {
    Copy-Item $core $payload -Force
} elseif (-not (Test-Path (Join-Path $payload 'dvplayer_media.dll'))) {
    throw 'dvplayer_media.dll not found. Run scripts\windows\build-core.ps1 first.'
}

# mpv: ship it beside the exe so the package works on a clean machine.
$payloadMpv = Join-Path $payload 'mpv'
if (-not (Test-Path (Join-Path $payloadMpv 'mpv.exe'))) {
    if (-not (Test-Path (Join-Path $MpvDir 'mpv.exe'))) {
        throw "mpv.exe not found in $MpvDir. Pass -MpvDir <dir>."
    }
    New-Item -ItemType Directory -Force $payloadMpv | Out-Null
    Copy-Item (Join-Path $MpvDir '*') $payloadMpv -Recurse -Force
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
