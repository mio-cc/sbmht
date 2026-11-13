#!/usr/bin/env bash
# miohh 账号管理（M1 原生 IPC 接入前：提供列表/状态；切号/登出走 QQ 管理）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
CMD="${1:-list}"
case "$CMD" in
  list)
    echo "登录状态: $(cat "$MIOHH_ROOT/run/login.state" 2>/dev/null || echo unknown)"
    echo "快速登录列表:"
    if [ -f "$MIOHH_ROOT/run/quicklogin.json" ]; then
      python3 - "$MIOHH_ROOT/run/quicklogin.json" <<'PY'
import json,sys
try:
    for it in json.load(open(sys.argv[1])):
        print("  - uin=%s nick=%s quick=%s" % (it.get("uin"), it.get("nick") or it.get("nickName") or "", it.get("isQuickLogin")))
except Exception as e:
    print("  (解析失败)", e)
PY
    else
      echo "  (暂无数据；原生登录钩子接入后写入)"
    fi
    ;;
  switch)
    echo "[miohh] 切号需要原生登录 IPC（PipeOp 30-34，M1 backlog）；当前请通过 QQ 登录界面切换" >&2
    exit 2 ;;
  logout)
    echo "[miohh] 登出将关闭 QQ 并等待重新登录（当前行为：停止服务）"
    bash "$MIOHH_ROOT/bin/miohh" stop
    ;;
  *) die "usage: miohh account list|switch|logout" 2 ;;
esac
