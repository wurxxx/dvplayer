#!/usr/bin/env bash
# 统一 PATH：项目内构建的 mpv/ffmpeg 优先，其次是 tools/bin 里的预编译工具，
# 最后是本机 pip --user 装的 meson/ninja。
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PATH="$ROOT/prefix/bin:$ROOT/tools/bin:$PATH"
if [ -d "$HOME/Library/Python/3.9/bin" ]; then
  export PATH="$HOME/Library/Python/3.9/bin:$PATH"
fi
export PKG_CONFIG_PATH="$ROOT/prefix/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
