#!/usr/bin/env bash
# 从源码构建 M0 所需的最小栈：
#   FFmpeg 9.0.2 + libplacebo 7.387.0 + libass 0.17.4 + mpv 0.42.0
#
# 为什么不用 Homebrew：本机是 Intel + macOS 26，Homebrew 已把该配置列为
# Tier 3、不再提供 bottle；且 /usr/local 权限异常。这里全部装进项目内的
# prefix/，不碰系统目录。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=${PREFIX:-$ROOT/prefix}
SRC=${SRC:-$ROOT/build/src}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
export PATH="$HOME/Library/Python/3.9/bin:$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

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
      --disable-autodetect \
      --disable-doc \
      --disable-debug \
      --disable-x86asm \
      --enable-shared \
      --disable-static \
      --enable-videotoolbox \
      --enable-audiotoolbox
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
  git -C "$SRC/libplacebo" submodule update --init --recursive
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

# ------------------------------------------------------------------ mpv 0.42
if [ -x "$PREFIX/bin/mpv" ]; then
  step "mpv 已安装，跳过"
else
  step "mpv v0.42.0"
  if [ ! -d "$SRC/mpv" ]; then
    git clone --depth 1 --branch v0.42.0 https://github.com/mpv-player/mpv.git "$SRC/mpv"
  fi
  rm -rf "$SRC/mpv/_build"
  meson setup "$SRC/mpv/_build" "$SRC/mpv" \
    --prefix="$PREFIX" \
    --buildtype=release \
    -Dgpl=false \
    -Dlibmpv=true \
    -Dlibarchive=disabled \
    -Dcaca=disabled \
    -Ddrm=disabled \
    -Dwayland=disabled \
    -Dx11=disabled \
    -Dvulkan=disabled \
    -Djavascript=disabled \
    -Dlua=disabled \
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
fi

step "done"
"$PREFIX/bin/mpv" --version | head -4
