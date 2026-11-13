#!/usr/bin/env bash
# miohh 运行状态
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
JSON=0
[ "${1:-}" = "--json" ] && JSON=1
QQPID="$(pgrep -f '/opt/QQ/qq' 2>/dev/null | head -1 || true)"
PORT_STATE=""
for p in 3000 3001 5099; do
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then PORT_STATE="$PORT_STATE $p:up"; else PORT_STATE="$PORT_STATE $p:down"; fi
done
if [ "$JSON" = 1 ]; then
  printf '{"qq_pid":%s,"ports":"%s"}\n' "${QQPID:-null}" "$(echo "$PORT_STATE" | sed 's/^ //')"
else
  echo "[miohh status]"
  echo "  qq_pid: ${QQPID:-未运行}"
  echo "  ports:${PORT_STATE}"
  systemctl is-active qts 2>/dev/null || systemctl is-active miohh 2>/dev/null || true
fi
