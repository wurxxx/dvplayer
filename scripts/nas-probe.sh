#!/usr/bin/env bash
# 通过 SSH 检查 NAS 上的目标文件。
# 需要环境变量：NAS_USER、NAS_PASS
set -euo pipefail

: "${NAS_USER:?NAS_USER is required}"
: "${NAS_PASS:?NAS_PASS is required}"

HOST=10.0.0.100
REMOTE="/vol1/1000/影视/I.Will.Find.You.2026.S01.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.H.265-DepWeb/I.Will.Find.You.2026.S01E01.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.H.265-DepWeb.mkv"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/askpass" <<'EOF'
#!/bin/sh
printf '%s\n' "$NAS_PASS"
EOF
chmod 700 "$TMP/askpass"

cat > "$TMP/remote.sh" <<'EOS'
F="/vol1/1000/影视/I.Will.Find.You.2026.S01.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.H.265-DepWeb/I.Will.Find.You.2026.S01E01.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.H.265-DepWeb.mkv"
echo "== ls =="
ls -l "$F" || { echo "MISSING"; exit 2; }
echo
echo "== tools =="
for t in ffprobe mediainfo ffmpeg; do
  printf '%s: ' "$t"
  command -v "$t" || echo missing
done
if command -v ffprobe >/dev/null 2>&1; then
  echo
  echo "== ffprobe =="
  ffprobe -v error -select_streams v \
    -show_entries stream=index,codec_name,profile,width,height,pix_fmt,codec_tag_string \
    -of default=nw=1 "$F"
  echo
  echo "== side data =="
  ffprobe -v error -select_streams v -show_entries stream_side_data \
    -of default=nw=1 "$F" || true
fi
if command -v mediainfo >/dev/null 2>&1; then
  echo
  echo "== mediainfo =="
  mediainfo "$F" | sed -n '1,60p'
fi
EOS

SSH_ASKPASS="$TMP/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
  ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=8 \
      -o NumberOfPasswordPrompts=1 \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      "$NAS_USER@$HOST" 'bash -s' < "$TMP/remote.sh"
