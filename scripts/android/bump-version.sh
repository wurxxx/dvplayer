#!/usr/bin/env bash
# 改 Android 的版本号（手机端和 TV 端各一条线，桌面端又一条）。
#
#   scripts/android/bump-version.sh phone 0.1.1
#   scripts/android/bump-version.sh tv    0.2.0
#
# 只改 apps/android/gradle.properties 里的默认值；发版时 CI 还会用标签覆盖一次，
# 两边保持一致才不会出现「本地装的 0.1.0、Release 上写着 0.1.1」。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILE="$ROOT/apps/android/gradle.properties"

APP=${1:?用法: bump-version.sh phone|tv <大>.<小>.<补丁>}
VERSION=${2:?用法: bump-version.sh phone|tv <大>.<小>.<补丁>}

case "$APP" in
    phone | tv) ;;
    *) echo "第一个参数只能是 phone 或 tv。" >&2; exit 2 ;;
esac

if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "版本号要写成 0.1.1 这样。" >&2
    exit 2
fi

# versionCode 必须递增：大*10000 + 小*100 + 补丁（0.1.0 → 100）。
CODE=$(printf '%s' "$VERSION" | awk -F. '{ printf "%d", $1 * 10000 + $2 * 100 + $3 }')

OLD=$(grep "^dvplayer.$APP.versionCode=" "$FILE" | cut -d= -f2)
if [ -n "$OLD" ] && [ "$CODE" -le "$OLD" ]; then
    echo "versionCode 要递增：$OLD → $CODE 不会让安装器认成升级。" >&2
    exit 2
fi

sed -i.bak \
    -e "s/^dvplayer\.$APP\.versionName=.*/dvplayer.$APP.versionName=$VERSION/" \
    -e "s/^dvplayer\.$APP\.versionCode=.*/dvplayer.$APP.versionCode=$CODE/" \
    "$FILE"
rm -f "$FILE.bak"

echo "Android ${APP} 版本：${VERSION}（versionCode ${CODE}）"
echo
echo "接着："
echo "  git add apps/android/gradle.properties && git commit -m '发布 Android $APP $VERSION'"
echo "  git push github master"
echo "  git tag android-$APP-v$VERSION && git push github android-$APP-v$VERSION"
