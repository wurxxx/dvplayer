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

# libmpv 和它的依赖（libass / libav* / libplacebo / libsw*）。
# prefix/lib 里这些 dylib 的 install name 都是本机绝对路径，拷进包后统一改成
# @rpath/<名字>，否则换台机器就找不到。
MPV_LIB="$ROOT/prefix/lib"
if [[ -f "$MPV_LIB/libmpv.2.dylib" ]]; then
    # prefix/lib 里既有 libfoo.dylib 这种副本，也有 libfoo.9.dylib -> libfoo.9.0.1.dylib 的软链。
    # 只拷真实文件（软链不拷），引用名再映射到真实名。
    for lib in "$MPV_LIB"/*.dylib; do
        [[ -L "$lib" ]] && continue
        cp "$lib" "$APP/Contents/Frameworks/"
    done

    # 依赖名 -> 包里的真实文件名（`libavcodec.63.dylib` -> `libavcodec.63.1.102.dylib`）。
    real_name() {
        python3 -c 'import os,sys; print(os.path.basename(os.path.realpath(sys.argv[1])))' \
            "$MPV_LIB/$1"
    }

    for file in "$APP/Contents/Frameworks"/*.dylib "$APP/Contents/MacOS/DvPlayer"; do
        install_name_tool -id "@rpath/$(basename "$file")" "$file" 2>/dev/null || true
        while read -r dep; do
            [[ -z "$dep" ]] && continue
            install_name_tool -change "$dep" "@rpath/$(real_name "$(basename "$dep")")" "$file"
        done < <(otool -L "$file" | tail -n +2 | awk '{print $1}' | grep "^$MPV_LIB/" || true)
    done
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "已生成：$APP"
