#!/usr/bin/env bash
# 把 libmpv.so 推到已连接的设备/模拟器，跑最小加载探针。
#
#   scripts/android/check-mpv.sh                    # 默认 arm64（真机）
#   ADB_SERIAL=QS48... scripts/android/check-mpv.sh # 指定设备（多台连着时必须）
#   ARCH=arm64 scripts/android/check-mpv.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=env.sh
source "$ROOT/scripts/android/env.sh"

ARCH=${ARCH:-arm64}
case "$ARCH" in
    x86_64) TRIPLE=x86_64-linux-android ;;
    arm64) TRIPLE=aarch64-linux-android ;;
    *) echo "不支持的 ARCH：$ARCH" >&2; exit 2 ;;
esac

# 多台设备连着时 adb 会拒绝执行，用 ADB_SERIAL 选一台。
ADB=(adb)
if [ -n "${ADB_SERIAL:-}" ]; then
    ADB=(adb -s "$ADB_SERIAL")
fi

PREFIX=$ROOT/build/android-mpv/$ARCH/prefix
SO=$PREFIX/lib/libmpv.so
[ -f "$SO" ] || { echo "找不到 $SO，先跑 build-mpv.sh" >&2; exit 2; }

TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64"
CC="$TOOLCHAIN/bin/${TRIPLE}26-clang"
READELF="$TOOLCHAIN/bin/llvm-readelf"

# 只允许系统库。出现 libc++_shared / libavcodec 之类就是链接形态错了，
# 推上去只会得到一行「cannot locate symbol」，不如在这里就报。
allowed=' libm.so libc.so libdl.so libandroid.so libmediandk.so libOpenSLES.so libEGL.so libGLESv2.so liblog.so libjnigraphics.so libz.so '
unexpected=
while IFS= read -r lib; do
    [ -n "$lib" ] || continue
    case "$allowed" in
        *" $lib "*) ;;
        *) unexpected="$unexpected $lib" ;;
    esac
done < <("$READELF" -d "$SO" | awk '/NEEDED/{ gsub(/[][]/, "", $NF); print $NF }')

if [ -n "$unexpected" ]; then
    echo "!! $SO 依赖了不该有的库：$unexpected" >&2
    exit 1
fi

OUT=$ROOT/build/android-mpv/$ARCH/probe
"$CC" -O2 -o "$OUT" "$ROOT/scripts/android/mpv-probe.c" -ldl

"${ADB[@]}" push "$SO" /data/local/tmp/libmpv.so >/dev/null
"${ADB[@]}" push "$OUT" /data/local/tmp/mpv-probe >/dev/null

echo "==> $("${ADB[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')"
"${ADB[@]}" shell "chmod 755 /data/local/tmp/mpv-probe && LD_LIBRARY_PATH=/data/local/tmp /data/local/tmp/mpv-probe"
