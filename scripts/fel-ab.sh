#!/usr/bin/env bash
# FEL A/B：同一帧，开/关增强层各截一张，算 PSNR / SSIM。
#
# 用法:
#   ./scripts/fel-ab.sh <input.mkv> [seconds]          # legacy gpu（无 DV）
#   ./scripts/fel-ab.sh <input.mkv> [seconds] --vk     # gpu-next + Vulkan（DV 正解）
#
# 只有 --vk 这条路会真正应用 Dolby Vision 整形与增强层；
# legacy gpu 连 P5 都会偏紫，更不会合成 EL。
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$here/.." && pwd)
# shellcheck source=env.sh
source "$here/env.sh"

mode=legacy
args=()
for a in "$@"; do
  case "$a" in
    --vk) mode=vk ;;
    --*)  args+=("$a") ;;
    *)    args+=("$a") ;;
  esac
done
set -- "${args[@]}"

if [ $# -lt 1 ]; then
  echo "usage: $0 <input.mkv> [seconds] [--vk]" >&2
  exit 2
fi

in=$1
t=${2:-60}
out=$ROOT/out/ab
mkdir -p "$out"

grab=(
  python3 "$here/grab_frame.py"
)
if [ "$mode" = "vk" ]; then
  if [ ! -x "$ROOT/prefix-vk/bin/mpv" ]; then
    echo "prefix-vk/bin/mpv 不存在，先跑 scripts/build-vk-macos.sh" >&2
    exit 1
  fi
  export DYLD_LIBRARY_PATH="$ROOT/prefix-vk/lib:$ROOT/prefix/lib:${DYLD_LIBRARY_PATH:-}"
  export VK_ICD_FILENAMES="$ROOT/prefix-vk/share/vulkan/icd.d/MoltenVK_icd.json"
  grab+=(--mpv "$ROOT/prefix-vk/bin/mpv" --vo gpu-next --gpu-context=macvk)
fi

echo "== with EL (FEL active) =="
a=$("${grab[@]}" "$in" "$t" with-el --outdir "$out" | tail -1)

echo "== base layer only =="
b=$("${grab[@]}" "$in" "$t" bl-only --no-el --outdir "$out" | tail -1)

echo
echo "with EL: $a"
echo "base   : $b"
echo

echo "== mpv log (dv / el / libplacebo) =="
grep -iE 'dolby|enhancement|libplacebo|gpu-next' "$out/with-el.log" | head -20 || true
echo

echo "== psnr =="
ffmpeg -hide_banner -i "$a" -i "$b" -lavfi psnr -f null - 2>&1 | grep -E 'PSNR' | tail -1 || true

echo "== ssim =="
ffmpeg -hide_banner -i "$a" -i "$b" -lavfi ssim -f null - 2>&1 | grep -E 'SSIM' | tail -1 || true

echo
echo "参考：真 FEL 的 PSNR 经验值 18–25 dB；接近 inf 说明 EL 没参与渲染。"
