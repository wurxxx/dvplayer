#!/usr/bin/env bash
# 编 macOS 壳，并打成能双击的 .app。
#
# 依赖仓库里现成的东西：
#   core/target/release/libdvplayer_media.dylib   （cargo build -p dvplayer-media --release）
#   prefix-vk/bin/mpv、prefix-vk/lib、prefix/lib   （scripts/build-vk-macos.sh + build-deps-macos.sh）
# 播放器是 mpv 子进程 + gpu-next + Vulkan/macvk，依赖一起打进 Contents/Frameworks。
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
# 品牌图：侧栏左上角和 Windows 的 exe 图标用同一份位图。
cp "$ROOT/assets/branding/DvPlayer-256.png" "$APP/Contents/Resources/"

# 核心 dylib 的 install name 是 cargo 的构建目录，不存在于运行期，
# 拷进包里并统一改成 @rpath 引用。
cp "$CORE_LIB" "$APP/Contents/Frameworks/"
CORE_ID="$(otool -D "$CORE_LIB" | tail -1)"
install_name_tool -id @rpath/libdvplayer_media.dylib \
    "$APP/Contents/Frameworks/libdvplayer_media.dylib"
install_name_tool -change "$CORE_ID" @rpath/libdvplayer_media.dylib \
    "$APP/Contents/MacOS/DvPlayer"

# 播放器：mpv 以子进程运行，需要它和它的依赖一起进包。
#   prefix/lib     libass / libav* / libsw*（解码）
#   prefix-vk/lib  libplacebo（带 Vulkan 后端）+ Vulkan loader + MoltenVK
# 这些 dylib 的 install name 都是本机绝对路径，统一改成 @rpath/<真实文件名>，
# 否则换台机器就找不到。
MPV_LIB="$ROOT/prefix/lib"
VK_LIB="$ROOT/prefix-vk/lib"
MPV_BIN="$ROOT/prefix-vk/bin/mpv"

if [[ ! -x "$MPV_BIN" ]]; then
    echo "缺少播放器：$MPV_BIN" >&2
    echo "先跑 scripts/build-vk-macos.sh" >&2
    exit 1
fi

# prefix/lib：只拷真实文件（`libavcodec.63.dylib` 是软链，真实文件带完整版本号）。
for lib in "$MPV_LIB"/*.dylib; do
    [[ -L "$lib" ]] && continue
    [[ "$(basename "$lib")" == "libmpv.2.dylib" ]] && continue   # 不再用 render API
    cp "$lib" "$APP/Contents/Frameworks/"
done

# prefix-vk：libplacebo 用 VK 版；loader 与 MoltenVK 是 DV 路径的必需品。
cp "$VK_LIB/libplacebo.387.dylib" "$APP/Contents/Frameworks/"
cp "$VK_LIB/libMoltenVK.dylib" "$APP/Contents/Frameworks/"
VK_LOADER="$(python3 -c 'import os,sys; print(os.path.basename(os.path.realpath(sys.argv[1])))' "$VK_LIB/libvulkan.1.dylib")"
cp "$VK_LIB/$VK_LOADER" "$APP/Contents/Frameworks/"

# mpv 自己 + ICD 配置（library_path 用相对路径，跟着 .app 走）。
cp "$MPV_BIN" "$APP/Contents/Frameworks/mpv"
python3 - "$ROOT/prefix-vk/share/vulkan/icd.d/MoltenVK_icd.json" \
         "$APP/Contents/Frameworks/MoltenVK_icd.json" <<'ICD'
import json, sys
source, target = sys.argv[1], sys.argv[2]
data = json.load(open(source))
data["ICD"]["library_path"] = "libMoltenVK.dylib"
json.dump(data, open(target, "w"), indent=4)
ICD

# 依赖名 -> 包里的真实文件名（`libavcodec.63.dylib` -> `libavcodec.63.1.102.dylib`）。
# 两个目录都要查：libplacebo / loader 只在 prefix-vk 里。
real_name() {
    local base="$1" dir
    for dir in "$VK_LIB" "$MPV_LIB"; do
        if [[ -e "$dir/$base" ]]; then
            python3 -c 'import os,sys; print(os.path.basename(os.path.realpath(sys.argv[1])))' \
                "$dir/$base"
            return
        fi
    done
    echo "$base"
}

for file in "$APP/Contents/Frameworks"/*.dylib "$APP/Contents/Frameworks/mpv" \
            "$APP/Contents/MacOS/DvPlayer"; do
    install_name_tool -id "@rpath/$(basename "$file")" "$file" 2>/dev/null || true
    # mpv 在 Frameworks 目录里，@executable_path 就是这一层。
    install_name_tool -add_rpath "@executable_path" "$file" 2>/dev/null || true

    while read -r dep; do
        [[ -z "$dep" ]] && continue
        install_name_tool -change "$dep" "@rpath/$(real_name "$(basename "$dep")")" "$file"
    done < <(otool -L "$file" | tail -n +2 | awk '{print $1}' \
             | grep -E "^($MPV_LIB|$VK_LIB)/" || true)

    # libplacebo 直接引用 @rpath/libvulkan.1.dylib；包里只有带完整版本号的那份。
    install_name_tool -change "@rpath/libvulkan.1.dylib" "@rpath/$VK_LOADER" "$file" 2>/dev/null || true
done

codesign --force --sign - "$APP/Contents/Frameworks/mpv" >/dev/null 2>&1 || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "已生成：$APP"
