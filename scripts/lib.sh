#!/usr/bin/env bash
# miohh 公共函数
set -uo pipefail
MIOHH_ROOT="${MIOHH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export MIOHH_ROOT
LOG_DIR="${MIOHH_LOG_DIR:-$MIOHH_ROOT/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true

log()  { echo "[miohh $(date '+%F %T')] $*"; }
warn() { echo "[miohh WARN] $*" >&2; }
die()  { echo "[miohh FATAL] $*" >&2; exit "${2:-1}"; }
need_root() { [ "$(id -u)" = "0" ] || die "需要 root（安装/沙箱/注入）" 2; }

json_escape() { python3 -c 'import json,sys;print(json.dumps(sys.argv[1],ensure_ascii=False))' "$1" 2>/dev/null || printf '"%s"' "$1"; }

kernel_ok() {
  case "$1" in
    *generic*|*-amd64|*-arm64|*-cloud-amd64|*-aws) return 0 ;;
    *) return 1 ;;
  esac
}
