# Mount a Blu-ray ISO and enumerate its playlists (the "select a title" data).
# Parses BDMV/PLAYLIST/*.mpls directly: no libbluray needed for listing.
#
# MPLS is BIG-ENDIAN. PlayItem layout (BD-ROM spec):
#   +0  length 16
#   +2  clip name 5
#   +7  codec id 4
#   +11 reserved(11)+is_multi_angle(1)+connection_condition(4) = 2 bytes
#   +13 if is_multi_angle: number_of_angles(8)+reserved(24) = 4 bytes
#   then STC_sequence_id 8
#   then IN_time 32   (45 kHz)   -> +14 normally, +18 when multi-angle
#   then OUT_time 32  (45 kHz)
# Pure ASCII.

param(
    [Parameter(Mandatory = $true)][string]$Iso
)

$ErrorActionPreference = "Continue"
$out = "D:\dvplayer\out\iso-titles.log"
"# iso-titles $Iso $(Get-Date -Format o)" | Set-Content $out
function Log($m) { Write-Host $m; $m | Add-Content $out }

if (-not (Test-Path $Iso)) { Log "missing $Iso"; exit 2 }

function BE16([byte[]]$b, [int]$o) {
    return ([int]$b[$o] -shl 8) -bor [int]$b[$o + 1]
}
function BE32([byte[]]$b, [int]$o) {
    return ([int64]$b[$o] -shl 24) -bor ([int64]$b[$o + 1] -shl 16) -bor ([int64]$b[$o + 2] -shl 8) -bor [int64]$b[$o + 3]
}

$img = Mount-DiskImage -ImagePath $Iso -PassThru -ErrorAction Stop
Start-Sleep -Seconds 2

try {
    $vol = $img | Get-Volume -ErrorAction Stop
    $drive = "$($vol.DriveLetter):"
    Log "mounted $drive  label=$($vol.FileSystemLabel)"

    $plDir = Join-Path $drive "BDMV\PLAYLIST"
    if (-not (Test-Path $plDir)) {
        Log "no BDMV\PLAYLIST under $drive"
        exit 1
    }

    function Get-PlaylistInfo([string]$path) {
        $b = [IO.File]::ReadAllBytes($path)
        if ($b.Length -lt 24) { return $null }
        if ([Text.Encoding]::ASCII.GetString($b, 0, 4) -ne "MPLS") { return $null }

        $playListStart = BE32 $b 8

        if ($playListStart + 10 -gt $b.Length) { return $null }

        $pos = [int]$playListStart
        $numItems = BE16 $b ($pos + 6)
        $pos += 10

        $ticks = 0L
        $clips = New-Object System.Collections.ArrayList
        $multi = 0
        $ok = $true

        for ($i = 0; $i -lt $numItems; $i++) {
            if ($pos + 12 -gt $b.Length) { $ok = $false; break }
            $itemLen = BE16 $b $pos
            if ($itemLen -lt 20 -or ($pos + $itemLen) -gt $b.Length) { $ok = $false; break }

            $clip = [Text.Encoding]::ASCII.GetString($b, $pos + 2, 5)
            [void]$clips.Add($clip)

            $b0 = $b[$pos + 11]
            $b1 = $b[$pos + 12]
            $isMulti = (($b1 -band 0x10) -ne 0)
            if ($isMulti) { $multi++ }

            $p = $pos + 13
            if ($isMulti) { $p += 4 }   # number_of_angles + reserved
            $p += 1                     # STC_sequence_id
            if ($p + 8 -gt $b.Length) { $ok = $false; break }

            $inTime  = BE32 $b $p
            $outTime = BE32 $b ($p + 4)
            if ($outTime -gt $inTime) { $ticks += ($outTime - $inTime) }

            $pos += $itemLen
        }

        # chapters: PlayListMark segment
        # mark layout: +0 len(2), +2 reserved(1), +3 mark_type(1),
        #              +4 ref_to_PlayItem_id(2), +6 mark_time_stamp(4)
        $markStart = BE32 $b 12
        $chapters = 0
        if ($markStart -gt 0 -and ($markStart + 8) -lt $b.Length) {
            $mpos = [int]$markStart
            $marks = BE16 $b ($mpos + 6)
            $mp = $mpos + 8
            for ($i = 0; $i -lt $marks; $i++) {
                if ($mp + 8 -gt $b.Length) { break }
                $markLen = BE16 $b $mp
                if ($markLen -lt 8) { break }
                $markType = $b[$mp + 3]
                if ($markType -eq 1) { $chapters++ }
                $mp += $markLen
            }
        }

        [pscustomobject]@{
            Name     = [IO.Path]::GetFileName($path)
            Items    = $numItems
            Multi    = $multi
            Parsed   = $ok
            Chapters = $chapters
            Ticks    = $ticks
            Seconds  = [Math]::Round($ticks / 45000.0, 1)
            Clips    = ($clips -join ",")
        }
    }

    $all = Get-ChildItem $plDir -Filter *.mpls | ForEach-Object { Get-PlaylistInfo $_.FullName } |
           Where-Object { $_ -ne $null } | Sort-Object Seconds -Descending

    Log ("{0} playlists, total {1}" -f $all.Count, ([TimeSpan]::FromSeconds(($all | Measure-Object Seconds -Sum).Sum)).ToString("hh\:mm\:ss"))
    Log "--- top 15 by duration ---"
    foreach ($p in ($all | Select-Object -First 15)) {
        Log ("{0}  {1,8:N1}s  items={2,3}  ch={3,2}  {4}  {5}" -f `
            ([TimeSpan]::FromSeconds($p.Seconds)).ToString("hh\:mm\:ss"), $p.Seconds, $p.Items, $p.Chapters, $p.Name, $p.Clips)
    }
    Log "--- main feature candidates (>30 min) ---"
    foreach ($p in ($all | Where-Object { $_.Seconds -gt 1800 })) {
        Log ("{0}  {1,8:N1}s  items={2,3}  ch={3,2}  {4}  {5}" -f `
            ([TimeSpan]::FromSeconds($p.Seconds)).ToString("hh\:mm\:ss"), $p.Seconds, $p.Items, $p.Chapters, $p.Name, $p.Clips)
    }
    Log "--- parse failures ---"
    $bad = @($all | Where-Object { -not $_.Parsed })
    if ($bad.Count -eq 0) { Log "none" } else { $bad | ForEach-Object { Log $_.Name } }
}
finally {
    Dismount-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue | Out-Null
    Log "dismounted"
}
