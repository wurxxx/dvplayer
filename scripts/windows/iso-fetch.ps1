# Download (or resume) the Blu-ray ISO from the NAS via psftp's reget, so an
# interrupted transfer continues where it stopped instead of starting over.
# Runs under schtasks because processes started from an SSH session get reaped.
# Credentials come from a base64 file that is deleted at the end.
# Pure ASCII.

param(
    [int64]$TargetBytes = 35972448256
)

$ErrorActionPreference = "Continue"

$credFile = "D:\dvplayer\setup\nas-creds.b64"
$log = "D:\dvplayer\out\iso-fetch.log"
$psftp = "D:\dvplayer\setup\psftp.exe"
$hostKey = "SHA256:k2Fvw8LMdvdGQji+oEW/9TJyXf4HiT2K6zrZUEdQ6qw"
$local = "D:\dvplayer\iso\hush2in1.iso"
$remote = "hush2in1.iso"

"# iso-fetch $(Get-Date -Format o)" | Set-Content $log
function Log($m) { Write-Host $m; $m | Add-Content $log }

if (-not (Test-Path $credFile)) { Log "missing creds"; exit 2 }
if (-not (Test-Path $psftp)) { Log "missing psftp"; exit 2 }

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

# psftp batch script: reget resumes a partial download.
# cd first: psftp lands in the login home dir, the ISO lives under /vol1/1000.
$script = "D:\dvplayer\setup\iso-fetch.psftp"
@(
    "cd /vol1/1000",
    "reget $remote $local",
    "bye"
) | Set-Content -Encoding ASCII $script

$xfer = "D:\dvplayer\out\iso-fetch-psftp.log"
Log "resume $remote -> $local"
$sw = [Diagnostics.Stopwatch]::StartNew()
& $psftp -batch -pw $pass -hostkey $hostKey -P 22 "${user}@10.0.0.100" -b $script 2>&1 |
    ForEach-Object { $_.ToString() } | Out-File -Encoding UTF8 $xfer
$code = $LASTEXITCODE
Log "exit=$code elapsed=$([int]$sw.Elapsed.TotalSeconds)s"
Log "--- psftp tail ---"
Get-Content $xfer -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { Log $_ }

if (Test-Path $local) {
    $n = (Get-Item $local).Length
    Log ("final {0} bytes ({1:N1}%)" -f $n, ($n * 100.0 / $TargetBytes))
    if ($n -ge $TargetBytes) { Log "download complete" } else { Log "still partial" }
}

Remove-Item $script -Force -ErrorAction SilentlyContinue
Remove-Item $credFile -Force -ErrorAction SilentlyContinue
Log "done"
