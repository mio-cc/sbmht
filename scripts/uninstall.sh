#!/usr/bin/env bash
# miohh 卸载
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1
PREFIX="${MIOHH_ROOT:-/opt/miohh}"
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^miohh\.service'; then
  systemctl disable --now miohh 2>/dev/null || true
  rm -f /etc/systemd/system/qts.service /etc/systemd/system/miohh.service
  rm -f /etc/systemd/system/miohh-healthcheck.service /etc/systemd/system/miohh-healthcheck.timer
  systemctl daemon-reload 2>/dev/null || true
fi
if [ -f "$PREFIX/run/serve.pid" ]; then
  kill -TERM "$(cat "$PREFIX/run/serve.pid" 2>/dev/null)" 2>/dev/null || true
fi
pkill -f '/opt/QQ/qq' 2>/dev/null || true
rm -f /usr/local/bin/miohh
if [ "$PURGE" = 1 ]; then
  log "purge：删除 $PREFIX 全部数据"
  rm -rf "$PREFIX"
else
  log "保留数据目录（--purge 可彻底删除）: $PREFIX"
fi
log "卸载完成"
