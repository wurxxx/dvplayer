# 在交互会话里跑 A5 并抓屏（由 schtasks /it 调用，不要直接 ssh 跑）
$ErrorActionPreference = "Continue"
$env:DOTNET_ROOT = "D:\dvplayer\dotnet"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"

$out = "D:\dvplayer\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$log = Join-Path $out "run-a5.log"
"start $(Get-Date -Format o) session=$((Get-Process -Id $PID).SessionId)" | Set-Content $log

$exe = "D:\dvplayer\apps\windows\DvPlayer.Windows\bin\Release\net10.0-windows\DvPlayer.Windows.exe"
if (-not (Test-Path $exe)) {
    "missing exe: $exe" | Add-Content $log
    exit 1
}

$p = Start-Process -FilePath $exe -PassThru
"pid=$($p.Id)" | Add-Content $log
Start-Sleep -Seconds 20

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size)
$bmp.Save((Join-Path $out "a5-shot.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()
"shot saved" | Add-Content $log

$mpvlog = Join-Path $env:LOCALAPPDATA "dvplayer\mpv.log"
if (Test-Path $mpvlog) {
    Copy-Item $mpvlog (Join-Path $out "mpv.log") -Force
    "mpv.log copied" | Add-Content $log
}

"alive=$(-not $p.HasExited)" | Add-Content $log
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
"done $(Get-Date -Format o)" | Add-Content $log
