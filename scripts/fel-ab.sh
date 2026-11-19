#!/usr/bin/env bash
# FEL A/B：同一帧，开/关增强层各截一张，算 PSNR / SSIM 与像素差统计。
#
# 用法:
#   ./scripts/fel-ab.sh <input.mkv> [seconds]          # legacy gpu（无 DV）
#   ./scripts/fel-ab.sh <input.mkv> [seconds] --vk     # gpu-next + Vulkan（DV 正解）
#
# 只有 --vk 这条路会真正应用 Dolby Vision 整形与增强层；
# legacy gpu 连 P5 都会偏紫，更不会合成 EL。
#
# 判读（重要）：SDR 显示器上的 8bit 截图会把 FEL 残差大幅压掉，
# 所以「PSNR 高」不等于「EL 没参与」。要证明链路通，用
#   ./scripts/fel-amplify.sh <input.mkv> [seconds] [factor]
# 把 NLQ 残差放大后重跑 A/B。
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$here/.." && pwd)
# shellcheck source=env.sh
source "$here/env.sh"

mode=legacy
for a in "$@"; do
  case "$a" in --vk) mode=vk ;; esac
done

args=()
for a in "$@"; do
  case "$a" in --vk) ;; *) args+=("$a") ;; esac
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

grab=(python3 "$here/grab_frame.py")
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

echo "== mpv log（EL 相关）=="
grep -iE 'Dolby Vision Profile|enhancement|splitter|el_pair' "$out/with-el.log" | head -10 || true
echo

echo "== psnr =="
psnr=$(ffmpeg -hide_banner -i "$a" -i "$b" -lavfi psnr -f null - 2>&1 |
       grep -E 'PSNR' | tail -1 || true)
echo "${psnr:-（未取得）}"

echo "== ssim =="
ssim=$(ffmpeg -hide_banner -i "$a" -i "$b" -lavfi ssim -f null - 2>&1 |
       grep -E 'SSIM' | tail -1 || true)
echo "${ssim:-（未取得）}"

echo "== 像素差（8bit RGB）=="
python3 - "$a" "$b" <<'PY'
import sys
import numpy as np
from PIL import Image

a = np.asarray(Image.open(sys.argv[1]).convert("RGB"), dtype=np.int16)
b = np.asarray(Image.open(sys.argv[2]).convert("RGB"), dtype=np.int16)
d = np.abs(a - b)
print(f"mean={d.mean():.3f}  max={d.max()}  p99={np.percentile(d, 99):.0f}  "
      f">2={100.0 * (d.max(axis=2) > 2).mean():.4f}%")
PY

echo
echo "判读：SDR 8bit 输出会压掉大部分 FEL 残差，差异小是正常的。"
echo "要确认 EL 真的进了 shader：./scripts/fel-amplify.sh \"$in\" \"$t\" 100"
