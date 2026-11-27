# 从本地密钥文件生成 Windows 构建用的 MSBuild 属性文件。
#
#   %USERPROFILE%\.config\dvplayer\trakt.env     TRAKT_CLIENT_ID / TRAKT_CLIENT_SECRET
#   %USERPROFILE%\.config\dvplayer\danmaku.env   DANMAKU_APP_ID / DANMAKU_APP_SECRET
#
# 输出 %USERPROFILE%\.config\dvplayer\windows.props（仓库外面），
# DvPlayer.csproj 会自动导入，于是普通 `dotnet build` 和 `dotnet publish`
# 也带上和发布包一样的凭据：设置页不再出现 Client ID / Secret 输入框。
#
# 环境变量优先（DVPLAYER_TRAKT_CLIENT_ID 等），方便临时覆盖。
# 两个 env 文件都没有时删除旧 props，避免一直带着过期凭据。

param([string]$OutFile = "")

$ErrorActionPreference = "Stop"

if (-not $OutFile) {
    $OutFile = Join-Path $env:USERPROFILE ".config\dvplayer\windows.props"
}

function Read-EnvFile([string]$path) {
    $map = @{}
    if (-not (Test-Path $path)) { return $map }
    Get-Content $path -Encoding UTF8 |
        Where-Object { $_ -match '^\s*[A-Za-z_]+\s*=' } |
        ForEach-Object {
            $name, $value = $_.Split('=', 2)
            $map[$name.Trim()] = $value.Trim()
        }
    return $map
}

function Pick([string]$envName, $map, [string]$key) {
    $value = [Environment]::GetEnvironmentVariable($envName)
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $map[$key] }
    if ($null -eq $value) { return "" }
    return $value.Trim()
}

function XmlEscape([string]$text) {
    return $text.Replace('&', '&amp;').Replace('<', '&lt;').
        Replace('>', '&gt;').Replace('"', '&quot;')
}

$cfgDir = Join-Path $env:USERPROFILE ".config\dvplayer"
$trakt = Read-EnvFile (Join-Path $cfgDir "trakt.env")
$danmaku = Read-EnvFile (Join-Path $cfgDir "danmaku.env")

$values = [ordered]@{
    DanmakuAppId      = Pick "DVPLAYER_DANMAKU_APP_ID" $danmaku "DANMAKU_APP_ID"
    DanmakuAppSecret  = Pick "DVPLAYER_DANMAKU_APP_SECRET" $danmaku "DANMAKU_APP_SECRET"
    TraktClientId     = Pick "DVPLAYER_TRAKT_CLIENT_ID" $trakt "TRAKT_CLIENT_ID"
    TraktClientSecret = Pick "DVPLAYER_TRAKT_CLIENT_SECRET" $trakt "TRAKT_CLIENT_SECRET"
}

$lines = @(
    '<Project>',
    '  <!-- 本机凭据：scripts\windows\sync-secrets.ps1 生成，不在仓库里，不要提交。 -->',
    '  <PropertyGroup>'
)
$written = 0
foreach ($key in $values.Keys) {
    $value = $values[$key]
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    $lines += ("    <{0}>{1}</{0}>" -f $key, (XmlEscape $value))
    $written++
}
$lines += '  </PropertyGroup>'
$lines += '</Project>'

if ($written -eq 0) {
    Write-Warning "没有找到凭据（trakt.env / danmaku.env / 环境变量），删除旧的 windows.props"
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
    exit 0
}

New-Item -ItemType Directory -Force (Split-Path -Parent $OutFile) | Out-Null
Set-Content -Path $OutFile -Value $lines -Encoding UTF8
Write-Host ("已生成 {0}（{1} 项）" -f $OutFile, $written)
