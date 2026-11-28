#!/usr/bin/env python3
"""生成真正的 HDR10 (PQ) / HLG 测试片，输出 raw yuv420p10le 到 stdout。

桌面 ffmpeg 没有 zscale / x265，所以在 numpy 里直接做传递函数：PQ 用
SMPTE ST 2084 的 OETF，HLG 用 ARIB STD-B67 的 OETF，再把编码后的 RGB 按
BT.2020 非恒定亮度矩阵转成 10-bit 有限范围 YUV。ffmpeg 只负责编码。

示例（PQ / HDR10）:
  python3 scripts/android/gen-hdr-sample.py --mode pq --seconds 10 --fps 24 \\
    | ./prefix/bin/ffmpeg -y -f rawvideo -pix_fmt yuv420p10le \\
        -s 1920x1080 -r 24 -i - \\
        -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -b:v 20M \\
        -bsf:v hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9 \\
        -tag:v hvc1 -movflags +faststart /tmp/dv-hdr10-real.mp4

HLG 把 --mode 换成 hlg，transfer_characteristics 换成 18。
"""
import argparse
import sys

import numpy as np

# SMPTE ST 2084 (PQ)
M1 = 2610.0 / 16384.0
M2 = 2523.0 / 32.0
C1 = 3424.0 / 4096.0
C2 = 2413.0 / 128.0
C3 = 2392.0 / 128.0

# ARIB STD-B67 (HLG)
HLG_A = 0.17883277
HLG_B = 0.28466892
HLG_C = 0.55991073


def pq_oetf(nits):
    """线性亮度 (cd/m^2, 0..10000) -> PQ 信号 0..1。"""
    y = np.clip(nits, 0.0, 10000.0) / 10000.0
    ym1 = np.power(y, M1)
    return np.power((C1 + C2 * ym1) / (1.0 + C3 * ym1), M2)


def hlg_oetf(scene):
    """场景线性 0..1 -> HLG 信号 0..1。"""
    s = np.clip(scene, 0.0, 1.0)
    low = np.sqrt(3.0 * s)
    high = HLG_A * np.log(np.maximum(12.0 * s - HLG_B, 1e-6)) + HLG_C
    return np.where(s <= 1.0 / 12.0, low, high)


def encode(nits, mode):
    """线性亮度（PQ 是 nits，HLG 按 1000 nit 名义峰值折算）-> 信号 0..1。"""
    if mode == "pq":
        return pq_oetf(nits)
    return hlg_oetf(np.asarray(nits, dtype=np.float32) / 1000.0)


def pattern(width, height, max_nits, bar_nits):
    """静态测试图，线性亮度 nits，形状 (H, W, 3)。"""
    yy, xx = np.mgrid[0:height, 0:width].astype(np.float32)
    u = xx / max(width - 1, 1)
    v = yy / max(height - 1, 1)

    rgb = np.zeros((height, width, 3), dtype=np.float32)

    # 上 25%：0..max_nits 的横向灰阶斜坡（看高光滚降）
    top = v < 0.25
    if top.any():
        rgb[top] = np.repeat((u * max_nits)[..., None], 3, axis=-1)[top]

    # 25%..58%：8 条色条，每个通道按 bar_nits 点亮
    bars = np.array(
        [
            [1, 1, 1],  # white
            [1, 1, 0],  # yellow
            [0, 1, 1],  # cyan
            [0, 1, 0],  # green
            [1, 0, 1],  # magenta
            [1, 0, 0],  # red
            [0, 0, 1],  # blue
            [0, 0, 0],  # black
        ],
        dtype=np.float32,
    )
    mid = (v >= 0.25) & (v < 0.58)
    if mid.any():
        idx = np.clip((u * 8).astype(np.int32), 0, 7)
        rgb[mid] = (bars[idx] * bar_nits)[mid]

    # 58%..82%：8 级灰阶，覆盖近黑到高光
    steps = np.array([0.0, 1.0, 10.0, 100.0, 200.0, 400.0, 700.0, 1000.0], dtype=np.float32)
    low = (v >= 0.58) & (v < 0.82)
    if low.any():
        sidx = np.clip((u * 8).astype(np.int32), 0, 7)
        rgb[low] = np.repeat(steps[sidx][..., None], 3, axis=-1)[low]

    return rgb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["pq", "hlg"], default="pq")
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--fps", type=float, default=24.0)
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--max-nits", type=float, default=1000.0)
    ap.add_argument("--bar-nits", type=float, default=400.0)
    args = ap.parse_args()

    width = args.width - (args.width % 2)
    height = args.height - (args.height % 2)
    frames = max(1, int(round(args.seconds * args.fps)))

    base = pattern(width, height, args.max_nits, args.bar_nits)

    # 底部一个 1000 nit 的白色方块左右移动，方便看运动与帧率
    sq_h = int(height * 0.12)
    sq_w = int(width * 0.10)
    sq_y0 = int(height * 0.86)
    sq_y1 = min(height, sq_y0 + sq_h)

    out = sys.stdout.buffer
    for i in range(frames):
        rgb = base.copy()
        travel = width - sq_w
        x0 = int((i / max(frames - 1, 1)) * travel)
        rgb[sq_y0:sq_y1, x0 : x0 + sq_w] = 1000.0

        sig = encode(rgb, args.mode)

        r, g, b = sig[..., 0], sig[..., 1], sig[..., 2]
        # BT.2020 非恒定亮度
        y = 0.2627 * r + 0.6780 * g + 0.0593 * b
        cb = (b - y) / 1.8814
        cr = (r - y) / 1.4746

        y10 = np.clip(64.0 + 876.0 * y, 0, 1023).astype(np.uint16)
        cb10 = np.clip(512.0 + 896.0 * cb, 0, 1023)
        cr10 = np.clip(512.0 + 896.0 * cr, 0, 1023)

        # 4:2:0
        cb10 = cb10.reshape(height // 2, 2, width // 2, 2).mean(axis=(1, 3))
        cr10 = cr10.reshape(height // 2, 2, width // 2, 2).mean(axis=(1, 3))
        cb10 = np.clip(np.rint(cb10), 0, 1023).astype(np.uint16)
        cr10 = np.clip(np.rint(cr10), 0, 1023).astype(np.uint16)

        out.write(y10.astype("<u2").tobytes())
        out.write(cb10.astype("<u2").tobytes())
        out.write(cr10.astype("<u2").tobytes())


if __name__ == "__main__":
    main()
