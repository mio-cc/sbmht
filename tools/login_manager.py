#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""miohh 登录管理器（M1 混合方案）
- 二维码：登录窗口截图（已验证通道；原生 PNG 捕获为后续优化项）
- 登录态：OneBot 探活 + QQ 进程/窗口检测，写入 run/login.state
- WebUI：二维码自动刷新、状态、快速登录列表（来自 run/quicklogin.json）
只监听 127.0.0.1。
"""
import argparse
import glob
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = {"display": ":1", "root": "/opt/miohh", "onebot": "http://127.0.0.1:3000/get_status",
         "cache": {"png": b"", "ts": 0.0}}
LOCK = threading.Lock()


def load_onebot_token(root):
    """从 runtime 账号配置读取 OneBot accessToken（未登录时返回空）"""
    try:
        cands = sorted(glob.glob(os.path.join(root, "data", "runtime", "config", "onebot_*.json")))
        if not cands:
            return ""
        with open(cands[-1], encoding="utf-8") as f:
            data = json.load(f)
        for s in (data.get("networks") or {}).get("httpServers") or []:
            tok = s.get("accessToken") or s.get("token")
            if tok:
                return tok
    except Exception:
        pass
    return ""



def qq_running():
    try:
        out = subprocess.run(["pgrep", "-f", "/opt/QQ/qq"], capture_output=True, text=True, timeout=3)
        return bool(out.stdout.strip())
    except Exception:
        return False


def onebot_status():
    try:
        import urllib.request
        req = urllib.request.Request(STATE["onebot"])
        tok = load_onebot_token(STATE["root"])
        if tok:
            req.add_header("Authorization", "Bearer " + tok)
        with urllib.request.urlopen(req, timeout=2) as r:
            body = r.read().decode("utf-8", "replace").replace(" ", "")
        return {"available": True, "online": '"online":true' in body}
    except Exception:
        return {"available": False, "online": False}


def grab_png(force=False):
    now = time.time()
    with LOCK:
        if not force and STATE["cache"]["png"] and now - STATE["cache"]["ts"] < 1.0:
            return STATE["cache"]["png"]
    path = "/tmp/miohh_login_qr.png"
    try:
        subprocess.run(["import", "-display", STATE["display"], "-window", "root", path],
                       check=True, capture_output=True, timeout=10)
        with open(path, "rb") as f:
            data = f.read()
    except Exception:
        data = b""
    with LOCK:
        if data:
            STATE["cache"] = {"png": data, "ts": now}
    return data


def phase():
    if onebot_status()["online"]:
        return "logged_in"
    if not qq_running():
        return "waiting_qq"
    return "waiting_scan"


def quicklogin_list():
    p = os.path.join(STATE["root"], "run", "quicklogin.json")
    try:
        with open(p, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:
        return []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype="text/html; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/qr.png"):
            data = grab_png()
            if not data:
                return self._send(503, b"no display", "text/plain")
            return self._send(200, data, "image/png")
        if self.path.startswith("/status"):
            body = json.dumps({"phase": phase(), "qq_running": qq_running(),
                               "onebot": onebot_status(), "ts": int(time.time())},
                              ensure_ascii=False).encode()
            return self._send(200, body, "application/json")
        if self.path.startswith("/api/quicklogin"):
            body = json.dumps({"items": quicklogin_list()}, ensure_ascii=False).encode()
            return self._send(200, body, "application/json")
        html = """<!doctype html><meta charset='utf-8'><title>miohh 登录</title>
<body style='font-family:system-ui,sans-serif;text-align:center;background:#111;color:#eee;padding:24px'>
<h2>miohh 登录</h2>
<p>用手机 QQ 扫码（页面每 2 秒自动刷新二维码）</p>
<img id='q' style='width:380px;background:#fff;padding:12px;border-radius:8px' alt='二维码加载中'>
<p id='s'>检查中…</p>
<div id='qk' style='margin-top:12px'></div>
<script>
function refresh(){
  document.getElementById('q').src='/qr.png?t='+Date.now();
  fetch('/status').then(r=>r.json()).then(j=>{
    var m={logged_in:'已登录 ✅',waiting_scan:'等待扫码',waiting_qq:'等待 QQ 启动'};
    document.getElementById('s').textContent=m[j.phase]||j.phase;
    if(j.phase==='logged_in'){document.getElementById('q').style.display='none';}
  });
  fetch('/api/quicklogin').then(r=>r.json()).then(j=>{
    if(j.items&&j.items.length){document.getElementById('qk').textContent='快速登录: '+j.items.map(x=>x.nick||x.uin).join(' / ');}
  });
}
setInterval(refresh,2000);refresh();
</script></body>"""
        return self._send(200, html.encode())


def state_writer():
    root = STATE["root"]
    os.makedirs(os.path.join(root, "run"), exist_ok=True)
    p = os.path.join(root, "run", "login.state")
    while True:
        try:
            with open(p, "w", encoding="utf-8") as f:
                f.write(phase() + "\n")
        except Exception:
            pass
        time.sleep(2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=6080)
    ap.add_argument("--display", default=":1")
    ap.add_argument("--root", default=os.environ.get("MIOHH_ROOT", "/opt/miohh"))
    ap.add_argument("--onebot", default="http://127.0.0.1:3000/get_status")
    args = ap.parse_args()
    STATE.update({"display": args.display, "root": args.root, "onebot": args.onebot})
    threading.Thread(target=state_writer, daemon=True).start()
    srv = HTTPServer((args.host, args.port), Handler)
    print(f"[miohh] login Manager: http://{args.host}:{args.port}/  display={args.display} root={args.root}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
