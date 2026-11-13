#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""envsim 自动探测：读取当前 VPS 的真实信息，自动生成一份"真实 Linux 桌面"DeviceProfile。

部署时无需手工填写：`sudo bash envsim.sh --auto <cmd...>` 会自动调用本脚本。

自动获取/生成：
  - vCPU 数（nproc）→ 选核心数匹配的桌面 CPU 型号；内存总量用真实值
  - 发行版（/etc/os-release）与内核（uname）→ 保持真实（不伪造 os-release/内核）
  - 时区（/etc/localtime → zoneinfo 名）、locale（/etc/default/locale）
  - machine-id（默认沿用本机唯一值；--regenerate-machine-id 可重置）
  - 普通用户（/etc/passwd UID>=1000）
  - 设备名（真实 Linux 桌面风格池：笔记本型号 / 发行版默认名，按 machine-id 确定性挑选）
"""
import argparse
import hashlib
import json
import os
import platform
import re
import secrets
import sys

FLAGS_INTEL = ("fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush "
               "mmx fxsr sse sse2 ht syscall nx lm constant_tsc rep_good nopl xtopology cpuid "
               "pni pclmulqdq ssse3 sse4_1 sse4_2 x2apic movbe popcnt aes xsave avx f16c rdrand "
               "fsgsbase bmi1 avx2 smep bmi2 erms invpcid rdseed adx smap clflushopt clwb "
               "xsaveopt xsavec xgetbv1 xsaves").split()
FLAGS_AMD = ("fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush "
             "mmx fxsr sse sse2 ht syscall nx mmxext fxsr_opt pdpe1gb rdtscp lm constant_tsc "
             "rep_good nopl xtopology cpuid pni pclmulqdq ssse3 fma cx16 sse4_1 sse4_2 movbe "
             "popcnt aes xsave avx f16c rdrand lahf_lm cmp_legacy svm extapic cr8_legacy abm "
             "sse4a misalignsse 3dnowprefetch osvw ibs xsaveopt xsavec xgetbv1 xsaves").split()

# 按线程数（=vCPU 数）匹配桌面 CPU；名字里带核心数的用 AMD（siblings=2*cores），
# Intel 名字不含核心数（cores=siblings=vCPU）
CPU_TABLE = {
    2:  dict(vendor="GenuineIntel", family=6, model=94, stepping=3,
             name="Intel(R) Celeron(R) G3900 CPU @ 2.80GHz", mhz=2800, cache=2048, cores=2),
    4:  dict(vendor="GenuineIntel", family=6, model=158, stepping=9,
             name="Intel(R) Core(TM) i5-7400 CPU @ 3.00GHz", mhz=3000, cache=6144, cores=4),
    6:  dict(vendor="GenuineIntel", family=6, model=158, stepping=10,
             name="Intel(R) Core(TM) i5-9400F CPU @ 2.90GHz", mhz=2900, cache=9216, cores=6),
    8:  dict(vendor="GenuineIntel", family=6, model=158, stepping=13,
             name="Intel(R) Core(TM) i7-9700 CPU @ 3.00GHz", mhz=3000, cache=12288, cores=8),
    12: dict(vendor="AuthenticAMD", family=25, model=33, stepping=0,
             name="AMD Ryzen 5 5600X 6-Core Processor", mhz=3700, cache=32768, cores=6),
    16: dict(vendor="AuthenticAMD", family=25, model=113, stepping=0,
             name="AMD Ryzen 7 3700X 8-Core Processor", mhz=3600, cache=32768, cores=8),
    24: dict(vendor="AuthenticAMD", family=25, model=113, stepping=0,
             name="AMD Ryzen 9 3900X 12-Core Processor", mhz=3800, cache=65536, cores=12),
    32: dict(vendor="AuthenticAMD", family=25, model=33, stepping=0,
             name="AMD Ryzen 9 5950X 16-Core Processor", mhz=3400, cache=65536, cores=16),
}

HOSTNAME_LAPTOP = ["ThinkPad-T14", "XPS-15-9500", "Legion-5-Pro", "Nitro-AN515", "OMEN-15",
                   "ROG-Strix-G15", "TUF-Gaming-F15", "Predator-PH315", "IdeaPad-5",
                   "Pavilion-15", "Inspiron-15", "Aspire-5", "ZenBook-UX425", "VivoBook-15",
                   "MSI-GF63", "ThinkBook-15", "EliteBook-840", "Latitude-5420"]
HOSTNAME_DISTRO = ["debian", "ubuntu", "archlinux", "manjaro", "pop-os", "linuxmint", "fedora",
                   "opensuse", "kali", "elementary", "zorin", "endeavouros", "garuda",
                   "voidlinux", "nixos", "devuan", "artix", "xubuntu"]


def read_os_release():
    info = {}
    try:
        with open("/etc/os-release", encoding="utf-8", errors="replace") as f:
            for line in f:
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    info[k] = v.strip('"')
    except OSError:
        pass
    return info


def read_mem_total_kb():
    try:
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return 8 * 1024 * 1024


def read_timezone():
    try:
        target = os.path.realpath("/etc/localtime")
        m = re.search(r"/zoneinfo/(.+)$", target)
        if m:
            return m.group(1)
    except OSError:
        pass
    try:
        tz = open("/etc/timezone", encoding="utf-8").read().strip()
        if tz:
            return tz
    except OSError:
        pass
    return "Asia/Shanghai"


def read_locale():
    for path in ("/etc/default/locale", "/etc/locale.conf"):
        try:
            for line in open(path, encoding="utf-8", errors="replace"):
                if line.startswith("LANG="):
                    return line.split("=", 1)[1].strip().strip('"')
        except OSError:
            pass
    return os.environ.get("LANG", "zh_CN.UTF-8") or "zh_CN.UTF-8"


def read_machine_id(regenerate=False):
    if not regenerate:
        try:
            mid = open("/etc/machine-id", encoding="utf-8").read().strip()
            if re.fullmatch(r"[0-9a-f]{32}", mid):
                return mid
        except OSError:
            pass
    return secrets.token_hex(16).lower()


def read_user():
    candidates = []
    try:
        for line in open("/etc/passwd", encoding="utf-8", errors="replace"):
            p = line.rstrip("\n").split(":")
            if len(p) >= 7:
                try:
                    uid = int(p[2])
                except ValueError:
                    continue
                if 1000 <= uid < 65534 and p[5].startswith("/"):
                    candidates.append((uid, p[0], p[5]))
    except OSError:
        pass
    candidates.sort()
    if candidates:
        return candidates[0][1]
    return "user"


def pick_hostname(style, seed):
    pool = HOSTNAME_LAPTOP if style == "laptop" else HOSTNAME_DISTRO
    idx = int(hashlib.sha256(seed.encode()).hexdigest(), 16) % len(pool)
    return pool[idx]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "auto-profile.json"))
    ap.add_argument("--hostname", default="")
    ap.add_argument("--hostname-style", choices=["laptop", "distro"], default="laptop")
    ap.add_argument("--timezone", default="")
    ap.add_argument("--locale", default="")
    ap.add_argument("--user", default="")
    ap.add_argument("--regenerate-machine-id", action="store_true")
    ap.add_argument("--json", action="store_true", help="只打印 JSON，不写文件")
    ap.add_argument("--preserve-host-intl", action="store_true",
                    help="保留宿主原始时区/locale（默认：宿主为 UTC + 英文 locale 时，改为中文账号画像 Asia/Shanghai + zh_CN.UTF-8）")
    ap.add_argument("--default-timezone", default="Asia/Shanghai")
    ap.add_argument("--default-locale", default="zh_CN.UTF-8")
    args = ap.parse_args()

    nproc = os.cpu_count() or 1
    mem_kb = read_mem_total_kb()
    osr = read_os_release()
    kernel = platform.uname().release
    tz = args.timezone or read_timezone()
    loc = args.locale or read_locale()
    # 国内账号画像：VPS 默认 UTC + C/en_US 时，换成中文桌面常见画像（可按需 --preserve-host-intl）
    if not args.preserve_host_intl and not args.timezone:
        if tz.strip() in ("Etc/UTC", "UTC", "Etc/Unknown", "GMT"):
            tz = args.default_timezone
    if not args.preserve_host_intl and not args.locale:
        if loc.strip() in ("C", "POSIX", "") or loc.strip().startswith("en_US"):
            loc = args.default_locale
    mid = read_machine_id(args.regenerate_machine_id)
    user = args.user or read_user()

    cpu_entry = CPU_TABLE.get(nproc)
    if cpu_entry:
        vendor, family, model, stepping, name, mhz, cache, cores = (
            cpu_entry["vendor"], cpu_entry["family"], cpu_entry["model"], cpu_entry["stepping"],
            cpu_entry["name"], cpu_entry["mhz"], cpu_entry["cache"], cpu_entry["cores"])
        siblings = nproc
    else:
        vendor, family, model, stepping = "GenuineIntel", 6, 158, 9
        name, mhz, cache = "Intel(R) Core(TM) i5-7400 CPU @ 3.00GHz", 3000, 6144
        cores = siblings = nproc
    flags = FLAGS_AMD if vendor == "AuthenticAMD" else FLAGS_INTEL

    hostname = args.hostname or pick_hostname(args.hostname_style, mid + user)
    profile = {
        "hostname": hostname,
        "cpu": {
            "vendor_id": vendor, "family": family, "model": model, "stepping": stepping,
            "model_name": name, "mhz": mhz, "cache_kb": cache,
            "processors": nproc, "cores": cores, "siblings": siblings,
            "flags": flags,
        },
        "mem_total_kb": mem_kb,
        "fake_meminfo": False,
        "machine_id": mid,
        "display": "1920x1080",
        "locale": loc,
        "timezone": tz,
        "user": user,
        "detected": {
            "nproc": nproc,
            "distro": osr.get("PRETTY_NAME", "unknown"),
            "distro_id": osr.get("ID", "unknown"),
            "kernel": kernel,
            "timezone": tz,
            "locale": loc,
            "user": user,
            "hostname_style": args.hostname_style,
        },
    }
    text = json.dumps(profile, ensure_ascii=False, indent=2) + "\n"
    if args.json:
        sys.stdout.write(text)
        return
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"[autogen] profile -> {args.out}")
    print(f"[autogen] nproc={nproc} cpu={name} mem={mem_kb}KB distro={osr.get('PRETTY_NAME')} kernel={kernel}")
    print(f"[autogen] hostname={hostname} timezone={tz} locale={loc} user={user} machine_id={mid}")


if __name__ == "__main__":
    main()
