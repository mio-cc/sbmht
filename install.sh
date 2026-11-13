#!/usr/bin/env bash
# miohh 一键安装（骨架 → 可运行：依赖/QQ/配置/profile/服务）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/scripts/lib.sh"

PREFIX="${MIOHH_PREFIX:-/opt/miohh}"
SKIP_DEPS=0; SKIP_QQ=0; NO_SYSTEMD=0; NO_LINK=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --skip-qq) SKIP_QQ=1; shift ;;
    --no-systemd) NO_SYSTEMD=1; shift ;;
    --no-link) NO_LINK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) echo "usage: install.sh [--prefix DIR] [--skip-deps] [--skip-qq] [--no-systemd] [--no-link] [--dry-run]"; exit 0 ;;
    *) die "未知参数: $1" 2 ;;
  esac
done

log "安装 miohh -> $PREFIX"
[ "$DRY" = 1 ] && log "DRY-RUN：只打印不执行"

run() { if [ "$DRY" = 1 ]; then echo "[dry] $*"; else "$@"; fi; }

if [ "$SKIP_DEPS" = 0 ] && [ "$DRY" = 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    apt-get install -y --no-install-recommends xvfb imagemagick xdotool x11-utils python3 python3-pil curl ca-certificates fonts-wqy-zenhei logrotate >/dev/null 2>&1 || \
      warn "依赖安装部分失败，请手动补装（xvfb/imagemagick/python3/fonts）"
    # locale：确保 zh_CN.UTF-8 真正可用（只跑 locale-gen 不够，必须先写 /etc/locale.gen）
    if command -v locale-gen >/dev/null 2>&1; then
      if [ -f /etc/locale.gen ]; then
        grep -qE '^[#[:space:]]*zh_CN\.UTF-8[[:space:]]+UTF-8' /etc/locale.gen || echo 'zh_CN.UTF-8 UTF-8' >> /etc/locale.gen
        sed -i 's/^[#[:space:]]*\(zh_CN\.UTF-8[[:space:]]\+UTF-8\)/\1/' /etc/locale.gen
      fi
      locale-gen zh_CN.UTF-8 >/dev/null 2>&1 || true
    fi
  else
    warn "非 Debian/Ubuntu：请手动安装 xvfb/imagemagick/python3/字体"
  fi
fi

if [ "$SKIP_QQ" = 0 ] && [ "$DRY" = 0 ]; then
  if [ ! -x /opt/QQ/qq ]; then
    log "安装钉版 QQ（3.2.32-52194）"
    bash "$HERE/scripts/qq-install.sh"
  else
    log "已存在 /opt/QQ/qq，跳过 QQ 安装"
  fi
fi
# 已安装 QQ 也强制锁版本（防止热更新/升级破坏 hook 契约）
if [ "$DRY" = 0 ] && command -v apt-mark >/dev/null 2>&1 && dpkg -s linuxqq >/dev/null 2>&1; then
  apt-mark hold linuxqq >/dev/null 2>&1 || true
fi

run mkdir -p "$PREFIX"
for d in bin runtime envsim scripts systemd config contracts tools assets; do
  [ -d "$HERE/$d" ] || continue
  run cp -a "$HERE/$d" "$PREFIX/"
done
run cp -f "$HERE/VERSION" "$PREFIX/VERSION"
run cp -f "$HERE/NOTICE" "$PREFIX/NOTICE" 2>/dev/null || true
run cp -f "$HERE/README.md" "$PREFIX/README.md" 2>/dev/null || true
run cp -f "$HERE/install.sh" "$PREFIX/install.sh" 2>/dev/null || true
run cp -f "$HERE/deploy.sh" "$PREFIX/deploy.sh" 2>/dev/null || true
run mkdir -p "$PREFIX/logs" "$PREFIX/profiles" "$PREFIX/data" "$PREFIX/run"
run chmod +x "$PREFIX/bin/miohh" "$PREFIX/scripts/"*.sh 2>/dev/null || true
run chmod +x "$PREFIX/runtime/bundled/node" "$PREFIX/runtime/bundled/launcher.sh" 2>/dev/null || true
# 清理仅用于研发的自测脚本（不随部署物分发）
if [ "$DRY" = 0 ]; then rm -f "$PREFIX"/tools/box_*.sh "$PREFIX"/tools/m3fix*.sh 2>/dev/null || true; fi
if [ ! -f "$PREFIX/config/miohh.yaml" ]; then
  run cp -f "$PREFIX/config/miohh.yaml.example" "$PREFIX/config/miohh.yaml"
fi
if [ ! -f "$PREFIX/config/service.env" ] && [ -f "$PREFIX/config/service.env.example" ]; then
  run cp -f "$PREFIX/config/service.env.example" "$PREFIX/config/service.env"
fi

# 旧版本升级：把单一 6080 登录端口迁移为"统一入口 5099 + 内部端口"。
# 只动缺失 GATEWAY_PORT 的旧 env 文件，保留用户已有的其它变量（如 ENVCHECK_SKIP）。
if [ "$DRY" = 0 ] && [ -f "$PREFIX/config/service.env" ] && ! grep -q '^MIOHH_GATEWAY_PORT=' "$PREFIX/config/service.env"; then
  sed -i '/^MIOHH_LOGIN_PORT=/d' "$PREFIX/config/service.env"
  cat >> "$PREFIX/config/service.env" <<'EOF'
# 统一入口：/ = 控制台，/login/ = QQ 扫码登录页
MIOHH_GATEWAY_PORT=5099
MIOHH_WEBUI_PORT=15099
MIOHH_LOGIN_PORT=16080
EOF
  log "已迁移 service.env：统一入口 5099（登录页 /login）"
fi

if [ "$NO_LINK" = 0 ] && [ "$DRY" = 0 ]; then
  ln -sf "$PREFIX/bin/miohh" /usr/local/bin/miohh
fi

if [ "$NO_SYSTEMD" = 0 ] && [ "$DRY" = 0 ] && [ -d /etc/systemd/system ]; then
  cp -f "$PREFIX/systemd/"*.service /etc/systemd/system/ 2>/dev/null || true
  cp -f "$PREFIX/systemd/"*.timer /etc/systemd/system/ 2>/dev/null || true
  [ -f "$PREFIX/systemd/miohh.logrotate" ] && cp -f "$PREFIX/systemd/miohh.logrotate" /etc/logrotate.d/miohh 2>/dev/null || true
  rm -f /etc/systemd/system/miohh.service
  ln -sf qts.service /etc/systemd/system/miohh.service
  systemctl daemon-reload || true
fi

if [ "$DRY" = 0 ]; then
  # 确保有一个可用于运行 QQ 的普通用户（envsim 会降权到该用户）。
  # 全新 VPS 常只有 root：没有普通用户时 envsim 只能以 root 回退运行，
  # 且缺少 HOME 会导致 QQ 启动即崩溃。这里自动创建 user（uid 1000）。
  has_runner=0
  while IFS=: read -r _name _pw _uid _gid _gecos _home _shell; do
    case "$_uid" in ''|*[!0-9]*) continue ;; esac
    [ "$_uid" -ge 1000 ] 2>/dev/null || continue
    [ "$_uid" -lt 65534 ] 2>/dev/null || continue
    [ -d "$_home" ] || continue
    has_runner=1
    break
  done < /etc/passwd
  if [ "$has_runner" = 0 ]; then
    if command -v useradd >/dev/null 2>&1; then
      useradd -m -s /bin/bash user >/dev/null 2>&1 || warn "创建运行用户 user 失败（QQ 将以 root 回退运行）"
      mkdir -p "/run/user/$(id -u user 2>/dev/null || echo 1000)"
      chown "user" "/run/user/$(id -u user 2>/dev/null || echo 1000)" 2>/dev/null || true
      chmod 700 "/run/user/$(id -u user 2>/dev/null || echo 1000)" 2>/dev/null || true
      log "已创建运行用户：user（envsim 将降权运行 QQ）"
    else
      warn "缺少 useradd，无法创建普通用户（QQ 将以 root 回退运行）"
    fi
  fi
  bash "$PREFIX/scripts/profile-gen.sh" >/dev/null 2>&1 || warn "profile-gen 失败（可在启动时自动重试）"
  MIOHH_ROOT="$PREFIX" bash "$PREFIX/scripts/qq-guard.sh" >/dev/null 2>&1 || warn "qq-guard 首次执行失败（timer 会重试）"
fi
log "安装完成。下一步：miohh env-check && miohh start（或 systemctl enable --now miohh）"
