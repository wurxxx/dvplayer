#!/usr/bin/env bash
# 验证 https 与内置 CA 包（A9 / 7.1）：
#   1. 自签证书 + --es tls_verify 1  → 必须失败（证明校验真的在跑）
#   2. 自签证书 + 默认（不校验）     → 必须能播（自签名 NAS 的默认路径）
#   3. 公网证书 + --es tls_verify 1  → 必须能播（证明内置的 Mozilla CA 可用）
#
# 本地自签服务由 tests/android/https_server.py 起在 8443，走 adb reverse。
# 第 3 项要外网；没有外网就 NO_NET=1 跳过。
#
#   tests/android/verify-tls.sh
set -u

cd "$(dirname "$0")/../.." || exit 1
if [ -n "${ADB:-}" ]; then read -r -a ADB_CMD <<< "$ADB"; else ADB_CMD=(adb -d); fi
PKG=com.dvplayer.app
ACT=$PKG/.PlayerTestActivity
APK=apps/android/app-phone/build/outputs/apk/debug/app-phone-debug.apk
PUBLIC="${TLS_PUBLIC_URL:-https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8}"
ROOT=$(mktemp -d)
PORT=8443
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; fi
    "${ADB_CMD[@]}" reverse --remove tcp:$PORT >/dev/null 2>&1 || true
    rm -rf "$ROOT"
}
trap cleanup EXIT

echo "== 准备：自签证书 + 本地 https 服务 =="
# 优先用小样片：自签那两项只关心「连没连上」
if [ -f /tmp/small.mp4 ]; then cp /tmp/small.mp4 "$ROOT/sample.mkv"; else cp samples/p5.mkv "$ROOT/sample.mkv"; fi
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
    -keyout "$ROOT/key.pem" -out "$ROOT/cert.pem" >/dev/null 2>&1 || { echo "openssl 失败"; exit 1; }
python3 tests/android/https_server.py --root "$ROOT" --port $PORT \
    --cert "$ROOT/cert.pem" --key "$ROOT/key.pem" >"$ROOT/server.log" 2>&1 &
SERVER_PID=$!
sleep 1
"${ADB_CMD[@]}" reverse tcp:$PORT tcp:$PORT >/dev/null || { echo "adb reverse 失败"; exit 1; }

"${ADB_CMD[@]}" install -r "$APK" >/dev/null 2>&1 || { echo "APK 安装失败"; exit 1; }
"${ADB_CMD[@]}" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true

play() { # 等待秒数 日志 参数...
    local wait=$1 log=$2
    shift 2
    "${ADB_CMD[@]}" shell am force-stop "$PKG"
    "${ADB_CMD[@]}" logcat -c
    "${ADB_CMD[@]}" logcat -v time -s DvPlayerTest:I DvMpv:I DvTls:I >"$log" 2>&1 &
    local pid=$!
    sleep 1
    "${ADB_CMD[@]}" shell am start -W -n "$ACT" --activity-clear-task "$@" >/dev/null 2>&1
    sleep "$wait"
    kill "$pid" 2>/dev/null || true
    sed 's/^.*): //' "$log"
}

echo "== 1. 自签 + 校验（应失败）=="
out=$(play 10 "$ROOT/1.log" --es url "https://127.0.0.1:$PORT/sample.mkv" --es tls_verify 1)
echo "$out" | grep -E "TLS 校验|CA 包|not correctly signed|loading failed" | head -4
if echo "$out" | grep -q "loading failed"; then echo "✓ 校验拦住了自签证书"; else echo "✗ 未校验，安全开关没生效"; exit 1; fi

echo "== 2. 自签 + 默认（应能播）=="
out=$(play 10 "$ROOT/2.log" --es url "https://127.0.0.1:$PORT/sample.mkv")
if echo "$out" | grep -qE "state mpv pos=[1-9][0-9]*ms"; then echo "✓ 默认不校验时自签可播"; else
    echo "✗ 默认路径播不了"; echo "$out" | tail -10; exit 1; fi

if [ "${NO_NET:-0}" = "1" ]; then
    echo "== 3. 公网证书（NO_NET=1，跳过）=="
    exit 0
fi

echo "== 3. 公网证书 + 校验（应能播）=="
out=$(play 20 "$ROOT/3.log" --es url "$PUBLIC" --es tls_verify 1)
echo "$out" | grep -E "TLS 校验|file loaded|state mpv" | head -4
if echo "$out" | grep -qE "state mpv pos=[1-9][0-9]*ms"; then
    echo "✓ 内置 CA 能校验公网证书"
else
    echo "✗ 公网 https 播不了（先确认设备有外网）"
    exit 1
fi
