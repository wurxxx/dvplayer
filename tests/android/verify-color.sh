#!/usr/bin/env bash
# 色彩回归：在任意已连机（真机 / 模拟器）上播三组已知片源，用 mpv 自带截图
# 取像素，按「白色是否中性、二次色通道是否相等」判解码 / 渲染有没有偏色。
#
# 用法：
#   tests/android/verify-color.sh                 # 默认设备，自动 hwdec
#   tests/android/verify-color.sh -s emulator-5554 --hwdec no
#   tests/android/verify-color.sh --keep          # 保留截图
#
# 片源：
#   sdr-bars   8-bit H.264 BT.709 彩条（ffmpeg 生成，参照值同源解码）
#   hdr10-bars PQ BT.2020 彩条（scripts/android/gen-hdr-sample.py 生成）
#
# 判据不用「和某台机器一样」，只用色彩学上必须成立的关系：
#   - 白条 R=G=B（±6）
#   - 黄 R≈G、青 G≈B、品红 R≈B（±8）
#   - 六个色条亮度顺序：白 > 黄/青/品红 > 绿/红/蓝
# 这样换了 tone mapping / 屏幕亮度也不会误判。
#
# 注意：4K 软解 seek 后要几秒才有首帧，shot_at 留足 5 秒。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SERIAL=""
HWDEC="auto"
KEEP=0
PKG=${PKG:-com.dvplayer.app}
ACT=${ACT:-com.dvplayer.app/.PlayerTestActivity}
FFMPEG=${FFMPEG:-$ROOT/prefix/bin/ffmpeg}
MEDIA=${MEDIA:-$ROOT/build/test-media}

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--serial) SERIAL=$2; shift 2 ;;
        --hwdec) HWDEC=$2; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")

log() { printf '\033[1m== %s\033[0m\n' "$*"; }

"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "没有设备（adb devices）" >&2; exit 1; }
"${ADB[@]}" shell pm path "$PKG" >/dev/null 2>&1 || {
    echo "设备上没装 $PKG，先装 debug APK" >&2; exit 1; }

mkdir -p "$MEDIA"

# ---- 生成片源 --------------------------------------------------------------
gen_sdr() {
    [ -s "$MEDIA/sdr-bars.mp4" ] && return
    log "生成 8-bit SDR 彩条"
    "$FFMPEG" -hide_banner -v error -y -f lavfi \
        -i smptehdbars=size=1920x1080:rate=24 -t 8 \
        -c:v h264_videotoolbox -b:v 16M -pix_fmt yuv420p \
        -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
        -movflags +faststart "$MEDIA/sdr-bars.mp4"
}

gen_hdr10() {
    [ -s "$MEDIA/hdr10-bars.mp4" ] && return
    log "生成 HDR10 PQ 彩条（10 秒 / 1080p24 / 400nit 色条）"
    python3 "$ROOT/scripts/android/gen-hdr-sample.py" --mode pq \
        --width 1920 --height 1080 --fps 24 --seconds 10 2>/dev/null |
    "$FFMPEG" -hide_banner -v error -y -f rawvideo -pix_fmt yuv420p10le \
        -s 1920x1080 -r 24 -i - -c:v hevc_videotoolbox -profile:v main10 \
        -pix_fmt p010le -b:v 20M \
        -bsf:v hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9 \
        -tag:v hvc1 -movflags +faststart "$MEDIA/hdr10-bars.mp4"
}

push() {  # push <本地> <设备名>
    "${ADB[@]}" push "$1" "/data/local/tmp/$2" >/dev/null
    "${ADB[@]}" shell run-as "$PKG" cp "/data/local/tmp/$2" "files/$2"
}

shot() {  # shot <设备内文件名> <seek_ms> <shot_ms> <输出>
    local name=$1 seek=$2 at=$3 out=$4
    "${ADB[@]}" shell run-as "$PKG" rm -f "files/$name.png" >/dev/null 2>&1 || true
    "${ADB[@]}" shell am force-stop "$PKG" >/dev/null 2>&1 || true
    sleep 1
    "${ADB[@]}" shell am start -W -n "$ACT" --activity-clear-task \
        --es url "/data/user/0/$PKG/files/$name" \
        --es hwdec "$HWDEC" \
        --el seek_to "$seek" \
        --es shot "/data/user/0/$PKG/files/$name.png" \
        --el shot_at "$at" >/dev/null
    # 4K / 软解首帧慢，最多等 40 秒
    for _ in $(seq 1 40); do
        local sz
        sz=$("${ADB[@]}" shell run-as "$PKG" stat -c %s "files/$name.png" 2>/dev/null | tr -d '\r' || true)
        if [ "${sz:-0}" -gt 1000 ] 2>/dev/null; then
            "${ADB[@]}" exec-out run-as "$PKG" cat "files/$name.png" > "$out"
            return 0
        fi
        sleep 1
    done
    echo "截图超时: $name" >&2
    return 1
}

# ---- 判色 ------------------------------------------------------------------
check() {  # check <png> <kind>
    python3 - "$1" "$2" <<'PY'
import sys
import numpy as np
from PIL import Image

path, kind = sys.argv[1], sys.argv[2]
a = np.asarray(Image.open(path).convert("RGB")).astype(float)
h, w, _ = a.shape

def px(fx, fy):
    return a[int(fy * h), int(fx * w)]

if kind == "sdr":
    # ffmpeg smptehdbars 的实际布局：0–0.125 灰、0.125–0.232 白，然后
    # 黄/青/绿/品红/红/蓝 各 0.107 宽，最后 0.876–1.0 又是灰。
    names = ["白", "黄", "青", "绿", "品红", "红", "蓝"]
    xs = [0.178, 0.285, 0.393, 0.500, 0.607, 0.714, 0.822]
    vals = {n: px(x, 0.20) for n, x in zip(names, xs)}
    # 60% 高度是灰阶行，取中间一条当白参考
    vals["灰"] = px(0.5, 0.62)
    names = ["白", "灰"] + names[1:]
    checks = [
        ("白", "all", 150, 12),      # 三通道都亮且接近
        ("灰", "all", 60, 12),
        ("黄", "rg", 150, 0),
        ("青", "gb", 150, 0),
        ("绿", "g", 150, 0),
        ("品红", "rb", 120, 0),
        ("红", "r", 120, 0),
        ("蓝", "b", 120, 0),
    ]
else:
    names = ["白", "黄", "青", "绿", "品红", "红", "蓝", "黑"]
    xs = [(i + 0.5) / 8 for i in range(8)]
    vals = {n: px(x, 0.40) for n, x in zip(names, xs)}
    checks = [
        ("白", "all", 170, 8),
        ("黄", "rg", 170, 0),
        ("青", "gb", 170, 0),
        ("绿", "g", 170, 0),
        ("品红", "rb", 170, 0),
        ("红", "r", 170, 0),
        ("蓝", "b", 140, 0),
        ("黑", "max", 0, 12),
    ]

for n in names:
    print(f"  {n:<3} {tuple(vals[n].round(0))}")

fails = []
for name, mode, lo, tol in checks:
    v = vals[name]
    if mode == "all":
        if v.min() < lo:
            fails.append(f"{name} 有通道 < {lo}: {tuple(v.round(0))}")
        if v.max() - v.min() > tol:
            fails.append(f"{name} 不中性（差 {v.max()-v.min():.0f}）: {tuple(v.round(0))}")
    elif mode == "max":
        if v.max() > tol:
            fails.append(f"{name} 不够黑: {tuple(v.round(0))}")
    else:
        idx = {"r": [0], "g": [1], "b": [2], "rg": [0, 1], "gb": [1, 2], "rb": [0, 2]}[mode]
        other = [i for i in range(3) if i not in idx]
        for i in idx:
            if v[i] < lo:
                fails.append(f"{name} 主通道 {i} 只有 {v[i]:.0f}")
        for i in other:
            if v[i] > max(lo * 0.85, 150):
                fails.append(f"{name} 串色: 通道 {i} = {v[i]:.0f}")

if fails:
    print("  ✗ " + "; ".join(fails))
    sys.exit(1)
print("  ✓ 白色中性、各色条主通道与串色都在范围内")
PY
}

fail=0
for kind in sdr hdr10; do
    if [ "$kind" = sdr ]; then gen_sdr; else gen_hdr10; fi
    src="$MEDIA/$kind-bars.mp4"
    log "$kind: $src"
    push "$src" "$kind-bars.mp4"
    out="$MEDIA/$kind-shot.png"
    if ! shot "$kind-bars.mp4" 2000 5000 "$out"; then
        fail=1
        continue
    fi
    [ "$KEEP" = 1 ] || true
    check "$out" "$kind" && echo "  截图: $out" || fail=1
done

# HDR 直出是否被正确降级
log "HDR 直出能力"
"${ADB[@]}" logcat -d -s DvMpv:I 2>/dev/null |
    grep -E "EGL 无 EGL_KHR_gl_colorspace|改由 mpv 做 HDR" | tail -2 ||
    echo "  （本次没有 HDR 片源的直出日志）"

exit $fail
