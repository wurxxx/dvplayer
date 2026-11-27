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
APP="$PWD/build/DV Player.app"
EXE="$APP/Contents/MacOS/DV Player"
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

cp "$BIN/DvPlayer" "$EXE"
cp Info.plist "$APP/Contents/Info.plist"

# 弹幕（弹弹play）凭据：打包时注入 Info.plist，仓库和 settings.json 里都不放。
# 优先级：环境变量 > 本地密钥文件（默认 ~/.config/dvplayer/danmaku.env，
# 可用 DVPLAYER_DANMAKU_ENV 换路径）。文件格式：
#   DANMAKU_APP_ID=xxx
#   DANMAKU_APP_SECRET=yyy
# 找不到就注入空值：这个包不带弹幕（开发构建就是这样），运行时不联网。
DANMAKU_ENV="${DVPLAYER_DANMAKU_ENV:-$HOME/.config/dvplayer/danmaku.env}"
danmaku_value() {
    local key="$1"
    [[ -f "$DANMAKU_ENV" ]] || { echo ""; return 0; }
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$DANMAKU_ENV" \
        | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//' || true
}
DANMAKU_APP_ID="${DVPLAYER_DANMAKU_APP_ID:-$(danmaku_value DANMAKU_APP_ID)}"
DANMAKU_APP_SECRET="${DVPLAYER_DANMAKU_APP_SECRET:-$(danmaku_value DANMAKU_APP_SECRET)}"

# Trakt：同样的注入方式，文件格式
#   TRAKT_CLIENT_ID=xxx
#   TRAKT_CLIENT_SECRET=yyy
# 设置页里填的值优先于这里的默认值。
TRAKT_ENV="${DVPLAYER_TRAKT_ENV:-$HOME/.config/dvplayer/trakt.env}"
trakt_value() {
    local key="$1"
    [[ -f "$TRAKT_ENV" ]] || { echo ""; return 0; }
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$TRAKT_ENV" \
        | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//' || true
}
TRAKT_CLIENT_ID="${DVPLAYER_TRAKT_CLIENT_ID:-$(trakt_value TRAKT_CLIENT_ID)}"
TRAKT_CLIENT_SECRET="${DVPLAYER_TRAKT_CLIENT_SECRET:-$(trakt_value TRAKT_CLIENT_SECRET)}"

python3 - "$APP/Contents/Info.plist" "$DANMAKU_APP_ID" "$DANMAKU_APP_SECRET" \
    "$TRAKT_CLIENT_ID" "$TRAKT_CLIENT_SECRET" <<'PLIST'
import plistlib, sys

path, app_id, secret, trakt_id, trakt_secret = sys.argv[1:6]
with open(path, "rb") as handle:
    info = plistlib.load(handle)
info["DVDanmakuAppId"] = app_id
info["DVDanmakuAppSecret"] = secret
info["DVTraktClientId"] = trakt_id
info["DVTraktClientSecret"] = trakt_secret
with open(path, "wb") as handle:
    plistlib.dump(info, handle)
PLIST
if [[ -n "$DANMAKU_APP_ID" ]]; then
    echo "-- 弹幕凭据：已注入（AppId ${DANMAKU_APP_ID:0:4}…）"
else
    echo "-- 弹幕凭据：没有找到 ${DANMAKU_ENV}，这个包不带弹幕" >&2
fi
if [[ -n "$TRAKT_CLIENT_ID" ]]; then
    echo "-- Trakt 凭据：已注入（Client ${TRAKT_CLIENT_ID:0:4}…）"
else
    echo "-- Trakt 凭据：没有找到 ${TRAKT_ENV}，设置页里可以自己填" >&2
fi
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
    "$EXE"

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
)
# jpeg：版本号会跟着 Homebrew 的 formula 变（Intel 上是 libjpeg.8/9，arm64
# runner 上是另一版），写死具体版本号必然有一边落空，用 glob 取。
for jp in "$BREW_PREFIX"/opt/jpeg/lib/libjpeg.*.dylib; do
    [[ -f "$jp" ]] && HOMEBREW_DEPS+=("$jp")
done
# little-cms2：mpv 的 `lcms` 是 auto 检测，CI runner 预装了它，编出来的 libmpv
# 就会链接 liblcms2（本机没装就不会）。不补进包里，发布包在用户机器上启动就
# 报 `Library not loaded: @rpath/liblcms2.2.dylib`。ABI 版本号会变，用 glob 取。
for lcms in "$BREW_PREFIX"/opt/little-cms2/lib/liblcms2.*.dylib; do
    [[ -f "$lcms" ]] && HOMEBREW_DEPS+=("$lcms")
done
for dep in "${HOMEBREW_DEPS[@]}"; do
    if [[ -f "$dep" ]]; then
        cp "$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$dep")" \
            "$FRAMEWORKS/"
    else
        echo "警告：缺少 ${dep}（libass / libmpv 的依赖，字幕或解码可能不可用）" >&2
    fi
done

# 依赖是链式的：freetype → libpng、harfbuzz → graphite2 + glib、glib →
# libintl + pcre2 … 硬编码清单永远追不上（先是漏了 lcms2，补上 lcms2 又发现
# 漏了 png / graphite2 / glib）。这里循环扫描包里每个 dylib 的依赖，源文件
# 存在就拷进来，直到没有新增。
#
# 两种依赖写法都要处理：
#   1) 绝对路径（Homebrew 的库常见）—— 直接按路径拷；
#   2) @rpath/xxx —— 先拿依赖方自己的 LC_RPATH 去找；找不到再在已知目录
#      里兜底搜索。arm64 runner 上 libbrotlidec 就是这种：它自己被绝对路径
#      拷进来，依赖的 libbrotlicommon 写成 @rpath，而 Apple Silicon 的
#      Homebrew 库自己**不带** LC_RPATH（rpath 是消费方声明的），只看它
#      自己的 rpath 会一无所获。漏掉的话发布包一启动就报
#      Library not loaded: @rpath/libbrotlicommon.1.dylib。
find_lib() {
    local base="$1" stem dir hit
    stem="${base%.dylib}"
    for dir in "$FRAMEWORKS" "$PREFIX_LIB" "$BREW_PREFIX/lib" "$BREW_PREFIX"/opt/*/lib; do
        [[ -e "$dir/$base" ]] && { echo "$dir/$base"; return 0; }
        # 只有带完整版本号的文件、没有软链时也能命中。
        for hit in "$dir/$stem"*.dylib; do
            [[ -e "$hit" ]] && { echo "$hit"; return 0; }
        done
    done
    return 1
}

for round in 1 2 3 4 5 6; do
    added=0
    for file in "$FRAMEWORKS"/*.dylib; do
        # 这个文件自己声明的 rpath 目录（可能有多个）。
        rp_list=$(otool -l "$file" | awk '/LC_RPATH/{f=1;next} f&&/path /{print $2; f=0}')
        while read -r dep; do
            [[ -z "$dep" ]] && continue
            case "$dep" in
                @rpath/*)
                    base="${dep#@rpath/}"
                    found=""
                    while IFS= read -r rp; do
                        [[ -z "$rp" ]] && continue
                        [[ -f "$rp/$base" ]] || continue
                        found="$rp/$base"
                        break
                    done <<< "$rp_list"
                    [[ -z "$found" ]] && found="$(find_lib "$base" || true)"
                    if [[ -z "$found" ]]; then
                        echo "警告：找不到 @rpath 依赖 ${base}（$(basename "$file") 需要）" >&2
                        continue
                    fi
                    real="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$found")"
                    realbase="$(basename "$real")"
                    if [[ ! -f "$FRAMEWORKS/$realbase" ]]; then
                        cp "$real" "$FRAMEWORKS/"
                        echo "  补齐依赖 ${realbase}（@rpath）"
                        added=1
                    fi
                    continue ;;
                @loader_path/*|@executable_path/*|/usr/lib/*|/System/*) continue ;;
            esac
            [[ -f "$dep" ]] || continue
            real="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$dep")"
            realbase="$(basename "$real")"
            if [[ ! -f "$FRAMEWORKS/$realbase" ]]; then
                cp "$real" "$FRAMEWORKS/"
                echo "  补齐依赖 $realbase"
                added=1
            fi
        done < <(otool -L "$file" | tail -n +2 | awk '{print $1}')
    done
    [[ $added -eq 0 ]] && break
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

for file in "$FRAMEWORKS"/*.dylib "$EXE"; do
    install_name_tool -id "@rpath/$(basename "$file")" "$file" 2>/dev/null || true
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$file" 2>/dev/null || true

    while read -r dep; do
        [[ -z "$dep" ]] && continue
        # @rpath 的也要改：包里放的是带完整版本号的文件名
        # （libbrotlicommon.1.2.1.dylib），依赖写的是 libbrotlicommon.1.dylib，
        # 不归一化的话发布包自检会认为缺文件。
        install_name_tool -change "$dep" "@rpath/$(real_name "$(basename "$dep")")" "$file"
    done < <(otool -L "$file" | tail -n +2 | awk '{print $1}' \
             | grep -E "^(@rpath/|$BREW_PREFIX/|$PREFIX_LIB/)" || true)
done

# 发布包自检：改写后所有依赖都应该是 @rpath/xxx 或系统库，@rpath 的目标必须
# 真的在 Frameworks 里。漏一个，到用户机器上就是
#   Library not loaded: @rpath/xxx.dylib
# 而这种错误只在冒烟测试（或用户那边）才暴露，日志里只有一句 dyld 报错。
# 这里提前失败，并指出是谁依赖它。
missing=0
for file in "$FRAMEWORKS"/*.dylib "$EXE"; do
    while read -r dep; do
        [[ -z "$dep" ]] && continue
        case "$dep" in
            @rpath/*)
                base="${dep#@rpath/}"
                if [[ ! -f "$FRAMEWORKS/$base" ]]; then
                    echo "错误：$(basename "$file") 依赖 ${dep}，但 Frameworks 里没有 ${base}" >&2
                    missing=1
                fi
                ;;
            @loader_path/*|@executable_path/*|/usr/lib/*|/System/*) ;;
            *)
                echo "错误：$(basename "$file") 还有没改写的绝对路径依赖：$dep" >&2
                missing=1
                ;;
        esac
    done < <(otool -L "$file" | tail -n +2 | awk '{print $1}')
done
if [[ $missing -ne 0 ]]; then
    echo "打包中止：发布包缺依赖，见上面的错误。" >&2
    exit 1
fi

# 签名：必须自内向外——先 Frameworks 里的 dylib，再整个 .app。
# 直接 `codesign "DV Player.app"` 会报 `code object is not signed at all`
# （内层 dylib 还没签），以前用 `|| true` 吞掉了，结果成品其实没签。
IDENTITY="${SIGN_IDENTITY:--}"
echo "-- 签名：${IDENTITY}"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
    "$FRAMEWORKS/"*.dylib
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP"

echo "已生成：$APP"
