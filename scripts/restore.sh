#!/usr/bin/env bash
# miohh 恢复（从备份 tar.gz）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    -h|--help) echo "usage: miohh restore --from BACKUP.tar.gz"; exit 0 ;;
    *) die "未知参数: $1" 2 ;;
  esac
done
[ -n "$FROM" ] && [ -f "$FROM" ] || die "需要 --from 备份文件" 2
if [ -f "$FROM.sha256" ]; then
  (cd "$(dirname "$FROM")" && sha256sum -c "$(basename "$FROM").sha256") || die "备份校验失败" 8
fi
systemctl stop miohh 2>/dev/null || bash "$MIOHH_ROOT/bin/miohh" stop 2>/dev/null || true
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
tar -xzf "$FROM" -C "$TMP"
[ -d "$TMP/backup" ] || die "备份结构无效" 8
for d in config profiles run; do
  [ -d "$TMP/backup/$d" ] || continue
  rm -rf "${MIOHH_ROOT:?}/$d"
  cp -a "$TMP/backup/$d" "$MIOHH_ROOT/"
done
[ -d "$TMP/backup/logs" ] && cp -a "$TMP/backup/logs" "$MIOHH_ROOT/" 2>/dev/null || true
chmod -R go-rwx "$MIOHH_ROOT/config" 2>/dev/null || true
log "恢复完成：$FROM"
log "如需恢复服务：miohh start"
