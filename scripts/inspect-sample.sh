#!/usr/bin/env bash
# 判断一个文件到底是哪种 Dolby Vision：P5 / P7(FEL|MEL) / P8.x / 只有 HDR10。
# 只用 ffprobe，不依赖 mpv（mpv 0.42 没有 DV profile 属性）。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=env.sh
source "$ROOT/scripts/env.sh"

if [ $# -lt 1 ]; then
  echo "usage: $0 <file>" >&2
  exit 2
fi

in=$1

# 用 -show_streams（不是 csv）避免 TS program 把同一条流重复输出
probe=$("$ROOT/prefix/bin/ffprobe" -v error -show_streams -of default=nw=1 "$in" 2>/dev/null)
dur=$("$ROOT/prefix/bin/ffprobe" -v error -show_entries format=duration -of csv=p=0 "$in" 2>/dev/null)


videos=$(printf '%s\n' "$probe" | grep -c '^codec_type=video$' || true)
profile=$(printf '%s\n' "$probe" | sed -n 's/^dv_profile=//p' | head -1)
el=$(printf '%s\n' "$probe" | sed -n 's/^el_present_flag=//p' | head -1)
bl=$(printf '%s\n' "$probe" | sed -n 's/^bl_present_flag=//p' | head -1)
compat=$(printf '%s\n' "$probe" | sed -n 's/^dv_bl_signal_compatibility_id=//p' | head -1)
pix=$(printf '%s\n' "$probe" | sed -n 's/^pix_fmt=//p' | head -1)
wh=$(printf '%s\n' "$probe" | sed -n 's/^width=//p' | head -1)
ht=$(printf '%s\n' "$probe" | sed -n 's/^height=//p' | head -1)


printf 'file      : %s\n' "$in"
printf 'video     : %s 条视频轨，%sx%s，%s\n' "${videos:-0}" "${wh:--}" "${ht:--}" "${pix:--}"
printf 'duration  : %s 秒\n' "${dur:--}"

if [ -z "${profile:-}" ]; then
  echo
  echo "结论: 没有 Dolby Vision 配置记录（普通 HDR10 / SDR，或双轨容器没写 DOVI 记录）"
  if [ "${videos:-0}" -gt 1 ]; then
    echo "      注意：有 $videos 条视频轨，可能是双轨 P7，用 scripts/m0-p7-report.sh 进一步判断"
  fi
  exit 0
fi

printf 'dv_profile: %s\n' "$profile"
printf 'el_present: %s\n' "${el:--}"
printf 'bl_present: %s\n' "${bl:--}"
printf 'bl_compat : %s\n' "${compat:--}"
echo

case "$profile:$el" in
  7:1) echo "结论: Dolby Vision Profile 7，双层。跑 scripts/m0-p7-report.sh 判定 FEL/MEL";;
  7:0) echo "结论: 标称 P7 但没有增强层（el_present_flag=0），实际只能当单层用";;
  5:*) echo "结论: Profile 5（单层 IPTPQc2，无 EL，无 HDR10 兼容）";;
  8:*) echo "结论: Profile 8.x（单层 BL+RPU，compat=$compat；1=HDR10 兼容）";;
  4:*) echo "结论: Profile 4";;
  *)   echo "结论: Profile $profile（el_present=${el:-?}）";;
esac
