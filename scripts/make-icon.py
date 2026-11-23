#!/usr/bin/env python3
"""生成两端的应用图标。

- Windows：`apps/windows/DvPlayer/Assets/DvPlayer.ico`（多尺寸 ICO，16 px 下
  自动用更粗的三角形版本，避免糊成一团）。
- macOS：`assets/branding/AppIcon.icns`（`build.sh` 拷进 .app，Dock / Finder 用）。
- 两份预览：`assets/branding/DvPlayer-256.png` 与 Windows 工程内的一份。

图形和侧栏 logo 一致：琥珀色圆角方块 + 深色摄像机（Segoe MDL2 `Video` 的简化版）。

用法（需要 Pillow；macOS 图标还要系统的 iconutil）：

    python3 scripts/make-icon.py
"""

from __future__ import annotations

import io
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    sys.exit("需要 Pillow：python3 -m pip install pillow")

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "apps" / "windows" / "DvPlayer" / "Assets" / "DvPlayer.ico"
# 品牌图两份：仓库里共享的 256 PNG（macOS 打包用），和 Windows 工程里的一份
# （WPF 的 `Image Source` 只认工程内资源）。
PREVIEW = ROOT / "assets" / "branding" / "DvPlayer-256.png"
WINDOWS_PREVIEW = ROOT / "apps" / "windows" / "DvPlayer" / "Assets" / "DvPlayer-256.png"
# macOS 的 .app 图标；Info.plist 的 CFBundleIconFile 指向它（不带扩展名）。
ICNS = ROOT / "assets" / "branding" / "AppIcon.icns"

AMBER_TOP = (255, 194, 74, 255)     # #FFC24A
AMBER_BOTTOM = (245, 160, 0, 255)   # #F5A000
INK = (26, 18, 0, 255)              # #1A1200，和侧栏 logo 的深色字形一致

SIZES = [16, 24, 32, 48, 64, 128, 256]
MASTER = 1024


def draw_master() -> Image.Image:
    """1024 px 母版：渐变底 + 摄像机。"""
    image = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))

    # 圆角方块用竖向渐变：画一张渐变图，再按圆角蒙版裁。
    gradient = Image.new("RGBA", (MASTER, MASTER))
    for y in range(MASTER):
        t = y / (MASTER - 1)
        color = tuple(
            round(AMBER_TOP[i] * (1 - t) + AMBER_BOTTOM[i] * t) for i in range(4)
        )
        ImageDraw.Draw(gradient).line([(0, y), (MASTER, y)], fill=color)

    mask = Image.new("L", (MASTER, MASTER), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [32, 32, MASTER - 32, MASTER - 32], radius=216, fill=255
    )
    image.paste(gradient, (0, 0), mask)

    draw = ImageDraw.Draw(image)
    s = MASTER / 256  # 按 256 坐标系设计，放大到母版

    # 摄像机机身
    draw.rounded_rectangle(
        [52 * s, 88 * s, 164 * s, 168 * s], radius=18 * s, fill=INK
    )
    # 镜头（右侧三角形，尖端朝机身）
    draw.polygon(
        [
            (176 * s, 116 * s),
            (204 * s, 96 * s),
            (204 * s, 160 * s),
            (176 * s, 140 * s),
        ],
        fill=INK,
    )
    return image


def draw_small(size: int) -> Image.Image:
    """16–32 px：只留圆角方块 + 粗三角。

    先在 256 上画再降采样，直接按 16 画会得到锯齿；简化图形在 16 px
    也认得出来，摄像机那种细结构会糊成一团。
    """
    canvas = 256
    image = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    draw.rounded_rectangle(
        [0, 0, canvas - 1, canvas - 1], radius=58, fill=AMBER_BOTTOM
    )
    # 视觉重心稍微右移，三角形的尖端别顶到边。
    draw.polygon(
        [(canvas * 0.33, canvas * 0.24), (canvas * 0.33, canvas * 0.76),
         (canvas * 0.75, canvas * 0.5)],
        fill=INK,
    )
    return image.resize((size, size), Image.LANCZOS)


def _bmp_frame(image: Image.Image) -> bytes:
    """ICO 里的 BMP 帧：BITMAPINFOHEADER + BGRA（自下而上）+ AND 掩码。

    小尺寸用 BMP 兼容性最好，Pillow 的 ICO 写入器只会把一张图缩放，
    没法让 16 / 32 用单独画的那版，所以这里自己拼 ICO。
    """
    image = image.convert("RGBA")
    width, height = image.size
    header = struct.pack(
        "<IiiHHIIiiII",
        40,              # biSize
        width,
        height * 2,      # XOR + AND 两张图叠起来
        1,               # biPlanes
        32,              # biBitCount
        0,               # biCompression = BI_RGB
        width * height * 4,
        0, 0, 0, 0,
    )
    pixels = image.tobytes("raw", "BGRA")  # DIB 的字节序是 B, G, R, A
    rows = [pixels[y * width * 4:(y + 1) * width * 4] for y in range(height)]
    xor = b"".join(rows[::-1])

    mask_row = ((width + 31) // 32) * 4  # 1bpp，按 4 字节对齐
    and_mask = bytes(mask_row * height)
    return header + xor + and_mask


def _png_frame(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def write_ico(path: Path, frames: list[Image.Image]) -> None:
    """frames 按尺寸从小到大；每帧都用自己那份位图，不互相缩放。"""
    payloads = [
        (_png_frame(image) if image.size[0] >= 128 else _bmp_frame(image), image.size[0])
        for image in frames
    ]
    offset = 6 + 16 * len(payloads)
    directory = bytearray(struct.pack("<HHH", 0, 1, len(payloads)))
    for data, size in payloads:
        directory += struct.pack(
            "<BBBBHHII",
            0 if size >= 256 else size,
            0 if size >= 256 else size,
            0, 0, 1, 32, len(data), offset,
        )
        offset += len(data)
    path.write_bytes(bytes(directory) + b"".join(data for data, _ in payloads))


def write_icns(master: Image.Image) -> None:
    """iconutil 只认 .iconset 目录：先按 Apple 要求的尺寸导出，再合成 ICNS。

    Linux 上没有 iconutil，跳过（Windows 的 ico 仍会生成）。
    """
    if shutil.which("iconutil") is None:
        print("跳过 macOS 图标：没有 iconutil")
        return

    ICNS.parent.mkdir(parents=True, exist_ok=True)
    iconset = Path(tempfile.mkdtemp(suffix=".iconset"))
    try:
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                master.resize((size * scale, size * scale), Image.LANCZOS).save(
                    iconset / f"icon_{size}x{size}{suffix}.png"
                )
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(ICNS)], check=True
        )
    finally:
        shutil.rmtree(iconset, ignore_errors=True)


def main() -> None:
    master = draw_master()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    preview = master.resize((256, 256), Image.LANCZOS)
    PREVIEW.parent.mkdir(parents=True, exist_ok=True)
    preview.save(PREVIEW)
    WINDOWS_PREVIEW.parent.mkdir(parents=True, exist_ok=True)
    preview.save(WINDOWS_PREVIEW)

    # ICO 里每个尺寸都单独画，避免小图糊掉。
    frames = [draw_small(size) if size <= 32 else master.resize((size, size), Image.LANCZOS)
              for size in SIZES]
    write_ico(OUT, frames)
    write_icns(master)
    print(f"已生成：{OUT}")
    print(f"        {ICNS}")
    print(f"预览：  {PREVIEW}")
    print(f"       {WINDOWS_PREVIEW}")


if __name__ == "__main__":
    main()
