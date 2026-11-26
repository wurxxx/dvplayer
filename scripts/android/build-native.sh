#!/usr/bin/env bash
# 构建 Android 侧 Rust native 库。
#
# A0 阶段只有一个 JNI 自检桩（core/media-jni）；A3 起换成真正的 core/media 绑定。
#
#   scripts/android/build-native.sh                  # arm64-v8a，release
#   ABIS="arm64-v8a x86_64" scripts/android/build-native.sh  # 模拟器调试用
#   PROFILE=debug scripts/android/build-native.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=env.sh
source "$ROOT/scripts/android/env.sh"

ABIS=${ABIS:-arm64-v8a}
PROFILE=${PROFILE:-release}
CRATE=${CRATE:-dvplayer-media-jni}
OUT="$ROOT/apps/android/core/src/main/jniLibs"

ndk_targets=()
for abi in $ABIS; do
    case "$abi" in
        arm64-v8a | x86_64) ndk_targets+=(-t "$abi") ;;
        *)
            echo "不支持的 ABI：$abi（只做 arm64-v8a，x86_64 仅本机模拟器调试）" >&2
            exit 2
            ;;
    esac
done

cargo_flags=()
if [ "$PROFILE" = "release" ]; then
    cargo_flags+=(--release)
fi

echo "==> cargo ndk ${ndk_targets[*]} build -p $CRATE ($PROFILE)"
cd "$ROOT/core"
cargo ndk --platform 26 "${ndk_targets[@]}" -o "$OUT" build -p "$CRATE" "${cargo_flags[@]}"

# ---------------------------------------------------------------- 16KB 校验
# Android 15（API 35）起 64 位设备可能用 16KB 页。NDK r28 默认按 16KB 对齐，
# 但链接参数被改过就会退回 4KB，装到这类设备上起不来。
READELF="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf"
if [ ! -x "$READELF" ]; then
    READELF=$(command -v llvm-readelf || true)
fi
if [ -z "$READELF" ] || [ ! -x "$READELF" ]; then
    echo "!! 找不到 llvm-readelf，跳过 16KB 校验" >&2
    exit 0
fi

fail=0
while IFS= read -r so; do
    [ -n "$so" ] || continue
    min_align=999999999
    while IFS= read -r align_hex; do
        [ -n "$align_hex" ] || continue
        value=$((16#${align_hex#0x}))
        if [ "$value" -lt "$min_align" ]; then
            min_align=$value
        fi
    done < <("$READELF" -lW "$so" | awk '$1 == "LOAD" { print $NF }')

    if [ "$min_align" -eq 999999999 ]; then
        echo "!! $so 没有 LOAD 段，校验失败" >&2
        fail=1
    elif [ "$min_align" -lt 16384 ]; then
        printf '!! 16KB 校验失败：%s 最小 LOAD 对齐 0x%x（< 0x4000）\n' "$so" "$min_align" >&2
        fail=1
    else
        printf '   %-12s LOAD align >= 0x4000\n' "$(basename "$so")"
    fi
done < <(find "$OUT" -name '*.so' -type f | sort)

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "==> native 库就绪：$OUT"
