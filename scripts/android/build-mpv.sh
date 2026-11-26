#!/usr/bin/env bash
# 构建 Android 版 libmpv。
#
# 许可：FFmpeg 关 GPL（--disable-gpl / --disable-version3），mpv 用 -Dgpl=false，
#       不链 libsmbclient；产物按 ADR-0014 的 LGPL 口径。
#
# 形态：所有依赖编成静态库，只产出一个共享 libmpv.so（不出现 libavcodec.so.62
#       这种 Android 装不进 APK 的版本化 soname）。FFmpeg 的静态库带 -fPIC。
#
# 依赖：FFmpeg n9.0.2 / libplacebo v7.387.0 / libass 0.17.4 / freetype 2.15.0 /
#       fribidi 1.0.18 / harfbuzz 15.2.0 / libunibreak 8.0.1 / fontconfig 2.18.4 /
#       libxml2 2.15.4 / libbluray 1.5.0 / libudfread 1.2.0
#
# 用法：
#   scripts/android/build-mpv.sh                  # x86_64 + arm64
#   ARCHES=arm64 scripts/android/build-mpv.sh
#   scripts/android/build-mpv.sh --clean          # 清掉两个 arch 的 build/prefix
#   scripts/android/build-mpv.sh --stage          # 顺带拷进 core/src/main/jniLibs
#
# 产物：build/android-mpv/<arch>/prefix/lib/libmpv.so
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=env.sh
source "$ROOT/scripts/android/env.sh"

WORK=${WORK:-$ROOT/build/android-mpv}
SRC=$WORK/src
DL=$WORK/dl
API=${API:-26}
ARCHES=${ARCHES:-"x86_64 arm64"}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64"
SYSROOT="$TOOLCHAIN/sysroot"
CLANG_VERSION=$(ls "$TOOLCHAIN/lib/clang" | sort -V | tail -1)

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { echo "!! $*" >&2; exit 1; }

clean=0
stage=0
while [ $# -gt 0 ]; do
    case "$1" in
        --clean) clean=1 ;;
        --stage) stage=1 ;;
        --arch)
            shift
            ARCHES=$1
            ;;
        -h | --help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            die "未知参数：$1"
            ;;
    esac
    shift
done

if [ "$clean" -eq 1 ]; then
    for a in $ARCHES; do rm -rf "${WORK:?}/$a"; done
fi

mkdir -p "$SRC" "$DL"

# ---------------------------------------------------------------- 源码准备
download() { # url dest
    local url=$1 dest=$2
    [ -f "$dest" ] && return 0
    case "$url" in
        https://github.com/*)
            if [ -n "${DVPLAYER_GH_PROXY:-}" ]; then
                url="${DVPLAYER_GH_PROXY%/}/$url"
            fi
            ;;
    esac
    log "下载 $(basename "$dest")"
    curl -L --fail -C - --retry 5 --retry-delay 2 --retry-all-errors \
        -sS -o "$dest" "$url"
}

ensure_tar() { # name tarball url
    local name=$1 tarball=$2 url=$3
    [ -d "$SRC/$name" ] && return 0
    download "$url" "$DL/$tarball"
    mkdir -p "$SRC/$name"
    tar -xf "$DL/$tarball" -C "$SRC/$name" --strip-components=1
}

ensure_tar libxml2 libxml2-2.15.4.tar.xz \
    https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.4.tar.xz
ensure_tar freetype freetype-2.15.0.tar.xz \
    https://download.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz
ensure_tar fribidi fribidi-1.0.18.tar.xz \
    https://github.com/fribidi/fribidi/releases/download/v1.0.18/fribidi-1.0.18.tar.xz
ensure_tar harfbuzz harfbuzz-15.2.0.tar.xz \
    https://github.com/harfbuzz/harfbuzz/releases/download/15.2.0/harfbuzz-15.2.0.tar.xz
ensure_tar libunibreak libunibreak-8.0.1.tar.gz \
    https://github.com/adah1972/libunibreak/releases/download/libunibreak_8_0_1/libunibreak-8.0.1.tar.gz
ensure_tar fontconfig fontconfig-2.18.4.tar.gz \
    https://gitlab.freedesktop.org/fontconfig/fontconfig/-/archive/2.18.4/fontconfig-2.18.4.tar.gz
ensure_tar libudfread libudfread-1.2.0.tar.xz \
    https://download.videolan.org/pub/videolan/libudfread/libudfread-1.2.0.tar.xz
ensure_tar libbluray libbluray-1.5.0.tar.xz \
    https://download.videolan.org/pub/videolan/libbluray/1.5.0/libbluray-1.5.0.tar.xz

# 大件一律用干净 tarball。桌面端的 build/src/* 是 in-tree 配置过的，
# autotools 会拒绝在「已经配置过的源码目录」外面再 configure
# （libass / FFmpeg 都踩这个），所以不走复用。
ensure_tar ffmpeg n9.0.2.tar.gz \
    https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n9.0.2.tar.gz
ensure_tar libass libass-0.17.4.tar.gz \
    https://github.com/libass/libass/releases/download/0.17.4/libass-0.17.4.tar.gz
ensure_tar mpv v0.42.0.tar.gz \
    https://github.com/mpv-player/mpv/archive/refs/tags/v0.42.0.tar.gz

FFMPEG_SRC=${FFMPEG_SRC:-$SRC/ffmpeg}
LIBASS_SRC=${LIBASS_SRC:-$SRC/libass}
MPV_SRC=${MPV_SRC:-$SRC/mpv}
# libplacebo 需要 submodule（glad / fast_float / jinja），GitHub 源码包不带，
# 只能 git clone --recursive；桌面端已经拉过就直接用。
if [ -z "${LIBPLACEBO_SRC:-}" ]; then
    if [ -d "$ROOT/build/src/libplacebo/3rdparty/glad" ]; then
        LIBPLACEBO_SRC="$ROOT/build/src/libplacebo"
    else
        LIBPLACEBO_SRC="$SRC/libplacebo"
        if [ ! -d "$LIBPLACEBO_SRC" ]; then
            log "clone libplacebo（含 submodule）"
            git clone --recursive --depth 1 -b v7.387.0 \
                https://github.com/haasn/libplacebo "$LIBPLACEBO_SRC"
        fi
    fi
fi

for d in "$FFMPEG_SRC" "$LIBASS_SRC" "$MPV_SRC" "$LIBPLACEBO_SRC"; do
    [ -d "$d" ] || die "缺少源码目录：$d"
done

# ---------------------------------------------------------------- 工具函数
ARCH=
ARCH_TRIPLE=
PREFIX=
BUILD=
CROSS=
CC=
CXX=
AR=
RANLIB=
NM=
STRIP=
FFMPEG_ARCH=
FFMPEG_CPU=

arch_setup() {
    ARCH=$1
    case "$ARCH" in
        arm64)
            ARCH_TRIPLE=aarch64-linux-android
            ARCH_FAMILY=aarch64
            ARCH_CPU=aarch64
            CLANG_RT_ARCH=aarch64
            FFMPEG_ARCH=aarch64
            FFMPEG_CPU=armv8-a
            ;;
        x86_64)
            ARCH_TRIPLE=x86_64-linux-android
            ARCH_FAMILY=x86_64
            ARCH_CPU=x86_64
            CLANG_RT_ARCH=x86_64
            FFMPEG_ARCH=x86_64
            FFMPEG_CPU=generic
            ;;
        *)
            die "不支持的 arch：$ARCH（只做 arm64 / x86_64）"
            ;;
    esac

    PREFIX=$WORK/$ARCH/prefix
    BUILD=$WORK/$ARCH/build
    CROSS=$WORK/$ARCH/crossfile.txt
    CROSS_MPV=$WORK/$ARCH/crossfile-mpv.txt
    mkdir -p "$PREFIX" "$BUILD"

    CC="$TOOLCHAIN/bin/${ARCH_TRIPLE}${API}-clang"
    CXX="$TOOLCHAIN/bin/${ARCH_TRIPLE}${API}-clang++"
    AR="$TOOLCHAIN/bin/llvm-ar"
    RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
    NM="$TOOLCHAIN/bin/llvm-nm"
    STRIP="$TOOLCHAIN/bin/llvm-strip"
    [ -x "$CC" ] || die "找不到 clang：$CC"

    cat >"$CROSS" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = '$ARCH_FAMILY'
cpu = '$ARCH_CPU'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF

    export CC CXX AR RANLIB NM STRIP
    # harfbuzz 是 C++ 静态库，mpv 用 C 链接器链接，必须把 libc++ 静态塞进去。
    # 不能用 -l 形式：meson 的 prefer_static 会把 -lxxx 当依赖再解析一遍，
    # 然后卡在「libandroid.a 不存在」上，所以这里给绝对路径。
    CXX_STATIC_ARCHIVES="$SYSROOT/usr/lib/$ARCH_TRIPLE/libc++_static.a"
    CXX_STATIC_ARCHIVES="$CXX_STATIC_ARCHIVES,$SYSROOT/usr/lib/$ARCH_TRIPLE/libc++abi.a"
    CXX_STATIC_ARCHIVES="$CXX_STATIC_ARCHIVES,$TOOLCHAIN/lib/clang/$CLANG_VERSION/lib/linux/$CLANG_RT_ARCH/libunwind.a"
    local archive
    for archive in ${CXX_STATIC_ARCHIVES//,/ }; do
        [ -f "$archive" ] || die "缺少 C++ 静态库：$archive"
    done
    export CFLAGS="-O2 -fPIC -I$PREFIX/include"
    export CXXFLAGS="-O2 -fPIC -I$PREFIX/include"
    export LDFLAGS="-L$PREFIX/lib -Wl,-z,max-page-size=16384"
    export PKG_CONFIG_PATH=
    # 只认我们自己的 prefix，防止把 /usr/local 的 host 库链进来。
    export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
    unset PKG_CONFIG_SYSROOT_DIR
    export PATH="$TOOLCHAIN/bin:$PATH"
}

is_done() { [ -f "$PREFIX/.done/$1" ]; }
mark_done() {
    mkdir -p "$PREFIX/.done"
    touch "$PREFIX/.done/$1"
}

meson_dep() { # name src extra...
    local name=$1 src=$2
    shift 2
    if is_done "$name"; then
        log "[$ARCH] $name 已构建"
        return 0
    fi
    log "[$ARCH] 构建 $name"
    rm -rf "$BUILD/$name"
    meson setup "$BUILD/$name" "$src" \
        --prefix="$PREFIX" \
        --cross-file="$CROSS" \
        --buildtype=release \
        --default-library=static \
        --prefer-static \
        --wrap-mode=nodownload \
        "$@"
    ninja -C "$BUILD/$name" -j"$JOBS"
    ninja -C "$BUILD/$name" install
    mark_done "$name"
}

autotools_dep() { # name src extra...
    local name=$1 src=$2
    shift 2
    if is_done "$name"; then
        log "[$ARCH] $name 已构建"
        return 0
    fi
    log "[$ARCH] 构建 $name"
    rm -rf "$BUILD/$name"
    mkdir -p "$BUILD/$name"
    (
        cd "$BUILD/$name"
        "$src/configure" --prefix="$PREFIX" --host="$ARCH_TRIPLE" "$@"
        make -j"$JOBS"
        make install
    )
    mark_done "$name"
}

build_ffmpeg() {
    if is_done ffmpeg; then
        log "[$ARCH] ffmpeg 已构建"
        return 0
    fi
    log "[$ARCH] 构建 ffmpeg（LGPL，静态）"
    rm -rf "$BUILD/ffmpeg"
    mkdir -p "$BUILD/ffmpeg"
    (
        cd "$BUILD/ffmpeg"
        # macOS 自带 bash 3.2：空数组展开会撞 set -u，用普通字符串。
        x86asm_flag=
        if [ "$ARCH" = "x86_64" ]; then x86asm_flag=--disable-x86asm; fi
        "$FFMPEG_SRC/configure" \
            --prefix="$PREFIX" \
            --target-os=android \
            --enable-cross-compile \
            --cross-prefix="$ARCH_TRIPLE-" \
            --cc="$CC" \
            --cxx="$CXX" \
            --ar="$AR" \
            --ranlib="$RANLIB" \
            --nm="$NM" \
            --strip="$STRIP" \
            --arch="$FFMPEG_ARCH" \
            --cpu="$FFMPEG_CPU" \
            --sysroot="$SYSROOT" \
            --enable-static \
            --disable-shared \
            --enable-pic \
            --disable-autodetect \
            --enable-zlib \
            --enable-jni \
            --enable-mediacodec \
            --disable-vulkan \
            --disable-gpl \
            --disable-version3 \
            --disable-nonfree \
            --disable-doc \
            --disable-programs \
            --disable-stripping \
            --disable-debug \
            --disable-muxers \
            --disable-encoders \
            --disable-devices \
            --enable-encoder=mjpeg,png \
            --enable-muxer=mov,matroska,mpegts \
            --extra-cflags="-I$PREFIX/include -fPIC" \
            --extra-ldflags="-L$PREFIX/lib -Wl,-z,max-page-size=16384" \
            $x86asm_flag
        make -j"$JOBS"
        make install
    )
    mark_done ffmpeg
}

build_mpv() {
    if is_done mpv; then
        log "[$ARCH] mpv 已构建"
        return 0
    fi
    log "[$ARCH] 构建 mpv（libmpv.so，LGPL）"
    rm -rf "$BUILD/mpv"
    # 只在 mpv 这一个工程上挂 libc++ 静态库，避免给 freetype/XML 那些小工具也塞进去。
    # 用 cross file 是因为 meson 的 -D 参数不会把逗号拆成数组。
    cp "$CROSS" "$CROSS_MPV"
    {
        echo
        echo '[built-in options]'
        printf 'c_link_args = ['
        sep=
        for archive in ${CXX_STATIC_ARCHIVES//,/ }; do
            printf "%s'%s'" "$sep" "$archive"
            sep=', '
        done
        echo ']'
    } >>"$CROSS_MPV"
    meson setup "$BUILD/mpv" "$MPV_SRC" \
        --prefix="$PREFIX" \
        --cross-file="$CROSS_MPV" \
        --buildtype=release \
        --default-library=shared \
        --prefer-static \
        --wrap-mode=nodownload \
        -Dcplayer=false \
        -Dlibmpv=true \
        -Dgpl=false \
        -Dlibbluray=enabled \
        -Dlibcurl=disabled \
        -Dlua=disabled \
        -Diconv=disabled \
        -Degl-android=enabled \
        -Dgl=enabled \
        -Dvulkan=disabled \
        -Dmanpage-build=disabled \
        -Dbuild-date=false \
        -Dtests=false
    ninja -C "$BUILD/mpv" -j"$JOBS"
    ninja -C "$BUILD/mpv" install
    mark_done mpv
}

verify() {
    local so=$PREFIX/lib/libmpv.so
    [ -f "$so" ] || die "[$ARCH] 没生成 libmpv.so"
    # FFmpeg 默认带 -g，静态链进来后 .so 有 29MB 调试信息；先剥掉再校验。
    "$STRIP" --strip-unneeded "$so"
    log "[$ARCH] 校验 $so"
    "$TOOLCHAIN/bin/llvm-readelf" -d "$so" | awk '/NEEDED/ { print "  NEEDED " $NF }'
    local min_align=999999999
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        v=$((16#${a#0x}))
        [ "$v" -lt "$min_align" ] && min_align=$v
    done < <("$TOOLCHAIN/bin/llvm-readelf" -lW "$so" | awk '$1 == "LOAD" { print $NF }')
    [ "$min_align" -ge 16384 ] || die "[$ARCH] LOAD 对齐 $(printf 0x%x "$min_align") < 0x4000"
    printf '  LOAD align >= 0x4000\n'
    ls -lh "$so"
}

# ---------------------------------------------------------------- 主流程
for arch in $ARCHES; do
    arch_setup "$arch"

    meson_dep freetype "$SRC/freetype" \
        -Dbrotli=disabled -Dbzip2=disabled -Dpng=disabled \
        -Dharfbuzz=disabled -Dzlib=disabled -Dtests=disabled

    # minimum 会关掉 push parser，而 fontconfig 的 fcxml.c 要用
    # xmlCreatePushParserCtxt / xmlParseChunk，必须把 push 单独打开。
    meson_dep libxml2 "$SRC/libxml2" \
        -Dminimum=true \
        -Dpush=enabled -Dreader=enabled -Dsax1=enabled \
        -Diso8859x=enabled -Dpattern=enabled

    meson_dep fribidi "$SRC/fribidi" -Dtests=false -Ddocs=false

    meson_dep harfbuzz "$SRC/harfbuzz" \
        -Dtests=disabled -Ddocs=disabled -Dutilities=disabled \
        -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dicu=disabled \
        -Dfreetype=disabled -Dgraphite=disabled -Dgraphite2=disabled \
        -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dsubset=disabled

    # libunibreak 只有 autotools（没有 meson.build）。
    autotools_dep libunibreak "$SRC/libunibreak" \
        --with-pic --enable-static --disable-shared

    meson_dep fontconfig "$SRC/fontconfig" \
        -Ddoc=disabled -Dtests=disabled -Dtools=disabled -Dnls=disabled \
        -Dxml-backend=libxml2 -Dcache-build=disabled

    autotools_dep libass "$LIBASS_SRC" \
        --with-pic --enable-static --disable-shared \
        --enable-fontconfig --enable-libunibreak --disable-asm

    meson_dep libudfread "$SRC/libudfread"

    meson_dep libbluray "$SRC/libbluray" \
        -Denable_tools=false -Denable_examples=false -Denable_docs=false \
        -Dbdj_jar=disabled \
        -Dfreetype=enabled -Dfontconfig=enabled -Dlibxml2=enabled

    meson_dep libplacebo "$LIBPLACEBO_SRC" \
        -Dvulkan=disabled -Ddemos=false -Dtests=false -Dbench=false \
        -Dfuzz=false -Dlcms=disabled -Ddovi=disabled -Dlibdovi=disabled

    build_ffmpeg
    build_mpv
    verify
    if [ "$stage" -eq 1 ]; then
        case "$ARCH" in
            arm64) ABI=arm64-v8a ;;
            x86_64) ABI=x86_64 ;;
        esac
        DEST=$ROOT/apps/android/core/src/main/jniLibs/$ABI
        mkdir -p "$DEST"
        cp "$PREFIX/lib/libmpv.so" "$DEST/libmpv.so"
        echo "  -> $DEST/libmpv.so"
    fi
done

log "完成"
for arch in $ARCHES; do
    echo "  $WORK/$arch/prefix/lib/libmpv.so"
done
