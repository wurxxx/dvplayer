# A5 量化验证：DPI、窗口/客户区、mpv 子窗口是否跟随、F11、改尺寸。
# 由 schtasks /it 在交互会话里跑。

$ErrorActionPreference = "Continue"
$env:DOTNET_ROOT = "D:\dvplayer\dotnet"

# PowerShell 默认不 DPI-aware：缩放屏上 Screen.Bounds 是虚拟化后的尺寸，
# CopyFromScreen 也只截到左上角一块。先声明 PerMonitorV2 再量、再截。
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

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Win32 {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
}
"@

$out = "D:\dvplayer\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$report = Join-Path $out "verify-a5.log"
"# A5 verify $(Get-Date -Format o)" | Set-Content $report

function Say($msg) {
    Write-Host $msg
    $msg | Add-Content $report
}

function Rect($h) {
    $r = New-Object Win32+RECT
    [Win32]::GetWindowRect($h, [ref]$r) | Out-Null
    return @{ L = $r.Left; T = $r.Top; W = $r.Right - $r.Left; H = $r.Bottom - $r.Top }
}

function Snapshot($tag) {
    $h = $script:main
    if ($h -eq [IntPtr]::Zero) { Say "$tag : no window"; return }
    $w = Rect $h
    $c = New-Object Win32+RECT
    [Win32]::GetClientRect($h, [ref]$c) | Out-Null
    $dpi = [Win32]::GetDpiForWindow($h)
    Say ("{0}: hwnd=0x{1:X} window={2},{3} {4}x{5}  client={6}x{7}  dpi={8}" -f $tag, $h.ToInt64(), $w.L, $w.T, $w.W, $w.H, $c.Right, $c.Bottom, $dpi)

    $script:kids = @()
    $cb = [Win32+EnumProc] {
        param($ch, $l)
        $script:kids += $ch
        return $true
    }
    [Win32]::EnumChildWindows($h, $cb, [IntPtr]::Zero) | Out-Null

    foreach ($k in $script:kids) {
        $owner = 0
        [Win32]::GetWindowThreadProcessId($k, [ref]$owner) | Out-Null
        $sb = New-Object System.Text.StringBuilder 128
        [Win32]::GetClassName($k, $sb, 128) | Out-Null
        $r = Rect $k
        Say ("   child hwnd=0x{0:X} pid={1} class={2} rect={3},{4} {5}x{6}" -f $k.ToInt64(), $owner, $sb.ToString(), $r.L, $r.T, $r.W, $r.H)
    }
}

function Shot($name) {
    $vs = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size)
    $bmp.Save((Join-Path $out $name), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
    Say "shot: $name"
}

$exe = "D:\dvplayer\apps\windows\DvPlayer.Windows\bin\Release\net10.0-windows\DvPlayer.Windows.exe"
$proc = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 3

# 等主窗口出现
for ($i = 0; $i -lt 40 -and $proc.MainWindowHandle -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 500
    $proc.Refresh()
}
$script:main = $proc.MainWindowHandle

Say ("screen: {0}x{1} at {2},{3}" -f [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width,
    [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height,
    [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.X,
    [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Y)

Start-Sleep -Seconds 8
Snapshot "startup"
Shot "a5-startup.png"

# --- F11 全屏 ---
[Win32]::SetForegroundWindow($script:main) | Out-Null
Start-Sleep -Milliseconds 800
[System.Windows.Forms.SendKeys]::SendWait("{F11}")
Start-Sleep -Seconds 3
Snapshot "f11-on"
Shot "a5-fullscreen.png"

[System.Windows.Forms.SendKeys]::SendWait("{F11}")
Start-Sleep -Seconds 3
Snapshot "f11-off"

# --- 改尺寸，看 mpv 子窗口跟不跟 ---
[Win32]::SetWindowPos($script:main, [IntPtr]::Zero, 120, 90, 1400, 800, 0x0040) | Out-Null
Start-Sleep -Seconds 3
Snapshot "resize-1400x800"
Shot "a5-resize.png"

Say ("alive=" + (-not $proc.HasExited))
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Say "done"
