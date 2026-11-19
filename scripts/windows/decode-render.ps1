# Render throughput: real gpu-next window, --untimed (no vsync wait), count frames/time.
# If elapsed ~= frames / source_fps, the GPU can render at the source rate.
# Pure ASCII (PowerShell 5.1 ANSI parsing).

$ErrorActionPreference = "Continue"

$mpv = "D:\dvplayer\mpv\mpv.com"
$out = "D:\dvplayer\out\decode3"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$summary = Join-Path $out "summary.txt"
"# render throughput $(Get-Date -Format o)" | Set-Content $summary
function Say($m) { Write-Host $m; $m | Add-Content $summary }

$samples = @(
    @{ n = "4k120-hdr10";     f = "D:\dvplayer\samples\uhd-4k120-hdr10.mp4";     frames = 600; src = 120 },
    @{ n = "4k60-hlg";        f = "D:\dvplayer\samples\uhd-4k60-hlg.mp4";        frames = 300; src = 60 },
    @{ n = "4k60-hdr10plus";  f = "D:\dvplayer\samples\uhd-4k60-hdr10plus.mp4";  frames = 300; src = 60 },
    @{ n = "8k60-hdr10";      f = "D:\dvplayer\samples\uhd-8k60-hdr10.mp4";      frames = 240; src = 60 },
    @{ n = "p7-fel";          f = "D:\dvplayer\samples\p7-fel.mkv";              frames = 240; src = 23.976 }
)

foreach ($s in $samples) {
    if (-not (Test-Path $s.f)) { Say "SKIP $($s.n): missing"; continue }

    $a = @(
        "--no-config", "--vo=gpu-next", "--hwdec=auto-safe",
        "--untimed", "--no-audio", "--no-osc", "--no-input-default-bindings",
        "--frames=$($s.frames)", "--msg-level=all=info,vo/gpu-next=info",
        $s.f
    )

    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $mpv @a *> (Join-Path $out "$($s.n).log")
    $el = [Math]::Round($sw.Elapsed.TotalSeconds, 2)

    $fps = if ($el -gt 0) { [Math]::Round($s.frames / $el, 1) } else { 0 }
    $ok = if ($fps -ge $s.src) { "OK" } else { "SLOW" }
    Say ("$($s.n): frames=$($s.frames) src=$($s.src) elapsed=${el}s render-fps=$fps $ok")
}

Say "done"
