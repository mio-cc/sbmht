#!/usr/bin/env bash
# miohh 升级/回滚（从新版本 tar.gz 或目录）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
FROM=""; ROLLBACK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --rollback) ROLLBACK=1; shift ;;
    -h|--help) echo "usage: miohh update --from NEW.tar.gz | --rollback"; exit 0 ;;
    *) die "未知参数: $1" 2 ;;
  esac
done

restore_flat() {
  local archive="$1"
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  tar -xzf "$archive" -C "$tmp"
  bash "$MIOHH_ROOT/bin/miohh" stop 2>/dev/null || true
  for d in bin runtime envsim scripts tools contracts systemd config profiles; do
    [ -d "$tmp/$d" ] || continue
    rm -rf "${MIOHH_ROOT:?}/$d"
    cp -a "$tmp/$d" "$MIOHH_ROOT/"
  done
  cp -f "$tmp/VERSION" "$MIOHH_ROOT/VERSION" 2>/dev/null || true
  cp -f "$tmp/NOTICE" "$MIOHH_ROOT/NOTICE" 2>/dev/null || true
  bash "$MIOHH_ROOT/bin/miohh" start 2>/dev/null || true
}

if [ "$ROLLBACK" = 1 ]; then
  LAST="$(ls -1t "$MIOHH_ROOT"/backups/pre-update-*.tar.gz 2>/dev/null | head -1 || true)"
  [ -n "$LAST" ] || die "没有可回滚的升级备份" 8
  log "回滚自: $LAST"
  restore_flat "$LAST"
  log "回滚完成"
  exit 0
fi
[ -n "$FROM" ] || die "需要 --from 新版本包" 2
[ -f "$FROM" ] || die "文件不存在: $FROM" 4
mkdir -p "$MIOHH_ROOT/backups"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
tar -xzf "$FROM" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 2 -type d -name bin 2>/dev/null | head -1)"
[ -n "$SRC" ] || die "升级包结构无效（缺 bin/）" 8
SRC="$(dirname "$SRC")"
log "升级：当前 $(cat "$MIOHH_ROOT/VERSION" 2>/dev/null) → 新版本"
PRE="$MIOHH_ROOT/backups/pre-update-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$PRE" -C "$MIOHH_ROOT" bin runtime envsim scripts tools contracts systemd config profiles 2>/dev/null || true
bash "$MIOHH_ROOT/bin/miohh" stop 2>/dev/null || true
for d in bin runtime envsim scripts tools contracts systemd; do
  [ -d "$SRC/$d" ] || continue
  rm -rf "${MIOHH_ROOT:?}/$d"
  cp -a "$SRC/$d" "$MIOHH_ROOT/"
done
cp -f "$SRC/VERSION" "$MIOHH_ROOT/VERSION" 2>/dev/null || true
cp -f "$SRC/NOTICE" "$MIOHH_ROOT/NOTICE" 2>/dev/null || true
bash "$MIOHH_ROOT/bin/miohh" start 2>/dev/null || true
log "升级完成（回滚: miohh update --rollback）"
echo "$PRE"
