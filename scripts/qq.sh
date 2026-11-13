#!/usr/bin/env bash
# miohh QQ 管理
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
CMD="${1:-status}"
case "$CMD" in
  install) need_root; bash "$HERE/qq-install.sh" ;;
  pin) need_root; apt-mark hold linuxqq >/dev/null 2>&1 || true; log "linuxqq 已锁定版本" ;;
  unpin) need_root; apt-mark unhold linuxqq >/dev/null 2>&1 || true; log "linuxqq 已解锁" ;;
  status)
    echo "QQ 版本: $(grep -m1 version /opt/QQ/resources/app/package.json 2>/dev/null || echo 未安装)"
    dpkg -l linuxqq 2>/dev/null | tail -1 || true
    apt-mark showhold 2>/dev/null | grep -i linuxqq || echo "未锁定"
    ;;
  *) die "usage: miohh qq install|pin|unpin|status" 2 ;;
esac
