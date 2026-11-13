#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""miohh 运行时编排（miohh _serve）：
1) 准备 DeviceProfile（缺失则自动探测生成）
2) 确保 X 显示（已有则复用；无则起 Xvfb）
3) 通过 envsim 沙箱启动 QQ
4) 启动登录管理器（二维码 WebUI）
5) 启动 bundled runtime（OneBot/WebUI/注入；存在时自动）
6) 守护/重启子进程，SIGTERM 时清理
"""
import json
import os
import pwd
import secrets
import signal
import socket
import subprocess
import sys
import threading
import time
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.environ.get("MIOHH_ROOT", "/opt/miohh")
DISPLAY_NUM = os.environ.get("MIOHH_DISPLAY") or os.environ.get("DISPLAY") or ":1"
# 统一入口：对外只开 GATEWAY_PORT（默认 5099），QQ 登录页挂在 /login，
# 其余请求反代到 runtime WebUI（内部端口，默认 15099），登录管理器内部端口默认 16080。
GATEWAY_PORT = int(os.environ.get("MIOHH_GATEWAY_PORT", "5099"))
WEBUI_PORT = int(os.environ.get("MIOHH_WEBUI_PORT", "15099"))
LOGIN_PORT = int(os.environ.get("MIOHH_LOGIN_PORT", "16080"))
if WEBUI_PORT == GATEWAY_PORT:
    WEBUI_PORT = GATEWAY_PORT + 1
    print("[miohh] MIOHH_WEBUI_PORT 与网关端口冲突，runtime 内部端口改用 %d" % WEBUI_PORT, flush=True)
LOG = os.path.join(ROOT, "logs", "miohh.log")
RUN = os.path.join(ROOT, "run")
QQ_BIN = os.environ.get("MIOHH_QQ_BIN", "/opt/QQ/qq")
PROFILE = os.path.join(ROOT, "profiles", "auto.json")
QQ_LAUNCH = os.path.join(ROOT, "runtime", "qq_launch.py")
QQ_PID_FILE = os.path.join(RUN, "qq.pid")
QQ_SPAWNED_AT = 0.0
QQ_START_GRACE = float(os.environ.get("MIOHH_QQ_START_GRACE", "120"))
children = []
stopping = False


def log(msg):
    line = "[miohh %s] %s" % (time.strftime("%F %T"), msg)
    print(line, flush=True)
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def port_open(host, port, timeout=0.3):
    s = socket.socket()
    s.settimeout(timeout)
    try:
        s.connect((host, port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def ensure_profile():
    if os.path.isfile(PROFILE):
        return True
    gen = os.path.join(ROOT, "envsim", "autogen_profile.py")
    if not os.path.isfile(gen):
        log("缺少 envsim/autogen_profile.py，无法生成档案")
        return False
    os.makedirs(os.path.dirname(PROFILE), exist_ok=True)
    r = subprocess.run([sys.executable, gen, "--out", PROFILE], capture_output=True, text=True, timeout=60)
    log("profile-gen rc=%d %s" % (r.returncode, (r.stdout or "").strip().splitlines()[-1:] or ""))
    return r.returncode == 0 and os.path.isfile(PROFILE)


def display_socket(display):
    n = display.lstrip(":")
    return "/tmp/.X11-unix/X%s" % n.split(".")[0]


def display_alive(display):
    """真正探测 X 显示是否可连接（避免残留 socket 骗过启动逻辑）。"""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.5)
        s.connect(display_socket(display))
        s.close()
        return True
    except OSError:
        return False


def ensure_display():
    sock = display_socket(DISPLAY_NUM)
    if os.path.exists(sock) and display_alive(DISPLAY_NUM):
        log("复用已有显示 %s" % DISPLAY_NUM)
        return True
    if os.path.exists(sock):
        # Xvfb 被杀后会留下 /tmp/.X11-unix/Xn 和 /tmp/.Xn-lock；残留 socket
        # 会让旧逻辑误判"显示已存在"，QQ 连不上 X 直接崩溃。
        log("显示 %s 的套接字存在但不可连（Xvfb 已死），清理后重启 Xvfb" % DISPLAY_NUM)
        try:
            os.unlink(sock)
        except OSError:
            pass
    disp_n = DISPLAY_NUM.lstrip(":").split(".")[0]
    lock = "/tmp/.X%s-lock" % disp_n
    try:
        os.unlink(lock)
    except OSError:
        pass
    try:
        # -ac：本机 headless 场景允许本地客户端（QQ 以普通用户运行）连接显示
        subprocess.Popen(["Xvfb", DISPLAY_NUM, "-screen", "0", "1920x1080x24", "-ac", "-nolisten", "tcp"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except FileNotFoundError:
        log("Xvfb 未安装（apt install xvfb）")
        return False
    for _ in range(50):
        if os.path.exists(sock) and display_alive(DISPLAY_NUM):
            log("Xvfb 已启动 %s" % DISPLAY_NUM)
            return True
        time.sleep(0.1)
    log("Xvfb 启动超时")
    return False


def start_child(name, argv, env=None, cwd=None):
    if name == "qq":
        # QQ 进程使用最小环境：杜绝 MIOHH/ENVSIM/systemd 等指纹泄漏到 /proc/self/environ
        e = {
            "PATH": os.environ.get("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"),
            "DISPLAY": DISPLAY_NUM,
        }
        if env:
            e.update(env)
    else:
        e = dict(os.environ)
        e.setdefault("DISPLAY", DISPLAY_NUM)
        if env:
            e.update(env)
    p = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         env=e, cwd=cwd, start_new_session=True)
    children.append((name, p))
    log("启动 %s pid=%d" % (name, p.pid))
    return p


def _pid_cmdline(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            return f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
    except OSError:
        return ""


def cleanup_stale_qq():
    """清理上一次崩溃残留的 launcher 链进程（dbus-run-session/envsim）。

    qq.pid 记录的是 daemon 化后的进程链 PID；QQ 本体崩溃后，链进程可能还活着，
    导致 qq_alive 误判、也会让端口/日志混乱。
    """
    try:
        with open(QQ_PID_FILE, encoding="utf-8") as f:
            pid = int(f.read().strip())
    except (OSError, ValueError):
        return
    cmd = _pid_cmdline(pid)
    if not cmd:
        return
    if QQ_BIN in cmd and "unshare" not in cmd and "dbus-run-session" not in cmd and "envsim" not in cmd:
        return  # 这已经是 QQ 本体，交给正常守护逻辑
    try:
        os.kill(pid, signal.SIGTERM)
        log("清理残留 QQ 启动链 pid=%d" % pid)
    except OSError:
        pass


def qq_alive():
    # 以真实 QQ 进程为准（argv0 是 /opt/QQ/qq）；启动宽限期内允许 launcher 链存活。
    try:
        r = subprocess.run(["pgrep", "-f", "^%s --no-sandbox" % QQ_BIN],
                           capture_output=True, timeout=3)
        if r.stdout.strip():
            return True
    except Exception:
        pass
    try:
        with open(QQ_PID_FILE, encoding="utf-8") as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        if time.time() - QQ_SPAWNED_AT < QQ_START_GRACE:
            return True
        cmd = _pid_cmdline(pid)
        # 链进程还活着但没有任何 QQ 进程 → 视为已死
        return bool(cmd and QQ_BIN in cmd and "dbus-run-session" not in cmd and "unshare" not in cmd)
    except (OSError, ValueError):
        return False


def _runner_ident():
    """QQ 运行身份的 HOME/USER/LOGNAME/XDG_RUNTIME_DIR。

    背景：serve 给 QQ 传的是最小环境（防指纹泄漏），envsim 在降权分支会自动补
    这些变量；但如果机器上没有普通用户（全新 VPS 常见），envsim 会走 root 回退
    分支——此前该分支缺 HOME，QQ/Electron 在无 HOME 环境下会 CHECK 崩溃
    （dmesg 报 qq trap invalid opcode/ud2）。这里统一兜底，保证两种分支都有 HOME。
    """
    user = ""
    try:
        with open(PROFILE, encoding="utf-8") as f:
            user = str((json.load(f) or {}).get("user") or "")
    except Exception:
        pass
    try:
        pw = pwd.getpwnam(user) if user else pwd.getpwuid(os.getuid())
        uid = pw.pw_uid
        runtime = os.environ.get("XDG_RUNTIME_DIR") or ("/run/user/%d" % uid if uid > 0 else "/tmp/miohh-runtime-%d" % uid)
        return {
            "HOME": pw.pw_dir or "/root",
            "USER": pw.pw_name,
            "LOGNAME": pw.pw_name,
            "XDG_RUNTIME_DIR": runtime,
        }
    except Exception:
        return {
            "HOME": os.environ.get("HOME", "/root"),
            "USER": os.environ.get("USER", "root"),
            "LOGNAME": os.environ.get("LOGNAME", "root"),
            "XDG_RUNTIME_DIR": os.environ.get("XDG_RUNTIME_DIR", "/tmp"),
        }


def start_qq():
    global QQ_SPAWNED_AT
    cleanup_stale_qq()
    QQ_SPAWNED_AT = time.time()
    envsim = os.path.join(ROOT, "envsim", "envsim.sh")
    qq_args = [QQ_BIN, "--no-sandbox", "--disable-gpu", "--enable-unsafe-swiftshader"]
    if os.path.isfile(envsim) and os.path.isfile(PROFILE) and os.path.isfile(QQ_LAUNCH):
        # 双重 fork（daemon 化）后再 exec envsim：断开 QQ 与 serve 的父进程链，
        # QQ 侧 /proc/<ppid>/cmdline 只能看到中性 launcher，最终祖先进程为 PID 1。
        minimal = {
            "PATH": os.environ.get("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"),
            "DISPLAY": DISPLAY_NUM,
            "MIOHH_RUN_DIR": RUN,
        }
        minimal.update(_runner_ident())
        argv = [sys.executable, QQ_LAUNCH, "bash", envsim, PROFILE,
                "dbus-run-session", "--"] + qq_args
        try:
            subprocess.run(argv, env=minimal, timeout=20,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            log("QQ 已通过 daemonized launcher 启动（父进程链已断开）")
            return None
        except Exception as e:
            log("daemonized launcher 失败，回退直接启动: %s" % e)
    if not os.path.isfile(envsim) or not os.path.isfile(PROFILE):
        log("envsim/档案缺失，直接启动 QQ（无仿真）")
        return start_child("qq", qq_args)
    return start_child("qq", ["bash", envsim, PROFILE, "dbus-run-session", "--"] + qq_args)


def start_login_manager():
    if port_open("127.0.0.1", LOGIN_PORT):
        log("登录管理器端口 %d 已被占用（可能是其他 miohh 实例/残留进程），拒绝复用" % LOGIN_PORT)
        raise SystemExit(7)
    argv = [sys.executable, os.path.join(ROOT, "tools", "login_manager.py"),
            "--host", "127.0.0.1", "--port", str(LOGIN_PORT),
            "--display", DISPLAY_NUM, "--root", ROOT]
    p = start_child("login-manager", argv)
    for _ in range(50):
        if port_open("127.0.0.1", LOGIN_PORT):
            log("登录服务: 内部 127.0.0.1:%d（对外 /login）" % LOGIN_PORT)
            break
        time.sleep(0.1)
    return p


class GatewayHandler(BaseHTTPRequestHandler):
    """统一入口：/login* → 登录管理器；其余 → runtime WebUI（支持 WebSocket 透传）。"""

    server_version = "miohh"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass

    def _logged_in(self):
        try:
            with open(os.path.join(RUN, "login.state"), encoding="utf-8") as f:
                return f.read().strip() == "logged_in"
        except OSError:
            return False

    def _target(self):
        path = self.path
        base = path.split("?", 1)[0]
        if base == "/login" or base.startswith("/login/"):
            rest = path[len("/login"):]
            return LOGIN_PORT, (rest or "/")
        if not self._logged_in():
            # 未登录时，根路径就是登录页（不再需要单独的 /login URL），
            # 登录页用到的相对资源也转给登录服务。
            if base in ("/", "/index.html"):
                return LOGIN_PORT, path
            if base in ("/qr.png", "/status", "/restart", "/api/quicklogin"):
                return LOGIN_PORT, path
        return WEBUI_PORT, path

    def _is_ws(self):
        return self.headers.get("Upgrade", "").lower() == "websocket"

    def _proxy(self):
        port, path = self._target()
        if self._is_ws():
            self._proxy_ws(port, path)
            return
        conn = None
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = 0
            body = self.rfile.read(length) if length > 0 else None
            headers = {}
            for k, v in self.headers.items():
                if k.lower() in ("host", "connection", "proxy-connection", "keep-alive", "transfer-encoding"):
                    continue
                headers[k] = v
            conn.request(self.command, path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() in ("connection", "transfer-encoding", "content-length"):
                    continue
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
        except Exception as e:
            try:
                self.send_error(502, "miohh gateway: %s" % e)
            except Exception:
                pass
        finally:
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass

    def _proxy_ws(self, port, path):
        try:
            up = socket.create_connection(("127.0.0.1", port), timeout=10)
        except OSError:
            try:
                self.send_error(502, "websocket upstream unavailable")
            except Exception:
                pass
            return
        try:
            lines = ["%s %s HTTP/1.1" % (self.command, path)]
            for k, v in self.headers.items():
                if k.lower() in ("host", "connection", "proxy-connection"):
                    continue
                lines.append("%s: %s" % (k, v))
            lines.append("Host: 127.0.0.1:%d" % port)
            up.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1", "replace"))
            import select
            socks = [self.connection, up]
            while True:
                try:
                    r, _, x = select.select(socks, [], [], 120)
                except (OSError, ValueError):
                    return
                if not r:
                    continue
                for s in r:
                    try:
                        data = s.recv(65536)
                    except OSError:
                        return
                    if not data:
                        return
                    other = up if s is self.connection else self.connection
                    try:
                        other.sendall(data)
                    except OSError:
                        return
        finally:
            try:
                up.close()
            except Exception:
                pass

    def do_GET(self):
        if self.path == "/login":
            self.send_response(302)
            self.send_header("Location", "/login/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._proxy()

    do_POST = _proxy
    do_PUT = _proxy
    do_DELETE = _proxy
    do_PATCH = _proxy
    do_HEAD = _proxy
    do_OPTIONS = _proxy


def start_gateway():
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", GATEWAY_PORT), GatewayHandler)
        srv.daemon_threads = True
    except OSError as e:
        log("统一 WebUI 端口 %d 启动失败: %s" % (GATEWAY_PORT, e))
        return None
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log("统一 WebUI: http://127.0.0.1:%d/ （QQ 登录: /login）" % GATEWAY_PORT)
    return srv


def runtime_enabled():
    if os.environ.get("MIOHH_RUNTIME", "auto") in ("0", "false", "off"):
        return False
    return os.path.isfile(os.path.join(ROOT, "runtime", "bundled", "index.mjs"))


def start_runtime():
    entry = os.path.join(ROOT, "runtime", "bundled", "index.mjs")
    if not os.path.isfile(entry):
        log("未发现 bundled runtime，跳过")
        return None
    node_bin = os.path.join(ROOT, "runtime", "bundled", "node")
    if not os.path.isfile(node_bin):
        node_bin = "node"
    work = os.path.join(ROOT, "data", "runtime")
    os.makedirs(os.path.join(work, "config"), exist_ok=True)
    pwd_file = os.path.join(work, "webui-password")
    if not os.path.isfile(pwd_file):
        with open(pwd_file, "w", encoding="utf-8") as f:
            f.write(secrets.token_hex(12) + "\n")
        os.chmod(pwd_file, 0o600)
    password = os.environ.get("MIOHH_WEBUI_PASSWORD") or open(pwd_file, encoding="utf-8").read().strip()
    webui_port = WEBUI_PORT
    env = {
        "MIOHHAPP_ACCEPT_EULA": "1",
        "MIOHHAPP_UPDATE_CHECK": "0",
        "MIOHHAPP_ACCEPT_PRIVACY": "1",
        "MIOHHAPP_HOOK_AUTOLOAD": os.environ.get("MIOHH_HOOK_AUTOLOAD", "1"),
        "MIOHHAPP_HOOK_AUTOLOAD_ALL": os.environ.get("MIOHH_HOOK_AUTOLOAD_ALL", "1"),
        "MIOHHAPP_LOG_DIR": os.path.join(ROOT, "logs", "runtime"),
        "MIOHHAPP_LOG_LEVEL": os.environ.get("MIOHH_RUNTIME_LOG_LEVEL", "info"),
        "MIOHHAPP_ONEBOT_HTTP_PORT": os.environ.get("MIOHH_ONEBOT_HTTP_PORT", "3000"),
        "MIOHHAPP_ONEBOT_WS_PORT": os.environ.get("MIOHH_ONEBOT_WS_PORT", "3001"),
        "MIOHHAPP_WEBUI_PORT": str(webui_port),
        "MIOHHAPP_WEBUI_HOST": "127.0.0.1",
        "MIOHHAPP_WEBUI_BOOTSTRAP_PASSWORD": password,
    }
    p = start_child("runtime", [node_bin, entry], env=env, cwd=work)
    log("runtime WebUI: 内部 127.0.0.1:%s（对外统一走 :%s）密码文件 %s" % (webui_port, GATEWAY_PORT, pwd_file))
    return p


def kill_stale_miohh():
    """清理上一实例残留的 runtime/login-manager 进程（端口冲突根因）。

    systemd 重启/超时/更新时，旧 serve 的清理可能没来得及执行，残留进程
    继续占着 3000/3001/15099/16080，导致新实例 env-check 端口占用失败、
    service 反复重启（对外表现为 502）。
    """
    me = os.getpid()
    markers = (
        os.path.join(ROOT, "runtime", "bundled", "index.mjs"),
        os.path.join(ROOT, "tools", "login_manager.py"),
    )
    killed = []
    try:
        for name in os.listdir("/proc"):
            if not name.isdigit():
                continue
            pid = int(name)
            if pid == me:
                continue
            cmd = _pid_cmdline(pid)
            if not cmd:
                continue
            if any(m in cmd for m in markers):
                try:
                    os.kill(pid, signal.SIGKILL)
                    killed.append(pid)
                except OSError:
                    pass
    except OSError:
        pass
    if killed:
        log("清理残留 miohh 子进程: %s" % killed)
        time.sleep(0.5)


def cleanup(*_args):
    global stopping
    if stopping:
        return
    stopping = True
    log("收到退出信号，清理子进程")
    # 先清理 daemon 化的 QQ（pid 文件记录）
    try:
        with open(QQ_PID_FILE, encoding="utf-8") as f:
            qqpid = int(f.read().strip())
        os.killpg(os.getpgid(qqpid), signal.SIGTERM)
    except (OSError, ValueError):
        pass
    time.sleep(1)
    try:
        subprocess.run(["pkill", "-9", "-f", "^%s" % QQ_BIN], timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
    for name, p in children:
        try:
            if p.poll() is None:
                os.killpg(os.getpgid(p.pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
    time.sleep(1)
    for _, p in children:
        try:
            if p.poll() is None:
                os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        os.unlink(os.path.join(RUN, "serve.pid"))
    except OSError:
        pass
    sys.exit(0)


def main():
    os.makedirs(RUN, exist_ok=True)
    os.makedirs(os.path.join(ROOT, "logs"), exist_ok=True)
    with open(os.path.join(RUN, "serve.pid"), "w", encoding="utf-8") as f:
        f.write(str(os.getpid()) + "\n")
    try:
        with open(os.path.join(RUN, "login.state"), "w", encoding="utf-8") as f:
            f.write("starting\n")
    except OSError:
        pass
    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)
    log("miohh 启动：root=%s display=%s" % (ROOT, DISPLAY_NUM))
    kill_stale_miohh()
    if not ensure_profile():
        log("档案生成失败（继续尝试）")
    if not ensure_display():
        log("显示不可用，退出")
        sys.exit(6)
    try:
        guard = os.path.join(ROOT, "scripts", "qq-guard.sh")
        if os.path.isfile(guard):
            r = subprocess.run(["bash", guard], capture_output=True, timeout=30)
            log("qq-guard rc=%d %s" % (r.returncode, (r.stdout or b"").decode("utf-8", "replace").strip().splitlines()[-1:] or ""))
    except Exception as e:
        log("qq-guard 执行失败: %s" % e)
    start_qq()
    start_login_manager()
    if runtime_enabled():
        start_runtime()
    else:
        log("bundled runtime 未启用/不存在（可设 MIOHH_RUNTIME=1 或放入 runtime/bundled）")
    start_gateway()
    restarts = {}
    qq_restarts = 0
    while not stopping:
        time.sleep(2)
        if not qq_alive():
            qq_restarts += 1
            log("QQ 进程不存在，重启（第 %d 次）" % qq_restarts)
            if qq_restarts > 20:
                log("QQ 重启次数过多，停止")
                cleanup()
            start_qq()
        for name, p in list(children):
            rc = p.poll()
            if rc is None:
                continue
            children.remove((name, p))
            if stopping:
                continue
            restarts[name] = restarts.get(name, 0) + 1
            log("%s 退出 rc=%s，第 %d 次重启" % (name, rc, restarts[name]))
            if restarts[name] > 20:
                log("%s 重启次数过多，停止" % name)
                cleanup()
            if name == "login-manager":
                start_login_manager()
            elif name == "runtime":
                start_runtime()


if __name__ == "__main__":
    main()
