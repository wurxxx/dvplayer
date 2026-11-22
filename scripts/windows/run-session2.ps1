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

# 每次用不同的任务名：上一次被强杀 / 卡在 Queued 的同名任务实例会挡住新实例。
$name = "dvplayer-session2-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
$processName = [System.IO.Path]::GetFileNameWithoutExtension($Exe)

Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

$action = New-ScheduledTaskAction -Execute $Exe -Argument $Arguments -WorkingDirectory $WorkingDirectory
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
# 笔记本用电池时计划任务默认不启动（状态会一直 Queued）；超时限制跟着参数走。
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Seconds ($TimeoutSeconds + 120))
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal `
    -Settings $settings -Force | Out-Null

try {
    # 用户可能自己开着一个 DvPlayer：只认本次任务新起的那个，别把旧的当成本次进程，
    # 也别在超时时把旧的强杀。
    $before = @(Get-Process -Name $processName -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Id)

    Start-ScheduledTask -TaskName $name

    # 等进程真的起来（计划任务启动有延迟）。
    $started = $null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        $started = Get-Process -Name $processName -ErrorAction SilentlyContinue |
                   Where-Object { $before -notcontains $_.Id } |
                   Select-Object -First 1
        if ($started) { break }
    }
    if (-not $started) { throw "进程没有起来（$processName）" }

    $startedId = $started.Id
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Process -Id $startedId -ErrorAction SilentlyContinue) -and
           (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }

    if (Get-Process -Id $startedId -ErrorAction SilentlyContinue) {
        Write-Host "超时，强制结束 $processName (pid=$startedId)"
        Stop-Process -Id $startedId -Force
    }

    Start-Sleep -Milliseconds 800
    $info = Get-ScheduledTaskInfo -TaskName $name
    Write-Host ("LastTaskResult = {0}" -f $info.LastTaskResult)
}
finally {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}
