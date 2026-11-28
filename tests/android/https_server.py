#!/usr/bin/env python3
"""本地 HTTPS 文件服务，带 Range，用来验证 mpv 的 TLS / https 播放。

用法：
    # 生成一天有效的自签证书
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj /CN=127.0.0.1 -keyout /tmp/https-key.pem -out /tmp/https-cert.pem

    python3 tests/android/https_server.py \
        --root /tmp/https-root --port 8443 \
        --cert /tmp/https-cert.pem --key /tmp/https-key.pem

    adb reverse tcp:8443 tcp:8443
    # 设备上播 https://127.0.0.1:8443/<文件>

mpv 的 Android 构建默认 `tls-verify=no`，所以自签证书可以直接播。
要验证「校验真的在跑」，加 `--es tls_verify 1`：自签会被 mbedTLS 拒掉
（CA 用 APK 内置的 Mozilla 包），公网证书则正常。三组回归见
tests/android/verify-tls.sh。
"""
import argparse
import os
import re
import socketserver
import ssl
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

RANGE_RE = re.compile(r"bytes=(\d*)-(\d*)")


def parse_range(header: str, size: int):
    m = RANGE_RE.fullmatch(header.strip())
    if not m:
        return None
    first, last = m.group(1), m.group(2)
    if first == "" and last == "":
        return None
    if first == "":
        n = int(last)
        if n <= 0:
            return None
        return max(0, size - n), size - 1
    start = int(first)
    end = int(last) if last else size - 1
    if start >= size or start > end:
        return None
    return start, min(end, size - 1)


class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        path = self.translate_path(self.path)
        rng = self.headers.get("Range")
        if not rng or not os.path.isfile(path):
            return super().do_GET()

        size = os.path.getsize(path)
        parsed = parse_range(rng, size)
        if parsed is None:
            self.send_error(416, "Range Not Satisfiable")
            return
        start, end = parsed
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                chunk = f.read(min(256 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):
        # HTTPServer.server_bind 会调 socket.getfqdn(host)；没有 DNS 的环境里
        # 这一步能卡几十秒，端口一直不进入 LISTEN。这里直接跳过。
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--port", type=int, default=8443)
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--bind", default="127.0.0.1")
    args = ap.parse_args()

    handler = lambda *a, **kw: Handler(*a, directory=args.root, **kw)
    httpd = Server((args.bind, args.port), handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(args.cert, args.key)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"https://{args.bind}:{args.port}/ -> {args.root}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
