#!/usr/bin/env bash
# 编译 m0-render。需要先跑 scripts/build-deps-macos.sh。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PREFIX="$ROOT/prefix"

if [ ! -f "$PREFIX/include/mpv/client.h" ] || [ ! -f "$PREFIX/lib/libmpv.dylib" ]; then
  echo "libmpv 未构建，先跑 scripts/build-deps-macos.sh" >&2
  exit 1
fi

clang++ -std=c++17 -fobjc-arc -O2 \
  -I "$PREFIX/include" \
  "$(dirname "$0")/main.mm" \
  -o "$(dirname "$0")/m0-render" \
  -L "$PREFIX/lib" -lmpv \
  -Wl,-rpath,"$PREFIX/lib" \
  -framework Cocoa -framework OpenGL -framework CoreFoundation

echo "built: $(dirname "$0")/m0-render"
