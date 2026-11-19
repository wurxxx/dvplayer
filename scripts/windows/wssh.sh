#!/bin/sh
# 在 Windows 上跑一段 PowerShell。
#
#   sh scripts/windows/wssh.sh 'Get-Date'
#   echo 'Get-ChildItem D:\dvplayer' | sh scripts/windows/wssh.sh
#
# 用 base64(-EncodedCommand) 传代码，绕开 cmd/ssh 的引号与转义问题；
# 输出强制 UTF-8，避免中文乱码。
set -u

HOST=${DVWIN_HOST:-192.168.0.102}
USER_NAME=${DVWIN_USER:-wucl}
KEY=${DVWIN_KEY:-$HOME/.ssh/dvplayer_win}

if [ "$#" -gt 0 ]; then
    CODE="$*"
else
    CODE=$(cat)
fi

PRELUDE='[Console]::OutputEncoding=[Text.Encoding]::UTF8; $OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference="SilentlyContinue";'
ENC=$(printf '%s\n' "$PRELUDE$CODE" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')

exec ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR \
    "$USER_NAME@$HOST" "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $ENC"
