#!/usr/bin/env bash
# 用 prefix-vk 里的 Vulkan 版 mpv（gpu-next + macvk）运行。
#
# 这是 M0 的「DV 验证工具」，不是产品运行时：
#   macOS 的 render API 只有 legacy gpu，gpu-next 只能走 mpv 自己的窗口
#   （cocoa-cb + Vulkan/Metal）。
#
# 用法: scripts/mpv-vk.sh [mpv 参数...]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VK="$ROOT/prefix-vk"

if [ ! -x "$VK/bin/mpv" ]; then
  echo "prefix-vk/bin/mpv 不存在，先跑 scripts/build-vk-macos.sh" >&2
  exit 1
fi

export DYLD_LIBRARY_PATH="$VK/lib:$ROOT/prefix/lib:${DYLD_LIBRARY_PATH:-}"
export VK_ICD_FILENAMES="$VK/share/vulkan/icd.d/MoltenVK_icd.json"

# 默认走 gpu-next + macvk；调用方显式指定 --vo 时以调用方为准。
has_vo=0
for a in "$@"; do
  case "$a" in --vo=*|-vo=*) has_vo=1;; esac
done

if [ "$has_vo" = 0 ]; then
  exec "$VK/bin/mpv" --vo=gpu-next --gpu-context=macvk "$@"
else
  exec "$VK/bin/mpv" "$@"
fi
