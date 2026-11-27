#!/usr/bin/env bash
# 从源码构建 M0 所需的最小栈：
#   FFmpeg 9.0.2 + libplacebo 7.387.0 + libass 0.17.4 + mpv master（gpu-next render backend）
#
# 为什么不用 Homebrew：本机是 Intel + macOS 26，Homebrew 已把该配置列为
# Tier 3、不再提供 bottle；且 /usr/local 权限异常。这里全部装进项目内的
# prefix/，不碰系统目录。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=${PREFIX:-$ROOT/prefix}
SRC=${SRC:-$ROOT/build/src}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
export PATH="$PREFIX/bin:$PATH"
# meson / ninja 可能来自 pip --user（~/.local 或 ~/Library/Python/<ver>/bin），
# 也可能是 brew（/opt/homebrew/bin，已经在 PATH 里）。
# 不写死 Python 版本：开发机是 3.9，CI runner 是 3.12+。
for pybin in "$HOME"/Library/Python/*/bin "$HOME"/.local/bin; do
    [ -d "$pybin" ] && PATH="$pybin:$PATH"
done
export PATH
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# ---------------------------------------------------------- 最低系统版本
# clang 不给 -mmacosx-version-min 时，链接器按 **SDK 版本**写 minos：在
# macos-15 上编出来是 15.0，在 macos-26 上编出来是 26.0。这样打出来的包
# 只能跑在编译机的系统上，和 App 声明的 13.0 对不上（v0.1.4 就这样发出去
# 过：libav*/libmpv/libplacebo 全是 minos 15.0）。
# 这里统一钉到 13.0，和 Info.plist / Package.swift 对齐。
#
# ffmpeg 的 configure 不读环境变量，下面单独用 --extra-cflags/-ldflags 传；
# meson（libplacebo / mpv）和 autotools（libass）读 CFLAGS / LDFLAGS。
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
DEPLOY_FLAG="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CFLAGS="${CFLAGS:+$CFLAGS }$DEPLOY_FLAG"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }$DEPLOY_FLAG"
export OBJCFLAGS="${OBJCFLAGS:+$OBJCFLAGS }$DEPLOY_FLAG"
export LDFLAGS="${LDFLAGS:+$LDFLAGS }$DEPLOY_FLAG"

mkdir -p "$PREFIX" "$SRC"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing: $1" >&2
    exit 1
  }
}

need meson
need ninja
need clang
need make
need git
need curl

step() { printf '\n== %s ==\n' "$*"; }

# 大件一律用干净 tarball：解出来的目录里记着包名，换版本就重解，
# 避免拿旧源码编出新标记。
ensure_tar() { # name tarball url
  local name=$1 tarball=$2 url=$3
  if [ -d "$SRC/$name" ]; then
    [ "$(cat "$SRC/$name/.tarball" 2>/dev/null)" = "$tarball" ] && return 0
    echo "源码包变了（${tarball}），重新解压 $name" >&2
    rm -rf "$SRC/$name"
  fi
  mkdir -p "$SRC/.dl"
  [ -f "$SRC/.dl/$tarball" ] || curl -sSL "$url" -o "$SRC/.dl/$tarball"
  mkdir -p "$SRC/$name"
  tar -xf "$SRC/.dl/$tarball" -C "$SRC/$name" --strip-components=1
  printf '%s' "$tarball" >"$SRC/$name/.tarball"
}

# ---------------------------------------------------------------- FFmpeg 9.0.2
if [ -f "$PREFIX/lib/pkgconfig/libavcodec.pc" ]; then
  step "FFmpeg 已安装，跳过"
else
  step "FFmpeg n9.0.2"
  if [ ! -d "$SRC/ffmpeg" ]; then
    git clone --depth 1 --branch n9.0.2 https://github.com/FFmpeg/FFmpeg.git "$SRC/ffmpeg"
  fi
  cd "$SRC/ffmpeg"
  if [ ! -f config.h ]; then
    ./configure \
      --prefix="$PREFIX" \
      --extra-cflags="$DEPLOY_FLAG" \
      --extra-ldflags="$DEPLOY_FLAG" \
      --disable-autodetect \
      --disable-doc \
      --disable-debug \
      --disable-x86asm \
      --enable-shared \
      --disable-static \
      --enable-videotoolbox \
      --enable-audiotoolbox \
      --enable-securetransport \
      --enable-zlib \
      --enable-encoder=png \
      --enable-decoder=png
  fi
  make -j"$JOBS"
  make install
fi

# ------------------------------------------------------------ libplacebo 7.387
if [ -f "$PREFIX/lib/pkgconfig/libplacebo.pc" ]; then
  step "libplacebo 已安装，跳过"
else
  step "libplacebo v7.387.0"
  if [ ! -d "$SRC/libplacebo" ]; then
    git clone --depth 1 --branch v7.387.0 https://code.videolan.org/videolan/libplacebo.git "$SRC/libplacebo"
  fi
  # libplacebo 有 6 个子模块，我们的配置需要这 5 个：
  #   fast_float / jinja / markupsafe —— shader 模板与数值解析
  #   glad                            —— OpenGL 函数加载（render API 走 GL）
  #   Vulkan-Headers                  —— 即使后端 disabled 也要：
  #                                      vulkan_stubs.c 会 include libplacebo/vulkan.h，
  #                                      后者无条件 include <vulkan/vulkan.h>。
  #                                      （别被 `-Dvulkan=disabled` 误导，删了头文件编不过。）
  # 只有 demos 用的 nuklear 可以不拉（demos=false）。
  git -C "$SRC/libplacebo" submodule update --init \
      3rdparty/fast_float 3rdparty/jinja 3rdparty/markupsafe 3rdparty/glad \
      3rdparty/Vulkan-Headers
  rm -rf "$SRC/libplacebo/_build"
  meson setup "$SRC/libplacebo/_build" "$SRC/libplacebo" \
    --prefix="$PREFIX" \
    --buildtype=release \
    -Dvulkan=disabled \
    -Dd3d11=disabled \
    -Dglslang=disabled \
    -Dshaderc=disabled \
    -Dlcms=disabled \
    -Ddemos=false \
    -Dtests=false
  meson compile -C "$SRC/libplacebo/_build"
  meson install -C "$SRC/libplacebo/_build"
fi

# ------------------------------------------------------------------ libass 0.17
if [ -f "$PREFIX/lib/pkgconfig/libass.pc" ]; then
  step "libass 已安装，跳过"
else
  step "libass 0.17.4"
  if [ ! -d "$SRC/libass-0.17.4" ]; then
    curl -sSL https://github.com/libass/libass/releases/download/0.17.4/libass-0.17.4.tar.xz \
      | tar -xJ -C "$SRC"
  fi
  cd "$SRC/libass-0.17.4"
  ./configure --prefix="$PREFIX" --disable-static --disable-asm
  make -j"$JOBS"
  make install
fi

# --------------------------------------------------- libudfread / libbluray
# 原盘（ISO）的 UDF 读取和 HDMV 菜单导航都由 libbluray 提供；
# mpv 用 `--disc-menu` + `discnav` 驱动盘里自带的菜单（见 docs/BLU-RAY.md §5.4）。
# 不编 BD-J（要 JVM + jar），-Dbdj_jar=disabled；BD-J 盘 mpv 会自己回退到
# 直接播正片。libbluray 的元数据 / 字体全关，只留 ISO 读取和 HDMV 导航。
LIBUDFREAD_VER=1.2.0
LIBBLURAY_VER=1.5.0
if [ -f "$PREFIX/lib/pkgconfig/libbluray.pc" ]; then
  step "libbluray 已安装，跳过"
else
  step "libudfread $LIBUDFREAD_VER"
  ensure_tar libudfread "libudfread-${LIBUDFREAD_VER}.tar.xz" \
    "https://download.videolan.org/pub/videolan/libudfread/libudfread-${LIBUDFREAD_VER}.tar.xz"
  rm -rf "$SRC/libudfread/_build"
  meson setup "$SRC/libudfread/_build" "$SRC/libudfread" \
    --prefix="$PREFIX" \
    --buildtype=release \
    --default-library=shared
  meson compile -C "$SRC/libudfread/_build"
  meson install -C "$SRC/libudfread/_build"

  step "libbluray $LIBBLURAY_VER"
  ensure_tar libbluray "libbluray-${LIBBLURAY_VER}.tar.xz" \
    "https://download.videolan.org/pub/videolan/libbluray/${LIBBLURAY_VER}/libbluray-${LIBBLURAY_VER}.tar.xz"
  rm -rf "$SRC/libbluray/_build"
  meson setup "$SRC/libbluray/_build" "$SRC/libbluray" \
    --prefix="$PREFIX" \
    --buildtype=release \
    --default-library=shared \
    -Dbdj_jar=disabled \
    -Dlibxml2=disabled \
    -Dfreetype=disabled \
    -Dfontconfig=disabled \
    -Denable_tools=false \
    -Denable_examples=false \
    -Denable_docs=false
  meson compile -C "$SRC/libbluray/_build"
  meson install -C "$SRC/libbluray/_build"
fi

# ------------------------------------------------------------------ mpv
# 必须是 2026-11-22 之后的 master：render API 从那时起才有 gpu-next 后端
# （`ad9d850` add gpu-next render backend / `eb565a2` add renderer selection）。
# 没有它，render API 只能用 legacy `gpu`，Dolby Vision P5 会把 IPT 当 YCbCr 解，
# 画面发紫（framebuffer 实测 meanDiff 30–54）。
MPV_COMMIT=${MPV_COMMIT:-1eb941f}
MPV_STAMP="$PREFIX/lib/libmpv.2.dylib"
# `.mpv-disc-menu` 记着「这份 mpv 是带 libbluray 编的」。老 prefix 里已经有
# mpv 但没开 libbluray 时（v0.1.6 之前的包），这里必须重编，否则 `--disc-menu`
# 和 `discnav` 都不存在，原盘只能直接播正片。
if [ -f "$MPV_STAMP" ] \
  && [ "$(cat "$PREFIX/.mpv-commit" 2>/dev/null)" = "$MPV_COMMIT" ] \
  && [ "$(cat "$PREFIX/.mpv-disc-menu" 2>/dev/null)" = "1" ]; then
  step "mpv 已安装（${MPV_COMMIT}），跳过"
else
  step "mpv $MPV_COMMIT"
  if [ ! -d "$SRC/mpv" ]; then
    git clone https://github.com/mpv-player/mpv.git "$SRC/mpv"
  fi
  git -C "$SRC/mpv" fetch --depth 200 origin master
  git -C "$SRC/mpv" checkout --force "$MPV_COMMIT"

  # 以前这里要打一个 macOS 补丁（把 view.swift 的 MetalLayer 换成 CAMetalLayer
  # 并补 import QuartzCore）。上游已经自己改成 CAMetalLayer 了，补丁从 2026-11
  # 起打不上，也不需要——metal_layer.swift 里的 MetalLayer 子类只在
  # -Dmetal=enabled 时进编译，我们编的是只开 OpenGL 的 render API，
  # view.swift 只需要 Cocoa（它转发 QuartzCore），CAMetalLayer 直接可用。
  # 见 patches/mpv/README.md。

  rm -rf "$SRC/mpv/_build"
  meson setup "$SRC/mpv/_build" "$SRC/mpv" \
    --prefix="$PREFIX" \
    --buildtype=release \
    -Dgpl=false \
    -Dlibmpv=true \
    -Dlibarchive=disabled \
    -Dcaca=disabled \
    -Ddrm=disabled \
    -Dgl=enabled \
    -Dlibbluray=enabled \
    -Dvulkan=disabled \
    -Djavascript=disabled \
    -Dlua=disabled \
    -Dcplugins=disabled \
    -Dalsa=disabled \
    -Dpulse=disabled \
    -Djack=disabled \
    -Dpipewire=disabled \
    -Duchardet=disabled \
    -Dzimg=disabled \
    -Dvapoursynth=disabled \
    -Drubberband=disabled
  meson compile -C "$SRC/mpv/_build"
  meson install -C "$SRC/mpv/_build"
  echo "$MPV_COMMIT" > "$PREFIX/.mpv-commit"
  echo 1 > "$PREFIX/.mpv-disc-menu"
fi

step "done"
"$PREFIX/bin/mpv" --version | head -4
