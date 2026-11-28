#!/usr/bin/env bash
# DV 链路回归：Dolby Vision 元数据有没有真的送到渲染器。
#
# 只看一条日志（最快，不依赖屏幕亮度 / 截图路径）：
#   [vd] Decoder format: ... dolbyvision/<prim>/<trc>/...
#
# 出现 `auto/auto/auto` 就是断了，P5 的 IPTPQc2 会被当成 BT.2020 解 → 发紫。
# 两个已知断点：
#   1. libplacebo 没开 -Ddovi=enabled → mpv 的 mp_image.c 里整段 DV 映射被
#      #ifdef PL_HAVE_LAV_DOLBY_VISION 编掉（这个宏由 PL_HAVE_DOVI 门控）；
#   2. mediacodec 硬解不吐 AV_FRAME_DATA_DOVI_METADATA → 必须 hwdec=no。
# 所以本脚本固定 `--es hwdec no`。
#
# 用法：
#   tests/android/verify-dv.sh                          # 默认 samples/p5.mkv
#   tests/android/verify-dv.sh /path/to/p5.mkv -s emulator-5554
#   tests/android/verify-dv.sh --keep                   # 保留设备上的截图
#
# 片源必须是 P5（profile 5）——它没有 BT.2020/PQ 兼容层，链路一断颜色必错。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PKG=${PKG:-com.dvplayer.app}
ACT=${ACT:-com.dvplayer.app/.PlayerTestActivity}
FILE=$ROOT/samples/p5.mkv
SERIAL=""
KEEP=0
SEEK_MS=5000
SHOT_MS=6500

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--serial) SERIAL=$2; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --seek-ms) SEEK_MS=$2; shift 2 ;;
        --shot-at) SHOT_MS=$2; shift 2 ;;
        *) FILE=$1; shift ;;
    esac
done

ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")

log() { printf '\033[1m== %s\033[0m\n' "$*"; }

"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "没有设备（adb devices）" >&2; exit 1; }
"${ADB[@]}" shell pm path "$PKG" >/dev/null 2>&1 || {
    echo "设备上没装 $PKG，先装 debug APK" >&2; exit 1; }

[ -s "$FILE" ] || { echo "找不到片源：$FILE" >&2; exit 1; }

name=$(basename "$FILE")
log "推送 $name"
"${ADB[@]}" push "$FILE" "/data/local/tmp/$name" >/dev/null
"${ADB[@]}" shell run-as "$PKG" cp "/data/local/tmp/$name" "files/$name"

shot=files/dv-verify.png
"${ADB[@]}" shell run-as "$PKG" rm -f "$shot" >/dev/null 2>&1 || true
"${ADB[@]}" shell am force-stop "$PKG" >/dev/null 2>&1 || true
"${ADB[@]}" logcat -c || true

log "起播（hwdec=no，seek ${SEEK_MS}ms）"
"${ADB[@]}" shell am start -W -n "$ACT" --activity-clear-task \
    --es url "/data/user/0/$PKG/files/$name" \
    --es hwdec no \
    --es log 1 \
    --el seek_to "$SEEK_MS" \
    --es shot "/data/user/0/$PKG/files/dv-verify.png" \
    --el shot_at "$SHOT_MS" >/dev/null

# 起播 + 4K 软解首帧：等日志出现 dolbyvision，最多 60 秒。
line=""
for _ in $(seq 1 60); do
    line=$("${ADB[@]}" logcat -d -v brief 2>/dev/null |
        grep -E "Decoder format: .*dolbyvision/" | head -1 || true)
    [ -n "$line" ] && break
    sleep 1
done

if [ -z "$line" ]; then
    echo "✗ 没等到 dolbyvision 的 Decoder format，最近一条：" >&2
    "${ADB[@]}" logcat -d -v brief | grep -E "Decoder format" | tail -2 >&2 || true
    echo "  排查：libplacebo 是否 -Ddovi=enabled（跑 build-mpv.sh 看 verify），" >&2
    echo "        是否被硬解接管（日志里找 hwdec / mediacodec）" >&2
    exit 1
fi
echo "  ${line#*): }"

# 截图单独回报，只做人工判读：绝对亮度跨端不可比（未缩放截图固定走 sRGB 目标），
# 色相才可比。品红的特征是 R/G、B/G 都 > 1。
for _ in $(seq 1 40); do
    sz=$("${ADB[@]}" shell run-as "$PKG" stat -c %s "$shot" 2>/dev/null | tr -d '\r' || true)
    if [ "${sz:-0}" -gt 1000 ] 2>/dev/null; then
        out="$ROOT/build/test-media/dv-verify.png"
        mkdir -p "$(dirname "$out")"
        "${ADB[@]}" exec-out run-as "$PKG" cat "$shot" >"$out"
        python3 - "$out" <<'PY'
import sys
import numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(float)
rows = np.where((a.sum(axis=2) > 20).mean(axis=1) > 0.5)[0]
sub = a[rows.min():rows.max() + 1]
lum = sub @ np.array([0.2126, 0.7152, 0.0722])
hi = sub[lum >= np.percentile(lum, 95)].reshape(-1, 3).mean(axis=0)
print(f"  截图 {sub.shape[1]}x{sub.shape[0]}  均值 {tuple(sub.reshape(-1,3).mean(axis=0).round(0))}")
print(f"  亮度前 5% {tuple(hi.round(0))}  R/G={hi[0]/max(hi[1],1):.3f} B/G={hi[2]/max(hi[1],1):.3f}")
PY
        [ "$KEEP" -eq 1 ] || "${ADB[@]}" shell run-as "$PKG" rm -f "$shot" >/dev/null 2>&1 || true
        break
    fi
    sleep 1
done
[ "${sz:-0}" -gt 1000 ] 2>/dev/null || echo "  （没等到截图，只做了日志判据）"

"${ADB[@]}" shell am force-stop "$PKG" >/dev/null 2>&1 || true
log "✓ DV 元数据已进渲染器"
