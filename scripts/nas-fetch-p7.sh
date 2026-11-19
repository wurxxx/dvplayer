#!/usr/bin/env bash
# 从 NAS 上的双轨 UHD 片源里切一小段（保留全部视频轨 + 首条音频），拉回本地。
# 用法: nas-fetch-p7.sh <远端文件> [本地输出] [起始秒] [时长秒]
# 需要环境变量：NAS_USER、NAS_PASS
set -euo pipefail

: "${NAS_USER:?NAS_USER is required}"
: "${NAS_PASS:?NAS_PASS is required}"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

HOST=10.0.0.100
REMOTE=${1:?remote file path is required}
OUT=${2:-samples/p7-fel.mkv}
START=${3:-60}
DUR=${4:-20}
TMP_REMOTE="/tmp/dvplayer-p7-$$.mkv"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/askpass" <<'EOF'
#!/bin/sh
printf '%s\n' "$NAS_PASS"
EOF
chmod 700 "$TMP/askpass"

ssh_run() {
  SSH_ASKPASS="$TMP/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=8 \
        -o NumberOfPasswordPrompts=1 \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        "$NAS_USER@$HOST" "$@"
}

echo "== 远端目录 =="
ssh_run "ls -lh '$(dirname "$REMOTE")' | head -20"

echo
echo "== 轨道结构 =="
ssh_run "ffprobe -v error -select_streams v -show_entries stream=index,codec_name,profile,width,height,pix_fmt,bit_rate -of default=nw=1 '$REMOTE'"

echo
echo "== 在 NAS 上切 ${DUR}s（起点 ${START}s，保留双轨）=="
ssh_run "ffmpeg -hide_banner -y -ss '$START' -i '$REMOTE' -t '$DUR' \
  -map 0:v:0 -map 0:v:1 -map 0:a:0? -c copy -f matroska '$TMP_REMOTE' \
  && ls -l '$TMP_REMOTE'"

echo
echo "== 拉回本地 =="
mkdir -p "$(dirname "$OUT")"
ssh_run "cat '$TMP_REMOTE'" > "$OUT"
ssh_run "rm -f '$TMP_REMOTE'" || true

ls -lh "$OUT"
echo
echo "== 本地复核 =="
"$ROOT/prefix/bin/ffprobe" -v error -select_streams v \
  -show_entries stream=index,codec_name,profile,width,height,pix_fmt -of default=nw=1 "$OUT"
