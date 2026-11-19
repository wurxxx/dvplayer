#!/usr/bin/env bash
# FEL A/B：同一帧，开/关增强层各截一张，算 PSNR / SSIM。
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env.sh
source "$here/env.sh"

if [ $# -lt 1 ]; then
  echo "usage: $0 <input.mkv> [seconds]" >&2
  exit 2
fi

in=$1
t=${2:-60}
out=$here/../out/ab
mkdir -p "$out"

echo "== with EL (FEL active) =="
a=$(python3 "$here/grab_frame.py" "$in" "$t" with-el --outdir "$out")

echo "== base layer only =="
b=$(python3 "$here/grab_frame.py" "$in" "$t" bl-only --no-el --outdir "$out")

echo
echo "with EL: $a"
echo "base   : $b"
echo

echo "== mpv log (dv / el / libplacebo) =="
grep -iE 'dolby|enhancement|libplacebo' "$out/with-el.log" | head -20 || true
echo

echo "== psnr =="
ffmpeg -hide_banner -i "$a" -i "$b" -lavfi psnr -f null - 2>&1 | grep -E 'PSNR' | tail -1 || true

echo "== ssim =="
ffmpeg -hide_banner -i "$a" -i "$b" -lavfi ssim -f null - 2>&1 | grep -E 'SSIM' | tail -1 || true

echo
echo "参考：真 FEL 的 PSNR 经验值 18–25 dB；接近 inf 说明 EL 没参与渲染。"
