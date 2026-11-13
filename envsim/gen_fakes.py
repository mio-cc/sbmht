#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""根据 DeviceProfile 生成"环境仿真"伪造文件（cpuinfo/hostname/machine-id/localtime/可选 meminfo）。"""
import json
import os
import shutil
import sys


def main():
    profile_path, outdir = sys.argv[1], sys.argv[2]
    p = json.load(open(profile_path, encoding="utf-8"))
    os.makedirs(outdir, exist_ok=True)
    cpu = p["cpu"]
    nproc = int(cpu.get("processors", os.cpu_count() or 4))
    cores = int(cpu.get("cores", nproc))
    siblings = int(cpu.get("siblings", nproc))
    flags = " ".join(cpu.get("flags") or [])
    lines = []
    for i in range(nproc):
        lines.append(
            "processor\t: {p}\n"
            "vendor_id\t: {v}\n"
            "cpu family\t: {f}\n"
            "model\t\t: {m}\n"
            "model name\t: {name}\n"
            "stepping\t: {s}\n"
            "microcode\t: 0x{f2:x}\n"
            "cpu MHz\t\t: {mhz}\n"
            "cache size\t: {cache} KB\n"
            "physical id\t: 0\n"
            "siblings\t: {sib}\n"
            "core id\t\t: {core}\n"
            "cpu cores\t: {cores}\n"
            "apicid\t\t: {apic}\n"
            "initial apicid\t: {apic}\n"
            "fpu\t\t: yes\n"
            "fpu_exception\t: yes\n"
            "cpuid level\t: 22\n"
            "wp\t\t: yes\n"
            "flags\t\t: {flags}\n"
            "bugs\t\t:\n"
            "bogomips\t: {bogo:.2f}\n"
            "clflush size\t: 64\n"
            "cache_alignment\t: 64\n"
            "address sizes\t: 39 bits physical, 48 bits virtual\n"
            "power management\t:\n".format(
                p=i, v=cpu["vendor_id"], f=cpu["family"], m=cpu["model"], name=cpu["model_name"],
                s=cpu["stepping"], f2=cpu.get("model", 0), mhz=cpu.get("mhz", 3000),
                cache=cpu.get("cache_kb", 6144), sib=siblings,
                core=(i if cores >= nproc else (i * cores) // nproc),
                cores=cores, apic=i, flags=flags, bogo=cpu.get("mhz", 3000) / 2.0,
            )
        )
    open(os.path.join(outdir, "cpuinfo"), "w", encoding="utf-8").write("\n\n".join(lines).rstrip() + "\n")
    open(os.path.join(outdir, "hostname"), "w", encoding="utf-8").write(p["hostname"] + "\n")
    open(os.path.join(outdir, "machine-id"), "w", encoding="utf-8").write(p["machine_id"].strip() + "\n")
    tz = p.get("timezone")
    if tz:
        src = os.path.join("/usr/share/zoneinfo", tz)
        if os.path.isfile(src):
            shutil.copyfile(src, os.path.join(outdir, "localtime"))
            try:
                shutil.copyfile(src, os.path.join(outdir, "zoneinfo"))  # 兼容：直接绑 zoneinfo 文件
            except OSError:
                pass
    if p.get("fake_meminfo"):
        total = int(p.get("mem_total_kb", 8162000))
        avail = int(total * 0.62)
        mem = (
            "MemTotal:       {t} kB\nMemFree:        {f} kB\nMemAvailable:   {a} kB\n"
            "Buffers:        245760 kB\nCached:        {c} kB\nSwapCached:         0 kB\n"
            "SwapTotal:     2097148 kB\nSwapFree:      2097148 kB\nDirty:             512 kB\n"
            "Writeback:           0 kB\nMapped:        1258291 kB\nShmem:           65536 kB\n"
            "Slab:           312576 kB\nKernelStack:      8192 kB\nVmallocUsed:     28672 kB\n"
        ).format(t=total, f=int(total * 0.30), a=avail, c=int(total * 0.25))
        open(os.path.join(outdir, "meminfo"), "w", encoding="utf-8").write(mem)
    print(outdir)


if __name__ == "__main__":
    main()
