# Build DVPlayer as a signed MSIX package (Windows).
#
# Usage (elevated PowerShell for first run if you also want to trust the cert):
#   powershell -ExecutionPolicy Bypass -File apps\windows\packaging\build-msix.ps1
#   powershell -ExecutionPolicy Bypass -File apps\windows\packaging\build-msix.ps1 -Version 1.0.1.0
#   ... -UpdateUrl http://127.0.0.1:8899/DvPlayer.appinstaller
#
# What it does:
#   1. dotnet publish (self-contained win-x64) into out\msix\payload
#   2. copies dvplayer_media.dll, mpv\ and MSIX assets
#   3. generates AppxManifest.xml from Package.appxmanifest
#   4. packs with makeappx.exe from Microsoft.Windows.SDK.BuildTools (NuGet)
#   5. signs with a reusable self-signed development certificate
#   6. optionally writes a .appinstaller update feed for App Installer
#
# The dev certificate lives in %LOCALAPPDATA%\dvplayer\msix (pfx + password + cer),
# not in the repo. Trust the cer once per machine:
#   Import-Certificate -FilePath <cer> -CertStoreLocation Cert:\LocalMachine\TrustedPeople

param(
    [string]$Configuration = 'Release',
    [string]$Version = '',
    [string]$Publisher = 'CN=DvPlayer Dev',
    [string]$IdentityName = 'Luckywur.DvPlayer',
    [string]$UpdateUrl = '',
    [string]$PfxPath = '',
    [string]$PfxPassword = '',
    [string]$MpvDir = 'D:\dvplayer\mpv',
    [string]$OutputDir = '',
    [switch]$SkipPublish,
    [switch]$SkipSign
)

$ErrorActionPreference = 'Stop'

$packaging = $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $packaging))
$out = if ($OutputDir) { $OutputDir } else { Join-Path $repo 'out\msix' }
$payload = Join-Path $out 'payload'
$proj = Join-Path $repo 'apps\windows\DvPlayer\DvPlayer.csproj'

if (-not $Version) {
    $xml = [xml](Get-Content $proj)
    $Version = @($xml.Project.PropertyGroup.Version | Where-Object { $_ })[0]
    if (-not $Version) { $Version = '0.1.0' }
}
$parts = @($Version.Split('.'))
while ($parts.Count -lt 4) { $parts += '0' }
$Version = ($parts[0..3] -join '.')

Write-Host "== DVPlayer MSIX $Version =="
Write-Host "repo: $repo"

# ---------------------------------------------------------------- tools
function Find-SdkTool([string]$name) {
    $root = Join-Path $env:USERPROFILE '.nuget\packages\microsoft.windows.sdk.buildtools'
    if (-not (Test-Path $root)) { return $null }
    return Get-ChildItem $root -Recurse -Filter $name -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
}

$makeappx = Find-SdkTool 'makeappx.exe'
$signtool = Find-SdkTool 'signtool.exe'
if (-not $makeappx -or -not $signtool) {
    Write-Host 'restoring Microsoft.Windows.SDK.BuildTools...'
    dotnet restore (Join-Path $packaging 'BuildTools.csproj') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'dotnet restore for SDK BuildTools failed' }
    $makeappx = Find-SdkTool 'makeappx.exe'
    $signtool = Find-SdkTool 'signtool.exe'
}
if (-not $makeappx -or -not $signtool) { throw 'makeappx.exe / signtool.exe not found' }
Write-Host "makeappx: $($makeappx.FullName)"

# ---------------------------------------------------------------- publish
if (-not $SkipPublish) {
    if (Test-Path $payload) { Remove-Item $payload -Recurse -Force }
    New-Item -ItemType Directory -Force $payload | Out-Null
    dotnet publish $proj -c $Configuration -r win-x64 --self-contained true `
        -p:DebugType=none -o $payload
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
}
if (-not (Test-Path (Join-Path $payload 'DvPlayer.exe'))) {
    throw "payload missing DvPlayer.exe: $payload"
}

# Shared core DLL: the csproj copies it into bin on build, but publish -o may
# not run that target. Copy straight from the Rust release output.
$core = Join-Path $repo 'core\target\x86_64-pc-windows-gnu\release\dvplayer_media.dll'
if (Test-Path $core) {
    Copy-Item $core $payload -Force
} elseif (-not (Test-Path (Join-Path $payload 'dvplayer_media.dll'))) {
    throw "dvplayer_media.dll not found. Run scripts\windows\build-core.ps1 first."
}

# mpv is the playback engine; ship it beside the exe (the app also accepts
# DVPLAYER_MPV, but the package should work on a clean machine).
$payloadMpv = Join-Path $payload 'mpv'
if (-not (Test-Path (Join-Path $payloadMpv 'mpv.exe'))) {
    if (-not (Test-Path (Join-Path $MpvDir 'mpv.exe'))) {
        throw "mpv.exe not found in $MpvDir. Pass -MpvDir <dir>."
    }
    New-Item -ItemType Directory -Force $payloadMpv | Out-Null
    Copy-Item (Join-Path $MpvDir '*') $payloadMpv -Recurse -Force
}

# MSIX logos (generated from the app icon by scripts/make-msix-assets.py).
$payloadAssets = Join-Path $payload 'Assets'
New-Item -ItemType Directory -Force $payloadAssets | Out-Null
Copy-Item (Join-Path $packaging 'Assets\*') $payloadAssets -Force

# ---------------------------------------------------------------- manifest
$template = Get-Content (Join-Path $packaging 'Package.appxmanifest') -Raw
$manifest = $template.Replace('__IDENTITY__', $IdentityName)
$manifest = $manifest.Replace('__PUBLISHER__', $Publisher)
$manifest = $manifest.Replace('__VERSION__', $Version)
$manifestPath = Join-Path $payload 'AppxManifest.xml'
[IO.File]::WriteAllText($manifestPath, $manifest, (New-Object System.Text.UTF8Encoding -ArgumentList $false))

# ---------------------------------------------------------------- pack
New-Item -ItemType Directory -Force $out | Out-Null
$msixName = "DvPlayer_${Version}_x64.msix"
$msix = Join-Path $out $msixName
if (Test-Path $msix) { Remove-Item $msix -Force }

& $makeappx.FullName pack /d $payload /p $msix /o
if ($LASTEXITCODE -ne 0) { throw 'makeappx pack failed' }
Write-Host "packed: $msix"

# ---------------------------------------------------------------- cert
$certDir = Join-Path $env:LOCALAPPDATA 'dvplayer\msix'
New-Item -ItemType Directory -Force $certDir | Out-Null
$cer = Join-Path $certDir 'DvPlayer-Dev.cer'
$passFile = Join-Path $certDir 'DvPlayer-Dev.password'
if (-not $PfxPath) { $PfxPath = Join-Path $certDir 'DvPlayer-Dev.pfx' }
if (-not $PfxPassword -and (Test-Path $passFile)) {
    $PfxPassword = (Get-Content $passFile -Raw).Trim()
}

if (-not $SkipSign -and -not (Test-Path $PfxPath)) {
    Write-Host 'creating self-signed development certificate...'
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $PfxPassword = [Convert]::ToBase64String($bytes)
    [IO.File]::WriteAllText($passFile, $PfxPassword, (New-Object System.Text.UTF8Encoding -ArgumentList $false))

    $cert = New-SelfSignedCertificate `
        -Type Custom `
        -Subject $Publisher `
        -KeyUsage DigitalSignature `
        -KeyExportPolicy Exportable `
        -FriendlyName 'DVPlayer Dev' `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    $secure = ConvertTo-SecureString $PfxPassword -AsPlainText -Force
    Export-PfxCertificate -Cert $cert -FilePath $PfxPath -Password $secure | Out-Null
    Export-Certificate -Cert $cert -FilePath $cer | Out-Null
    Write-Host "certificate thumbprint: $($cert.Thumbprint)"
} elseif (-not (Test-Path $cer)) {
    $found = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $Publisher } |
        Select-Object -First 1
    if ($found) { Export-Certificate -Cert $found -FilePath $cer | Out-Null }
}

# ---------------------------------------------------------------- sign
if (-not $SkipSign) {
    if (-not $PfxPassword) { throw 'no pfx password. Pass -PfxPassword.' }
    & $signtool.FullName sign /fd SHA256 /f $PfxPath /p $PfxPassword `
        /tr 'http://timestamp.digicert.com' /td SHA256 $msix
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'timestamp server unreachable, signing without timestamp'
        & $signtool.FullName sign /fd SHA256 /f $PfxPath /p $PfxPassword $msix
        if ($LASTEXITCODE -ne 0) { throw 'signtool sign failed' }
    }
    Write-Host 'signed'
}

# ---------------------------------------------------------------- update feed
if ($UpdateUrl) {
    $feed = Join-Path $out 'feed'
    New-Item -ItemType Directory -Force $feed | Out-Null
    Copy-Item $msix (Join-Path $feed $msixName) -Force

    $base = New-Object System.Uri -ArgumentList $UpdateUrl
    $msixUri = (New-Object System.Uri -ArgumentList $base, $msixName).AbsoluteUri
    $installer = @"
<?xml version="1.0" encoding="utf-8"?>
<AppInstaller Uri="$UpdateUrl" Version="$Version" xmlns="http://schemas.microsoft.com/appx/appinstaller/2018">
  <MainBundle Name="$IdentityName" Version="$Version" Publisher="$Publisher" Uri="$msixUri" />
  <UpdateSettings>
    <OnLaunch HoursBetweenUpdateChecks="0" ShowPrompt="false" UpdateBlocksActivation="false" />
    <AutomaticBackgroundTask />
    <ForceUpdateFromAnyVersion>true</ForceUpdateFromAnyVersion>
  </UpdateSettings>
</AppInstaller>
"@
    $installerPath = Join-Path $feed 'DvPlayer.appinstaller'
    [IO.File]::WriteAllText($installerPath, $installer, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
    Write-Host "update feed: $installerPath"
}

Write-Host ''
Write-Host "MSIX : $msix"
Write-Host ("SIZE : {0:N1} MB" -f ((Get-Item $msix).Length / 1MB))
if (Test-Path $cer) {
    Write-Host "CERT : $cer"
    Write-Host "TRUST: Import-Certificate -FilePath `"$cer`" -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
}
