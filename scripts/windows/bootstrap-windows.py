#!/usr/bin/env python3
"""Windows 一次性交付：等代理上线 → 装 .NET 10 SDK → 解包并编译 A5 → 跑起来抓屏。

前提：Windows 上双击了 agent.bat（会自动提权），代理在轮询 /agent/task。

用法：

    python3 scripts/windows/bootstrap-windows.py            # 等到天亮
    python3 scripts/windows/bootstrap-windows.py --wait 600 # 最多等 10 分钟

每一步的输出都会打印并写进 build/agent/bootstrap.log。
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import dvagent  # noqa: E402

LOG = os.path.join(dvagent.STATE, "bootstrap.log")

PROBE = 'Write-Output ("DVAGENT " + $env:COMPUTERNAME + " " + [Environment]::OSVersion.VersionString)'

SDK = r'''
$ErrorActionPreference = "Continue"
$base = "http://192.168.0.15:8080"
$dst = "D:\dvplayer\setup"
New-Item -ItemType Directory -Force -Path $dst | Out-Null

# 解压版 SDK：不装系统目录、不需要管理员
$root = "D:\dvplayer\dotnet"
$dotnet = Join-Path $root "dotnet.exe"
$zip = Join-Path $dst "dotnet-sdk-10.0.404-win-x64.zip"

if (-not (Test-Path $dotnet)) {
    if (-not (Test-Path $zip) -or (Get-Item $zip).Length -lt 200MB) {
        Write-Output "downloading .NET 10 SDK zip from the Mac ..."
        $wc = New-Object Net.WebClient
        $wc.Proxy = $null
        $wc.DownloadFile("$base/dotnet-sdk-10.0.404-win-x64.zip", $zip)
        Write-Output ("downloaded " + [int]((Get-Item $zip).Length / 1MB) + " MB")
    }
    Write-Output "extracting SDK to $root ..."
    Expand-Archive -Path $zip -DestinationPath $root -Force
}

if (Test-Path $dotnet) {
    Write-Output "---- dotnet --list-sdks ----"
    (& $dotnet --list-sdks) -join "`n" | Write-Output
    Write-Output "DOTNET=$dotnet"
    Write-Output "RESULT: SDK_OK"
} else {
    Write-Output "RESULT: SDK_MISSING"
}
'''

BUILD = r'''
$ErrorActionPreference = "Continue"
$base = "http://192.168.0.15:8080"
$setup = "D:\dvplayer\setup"
New-Item -ItemType Directory -Force -Path $setup | Out-Null
$zip = Join-Path $setup "dvplayer-a5.zip"

$wc = New-Object Net.WebClient
$wc.Proxy = $null
$wc.DownloadFile("$base/dvplayer-a5.zip", $zip)
Write-Output ("downloaded a5 zip " + [int]((Get-Item $zip).Length / 1KB) + " KB")

Expand-Archive -Path $zip -DestinationPath "D:\dvplayer" -Force
Write-Output "unzipped to D:\dvplayer\apps\windows"

$proj = "D:\dvplayer\apps\windows\DvPlayer.Windows\DvPlayer.Windows.csproj"
$dotnet = "D:\dvplayer\dotnet\dotnet.exe"
& $dotnet build $proj -c Release --nologo 2>&1 | Select-Object -Last 30 | ForEach-Object { "$_" }
$code = $LASTEXITCODE
Write-Output ("BUILD_EXIT=" + $code)
if ($code -eq 0) { Write-Output "RESULT: BUILD_OK" } else { Write-Output "RESULT: BUILD_FAIL" }
'''

RUN = r'''
$ErrorActionPreference = "Continue"
$exe = "D:\dvplayer\apps\windows\DvPlayer.Windows\bin\Release\net10.0-windows\DvPlayer.Windows.exe"
if (-not (Test-Path $exe)) {
    Write-Output "RESULT: NO_EXE"
    return
}

# 用的是解压版 SDK，apphost 靠 DOTNET_ROOT 找 WindowsDesktop 运行时
$env:DOTNET_ROOT = "D:\dvplayer\dotnet"
$proc = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 22

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size)
$shot = Join-Path $env:TEMP "a5-shot.png"
$bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()
Write-Output (Send-File $shot "a5-shot.png")

$log = Join-Path $env:LOCALAPPDATA "dvplayer\mpv.log"
if (Test-Path $log) {
    Write-Output "---- mpv.log (filtered) ----"
    Get-Content $log | Select-String -Pattern "Dolby Vision|el_pair|VO: \[|error|fail" |
        Select-Object -First 15 | ForEach-Object { $_.Line }
    Send-File $log "a5-mpv.log" | Out-Null
} else {
    Write-Output "no mpv.log yet"
}

Write-Output ("process_alive=" + (-not $proc.HasExited))
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Write-Output "RESULT: RUN_DONE"
'''


def log(msg):
    line = "[%s] %s" % (time.strftime("%H:%M:%S"), msg)
    print(line, flush=True)
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def call(code, timeout):
    task_id = dvagent.submit(code)
    return dvagent.wait(task_id, timeout)


def show(result):
    if result is None:
        log("没有回音（代理没在跑？）")
        return ""
    out = (result.get("out") or "").rstrip()
    log("task done exit=%s ms=%s" % (result.get("exit"), result.get("ms")))
    for line in out.splitlines():
        log("  " + line)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wait", type=int, default=1800, help="等代理上线的秒数")
    args = ap.parse_args()

    dvagent.ensure()
    log("等待 Windows 代理上线 ...")

    deadline = time.time() + args.wait
    host = None
    while time.time() < deadline:
        out = show(call(PROBE, 6))
        if "DVAGENT" in out:
            host = out.strip().splitlines()[-1]
            break
        time.sleep(4)

    if not host:
        log("等不到代理。请在 Windows 上双击 agent.bat（管理员会弹 UAC）。")
        return 1

    log("代理在线：%s" % host)

    log("== 1/3 安装 .NET 10 SDK ==")
    out = show(call(SDK, 900))
    if "SDK_OK" not in out:
        log("SDK 没装好，停在这里。")
        return 2

    log("== 2/3 解包并编译 ==")
    out = show(call(BUILD, 900))
    if "BUILD_OK" not in out:
        log("编译失败，看上面的错误。")
        return 3

    log("== 3/3 运行并抓屏 ==")
    show(call(RUN, 300))

    log("截图/日志已上传到 build/agent/uploads/")
    log("DONE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
