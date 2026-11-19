#!/usr/bin/env bash
# M0 工具链自检：版本 + FEL 相关能力。
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=env.sh
source "$ROOT/scripts/env.sh"

ok=0
bad=0

pass() { printf '  [ok]   %s\n' "$1"; ok=$((ok + 1)); }
fail() { printf '  [fail] %s\n' "$1"; bad=$((bad + 1)); }
warn() { printf '  [warn] %s\n' "$1"; }

printf '\n== dvplayer preflight ==\n'
printf 'host : %s %s\n' "$(uname -s)" "$(uname -m)"
printf 'date : %s\n\n' "$(date '+%Y-%m-%d %H:%M')"

for t in mpv ffmpeg ffprobe dovi_tool; do
  if command -v "$t" >/dev/null 2>&1; then
    pass "$t  $(command -v "$t")"
  else
    fail "$t  未安装"
  fi
done

if command -v mpv >/dev/null 2>&1; then
  line=$(mpv --version | head -1)
  printf '  mpv  %s\n' "$line"
  if printf '%s' "$line" | grep -qE 'mpv v?0\.42'; then
    pass "mpv 0.42+"
  else
    fail "mpv 需要 0.42+（gpu-next 的 P7 增强层）"
  fi

  lp=$(mpv --version | sed -n 's/^libplacebo version: v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | head -1)
  if [ -n "${lp:-}" ]; then
    printf '  libplacebo %s\n' "$lp"
    lowest=$(printf '%s\n%s\n' "7.387.0" "$lp" | sort -V | head -1)
    if [ "$lowest" = "7.387.0" ]; then
      pass "libplacebo >= 7.387"
    else
      fail "libplacebo 需要 >= 7.387（FEL API）"
    fi
  else
    warn "mpv --version 未显示 libplacebo 版本（不影响播放，但无法自动核对）"
  fi
fi

# macOS Vulkan 验证路径（ADR-0006）。缺了不影响产品构建，只是看不了 P5 的正确颜色。
if [ -x "$ROOT/prefix-vk/bin/mpv" ] &&
   grep -q 'pl_has_vulkan=1' "$ROOT/prefix-vk/lib/pkgconfig/libplacebo.pc" 2>/dev/null; then
  pass "prefix-vk mpv（Vulkan/gpu-next 验证路径）"
else
  warn "prefix-vk 未构建：DV 验证路径不可用（scripts/build-vk-macos.sh，见 ADR-0006）"
fi

if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -version 2>/dev/null | head -1
  if ffmpeg -hide_banner -bsfs 2>/dev/null | grep -qx 'dovi_split'; then
    pass "ffmpeg 含 dovi_split"
  else
    fail "ffmpeg 缺 dovi_split（需要 9.0+）"
  fi
fi

if command -v dovi_tool >/dev/null 2>&1; then
  dovi_tool --version 2>&1 | head -1 || true
fi

printf '\n'
for t in meson ninja nasm cargo; do
  command -v "$t" >/dev/null 2>&1 || warn "$t 未安装（M1 vendored 构建需要，M0 不需要）"
done

shopt -s nullglob
samples=(samples/*.mkv samples/*.mp4)
if [ ${#samples[@]} -eq 0 ]; then
  warn "samples/ 下没有样片（A1/A2 需要 P7 FEL 片源）"
else
  printf '  samples: %s\n' "${samples[*]}"
fi

printf '\n%d ok, %d failed\n' "$ok" "$bad"
[ "$bad" -eq 0 ]
