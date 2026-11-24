#!/usr/bin/env bash
# 打 macOS 发布产物：
#   - DMG 安装镜像   out/release/DvPlayer-<version>-macos-<arch>.dmg
#   - 便携 zip       out/release/DvPlayer-<version>-macos-<arch>.zip
#
# 两个产物用的是同一个 build.sh 编出来的 .app（内含 libmpv 与全部依赖）。
#
# 版本号以 Info.plist 的 CFBundleShortVersionString 为准，发布时和
# core/Cargo.toml、apps/windows/DvPlayer/DvPlayer.csproj 一起改。
#
# 用法：
#   apps/macos/packaging/build-release.sh              # 编译 + 打包
#   apps/macos/packaging/build-release.sh -SkipBuild   # 复用现有 .app
#   apps/macos/packaging/build-release.sh -SkipDmg     # 只出 zip
#   apps/macos/packaging/build-release.sh -Version 0.1.5   # 覆盖版本号（只影响产物名）
#
# 签名：默认 ad-hoc（codesign --sign -）。没有公证证书，别人首次打开要
# 右键「打开」或在「系统设置 → 隐私与安全性」里放行。
# 有开发者证书时用 SIGN_IDENTITY="Developer ID Application: xxx" 指定，
# 再自己跑 notarytool（脚本不碰凭据）。
set -euo pipefail

cd "$(dirname "$0")"
APPDIR="$(cd .. && pwd)"          # apps/macos
ROOT="$(cd ../../.. && pwd)"
APP="$APPDIR/DvPlayer/build/DvPlayer.app"
PLIST="$APPDIR/DvPlayer/Info.plist"

SKIP_BUILD=0
SKIP_DMG=0
SKIP_ZIP=0
VERSION=""
OUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -SkipBuild) SKIP_BUILD=1; shift ;;
        -SkipDmg)   SKIP_DMG=1; shift ;;
        -SkipZip)   SKIP_ZIP=1; shift ;;
        -Version)   VERSION="$2"; shift 2 ;;
        -OutputDir) OUT_DIR="$2"; shift 2 ;;
        -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 1 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
fi
ARCH="$(uname -m)"
OUT="${OUT_DIR:-$ROOT/out/release}"
mkdir -p "$OUT"

echo "== DVPlayer macOS release $VERSION ($ARCH) =="

# —— 1. 编译 ——
if [[ $SKIP_BUILD -eq 0 ]]; then
    "$APPDIR/DvPlayer/build.sh"
fi
if [[ ! -d "$APP" ]]; then
    echo "缺少 ${APP}，先跑 build.sh" >&2
    exit 1
fi

# 版本号写进包里的 Info.plist，别让产物名和包内版本对不上。
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" \
        "$APP/Contents/Info.plist"

# —— 2. 签名 ——
# 必须自内向外签：先 Frameworks 里的 dylib，再整个 .app。先签外层会让
# 内层改动失效（`code object is not signed at all`）。
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "-- 签名：${SIGN_IDENTITY}"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
    "$APP/Contents/Frameworks/"*.dylib
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# —— 3. 打包 ——
BASE="DvPlayer-$VERSION-macos-$ARCH"

# 两个产物都要一份叫「DV Player.app」的拷贝（和 Finder / Dock 显示名一致），
# 统一在退出时清掉。
STAGES=()
cleanup() { for d in "${STAGES[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done; }
trap cleanup EXIT

stage_app() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/dvplayer-stage.XXXXXX")"
    STAGES+=("$dir")
    ditto "$APP" "$dir/DV Player.app"
    printf '%s' "$dir"
}

# zip：`ditto` 才能保住符号链接、扩展属性和代码签名（zip 命令会破坏签名）。
if [[ $SKIP_ZIP -eq 0 ]]; then
    ZIP="$OUT/$BASE.zip"
    rm -f "$ZIP"
    echo "-- zip → $ZIP"
    ZDIR="$(stage_app)"
    ditto -c -k --sequesterRsrc --keepParent "$ZDIR/DV Player.app" "$ZIP"
fi

# DMG：.app + 指向 /Applications 的软链，拖进去就是安装。
if [[ $SKIP_DMG -eq 0 ]]; then
    DMG="$OUT/$BASE.dmg"
    echo "-- dmg → $DMG"
    DDIR="$(stage_app)"
    ln -s /Applications "$DDIR/Applications"

    rm -f "$DMG"
    hdiutil create -quiet -volname "DV Player $VERSION" \
        -srcfolder "$DDIR" -ov -format UDZO "$DMG"
fi

echo
echo "完成："
[[ $SKIP_ZIP -eq 0 ]] && ls -lh "$OUT/$BASE.zip"
[[ $SKIP_DMG -eq 0 ]] && ls -lh "$OUT/$BASE.dmg"
exit 0
