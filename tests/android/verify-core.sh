#!/usr/bin/env bash
# A3 数据层回归：Kotlin → JNI → Rust 核心，跑通「建连 → 库 → 条目 → 详情 →
# 播放源 → 记录 → 搜索 → 流式建连 → DV 探测」。
#
# 前置：
#   1. 推好 native：ABIS="arm64-v8a x86_64" scripts/android/build-native.sh
#   2. 模拟器要 x86_64：apps/android/gradlew :app-phone:assembleDebug -Pdvplayer.debugAbi=x86_64
#   3. 设备已装该 debug APK（脚本不负责装，避免覆盖你手动调的包）
#
# 用法：
#   tests/android/verify-core.sh                 # 默认 samples/p5.mkv
#   tests/android/verify-core.sh -s emulator-5554
#   tests/android/verify-core.sh /path/to/x.mkv
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PKG=${PKG:-com.dvplayer.app}
ACT=${ACT:-com.dvplayer.app/.CoreSmokeActivity}
FILE=$ROOT/samples/p5.mkv
SERIAL=""
TIMEOUT=60

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--serial) SERIAL=$2; shift 2 ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        *) FILE=$1; shift ;;
    esac
done

ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")

log() { printf '\033[1m== %s\033[0m\n' "$*"; }

"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "没有设备（adb devices）" >&2; exit 1; }
"${ADB[@]}" shell pm path "$PKG" >/dev/null 2>&1 || {
    echo "设备上没装 $PKG，先装 debug APK" >&2
    exit 1
}

# 设备 ABI 与 APK 必须对得上：模拟器上跑 arm64 包会直接起不来。
abi=$("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')
if [ "$abi" = "x86_64" ]; then
    installed=$("${ADB[@]}" shell dumpsys package "$PKG" 2>/dev/null |
        grep -m1 primaryCpuAbi | tr -d '\r')
    case "$installed" in
        *x86_64*) ;;
        *)
            echo "设备是 x86_64，但装上的 APK 没选到 x86_64 核心（$installed）" >&2
            echo "用 -Pdvplayer.debugAbi=x86_64 重新打包再装" >&2
            exit 1
            ;;
    esac
fi

if [ -s "$FILE" ]; then
    name=$(basename "$FILE")
    log "推送 $name"
    "${ADB[@]}" push "$FILE" "/data/local/tmp/$name" >/dev/null
    "${ADB[@]}" shell run-as "$PKG" mkdir -p files/medias
    "${ADB[@]}" shell run-as "$PKG" cp "/data/local/tmp/$name" "files/medias/$name"
    dir="/data/user/0/$PKG/files/medias"
    dovi="$dir/$name"
else
    log "没有样片，只验证空目录链路"
    dir="/data/user/0/$PKG/files/medias"
    dovi=""
fi

"${ADB[@]}" shell am force-stop "$PKG" >/dev/null 2>&1 || true
"${ADB[@]}" logcat -c || true

log "跑冒烟（${TIMEOUT}s 超时）"
"${ADB[@]}" shell am start -n "$ACT" --activity-clear-task \
    --es dir "$dir" \
    --es dovi "$dovi" >/dev/null

result=""
for _ in $(seq 1 "$TIMEOUT"); do
    result=$("${ADB[@]}" logcat -d -v brief 2>/dev/null |
        grep -E "DvCoreSmoke.*RESULT (PASS|FAIL)" | tail -1 || true)
    [ -n "$result" ] && break
    sleep 1
done

echo
"${ADB[@]}" logcat -d -v brief 2>/dev/null | grep "DvCoreSmoke" | sed 's/.*DvCoreSmoke: //' || true
echo

case "$result" in
    *"RESULT PASS"*)
        log "通过"
        ;;
    *"RESULT FAIL"*)
        echo "冒烟失败，看上面的 ✗ 行" >&2
        exit 1
        ;;
    *)
        echo "${TIMEOUT}s 内没等到结果：Activity 崩了或模拟器掉了" >&2
        exit 1
        ;;
esac
