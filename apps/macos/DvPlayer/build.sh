#!/usr/bin/env bash
# 编 macOS 壳，并打成能双击的 .app。
#
# 依赖仓库里现成的东西：
#   core/target/release/libdvplayer_media.dylib   （cargo build -p dvplayer-media --release）
#   prefix/lib/libmpv.2.dylib + libplacebo/libass/ffmpeg 系列
#       （scripts/build-deps-macos.sh；mpv 用 scripts/build-mpv-macos.sh）
#
# 播放器是**进程内 libmpv**（render API + gpu-next render backend，跑 OpenGL），
# 视频画进我们自己的窗口，所以要把 libmpv 和它的依赖一起打进 Contents/Frameworks。
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(cd ../../.. && pwd)"
CORE_LIB="$ROOT/core/target/release/libdvplayer_media.dylib"
PREFIX_LIB="$ROOT/prefix/lib"
APP="$PWD/build/DvPlayer.app"
FRAMEWORKS="$APP/Contents/Frameworks"

if [[ ! -f "$CORE_LIB" ]]; then
    echo "缺少共享核心：$CORE_LIB" >&2
    echo "先在仓库根跑：cargo build -p dvplayer-media --release" >&2
    exit 1
fi

if [[ ! -f "$PREFIX_LIB/libmpv.2.dylib" ]]; then
    echo "缺少 libmpv：$PREFIX_LIB/libmpv.2.dylib" >&2
    echo "先跑 scripts/build-deps-macos.sh" >&2
    exit 1
fi

# SwiftPM 的 module map 用绝对路径 include 头文件，换机器时要先改这一行。
BRIDGE="Sources/MpvC/include/mpv_bridge.h"
if ! grep -q "\"$ROOT/prefix/include/mpv/client.h\"" "$BRIDGE"; then
    echo "更新 $BRIDGE 里的头文件路径（仓库挪过位置）"
    python3 - "$BRIDGE" "$ROOT" <<'FIX'
import re, sys
path, root = sys.argv[1], sys.argv[2]
text = open(path).read()
text = re.sub(r'#include "[^"]*/prefix/include/mpv/([a-z_]+\.h)"',
              lambda m: f'#include "{root}/prefix/include/mpv/{m.group(1)}"', text)
open(path, "w").write(text)
FIX
fi

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$FRAMEWORKS" "$APP/Contents/Resources"

cp "$BIN/DvPlayer" "$APP/Contents/MacOS/DvPlayer"
cp Info.plist "$APP/Contents/Info.plist"
# 应用图标：Dock / Finder 读 Info.plist 的 CFBundleIconFile（AppIcon.icns），
# 由 scripts/make-icon.py 生成。
cp "$ROOT/assets/branding/AppIcon.icns" "$APP/Contents/Resources/"
# 品牌图：侧栏左上角和 Windows 的 exe 图标用同一份位图。
cp "$ROOT/assets/branding/DvPlayer-256.png" "$APP/Contents/Resources/"

# 服务器图标（飞牛 / Emby / Jellyfin / 本地 / SMB / NFS / WebDAV）：
# 和 Windows 工程里同一份图，scripts/make-source-icons.py 生成。
mkdir -p "$APP/Contents/Resources/sources"
cp "$ROOT/assets/sources/"*.png "$APP/Contents/Resources/sources/"

# 核心 dylib 的 install name 是 cargo 的构建目录，不存在于运行期，
# 拷进包里并统一改成 @rpath 引用。
cp "$CORE_LIB" "$FRAMEWORKS/"
CORE_ID="$(otool -D "$CORE_LIB" | tail -1)"
install_name_tool -id @rpath/libdvplayer_media.dylib \
    "$FRAMEWORKS/libdvplayer_media.dylib"
install_name_tool -change "$CORE_ID" @rpath/libdvplayer_media.dylib \
    "$APP/Contents/MacOS/DvPlayer"

# libmpv 和它的依赖。
# prefix/lib 里只拷真实文件（`libavcodec.63.dylib` 是软链，真实文件带完整版本号）。
for lib in "$PREFIX_LIB"/*.dylib; do
    [[ -L "$lib" ]] && continue
    case "$(basename "$lib")" in
        *.bak-*) continue ;;
    esac
    cp "$lib" "$FRAMEWORKS/"
done

# libass / libmpv 还依赖 Homebrew 的几个库（fribidi / harfbuzz / fontconfig /
# freetype / jpeg）。它们在别人机器上不一定有，而且路径是本机的，一起拷进来。
#
# 路径不能写死 /usr/local：Intel Mac 的 Homebrew 在 /usr/local，
# Apple Silicon 在 /opt/homebrew。用 brew --prefix 问出来，CI 上才编得过。
BREW_PREFIX="${BREW_PREFIX:-$(brew --prefix 2>/dev/null || echo /usr/local)}"
HOMEBREW_DEPS=(
    "$BREW_PREFIX/opt/fribidi/lib/libfribidi.0.dylib"
    "$BREW_PREFIX/opt/harfbuzz/lib/libharfbuzz.0.dylib"
    "$BREW_PREFIX/opt/fontconfig/lib/libfontconfig.1.dylib"
    "$BREW_PREFIX/opt/freetype/lib/libfreetype.6.dylib"
    "$BREW_PREFIX/opt/jpeg/lib/libjpeg.9.dylib"
)
for dep in "${HOMEBREW_DEPS[@]}"; do
    if [[ -f "$dep" ]]; then
        cp "$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$dep")" \
            "$FRAMEWORKS/"
    else
        echo "警告：缺少 ${dep}（libass / libmpv 的依赖，字幕或解码可能不可用）" >&2
    fi
done

# 依赖名 -> 包里的真实文件名（`libavcodec.63.dylib` -> `libavcodec.63.1.102.dylib`）。
real_name() {
    local base="$1" dir
    for dir in "$FRAMEWORKS" "$PREFIX_LIB" "$BREW_PREFIX"/opt/*/lib; do
        if [[ -e "$dir/$base" ]]; then
            python3 -c 'import os,sys;print(os.path.basename(os.path.realpath(sys.argv[1])))' \
                "$dir/$base"
            return
        fi
    done
    echo "$base"
}

for file in "$FRAMEWORKS"/*.dylib "$APP/Contents/MacOS/DvPlayer"; do
    install_name_tool -id "@rpath/$(basename "$file")" "$file" 2>/dev/null || true
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$file" 2>/dev/null || true

    while read -r dep; do
        [[ -z "$dep" ]] && continue
        install_name_tool -change "$dep" "@rpath/$(real_name "$(basename "$dep")")" "$file"
    done < <(otool -L "$file" | tail -n +2 | awk '{print $1}' \
             | grep -E "^($BREW_PREFIX/|$PREFIX_LIB/)" || true)
done

# 签名：必须自内向外——先 Frameworks 里的 dylib，再整个 .app。
# 直接 `codesign DvPlayer.app` 会报 `code object is not signed at all`
# （内层 dylib 还没签），以前用 `|| true` 吞掉了，结果成品其实没签。
IDENTITY="${SIGN_IDENTITY:--}"
echo "-- 签名：${IDENTITY}"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
    "$FRAMEWORKS/"*.dylib
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP"

echo "已生成：$APP"
