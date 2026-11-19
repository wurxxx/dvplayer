# A4 on Windows: mpv --wid into a WinForms parent window
#
# Verifies that an external HWND can host mpv's gpu-next output with Dolby
# Vision Profile 7 FEL (splitter + EL pairing + DV colour system).
#
# DPI note: the process must be DPI-aware BEFORE any window is created.
# Without it, Windows virtualises the client rect at 150% scaling while mpv
# renders at physical pixels, which crops the picture (this actually happened
# on the first run: 2160x1440 @ 144 DPI, image zoomed and clipped).
# AutoScaleMode=None keeps WinForms from rescaling the client size again.

param(
    [string]$Root = $PSScriptRoot,
    [int]$Seconds = 20
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DpiHelper {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[DpiHelper]::SetProcessDPIAware() | Out-Null

$sample = Join-Path $Root "samples\p7-fel.mkv"
if (-not (Test-Path $sample)) { $sample = Join-Path $Root "p7-fel.mkv" }
if (-not (Test-Path $sample)) {
    Write-Host "ERROR: p7-fel.mkv not found under $Root (looked in samples\ and .\)"
    Read-Host "Press Enter"
    exit 1
}

$mpv = Join-Path $Root "mpv\mpv.exe"
if (-not (Test-Path $mpv)) {
    Write-Host "ERROR: $mpv not found. Unzip the mpv build so that mpv\mpv.exe exists."
    Read-Host "Press Enter"
    exit 1
}

$outDir = Join-Path $Root "out"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$log = Join-Path $outDir "a4-wid.log"
$err = "$log.err"

$form = New-Object System.Windows.Forms.Form
$form.Text = "A4: mpv --wid (DPI-aware)"
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.ClientSize = New-Object System.Drawing.Size(1280, 720)   # 16:9, same as the frame
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::Black
$form.Show()
[System.Windows.Forms.Application]::DoEvents()

$hwnd = $form.Handle.ToInt64()
Write-Host "parent HWND = $hwnd, client = $($form.ClientSize.Width)x$($form.ClientSize.Height)"

$mpvArgs = @(
    "--no-config",
    "--vo=gpu-next",
    "--wid=$hwnd",
    "--msg-level=vd=v,vf=v,mkv=v,cplayer=info,vo/gpu-next=info,vo/gpu-next/win32=v",
    "--length=$Seconds",
    $sample
)

$proc = Start-Process -FilePath $mpv -ArgumentList $mpvArgs -PassThru `
    -RedirectStandardOutput $log -RedirectStandardError $err

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
    if ($proc.HasExited) { $form.Close() }
})
$timer.Start()

Write-Host "mpv pid = $($proc.Id), playing $Seconds s inside the form."
Write-Host "Expect the picture inside this window, black bars only where the source has them."
[System.Windows.Forms.Application]::Run($form)

Remove-Item $err -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "==== key log lines ===="
Select-String -Path $log -Pattern "Dolby Vision Profile","DPI detected","\[el_pair\]","VO: \[gpu-next\]" |
    ForEach-Object { $_.Line }
Write-Host ""
Write-Host "log: $log"
Read-Host "Press Enter"
