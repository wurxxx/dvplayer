#!/usr/bin/env bash
# 刷新 APK 内置的 Mozilla CA 包（mbedTLS 校验公开 https 用）。
#
# Android 的系统 CA 在 conscrypt 的 APEX 里，native 的 mbedTLS 读不到；
# 所以把 curl 维护的 cacert.pem 打进 APK。证书到期 / 换新后跑一次：
#
#   scripts/android/update-cacert.sh
#
# 然后重新打包（Gradle 会把它当 resources 增量处理）。
set -eu

cd "$(dirname "$0")/../.." || exit 1
TARGET=apps/android/core/src/main/assets/cacert.pem
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

curl -fsSL --max-time 60 https://curl.se/ca/cacert.pem -o "$TMP"

if ! grep -q "BEGIN CERTIFICATE" "$TMP"; then
    echo "下载的文件不是 PEM 证书包" >&2
    exit 1
fi

mv "$TMP" "$TARGET"
count=$(grep -c "BEGIN CERTIFICATE" "$TARGET")
date=$(grep -m1 "Certificate data from Mozilla" "$TARGET" | sed 's/^#* *//')
echo "已更新 $TARGET：$count 张证书"
echo "$date"
