#!/usr/bin/env bash
# miohh 备份（config/profiles/run 状态；可选 --with-logs）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
DEST="${MIOHH_ROOT}/backups"
WITH_LOGS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DEST="$2"; shift 2 ;;
    --with-logs) WITH_LOGS=1; shift ;;
    -h|--help) echo "usage: miohh backup [--dir D] [--with-logs]"; exit 0 ;;
    *) die "未知参数: $1" 2 ;;
  esac
done
mkdir -p "$DEST"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$DEST/miohh-backup-$STAMP.tar.gz"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/backup"
cp -a "$MIOHH_ROOT/config" "$TMP/backup/" 2>/dev/null || true
cp -a "$MIOHH_ROOT/profiles" "$TMP/backup/" 2>/dev/null || true
cp -a "$MIOHH_ROOT/run" "$TMP/backup/" 2>/dev/null || true
[ "$WITH_LOGS" = 1 ] && cp -a "$MIOHH_ROOT/logs" "$TMP/backup/" 2>/dev/null || true
printf 'version=%s\ndate=%s\n' "$(cat "$MIOHH_ROOT/VERSION" 2>/dev/null)" "$(date -Is)" > "$TMP/backup/META"
tar -czf "$OUT" -C "$TMP" backup
chmod 600 "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256" >/dev/null
# 保留最近 7 份
ls -1t "$DEST"/miohh-backup-*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f
log "备份完成: $OUT"
echo "$OUT"
