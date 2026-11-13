#!/usr/bin/env bash
# miohh 品牌门禁：扫描安装目录/进程/线程/管道/环境变量/日志/接入面中的旧名残留
# 旧名模式不随包分发：通过 MIOHH_FORBIDDEN_PATTERNS（逗号分隔）或
# MIOHH_FORBIDDEN_PATTERNS_FILE（每行一个）在构建/CI 时注入。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

MODE="normal"
[ "${1:-}" = "--strict" ] && MODE="strict"
PATTERNS=()
if [ -n "${MIOHH_FORBIDDEN_PATTERNS:-}" ]; then
  IFS=',' read -r -a PATTERNS <<< "$MIOHH_FORBIDDEN_PATTERNS"
fi
if [ -n "${MIOHH_FORBIDDEN_PATTERNS_FILE:-}" ]; then
  [ -f "$MIOHH_FORBIDDEN_PATTERNS_FILE" ] || die "patterns file 不存在: $MIOHH_FORBIDDEN_PATTERNS_FILE" 2
  while IFS= read -r line; do
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    PATTERNS+=("$line")
  done < "$MIOHH_FORBIDDEN_PATTERNS_FILE"
fi
if [ "${#PATTERNS[@]}" -eq 0 ]; then
  echo "[miohh rename-check] 未提供旧名模式（内部构建/CI 注入），无法扫描" >&2
  exit 7
fi

hits=0
hit() { echo "  HIT  $1 :: $2"; hits=$((hits+1)); }

echo "[miohh rename-check] 模式数=${#PATTERNS[@]} 模式=$MODE"
echo "== 安装目录 =="
for pat in "${PATTERNS[@]}"; do
  while IFS= read -r f; do
    [ -n "$f" ] && hit "file" "$f"
  done < <(grep -rIl --exclude-dir=data --exclude-dir=logs --exclude-dir=profiles -e "$pat" "$MIOHH_ROOT" 2>/dev/null | head -20)
done

echo "== 运行时进程/线程/环境 =="
SELF_PID=$$
for pid in $(pgrep -f 'miohh|/opt/QQ/qq' 2>/dev/null || true); do
  [ "$pid" = "$SELF_PID" ] && continue
  [ "$pid" = "$PPID" ] && continue
  for pat in "${PATTERNS[@]}"; do
    if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -v "MIOHH_FORBIDDEN_PATTERNS" | grep -qi -- "$pat" 2>/dev/null; then hit "cmdline" "pid=$pid"; fi
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    if [ -n "$comm" ] && echo "$comm" | grep -qi -- "$pat"; then hit "comm" "pid=$pid comm=$comm"; fi
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -v "MIOHH_FORBIDDEN_PATTERNS" | grep -qi -- "$pat" && hit "environ" "pid=$pid"
    if [ -d "/proc/$pid/task" ]; then
      for t in /proc/$pid/task/*/comm; do
        tn="$(cat "$t" 2>/dev/null || true)"
        echo "$tn" | grep -qi -- "$pat" && hit "thread" "pid=$pid thread=$tn"
      done
    fi
  done
done

echo "== 管道/socket 名称 =="
for pat in "${PATTERNS[@]}"; do
  if command -v ss >/dev/null 2>&1 && ss -xlpn 2>/dev/null | grep -qi -- "$pat"; then hit "socket" "$pat"; fi
  find /tmp /run -maxdepth 3 -iname "*$pat*" 2>/dev/null | head -5 | while read -r p; do [ -n "$p" ] && hit "path" "$p"; done
done

echo "== 日志 =="
for pat in "${PATTERNS[@]}"; do
  grep -rIl -e "$pat" "$MIOHH_ROOT/logs" 2>/dev/null | head -5 | while read -r l; do [ -n "$l" ] && hit "log" "$l"; done
done

echo "== 接入面（OneBot app_name） =="
RESP="$(curl -s -m 3 "http://127.0.0.1:3000/get_version_info" 2>/dev/null || true)"
if [ -n "$RESP" ]; then
  for pat in "${PATTERNS[@]}"; do
    echo "$RESP" | grep -qi -- "$pat" && hit "onebot" "get_version_info 命中模式"
  done
fi

if [ "$hits" -eq 0 ]; then
  echo "[miohh rename-check] RESULT: PASS（0 命中）"
  exit 0
else
  echo "[miohh rename-check] RESULT: FAIL（命中 $hits 处）"
  exit 7
fi
