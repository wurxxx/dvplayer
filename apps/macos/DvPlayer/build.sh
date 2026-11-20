#!/usr/bin/env bash
# 编 macOS 壳，并打成能双击的 .app。
#
# 依赖仓库里现成的东西：
#   core/target/release/libdvplayer_media.dylib   （cargo build -p dvplayer-media --release）
#   prefix/lib/libmpv.2.dylib                      （scripts/build-deps-macos.sh）
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(cd ../../.. && pwd)"
CORE_LIB="$ROOT/core/target/release/libdvplayer_media.dylib"
APP="$PWD/build/DvPlayer.app"

if [[ ! -f "$CORE_LIB" ]]; then
    echo "缺少共享核心：$CORE_LIB" >&2
    echo "先在仓库根跑：cargo build -p dvplayer-media --release" >&2
    exit 1
fi

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp "$BIN/DvPlayer" "$APP/Contents/MacOS/DvPlayer"
cp Info.plist "$APP/Contents/Info.plist"

# 核心 dylib 的 install name 是 cargo 的构建目录，不存在于运行期，
# 拷进包里并统一改成 @rpath 引用。
cp "$CORE_LIB" "$APP/Contents/Frameworks/"
CORE_ID="$(otool -D "$CORE_LIB" | tail -1)"
install_name_tool -id @rpath/libdvplayer_media.dylib \
    "$APP/Contents/Frameworks/libdvplayer_media.dylib"
install_name_tool -change "$CORE_ID" @rpath/libdvplayer_media.dylib \
    "$APP/Contents/MacOS/DvPlayer"

# 播放页落地后会用到 libmpv：先一起带上，省得到时又改打包脚本。
if [[ -f "$ROOT/prefix/lib/libmpv.2.dylib" ]]; then
    cp "$ROOT/prefix/lib/libmpv.2.dylib" "$APP/Contents/Frameworks/"
    install_name_tool -id @rpath/libmpv.2.dylib \
        "$APP/Contents/Frameworks/libmpv.2.dylib"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "已生成：$APP"
