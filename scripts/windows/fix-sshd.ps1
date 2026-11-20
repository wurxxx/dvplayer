# Register and start the OpenSSH Server service. Must run elevated.
# Writes a short result log to %TEMP%\fix-sshd.log.

$ErrorActionPreference = "Stop"
$log = Join-Path $env:TEMP "fix-sshd.log"
$out = @()

try {
    $exe = "C:\Program Files\OpenSSH\sshd.exe"
    if (-not (Test-Path $exe)) {
        $exe = "C:\Windows\System32\OpenSSH\sshd.exe"
    }
    $out += "exe=$exe"

    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $svc) {
        New-Service -Name sshd -BinaryPathName ('"' + $exe + '"') `
            -DisplayName "OpenSSH SSH Server" -StartupType Automatic `
            -Description "OpenSSH Server" | Out-Null
        $out += "service=created"
    } else {
        $out += "service=existed"
    }

    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd
    Start-Sleep -Seconds 2

    $out += "status=" + (Get-Service sshd).Status

    $rule = netsh advfirewall firewall show rule name="OpenSSH SSH Server" 2>&1
    if ($rule -match "OpenSSH SSH Server") {
        $out += "firewall=exists"
    } else {
        netsh advfirewall firewall add rule name="OpenSSH SSH Server" dir=in action=allow protocol=TCP localport=22 | Out-Null
        $out += "firewall=added"
    }

    $listen = netstat -ano | Select-String ":22 " | ForEach-Object { $_.Line.Trim() }
    $out += "listen=" + ($listen -join " || ")
} catch {
    $out += "ERROR: " + $_.Exception.Message
}

$out | Set-Content -Path $log -Encoding UTF8