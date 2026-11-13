#!/usr/bin/env bash
# miohh QQ 热更新屏蔽（安全版）：
# 保留 versions 目录 user 可写（否则 launcher 报 EACCES），只清理更新包并锁定 config.curVersion；
# 服务启动前 + systemd timer 定期执行，确保重启前不会应用热更新。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

EXPECTED="${MIOHH_QQ_VERSION:-3.2.32-52194}"
QQ_JSON=/opt/QQ/resources/app/package.json

if [ -f "$QQ_JSON" ]; then
  CUR="$(grep -m1 '"version"' "$QQ_JSON" | sed -E 's/.*"version"[^"]*"([^"]+)".*/\1/')"
  if [ "$CUR" = "$EXPECTED" ]; then log "QQ 版本正常: $CUR"; else warn "QQ 版本漂移: $CUR（期望 $EXPECTED）"; fi
else
  warn "未找到 $QQ_JSON"
fi

RUNUSER=""
if [ -f "$MIOHH_ROOT/profiles/auto.json" ]; then
  RUNUSER="$(python3 - "$MIOHH_ROOT/profiles/auto.json" <<'PY' 2>/dev/null || true
import json,sys
try:
    d=json.load(open(sys.argv[1])); print(d.get("user") or d.get("run_user") or "")
except Exception: pass
PY
)"
fi
HOME_DIR=""
[ -n "$RUNUSER" ] && HOME_DIR="$(getent passwd "$RUNUSER" | cut -d: -f6)"
[ -n "$HOME_DIR" ] || HOME_DIR="${HOME:-/root}"
CFG="$HOME_DIR/.config/QQ"
VD="$CFG/versions"

if [ -d "$CFG" ]; then
  find "$CFG" -maxdepth 1 -type d -name 'versions.disabled.*' -exec rm -rf {} + 2>/dev/null || true
  mkdir -p "$VD" 2>/dev/null || true
  chown "${RUNUSER:-root}:" "$CFG" 2>/dev/null || true
  chown -R "${RUNUSER:-root}:" "$VD" 2>/dev/null || true
  chmod 775 "$VD" 2>/dev/null || true
  # 仅删除更新包（版本目录 + zip），保留 config.json/setting.json
  find "$VD" -mindepth 1 -maxdepth 1 \( -type d -name '[0-9]*' -o -type f -name '*.zip*' \) -exec rm -rf {} + 2>/dev/null || true
  # 写回合法 launcher 配置并锁定 curVersion
  python3 - "$VD/config.json" "$EXPECTED" <<'PY' 2>/dev/null || true
import json, sys, os
p, expected = sys.argv[1], sys.argv[2]
cfg = {
    "baseVersion": expected,
    "curVersion": expected,
    "prevVersion": "",
    "onErrorVersions": [],
    "buildId": expected.split("-")[-1] if "-" in expected else "",
    "unzipRetryCount": 0,
}
try:
    if os.path.exists(p):
        cur = json.load(open(p))
        if cur.get("curVersion") == expected and cur.get("baseVersion") == expected:
            raise SystemExit
except SystemExit:
    raise
except Exception:
    pass
json.dump(cfg, open(p, "w"), indent=2)
PY
  [ -n "${RUNUSER:-}" ] && chown -R "$RUNUSER:" "$VD" 2>/dev/null || true
  ZIPN="$(find "$VD" -mindepth 1 -maxdepth 1 \( -type d -name '[0-9]*' -o -type f -name '*.zip*' \) 2>/dev/null | wc -l)"
  if [ "$ZIPN" -eq 0 ]; then log "热更新包已清理（versions 目录仅保留 config）"; else warn "仍有 $ZIPN 个更新包未清理"; fi
else
  warn "QQ 配置目录不存在，跳过: $CFG"
fi

if command -v apt-mark >/dev/null 2>&1; then
  apt-mark hold linuxqq >/dev/null 2>&1 && log "linuxqq 已 hold" || true
fi
