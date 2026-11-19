#!/usr/bin/env python3
"""Mac 侧命令行：给 Windows 代理下发 PowerShell 任务，等结果。

用法：

    python3 scripts/windows/dvagent.py run "Get-ComputerInfo | Select WindowsProductName"
    python3 scripts/windows/dvagent.py run -f some.ps1 --timeout 300
    python3 scripts/windows/dvagent.py log
    python3 scripts/windows/dvagent.py get shot.png

任务写成 build/agent/task.json，代理每秒来取；结果落在 build/agent/results/<id>.json。
只在本机文件系统上操作，不走网络。
"""
import argparse
import base64
import json
import os
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STATE = os.path.join(REPO, "build", "agent")
TASK = os.path.join(STATE, "task.json")
RESULTS = os.path.join(STATE, "results")
UPLOADS = os.path.join(STATE, "uploads")


def ensure():
    os.makedirs(RESULTS, exist_ok=True)
    os.makedirs(UPLOADS, exist_ok=True)
    if not os.path.exists(TASK):
        write_json(TASK, {"id": 0, "ps": ""})


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


def submit(code):
    task = read_json(TASK, {"id": 0, "ps": ""}) or {"id": 0, "ps": ""}
    task_id = int(task.get("id", 0)) + 1
    ps = base64.b64encode(code.encode("utf-8")).decode("ascii")
    write_json(TASK, {"id": task_id, "ps": ps})
    return task_id


def wait(task_id, timeout):
    path = os.path.join(RESULTS, "%d.json" % task_id)
    deadline = time.time() + timeout if timeout else None
    while True:
        result = read_json(path)
        if result is not None:
            return result
        if deadline and time.time() > deadline:
            return None
        time.sleep(0.5)


def print_result(result):
    if result is None:
        print("(超时，没有结果。检查 Windows 上的 agent 窗口还在不在)", file=sys.stderr)
        return 1
    out = (result.get("out") or "").rstrip()
    print("--- exit=%s ms=%s host=%s ---" % (
        result.get("exit"), result.get("ms"), result.get("host")))
    print(out if out else "(empty)")
    return 0


def main():
    ap = argparse.ArgumentParser(description="dvplayer Windows agent client")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_run = sub.add_parser("run", help="下发并等待一个 PowerShell 片段")
    p_run.add_argument("code", nargs="?", help="PowerShell 代码")
    p_run.add_argument("-f", "--file", help="从文件读 PowerShell")
    p_run.add_argument("--timeout", type=int, default=180)
    p_run.add_argument("--no-wait", action="store_true")

    p_wait = sub.add_parser("wait", help="等某个任务号")
    p_wait.add_argument("id", type=int)
    p_wait.add_argument("--timeout", type=int, default=180)

    sub.add_parser("log", help="看最近的结果")
    p_get = sub.add_parser("get", help="打印代理上传的文件路径")
    p_get.add_argument("name")

    args = ap.parse_args()
    ensure()

    if args.cmd == "run":
        code = args.code
        if args.file:
            with open(args.file, encoding="utf-8") as f:
                code = f.read()
        if not code:
            print("没给代码", file=sys.stderr)
            return 2
        task_id = submit(code)
        print("task #%d 已下发" % task_id, file=sys.stderr)
        if args.no_wait:
            return 0
        return print_result(wait(task_id, args.timeout))

    if args.cmd == "wait":
        return print_result(wait(args.id, args.timeout))

    if args.cmd == "log":
        files = sorted(
            (int(f[:-5]), f) for f in os.listdir(RESULTS) if f.endswith(".json") and f[:-5].isdigit()
        )
        for task_id, name in files[-5:]:
            result = read_json(os.path.join(RESULTS, name)) or {}
            out = (result.get("out") or "").strip().splitlines()
            head = out[0][:110] if out else "(empty)"
            print("#%d %s | %s" % (task_id, result.get("received", "?"), head))
        return 0

    if args.cmd == "get":
        path = os.path.join(UPLOADS, os.path.basename(args.name))
        if not os.path.exists(path):
            print("没有这个上传文件：%s" % path, file=sys.stderr)
            return 1
        print(path)
        return 0

    return 2


if __name__ == "__main__":
    sys.exit(main())
