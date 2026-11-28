#!/usr/bin/env bash
# 生成 Android 发版签名密钥，并打印要给 GitHub Secrets 填的四个值。
#
#   scripts/android/make-keystore.sh [输出路径]
#
# 默认落在 ~/.config/dvplayer/android-release.jks（600 权限），文件名和密码
# 都不要进仓库。密钥丢了这个包就再也盖不上去，记得备份。
#
# 密码在终端里输入（不回显），所以别用带 Run 按钮的方式跑。
set -euo pipefail

OUT=${1:-${HOME}/.config/dvplayer/android-release.jks}
ALIAS=${ALIAS:-dvplayer}
DNAME=${DNAME:-"CN=DVPlayer, OU=Sideload, O=DVPlayer, L=Shenzhen, ST=Guangdong, C=CN"}

command -v keytool >/dev/null 2>&1 || {
    echo "找不到 keytool：装一个 JDK（17）再跑。" >&2
    exit 2
}

if [ -e "$OUT" ]; then
    echo "已经存在：$OUT" >&2
    echo "要重新生成就先挪走它——覆盖会让已发布的包再也升级不了。" >&2
    exit 2
fi

mkdir -p "$(dirname "$OUT")"
chmod 700 "$(dirname "$OUT")"

printf '给密钥设个密码（至少 6 位，输入时不显示）：' >&2
IFS= read -rs STORE_PASSWORD
printf '\n再输一次：' >&2
IFS= read -rs AGAIN
printf '\n' >&2
[ "$STORE_PASSWORD" = "$AGAIN" ] || { echo "两次输入不一致。" >&2; exit 2; }
[ ${#STORE_PASSWORD} -ge 6 ] || { echo "太短了，keytool 至少要求 6 位。" >&2; exit 2; }

keytool -genkeypair \
    -keystore "$OUT" \
    -alias "$ALIAS" \
    -keyalg RSA -keysize 4096 -validity 10000 \
    -storepass "$STORE_PASSWORD" \
    -keypass "$STORE_PASSWORD" \
    -dname "$DNAME" >/dev/null

chmod 600 "$OUT"

echo
echo "密钥：${OUT}（别名 ${ALIAS}）"
echo "备份它和密码，丢了就不能给已装的用户发升级包。"
echo
echo "GitHub → 仓库 → Settings → Secrets and variables → Actions，新增四个："
echo
echo "  DVPLAYER_ANDROID_KEYSTORE_BASE64"
base64 < "$OUT" | tr -d '\n'
echo
echo
echo "  DVPLAYER_ANDROID_STORE_PASSWORD = （刚才输入的密码）"
echo "  DVPLAYER_ANDROID_KEY_ALIAS      = $ALIAS"
echo "  DVPLAYER_ANDROID_KEY_PASSWORD   = （和 STORE_PASSWORD 相同）"
echo
echo "本机构建也可以直接用："
echo "  export DVPLAYER_ANDROID_KEYSTORE=$OUT"
echo "  export DVPLAYER_ANDROID_STORE_PASSWORD=... DVPLAYER_ANDROID_KEY_ALIAS=$ALIAS \\"
echo "         DVPLAYER_ANDROID_KEY_PASSWORD=..."
