# Compare scalers for 8K/4K120 render throughput (--untimed, real gpu-next window).
# Pure ASCII.

$ErrorActionPreference = "Continue"

$mpv = "D:\dvplayer\mpv\mpv.com"
$out = "D:\dvplayer\out\decode3"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$summary = Join-Path $out "scalers.txt"
"# scaler compare $(Get-Date -Format o)" | Set-Content $summary
function Say($m) { Write-Host $m; $m | Add-Content $summary }

$cases = @(
    @{ n = "8k60-hdr10"; f = "D:\dvplayer\samples\uhd-8k60-hdr10.mp4"; frames = 240; scale = "bilinear" },
    @{ n = "8k60-hdr10"; f = "D:\dvplayer\samples\uhd-8k60-hdr10.mp4"; frames = 240; scale = "lanczos" },
    @{ n = "4k120-hdr10"; f = "D:\dvplayer\samples\uhd-4k120-hdr10.mp4"; frames = 600; scale = "bilinear" }
)

foreach ($c in $cases) {
    $a = @(
        "--no-config", "--vo=gpu-next", "--hwdec=auto-safe", "--untimed",
        "--no-audio", "--no-osc", "--no-input-default-bindings",
        "--scale=$($c.scale)", "--frames=$($c.frames)",
        "--msg-level=all=info", $c.f
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $mpv @a *> (Join-Path $out "scaler-$($c.n)-$($c.scale).log")
    $el = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    $fps = if ($el -gt 0) { [Math]::Round($c.frames / $el, 1) } else { 0 }
    Say ("$($c.n) scale=$($c.scale): frames=$($c.frames) elapsed=${el}s render-fps=$fps")
}

Say "done"
