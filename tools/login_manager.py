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
import hashlib
import io
import json
import os
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"display": ":1", "root": "/opt/miohh", "onebot": "http://127.0.0.1:3000/get_status",
         "cache": {"png": b"", "ts": 0.0}, "err": "", "last_change": 0.0, "last_restart": 0.0}
LOCK = threading.Lock()
QR_STALE_SECONDS = int(os.environ.get("MIOHH_QR_STALE_SECONDS", "180"))
AUTO_RESTART = os.environ.get("MIOHH_QR_AUTO_RESTART", "1") not in ("0", "false", "off")
RESTART_COOLDOWN = 90
AUTO_LOGIN = os.environ.get("MIOHH_AUTO_LOGIN", "1") not in ("0", "false", "off")
_WIN_CACHE = {"id": None, "w": 0, "h": 0, "at": 0.0}


def _x(cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              env=dict(os.environ, DISPLAY=STATE["display"]))
    except Exception:
        return None


def _window_mapped(wid):
    r = _x(["xwininfo", "-id", str(wid)])
    return bool(r and "IsViewable" in (r.stdout or ""))


def _window_geometry(wid):
    r = _x(["xdotool", "getwindowgeometry", "--shell", str(wid)])
    w = h = 0
    for line in (getattr(r, "stdout", "") or "").splitlines():
        if line.startswith("WIDTH="):
            w = int(line.split("=", 1)[1])
        elif line.startswith("HEIGHT="):
            h = int(line.split("=", 1)[1])
    return w, h


def find_qq_window():
    """定位 QQ 登录窗口。

    QQ 登录窗口本身没有 WM_NAME（父 frame 也没有），但内容窗口的 WM_CLASS
    是 ("qq" "QQ")，浏览器/文件管理器不会命中；用 xdotool 按 class 找内容
    窗口，再按尺寸挑主窗口，避免误抓 Chromium/桌面窗口。
    """
    now = time.time()
    if _WIN_CACHE["id"] and now - _WIN_CACHE["at"] < 5 and _window_mapped(_WIN_CACHE["id"]):
        return _WIN_CACHE
    ids = []
    for cls in ("QQ", "qq"):
        r = _x(["xdotool", "search", "--class", cls])
        for token in (getattr(r, "stdout", "") or "").split():
            try:
                ids.append(int(token))
            except ValueError:
                continue
    best = None
    for wid in sorted(set(ids)):
        if not _window_mapped(wid):
            continue
        w, h = _window_geometry(wid)
        if not (420 <= w <= 1200 and 300 <= h <= 1000):
            continue
        ratio = w / float(h or 1)
        if not (1.15 <= ratio <= 2.1):
            continue
        area = w * h
        if best is None or area > best[0]:
            best = (area, wid, w, h)
    if not best:
        # 兜底：仍从 xwininfo 里找无标题大窗口（旧环境/窗口类名缺失时）
        r = _x(["xwininfo", "-root", "-tree"])
        for line in (getattr(r, "stdout", "") or "").splitlines():
            m = re.search(
                r'^\s*(0x[0-9a-fA-F]+)\s+\(has no name\)\s*:.*?(\d+)x(\d+)\+(-?\d+)\+(-?\d+)',
                line,
            )
            if not m:
                continue
            wid = int(m.group(1), 16)
            w, h = int(m.group(2)), int(m.group(3))
            if not (420 <= w <= 1200 and 300 <= h <= 1000):
                continue
            ratio = w / float(h or 1)
            if not (1.15 <= ratio <= 2.1):
                continue
            if not _window_mapped(wid):
                continue
            area = w * h
            if best is None or area > best[0]:
                best = (area, wid, w, h)
    if not best:
        return None
    _WIN_CACHE.update({"id": best[1], "w": best[2], "h": best[3], "at": now})
    return _WIN_CACHE


def _click(wid, x, y):
    if wid is None:
        return False
    r = _x(["xdotool", "mousemove", "--window", str(wid), str(x), str(y), "click", "1"], timeout=8)
    return bool(r and r.returncode == 0)


def grab_png(force=False):
    now = time.time()
    with LOCK:
        if not force and STATE["cache"]["png"] and now - STATE["cache"]["ts"] < 1.0:
            return STATE["cache"]["png"]
    path = "/tmp/miohh_login_qr.png"
    data = b""
    win = find_qq_window()
    if win:
        r = _x(["import", "-display", STATE["display"], "-window", str(win["id"]), path], timeout=12)
        if r is not None and r.returncode == 0 and os.path.isfile(path):
            # 窗口通常 ~680x440，放大 2 倍让二维码在页面上足够大（点采样不糊）。
            if win["w"] < 900:
                _x(["convert", path, "-filter", "point", "-resize", "200%", path], timeout=12)
            try:
                with open(path, "rb") as f:
                    data = f.read()
            except OSError:
                data = b""
            STATE["err"] = ""
    if not data:
        # 兜底：整屏截图 + 居中裁剪（避免黑边把二维码挤小）
        raw = "/tmp/miohh_login_screen.png"
        r = _x(["import", "-display", STATE["display"], "-window", "root", raw], timeout=12)
        if r is not None and r.returncode == 0 and os.path.isfile(raw):
            _x(["convert", raw, "-gravity", "center", "-crop", "760x760+0+0", "+repage", path], timeout=12)
            try:
                with open(path, "rb") as f:
                    data = f.read()
                STATE["err"] = ""
            except OSError:
                data = b""
        if not data:
            STATE["err"] = ("no display: %s" % (getattr(r, "stderr", "") or STATE.get("err", "")))[:200]
    with LOCK:
        if data:
            h = hashlib.sha1(data).hexdigest()
            if h != STATE.get("qr_hash"):
                STATE["qr_hash"] = h
                STATE["last_change"] = now
            STATE["cache"] = {"png": data, "ts": now}
    return data

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


def restart_qq(reason=""):
    """重启 qts（会连带重启 QQ 并重新出码），带冷却避免循环。"""
    now = time.time()
    if now - float(STATE.get("last_restart") or 0) < RESTART_COOLDOWN:
        return False
    STATE["last_restart"] = now
    try:
        subprocess.Popen(["systemctl", "restart", "qts.service"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:
        return False


def watchdog():
    """二维码长时间不变化 / 截不到图时自动重启 QQ，避免卡在失败提示页。"""
    no_png_since = 0.0
    while True:
        time.sleep(5)
        if not AUTO_RESTART:
            continue
        try:
            if phase() == "logged_in":
                no_png_since = 0.0
                continue
            data = grab_png(force=True)
            now = time.time()
            if data:
                no_png_since = 0.0
                last_change = float(STATE.get("last_change") or now)
                if now - last_change > QR_STALE_SECONDS and phase() == "waiting_scan":
                    restart_qq("qr stale")
            else:
                if not no_png_since:
                    no_png_since = now
                elif now - no_png_since > 90 and phase() == "waiting_scan":
                    restart_qq("no screenshot")
                    no_png_since = now
        except Exception:
            pass


def _analyze_png(data):
    """识别登录窗口里的"蓝色登录按钮"和"有效二维码"（Pillow 可选）。"""
    try:
        from PIL import Image
    except Exception:
        return None
    try:
        im = Image.open(io.BytesIO(data)).convert("RGB")
        w, h = im.size
        px = im.load()
        # 右侧区域是否有有效二维码（黑模块密度）
        dark = total = 0
        for y in range(int(h * 0.15), int(h * 0.85), 3):
            for x in range(int(w * 0.52), int(w * 0.98), 3):
                r, g, b = px[x, y]
                total += 1
                if r < 95 and g < 95 and b < 95:
                    dark += 1
        qr = total > 0 and (dark / float(total)) > 0.10
        # 下方是否有"蓝色实心登录按钮"（QQ 蓝约 #12B7F5；禁用态偏淡会被排除）
        minx, miny, maxx, maxy, cnt = w, h, -1, -1, 0
        for y in range(int(h * 0.50), h, 2):
            for x in range(0, w, 2):
                r, g, b = px[x, y]
                if b > 200 and 120 < g < 235 and r < 95:
                    cnt += 1
                    if x < minx: minx = x
                    if y < miny: miny = y
                    if x > maxx: maxx = x
                    if y > maxy: maxy = y
        blue = cnt > 200 and maxx > minx
        return {
            "qr": qr,
            "blue": blue,
            "blue_xy": (((minx + maxx) / 2.0) / w, ((miny + maxy) / 2.0) / h) if blue else None,
        }
    except Exception:
        return None


def auto_assist():
    """自动登录/自动刷新二维码（截图模式下的 NapCat 快速登录等价物）。

    QQ 登录窗口有两种常见形态：
      1) 已保存账号 + 登录按钮（快速登录页）：点击窗口中心偏下触发登录；
      2) 账号密码页 + 右侧二维码（可能"二维码已过期"）：点击右侧刷新按钮。
    该线程先尝试 1)，若画面长时间无变化再尝试 2)。
    """
    last_win = None
    quick_done = False
    auto_toggle_done = False
    last_click = 0.0
    last_hash = None
    last_change = time.time()
    while True:
        time.sleep(4)
        try:
            if not AUTO_LOGIN:
                continue
            if phase() == "logged_in":
                last_win = None
                quick_done = False
                auto_toggle_done = False
                last_hash = None
                last_change = time.time()
                continue
            win = find_qq_window()
            if not win:
                continue
            wid, w, h = win["id"], win["w"], win["h"]
            now = time.time()
            if wid != last_win:
                last_win = wid
                quick_done = False
                auto_toggle_done = False
                last_click = 0.0
                last_hash = None
                last_change = now
            data = grab_png(force=True)
            info = _analyze_png(data) if data else None
            if data:
                hsh = hashlib.sha1(data).hexdigest()
                if hsh != last_hash:
                    last_hash = hsh
                    last_change = now
            if info is not None:
                # 有蓝色实心"登录"按钮且右侧无有效二维码 → 快速登录页
                if info.get("blue") and not info.get("qr") and now - last_click > 20:
                    if not auto_toggle_done:
                        # 先勾选"自动登录"（该页布局里复选框在按钮正上方居中）
                        _click(wid, int(w * 0.5), int(h * 0.72))
                        auto_toggle_done = True
                    bx, by = info["blue_xy"]
                    _click(wid, int(bx * w), int(by * h))
                    quick_done = True
                    last_click = now
                    last_change = now
                    continue
                # 没有有效二维码（过期/未生成）→ 点窗口右侧的"刷新"区域
                if not info.get("qr") and now - last_click > 15:
                    _click(wid, int(w * 0.72), int(h * 0.45))
                    last_click = now
                    last_change = now
                    continue
            else:
                # Pillow 不可用时的固定坐标兜底
                if not quick_done and now - last_change > 6:
                    _click(wid, w // 2, int(h * 0.78))
                    quick_done = True
                    last_click = now
                    last_change = now
                    continue
                if now - last_change > 25 and now - last_click > 15:
                    _click(wid, int(w * 0.72), int(h * 0.44))
                    last_click = now
                    last_change = now
        except Exception:
            pass


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
        path = self.path
        if path.startswith("/qr.png"):
            data = grab_png()
            if not data:
                detail = ("no display: %s" % STATE.get("err", ""))[:300]
                return self._send(503, detail.encode(), "text/plain")
            return self._send(200, data, "image/png")
        if path.startswith("/status"):
            now = time.time()
            last_change = float(STATE.get("last_change") or 0)
            body = json.dumps({
                "phase": phase(), "qq_running": qq_running(),
                "onebot": onebot_status(), "ts": int(now),
                "qr_age": int(now - last_change) if last_change else None,
                "stale_seconds": QR_STALE_SECONDS,
                "auto_restart": AUTO_RESTART,
                "auto_login": AUTO_LOGIN,
            }, ensure_ascii=False).encode()
            return self._send(200, body, "application/json")
        if path.startswith("/restart") or path.startswith("/api/restart"):
            ok = restart_qq("manual")
            return self._send(200, json.dumps({"ok": ok, "restarted": ok}).encode(), "application/json")
        if path.startswith("/api/quicklogin"):
            body = json.dumps({"items": quicklogin_list()}, ensure_ascii=False).encode()
            return self._send(200, body, "application/json")
        html = """<!doctype html><meta charset='utf-8'><title>miohh 登录</title>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<body style='font-family:system-ui,sans-serif;text-align:center;background:#111;color:#eee;padding:24px'>
<h2>miohh 登录</h2>
<p>用手机 QQ 扫码；已保存账号会自动尝试快速登录，二维码过期会自动刷新</p>
<img id='q' style='width:min(860px,94vw);background:#fff;padding:12px;border-radius:8px' alt='二维码加载中'>"
<p id='s'>检查中…</p>
<p><button onclick='doRestart()' style='padding:8px 16px;border-radius:8px;border:1px solid #555;background:#222;color:#eee;cursor:pointer'>重启 QQ / 重新出码</button></p>
<p id='m' style='color:#aaa;font-size:13px'></p>
<div id='qk' style='margin-top:12px;color:#aaa'></div>
<script>
var restarting=false;
function doRestart(){
  if(restarting) return; restarting=true;
  document.getElementById('m').textContent='正在重启 QQ…';
  fetch('restart',{method:'POST'}).then(r=>r.json()).then(j=>{
    document.getElementById('m').textContent=j.restarted?'已提交重启，稍等几秒刷新':'重启过于频繁，请稍后';
    setTimeout(()=>{restarting=false;refresh();},5000);
  }).catch(()=>{restarting=false;document.getElementById('m').textContent='重启请求失败';});
}
function refresh(){
  if(restarting) return;
  document.getElementById('q').src='qr.png?t='+Date.now();
  fetch('status').then(r=>r.json()).then(j=>{
    var m={logged_in:'已登录 ✅（可进入控制台）',waiting_scan:'等待扫码',waiting_qq:'等待 QQ 启动'};
    document.getElementById('s').textContent=(m[j.phase]||j.phase)+(j.qr_age?(' · 二维码更新于 '+j.qr_age+'s 前'):'');
    document.getElementById('q').style.display=j.phase==='logged_in'?'none':'';
  }).catch(()=>{});
  fetch('api/quicklogin').then(r=>r.json()).then(j=>{
    if(j.items&&j.items.length){document.getElementById('qk').textContent='快速登录: '+j.items.map(x=>x.nick||x.uin).join(' / ');}
  }).catch(()=>{});
}
setInterval(refresh,2000);refresh();
</script></body>"""
        return self._send(200, html.encode())

    def do_POST(self):
        if self.path.startswith("/restart") or self.path.startswith("/api/restart"):
            ok = restart_qq("manual")
            return self._send(200, json.dumps({"ok": ok, "restarted": ok}).encode(), "application/json")
        return self._send(404, b"not found", "text/plain")


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
    ap.add_argument("--port", type=int, default=16080)
    ap.add_argument("--display", default=":1")
    ap.add_argument("--root", default=os.environ.get("MIOHH_ROOT", "/opt/miohh"))
    ap.add_argument("--onebot", default="http://127.0.0.1:3000/get_status")
    args = ap.parse_args()
    STATE.update({"display": args.display, "root": args.root, "onebot": args.onebot})
    threading.Thread(target=state_writer, daemon=True).start()
    threading.Thread(target=watchdog, daemon=True).start()
    threading.Thread(target=auto_assist, daemon=True).start()
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    srv.daemon_threads = True
    print(f"[miohh] login Manager: http://{args.host}:{args.port}/  display={args.display} root={args.root} "
          f"stale={QR_STALE_SECONDS}s auto_restart={AUTO_RESTART}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
