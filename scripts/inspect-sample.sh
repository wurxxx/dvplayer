#!/usr/bin/env bash
# 判断一个文件是不是 P7 双层，以及是 FEL 还是 MEL。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=env.sh
source "$ROOT/scripts/env.sh"

if [ $# -lt 1 ]; then
  echo "usage: $0 <file>" >&2
  exit 2
fi

in=$1

echo "== stream =="
ffprobe -v error -select_streams v \
  -show_entries stream=index,codec_name,profile,width,height,pix_fmt,codec_tag_string \
  -of compact "$in"

echo
echo "video streams: $(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$in" | wc -l | tr -d ' ')"

echo
echo "== mpv 探测 =="
mpv --no-config --vo=null --hwdec=no --frames=1 --start=0 -v "$in" 2>&1 \
  | grep -iE 'dolby|enhancement|profile 7|el_present|libplacebo' \
  | head -20 || true

cat <<'EOF'

判读：
- 出现 "Dolby Vision Profile 7" → 是 P7。
- video streams = 2 → 双轨（BL 一条、EL 一条）。
- video streams = 1 且日志有 splitter → 单轨带内交织。
- FEL/MEL 最终以 dovi_tool info 的 disable_residual_flag 为准
  （scripts/split-el.sh 会打印）。
EOF
