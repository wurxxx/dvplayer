#!/usr/bin/env bash
# 从 NAS 上切一小段样本并拉回本地。
# 用法: nas-fetch-sample.sh [输出文件] [起始秒] [时长秒]
# 需要环境变量：NAS_USER、NAS_PASS
set -euo pipefail

: "${NAS_USER:?NAS_USER is required}"
: "${NAS_PASS:?NAS_PASS is required}"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

HOST=10.0.0.100
OUT=${1:-samples/p5.mkv}
START=${2:-30}
DUR=${3:-20}

REMOTE_DIR="/vol1/1000/影视/I.Will.Find.You.2026.S01.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.H.265-DepWeb"
REMOTE_FILE="$REMOTE_DIR/I.Will.Find.You.2026.S01E01.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.H.265-DepWeb.mkv"
TMP_REMOTE="/tmp/dvplayer-sample-$$.mkv"

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

mkdir -p "$(dirname "$OUT")"

echo "== 在 NAS 上切片（start=${START}s, dur=${DUR}s）=="
ssh_run "ffmpeg -hide_banner -y -ss '$START' -i '$REMOTE_FILE' -t '$DUR' -map 0 -c copy '$TMP_REMOTE' && ls -l '$TMP_REMOTE'"

echo
echo "== 拉回本地 =="
ssh_run "cat '$TMP_REMOTE'" > "$OUT"
ssh_run "rm -f '$TMP_REMOTE'" || true

ls -lh "$OUT"
