#!/usr/bin/env bash
# 给 HDR10 样片注入 HDR10+ 动态元数据（SMPTE ST 2094-40）。
#
# 依赖：
#   - ffmpeg / ffprobe
#   - hdr10plus_tool（https://github.com/quietvoid/hdr10plus_tool，1.7.2 验过）
#
# 用法：
#   scripts/android/gen-hdr10plus-sample.sh 输入.mp4 输出.mp4 [hdr10plus_tool]
#
# 输入应当是 gen-hdr-sample.py 产出的真 PQ 片源（BT.2020 / PQ / Main10）。
# 输出每帧都带 ST2094-40 SEI，mpv 软解后 video-params/scene-max-* 能读出来。
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "用法: $0 <输入 HDR10 mp4> <输出 mp4> [hdr10plus_tool]" >&2
    exit 2
fi

INPUT=$1
OUTPUT=$2
TOOL=${3:-hdr10plus_tool}
FFMPEG=${FFMPEG:-ffmpeg}
FFPROBE=${FFPROBE:-ffprobe}

command -v "$TOOL" >/dev/null 2>&1 || { echo "找不到 hdr10plus_tool: $TOOL" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 帧数决定注入多少条元数据。
FRAMES=$("$FFPROBE" -v error -select_streams v:0 -count_frames \
    -show_entries stream=nb_read_frames -of csv=p=0 "$INPUT")
if [ -z "$FRAMES" ] || [ "$FRAMES" -le 0 ] 2>/dev/null; then
    echo "读不到帧数: $INPUT" >&2
    exit 1
fi
echo "帧数: $FRAMES"

# 每帧一条元数据；MaxScl / 直方图取一组固定的中高亮内容，便于和 mpv 读出的
# video-params/scene-max-* 对数。
python3 - "$FRAMES" "$WORK/hdr10plus.json" <<'PY'
import json
import sys

frames = int(sys.argv[1])
out = sys.argv[2]

entry = {
    "BezierCurveData": {
        "Anchors": [143, 298, 447, 592, 731, 864, 891, 917, 938],
        "KneePointX": 164,
        "KneePointY": 240,
    },
    "LuminanceParameters": {
        "AverageRGB": 263,
        "LuminanceDistributions": {
            "DistributionIndex": [1, 5, 10, 25, 50, 75, 90, 95, 99],
            "DistributionValues": [0, 6080, 92, 1, 4, 107, 726, 1784, 5843],
        },
        "MaxScl": [7768, 6589, 6912],
    },
    "NumberOfWindows": 1,
    "TargetedSystemDisplayMaximumLuminance": 400,
    "SceneId": 0,
}

scenes = []
for i in range(frames):
    item = dict(entry)
    item["SceneFrameIndex"] = i
    item["SequenceFrameIndex"] = i
    scenes.append(item)

json.dump(
    {
        "JSONInfo": {"HDR10plusProfile": "B", "Version": "1.0"},
        "SceneInfo": scenes,
        "SceneInfoSummary": {
            "SceneFirstFrameIndex": list(range(frames)),
            "SceneFrameNumbers": [1] * frames,
        },
        "ToolInfo": {"Tool": "hdr10plus_tool", "Version": "1.7.2"},
    },
    open(out, "w"),
)
PY

# mp4 -> Annex B 裸流 -> 注入 SEI -> 封回 mp4。
"$FFMPEG" -hide_banner -loglevel error -y -i "$INPUT" \
    -c:v copy -bsf:v hevc_mp4toannexb -f hevc "$WORK/in.hevc"

"$TOOL" inject --json "$WORK/hdr10plus.json" "$WORK/in.hevc" -o "$WORK/out.hevc"

# 注入后校验：提取出来的条数应当等于帧数。
"$TOOL" extract "$WORK/out.hevc" -o "$WORK/check.json"
COUNT=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["SceneInfo"]))' "$WORK/check.json")
echo "提取到 $COUNT 条 HDR10+ 元数据"
[ "$COUNT" = "$FRAMES" ] || { echo "条数与帧数不一致" >&2; exit 1; }

# 用输入片源的 VUI 重新封装，保证色彩标签不被丢掉。
"$FFMPEG" -hide_banner -loglevel error -y -fflags +genpts -r 24 -i "$WORK/out.hevc" \
    -c:v copy -tag:v hvc1 \
    -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv \
    -movflags +faststart "$OUTPUT"

"$FFPROBE" -hide_banner -loglevel error \
    -show_entries stream=codec_name,profile,pix_fmt,color_transfer,color_primaries,nb_frames \
    -of default=nw=1 "$OUTPUT"
echo "完成: $OUTPUT"
