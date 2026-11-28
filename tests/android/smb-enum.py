#!/usr/bin/env python3
"""用 SMB2 的 srvsvc.NetShareEnumAll 列出共享名（Finder 连上 NAS 后显示的那种列表）。

凭据从环境变量读：SMB_HOST / SMB_USER / SMB_PASS / SMB_DOMAIN。
结果写到 TEMP 下的 dv-smb-enum.txt，供人工确认；stdout 只给一行状态。
"""
import os
import sys
import tempfile
import traceback

from impacket.smbconnection import SMBConnection

HOST = os.environ.get("SMB_HOST", "10.0.0.134")
USER = os.environ.get("SMB_USER", "")
PASS = os.environ.get("SMB_PASS", "")
DOMAIN = os.environ.get("SMB_DOMAIN", "")
OUT = os.environ.get(
    "SMB_ENUM_OUT",
    os.path.join(tempfile.gettempdir(), "dv-smb", "dv-smb-enum.txt"),
)
os.makedirs(os.path.dirname(OUT), exist_ok=True)

lines = []


def main():
    last = None
    for remote in ("*SMBSERVER", HOST):
        try:
            conn = SMBConnection(remote, HOST, sess_port=445)
            conn.login(USER, PASS, DOMAIN, "", "")
            lines.append(f"== 登录成功（remoteName={remote}）==")
            shares = conn.listShares()
            for sh in shares:
                # impacket 的 SHARE_INFO_1 是 NDR 结构，按字段名索引；老版本返回 dict。
                def field(key):
                    if isinstance(sh, dict):
                        raw = sh.get(key, b"")
                    else:
                        try:
                            raw = sh[key]
                        except Exception:  # noqa: BLE001
                            raw = getattr(sh, key, b"")
                    if isinstance(raw, bytes):
                        try:
                            raw = raw.decode("utf-16le")
                        except Exception:  # noqa: BLE001
                            raw = raw.decode("latin-1")
                    return str(raw).rstrip("\x00")

                name = field("shi1_netname")
                lines.append(f"SHARE|{name}|type={field('shi1_type')}|{field('shi1_remark')}")
            conn.logoff()
            return
        except Exception as exc:  # noqa: BLE001
            last = exc
            lines.append(f"== {remote} 失败：{exc!r} ==")
    raise last


try:
    main()
except Exception:  # noqa: BLE001
    lines.append("== 失败 ==")
    lines.append(traceback.format_exc())
finally:
    text = "\n".join(lines) + "\n"
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"枚举结果 {len(lines)} 行 -> {OUT}")
