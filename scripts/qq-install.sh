#!/usr/bin/env bash
# 安装钉版 QQ（miohh 依赖）并锁定版本
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
need_root

QQ_VER="3.2.32-52194"
SHA="d085dd89397225061eb9f194308f688129818ed445777e97a4a0a16e13d7b0e8"
DEB="/tmp/miohh-linuxqq_$QQ_VER.deb"
URLS=(
  "https://github.com/Rodert/qq-versions/releases/download/qq-packages-20260813-1d08f1d4/QQ_3.2.32_260812_amd64_01.deb"
  "https://dldir1.qq.com/qqfile/qq/QQNT/Linux/QQ_3.2.32_260812_amd64_01.deb"
)

log "安装钉版 QQ $QQ_VER"
if [ -f "$DEB" ]; then
  log "复用已下载包: $DEB"
else
  ok=0
  for u in "${URLS[@]}"; do
    log "下载: $u"
    if curl -fL --retry 2 --connect-timeout 30 --max-time 900 -o "$DEB" "$u"; then ok=1; break; fi
    rm -f "$DEB"
  done
  [ "$ok" = 1 ] || die "QQ 安装包下载失败（可手动放到 $DEB）" 4
fi
ACTUAL="$(sha256sum "$DEB" | awk '{print $1}')"
if [ "$ACTUAL" != "$SHA" ]; then
  warn "sha256 不匹配：$ACTUAL（期望 $SHA），继续但请核对来源"
fi
export DEBIAN_FRONTEND=noninteractive
dpkg -i "$DEB" || apt-get -f install -y
apt-mark hold linuxqq >/dev/null 2>&1 || true
log "QQ 安装完成：$(grep -m1 version /opt/QQ/resources/app/package.json 2>/dev/null || echo unknown)"
