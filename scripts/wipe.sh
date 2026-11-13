#!/usr/bin/env bash
# miohh 安全清理（日志/截图/临时/诊断包）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
YES=0; PROFILES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --profiles) PROFILES=1; shift ;;
    -h|--help) echo "usage: miohh wipe --yes [--profiles]"; exit 0 ;;
    *) die "未知参数: $1" 2 ;;
  esac
done
[ "$YES" = 1 ] || die "需要 --yes 确认" 2
log "清理日志/截图/临时/诊断包"
rm -f "$MIOHH_ROOT"/logs/*.log "$MIOHH_ROOT"/logs/*.out 2>/dev/null || true
rm -rf "$MIOHH_ROOT"/screens "$MIOHH_ROOT"/diag-*.tar.gz 2>/dev/null || true
rm -f /tmp/miohh* /tmp/login_manager.log /tmp/probe_*.out /tmp/miohh_capture_*.bin 2>/dev/null || true
rm -f "$MIOHH_ROOT"/run/login-qr.png 2>/dev/null || true
if [ "$PROFILES" = 1 ]; then
  log "--profiles：重置设备档案（下次启动重新生成）"
  rm -f "$MIOHH_ROOT"/profiles/*.json 2>/dev/null || true
fi
log "清理完成（账号数据目录未动：$MIOHH_ROOT/data）"
