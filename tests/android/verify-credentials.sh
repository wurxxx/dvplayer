#!/usr/bin/env bash
# 验证 SMB 凭据的加密存储（A9）：
#   1. 第一次显式传 smb_pass 列目录 → 密码落盘必须是密文
#   2. 第二次不传 smb_pass → 仍能连上（从 Keystore 加密存储里取）
#
# 凭据从环境变量读，不落盘：
#   SMB_URL   共享地址，默认 smb://10.0.0.134/影视/
#   SMB_USER  用户名（必填）
#   SMB_PASS  密码（必填）
set -u

cd "$(dirname "$0")/../.." || exit 1
if [ -n "${ADB:-}" ]; then read -r -a ADB_CMD <<< "$ADB"; else ADB_CMD=(adb -d); fi
PKG=com.dvplayer.app
ACT=$PKG/.PlayerTestActivity
APK=apps/android/app-phone/build/outputs/apk/debug/app-phone-debug.apk
URL="${SMB_URL:-smb://10.0.0.134/影视/}"
URL="${URL// /%20}"
USER_NAME="${SMB_USER:?需要 SMB_USER}"
PASS="${SMB_PASS:?需要 SMB_PASS}"
# adb shell 会再过一次 sh，密码里的特殊字符会被吃掉；用 Base64 传。
PASS_B64=$(printf %s "$PASS" | base64 | tr -d "\n")
PREFS="${TMPDIR:-/tmp}/dv-cred-prefs.xml"

"${ADB_CMD[@]}" install -r "$APK" >/dev/null 2>&1 || { echo "APK 安装失败"; exit 1; }
"${ADB_CMD[@]}" shell pm clear "$PKG" >/dev/null 2>&1
"${ADB_CMD[@]}" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
"${ADB_CMD[@]}" shell svc power stayon true >/dev/null 2>&1 || true

list() { # log 额外参数...
    local log=$1
    shift
    "${ADB_CMD[@]}" shell am force-stop "$PKG"
    "${ADB_CMD[@]}" logcat -c
    "${ADB_CMD[@]}" logcat -v time -s DvPlayerTest:I DvSmb:I AndroidRuntime:E >"$log" 2>&1 &
    local pid=$!
    sleep 1
    "${ADB_CMD[@]}" shell am start -W -n "$ACT" --activity-clear-task --es smb_deep 1 "$@" >/dev/null 2>&1
    sleep 8
    kill "$pid" 2>/dev/null || true
    sed 's/^.*): //' "$log" | grep -E 'list .*-> [0-9]+ 项|SMB 列表失败|凭据' | head -4
}

echo "本地密码长度=${#PASS}，Base64 长度=${#PASS_B64}"
echo "== 1. 带密码列目录（应保存密文凭据）=="
list /tmp/dv-cred-1.log --es smb_user "$USER_NAME" --es smb_pass_b64 "$PASS_B64" --es smb "$URL"

echo "== 2. 检查落盘内容 =="
"${ADB_CMD[@]}" shell run-as "$PKG" cat shared_prefs/dvplayer_credentials.xml >"$PREFS" 2>/dev/null
if [ ! -s "$PREFS" ]; then
    echo "✗ 没有生成 dvplayer_credentials.xml"
    exit 1
fi
grep -o 'cred:smb://[^<]*' "$PREFS" | head -3
if grep -qF "$PASS" "$PREFS"; then
    echo "✗ prefs 里出现了明文密码"
    exit 1
fi
if grep -qE '>[A-Za-z0-9+/=]+:[A-Za-z0-9+/=]+<' "$PREFS"; then
    echo "✓ 落盘格式是 iv:Base64(密文)，没有明文"
else
    echo "✗ 没有找到加密后的 iv:密文"
    exit 1
fi

echo "== 3. 不带密码再列一次（应读加密存储）=="
list /tmp/dv-cred-2.log --es smb_user "$USER_NAME" --es smb "$URL"

echo "== 4. 结果 =="
if sed 's/^.*): //' /tmp/dv-cred-2.log | grep -qE 'list .*-> [0-9]+ 项'; then
    echo "✓ 第二次未传密码仍能列目录"
else
    echo "✗ 第二次没列出来"
    sed 's/^.*): //' /tmp/dv-cred-2.log | tail -10
    exit 1
fi
