#!/usr/bin/env bash
# 自动生成 miohh 设备档案（环境仿真用）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
need_root
ACCOUNT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    -h|--help) echo "usage: miohh profile-gen [--account NAME]"; exit 0 ;;
    *) die "未知参数: $1" 2 ;;
  esac
done
OUT_DIR="$MIOHH_ROOT/profiles"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/auto.json"
[ -n "$ACCOUNT" ] && OUT="$OUT_DIR/$ACCOUNT.json"
python3 "$MIOHH_ROOT/envsim/autogen_profile.py" --out "$OUT"
log "档案已生成: $OUT"
