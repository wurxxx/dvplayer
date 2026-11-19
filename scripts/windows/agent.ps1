# dvplayer Windows 代理
#
# 双击 agent.bat 即可，不需要管理员（装 SDK 走解压版，不写系统目录）。
# 需要管理员时任务里调 Start-ElevatedAgent 再弹一次 UAC。
#
# 它循环向 Mac 上的控制服务要任务：
#   GET  http://192.168.0.15:8080/agent/task?token=...
#   POST http://192.168.0.15:8080/agent/result?token=...
#   POST http://192.168.0.15:8080/agent/upload?token=...&name=...
#
# 任务是一段 base64 的 PowerShell，在本进程里执行，所以可以用到下面定义的
# Send-File 函数把自己的日志/截图传回去。
# 只有在同一局域网 + 知道 token 的人才能下发任务，别把这个窗口发给别人。

$ErrorActionPreference = "Continue"
$server = "http://192.168.0.15:8080"
$token  = "dvplayer-lan-7c1f19"

# --- 权限 ---
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Start-ElevatedAgent {
    # 需要管理员时才用：新增一个装了 UAC 的代理窗口，这个窗口继续跑。
    Start-Process powershell -Verb RunAs -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`""
    )
    return "elevation requested - approve the UAC prompt"
}

$me = "$env:COMPUTERNAME\$env:USERNAME"

function New-Client {
    $wc = New-Object System.Net.WebClient
    $wc.Proxy = $null
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers.Add("Content-Type", "text/plain; charset=utf-8")
    return $wc
}

function Send-Text([string]$Path, [string]$Text) {
    try {
        $wc = New-Client
        $wc.UploadString("$server$Path?token=$token", "POST", $Text) | Out-Null
    } catch { }
}

function Send-File([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return "missing: $Path"
    }
    try {
        $wc = New-Client
        $url = "$server/agent/upload?token=$token&name=" + [Uri]::EscapeDataString($Name)
        $wc.UploadFile($url, $Path) | Out-Null
        return "uploaded $Name ($((Get-Item -LiteralPath $Path).Length) bytes)"
    } catch {
        return "upload failed: $($_.Exception.Message)"
    }
}

$host.ui.RawUI.WindowTitle = "dvplayer agent - $me"
Write-Host "dvplayer agent up as $me (admin=$isAdmin)"
Write-Host "server: $server"
Write-Host "keep this window open; minimize it if it is in the way."
Write-Host ""

Send-Text "/agent/hello" (@{ host = $me; when = (Get-Date -Format o) } | ConvertTo-Json -Compress)

$lastId = 0
$idle = 0

while ($true) {
    try {
        $wc = New-Client
        $raw = $wc.DownloadString("$server/agent/task?token=$token")
        $task = $null
        if ($raw) { $task = $raw | ConvertFrom-Json }

        if ($task -and [int]$task.id -gt $lastId) {
            $lastId = [int]$task.id
            $idle = 0
            Write-Host ("[{0}] task #{1}" -f (Get-Date -Format HH:mm:ss), $lastId)

            $script = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($task.ps))
            $tmp = Join-Path $env:TEMP ("dvtask-{0}.ps1" -f $lastId)
            [IO.File]::WriteAllText($tmp, $script, (New-Object Text.UTF8Encoding($false)))

            $started = Get-Date
            $out = ""
            try {
                $out = (& $tmp) 2>&1 | Out-String
            } catch {
                $out = "EXCEPTION: " + $_.Exception.ToString()
            }
            $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
            $code = $LASTEXITCODE

            if ([string]::IsNullOrWhiteSpace($out)) { $out = "(no output)" }
            $body = @{
                id   = $lastId
                host = $me
                exit = $code
                ms   = $elapsed
                out  = $out
            } | ConvertTo-Json -Compress -Depth 4
            Send-Text "/agent/result" $body
            Write-Host ("    done in {0} ms, sent back" -f $elapsed)
        } else {
            $idle++
            if ($idle % 60 -eq 0) { Write-Host ("[{0}] idle" -f (Get-Date -Format HH:mm:ss)) }
        }
    } catch {
        Start-Sleep -Milliseconds 1500
        continue
    }

    Start-Sleep -Milliseconds 700
}
