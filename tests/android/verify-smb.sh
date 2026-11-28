#!/usr/bin/env bash
# A9 真机 SMB 验证：列目录 → 挑最大的视频 → 经 127.0.0.1 桥接起播并 seek。
#
# 凭据从环境变量读，不落盘：
#   SMB_HOST  默认 10.0.0.134
#   SMB_SHARE 共享名（必填）
#   SMB_USER  用户名（必填）
#   SMB_PASS  密码（必填）
#   SMB_PATH  共享内子目录（可选，留空=共享根）
#   SMB_DOMAIN 域/工作组（可选）
#   SMB_DEEP  列表递归层数，默认 2
#   SMB_PICK  指定要播的相对路径（可选；留空自动挑最大的视频）
#   SMB_ENGINE 播放内核，默认 mpv（media3 用来验证桥接的 Range 兼容性）
set -u

cd "$(dirname "$0")/../.." || exit 1
OC="${TMPDIR:-/tmp}/dv-smb"
mkdir -p "$OC"
LIST_LOG="$OC/dv-smb-list.log"
PLAY_LOG="$OC/dv-smb-play.log"
APK=apps/android/app-phone/build/outputs/apk/debug/app-phone-debug.apk
PKG=com.dvplayer.app
ACT=$PKG/.PlayerTestActivity
HOST="${SMB_HOST:-10.0.0.134}"
SHARE="${SMB_SHARE%/}"
BASE="smb://$HOST/$SHARE"
if [ -n "${SMB_PATH:-}" ]; then
  BASE="$BASE/${SMB_PATH#/}"
fi
DEEP="${SMB_DEEP:-2}"
# adb shell 对空格参数转义不可靠（空格之后的内容会被截断），先把空格编码；
# 客户端 parse() 会用 Uri.decode 还原。
ENC_BASE="${BASE// /%20}"
EXTRA=(--es smb_user "$SMB_USER" --es smb_pass "$SMB_PASS")
# 空值的 --es 会被 adb 吃掉，am 会报 "Argument expected after smb_domain"。
if [ -n "${SMB_DOMAIN:-}" ]; then EXTRA+=(--es smb_domain "$SMB_DOMAIN"); fi

adb install -r "$APK" >/dev/null 2>&1 || { echo "APK 安装失败"; exit 1; }
adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
adb shell svc power stayon true >/dev/null 2>&1 || true
adb shell am force-stop "$PKG"
# 首次安装会弹通知权限框，挡住 am start 的冷启动；测试页用不到通知，直接授了省事。
adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true

if [ -n "${SMB_PICK:-}" ]; then
  PICK="$BASE/${SMB_PICK#/}"
  echo "== 跳过列表，直接播 ${PICK} =="
else
  adb logcat -c
  adb logcat -v time -s DvPlayerTest:I DvSmb:I DvBridge:I DvMedia3:I AndroidRuntime:E >"$LIST_LOG" 2>&1 &
  BPID=$!
  sleep 2

  echo "== 列表 ${BASE}（深度 ${DEEP}）=="
  adb shell am start -W -n "$ACT" --activity-clear-task \
    "${EXTRA[@]}" --es smb_deep "$DEEP" --es smb "$ENC_BASE/" >>"$LIST_LOG" 2>&1
  sleep 12
  if ! grep -q 'DvPlayerTest' "$LIST_LOG"; then
    echo "（首次启动没起来，重试一次）"
    adb shell am start -W -n "$ACT" --activity-clear-task \
      "${EXTRA[@]}" --es smb_deep "$DEEP" --es smb "$ENC_BASE/" >>"$LIST_LOG" 2>&1
    sleep 12
  fi
  grep -E 'SMB\|' "$LIST_LOG" | sed 's/^.*): //' | head -40
  echo "== 列表错误 =="
  grep -E 'SMB 列表失败|SMB 子目录失败|AndroidRuntime|DvSmb' "$LIST_LOG" | sed 's/^.*): //' | tail -10
  kill "$BPID" 2>/dev/null || true

  PICK=$(grep -E 'SMB\|F\|[0-9]+\|smb://' "$LIST_LOG" \
    | grep -Ei '\.(mkv|mp4|m2ts|ts|iso)$' \
    | sed 's/^.*|\([0-9]*\)|\(smb:\/\/.*\)$/\1|\2/' \
    | sort -rn | head -1 | cut -d'|' -f2-)
fi
if [ -z "${PICK:-}" ]; then
  echo "== 没找到视频文件，停在列表这一步（可用 SMB_PICK 指定）=="
  exit 0
fi

echo "== 播放 ${PICK}（seek 15s）=="
adb shell am force-stop "$PKG"
adb logcat -c
adb logcat -v time -s DvPlayerTest:I DvSmb:I DvBridge:I DvMedia3:I AndroidRuntime:E >"$PLAY_LOG" 2>&1 &
BPID2=$!
sleep 2
adb shell am start -W -n "$ACT" --activity-clear-task \
  "${EXTRA[@]}" --es engine "${SMB_ENGINE:-mpv}" --el seek_to 15000 --es smb_play "${PICK// /%20}" >>"$PLAY_LOG" 2>&1
sleep "${SMB_SECONDS:-22}"
grep -E 'SMB 桥接|桥接启动|内核|state |first frame|video format|pos |错误|AndroidRuntime|Exception' "$PLAY_LOG" \
  | sed 's/^.*): //' | head -50
kill "$BPID2" 2>/dev/null || true
