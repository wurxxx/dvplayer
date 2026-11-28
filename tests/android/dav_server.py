#!/usr/bin/env python3
"""测试用最小 WebDAV 服务（A9 验证）。

只实现 PROPFIND(Depth:1) 与带 Range 的 GET，够验证浏览 + 起播 + seek。
基本认证固定 user/pass，可用 --no-auth 关掉。

用法：
    python3 tests/android/dav_server.py --root /tmp/davroot --port 8099
"""
import argparse
import base64
import email.utils
import os
import posixpath
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote, urlsplit

ROOT = "/tmp/davroot"
PREFIX = "/dav"
AUTH = "Basic " + base64.b64encode(b"user:pass").decode()


def href_for(rel: str, is_dir: bool) -> str:
    path = PREFIX + "/" + quote(rel)
    if is_dir and not path.endswith("/"):
        path += "/"
    return path


def entry_xml(rel: str, full: str) -> str:
    is_dir = os.path.isdir(full)
    stat = os.stat(full)
    modified = email.utils.formatdate(stat.st_mtime, usegmt=True)
    rtype = "<d:resourcetype><d:collection/></d:resourcetype>" if is_dir else "<d:resourcetype/>"
    length = "" if is_dir else f"<d:getcontentlength>{stat.st_size}</d:getcontentlength>"
    return (
        "<d:response>"
        f"<d:href>{href_for(rel, is_dir)}</d:href>"
        "<d:propstat><d:prop>"
        f"{rtype}{length}<d:getlastmodified>{modified}</d:getlastmodified>"
        "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>"
        "</d:response>"
    )


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _authorized(self) -> bool:
        if AUTH is None:
            return True
        got = self.headers.get("Authorization", "")
        if got == AUTH:
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="dav"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def _resolve(self):
        path = unquote(urlsplit(self.path).path)
        if not path.startswith(PREFIX):
            return None, None
        rel = path[len(PREFIX):].strip("/")
        full = os.path.normpath(os.path.join(ROOT, rel))
        if not full.startswith(ROOT):
            return None, None
        return rel, full

    def _drain_body(self):
        # PROPFIND 允许带请求体；不读完会在 keep-alive 连接里被当成下一个请求行。
        length = int(self.headers.get("Content-Length") or 0)
        if length > 0:
            self.rfile.read(length)

    def do_PROPFIND(self):
        if not self._authorized():
            return
        self._drain_body()
        rel, full = self._resolve()
        if not full or not os.path.exists(full):
            self.send_error(404)
            return
        items = [entry_xml(rel, full)]
        depth = self.headers.get("Depth", "1")
        if depth != "0" and os.path.isdir(full):
            for name in sorted(os.listdir(full)):
                child_rel = posixpath.join(rel, name) if rel else name
                items.append(entry_xml(child_rel, os.path.join(full, name)))
        body = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<d:multistatus xmlns:d="DAV:">' + "".join(items) + "</d:multistatus>"
        ).encode()
        self.send_response(207)
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        self._send_file(head=True)

    def do_GET(self):
        self._send_file(head=False)

    def _send_file(self, head: bool):
        if not self._authorized():
            return
        _, full = self._resolve()
        if not full or not os.path.isfile(full):
            self.send_error(404)
            return
        size = os.path.getsize(full)
        start, end = 0, size - 1
        status = 200
        rng = self.headers.get("Range")
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)", rng)
            if m:
                if m.group(1):
                    start = int(m.group(1))
                if m.group(2):
                    end = int(m.group(2))
                if m.group(1) == "" and m.group(2):
                    start = max(0, size - int(m.group(2)))
                    end = size - 1
                status = 206
        end = min(end, size - 1)
        length = max(0, end - start + 1)
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head:
            return
        with open(full, "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(64 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)


def main():
    global ROOT, AUTH
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=ROOT)
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--no-auth", action="store_true")
    args = parser.parse_args()
    ROOT = os.path.abspath(args.root)
    if args.no_auth:
        AUTH = None
    os.makedirs(ROOT, exist_ok=True)
    print(f"WebDAV {ROOT} on http://127.0.0.1:{args.port}{PREFIX}/", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
