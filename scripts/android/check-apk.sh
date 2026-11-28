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

# zipalign 只保证「APK 内的偏移」，还要确认 ELF 自己的 PT_LOAD 按 0x4000
# 对齐——16KB 页设备上 dlopen 读的是后者。
READELF=
for candidate in \
    "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf" \
    "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"; do
    [ -x "$candidate" ] && READELF=$candidate && break
done
if [ -z "$READELF" ]; then
    echo "⚠ 找不到 llvm-readelf，跳过 ELF 对齐检查" >&2
    exit 0
fi

tmp=$(mktemp -d)
unzip -q "$APK" 'lib/*' -d "$tmp"
status=0
while IFS= read -r so; do
    bad=$("$READELF" -lW "$so" | awk '$1 == "LOAD" { print $NF }' | while read -r align; do
        python3 - "$align" <<'PY'
import sys
if int(sys.argv[1], 16) < 0x4000:
    print(sys.argv[1])
PY
    done)
    if [ -n "$bad" ]; then
        echo "✗ $(basename "$so") 的 LOAD 段没按 16KB 对齐：$bad" >&2
        status=1
    else
        echo "✓ $(basename "$so") LOAD 全部 ≥ 0x4000"
    fi
done < <(find "$tmp/lib" -name '*.so' 2>/dev/null)
rm -rf "$tmp"
exit $status
