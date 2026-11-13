#!/usr/bin/env bash
# miohh 部署环境门禁
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

JSON=0
[ "${1:-}" = "--json" ] && JSON=1
if [ "${MIOHH_ENVCHECK_SKIP:-0}" = "1" ]; then
  [ "$JSON" = 0 ] && echo "[miohh env-check] SKIP（MIOHH_ENVCHECK_SKIP=1）"
  [ "$JSON" = 1 ] && echo '{"skip":true,"fail":0}'
  exit 0
fi
fail=0
ok()  { [ "$JSON" = 0 ] && printf "  PASS  %s\n" "$*"; }
bad() { [ "$JSON" = 0 ] && printf "  FAIL  %s\n" "$*"; fail=$((fail+1)); }
warn(){ [ "$JSON" = 0 ] && printf "  WARN  %s\n" "$*"; }

KERNEL="$(uname -r)"
VIRT="$(systemd-detect-virt 2>/dev/null || echo unknown)"
DISTRO="$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)"
NPROC="$(nproc 2>/dev/null || echo 0)"
MEM_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
ROOTFS_FREE="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"

[ "$JSON" = 0 ] && echo "[miohh env-check]"
case "$VIRT" in
  kvm|none|amazon|microsoft) ok "虚拟化: $VIRT（普通 VPS/KVM）" ;;
  lxc|openvz|systemd-nspawn|docker|podman)
    bad "虚拟化: $VIRT（容器类环境不合格，请换 KVM VPS）" ;;
  *) warn "虚拟化: $VIRT（未知，需人工确认）" ;;
esac
if kernel_ok "$KERNEL"; then ok "内核: $KERNEL（标准发行版风格）"; else bad "内核: $KERNEL（非标准内核，uname/环境画像不一致，请换标准内核 VPS）"; fi
case "$DISTRO" in
  *Ubuntu*|*Debian*) ok "发行版: $DISTRO" ;;
  *) warn "发行版: $DISTRO（建议 Ubuntu/Debian 官方镜像）" ;;
esac
[ "$NPROC" -ge 2 ] && ok "vCPU: $NPROC" || bad "vCPU: $NPROC（建议 ≥2）"
[ "$MEM_MB" -ge 3500 ] && ok "内存: ${MEM_MB}MB" || bad "内存: ${MEM_MB}MB（建议 ≥4GB）"
[ "${ROOTFS_FREE:-0}" -ge 20000 ] && ok "根分区可用: ${ROOTFS_FREE}MB" || warn "根分区可用: ${ROOTFS_FREE}MB（建议 ≥20GB）"
if command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null | grep -qiE 'zh_CN\.utf-?8'; then
  ok "locale: zh_CN.UTF-8 可用"
else
  bad "locale: 缺少 zh_CN.UTF-8（安装阶段执行 locale-gen）"
fi
FONTS="$(fc-list 2>/dev/null | wc -l || echo 0)"
[ "$FONTS" -ge 100 ] && ok "字体: $FONTS" || warn "字体: $FONTS（建议安装常见字体集）"
for p in 3000 3001 5099; do
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then bad "端口 $p 已被占用"; else ok "端口 $p 可用"; fi
done
command -v python3 >/dev/null && ok "python3 可用" || bad "缺少 python3"
command -v curl >/dev/null && ok "curl 可用" || bad "缺少 curl"

if [ "$JSON" = 1 ]; then
  printf '{"kernel":"%s","virt":"%s","distro":"%s","nproc":%s,"mem_mb":%s,"fonts":%s,"fail":%s}\n' \
    "$KERNEL" "$VIRT" "$DISTRO" "$NPROC" "$MEM_MB" "$FONTS" "$fail"
fi
if [ "$fail" -eq 0 ]; then
  [ "$JSON" = 0 ] && echo "[miohh env-check] RESULT: PASS"
  exit 0
else
  [ "$JSON" = 0 ] && echo "[miohh env-check] RESULT: FAIL ($fail)"
  exit 3
fi
