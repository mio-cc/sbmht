#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""miohh 登录二维码本地 WebUI（最小实现）：
   GET /           -> HTML（每 2s 刷新二维码图片 + 状态）
   GET /qr.png     -> 当前登录窗口截图（PNG）
   GET /status     -> JSON（登录态/OneBot 探活）
只监听 127.0.0.1；用于 headless 环境扫码登录。
"""
import argparse
import json
import subprocess
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

DISPLAY = ":1"
QR_PATH = "/tmp/miohh_login_qr.png"
ONE_BOT_URL = "http://127.0.0.1:3000/get_status"


def grab_screenshot():
    try:
        subprocess.run(["import", "-display", DISPLAY, "-window", "root", QR_PATH],
                       check=True, capture_output=True, timeout=10)
        with open(QR_PATH, "rb") as f:
            return f.read()
    except Exception:
        return b""


def check_login():
    try:
        with urllib.request.urlopen(ONE_BOT_URL, timeout=2) as r:
            body = r.read().decode("utf-8", "replace")
        return {"onebot": True, "online": '"online":true' in body.replace(" ", "")}
    except Exception:
        return {"onebot": False, "online": False}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path.startswith("/qr.png"):
            data = grab_screenshot()
            if not data:
                self.send_response(503)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif self.path.startswith("/status"):
            body = json.dumps(check_login()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            html = ("<!doctype html><meta charset='utf-8'><title>miohh 登录</title>"
                    "<body style='font-family:sans-serif;text-align:center;background:#111;color:#eee'>"
                    "<h2>miohh 登录</h2><p>用手机 QQ 扫码（页面每 2 秒自动刷新）</p>"
                    "<img id='q' style='width:360px;background:#fff;padding:12px;border-radius:8px'>"
                    "<p id='s'>检查中…</p><script>"
                    "function r(){document.getElementById('q').src='/qr.png?t='+Date.now();"
                    "fetch('/status').then(r=>r.json()).then(j=>{document.getElementById('s').textContent="
                    "j.online?'已登录 ✅':(j.onebot?'等待扫码':'等待 QQ 启动');});}"
                    "setInterval(r,2000);r();</script></body>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html)


def main():
    global DISPLAY
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=6080)
    ap.add_argument("--display", default=":1")
    args = ap.parse_args()
    DISPLAY = args.display
    srv = HTTPServer((args.host, args.port), Handler)
    print(f"[miohh] QR WebUI: http://{args.host}:{args.port}/  (display={DISPLAY})", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
