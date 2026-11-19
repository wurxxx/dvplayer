# Decode capability matrix: 4K120, 8K60, HDR10, HLG, DV P7.
# NOTE: keep this file pure ASCII. PowerShell 5.1 reads BOM-less files as ANSI
# and multi-byte CJK comments can break quoting.
#
# Round A: realtime playback (gpu-next + d3d11) - hwdec type, frame drops.
# Round B: pure decode (--untimed --vo=null) - throughput, no display limit.
#
# Run via schtasks /it in the interactive session. Output: D:\dvplayer\out\decode\

$ErrorActionPreference = "Continue"

$mpv = "D:\dvplayer\mpv\mpv.com"   # console wrapper: mpv.exe is GUI subsystem (no stdout, no wait)
$out = "D:\dvplayer\out\decode"
New-Item -ItemType Directory -Force -Path $out | Out-Null

$summary = Join-Path $out "summary.txt"
"# decode matrix $(Get-Date -Format o)" | Set-Content $summary
function Say($m) { Write-Host $m; $m | Add-Content $summary }

$playing = 'w=${=video-params/w} h=${=video-params/h} fps=${container-fps} hw=${hwdec-current} pf=${video-params/pixelformat} prim=${video-params/primaries} trc=${video-params/gamma} levels=${video-params/colorlevels} peak=${video-params/sig-peak} depth=${video-params/plane-depth}'
$status = 'drop=${frame-drop-count} decdrop=${decoder-frame-drop-count} vfps=${estimated-vf-fps} dfps=${display-fps}'

$samples = @(
    @{ n = "4k120-hdr10"; f = "D:\dvplayer\samples\uhd-4k120-hdr10.mp4"; frames = 480;  dec = 1200 },
    @{ n = "4k60-hlg";    f = "D:\dvplayer\samples\uhd-4k60-hlg.mp4";    frames = 300;  dec = 900 },
    @{ n = "8k60-hdr10";  f = "D:\dvplayer\samples\uhd-8k60-hdr10.mp4";  frames = 120;  dec = 360 },
    @{ n = "p7-fel";      f = "D:\dvplayer\samples\p7-fel.mkv";          frames = 240;  dec = 720 }
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Dpi2 { [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c); }
"@
[Dpi2]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
Add-Type -AssemblyName System.Windows.Forms
Say ("screen: " + [System.Windows.Forms.Screen]::PrimaryScreen.Bounds)

foreach ($s in $samples) {
    if (-not (Test-Path $s.f)) {
        Say "SKIP $($s.n): missing file"
        continue
    }

    $log = Join-Path $out "$($s.n).log"
    $stats = Join-Path $out "$($s.n).csv"
    $a = @(
        "--no-config", "--vo=gpu-next", "--hwdec=auto-safe", "--terminal=yes",
        "--no-audio", "--no-osc", "--no-input-default-bindings",
        "--frames=$($s.frames)",
        "--msg-level=all=info,vd=v,vo/gpu-next=v",
        "--term-playing-msg=$playing",
        "--term-status-msg=$status",
        "--dump-stats=$stats",
        $s.f
    )

    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $mpv @a *> $log
    $el = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    Say ("A $($s.n): exit=$LASTEXITCODE elapsed=${el}s frames=$($s.frames)")

    $blog = Join-Path $out "$($s.n).decode.log"
    $b = @(
        "--no-config", "--vo=null", "--hwdec=auto-safe", "--untimed", "--terminal=yes",
        "--no-audio", "--frames=$($s.dec)",
        "--msg-level=all=info,vd=v",
        $s.f
    )
    $sw.Restart()
    & $mpv @b *> $blog
    $el = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    $fps = if ($el -gt 0) { [Math]::Round($s.dec / $el, 1) } else { 0 }
    Say ("B $($s.n): exit=$LASTEXITCODE elapsed=${el}s frames=$($s.dec) decode-fps=$fps")
}

Say "done"
