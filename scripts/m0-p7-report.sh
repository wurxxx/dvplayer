#!/usr/bin/env bash
# 拿到 P7 素材后的一键验收：A1（拆层 + FEL/MEL 判定）+ A2（EL 是否被重建）。
#
# 用法: m0-p7-report.sh <p7文件> [报告目录]
#
# A1 在任何机器上都能跑（只用到 ffmpeg / dovi_tool）。
# A2 需要 gpu-next（Windows d3d11，或 macOS 的 Vulkan 构建），否则会跳过并说明原因。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=env.sh
source "$ROOT/scripts/env.sh"

if [ $# -lt 1 ]; then
  echo "usage: $0 <p7.mkv|p7.m2ts|p7.mp4> [outdir]" >&2
  exit 2
fi

IN=$1
OUT=${2:-out/p7-report}
mkdir -p "$OUT"
REPORT="$OUT/report.md"
BL="$OUT/bl.hevc"
EL="$OUT/el_rpu.hevc"

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }

: > "$REPORT"
say "# P7 验收报告"
say
say "- 输入: \`$IN\`"
say "- 时间: $(date '+%Y-%m-%d %H:%M')"
say

# ---------------------------------------------------------------- 0. 探测
say "## 0. 容器探测"
say
"$ROOT/prefix/bin/ffprobe" -v error -show_streams -of default=nw=1 "$IN" \
  | grep -E '^(index|codec_name|codec_type|width|height|pix_fmt|dv_profile|el_present_flag|bl_present_flag|dv_bl_signal_compatibility_id)=' \
  > "$OUT/probe.txt" || true
say '```'
say "$(cat "$OUT/probe.txt")"
say '```'
say

videos=$(grep -c '^codec_type=video$' "$OUT/probe.txt" || true)
profile=$(sed -n 's/^dv_profile=//p' "$OUT/probe.txt" | head -1)
el_flag=$(sed -n 's/^el_present_flag=//p' "$OUT/probe.txt" | head -1)

if [ "$videos" -gt 2 ]; then
  say "视频轨数异常（${videos}），后面只取前两条。"
fi

# ---------------------------------------------------------------- 1. A1 拆层
say "## 1. A1 拆层"
say
say "视频轨数: ${videos}，dv_profile=${profile:-无}，el_present_flag=${el_flag:-无}"
say

if [ "$videos" -ge 2 ]; then
  # 双轨：BL 轨 + EL 轨，直接分流，不需要 dovi_split
  say "双轨容器：分别抽出 BL 与 EL。"
  "$ROOT/prefix/bin/ffmpeg" -hide_banner -y -i "$IN" -map 0:v:0 -c copy "$BL" 2>>"$OUT/ffmpeg.log"
  "$ROOT/prefix/bin/ffmpeg" -hide_banner -y -i "$IN" -map 0:v:1 -c copy "$EL" 2>>"$OUT/ffmpeg.log"
else
  # 单轨带内交织：dovi_split
  say "单轨带内交织：用 dovi_split 拆 BL / EL+RPU。"
  "$ROOT/prefix/bin/ffmpeg" -hide_banner -y -i "$IN" -map 0:v:0 -c copy \
    -bsf:v dovi_split=mode=bl_rpu "$BL" 2>>"$OUT/ffmpeg.log"
  "$ROOT/prefix/bin/ffmpeg" -hide_banner -y -i "$IN" -map 0:v:0 -c copy \
    -bsf:v dovi_split=mode=el_rpu "$EL" 2>>"$OUT/ffmpeg.log" || true
fi

ls -lh "$BL" "$EL" 2>/dev/null | tee -a "$REPORT" || true
say

# ---------------------------------------------------------------- 2. RPU
say "## 2. RPU / FEL 判定"
say
RPU="$OUT/rpu.bin"
rm -f "$RPU"
for src in "$EL" "$BL"; do
  [ -f "$src" ] || continue
  if "$ROOT/tools/bin/dovi_tool" extract-rpu -i "$src" -o "$RPU" >"$OUT/extract.log" 2>&1; then
    if [ -s "$RPU" ]; then
      say "RPU 来源: \`$(basename "$src")\`"
      break
    fi
  fi
done

verdict="未知"
if [ -s "$RPU" ]; then
  "$ROOT/tools/bin/dovi_tool" info -i "$RPU" -s > "$OUT/rpu-summary.txt" 2>&1 || true
  "$ROOT/tools/bin/dovi_tool" info -i "$RPU" -f 0 > "$OUT/rpu-frame0.json" 2>&1 || true

  say
  say '```'
  say "$(cat "$OUT/rpu-summary.txt")"
  say '```'

  residual=$(grep -o '"disable_residual_flag": [a-z]*' "$OUT/rpu-frame0.json" | head -1 | awk '{print $2}')
  rpu_profile=$(grep -o '"dovi_profile": [0-9]*' "$OUT/rpu-frame0.json" | head -1 | awk '{print $2}')

  say
  say "- RPU profile: ${rpu_profile:-?}"
  say "- disable_residual_flag: ${residual:-?}"

  case "$rpu_profile:$residual" in
    7:false) verdict="DV P7 (FEL)";;
    7:true)  verdict="DV P7 (MEL)";;
    7:*)     verdict="DV P7（无法判定残差标志）";;
    *:*)     verdict="DV P${rpu_profile:-?}（单层，不是 P7）";;
  esac
else
  say "没能从 BL/EL 中提取出 RPU，A1 未通过。"
fi

say
say "**A1 结论: $verdict**"
say

# ---------------------------------------------------------------- 3. A2
say "## 3. A2 增强层是否被重建"
say

gpu_out=$("$ROOT/prefix/bin/mpv" --no-config --vo=gpu-next --gpu-api=auto \
          --frames=1 --ao=null --hwdec=no --msg-level=all=error "$IN" 2>&1 || true)
if printf '%s' "$gpu_out" | grep -qiE 'Failed initializing|could not|not supported|no gpu context'; then
  say "跳过：本机 mpv 没有可用的 GPU context（macOS 需要 Vulkan 才能跑 gpu-next）。"
  say
  say "A2 需要在有 gpu-next 的环境上跑："
  say
  say '```bash'
  say "./scripts/fel-ab.sh \"$IN\" 60"
  say '```'
else
  say "gpu-next 可用，开始 A/B 截帧。"
  say
  if "$ROOT/scripts/fel-ab.sh" "$IN" 60 2>&1 | tee "$OUT/ab.txt"; then
    say
    say '```'
    say "$(cat "$OUT/ab.txt")"
    say '```'
    say
    say "判读：PSNR 18–25 dB 说明 EL 参与了重建；接近 inf 说明只播了 BL。"
  else
    say "A/B 失败，见 \`$OUT/ab.txt\`。"
  fi
fi

say
say "---"
say "产物目录: \`$OUT\`"
echo
echo "报告: $REPORT"
