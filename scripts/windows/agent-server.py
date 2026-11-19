#!/usr/bin/env python3
"""局域网服务：静态文件下载 + Windows 代理的任务通道。

同一个端口上：

  GET  /...                          静态文件（build/win-bundle/dist）
  GET  /agent/task?token=...         代理来取当前任务
  POST /agent/result?token=...       代理回传执行结果
  POST /agent/upload?token=...&name= 代理上传文件（截图、日志）
  POST /agent/hello?token=...        代理上线

任务和结果都在 build/agent/ 下，Mac 侧用 dvagent.py 写任务、读结果，
不需要走 HTTP（同一台机器）。

只用标准库，兼容 Python 3.9。
"""
import http.server
import json
import os
import socketserver
import time
import urllib.parse

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DIST = os.path.join(REPO, "build", "win-bundle", "dist")
STATE = os.path.join(REPO, "build", "agent")
RESULT_DIR = os.path.join(STATE, "results")
UPLOAD_DIR = os.path.join(STATE, "uploads")
TASK_PATH = os.path.join(STATE, "task.json")

TOKEN = "dvplayer-lan-7c1f19"


def ensure_dirs():
    for d in (STATE, RESULT_DIR, UPLOAD_DIR):
        os.makedirs(d, exist_ok=True)
    if not os.path.exists(TASK_PATH):
        write_json(TASK_PATH, {"id": 0, "ps": ""})


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIST, **kwargs)

    def log_message(self, fmt, *args):
        pass

    # --- helpers ---
    def _query(self):
        return urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)

    def _authed(self):
        return self._query().get("token", [""])[0] == TOKEN

    def _reply(self, code, body=b"", ctype="text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(length) if length else b""

    # --- GET ---
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/agent/task":
            if not self._authed():
                self._reply(403, b"forbidden")
                return
            task = read_json(TASK_PATH, {"id": 0, "ps": ""})
            self._reply(200, json.dumps(task).encode("utf-8"), "application/json")
            return
        if path == "/agent/ping":
            self._reply(200, b"dvagent ok")
            return
        super().do_GET()

    # --- POST ---
    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if not path.startswith("/agent/"):
            self._reply(404, b"not found")
            return
        if not self._authed():
            self._reply(403, b"forbidden")
            return

        data = self._body()

        if path == "/agent/result":
            try:
                result = json.loads(data.decode("utf-8"))
            except ValueError:
                self._reply(400, b"bad json")
                return
            task_id = int(result.get("id", 0))
            result["received"] = time.strftime("%Y-%m-%d %H:%M:%S")
            write_json(os.path.join(RESULT_DIR, "%d.json" % task_id), result)
            summary = (result.get("out") or "").strip().splitlines()
            head = summary[0][:100] if summary else "(empty)"
            print("[result #%d] %s | %s" % (task_id, result.get("host", "?"), head), flush=True)
            self._reply(200, b"ok")
            return

        if path == "/agent/upload":
            name = self._query().get("name", ["upload.bin"])[0]
            name = os.path.basename(name) or "upload.bin"
            with open(os.path.join(UPLOAD_DIR, name), "wb") as f:
                f.write(data)
            print("[upload] %s (%d bytes)" % (name, len(data)), flush=True)
            self._reply(200, b"ok")
            return

        if path == "/agent/hello":
            text = data.decode("utf-8", "replace")
            with open(os.path.join(STATE, "hello.log"), "a", encoding="utf-8") as f:
                f.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), text))
            print("[hello] %s" % text, flush=True)
            self._reply(200, b"ok")
            return

        self._reply(404, b"not found")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "dvagent"
        self.server_port = self.server_address[1]


def main():
    ensure_dirs()
    port = int(os.environ.get("PORT", "8080"))
    with Server(("0.0.0.0", port), Handler) as httpd:
        print("serving %s" % DIST, flush=True)
        print("agent endpoints under /agent/*", flush=True)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("bye", flush=True)


if __name__ == "__main__":
    main()
