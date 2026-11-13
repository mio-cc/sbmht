#!/usr/bin/env bash
# envsim：普通 VPS 上的"Linux 桌面环境仿真"启动器（root 运行；建 mount/UTS 命名空间后降权）
# 用法:
#   sudo bash envsim.sh --auto <命令...>          # 部署模式：自动探测本机生成 DeviceProfile
#   sudo bash envsim.sh <profile.json> <命令...>  # 指定档案
# 例:
#   sudo bash envsim.sh --auto bash check.sh
#   sudo bash envsim.sh ../envsim/auto-profile.json bash check.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# -ge 1 ] || { echo "usage: sudo bash envsim.sh [--auto|<profile.json>] <cmd...>"; exit 2; }
if [ "$1" = "--auto" ]; then
  shift
  [ $# -ge 1 ] || { echo "usage: sudo bash envsim.sh --auto <cmd...>"; exit 2; }
  PROFILE="$HERE/auto-profile.json"
  echo "[envsim] --auto：探测本机生成 DeviceProfile..." >&2
  python3 "$HERE/autogen_profile.py" --out "$PROFILE" >&2
else
  PROFILE="$(readlink -f "$1")"; shift
  [ $# -ge 1 ] || { echo "usage: sudo bash envsim.sh <profile.json> <cmd...>"; exit 2; }
fi
[ -f "$PROFILE" ] || { echo "profile not found: $PROFILE"; exit 2; }
[ "$(id -u)" = "0" ] || { echo "need root (unshare/mount)"; exit 2; }

WORK="$(mktemp -d /tmp/envsim.XXXXXX)"
chmod 755 "$WORK"
python3 "$HERE/gen_fakes.py" "$PROFILE" "$WORK" >/dev/null

eval "$(python3 - "$PROFILE" <<'PY'
import json, sys, shlex
p = json.load(open(sys.argv[1], encoding="utf-8"))
print("P_HOSTNAME=%s" % shlex.quote(p["hostname"]))
print("P_USER=%s" % shlex.quote(p.get("user", "user")))
print("P_FAKEMEM=%s" % shlex.quote("1" if p.get("fake_meminfo") else "0"))
print("P_TZ=%s" % shlex.quote(p.get("timezone", "")))
print("P_LOCALE=%s" % shlex.quote(p.get("locale", "zh_CN.UTF-8")))
PY
)"

echo "[envsim] namespace: mount+uts; profile=$PROFILE; hostname=$P_HOSTNAME; tz=$P_TZ; locale=$P_LOCALE" >&2
exec env WORK="$WORK" PROFILE="$PROFILE" HOSTN="$P_HOSTNAME" RUNUSER="$P_USER" FAKEMEM="$P_FAKEMEM" \
  TZ_NAME="$P_TZ" LOCALE_NAME="$P_LOCALE" \
  unshare --mount --uts --fork bash -c '
    set -e
    hostname "$HOSTN"
    mount --bind "$WORK/cpuinfo" /proc/cpuinfo
    mount --bind "$WORK/hostname" /etc/hostname 2>/dev/null || true
    mount --bind "$WORK/machine-id" /etc/machine-id 2>/dev/null || true
    if [ "$FAKEMEM" = "1" ] && [ -f "$WORK/meminfo" ]; then
      mount --bind "$WORK/meminfo" /proc/meminfo 2>/dev/null || true
    fi
    if [ -n "$TZ_NAME" ] && [ -f "$WORK/localtime" ]; then
      LT_TARGET="$(readlink -f /etc/localtime 2>/dev/null || echo /etc/localtime)"
      mount --bind "$WORK/localtime" "$LT_TARGET" 2>/dev/null || true
    fi
    # 降权到普通用户（仿真"用户自己的桌面机"，不用 root 跑 QQ）
    if [ "$(id -u)" = "0" ] && id "$RUNUSER" >/dev/null 2>&1; then
      RUID="$(id -u "$RUNUSER")"; RGID="$(id -g "$RUNUSER")"
      RHOME="$(getent passwd "$RUNUSER" | cut -d: -f6)"; [ -n "$RHOME" ] || RHOME="/home/$RUNUSER"
      RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$RUID}"
      mkdir -p "$RUNTIME"; chown "$RUID:$RGID" "$RUNTIME" 2>/dev/null || true; chmod 700 "$RUNTIME" 2>/dev/null || true
      exec setpriv --reuid="$RUID" --regid="$RGID" --init-groups env \
        -u FAKEMEM -u HOSTN -u LOCALE_NAME -u TZ_NAME -u RUNUSER -u WORK -u PROFILE \
        HOME="$RHOME" USER="$RUNUSER" LOGNAME="$RUNUSER" \
        XDG_RUNTIME_DIR="$RUNTIME" LANG="$LOCALE_NAME" LC_ALL="$LOCALE_NAME" TZ="$TZ_NAME" "$@"
    fi
    exec env -u FAKEMEM -u HOSTN -u LOCALE_NAME -u TZ_NAME -u RUNUSER -u WORK LANG="$LOCALE_NAME" LC_ALL="$LOCALE_NAME" TZ="$TZ_NAME" "$@"
  ' qts "$@"
