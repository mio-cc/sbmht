#!/usr/bin/env bash
# miohh 健康检查（进程/登录/端口/磁盘/日志）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
JSON=0; [ "${1:-}" = "--json" ] && JSON=1
fails=0; warns=0
ok()   { if [ "$JSON" = 0 ]; then printf "  PASS  %s\n" "$*"; fi; return 0; }
bad()  { if [ "$JSON" = 0 ]; then printf "  FAIL  %s\n" "$*"; fi; fails=$((fails+1)); return 0; }
warn() { if [ "$JSON" = 0 ]; then printf "  WARN  %s\n" "$*"; fi; warns=$((warns+1)); return 0; }

RUN="$MIOHH_ROOT/run"
SERVE_PID="$(cat "$RUN/serve.pid" 2>/dev/null | tr -dc '0-9' || true)"
if [ -n "$SERVE_PID" ] && kill -0 "$SERVE_PID" 2>/dev/null; then ok "serve 进程: $SERVE_PID"; else bad "serve 进程未运行"; fi
QQPID="$(pgrep -f '/opt/QQ/qq' 2>/dev/null | head -1 || true)"
if [ -n "$QQPID" ]; then ok "QQ 进程: $QQPID"; else bad "QQ 进程未运行"; fi
PHASE="$(cat "$RUN/login.state" 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
[ -n "$PHASE" ] || PHASE="unknown"
case "$PHASE" in
  logged_in) ok "登录状态: logged_in" ;;
  waiting_scan|waiting_qq|starting) ok "登录状态: $PHASE" ;;
  *) bad "登录状态异常: $PHASE" ;;
esac
# QQ 版本与热更新锁定检查
EXPECTED_QQ="${MIOHH_QQ_VERSION:-3.2.32-52194}"
if [ -f /opt/QQ/resources/app/package.json ]; then
  CUR_QQ="$(grep -m1 '"version"' /opt/QQ/resources/app/package.json | sed -E 's/.*"version"[^"]*"([^"]+)".*/\1/')"
  if [ "$CUR_QQ" = "$EXPECTED_QQ" ]; then ok "QQ 版本: $CUR_QQ"; else bad "QQ 版本漂移: $CUR_QQ（期望 $EXPECTED_QQ）"; fi
else
  bad "未找到 /opt/QQ/resources/app/package.json"
fi
QQRUNUSER="$(python3 - "$MIOHH_ROOT/profiles/auto.json" <<'PY' 2>/dev/null || true
import json,sys
try:
    d=json.load(open(sys.argv[1])); print(d.get("user") or d.get("run_user") or "")
except Exception: pass
PY
)"
QQHOME=""
[ -n "$QQRUNUSER" ] && QQHOME="$(getent passwd "$QQRUNUSER" | cut -d: -f6)"
if [ -n "$QQHOME" ] && [ -d "$QQHOME/.config/QQ/versions" ]; then
  VD="$QQHOME/.config/QQ/versions"
  PKGN="$(find "$VD" -mindepth 1 -maxdepth 1 \( -type d -name '[0-9]*' -o -type f -name '*.zip*' \) 2>/dev/null | wc -l)"
  if [ "$PKGN" -eq 0 ]; then ok "QQ 热更新包: 无"; else warn "QQ versions 内有 $PKGN 个更新包（guard 会清理）"; fi
  CVER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("curVersion",""))' "$VD/config.json" 2>/dev/null || true)"
  if [ -n "$CVER" ] && [ "$CVER" = "$EXPECTED_QQ" ]; then ok "QQ launcher curVersion: $CVER"; else warn "QQ launcher curVersion 异常: ${CVER:-missing}（期望 $EXPECTED_QQ）"; fi
fi
GW_PORT="${MIOHH_GATEWAY_PORT:-5099}"
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$GW_PORT$"; then ok "统一 WebUI 端口: $GW_PORT"; else bad "统一 WebUI 端口 $GW_PORT 未监听"; fi
if curl -s -m 2 "http://127.0.0.1:$GW_PORT/login/status" 2>/dev/null | grep -q '"phase"'; then ok "登录页: http://127.0.0.1:$GW_PORT/login/"; else warn "登录页 /login 不可用"; fi
ONEBOT=0
if curl -s -m 2 "http://127.0.0.1:3000/get_status" 2>/dev/null | grep -q '"online":true'; then ONEBOT=1; ok "OneBot: online"; fi
if [ "$ONEBOT" = 0 ]; then
  if [ "$PHASE" = "logged_in" ]; then bad "OneBot 不可用（phase=logged_in）"; else warn "OneBot 未就绪（phase=$PHASE，登录后自动启动）"; fi
fi
for p in 3000 3001; do
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then ok "端口 $p 监听"; else warn "端口 $p 未监听（未登录阶段正常）"; fi
done
DISK_FREE="$(df -Pm "$MIOHH_ROOT" 2>/dev/null | awk 'NR==2{print $4}' | tr -dc '0-9')"; DISK_FREE="${DISK_FREE:-0}"
if [ "$DISK_FREE" -ge 5120 ]; then ok "磁盘可用: ${DISK_FREE}MB"; else bad "磁盘不足: ${DISK_FREE}MB"; fi
LOG_MB="$(du -sm "$MIOHH_ROOT/logs" 2>/dev/null | awk '{print $1}' | tr -dc '0-9')"; LOG_MB="${LOG_MB:-0}"
if [ "$LOG_MB" -le 512 ]; then ok "日志体积: ${LOG_MB}MB"; else bad "日志过大: ${LOG_MB}MB"; fi

if [ "$JSON" = 1 ]; then
  MIOHH_HC_SERVE="$SERVE_PID" MIOHH_HC_QQ="$QQPID" MIOHH_HC_PHASE="$PHASE" \
  MIOHH_HC_FAIL="$fails" MIOHH_HC_WARN="$warns" MIOHH_HC_DISK="$DISK_FREE" MIOHH_HC_LOG="$LOG_MB" \
  python3 - <<'PY'
import json, os
def num(name):
    v = os.environ.get(name, "")
    return int(v) if v.isdigit() else None
print(json.dumps({
    "serve_pid": num("MIOHH_HC_SERVE"),
    "qq_pid": num("MIOHH_HC_QQ"),
    "phase": os.environ.get("MIOHH_HC_PHASE", "unknown"),
    "fail": num("MIOHH_HC_FAIL") or 0,
    "warns": num("MIOHH_HC_WARN") or 0,
    "disk_free_mb": num("MIOHH_HC_DISK") or 0,
    "log_mb": num("MIOHH_HC_LOG") or 0,
}, ensure_ascii=False))
PY
fi
if [ "$fails" -eq 0 ]; then [ "$JSON" = 0 ] && echo "[miohh healthcheck] RESULT: PASS（warns=$warns）"; exit 0; else [ "$JSON" = 0 ] && echo "[miohh healthcheck] RESULT: FAIL（fails=$fails warns=$warns）"; exit 6; fi
