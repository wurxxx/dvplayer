#!/usr/bin/env python3
"""生成 MSIX 需要的方形 / 宽幅图标。

来源是 Windows 应用图标 apps/windows/DvPlayer/Assets/DvPlayer-256.png，
输出到 apps/windows/packaging/Assets/。改了品牌图后重跑：

    python3 scripts/make-msix-assets.py
"""

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "apps/windows/DvPlayer/Assets/DvPlayer-256.png"
OUT = ROOT / "apps/windows/packaging/Assets"

TILE_BG = (20, 20, 25, 255)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    src = Image.open(SRC).convert("RGBA")

    for name, size in {
        "Square44x44Logo.png": 44,
        "Square71x71Logo.png": 71,
        "Square150x150Logo.png": 150,
        "Square310x310Logo.png": 310,
        "StoreLogo.png": 50,
    }.items():
        src.resize((size, size), Image.LANCZOS).save(OUT / name)

    wide = Image.new("RGBA", (310, 150), TILE_BG)
    icon = src.resize((110, 110), Image.LANCZOS)
    wide.alpha_composite(icon, ((310 - 110) // 2, (150 - 110) // 2))
    wide.convert("RGB").save(OUT / "Wide310x150Logo.png")


if __name__ == "__main__":
    main()
