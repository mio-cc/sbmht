#!/usr/bin/env bash
# envsim 自检：在沙箱内运行，校验 QQ 会读到的环境是否等于 DeviceProfile
# 用法: sudo bash envsim.sh profile.json bash check.sh
set -uo pipefail
P="${ENVSIM_PROFILE:-}"
if [ -z "$P" ] || [ ! -f "$P" ]; then
  echo "[check] SKIP: 不在 envsim 沙箱内（ENVSIM_PROFILE 未设置）"
  exit 0
fi
eval "$(python3 - "$P" <<'PY'
import json, sys, shlex
p = json.load(open(sys.argv[1], encoding="utf-8"))
c = p["cpu"]
print("E_HOST=%s" % shlex.quote(p["hostname"]))
print("E_MODEL=%s" % shlex.quote(c["model_name"]))
print("E_PROC=%s" % shlex.quote(str(c.get("processors", 4))))
print("E_MID=%s" % shlex.quote(p["machine_id"].strip()))
print("E_MEMKB=%s" % shlex.quote(str(p.get("mem_total_kb", 0))))
print("E_FAKEMEM=%s" % shlex.quote("1" if p.get("fake_meminfo") else "0"))
PY
)"
fail=0
ok()  { printf "  PASS  %s\n" "$*"; }
bad() { printf "  FAIL  %s\n" "$*"; fail=$((fail+1)); }

H=$(hostname 2>/dev/null || echo "?")
UN=$(uname -n 2>/dev/null || echo "?")
MODEL=$(grep -m1 -i 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: *//')
NPROC_FILE=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0)
NPROC_SYS=$(nproc 2>/dev/null || echo 0)
MID=$(cat /etc/machine-id 2>/dev/null | tr -d '[:space:]')

echo "[check] 沙箱内环境自检（profile: $(basename "$P")）"
[ "$H" = "$E_HOST" ] && ok "hostname = $H" || bad "hostname: 实际=$H 期望=$E_HOST"
[ "$UN" = "$E_HOST" ] && ok "uname -n = $UN" || bad "uname -n: 实际=$UN 期望=$E_HOST"
[ "$MODEL" = "$E_MODEL" ] && ok "cpuinfo model name = $MODEL" || bad "cpuinfo model name: 实际=$MODEL 期望=$E_MODEL"
[ "$NPROC_FILE" = "$E_PROC" ] && ok "cpuinfo processor 数 = $NPROC_FILE" || bad "cpuinfo processor 数: 实际=$NPROC_FILE 期望=$E_PROC"
if [ "$NPROC_SYS" = "$E_PROC" ]; then ok "nproc 系统调用 = $NPROC_SYS（与档案一致）"; else bad "nproc 系统调用: 实际=$NPROC_SYS 期望=$E_PROC（VPS 必须是真实 vCPU 数）"; fi
if grep -qi 'hypervisor' /proc/cpuinfo 2>/dev/null; then bad "cpuinfo 含 hypervisor flag（虚拟化暴露）"; else ok "cpuinfo 无 hypervisor flag"; fi
[ "$MID" = "$E_MID" ] && ok "machine-id = $MID" || bad "machine-id: 实际=$MID 期望=$E_MID"
if [ "$E_FAKEMEM" = "1" ]; then
  MT=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
  [ "$MT" = "$E_MEMKB" ] && ok "meminfo MemTotal = $MT kB" || bad "meminfo MemTotal: 实际=$MT 期望=$E_MEMKB"
fi
KR=$(uname -r 2>/dev/null)
case "$KR" in
  *generic*|*-amd64|*-arm64) ok "kernel release = $KR（标准发行版风格）" ;;
  *) echo "  WARN  kernel release = $KR（非标准风格；需换标准内核 VPS 或评估 uname 一致性）" ;;
esac
echo
if [ "$fail" -eq 0 ]; then echo "[check] RESULT: PASS"; exit 0; else echo "[check] RESULT: FAIL ($fail)"; exit 1; fi
