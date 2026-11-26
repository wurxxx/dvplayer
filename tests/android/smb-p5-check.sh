#!/usr/bin/env bash
# SMB 上的 DV P5：经 VFS 探测 → 自动软解，确认颜色与流畅度。
set -u
cd /Volumes/data/dev/workspace/dvplayer || exit 1
PKG=com.dvplayer.app
ACT=$PKG/.PlayerTestActivity
URL='smb://10.0.0.134/%E5%BD%B1%E8%A7%86/Lovesick.2026.S01.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.H.265-DepWeb/Lovesick.2026.S01E01.Two.Weddings.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.H.265-DepWeb.mkv'
LOG=${TMPDIR:-/tmp}/smb-p5.log
rm -f "$LOG"
adb shell am force-stop "$PKG"
adb logcat -c
adb logcat -v time -s DvPlayerTest:I DvMpv:I DvDovi:I DvSmb:I DvBridge:I AndroidRuntime:E >"$LOG" 2>&1 &
BPID=$!
sleep 1
adb shell am start -W -n "$ACT" --activity-clear-task \
  --es smb_user wurxx --es smb_pass "$SMB_PASS" \
  --es smb_play "$URL" --el seek_to 120000 >/dev/null 2>&1
sleep 20
adb exec-out screencap -p >"${TMPDIR:-/tmp}/smb-p5.png"
kill $BPID 2>/dev/null
sed 's/^.*): //' "$LOG" | grep -E "DV|切软解|file loaded|state|色彩空间|Exception" | tail -12
