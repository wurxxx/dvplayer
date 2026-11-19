# Verify Blu-ray ISO playback through libbluray for several targets.
# Runs iso-play.ps1 once per target so each gets its own log.
# Pure ASCII.

param(
    [Parameter(Mandatory = $true)][string]$Iso,
    [int]$Frames = 200
)

$ErrorActionPreference = "Continue"
$here = "D:\dvplayer\setup"
$out = "D:\dvplayer\out\iso-verify.log"
"# iso-verify $Iso $(Get-Date -Format o)" | Set-Content $out
function Log($m) { Write-Host $m; $m | Add-Content $out }

$targets = @(
    @{ name = "mpls1";  url = "bd://mpls/1" },
    @{ name = "mpls2";  url = "bd://mpls/2" },
    @{ name = "ed2";    url = "bd://";  extra = "--edition=1" }
)

foreach ($t in $targets) {
    Log ""
    Log "================ $($t.name): $($t.url) ================"
    if ($t.extra) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$here\iso-play.ps1" `
            -Iso $Iso -Target $t.url -Frames $Frames -Tag $t.name -Extra $t.extra
    } else {
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$here\iso-play.ps1" `
            -Iso $Iso -Target $t.url -Frames $Frames -Tag $t.name
    }
    Log "returned from $($t.name) exit=$LASTEXITCODE"
}

Log ""
Log "--- summary files ---"
Get-ChildItem "D:\dvplayer\out\iso-play-*.log" | ForEach-Object {
    Log ("{0}  {1} bytes" -f $_.Name, $_.Length)
}
