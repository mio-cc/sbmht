#!/usr/bin/env bash
# miohh 自检：版本/环境/沙箱/关键目录
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
fail=0
echo "[miohh selftest]"
echo "  version: $(cat "$MIOHH_ROOT/VERSION" 2>/dev/null || echo unknown)"
for d in bin runtime envsim scripts config contracts; do
  [ -d "$MIOHH_ROOT/$d" ] && echo "  OK  $d/" || { echo "  FAIL  $d/ 缺失"; fail=$((fail+1)); }
done
command -v python3 >/dev/null && echo "  OK  python3" || { echo "  FAIL python3"; fail=$((fail+1)); }
if [ -x "$MIOHH_ROOT/envsim/envsim.sh" ]; then
  echo "  OK  envsim 可执行"
else
  echo "  WARN envsim 未就绪（M2 集成）"
fi
if [ "$fail" -eq 0 ]; then echo "[miohh selftest] RESULT: PASS"; exit 0; else echo "[miohh selftest] RESULT: FAIL ($fail)"; exit 6; fi
