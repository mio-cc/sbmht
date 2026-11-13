#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""M0/M1 动态探针执行器：attach 或 spawn 模式注入 frida_login_probe.js。"""
import argparse
import json
import os
import sys
import time

import frida  # type: ignore


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pid", type=int, default=0)
    ap.add_argument("--spawn", action="store_true")
    ap.add_argument("--env", action="append", default=[])
    ap.add_argument("--cwd", default=None)
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--server", default="127.0.0.1:27042")
    ap.add_argument("--script", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "frida_login_probe.js"))
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    js = open(args.script, "r", encoding="utf-8").read()
    device = frida.get_device_manager().add_remote_device(args.server)
    events = []

    captures = []

    def on_message(msg, data):
        if msg.get("type") == "send":
            p = msg.get("payload") or {}
            events.append(p)
            if data:
                import hashlib
                path = "/tmp/miohh_capture_%d.bin" % len(captures)
                with open(path, "wb") as fh:
                    fh.write(data)
                captures.append(path)
                print("[probe] CAPTURE %s bytes=%d sha256=%s" % (path, len(data), hashlib.sha256(data).hexdigest()[:16]), flush=True)
            print("[probe]", json.dumps(p, ensure_ascii=False)[:1500], flush=True)
        elif msg.get("type") == "error":
            print("[probe][error]", msg.get("description"), flush=True)

    if args.spawn:
        env = dict(os.environ)
        for kv in args.env:
            if "=" in kv:
                k, v = kv.split("=", 1)
                env[k] = v
        argv = list(args.cmd)
        if argv and argv[0] == "--":
            argv = argv[1:]
        if not argv:
            print("ERR: spawn 需要命令行", file=sys.stderr)
            sys.exit(2)
        print("[probe] spawn: %s cwd=%s env_overrides=%s" % (argv, args.cwd, args.env), flush=True)
        kw = {"env": env}
        if args.cwd:
            kw["cwd"] = args.cwd
        pid = device.spawn(argv, **kw)
        print("[probe] spawned pid=%d" % pid, flush=True)
        session = device.attach(pid)
        script = session.create_script(js)
        script.on("message", on_message)
        script.load()
        device.resume(pid)
        print("[probe] resumed, collecting %ds ..." % args.seconds, flush=True)
    else:
        if not args.pid:
            print("ERR: attach 模式需要 --pid", file=sys.stderr)
            sys.exit(2)
        session = device.attach(args.pid)
        script = session.create_script(js)
        script.on("message", on_message)
        script.load()
        print("[probe] attached pid=%d, collecting %ds ..." % (args.pid, args.seconds), flush=True)

    time.sleep(args.seconds)
    try:
        session.detach()
    except Exception:
        pass
    hits = [e for e in events if e.get("type") in
            ("qr-string", "qr-buffer", "qr-prop", "scan-hit", "napi-str", "napi-str16", "napi-buffer")]
    out = {"spawn": args.spawn, "seconds": args.seconds, "events": len(events),
           "data_hits": hits[:50],
           "rva_hits": [e for e in events if e.get("type") == "rva-hit"][:20]}
    print("[probe] summary:", json.dumps(out, ensure_ascii=False)[:3000], flush=True)
    with open("/tmp/miohh_login_probe.json", "w", encoding="utf-8") as f:
        json.dump({"events": events, "summary": out}, f, ensure_ascii=False, indent=1)
    print("[probe] saved /tmp/miohh_login_probe.json", flush=True)


if __name__ == "__main__":
    main()
