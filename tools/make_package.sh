#!/usr/bin/env bash
# miohh 发布打包：生成 dist/miohh-<ver>-linux-x64.tar.gz + manifest.sha256
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${MIOHH_DIST:-$ROOT/dist}"
VER="$(head -1 "$ROOT/VERSION" 2>/dev/null | sed 's/^miohh[[:space:]]*//' | tr -d '[:space:]')"
VER="${VER:-0.0.0}"
NAME="miohh-${VER}-linux-x64"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT_DIR" "$STAGE/$NAME"

log() { echo "[miohh package] $*"; }
log "打包 $NAME"
ITEMS=""
for d in bin runtime envsim scripts tools contracts systemd config assets; do
  [ -e "$ROOT/$d" ] && ITEMS="$ITEMS $d"
done
for f in VERSION NOTICE README.md install.sh deploy.sh; do
  [ -e "$ROOT/$f" ] && ITEMS="$ITEMS $f"
done
tar -cf - -C "$ROOT" $ITEMS | tar -xf - -C "$STAGE/$NAME" || { log "staging tar 失败（$ITEMS）"; exit 6; }
# 排除研发自测脚本
find "$STAGE/$NAME" -type f \( -name 'box_*.sh' -o -name 'm3fix*.sh' -o -name '*.pyc' \) -delete 2>/dev/null || true
chmod +x "$STAGE/$NAME/bin/miohh" "$STAGE/$NAME/scripts/"*.sh 2>/dev/null || true
chmod +x "$STAGE/$NAME/runtime/bundled/node" "$STAGE/$NAME/runtime/bundled/launcher.sh" 2>/dev/null || true
rm -rf "$STAGE/$NAME"/tools/__pycache__ "$STAGE/$NAME"/runtime/__pycache__ "$STAGE/$NAME"/envsim/__pycache__ 2>/dev/null || true
# manifest
( cd "$STAGE/$NAME" && find . -type f ! -name manifest.sha256 -print0 | sort -z | xargs -0 sha256sum > manifest.sha256 )
# 校验清单自检
( cd "$STAGE/$NAME" && sha256sum -c manifest.sha256 >/dev/null ) || { log "manifest 校验失败"; exit 8; }
# 可选：发布门禁（需要内部旧名模式）
if [ -n "${MIOHH_FORBIDDEN_PATTERNS_FILE:-}" ] || [ -n "${MIOHH_FORBIDDEN_PATTERNS:-}" ]; then
  log "运行发布门禁（ci_check release）"
  MIOHH_ROOT="$STAGE/$NAME" MIOHH_RELEASE=1 bash "$STAGE/$NAME/tools/ci_check.sh" >/tmp/miohh-release-ci.log 2>&1 || { log "发布门禁失败，详见 /tmp/miohh-release-ci.log"; tail -20 /tmp/miohh-release-ci.log; exit 7; }
  log "发布门禁通过"
fi
OUT="$OUT_DIR/$NAME.tar.gz"
tar -czf "$OUT" -C "$STAGE" "$NAME"
SHA="$(sha256sum "$OUT" | awk '{print $1}')"
echo "$SHA  $(basename "$OUT")" > "$OUT.sha256"
log "完成: $OUT"
log "sha256: $SHA"
log "文件数: $(wc -l < "$STAGE/$NAME/manifest.sha256")"
echo "$OUT"
