#!/usr/bin/env bash
# 校验 APK 里的 native 库：未压缩、且在 APK 内按 16KB 页对齐。
#
#   scripts/android/check-apk.sh apps/android/app-phone/build/outputs/apk/debug/app-phone-debug.apk
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=env.sh
source "$ROOT/scripts/android/env.sh"

APK=${1:?用法: check-apk.sh <apk>}
[ -f "$APK" ] || { echo "找不到 APK：$APK" >&2; exit 2; }

ZIPALIGN="$ANDROID_HOME/build-tools/36.1.0/zipalign"
if [ ! -x "$ZIPALIGN" ]; then
    ZIPALIGN=$(find "$ANDROID_HOME/build-tools" -name zipalign -type f | sort -V | tail -1)
fi
[ -x "$ZIPALIGN" ] || { echo "找不到 zipalign" >&2; exit 2; }

echo "==> $APK"
"$ZIPALIGN" -c -P 16 -v 4 "$APK" | grep -E '\.so|Verification' || true

echo "--- native 库（方法 / 大小 / 路径）"
unzip -lv "$APK" | awk 'NR > 3 && $NF ~ /\.so$/ { printf "%-6s %10s  %s\n", $2, $1, $NF }'
