#!/usr/bin/env python3
"""用 mpv 抓单帧：seek 到指定时间、暂停、截图、退出。

mpv 没有“在时间 T 截图”的命令行开关，所以这里用 --input-ipc-server
驱动：等 video-params 可用后发 screenshot，再 quit。
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time


def send(sock: socket.socket, payload: dict) -> None:
    sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))


_buffers: dict[int, bytes] = {}


def read_message(sock: socket.socket, timeout: float) -> dict:
    sock.settimeout(timeout)
    key = sock.fileno()
    buf = _buffers.get(key, b"")
    while b"\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("mpv closed the IPC socket")
        buf += chunk
    line, rest = buf.split(b"\n", 1)
    _buffers[key] = rest
    if not line.strip():
        return read_message(sock, timeout)
    return json.loads(line.decode("utf-8"))


def call(sock: socket.socket, command: list, request_id: int, timeout: float = 10.0) -> dict:
    send(sock, {"command": command, "request_id": request_id})
    deadline = time.time() + timeout
    while time.time() < deadline:
        msg = read_message(sock, max(0.5, deadline - time.time()))
        if msg.get("request_id") == request_id:
            if msg.get("error") != "success":
                raise RuntimeError(f"command failed: {command}: {msg}")
            return msg
    raise TimeoutError(f"no reply for {command}")


def connect(path: str, timeout: float = 15.0) -> socket.socket:
    deadline = time.time() + timeout
    last: Exception | None = None
    while time.time() < deadline:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(path)
            return sock
        except OSError as exc:  # not up yet
            last = exc
            time.sleep(0.05)
    raise TimeoutError(f"mpv IPC not ready: {path} ({last})")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("timestamp")
    ap.add_argument("prefix")
    ap.add_argument("--outdir", default="out/ab")
    ap.add_argument("--no-el", action="store_true", help="禁用增强层（A/B 对照）")
    ap.add_argument("--gpu-api", default="opengl")
    ap.add_argument("--mpv", default=os.environ.get("MPV"),
                    help="mpv 二进制；默认用 PATH 里的 mpv 或 prefix/bin/mpv")
    ap.add_argument("--vo", default="", choices=["", "gpu", "gpu-next"],
                    help="gpu-next 需要 Vulkan（配合 --gpu-context=macvk）")
    ap.add_argument("--gpu-context", default="",
                    help="如 macvk（macOS 上 gpu-next 用）")
    ap.add_argument("--screenshot-format", default="jpg",
                    choices=["jpg", "png", "webp"],
                    help="png 需要 FFmpeg 的 zlib 支持；本仓库构建默认没有")
    ap.add_argument("--extra", action="append", default=[], metavar="ARG")
    args = ap.parse_args()

    src = os.path.abspath(args.input)
    if not os.path.isfile(src):
        print(f"no such file: {src}", file=sys.stderr)
        return 2

    outdir = os.path.abspath(args.outdir)
    os.makedirs(outdir, exist_ok=True)
    runtime = tempfile.mkdtemp(prefix="dvplayer-")
    sock_path = os.path.join(runtime, "mpv.sock")
    log_path = os.path.join(outdir, f"{args.prefix}.log")

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    mpv = args.mpv or shutil.which("mpv") or os.path.join(repo, "prefix", "bin", "mpv")
    if not os.path.isfile(mpv):
        print("mpv not found; run scripts/build-deps-macos.sh first", file=sys.stderr)
        return 2

    cmd = [
        mpv, "--no-config",
        "--hr-seek=yes", f"--start={args.timestamp}", "--pause",
        "--osd-level=0",
        "--input-default-bindings=no", "--input-vo-keyboard=no",
        f"--input-ipc-server={sock_path}",
        f"--screenshot-directory={outdir}",
        f"--screenshot-template={args.prefix}",
        f"--screenshot-format={args.screenshot_format}",
        "--screenshot-jpeg-quality=100",
        "--msg-level=all=info",
    ]
    if args.vo == "gpu-next":
        cmd.append("--vo=gpu-next")
        if args.gpu_context:
            cmd.append(f"--gpu-context={args.gpu_context}")
    elif args.vo == "gpu":
        cmd += ["--hwdec=no", f"--gpu-api={args.gpu_api}"]
    else:
        # 没指定时按 gpu-api 猜：vulkan 只能是 gpu-next
        if args.gpu_api == "vulkan":
            cmd.append("--vo=gpu-next")
            if args.gpu_context:
                cmd.append(f"--gpu-context={args.gpu_context}")
        else:
            cmd += ["--hwdec=no", f"--gpu-api={args.gpu_api}"]
    if args.no_el:
        cmd.append("--vf=format=enhancement-layer=no")
    cmd.extend(args.extra)
    cmd.append(src)

    print(f"[grab] mpv -> {log_path}", flush=True)
    with open(log_path, "w", encoding="utf-8") as logf:
        proc = subprocess.Popen(cmd, stdout=logf, stderr=logf)
        try:
            sock = connect(sock_path)
            call(sock, ["set_property", "pause", True], 1)

            rid = 2
            deadline = time.time() + 60
            while time.time() < deadline:
                try:
                    res = call(sock, ["get_property", "video-params"], rid)
                except RuntimeError:
                    # 文件还没加载完时是 "property unavailable"
                    time.sleep(0.2)
                    continue
                finally:
                    rid += 1
                data = res.get("data")
                if isinstance(data, dict) and data.get("w"):
                    break
                time.sleep(0.1)
            else:
                raise TimeoutError("no video frame within 60s")

            # gpu-next/Vulkan 的首帧要等 shader 编译完，截太早会拿不到帧。
            # 截图命令偶尔会在无帧时返回 error，所以以「文件是否出现」为准。
            for old in glob.glob(os.path.join(outdir, f"{args.prefix}*.{args.screenshot_format}")):
                try:
                    os.unlink(old)
                except OSError:
                    pass
            time.sleep(1.5)
            wrote = False
            for _ in range(8):
                try:
                    call(sock, ["screenshot", "video"], rid)
                except Exception:
                    pass
                finally:
                    rid += 1
                time.sleep(0.6)
                if glob.glob(os.path.join(outdir, f"{args.prefix}*.{args.screenshot_format}")):
                    wrote = True
                    break
            if not wrote:
                raise RuntimeError("screenshot did not produce a file after 8 tries")
            time.sleep(0.2)
            call(sock, ["quit"], rid)
        finally:
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()

    shot = os.path.join(outdir, f"{args.prefix}.{args.screenshot_format}")
    png = shot
    if not os.path.isfile(png):
        matches = sorted(
            glob.glob(os.path.join(outdir, f"{args.prefix}*.{args.screenshot_format}")),
            key=os.path.getmtime,
        )
        png = matches[-1] if matches else ""

    if not png or not os.path.isfile(png):
        print("screenshot not produced, see log", file=sys.stderr)
        return 1

    print(png)
    return 0


if __name__ == "__main__":
    sys.exit(main())
