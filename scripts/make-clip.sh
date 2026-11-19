#!/usr/bin/env bash
# 从大文件里无损切一小段，保留所有视频轨与首条音频。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=env.sh
source "$ROOT/scripts/env.sh"

if [ $# -lt 4 ]; then
  echo "usage: $0 <input> <start_seconds> <duration_seconds> <output>" >&2
  exit 2
fi

in=$1
start=$2
dur=$3
out=$4

mkdir -p "$(dirname "$out")"
ffmpeg -hide_banner -y -ss "$start" -i "$in" -t "$dur" \
  -map 0:v -map 0:a:0? -c copy "$out"

ls -lh "$out"
