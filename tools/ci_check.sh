#!/usr/bin/env bash
# miohh CI/发布门禁：语法、测试脚本排除、契约、CLI 冒烟、品牌旧名扫描（模式由内部注入）
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MIOHH_ROOT="${MIOHH_ROOT:-$ROOT}"
fails=0
sec() { echo "== $* =="; }
bad() { echo "  FAIL  $*"; fails=$((fails+1)); }
ok()  { echo "  PASS  $*"; }

sec "shell 语法"
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null && ok "$(basename "$f")" || bad "语法错误: $f"
done < <(find "$ROOT" -type f -name '*.sh' -not -path '*/node_modules/*' | sort)

sec "python 语法"
while IFS= read -r f; do
  python3 -m py_compile "$f" 2>/dev/null && ok "$(basename "$f")" || bad "py 语法错误: $f"
done < <(find "$ROOT" -type f -name '*.py' -not -path '*/node_modules/*' | sort)

sec "研发自测脚本不应随包"
DEV_HITS="$(find "$ROOT" -type f \( -name 'box_*.sh' -o -name 'm3fix*.sh' \) | head -20)"
if [ -n "$DEV_HITS" ]; then
  if [ "${MIOHH_RELEASE:-0}" = "1" ]; then bad "发布物含研发自测脚本: $DEV_HITS"; else echo "  WARN  源码目录含研发自测脚本（发布打包会自动排除）"; fi
else ok "无研发自测脚本"; fi

sec "契约文件"
if ls "$ROOT"/contracts/qq-*.json >/dev/null 2>&1; then
  for c in "$ROOT"/contracts/qq-*.json; do
    python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$c" 2>/dev/null && ok "$(basename "$c")" || bad "契约 JSON 非法: $c"
  done
else
  bad "缺少 contracts/qq-*.json"
fi

sec "CLI 冒烟"
bash "$ROOT/bin/miohh" version >/dev/null 2>&1 && ok "miohh version" || bad "miohh version 失败"
bash "$ROOT/bin/miohh" help >/dev/null 2>&1 && ok "miohh help" || bad "miohh help 失败"
SKIP_OUT="$(MIOHH_ENVCHECK_SKIP=1 bash "$ROOT/bin/miohh" env-check --json 2>/dev/null)"
echo "$SKIP_OUT" | grep -q '"skip":true' && ok "env-check --json" || bad "env-check --json 异常: $SKIP_OUT"

sec "品牌旧名扫描"
PATTERNS=()
if [ -n "${MIOHH_FORBIDDEN_PATTERNS:-}" ]; then IFS=',' read -r -a PATTERNS <<< "$MIOHH_FORBIDDEN_PATTERNS"; fi
if [ -n "${MIOHH_FORBIDDEN_PATTERNS_FILE:-}" ] && [ -f "$MIOHH_FORBIDDEN_PATTERNS_FILE" ]; then
  while IFS= read -r l; do
    l="$(echo "$l" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$l" ] && continue
    case "$l" in \#*) continue ;; esac
    PATTERNS+=("$l")
  done < "$MIOHH_FORBIDDEN_PATTERNS_FILE"
fi
if [ "${#PATTERNS[@]}" -eq 0 ]; then
  echo "  WARN  未提供旧名模式（内部构建注入），跳过品牌扫描"
else
  hits=0
  for pat in "${PATTERNS[@]}"; do
    while IFS= read -r f; do
      [ -n "$f" ] && { bad "品牌命中: $f :: $pat"; hits=$((hits+1)); }
    done < <(grep -rIl -e "$pat" "$ROOT" \
      --exclude-dir=data --exclude-dir=logs --exclude-dir=profiles \
      --exclude-dir=backups --exclude-dir=dist --exclude='*.tar.gz' --exclude='*.sha256' 2>/dev/null | head -20)
    # 二进制扫描
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if grep -aqi -- "$pat" "$f" 2>/dev/null; then bad "二进制品牌命中: $f :: $pat"; hits=$((hits+1)); fi
    done < <(find "$ROOT" -type f \( -name '*.node' -o -name '*.so' -o -name '*.bin' -o -name 'node' \) -not -path '*/dist/*' 2>/dev/null)
  done
  [ "$hits" -eq 0 ] && ok "品牌扫描 0 命中"
fi

sec "结果"
if [ "$fails" -eq 0 ]; then echo "CI: PASS"; exit 0; else echo "CI: FAIL ($fails)"; exit 7; fi
