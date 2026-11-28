#!/usr/bin/env bash
# 真机验证 NFS（A9）：列目录 + 经 VfsHttpBridge 起播。
#
# 先在 Mac 上建导出（需要 sudo，见 nfs-export.sh），并把样片放进导出目录：
#   tests/android/nfs-export.sh create
#   cp samples/p5.mkv /Volumes/data/tmp/dvplayer-nfs/
#
# 然后：
#   NFS_URL=nfs://<mac-ip>/Volumes/data/tmp/dvplayer-nfs \
#   NFS_PLAY=nfs://<mac-ip>/Volumes/data/tmp/dvplayer-nfs/p5.mkv \
#   tests/android/verify-nfs.sh
#
# 没给 NFS_PLAY 就只列目录。
set -u

cd "$(dirname "$0")/../.." || exit 1
if [ -n "${ADB:-}" ]; then read -r -a ADB_CMD <<< "$ADB"; else ADB_CMD=(adb -d); fi
PKG=com.dvplayer.app
ACT=$PKG/.PlayerTestActivity
APK=apps/android/app-phone/build/outputs/apk/debug/app-phone-debug.apk
URL="${NFS_URL:?需要 NFS_URL，例如 nfs://10.0.0.5/Volumes/data/tmp/dvplayer-nfs}"
PLAY="${NFS_PLAY:-}"
URL="${URL// /%20}"
PLAY="${PLAY// /%20}"

"${ADB_CMD[@]}" install -r "$APK" >/dev/null 2>&1 || { echo "APK 安装失败"; exit 1; }
"${ADB_CMD[@]}" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
"${ADB_CMD[@]}" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
"${ADB_CMD[@]}" shell wm dismiss-keyguard >/dev/null 2>&1 || true
"${ADB_CMD[@]}" shell svc power stayon true >/dev/null 2>&1 || true

run() { # sleep秒数 日志 参数...
    local wait=$1 log=$2
    shift 2
    "${ADB_CMD[@]}" shell am force-stop "$PKG"
    "${ADB_CMD[@]}" logcat -c
    "${ADB_CMD[@]}" logcat -v time -s DvPlayerTest:I DvNfs:I DvBridge:I AndroidRuntime:E >"$log" 2>&1 &
    local pid=$!
    sleep 1
    "${ADB_CMD[@]}" shell am start -W -n "$ACT" --activity-clear-task "$@" >/dev/null 2>&1
    sleep "$wait"
    kill "$pid" 2>/dev/null || true
}

echo "== 1. 列目录（深度 1）=="
run 10 /tmp/dv-nfs-list.log --es nfs "$URL" --es nfs_deep 1
sed 's/^.*): //' /tmp/dv-nfs-list.log |
    grep -E 'NFS\|L[01]\||list .* -> [0-9]+ 项|NFS 列表失败|NFS 导出点' | head -12

if ! sed 's/^.*): //' /tmp/dv-nfs-list.log | grep -qE 'NFS\|L0\|[0-9]+'; then
    echo "✗ 没列出目录"
    sed 's/^.*): //' /tmp/dv-nfs-list.log | tail -15
    exit 1
fi

if [ -z "$PLAY" ]; then
    echo "✓ 列表通过（没给 NFS_PLAY，跳过播放）"
    exit 0
fi

echo "== 2. 经桥接起播 =="
run 12 /tmp/dv-nfs-play.log --es nfs_play "$PLAY"
sed 's/^.*): //' /tmp/dv-nfs-play.log |
    grep -E 'NFS 桥接|NFS 片源|桥接启动|state mpv|播放内核|NFS 桥接失败' | head -10

echo "== 3. 结果 =="
if sed 's/^.*): //' /tmp/dv-nfs-play.log | grep -qE 'state mpv pos=[1-9][0-9]*ms'; then
    echo "✓ 桥接起播成功（position 在走）"
else
    echo "✗ 没看到播放进度"
    sed 's/^.*): //' /tmp/dv-nfs-play.log | tail -20
    exit 1
fi
