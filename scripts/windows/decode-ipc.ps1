# Decode matrix through the real product path: shell + mpv --wid + IPC.
# Pure ASCII (PowerShell 5.1 ANSI parsing).
#
# Samples are short (2-5 s), so we loop the file and take 3 samples 4 s apart
# to separate startup cost from steady state. Steady drop rate tells whether
# the bottleneck is decode (decdrop) or render/display (drop).

$ErrorActionPreference = "Continue"

$exe = "D:\dvplayer\apps\windows\DvPlayer.Windows\bin\Release\net10.0-windows\DvPlayer.Windows.exe"
$out = "D:\dvplayer\out\decode2"
New-Item -ItemType Directory -Force -Path $out | Out-Null

$summary = Join-Path $out "summary.txt"
"# shell decode matrix $(Get-Date -Format o)" | Set-Content $summary
function Say($m) { Write-Host $m; $m | Add-Content $summary }

$samples = @(
    @{ n = "4k120-hdr10"; f = "D:\dvplayer\samples\uhd-4k120-hdr10.mp4" },
    @{ n = "4k60-hlg";    f = "D:\dvplayer\samples\uhd-4k60-hlg.mp4" },
    @{ n = "4k60-hdr10plus"; f = "D:\dvplayer\samples\uhd-4k60-hdr10plus.mp4" },
    @{ n = "8k60-hdr10";  f = "D:\dvplayer\samples\uhd-8k60-hdr10.mp4" },
    @{ n = "p7-fel";      f = "D:\dvplayer\samples\p7-fel.mkv" }
)

$sw = $null
$sr = $null
$rid = 0

function Invoke-Mpv($cmd) {
    $script:rid++
    $id = $script:rid
    $script:sw.WriteLine((@{ command = $cmd; request_id = $id } | ConvertTo-Json -Compress))
    $deadline = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $deadline) {
        $line = $script:sr.ReadLine()
        if ($null -eq $line) { break }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.request_id -eq $id) {
            if ($o.error -ne "success") { return $null }
            return $o.data
        }
    }
    return $null
}

function Snapshot {
    return [pscustomobject]@{
        drop    = Invoke-Mpv -cmd @("get_property", "frame-drop-count")
        decdrop = Invoke-Mpv -cmd @("get_property", "decoder-frame-drop-count")
        vfps    = Invoke-Mpv -cmd @("get_property", "estimated-vf-fps")
    }
}

foreach ($s in $samples) {
    if (-not (Test-Path $s.f)) {
        Say "SKIP $($s.n): missing"
        continue
    }

    $env:DVPLAYER_FILE = $s.f
    $proc = Start-Process -FilePath $exe -PassThru

    $pipe = $null
    for ($i = 0; $i -lt 20 -and -not $pipe; $i++) {
        Start-Sleep -Milliseconds 400
        $pipe = Get-ChildItem \\.\pipe\ | Where-Object { $_.Name -like "dvplayer-$($proc.Id)-*" } | Select-Object -Last 1
    }
    if (-not $pipe) {
        Say "$($s.n): no pipe (pid=$($proc.Id))"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        continue
    }

    $client = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipe.Name, [System.IO.Pipes.PipeDirection]::InOut)
    try { $client.Connect(3000) } catch { Say "$($s.n): pipe connect failed"; continue }
    $script:sw = New-Object System.IO.StreamWriter($client)
    $script:sw.AutoFlush = $true
    $script:sr = New-Object System.IO.StreamReader($client)
    $script:rid = 0

    $size = Invoke-Mpv -cmd @("get_property", "video-params/w")
    $height = Invoke-Mpv -cmd @("get_property", "video-params/h")
    $cfps = Invoke-Mpv -cmd @("get_property", "container-fps")
    $hw = Invoke-Mpv -cmd @("get_property", "hwdec-current")
    $pf = Invoke-Mpv -cmd @("get_property", "video-params/pixelformat")
    $prim = Invoke-Mpv -cmd @("get_property", "video-params/primaries")
    $trc = Invoke-Mpv -cmd @("get_property", "video-params/gamma")
    $dfps = Invoke-Mpv -cmd @("get_property", "display-fps")

    Start-Sleep -Seconds 2
    $a = Snapshot
    Start-Sleep -Seconds 3
    $b = Snapshot
    Start-Sleep -Seconds 3
    $c = Snapshot

    $dropRate = [Math]::Round(($c.drop - $b.drop) / 3.0, 1)
    $decRate = [Math]::Round(($c.decdrop - $b.decdrop) / 3.0, 1)

    Say ("== $($s.n)")
    Say ("   {0}x{1} src={2} hw={3} pf={4} prim={5} trc={6} display={7}Hz" -f `
        $size, $height, $cfps, $hw, $pf, $prim, $trc, $dfps)
    Say ("   drop {0}/{1}/{2}  decdrop {3}/{4}/{5}  vfps {6}/{7}/{8}" -f `
        $a.drop, $b.drop, $c.drop, $a.decdrop, $b.decdrop, $c.decdrop, $a.vfps, $b.vfps, $c.vfps)
    Say ("   steady: display-drop={0}/s  decode-drop={1}/s" -f $dropRate, $decRate)

    $script:sw.Dispose(); $script:sr.Dispose(); $client.Dispose()
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

Remove-Item Env:\DVPLAYER_FILE -ErrorAction SilentlyContinue
Say "done"
