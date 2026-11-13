#!/usr/bin/env bash
# miohh 登录辅助：截图二维码 / 等待登录 / 状态
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

MODE="auto"; OUT=""; DISPLAY_NUM="${DISPLAY_NUM:-:1}"; WAIT=0; SERVE=0; SERVE_PORT=6080
while [ $# -gt 0 ]; do
  case "$1" in
    --screenshot) MODE="screenshot"; shift ;;
    --qr) MODE="qr"; shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --display) DISPLAY_NUM="${2:-:1}"; shift 2 ;;
    --wait-login) WAIT="${2:-180}"; shift 2 ;;
    --serve) SERVE=1; shift ;;
    --serve-port) SERVE_PORT="${2:-6080}"; shift 2 ;;
    -h|--help) echo "usage: miohh login [--screenshot|--qr] [--out PNG] [--display :1] [--wait-login SEC]"; exit 0 ;;
    *) die "未知参数: $1" 2 ;;
  esac
done

RUN_DIR="$MIOHH_ROOT/run"; mkdir -p "$RUN_DIR"
[ -n "$OUT" ] || OUT="$RUN_DIR/login-qr.png"

if ! command -v import >/dev/null 2>&1; then
  die "需要 imagemagick（import）" 6
fi

case "$MODE" in
  screenshot|auto|qr)
    log "截图登录窗口（DISPLAY=$DISPLAY_NUM）-> $OUT"
    import -display "$DISPLAY_NUM" -window root "$OUT" || die "截图失败（X/显示不可用？）" 6
    if [ -s "$OUT" ]; then
      log "二维码截图: $OUT"
      printf '{"mode":"screenshot","ok":true,"qr_png":"%s"}\n' "$OUT"
    else
      die "截图文件为空" 6
    fi
    ;;
esac

if [ "$SERVE" = "1" ]; then
  log "启动二维码 WebUI: http://127.0.0.1:${SERVE_PORT}/ （仅本机）"
  exec python3 "$MIOHH_ROOT/tools/login_manager.py" --host 127.0.0.1 --port "$SERVE_PORT" --display "$DISPLAY_NUM" --root "$MIOHH_ROOT"
fi

if [ "$WAIT" -gt 0 ]; then
  log "等待登录（最多 ${WAIT}s）..."
  deadline=$(( $(date +%s) + WAIT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # 登录态由运行时写入的 run/login.state（M1 接入）；不存在时用 OneBot 探活兜底
    if [ -f "$RUN_DIR/login.state" ] && grep -q 'logged_in' "$RUN_DIR/login.state" 2>/dev/null; then
      log "检测到登录成功"; exit 0
    fi
    if curl -s -m 2 "http://127.0.0.1:3000/get_status" 2>/dev/null | grep -q '"online":true'; then
      log "OneBot 在线，判定登录成功"; exit 0
    fi
    sleep 2
  done
  log "等待登录超时"; exit 5
fi
