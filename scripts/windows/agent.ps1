# dvplayer Windows agent
#
# Double-click agent.bat. No admin needed (the SDK is unzipped, nothing goes to system dirs).
# When a task needs admin it calls Start-ElevatedAgent for another UAC prompt.
#
# It polls the control service on the Mac for tasks:
#   GET  http://192.168.0.15:8080/agent/task?token=...
#   POST http://192.168.0.15:8080/agent/result?token=...
#   POST http://192.168.0.15:8080/agent/upload?token=...&name=...
#
# A task is a base64 PowerShell script run in this process, so it can use the
# Send-File function below to send logs and screenshots back.
# Only someone on the same LAN with the token can submit tasks. Do not share this window.

$ErrorActionPreference = "Continue"
$server = "http://192.168.0.15:8080"
$token  = "dvplayer-lan-7c1f19"

# --- elevation ---
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Start-ElevatedAgent {
    # Only when admin is required: spawn another agent window behind UAC; this one keeps running.
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
