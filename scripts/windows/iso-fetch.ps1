# Download (or resume) the Blu-ray ISO from the NAS via OpenSSH sftp's reget,
# so an interrupted transfer continues where it stopped instead of starting over.
# Runs under schtasks because processes started from an SSH session get reaped.
# Credentials come from a base64 file that is deleted at the end.
#
# The password is handed to sftp via SSH_ASKPASS, never on the command line:
# psftp's `-pw` was readable by any local user through Win32_Process.
# Requires the Windows OpenSSH client (sftp / ssh-keyscan / ssh-keygen).
# Pure ASCII.

param(
    [int64]$TargetBytes = 35972448256
)

$ErrorActionPreference = "Continue"

$credFile = "D:\dvplayer\setup\nas-creds.b64"
$log = "D:\dvplayer\out\iso-fetch.log"
$sshDir = "C:\Program Files\OpenSSH"
$hostKey = "SHA256:k2Fvw8LMdvdGQji+oEW/9TJyXf4HiT2K6zrZUEdQ6qw"
$local = "D:\dvplayer\iso\hush2in1.iso"
$remote = "hush2in1.iso"

"# iso-fetch $(Get-Date -Format o)" | Set-Content $log
function Log($m) { Write-Host $m; $m | Add-Content $log }

if (-not (Test-Path $credFile)) { Log "missing creds"; exit 2 }
if (-not (Test-Path (Join-Path $sshDir "sftp.exe"))) { Log "missing OpenSSH sftp"; exit 2 }

$lines = Get-Content $credFile
function Dec([string]$b64) {
    if ([string]::IsNullOrWhiteSpace($b64)) { return "" }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64.Trim()))
}

$user = Dec $lines[0]
$pass = Dec $lines[1]

New-Item -ItemType Directory -Force "D:\dvplayer\iso" | Out-Null

$have = 0
if (Test-Path $local) { $have = (Get-Item $local).Length }
Log ("local have {0} bytes of {1} ({2:N1}%)" -f $have, $TargetBytes, ($have * 100.0 / $TargetBytes))

if ($have -ge $TargetBytes) {
    Log "already complete"
    Remove-Item $credFile -Force -ErrorAction SilentlyContinue
    exit 0
}

# sftp batch script: reget resumes a partial download.
# cd first: sftp lands in the login home dir, the ISO lives under /vol1/1000.
$script = "D:\dvplayer\setup\iso-fetch.sftp"
@(
    "cd /vol1/1000",
    "reget $remote $local",
    "bye"
) | Set-Content -Encoding ASCII $script

# Pin the NAS host key: scan once, use the result only if the fingerprint matches.
# (psftp took -hostkey directly; OpenSSH needs a known_hosts file.)
$known = "D:\dvplayer\setup\known_hosts"
$keyscan = Join-Path $sshDir "ssh-keyscan.exe"
$keygen = Join-Path $sshDir "ssh-keygen.exe"
$scan = & $keyscan -T 10 10.0.0.100 2>$null
if (-not $scan) {
    Log "ssh-keyscan failed"
    Remove-Item $credFile -Force -ErrorAction SilentlyContinue
    exit 3
}

$scan | Set-Content -Encoding ASCII $known
$fps = (& $keygen -lf $known 2>$null) -join "`n"
if ($fps -notlike "*$hostKey*") {
    Log "host key mismatch"
    Remove-Item $known -Force -ErrorAction SilentlyContinue
    Remove-Item $credFile -Force -ErrorAction SilentlyContinue
    exit 3
}

# Hand the password to sftp through an askpass helper: it never appears in argv
# or in the environment, so other local users cannot read it from Win32_Process.
$askpass = "D:\dvplayer\setup\askpass.cmd"
@("@echo off", "echo $pass") | Set-Content -Encoding ASCII $askpass
$env:SSH_ASKPASS = $askpass
$env:SSH_ASKPASS_REQUIRE = "force"

$xfer = "D:\dvplayer\out\iso-fetch-sftp.log"
Log "resume $remote -> $local"
$sw = [Diagnostics.Stopwatch]::StartNew()
& (Join-Path $sshDir "sftp.exe") -b $script -P 22 `
    -o "UserKnownHostsFile=$known" -o "StrictHostKeyChecking=yes" `
    "${user}@10.0.0.100" 2>&1 |
    ForEach-Object { $_.ToString() } | Out-File -Encoding UTF8 $xfer
$code = $LASTEXITCODE
Log "exit=$code elapsed=$([int]$sw.Elapsed.TotalSeconds)s"
Log "--- sftp tail ---"
Get-Content $xfer -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { Log $_ }

Remove-Item $askpass -Force -ErrorAction SilentlyContinue
Remove-Item $known -Force -ErrorAction SilentlyContinue

if (Test-Path $local) {
    $n = (Get-Item $local).Length
    Log ("final {0} bytes ({1:N1}%)" -f $n, ($n * 100.0 / $TargetBytes))
    if ($n -ge $TargetBytes) { Log "download complete" } else { Log "still partial" }
}

Remove-Item $script -Force -ErrorAction SilentlyContinue
Remove-Item $credFile -Force -ErrorAction SilentlyContinue
Log "done"
