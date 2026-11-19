#!/usr/bin/env bash
# 在 NAS 上跑一条任意命令（只读探测用）。
# 用法: nas-run.sh '<remote shell command>'
# 需要环境变量：NAS_USER、NAS_PASS
set -euo pipefail

: "${NAS_USER:?NAS_USER is required}"
: "${NAS_PASS:?NAS_PASS is required}"

HOST=10.0.0.100
CMD=${1:?command is required}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/askpass" <<'EOF'
#!/bin/sh
printf '%s\n' "$NAS_PASS"
EOF
chmod 700 "$TMP/askpass"

SSH_ASKPASS="$TMP/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
  ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=8 \
      -o NumberOfPasswordPrompts=1 \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      "$NAS_USER@$HOST" "$CMD"
