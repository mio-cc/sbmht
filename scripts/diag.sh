#!/usr/bin/env bash
# miohh 诊断包（脱敏）：状态/配置/日志/环境/契约，不含二维码/令牌/消息正文
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
OUT="${MIOHH_ROOT}/diag-$(date +%Y%m%d-%H%M%S).tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/diag"
{
  echo "# miohh diag"; date -Is; echo
  echo "## version"; cat "$MIOHH_ROOT/VERSION" 2>/dev/null
  echo "## system"; uname -a; . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"
  echo "## qq"; grep -m1 version /opt/QQ/resources/app/package.json 2>/dev/null || echo none
  echo "## processes"; ps -eo pid,ppid,rss,etime,args --sort=-rss | grep -Ei 'miohh|qq|envsim|login_manager' | grep -v grep | head -20
  echo "## ports"; ss -lntp 2>/dev/null | head -20
  echo "## disk"; df -h "$MIOHH_ROOT" / 2>/dev/null
} > "$TMP/diag/system.txt" 2>&1 || true
bash "$HERE/status.sh" --json > "$TMP/diag/status.json" 2>/dev/null || true
bash "$HERE/healthcheck.sh" --json > "$TMP/diag/healthcheck.json" 2>/dev/null || true
if [ -f "$MIOHH_ROOT/config/miohh.yaml" ]; then
  sed -E 's/(token|password)[^:]*:[[:space:]]*.*/\1: ***/Ig' "$MIOHH_ROOT/config/miohh.yaml" > "$TMP/diag/miohh.yaml.masked" 2>/dev/null || true
fi
for f in "$MIOHH_ROOT"/profiles/*.json; do
  [ -f "$f" ] || continue
  sed -E 's/("machine_id"[[:space:]]*:[[:space:]]*")[^"]*/\1***/g' "$f" > "$TMP/diag/$(basename "$f").masked" 2>/dev/null || true
done
[ -f "$MIOHH_ROOT/logs/miohh.log" ] && tail -n 300 "$MIOHH_ROOT/logs/miohh.log" | sed -E 's/[A-Za-z0-9_-]{40,}/***/g' > "$TMP/diag/miohh.log.tail" 2>/dev/null || true
cp -f "$MIOHH_ROOT/contracts/qq-*.json" "$TMP/diag/" 2>/dev/null || true
tar -czf "$OUT" -C "$TMP" diag
log "诊断包: $OUT"
echo "$OUT"
