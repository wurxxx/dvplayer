# 验证 mpv IPC + 控制条。
# 关键：PowerShell 默认不是 DPI-aware，Screen.Bounds/CopyFromScreen 会只截到
# 物理屏幕的左上角一块。这里先声明 PerMonitorV2 再测量和截图。

$ErrorActionPreference = "Continue"
$env:DOTNET_ROOT = "D:\dvplayer\dotnet"

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DpiCtx {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
}
"@
[DpiCtx]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$out = "D:\dvplayer\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$log = Join-Path $out "verify-ipc.log"
"# IPC verify $(Get-Date -Format o)" | Set-Content $log
function Say($m) { Write-Host $m; $m | Add-Content $log }

$vs = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
Say ("screen(physical) = {0}x{1}" -f $vs.Width, $vs.Height)

function Shot($name) {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $bmp.Save((Join-Path $out $name), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
    Say "shot: $name"
}

$exe = "D:\dvplayer\apps\windows\DvPlayer.Windows\bin\Release\net10.0-windows\DvPlayer.Windows.exe"
$proc = Start-Process -FilePath $exe -PassThru
Say ("pid=" + $proc.Id)
Start-Sleep -Seconds 14

$pipe = Get-ChildItem \\.\pipe\ |
    Where-Object { $_.Name -like "dvplayer-$($proc.Id)-*" } |
    Select-Object -Last 1
if (-not $pipe) {
    Say "no dvplayer pipe found"
    Shot "a5-ipc-fail.png"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    return
}
Say ("pipe: " + $pipe.Name)

$client = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipe.Name, [System.IO.Pipes.PipeDirection]::InOut)
$client.Connect(3000)
$sw = New-Object System.IO.StreamWriter($client)
$sw.AutoFlush = $true
$sr = New-Object System.IO.StreamReader($client)
$script:rid = 0

function Cmd($cmdArgs) {
    $script:rid++
    $id = $script:rid
    $sw.WriteLine((@{ command = $cmdArgs; request_id = $id } | ConvertTo-Json -Compress))
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
        $line = $sr.ReadLine()
        if ($null -eq $line) { break }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.request_id -eq $id) { return $line }
    }
    return "<timeout>"
}

Say ("time-pos: " + (Cmd @("get_property", "time-pos")))
Say ("duration: " + (Cmd @("get_property", "duration")))
Say ("pause:    " + (Cmd @("get_property", "pause")))
Say ("vid-params: " + (Cmd @("get_property", "video-params/pixelformat")))
Say ("track-dovi-p: " + (Cmd @("get_property", "current-tracks/video/dolby-vision-profile")))
Say ("track-dovi-l: " + (Cmd @("get_property", "current-tracks/video/dolby-vision-level")))

$probe = Join-Path $env:LOCALAPPDATA "dvplayer\dvprobe.json"
if (Test-Path $probe) {
    Say ("dvprobe.json: " + (Get-Content $probe -Raw))
} else {
    Say "dvprobe.json: 还没有（FEL/MEL 探测未完成）"
}
Shot "a5-controls.png"

Say ("set pause true -> " + (Cmd @("set_property", "pause", $true)))
Start-Sleep -Milliseconds 400
Say ("pause now: " + (Cmd @("get_property", "pause")))
Shot "a5-paused.png"

Say ("seek 14 -> " + (Cmd @("seek", 14, "absolute")))
Start-Sleep -Milliseconds 700
Say ("time-pos now: " + (Cmd @("get_property", "time-pos")))
Say ("set pause false -> " + (Cmd @("set_property", "pause", $false)))

# 壳自己的快捷键：焦点给主窗口再按空格
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Fg { [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); }
"@
$proc.Refresh()
[Fg]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 600
[System.Windows.Forms.SendKeys]::SendWait(" ")
Start-Sleep -Milliseconds 800
Say ("pause after Space: " + (Cmd @("get_property", "pause")))

Start-Sleep -Milliseconds 300
Shot "a5-ipc-after.png"

$sw.Dispose()
$sr.Dispose()
$client.Dispose()
Say ("alive=" + (-not $proc.HasExited))
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Say "done"
