# Play a Blu-ray ISO through mpv's libbluray and capture the bluray/decoder log.
# mpv reads the ISO directly (no mount needed): --bluray-device=<iso> bd://...
# Pure ASCII.

param(
    [Parameter(Mandatory = $true)][string]$Iso,
    [string]$Target = "bd://",
    [int]$Frames = 300,
    [string]$Tag = "default",
    [string]$Extra = ""
)

$ErrorActionPreference = "Continue"
$mpv = "D:\dvplayer\mpv\mpv.com"
$out = "D:\dvplayer\out\iso-play-$Tag.log"
$raw = "D:\dvplayer\out\iso-play-$Tag.raw.txt"

"# iso-play tag=$Tag target=$Target $(Get-Date -Format o)" | Set-Content $out
function Log($m) { Write-Host $m; $m | Add-Content $out }

if (-not (Test-Path $Iso)) { Log "missing $Iso"; exit 2 }

Log "iso = $Iso"
Log "target = $Target"
Log "frames = $Frames"

# Single-quoted so PowerShell does not expand ${...}; mpv expands them.
$statusMsg = '--term-playing-msg=duration=${duration} res=${width}x${height} codec=${video-codec} fps=${estimated-vf-fps} hwdec=${hwdec-current}'

$a = @(
    "--no-config",
    "--vo=gpu-next",
    "--hwdec=auto-safe",
    "--no-audio",
    "--osc=no",
    "--no-input-default-bindings",
    "--bluray-device=$Iso",
    "--msg-level=all=info,bd=v,bluray=v,disc=v",
    "--frames=$Frames",
    $statusMsg,
    $Target
)
if ($Extra) { $a = @($Extra -split '\s+' | Where-Object { $_ }) + $a }

$sw = [Diagnostics.Stopwatch]::StartNew()
& $mpv @a 2>&1 | ForEach-Object { $_.ToString() } | Out-File -Encoding UTF8 $raw
$code = $LASTEXITCODE
Log "mpv exit=$code elapsed=$([int]$sw.Elapsed.TotalSeconds)s"

Log "--- bluray / playlist ---"
Get-Content $raw -ErrorAction SilentlyContinue |
    Select-String -Pattern "bluray|bd_|playlist|title|disc|BDMV|MPLS|opening" |
    Select-Object -First 30 | ForEach-Object { Log $_.Line.Trim() }

Log "--- decoder / vo ---"
Get-Content $raw -ErrorAction SilentlyContinue |
    Select-String -Pattern "VO: \[|Using hardware|Opening decoder|hwdec|duration=|res=" |
    Select-Object -First 15 | ForEach-Object { Log $_.Line.Trim() }

Log "--- errors ---"
Get-Content $raw -ErrorAction SilentlyContinue |
    Select-String -Pattern "error|failed|not supported|could not" |
    Select-Object -First 15 | ForEach-Object { Log $_.Line.Trim() }
