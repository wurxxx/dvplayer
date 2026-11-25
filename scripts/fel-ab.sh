#!/usr/bin/env bash
# FEL A/B：同一帧，开/关增强层各截一张，算 PSNR / SSIM 与像素差统计。
#
# 用法:
#   ./scripts/fel-ab.sh <input.mkv> [seconds]
#
# 走产品自己的播放路径（进程内 libmpv + render API + gpu-next），截图读的是
# 应用自己的 GL framebuffer，所以**包含 Dolby Vision 整形与增强层**。
# 两张图的唯一区别是 `--vf=format=enhancement-layer=no`（`DVPLAYER_VF` 注入）。
#
# 判读（重要）：SDR 显示器上的 8bit 截图会把 FEL 残差大幅压掉，
# 所以「PSNR 高」不等于「EL 没参与」。
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$here/.." && pwd)
# shellcheck source=env.sh
source "$here/env.sh"

if [ $# -lt 1 ]; then
  echo "usage: $0 <input.mkv> [seconds]" >&2
  exit 2
fi

in=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
t=${2:-60}
out=$ROOT/out/ab
mkdir -p "$out"

APP="$ROOT/apps/macos/DvPlayer/build/DvPlayer.app/Contents/MacOS/DvPlayer"
if [ ! -x "$APP" ]; then
  echo "没找到 ${APP}，先跑：cd apps/macos/DvPlayer && ./build.sh" >&2
  exit 1
fi

# 产品 app 的 mpv 日志落在 NSTemporaryDirectory()，抓完留着方便对照。
# `pause,seek:` 保证两次都在**同一帧**：起播后暂停，再精确定位到 t，
# 否则两次的播放位置差几十毫秒，PSNR 就成了帧间差而非 EL 差。
grab() { # <输出 png> <日志名> [额外 env...]
  local png=$1 log=$2
  shift 2
  env DVPLAYER_LOCAL="$in" DVPLAYER_LOCAL_START="$t" \
      DVPLAYER_PLAY_UI="wait:1,pause,seek:$t" DVPLAYER_PLAY_SECONDS=4 \
      DVPLAYER_PLAY_FRAME="$png" DVPLAYER_EXIT=1 \
      "$@" "$APP" >/dev/null 2>&1 || true
  [ -f "$png" ] || { echo "抓帧失败（没有产出 ${png}）" >&2; return 1; }
  for cand in "${TMPDIR:-/tmp}/dvplayer-mpv.log" "${TMPDIR:-/tmp}dvplayer-mpv.log"; do
    [ -f "$cand" ] && cp "$cand" "$out/$log.log" && break
  done
  return 0
}

echo "== with EL (FEL active) =="
a="$out/with-el.png"
rm -f "$a"
grab "$a" with-el || exit 1

echo "== base layer only =="
b="$out/bl-only.png"
rm -f "$b"
grab "$b" bl-only DVPLAYER_VF=format=enhancement-layer=no || exit 1

echo
echo "with EL: $a"
echo "base   : $b"
echo

echo "== mpv log（EL 相关）=="
grep -iE 'Dolby Vision Profile|enhancement|splitter|el_pair' "$out/with-el.log" 2>/dev/null | head -10 || true
echo

echo "== psnr =="
psnr_log=$(ffmpeg -hide_banner -i "$a" -i "$b" -lavfi psnr -f null - 2>&1) || {
  echo "PSNR 计算失败" >&2
  exit 1
}
psnr=$(printf '%s\n' "$psnr_log" | grep -E 'PSNR' | tail -1)
[ -n "$psnr" ] || { echo "PSNR 没有输出" >&2; exit 1; }
echo "$psnr"

echo "== ssim =="
ssim_log=$(ffmpeg -hide_banner -i "$a" -i "$b" -lavfi ssim -f null - 2>&1) || {
  echo "SSIM 计算失败" >&2
  exit 1
}
ssim=$(printf '%s\n' "$ssim_log" | grep -E 'SSIM' | tail -1)
[ -n "$ssim" ] || { echo "SSIM 没有输出" >&2; exit 1; }
echo "$ssim"

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
echo "确认 EL 是否参与：看上面的 mpv log 里有没有 \"Dolby Vision Profile\" / enhancement 行。"
