#!/bin/bash
#
# 生成一张双标题的测试原盘 ISO（只在 macOS 上验证用）。
#
# 正片 20 秒、花絮 8 秒，正好覆盖：
#   - 打开直接播默认标题（20 秒的正片，不是第一条花絮）
#   - 播放器右侧「标题」面板（正片在前、花絮在后）
#   - 切标题 / 播完关窗
#
# 用法：scripts/make-test-disc.sh [输出目录]
# 输出：<输出目录>/disc-test.iso
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/dvplayer-test-disc}"
FFMPEG="$ROOT/prefix/bin/ffmpeg"

if [ ! -x "$FFMPEG" ]; then
    echo "找不到 ffmpeg：$FFMPEG（先跑 scripts/build-deps-macos.sh）" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/BDMV/PLAYLIST" "$OUT/BDMV/STREAM" "$OUT/BDMV/META/DL"

# 两段 mpegts 当 m2ts；测试盘只需要 mpv 能解码。
"$FFMPEG" -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=480x270:rate=25" -t 20 \
    -c:v mpeg2video -b:v 2M -f mpegts "$OUT/BDMV/STREAM/00001.m2ts"
"$FFMPEG" -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=480x270:rate=25" -t 8 \
    -c:v mpeg2video -b:v 2M -f mpegts "$OUT/BDMV/STREAM/00002.m2ts"

# 最小可解析的 mpls：PlayList 段一个 PlayItem，IN/OUT 用 45 kHz 刻度。
python3 - "$OUT" <<'PY'
import pathlib
import struct
import sys

root = pathlib.Path(sys.argv[1])


def mpls(name: str, seconds: float) -> bytes:
    data = bytearray(44)
    data[8:12] = struct.pack(">I", 12)      # PlayListStart
    data[18:20] = struct.pack(">H", 1)      # PlayItem 数
    struct.pack_into(">H", data, 22, 20)    # PlayItem 长度
    data[24:29] = name.encode("ascii")      # 5 字节 clip 名
    struct.pack_into(">H", data, 33, 0)     # flags
    data[35] = 1                            # STC_sequence_id
    struct.pack_into(">I", data, 36, 0)     # IN_time
    struct.pack_into(">I", data, 40, int(seconds * 45000))  # OUT_time
    return bytes(data)


(root / "BDMV/PLAYLIST/00001.mpls").write_bytes(mpls("00001", 20))
(root / "BDMV/PLAYLIST/00002.mpls").write_bytes(mpls("00002", 8))
(root / "BDMV/META/DL/bdmt_eng.xml").write_text(
    '<?xml version="1.0" encoding="UTF-8"?>'
    "<disclib><di:discinfo><di:title><di:name>Test Disc</di:name>"
    "</di:title></di:discinfo></disclib>",
    encoding="utf-8",
)
PY

hdiutil makehybrid -quiet -o "$OUT/disc-test.iso" "$OUT" -iso -joliet
echo "$OUT/disc-test.iso"
