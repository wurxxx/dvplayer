#!/usr/bin/env bash
# 构建 macOS 上的 Vulkan 版 mpv（gpu-next + macvk），装进 prefix-vk/。
#
# 这份 mpv 既是验证工具，也是产品运行时：
#   macOS 的 libmpv render API 只有 legacy gpu（没有 gpu-next 后端），
#   gpu-next 只能走 mpv 自己的窗口（cocoa-cb + Vulkan/Metal）。
#   apps/macos/DvPlayer/build.sh 会把它、libplacebo、MoltenVK 与
#   Vulkan loader 一起打进 .app（ADR-0010）。P5/P7 的色彩与 FEL 也在这条路径上验证。
#
# 可重入：每一步都有「已存在就跳过」的判断。
# 需要：cmake（脚本会自动 pip 安装）、meson/ninja、swiftc、Xcode 命令行工具。
#
# 用法:
#   ./scripts/build-vk-macos.sh          # 全量
#   ./scripts/build-vk-macos.sh --clean  # 先删 prefix-vk 和中间目录
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PREFIX_VK=${PREFIX_VK:-$ROOT/prefix-vk}
PREFIX=${PREFIX:-$ROOT/prefix}
SRC=${SRC:-$ROOT/build/src}
DL=${DL:-$ROOT/build/dl}
VK_BUILD=${VK_BUILD:-$ROOT/build/vk}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
# 默认直连 GitHub：GH_PROXY 是第三方代理，拿到的 tar 没有哈希可校验，
# 等于把编译进去的源码交给中间人。只有明确信任时再 export GH_PROXY=...。
GH_PROXY=${GH_PROXY:-}

MVK_TAG=v1.4.2
HEADERS_TAG=vulkan-sdk-1.4.363.0
LOADER_TAG=vulkan-sdk-1.4.363.0
GLSLANG_TAG=16.6.0

if [ "${1:-}" = "--clean" ]; then
  rm -rf "$PREFIX_VK" "$VK_BUILD"
  rm -rf "$SRC"/Vulkan-Headers-* "$SRC"/Vulkan-Loader-* "$SRC"/glslang-*
  rm -rf "$SRC/libplacebo/_build-vk" "$SRC/mpv/_build-vk"
fi

export PATH="$HOME/Library/Python/3.9/bin:$PREFIX/bin:$PATH"

step() { printf '\n== %s ==\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }

step "检查前置"
if [ ! -f "$PREFIX/lib/pkgconfig/libplacebo.pc" ]; then
  echo "prefix/ 里还没有 FFmpeg/libass，先跑 scripts/build-deps-macos.sh" >&2
  exit 1
fi
need meson
need ninja
need swiftc
need pkg-config

if ! command -v cmake >/dev/null 2>&1; then
  step "安装 cmake（pip --user）"
  python3 -m pip install --user --quiet cmake
  export PATH="$HOME/Library/Python/3.9/bin:$PATH"
fi
need cmake

mkdir -p "$PREFIX_VK" "$SRC" "$DL" "$VK_BUILD"

# ---------------------------------------------------------------- 源码
fetch() { # fetch <repo> <tag> <outfile>
  local repo=$1 tag=$2 out=$3
  # 只认「能被 tar 解开」的文件：上次 curl 被中断留下的半截包同样存在，
  # 按「文件存在就跳过」会让后面解包静默失败。
  if [ -f "$out" ] && tar -tzf "$out" >/dev/null 2>&1; then
    echo "已下载: $(basename "$out")"
    return
  fi
  rm -f "$out"
  echo "下载 $repo $tag"
  [ -z "$GH_PROXY" ] || echo "经第三方代理 $GH_PROXY 下载（无哈希校验）" >&2
  curl -fsSL --retry 2 --max-time 900 -o "$out.part" \
    "${GH_PROXY}https://github.com/KhronosGroup/$repo/archive/refs/tags/$tag.tar.gz"
  tar -tzf "$out.part" >/dev/null 2>&1 || {
    echo "下载结果不是完整 tar.gz：${out}.part" >&2
    rm -f "$out.part"
    exit 1
  }
  mv "$out.part" "$out"
}

step "下载源码"
fetch Vulkan-Headers "$HEADERS_TAG" "$DL/vulkan-headers.tar.gz"
fetch Vulkan-Loader  "$LOADER_TAG"  "$DL/vulkan-loader.tar.gz"
fetch glslang        "$GLSLANG_TAG" "$DL/glslang-$GLSLANG_TAG.tar.gz"
fetch_release="MoltenVK-macos.tar"
if [ ! -f "$DL/$fetch_release" ] || ! tar -tf "$DL/$fetch_release" >/dev/null 2>&1; then
  # 半截包同样会让解包失败：先删掉再下，下完用 tar 自检。
  rm -f "$DL/$fetch_release"
  repo=${fetch_release%-macos.tar}
  echo "下载 $fetch_release（$MVK_TAG）"
  [ -z "$GH_PROXY" ] || echo "经第三方代理 $GH_PROXY 下载（无哈希校验）" >&2
  curl -fsSL --retry 2 --max-time 900 -o "$DL/$fetch_release.part" \
    "${GH_PROXY}https://github.com/KhronosGroup/$repo/releases/download/$MVK_TAG/$fetch_release"
  tar -tf "$DL/$fetch_release.part" >/dev/null 2>&1 || {
    echo "下载结果不是完整 tar：$DL/$fetch_release.part" >&2
    rm -f "$DL/$fetch_release.part"
    exit 1
  }
  mv "$DL/$fetch_release.part" "$DL/$fetch_release"
fi

for t in vulkan-headers.tar.gz vulkan-loader.tar.gz "glslang-$GLSLANG_TAG.tar.gz"; do
  tar -xzf "$DL/$t" -C "$SRC"
done
mkdir -p "$VK_BUILD/mvk"
tar -xf "$DL/$fetch_release" -C "$VK_BUILD/mvk"

# ---------------------------------------------------------------- Vulkan-Headers
step "Vulkan-Headers"
if [ ! -f "$PREFIX_VK/include/vulkan/vulkan.h" ]; then
  cmake -S "$SRC/Vulkan-Headers-$HEADERS_TAG" -B "$VK_BUILD/headers" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX_VK" -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$VK_BUILD/headers" --target install >/dev/null
fi

# ---------------------------------------------------------------- Vulkan-Loader
step "Vulkan-Loader"
if [ ! -f "$PREFIX_VK/lib/pkgconfig/vulkan.pc" ]; then
  cmake -S "$SRC/Vulkan-Loader-$LOADER_TAG" -B "$VK_BUILD/loader" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX_VK" -DCMAKE_BUILD_TYPE=Release \
    -DVULKAN_HEADERS_INSTALL_DIR="$PREFIX_VK" \
    -DBUILD_TESTS=OFF -DUPDATE_DEPS=OFF >/dev/null
  cmake --build "$VK_BUILD/loader" -j "$JOBS" >/dev/null
  cmake --install "$VK_BUILD/loader" >/dev/null
fi

# ---------------------------------------------------------------- glslang
step "glslang"
if [ ! -f "$PREFIX_VK/lib/libglslang.dylib" ]; then
  cmake -S "$SRC/glslang-$GLSLANG_TAG" -B "$VK_BUILD/glslang" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX_VK" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON -DENABLE_OPT=OFF -DENABLE_HLSL=OFF \
    -DBUILD_EXTERNAL=OFF -DGLSLANG_TESTS=OFF -DGLSLANG_ENABLE_INSTALL=ON >/dev/null
  cmake --build "$VK_BUILD/glslang" -j "$JOBS" >/dev/null
  cmake --install "$VK_BUILD/glslang" >/dev/null
fi

# ---------------------------------------------------------------- MoltenVK
step "MoltenVK"
if [ ! -f "$PREFIX_VK/lib/libMoltenVK.dylib" ]; then
  cp "$VK_BUILD/mvk/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" \
     "$PREFIX_VK/lib/"
fi
mkdir -p "$PREFIX_VK/share/vulkan/icd.d"
python3 - "$PREFIX_VK" <<'PY'
import json, os, sys
prefix = sys.argv[1]
src = os.path.join(prefix, "share", "vulkan", "icd.d", "MoltenVK_icd.json")
os.makedirs(os.path.dirname(src), exist_ok=True)
json.dump({
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": os.path.join(prefix, "lib", "libMoltenVK.dylib"),
        "api_version": "1.4.0",
        "is_portability_driver": True,
    },
}, open(src, "w"), indent=4)
PY

# ---------------------------------------------------------------- libplacebo
# fel-amplify.sh 还原失败会留下这个标记：prefix-vk 里还是放大过的 shader。
# 照常「pc 存在就跳过」会让标记永远清不掉，这里强制重装一次。
if [ -f "$SRC/libplacebo/_build-vk/.dovi-amplify-dirty" ]; then
  echo "检测到残差放大器残留标记，重建 libplacebo"
  rm -rf "$SRC/libplacebo/_build-vk"
  rm -f "$PREFIX_VK/lib/pkgconfig/libplacebo.pc"
fi

step "libplacebo（Vulkan + glslang）"
# 上游 7.387 的 glslang 检测有两处没传 dirs，导致 find_library 找不到库。
# 这里在 build/src 里打本地补丁（不进仓库），只影响构建。
python3 - "$SRC/libplacebo/src/glsl/meson.build" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
if "vulkan_lib_dirs) \n" not in s and "glslang-default-resource-limits', required: false,\n                     dirs: vulkan_lib_dirs)" not in s:
    old = """  glslang_deps = [
    cxx.find_library('glslang-default-resource-limits', required: false)
  ]

  # meson doesn't respect generator expressions in INTERFACE_LINK_LIBRARIES
  # https://github.com/mesonbuild/meson/issues/8232
  # TODO: Use the following once it's fixed
  # glslang = dependency('glslang', method: 'cmake', modules: ['glslang::SPIRV'])

  vulkan_sdk = get_option('vulkan-sdk')
  vulkan_lib_dirs = []
  if vulkan_sdk != ''
    vulkan_lib_dirs += [vulkan_sdk / 'lib']
  endif
  prefer_static = get_option('prefer_static')"""
    new = """  vulkan_sdk = get_option('vulkan-sdk')
  vulkan_lib_dirs = []
  if vulkan_sdk != ''
    vulkan_lib_dirs += [vulkan_sdk / 'lib']
  endif

  glslang_deps = [
    cxx.find_library('glslang-default-resource-limits', required: false,
                     dirs: vulkan_lib_dirs)
  ]

  # meson doesn't respect generator expressions in INTERFACE_LINK_LIBRARIES
  # https://github.com/mesonbuild/meson/issues/8232
  # TODO: Use the following once it's fixed
  # glslang = dependency('glslang', method: 'cmake', modules: ['glslang::SPIRV'])

  prefer_static = get_option('prefer_static')"""
    if old not in s:
        print("警告: libplacebo meson 结构与预期不同，跳过补丁", file=sys.stderr)
    else:
        s = s.replace(old, new)
s = s.replace("cxx.find_library('glslang', required: required, static: static)",
              "cxx.find_library('glslang', required: required, static: static, dirs: vulkan_lib_dirs)")
open(p, "w").write(s)
PY

if [ ! -f "$PREFIX_VK/lib/pkgconfig/libplacebo.pc" ] || ! grep -q 'pl_has_vulkan=1' "$PREFIX_VK/lib/pkgconfig/libplacebo.pc"; then
  export PKG_CONFIG_PATH="$PREFIX_VK/lib/pkgconfig:$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CFLAGS="-I$PREFIX_VK/include -I$PREFIX/include ${CFLAGS:-}"
  export CXXFLAGS="$CFLAGS"
  rm -rf "$SRC/libplacebo/_build-vk"
  meson setup "$SRC/libplacebo/_build-vk" "$SRC/libplacebo" \
    --prefix="$PREFIX_VK" --buildtype=release \
    -Dvulkan=enabled -Dvk-proc-addr=enabled \
    -Dglslang=enabled -Dshaderc=disabled -Dprefer_static=true \
    -Dvulkan-sdk="$PREFIX_VK" \
    -Dopengl=enabled -Dd3d11=disabled -Dlcms=disabled \
    -Ddemos=false -Dtests=false
  meson compile -C "$SRC/libplacebo/_build-vk"
  meson install -C "$SRC/libplacebo/_build-vk"
fi

# ---------------------------------------------------------------- mpv
step "mpv（Vulkan + libmpv）"
export DYLD_LIBRARY_PATH="$PREFIX_VK/lib:$PREFIX/lib:${DYLD_LIBRARY_PATH:-}"
if [ ! -x "$PREFIX_VK/bin/mpv" ] || ! "$PREFIX_VK/bin/mpv" --no-config --gpu-context=help 2>/dev/null | grep -q macvk; then
  export PKG_CONFIG_PATH="$PREFIX_VK/lib/pkgconfig:$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CFLAGS="-I$PREFIX_VK/include -I$PREFIX/include ${CFLAGS:-}"
  export CXXFLAGS="$CFLAGS"
  export LDFLAGS="-L$PREFIX_VK/lib -L$PREFIX/lib ${LDFLAGS:-}"

  rm -rf "$SRC/mpv/_build-vk"
  meson setup "$SRC/mpv/_build-vk" "$SRC/mpv" \
    --prefix="$PREFIX_VK" --buildtype=release \
    -Dgpl=false -Dlibmpv=true \
    -Dlibarchive=disabled -Dcaca=disabled \
    -Ddrm=disabled -Dwayland=disabled -Dx11=disabled \
    -Dvulkan=enabled \
    -Djavascript=disabled -Dlua=disabled \
    -Dalsa=disabled -Dpulse=disabled -Djack=disabled -Dpipewire=disabled \
    -Duchardet=disabled -Dzimg=disabled -Dvapoursynth=disabled -Drubberband=disabled
  meson compile -C "$SRC/mpv/_build-vk"
  meson install -C "$SRC/mpv/_build-vk"

  # 让二进制自己找到 prefix-vk/lib，不依赖 DYLD_LIBRARY_PATH
  for bin in "$PREFIX_VK/bin/mpv" "$PREFIX_VK/lib/libmpv.2.dylib"; do
    [ -f "$bin" ] || continue
    if ! otool -l "$bin" \
        | awk '/LC_RPATH/{want=1; next} want && /path /{print $2; want=0}' \
        | grep -qx "$PREFIX_VK/lib"; then
      install_name_tool -add_rpath "$PREFIX_VK/lib" "$bin"
      codesign --force --sign - "$bin" >/dev/null 2>&1 || true
    fi
  done
fi

step "自检"
export DYLD_LIBRARY_PATH="$PREFIX_VK/lib:$PREFIX/lib:${DYLD_LIBRARY_PATH:-}"
export VK_ICD_FILENAMES="$PREFIX_VK/share/vulkan/icd.d/MoltenVK_icd.json"
"$PREFIX_VK/bin/mpv" --version | head -3
"$PREFIX_VK/bin/mpv" --no-config --gpu-context=help 2>&1 | grep -q macvk \
  && echo "gpu-context macvk: ok" \
  || { echo "gpu-context macvk 不可用" >&2; exit 1; }

step "done"
echo "verification mpv: $PREFIX_VK/bin/mpv"
echo "运行: ./scripts/mpv-vk.sh <file>"
