#!/usr/bin/env python3
"""从 MEGA 公开链接下载 P7 FEL 测试片。

用法: fetch-p7-public.py <mega-url> <输出文件>
MEGA 的公开链接不需要账号，但需要走 MEGA 的加密协议，
所以用 mega.py 而不是普通 HTTP 下载。
"""
from __future__ import annotations

import os
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    url, out = sys.argv[1], sys.argv[2]
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)

    try:
        from mega import Mega
    except ImportError:
        print("mega.py 未安装：python3 -m pip install --user mega.py", file=sys.stderr)
        return 2

    m = Mega()
    print(f"[mega] {url}", flush=True)
    print(f"[mega] -> {out}", flush=True)
    try:
        path = m.download_url(url, dest_path=os.path.dirname(out) or ".",
                              dest_filename=os.path.basename(out))
    except Exception as exc:  # noqa: BLE001
        print(f"[mega] 失败: {exc}", file=sys.stderr)
        return 1

    print(f"[mega] saved: {path}", flush=True)
    if path and os.path.isfile(path):
        print(f"[mega] size: {os.path.getsize(path)}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
