#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""QQ 启动器（双重 fork / daemon 化）：
- serve.py 调用本脚本，脚本 fork 两次后 exec 真正的 envsim+QQ 命令；
- 效果：QQ 的祖先进程链不再出现 serve.py/envsim，终点为 PID 1（systemd/init）；
- 子进程 PID 写入 run/qq.pid 供 serve 监控/清理。
"""
import os
import sys
import time


def main():
    if len(sys.argv) < 2:
        sys.exit(2)
    run_dir = os.environ.get("MIOHH_RUN_DIR") or os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "run")
    pid = os.fork()
    if pid > 0:
        os._exit(0)
    os.setsid()
    pid = os.fork()
    if pid > 0:
        os._exit(0)
    try:
        os.makedirs(run_dir, exist_ok=True)
        with open(os.path.join(run_dir, "qq.pid"), "w",
                  encoding="utf-8") as f:
            f.write(str(os.getpid()) + "\n")
    except OSError:
        pass
    os.environ.pop("MIOHH_RUN_DIR", None)
    try:
        os.execvp(sys.argv[1], sys.argv[1:])
    except OSError:
        os._exit(127)


if __name__ == "__main__":
    main()
