#!/usr/bin/env python3
"""生成服务器图标（`assets/sources/<kind>.png`）。

一套 128×128 的圆角方块图标，按源的种类给品牌色和标记：

| kind                | 图标 |
| ------------------- | ---- |
| fnos（飞牛）        | 品牌蓝底 + 飞牛官方牛头（从官方 logo 抠出来的白色剪影） |
| emby                | Emby 官方 app 图标（绿菱形 + 白三角），直接用官方位图 |
| jellyfin            | Jellyfin 官方标志（紫 → 青三角），从官方 SVG 渲染 |
| local               | 石板灰 | 文件夹 |
| smb / cifs          | 深蓝 | 共享（三点连线） |
| nfs                 | 琥珀橙 | 硬盘 |
| webdav              | 青 | 云 |

同一天空下的 GUI 都按同一个尺寸画，所以图标在服务器卡片（42 px）和
侧栏（16 px）里都直接缩放，不用出两套。

产物同时写两份：仓库共享的 `assets/sources/`（macOS 打包用），和
Windows 工程内的 `apps/windows/DvPlayer/Assets/sources/`（WPF 的
`Image Source` 只认工程内资源）。

用法（需要 Pillow）：

    python3 scripts/make-source-icons.py

Emby / Jellyfin 不用自己画的三角，直接取官方图：

- Emby：<https://emby.media/android-chrome-192x192.png>（官方 app 图标）
- Jellyfin：<https://jellyfin.org/images/logo.svg> 左边的标志，
  用 `rsvg-convert` 渲染后裁出来（没装就退回自己画的三角）

官方素材会缓存成 `assets/sources/.<kind>-official.*`，不入库。
"""

from __future__ import annotations

import io
import subprocess
import sys
import urllib.request
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    sys.exit("需要 Pillow：python3 -m pip install pillow")

ROOT = Path(__file__).resolve().parent.parent
SHARED = ROOT / "assets" / "sources"
WINDOWS = ROOT / "apps" / "windows" / "DvPlayer" / "Assets" / "sources"
LOGO_URL = "https://static2.fnnas.com/official/fnos-logo.png"
EMBY_URL = "https://emby.media/android-chrome-192x192.png"
JELLYFIN_URL = "https://jellyfin.org/images/logo.svg"

SIZE = 128
SS = 4  # 超采样倍数：先按 512 画，最后 LANCZOS 缩到 128，边缘才干净。


def rounded_plate(color: str, second: str | None = None) -> Image.Image:
    """圆角方块底；给 `second` 就是对角渐变。"""
    big = SIZE * SS
    plate = Image.new("RGBA", (big, big), (0, 0, 0, 0))

    if second:
        top = Image.new("RGB", (big, big), color)
        bottom = Image.new("RGB", (big, big), second)
        mask = Image.linear_gradient("L").resize((big, big))
        plate.paste(Image.composite(bottom, top, mask), (0, 0))
    else:
        ImageDraw.Draw(plate).rectangle([0, 0, big, big], fill=color)

    corner = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(corner).rounded_rectangle(
        [0, 0, big - 1, big - 1], radius=int(big * 0.225), fill="#FFFFFF")
    plate.putalpha(corner.getchannel("A"))
    return plate


def draw_triangle(draw: ImageDraw.ImageDraw, big: int) -> None:
    """播放三角，圆角（PIL 的 polygon 没圆角，用同色粗描边做 joint="curve"）。"""
    u = big / 128
    points = [(46 * u, 26 * u), (104 * u, 64 * u), (46 * u, 102 * u)]
    draw.polygon(points, fill="#FFFFFF")
    draw.line(points + [points[0]], fill="#FFFFFF", width=int(16 * u), joint="curve")


def fnos_mark(big: int) -> Image.Image | None:
    """从官方 logo 里抠出蓝色牛头，转成白色剪影。"""
    cached = SHARED / ".fnos-logo.png"
    if not cached.exists():
        try:
            urllib.request.urlretrieve(LOGO_URL, cached)
        except OSError as error:
            print(f"下载飞牛 logo 失败（{error}），改用播放三角", file=sys.stderr)
            return None

    logo = Image.open(cached).convert("RGBA")
    pixels = logo.load()
    mask = Image.new("L", logo.size, 0)
    target = mask.load()

    # logo 左边是蓝色图形、右边是黑色「飞牛」两个字：只取偏蓝的像素。
    for y in range(logo.size[1]):
        for x in range(logo.size[0]):
            r, g, b, a = pixels[x, y]
            if a > 40 and b > r + 40 and b > 90:
                target[x, y] = a

    box = mask.getbbox()
    if box is None:
        return None

    mask = mask.crop(box)
    width, height = mask.size
    scale = min(big * 0.72 / height, big * 0.72 / width)
    mask = mask.resize((max(1, int(width * scale)), max(1, int(height * scale))),
                       Image.LANCZOS)

    mark = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    white = Image.new("RGBA", mask.size, "#FFFFFF")
    mark.paste(white, ((big - mask.size[0]) // 2, (big - mask.size[1]) // 2), mask)
    return mark


def folder_mark(big: int) -> Image.Image:
    mark = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(mark)
    u = big / 128  # 按 128 的坐标画，再乘倍数

    def box(x0, y0, x1, y1, radius, fill="#FFFFFF"):
        d.rounded_rectangle([x0 * u, y0 * u, x1 * u, y1 * u],
                            radius=radius * u, fill=fill)

    box(30, 42, 98, 94, 9)          # 文件夹主体
    box(30, 30, 66, 52, 8)          # 标签
    box(30, 42, 98, 58, 8, "#FFFFFF")
    d.rectangle([36 * u, 58 * u, 92 * u, 88 * u], fill="#FFFFFF")
    # 中间挖一道缝，缩到 16 px 才不会像一块白砖。
    d.rounded_rectangle([36 * u, 62 * u, 92 * u, 70 * u], radius=3 * u,
                        fill=(0, 0, 0, 0))
    return mark


def share_mark(big: int) -> Image.Image:
    """SMB：三点连线的共享标记。"""
    mark = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(mark)
    u = big / 128
    nodes = [(40, 64), (78, 36), (78, 92)]
    for a, b in ((nodes[0], nodes[1]), (nodes[0], nodes[2])):
        d.line([a[0] * u, a[1] * u, b[0] * u, b[1] * u],
               fill="#FFFFFF", width=int(9 * u))
    for cx, cy in nodes:
        r = 17 * u
        d.ellipse([cx * u - r, cy * u - r, cx * u + r, cy * u + r],
                  fill="#FFFFFF")
    # 节点中心再挖空，看起来才像「共享」而不是三个实心圆。
    for cx, cy in ((78, 36), (78, 92)):
        r = 6 * u
        d.ellipse([cx * u - r, cy * u - r, cx * u + r, cy * u + r],
                  fill=(0, 0, 0, 0))
    return mark


def disk_mark(big: int) -> Image.Image:
    """NFS：一块硬盘。"""
    mark = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(mark)
    u = big / 128
    d.rounded_rectangle([28 * u, 34 * u, 100 * u, 94 * u], radius=12 * u,
                        fill="#FFFFFF")
    d.rounded_rectangle([38 * u, 44 * u, 90 * u, 68 * u], radius=6 * u,
                        fill=(0, 0, 0, 0))
    for cx in (46, 64, 82):
        r = 5 * u
        d.ellipse([cx * u - r, 80 * u - r, cx * u + r, 80 * u + r],
                  fill=(0, 0, 0, 0))
    return mark


def cloud_mark(big: int) -> Image.Image:
    """WebDAV：一朵云。"""
    mark = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(mark)
    u = big / 128
    for cx, cy, r in ((52, 70, 20), (76, 58, 25), (94, 74, 17)):
        d.ellipse([(cx - r) * u, (cy - r) * u, (cx + r) * u, (cy + r) * u],
                  fill="#FFFFFF")
    d.rounded_rectangle([52 * u, 70 * u, 94 * u, 92 * u], radius=11 * u,
                        fill="#FFFFFF")
    return mark


def fetch(url: str, cache_name: str) -> bytes | None:
    """下载一次就缓存到 `assets/sources/.<name>`，断网时也用上次的。"""
    cached = SHARED / cache_name
    if cached.exists():
        return cached.read_bytes()

    try:
        data = urllib.request.urlopen(url, timeout=30).read()
    except OSError as error:
        print(f"下载失败（{error}）：{url}", file=sys.stderr)
        return None

    cached.write_bytes(data)
    return data


def official_mark(kind: str) -> Image.Image | None:
    """Emby / Jellyfin 的官方图标（透明背景，自己带颜色）。"""
    if kind == "emby":
        data = fetch(EMBY_URL, ".emby-official.png")
        if not data:
            return None
        icon = Image.open(io.BytesIO(data)).convert("RGBA")
        return icon

    if kind != "jellyfin":
        return None

    svg = fetch(JELLYFIN_URL, ".jellyfin-logo.svg")
    if not svg:
        return None

    # 官方 logo 是「标志 + Jellyfin 字样」的横版（252×72），只留左边的标志。
    source = SHARED / ".jellyfin-logo.svg"
    raw = SHARED / ".jellyfin-logo.png"
    try:
        subprocess.run(["rsvg-convert", "-w", "1008", "-h", "288", str(source), "-o", str(raw)],
                       check=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError):
        print("没装 rsvg-convert，Jellyfin 改用自己画的三角", file=sys.stderr)
        return None

    wordmark = Image.open(raw).convert("RGBA")
    side = int(wordmark.height)
    return wordmark.crop((0, 0, side, side))  # 252:72 -> 标志占 72×72


def fit_centered(image: Image.Image, size: int, ratio: float = 0.86) -> Image.Image:
    """等比缩到 `size * ratio`，居中贴在 `size` 的透明画布上。"""
    target = max(1, int(size * ratio))
    scale = min(target / image.width, target / image.height)
    scaled = image.resize((max(1, int(image.width * scale)),
                           max(1, int(image.height * scale))), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(scaled, ((size - scaled.width) // 2, (size - scaled.height) // 2), scaled)
    return canvas


def finish(plate: Image.Image, mark: Image.Image | None) -> Image.Image:
    if mark is not None:
        plate = Image.alpha_composite(plate, mark)
    return plate.resize((SIZE, SIZE), Image.LANCZOS)


def build() -> list[Path]:
    SHARED.mkdir(parents=True, exist_ok=True)
    WINDOWS.mkdir(parents=True, exist_ok=True)
    big = SIZE * SS
    written: list[Path] = []

    specs = [
        ("fnos", "#2F6BF6", None, None),               # 飞牛：品牌蓝 + 官方牛头
        ("emby", "#52B54B", None, "triangle"),
        ("jellyfin", "#8B5CF6", "#00A4DC", "triangle"),
        ("local", "#4A5568", None, "folder"),
        ("smb", "#2B6CB0", None, "share"),
        ("nfs", "#C05621", None, "disk"),
        ("webdav", "#0E7490", None, "cloud"),
    ]

    for kind, color, second, mark_kind in specs:
        # Emby / Jellyfin 直接用官方图标（圆角方块是给剩下几种的）。
        if kind in ("emby", "jellyfin"):
            official = official_mark(kind)
            # Jellyfin 的三角本身四周就留白，撑满 128；Emby 的菱形顶到边，留一点。
            icon = (fit_centered(official, SIZE, 0.92 if kind == "emby" else 1.0)
                    if official is not None
                    else finish(rounded_plate(color, second), _triangle_mark(big)))
        else:
            icon = finish(rounded_plate(color, second),
                          _mark_for(kind, mark_kind, big))

        for directory in (SHARED, WINDOWS):
            path = directory / f"{kind}.png"
            icon.save(path, optimize=True)
            written.append(path)

    # SMB 别名也复制一份，源码里 `cifs` 这种写法也能直接取到图。
    for alias, source in (("cifs", "smb"), ("feiniu", "fnos")):
        for directory in (SHARED, WINDOWS):
            path = directory / f"{alias}.png"
            path.write_bytes((directory / f"{source}.png").read_bytes())
            written.append(path)

    return written


def _triangle_mark(big: int) -> Image.Image:
    mark = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw_triangle(ImageDraw.Draw(mark), big)
    return mark


def _mark_for(kind: str, mark_kind: str | None, big: int) -> Image.Image | None:
    if mark_kind is None:
        return fnos_mark(big) or _triangle_mark(big)
    if mark_kind == "triangle":
        return _triangle_mark(big)
    if mark_kind == "folder":
        return folder_mark(big)
    if mark_kind == "share":
        return share_mark(big)
    if mark_kind == "disk":
        return disk_mark(big)
    if mark_kind == "cloud":
        return cloud_mark(big)
    return None


if __name__ == "__main__":
    output = build()
    print(f"已生成 {len(output)} 个文件：")
    for path in output:
        print(" ", path.relative_to(ROOT))
