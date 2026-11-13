#!/usr/bin/env bash
# miohh systemd 单元/定时器/日志轮转管理
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
need_root
CMD="${1:-install}"
case "$CMD" in
  install)
    cp -f "$MIOHH_ROOT/systemd/"*.service /etc/systemd/system/ 2>/dev/null || true
    cp -f "$MIOHH_ROOT/systemd/"*.timer /etc/systemd/system/ 2>/dev/null || true
    rm -f /etc/systemd/system/miohh.service
    ln -sf qts.service /etc/systemd/system/miohh.service
    if [ -f "$MIOHH_ROOT/systemd/miohh.logrotate" ]; then
      cp -f "$MIOHH_ROOT/systemd/miohh.logrotate" /etc/logrotate.d/miohh
    fi
    systemctl daemon-reload
    systemctl enable qts.service 2>/dev/null || true
    systemctl enable --now miohh-healthcheck.timer 2>/dev/null || true
    systemctl enable --now miohh-qq-guard.timer 2>/dev/null || true
    systemctl enable --now miohh-backup.timer 2>/dev/null || true
    log "systemd 单元/定时器已安装并启用"
    ;;
  status)
    systemctl status qts.service --no-pager 2>/dev/null | head -15 || true
    systemctl list-timers 'miohh*' --no-pager 2>/dev/null | head -8 || true
    ;;
  uninstall)
    systemctl disable --now qts.service 2>/dev/null || true
    systemctl disable --now miohh-healthcheck.timer 2>/dev/null || true
    systemctl disable --now miohh-qq-guard.timer 2>/dev/null || true
    systemctl disable --now miohh-backup.timer 2>/dev/null || true
    rm -f /etc/systemd/system/qts.service /etc/systemd/system/miohh.service
    rm -f /etc/systemd/system/miohh*.service /etc/systemd/system/miohh*.timer /etc/logrotate.d/miohh
    systemctl daemon-reload 2>/dev/null || true
    log "systemd 单元已移除"
    ;;
  *) die "usage: miohh service install|status|uninstall" 2 ;;
esac
