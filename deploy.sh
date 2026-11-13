#!/usr/bin/env bash
# ============================================================================
# miohh 一键运维脚本（root 运行）
#
# 交互菜单：        sudo bash deploy.sh
# 命令模式：
#   sudo bash deploy.sh install            # 一键部署（依赖 + 钉版QQ + miohh + systemd）
#   sudo bash deploy.sh deploy             # install + 启动 + 健康检查
#   sudo bash deploy.sh update --from X    # 升级到发布包/目录（自动备份+回滚）
#   sudo bash deploy.sh pull               # 源码目录 git pull 后同步安装并重启
#   sudo bash deploy.sh build [--install]  # 构建发布包（可选直接安装）
#   sudo bash deploy.sh restart|start|stop|status
#   sudo bash deploy.sh logs [-f]          # 服务日志（journal 或文件）
#   sudo bash deploy.sh health             # 健康检查（失败返回非 0）
#   sudo bash deploy.sh doctor             # 诊断（环境/服务/端口/版本/磁盘/热更新）
#   sudo bash deploy.sh backup|restore --from F
#   sudo bash deploy.sh qq-guard           # 热更新屏蔽/版本锁定
#   sudo bash deploy.sh uninstall [--purge]
#   sudo bash deploy.sh version|help
#
# 常用覆盖变量：
#   PREFIX=/opt/miohh  MIOHH_QQ_VERSION=3.2.32-52194
#   SRC=/path/to/miohh-source  REPO=origin  BRANCH=main
#   NO_START=1  DRY_RUN=1  HEALTH_TIMEOUT=60
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-${MIOHH_PREFIX:-/opt/miohh}}"
SRC="${SRC:-${MIOHH_SOURCE_DIR:-$SCRIPT_DIR}}"
SERVICE_CANDIDATES=("qts.service" "miohh.service")
EXPECTED_QQ_VERSION="${MIOHH_QQ_VERSION:-3.2.32-52194}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
NO_START="${NO_START:-0}"
DRY_RUN="${DRY_RUN:-0}"
REPO="${REPO:-origin}"
BRANCH="${BRANCH:-}"
ASSUME_YES="${ASSUME_YES:-0}"

C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_YEL=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'
log()  { printf '%s[miohh]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
warn() { printf '%s[miohh]%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
fail() { printf '%s[miohh]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
ok()   { printf '%s[miohh]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { if [ "$DRY_RUN" = "1" ]; then echo "[dry] $*"; else "$@"; fi; }

require_root() { [ "$(id -u)" = "0" ] || fail "需要 root：sudo bash deploy.sh $*"; }
ensure_layout() {
  [ -d "$PREFIX" ] || fail "PREFIX 不存在：$PREFIX（先 install）"
  [ -x "$PREFIX/bin/miohh" ] || fail "$PREFIX/bin/miohh 不存在（安装不完整）"
}

svc_name() {
  for s in "${SERVICE_CANDIDATES[@]}"; do
    if systemctl cat "$s" >/dev/null 2>&1; then echo "$s"; return 0; fi
  done
  echo ""
}

systemd_available() { have systemctl && [ -d /etc/systemd/system ]; }

# ---------------------------------------------------------------------------
# 健康检查等待
# ---------------------------------------------------------------------------
health_json() { "$PREFIX/bin/miohh" healthcheck --json 2>/dev/null; }

health_wait() {
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local out; out="$(health_json)"
    if printf '%s' "$out" | grep -q '"fail": 0'; then
      ok "健康检查通过：$out"; return 0
    fi
    sleep 2
  done
  warn "健康检查超时（${HEALTH_TIMEOUT}s）：$(health_json)"
  # 自动 dump 失败原因，避免只看到 timeout 无从下手
  local svc; svc="$(svc_name)"
  if [ -n "$svc" ]; then
    warn "---- systemctl status $svc ----"
    systemctl status "$svc" --no-pager 2>&1 | head -20
    warn "---- journalctl -u $svc (最近 40 行) ----"
    journalctl -u "$svc" -n 40 --no-pager 2>&1 | tail -40
  fi
  [ -x "$PREFIX/bin/miohh" ] && { warn "---- env-check ----"; MIOHH_ROOT="$PREFIX" "$PREFIX/bin/miohh" env-check 2>&1 | tail -20 || true; }
  return 1
}

# ---------------------------------------------------------------------------
# 安装 / 部署
# ---------------------------------------------------------------------------
cmd_install() {
  require_root install
  local args=("$@")
  log "安装 miohh → $PREFIX"
  run bash "$SRC/install.sh" --prefix "$PREFIX" "${args[@]}"
  if systemd_available && [ "$NO_START" = "0" ] && [ "$DRY_RUN" = "0" ]; then
    local svc; svc="$(svc_name)"
    if [ -n "$svc" ]; then
      systemctl daemon-reload
      systemctl enable "$svc" >/dev/null 2>&1 || true
      systemctl restart "$svc" >/dev/null 2>&1 || true
      log "服务已启动：$svc"
    fi
  fi
  ok "安装完成"
}

cmd_deploy() {
  cmd_install "$@"
  [ "$NO_START" = "1" ] && { warn "NO_START=1，跳过健康检查"; return 0; }
  [ "$DRY_RUN" = "1" ] && return 0
  health_wait || true
  cmd_status
}

# ---------------------------------------------------------------------------
# 升级 / 拉取 / 构建
# ---------------------------------------------------------------------------
cmd_update() {
  require_root update
  ensure_layout
  local from=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      --from=*) from="${1#--from=}"; shift ;;
      *) fail "update 未知参数: $1" ;;
    esac
  done
  [ -n "$from" ] || fail "用法：deploy.sh update --from <发布包.tar.gz|目录>"
  if [[ "$from" =~ ^https?:// ]]; then
    local tmp="/tmp/miohh-update-$(date +%s).tar.gz"
    log "下载发布包：$from"
    have curl || fail "缺少 curl"
    run curl -fL --retry 2 --max-time 900 -o "$tmp" "$from" || fail "下载失败"
    from="$tmp"
  fi
  [ -e "$from" ] || fail "升级源不存在：$from"
  log "升级 miohh（会先做 pre-update 备份）"
  run bash "$PREFIX/scripts/update.sh" --from "$from"
  if [ "$DRY_RUN" = "0" ]; then
    local svc; svc="$(svc_name)"
    [ -n "$svc" ] && { systemctl restart "$svc" >/dev/null 2>&1 || true; }
    health_wait || warn "升级后健康检查未通过，可用：deploy.sh update --rollback（或 scripts/update.sh --rollback）"
  fi
  ok "升级完成"
}

cmd_pull() {
  require_root pull
  local build=0 install_after=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --build) build=1; shift ;;
      --install) install_after=1; shift ;;
      *) fail "pull 未知参数: $1" ;;
    esac
  done
  [ -d "$SRC/.git" ] || fail "源码目录不是 git 仓库：$SRC（设置 SRC=...）"
  log "git pull：$REPO ${BRANCH:+$BRANCH} @ $SRC"
  run git -C "$SRC" fetch --prune "$REPO" || fail "git fetch 失败"
  local branch="${BRANCH:-$(git -C "$SRC" rev-parse --abbrev-ref HEAD)}"
  run git -C "$SRC" pull --ff-only "$REPO" "$branch" || fail "git pull 失败（有本地改动请先处理）"
  if [ "$build" = "1" ]; then cmd_build --no-install; fi
  log "同步安装到 $PREFIX"
  cmd_install --skip-deps --skip-qq
  if [ "$install_after" = "1" ] && [ "$build" = "1" ]; then
    local latest; latest="$(ls -t "$SRC"/dist/miohh-*.tar.gz 2>/dev/null | head -1 || true)"
    [ -n "$latest" ] && cmd_update --from "$latest"
  fi
  if [ "$DRY_RUN" = "0" ] && [ "$NO_START" = "0" ]; then
    local svc; svc="$(svc_name)"
    [ -n "$svc" ] && systemctl restart "$svc" >/dev/null 2>&1 || true
    health_wait || true
  fi
  ok "拉取并同步完成"
}

cmd_build() {
  local install_after=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --install) install_after=1; shift ;;
      --no-install) install_after=0; shift ;;
      *) fail "build 未知参数: $1" ;;
    esac
  done
  log "构建发布包：$SRC/tools/make_package.sh"
  run bash "$SRC/tools/make_package.sh" || fail "构建失败"
  local latest; latest="$(ls -t "$SRC"/dist/miohh-*.tar.gz 2>/dev/null | head -1 || true)"
  [ -n "$latest" ] && ok "产物：$latest"
  if [ "$install_after" = "1" ] && [ -n "$latest" ]; then
    cmd_update --from "$latest"
  fi
}

# ---------------------------------------------------------------------------
# 服务控制
# ---------------------------------------------------------------------------
cmd_start()   { local svc; svc="$(svc_name)"; if [ -n "$svc" ]; then run systemctl start "$svc"; else ensure_layout; run "$PREFIX/bin/miohh" start; fi; }
cmd_stop()    { local svc; svc="$(svc_name)"; if [ -n "$svc" ]; then run systemctl stop "$svc"; else ensure_layout; run "$PREFIX/bin/miohh" stop; fi; }
cmd_restart() { local svc; svc="$(svc_name)"; if [ -n "$svc" ]; then run systemctl restart "$svc"; else ensure_layout; run "$PREFIX/bin/miohh" restart; fi; }
cmd_status() {
  local svc; svc="$(svc_name)"
  echo "---- miohh 状态 ----"
  echo "PREFIX: $PREFIX"
  echo "VERSION: $(cat "$PREFIX/VERSION" 2>/dev/null || echo '?')"
  if [ -n "$svc" ]; then
    echo "SERVICE: $svc ($(systemctl is-active "$svc" 2>/dev/null || echo unknown))"
    systemctl show -p NRestarts -p ActiveEnterTimestamp "$svc" 2>/dev/null | sed 's/^/  /'
  else
    echo "SERVICE: 未安装 systemd 单元（开发模式）"
  fi
  [ -x "$PREFIX/bin/miohh" ] && "$PREFIX/bin/miohh" healthcheck --json 2>/dev/null | sed 's/^/HEALTH: /'
  local qqver; qqver="$(grep -m1 '"version"' /opt/QQ/resources/app/package.json 2>/dev/null | sed -E 's/.*"version"[^"]*"([^"]+)".*/\1/' || true)"
  echo "QQ: ${qqver:-未安装}（期望 $EXPECTED_QQ_VERSION）"
  echo "端口:"
  ss -lnt 2>/dev/null | awk 'NR>1{print "  "$4}' | grep -E ':(3000|3001|5099|6080)$' || echo "  （无服务端口监听）"
}

cmd_logs() {
  local follow=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--follow) follow=1; shift ;;
      *) break ;;
    esac
  done
  local svc; svc="$(svc_name)"
  if [ -n "$svc" ]; then
    if [ "$follow" = "1" ]; then journalctl -u "$svc" -f -n 200; else journalctl -u "$svc" -n 300 --no-pager; fi
  else
    ensure_layout
    if [ "$follow" = "1" ]; then "$PREFIX/bin/miohh" logs --follow; else "$PREFIX/bin/miohh" logs; fi
  fi
}

# ---------------------------------------------------------------------------
# 健康 / 诊断
# ---------------------------------------------------------------------------
cmd_health() {
  ensure_layout
  log "健康检查"
  "$PREFIX/bin/miohh" healthcheck "$@"
}

cmd_doctor() {
  local fails=0
  echo "================ miohh doctor ================"
  echo "时间: $(date -Is)"
  echo "主机: $(uname -srm) / $(grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
  echo "PREFIX: $PREFIX / 版本: $(cat "$PREFIX/VERSION" 2>/dev/null || echo '?')"
  echo
  echo "---- 环境门禁 ----"
  if [ -x "$PREFIX/bin/miohh" ]; then
    MIOHH_ROOT="$PREFIX" "$PREFIX/bin/miohh" env-check || warn "env-check 未通过（生产需标准发行版内核）"
  else
    warn "未安装 miohh"; fails=$((fails+1))
  fi
  echo
  echo "---- QQ 版本/热更新 ----"
  local qqver; qqver="$(grep -m1 '"version"' /opt/QQ/resources/app/package.json 2>/dev/null | sed -E 's/.*"version"[^"]*"([^"]+)".*/\1/' || true)"
  if [ "${qqver:-}" = "$EXPECTED_QQ_VERSION" ]; then ok "QQ 版本: $qqver"; else warn "QQ 版本异常: ${qqver:-未安装}（期望 $EXPECTED_QQ_VERSION）"; fi
  local rundir; rundir="$(python3 - "$PREFIX/profiles/auto.json" <<'PY' 2>/dev/null || true
import json,sys
try:
    d=json.load(open(sys.argv[1])); print(d.get("user") or d.get("run_user") or "")
except Exception: pass
PY
)"
  if [ -n "$rundir" ]; then
    local home; home="$(getent passwd "$rundir" | cut -d: -f6)"
    local vd="$home/.config/QQ/versions"
    if [ -d "$vd" ]; then
      local n; n="$(find "$vd" -mindepth 1 -maxdepth 1 \( -type d -name '[0-9]*' -o -type f -name '*.zip*' \) 2>/dev/null | wc -l)"
      [ "$n" -eq 0 ] && ok "热更新包: 无" || warn "热更新包: $n 个（qq-guard 会清理）"
    fi
  fi
  echo
  echo "---- 服务 ----"
  local svc; svc="$(svc_name)"
  if [ -n "$svc" ]; then
    echo "systemd: $svc ($(systemctl is-active "$svc" 2>/dev/null || echo unknown))"
    systemctl show -p NRestarts -p ActiveEnterTimestamp -p MemoryCurrent "$svc" 2>/dev/null | sed 's/^/  /'
    systemd-analyze verify /etc/systemd/system/"$svc" >/dev/null 2>&1 && ok "unit 语法正常" || warn "unit 校验有告警"
  else
    warn "未安装 systemd 单元"
  fi
  [ -x "$PREFIX/bin/miohh" ] && { echo; echo "---- healthcheck ----"; "$PREFIX/bin/miohh" healthcheck || true; }
  echo
  echo "---- 端口 ----"
  ss -lnt 2>/dev/null | grep -E ':(3000|3001|5099|6080)\b' || echo "  无监听"
  echo
  echo "---- 资源 ----"
  df -h "$PREFIX" 2>/dev/null | tail -1
  free -m 2>/dev/null | head -2
  echo
  echo "---- 组件 ----"
  for c in node python3 import Xvfb curl tar; do have "$c" && echo "  OK  $c" || { echo "  MISS $c"; }; done
  echo
  echo "---- 日志尾 ----"
  local svc2; svc2="$(svc_name)"
  if [ -n "$svc2" ]; then journalctl -u "$svc2" -n 10 --no-pager 2>/dev/null | tail -10; else tail -n 10 "$PREFIX/logs/miohh.log" 2>/dev/null || true; fi
  echo "=============================================="
  [ "$fails" -eq 0 ] && ok "doctor 完成（无致命项）" || warn "doctor 完成（有致命项 $fails）"
}

# ---------------------------------------------------------------------------
# 备份 / 热更新锁 / 卸载
# ---------------------------------------------------------------------------
cmd_backup()  { ensure_layout; "$PREFIX/bin/miohh" backup "$@"; }
cmd_restore() { ensure_layout; require_root restore; "$PREFIX/bin/miohh" restore "$@"; }
cmd_qqguard() { ensure_layout; require_root qq-guard; "$PREFIX/bin/miohh" qq-guard "$@"; }

cmd_uninstall() {
  require_root uninstall
  local purge=0
  [ "${1:-}" = "--purge" ] && purge=1
  if [ "$ASSUME_YES" != "1" ] && [ -t 0 ]; then
    read -r -p "确认卸载 miohh${purge:+（--purge 将删除数据）}? [y/N] " a
    [ "$a" = "y" ] || [ "$a" = "Y" ] || { warn "已取消"; exit 0; }
  fi
  run bash "$PREFIX/scripts/uninstall.sh" ${purge:+--purge}
  ok "卸载完成"
}

cmd_version() { echo "miohh $(cat "$SRC/VERSION" 2>/dev/null || cat "$PREFIX/VERSION" 2>/dev/null || echo '?')"; }

# ---------------------------------------------------------------------------
# 交互菜单
# ---------------------------------------------------------------------------
menu() {
  while true; do
    echo
    echo "============== miohh 运维菜单 =============="
    echo " 1) 部署（安装+启动+健康检查）"
    echo " 2) 启动       3) 停止       4) 重启"
    echo " 5) 状态       6) 日志       7) 健康检查"
    echo " 8) 升级（--from 包/URL）"
    echo " 9) 拉取（git pull 后同步安装）"
    echo "10) 构建发布包   11) 诊断 doctor"
    echo "12) 备份      13) 恢复      14) QQ 热更新锁"
    echo "15) 卸载      16) 版本      0) 退出"
    echo "============================================"
    read -r -p "请选择: " choice
    case "$choice" in
      1) cmd_deploy ;;
      2) cmd_start ;;
      3) cmd_stop ;;
      4) cmd_restart ;;
      5) cmd_status ;;
      6) cmd_logs ;;
      7) cmd_health ;;
      8) read -r -p "发布包路径/URL: " src; cmd_update --from "$src" ;;
      9) cmd_pull ;;
      10) cmd_build ;;
      11) cmd_doctor ;;
      12) cmd_backup ;;
      13) read -r -p "备份文件路径: " bf; cmd_restore --from "$bf" ;;
      14) cmd_qqguard ;;
      15) read -r -p "purge? [y/N] " p; if [ "$p" = "y" ]; then cmd_uninstall --purge; else cmd_uninstall; fi ;;
      16) cmd_version ;;
      0|q|exit) exit 0 ;;
      *) warn "无效选项: $choice" ;;
    esac
  done
}

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

ACTION="${1:-menu}"
[ $# -gt 0 ] && shift || true
case "$ACTION" in
  menu) menu ;;
  install) cmd_install "$@" ;;
  deploy) cmd_deploy "$@" ;;
  update) cmd_update "$@" ;;
  pull) cmd_pull "$@" ;;
  build) cmd_build "$@" ;;
  start) cmd_start "$@" ;;
  stop) cmd_stop "$@" ;;
  restart) cmd_restart "$@" ;;
  status) cmd_status "$@" ;;
  logs) cmd_logs "$@" ;;
  health|healthcheck) cmd_health "$@" ;;
  doctor|diag) cmd_doctor "$@" ;;
  backup) cmd_backup "$@" ;;
  restore) cmd_restore "$@" ;;
  qq-guard|qqguard) cmd_qqguard "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  version|--version|-v) cmd_version ;;
  help|-h|--help) usage ;;
  *) fail "未知命令: $ACTION（deploy.sh help 查看用法）" ;;
esac
