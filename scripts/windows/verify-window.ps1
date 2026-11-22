# 看窗口实际尺寸和控制条是否画出来：PrintWindow 抓窗口自身（不受屏幕位置影响）。
$ErrorActionPreference = "Continue"
$env:DOTNET_ROOT = "D:\dvplayer\dotnet"
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Pw {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
}
"@

$out = "D:\dvplayer\out"
$log = Join-Path $out "verify-window.log"
"# window $(Get-Date -Format o)" | Set-Content $log
function Say($m) { Write-Host $m; $m | Add-Content $log }

$exe = "D:\dvplayer\apps\windows\DvPlayer.Windows\bin\Release\net10.0-windows\DvPlayer.Windows.exe"
$proc = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 8
$proc.Refresh()
$h = $proc.MainWindowHandle
if ($h -eq [IntPtr]::Zero) { Say "no window"; return }

$r = New-Object Pw+RECT
[Pw]::GetWindowRect($h, [ref]$r) | Out-Null
$c = New-Object Pw+RECT
[Pw]::GetClientRect($h, [ref]$c) | Out-Null
Say ("window rect = {0},{1} {2}x{3}" -f $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
Say ("client rect = {0}x{1}" -f $c.Right, $c.Bottom)

$w = $r.Right - $r.Left
$hh = $r.Bottom - $r.Top
$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
[Pw]::PrintWindow($h, $hdc, 0) | Out-Null
$g.ReleaseHdc($hdc)
$g.Dispose()
$bmp.Save((Join-Path $out "a5-window.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Say "saved a5-window.png"

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Say "done"
