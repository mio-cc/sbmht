#!/usr/bin/env bash
# miohh 日志查看（脱敏输出）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
FOLLOW=0; SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --follow|-f) FOLLOW=1; shift ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    -h|--help) echo "usage: miohh logs [--follow] [--since TIME]"; exit 0 ;;
    *) die "未知参数: $1" 2 ;;
  esac
done
if [ -f "$LOG_DIR/miohh.log" ]; then LOG="$LOG_DIR/miohh.log"; elif [ -f "$LOG_DIR/serve.out" ]; then LOG="$LOG_DIR/serve.out"; else echo "[miohh] 暂无日志文件" >&2; exit 6; fi
mask() { sed -E 's/(access_token|token|password|qrcode|base64)[=:][^ ,"]+/\1=***/Ig; s/[A-Za-z0-9_-]{40,}/***/g'; }
if [ "$FOLLOW" = 1 ]; then tail -n 200 -f "$LOG" | mask; else tail -n 400 "$LOG" | mask; fi
