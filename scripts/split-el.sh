#!/usr/bin/env bash
# 从 P7 双层 HEVC 中拆出 BL 与 EL(+RPU)，并打印 RPU 信息。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=env.sh
source "$ROOT/scripts/env.sh"

if [ $# -lt 1 ]; then
  echo "usage: $0 <input.mkv|mp4> [outdir]" >&2
  exit 2
fi

in=$1
out=${2:-out/split}
mkdir -p "$out"

base=$(basename "$in")
base=${base%.*}

echo "== input =="
echo "$in"
ffprobe -v error -select_streams v \
  -show_entries stream=index,codec_name,width,height,pix_fmt \
  -of compact "$in" || true

nvid=$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$in" | wc -l | tr -d ' ')
echo "video streams: $nvid"

echo
echo "== base layer =="
ffmpeg -hide_banner -y -i "$in" -map 0:v:0 -c copy \
  -bsf:v dovi_split=mode=bl "$out/$base.bl.hevc"

echo
echo "== enhancement layer + RPU =="
ffmpeg -hide_banner -y -i "$in" -map 0:v:0 -c copy \
  -bsf:v dovi_split=mode=el_rpu "$out/$base.el.hevc"

echo
ls -lh "$out/$base.bl.hevc" "$out/$base.el.hevc"

echo
echo "== rpu info =="
if command -v dovi_tool >/dev/null 2>&1; then
  dovi_tool info -i "$out/$base.el.hevc" 2>&1 | head -40 || true
else
  echo "dovi_tool 不可用，跳过"
fi

cat <<'EOF'

提示：
- 若源是双轨 MKV（BL/EL 各一条视频轨），EL 在第二条轨上，
  dovi_split 只处理带内交织（单轨 P7）。上面 video streams > 1 时，
  第二条轨就是 EL，可直接 ffmpeg -map 0:v:1 -c copy 抽出。
- 判定 FEL/MEL：看 dovi_tool 输出里的 disable_residual_flag，
  false = FEL，true = MEL。
EOF
