#!/usr/bin/env python3
"""开发用：把一台飞牛 / Emby 源写进 macOS 壳的 settings.json。

只在验证页面时有意义，正常使用直接在「服务器」页里填。
账号密码从环境变量读，不落命令行参数，也不打印。

    FNOS_USER=xxx FNOS_PASS=yyy python3 scripts/seed-source.py [地址]

默认地址 http://10.0.0.134:8005（家里的测试机）。
"""
import json
import os
import pathlib
import sys

base = sys.argv[1] if len(sys.argv) > 1 else "http://10.0.0.134:8005"
user = os.environ.get("FNOS_USER", "")
password = os.environ.get("FNOS_PASS", "")

path = pathlib.Path.home() / "Library/Application Support/DvPlayer/settings.json"
path.parent.mkdir(parents=True, exist_ok=True)

data = {
    "sources": [{
        "id": "fnos-1",
        "name": "飞牛影视",
        "kind": "fnos",
        "base": base,
        "username": user,
        "password": password,
    }],
    "lastSourceId": "fnos-1",
    "autoConnect": True,
    "startPage": "libraries",
    "pageSize": 60,
    "showResolution": True,
    "resumePlayback": True,
}

path.write_text(json.dumps(data, ensure_ascii=False, indent=2))
print(f"written {path} (user={'set' if user else 'empty'}, password={'set' if password else 'empty'})")
