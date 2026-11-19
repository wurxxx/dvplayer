# 在交互式会话（Session 2）里跑一个程序并等它结束。
#
# 为什么需要：D3D11 的 swapchain 只在已登录的桌面会话里可用。从 SSH 进来的
# 进程属于 Session 0，直接 Start-Process 起 mpv 会报
#   Failed to create swapchain: 0x887A0022
# 用「交互式主体」的计划任务启动，进程就落在 Session 2，能正常出画面。
#
#   .\run-session2.ps1 -Exe D:\dvplayer\apps\windows\DvPlayer\bin\Release\net10.0-windows\DvPlayer.exe -Arguments "--play xxx --play-seconds 20"
#
# 退出码放在 LastTaskResult 里（0 = 正常结束）。

param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Arguments = "",
    [string]$WorkingDirectory = "",
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Exe)) { throw "找不到程序：$Exe" }
if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path -Parent $Exe }

$name = "dvplayer-session2"
$processName = [System.IO.Path]::GetFileNameWithoutExtension($Exe)

Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

$action = New-ScheduledTaskAction -Execute $Exe -Argument $Arguments -WorkingDirectory $WorkingDirectory
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force | Out-Null

try {
    Start-ScheduledTask -TaskName $name

    # 等进程真的起来（计划任务启动有延迟）。
    $appeared = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Get-Process -Name $processName -ErrorAction SilentlyContinue) { $appeared = $true; break }
    }
    if (-not $appeared) { throw "进程没有起来（$processName）" }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Process -Name $processName -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }

    if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
        Write-Host "超时，强制结束 $processName"
        Stop-Process -Name $processName -Force
    }

    Start-Sleep -Milliseconds 800
    $info = Get-ScheduledTaskInfo -TaskName $name
    Write-Host ("LastTaskResult = {0}" -f $info.LastTaskResult)
}
finally {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}
