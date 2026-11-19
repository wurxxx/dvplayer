#!/usr/bin/env bash
# FEL 残差放大器（诊断用）：把 libplacebo 的 NLQ 残差临时放大 N 倍，
# 重编 prefix-vk 里的 libplacebo，再跑 fel-ab.sh --vk，最后自动还原并重编。
#
# 用途：SDR 8bit 输出会把真实 FEL 残差压到几乎看不见。放大后如果
# 「开 EL / 关 EL」出现明显差异，就证明 EL 真的进了 shader；
# 反之说明链路没接上（或采样对齐错了）。
#
# 用法: ./scripts/fel-amplify.sh <input.mkv> [seconds] [factor=100]
#
# 前置：scripts/build-vk-macos.sh 已跑过，build/src/libplacebo 尚在。
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$here/.." && pwd)

in=${1:?usage: $0 <input.mkv> [seconds] [factor]}
t=${2:-60}
factor=${3:-100}

LP="$ROOT/build/src/libplacebo"
SRC="$LP/src/shaders/colorspace.c"
BUILD="$LP/_build-vk"

[ -f "$SRC" ] || { echo "找不到 $SRC（先跑 scripts/build-vk-macos.sh）" >&2; exit 1; }
[ -d "$BUILD" ] || { echo "找不到 $BUILD（先跑 scripts/build-vk-macos.sh）" >&2; exit 1; }
grep -q 'color.rgb += clamp(res, -\$mx, \$mx);' "$SRC" || {
  echo "colorspace.c 的 NLQ 行不是预期形态；可能上次没还原，先检查 $SRC" >&2
  exit 1
}

export PATH="$HOME/Library/Python/3.9/bin:$PATH"

backup=$(mktemp -t dovi-colorspace.XXXXXX)
cp "$SRC" "$backup"

cleanup() {
  cp "$backup" "$SRC"
  rm -f "$backup"
  if meson compile -C "$BUILD" >/dev/null 2>&1 &&
     meson install -C "$BUILD" >/dev/null 2>&1; then
    echo "[amplify] 已还原 libplacebo 并重编"
  else
    echo "[amplify] 警告：还原源码后重编失败，请手动跑 scripts/build-vk-macos.sh" >&2
  fi
}
trap cleanup EXIT INT TERM

python3 - "$SRC" "$factor" <<'PY'
import sys
p, factor = sys.argv[1], sys.argv[2]
s = open(p).read()
old = "color.rgb += clamp(res, -$mx, $mx);"
new = f"color.rgb += clamp(res * {factor}.0, -1.0, 1.0);"
assert old in s, "NLQ clamp line not found"
open(p, "w").write(s.replace(old, new))
print(f"[amplify] 残差 ×{factor}")
PY

meson compile -C "$BUILD" >/dev/null
meson install -C "$BUILD" >/dev/null
echo "[amplify] libplacebo 已重编"

"$ROOT/scripts/fel-ab.sh" "$in" "$t" --vk
