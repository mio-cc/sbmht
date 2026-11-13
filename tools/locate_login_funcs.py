#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""轻量静态定位器：在 QQ 原生模块中定位登录服务/二维码回调相关函数（M0）。

思路：
  1) 解析 ELF64（节表/程序头/重定位），建立 文件偏移 <-> 虚拟地址 映射；
  2) 找出目标字符串（登录服务接口/二维码字段）的虚拟地址；
  3) 解析 .rela.dyn（R_X86_64_RELATIVE）与 .data.rel.ro 中的指针，得到 GOT/数据槽地址；
  4) 扫描 .text 中的 RIP 相对 LEA 引用（48-4F 8D / 8D），解析目标；
  5) 对命中指令回扫函数序言（endbr64 / push rbp / push r15...），给出候选函数起始 RVA；
  6) 输出 JSON 契约 + 控制台摘要（同一函数引用多个二维码字段的，标为"回调转换器候选"）。

用法:
  python locate_login_funcs.py <wrapper.node> [--out contract.json] [--max-refs N]
"""
import argparse
import hashlib
import json
import os
import re
import struct
import sys

# QQ 原生接口/字段名（腾讯二进制中的事实字符串，不含本项目旧名）
TARGETS = [
    "NodeIKernelLoginService::",
    "IKernelLoginService",
    "NodeIKernelLoginListener",
    "getQRCodePicture",
    "getLoginList",
    "quickLoginWithUin",
    "addKernelLoginListener",
    "onQRCodeGetPicture",
    "pngBase64QrcodeData",
    "qrcodeUrl",
    "QRCodeLoginSucceed",
    "onQRCodeSessionUserScaned",
    "onQRCodeSessionFailed",
    "setAutoLogin",
    "getMachineGuid",
    "startPolling",
    "abortPolling",
]


def parse_elf(data):
    if data[:4] != b"\x7fELF" or data[4] != 2:
        raise SystemExit("not ELF64")
    e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_phentsize = struct.unpack_from("<H", data, 0x36)[0]
    e_phnum = struct.unpack_from("<H", data, 0x38)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]

    phdrs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = struct.unpack_from(
            "<IIQQQQQQ", data, off)
        phdrs.append(dict(type=p_type, flags=p_flags, offset=p_offset, vaddr=p_vaddr, filesz=p_filesz))

    secs = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, typ, flags, addr, offset, size, link, info, align, entsize = struct.unpack_from(
            "<IIQQQQIIQQ", data, off)
        secs.append(dict(name=name, type=typ, flags=flags, addr=addr, offset=offset, size=size,
                         link=link, info=info, entsize=entsize))
    st = secs[e_shstrndx]
    stab = data[st["offset"]: st["offset"] + st["size"]]
    for s in secs:
        s["sname"] = stab[s["name"]: stab.index(b"\x00", s["name"])].decode(errors="replace")

    loads = [p for p in phdrs if p["type"] == 1]
    min_vaddr = min(p["vaddr"] for p in loads) if loads else 0
    return secs, phdrs, min_vaddr


def build_maps(secs, min_vaddr):
    off2va = []   # (file_off_start, file_off_end, va_start)
    va2off = []
    for s in secs:
        if s["size"] and s["type"] != 8:  # ignore NOBITS
            off2va.append((s["offset"], s["offset"] + s["size"], s["addr"]))
            va2off.append((s["addr"], s["addr"] + s["size"], s["offset"]))

    def f2v(off):
        for a, b, va in off2va:
            if a <= off < b:
                return va + (off - a)
        return None

    def v2f(va):
        for a, b, off in va2off:
            if a <= va < b:
                return off + (va - a)
        return None

    return f2v, v2f


def scan_strings(data, f2v):
    hits = {}
    for key in TARGETS:
        kb = key.encode()
        pos = 0
        n = 0
        while True:
            i = data.find(kb, pos)
            if i < 0:
                break
            pos = i + 1
            va = f2v(i)
            if va is None:
                continue
            ctx = data[max(0, i - 40): i + len(kb) + 80]
            ctx = bytes([x if 32 <= x < 127 else 46 for x in ctx]).decode()
            hits.setdefault(key, []).append({"file_off": i, "va": va, "rva": va - (hits_min_vaddr[0] if False else 0), "ctx": ctx})
            n += 1
            if n >= 200:
                break
    return hits


def parse_relocs(data, secs, string_vas, min_vaddr):
    """返回 (goto_targets:set(va), slot_map: {slot_va: string_va})"""
    goto_targets = set()
    slot_map = {}
    for s in secs:
        if s["sname"] not in (".rela.dyn", ".rela.plt") or s["type"] != 4:
            continue
        ent = s["entsize"] or 24
        for off in range(s["offset"], s["offset"] + s["size"], ent):
            if off + 24 > len(data):
                break
            r_offset, r_info, r_addend = struct.unpack_from("<QQq", data, off)
            rtype = r_info & 0xFFFFFFFF
            if rtype == 8 and r_addend in string_vas:  # R_X86_64_RELATIVE
                slot_map[r_offset] = r_addend
                goto_targets.add(r_offset)
    # 直接扫描 .data.rel.ro / .data 中的指针
    for s in secs:
        if s["sname"] in (".data.rel.ro", ".data") and s["type"] != 8:
            for off in range(s["offset"], s["offset"] + s["size"] - 7, 8):
                val = struct.unpack_from("<Q", data, off)[0]
                if val in string_vas:
                    slot_va = s["addr"] + (off - s["offset"])
                    slot_map[slot_va] = val
                    goto_targets.add(slot_va)
    return goto_targets, slot_map


REX_LEA = re.compile(rb"[\x48-\x4f]\x8d[\x05\x0d\x15\x1d\x25\x2d\x35\x3d](....)", re.S)
PLAIN_LEA = re.compile(rb"\x8d[\x05\x0d\x15\x1d\x25\x2d\x35\x3d](....)", re.S)


def scan_text_refs(data, secs, targets, min_vaddr, f2v, v2f):
    refs = []
    for s in secs:
        if not (s["flags"] & 0x4) or s["type"] == 8:  # SHF_EXECINSTR
            continue
        text = data[s["offset"]: s["offset"] + s["size"]]
        if not text:
            continue
        for rx, insn_len in ((REX_LEA, 7), (PLAIN_LEA, 6)):
            for m in rx.finditer(text):
                insn_off = s["offset"] + m.start()
                insn_va = s["addr"] + m.start()
                disp = struct.unpack("<i", m.group(1))[0]
                tgt = insn_va + insn_len + disp
                if tgt in targets:
                    refs.append({"insn_va": insn_va, "insn_off": insn_off, "target": tgt})
    # 去重（plain 可能落在 rex 指令内部）
    seen = set()
    uniq = []
    for r in refs:
        k = (r["insn_va"], r["target"])
        if k in seen:
            continue
        seen.add(k)
        uniq.append(r)
    return uniq, min_vaddr


PROLOGUES = [
    b"\xf3\x0f\x1e\xfa",                    # endbr64
    b"\x55\x48\x89\xe5",                    # push rbp; mov rbp,rsp
    b"\x55\x41\x57",                        # push rbp; push r15
    b"\x41\x57\x41\x56\x41\x55\x41\x54\x41\x53\x41\x52\x41\x51\x41\x50\x53",  # push r15..r11
    b"\x48\x83\xec",                        # sub rsp, imm8
    b"\x48\x81\xec",                        # sub rsp, imm32
]


def find_func_start(data, secs, insn_off, v2f, f2v, back=0x20000):
    for s in secs:
        if not (s["flags"] & 0x4) or s["type"] == 8:
            continue
        if not (s["offset"] <= insn_off < s["offset"] + s["size"]):
            continue
        lo = max(s["offset"], insn_off - back)
        chunk = data[lo: insn_off]
        best = None
        for pro in PROLOGUES:
            idx = chunk.rfind(pro)
            if idx >= 0:
                cand = lo + idx
                if best is None or cand > best:
                    best = cand
        if best is None:
            return None
        return {"file_off": best, "va": f2v(best)}
    return None


hits_min_vaddr = [0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("--out", default="")
    ap.add_argument("--max-refs", type=int, default=400)
    args = ap.parse_args()

    path = os.path.abspath(args.binary)
    data = open(path, "rb").read()
    secs, phdrs, min_vaddr = parse_elf(data)
    hits_min_vaddr[0] = min_vaddr
    f2v, v2f = build_maps(secs, min_vaddr)

    string_hits = scan_strings(data, f2v)
    string_vas = set()
    va2key = {}
    for key, arr in string_hits.items():
        for h in arr:
            h["rva"] = h["va"] - min_vaddr
            string_vas.add(h["va"])
            va2key[h["va"]] = key

    got_targets, slot_map = parse_relocs(data, secs, string_vas, min_vaddr)
    targets = set(string_vas) | got_targets
    refs, _ = scan_text_refs(data, secs, targets, min_vaddr, f2v, v2f)

    # 按目标归类 + 候选函数
    by_target = {}
    for r in refs[: args.max_refs * 4]:
        tgt = r["target"]
        key = va2key.get(tgt) or (("GOT:" + va2key.get(slot_map.get(tgt, -1), "?")) if tgt in slot_map else "?")
        fs = find_func_start(data, secs, r["insn_off"], v2f, f2v)
        item = {
            "insn_va": r["insn_va"], "insn_rva": r["insn_va"] - min_vaddr,
            "target_va": tgt, "target_rva": tgt - min_vaddr, "key": key,
            "func_va": fs["va"] if fs else None,
            "func_rva": (fs["va"] - min_vaddr) if fs else None,
        }
        by_target.setdefault(key, []).append(item)

    # 同一候选函数引用了二维码字段（pngBase64QrcodeData + qrcodeUrl）→ 回调转换器候选
    func_keys = {}
    for key, arr in by_target.items():
        for it in arr:
            if it["func_rva"] is not None:
                func_keys.setdefault(it["func_rva"], set()).add(key)
    callback_candidates = [
        {"func_rva": fr, "keys": sorted(ks)}
        for fr, ks in func_keys.items()
        if "pngBase64QrcodeData" in ks and "qrcodeUrl" in ks
    ]

    summary = {
        "binary": path,
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
        "elf_min_vaddr": min_vaddr,
        "strings": {k: v[:8] for k, v in string_hits.items()},
        "refs_by_key": {k: v[:20] for k, v in by_target.items()},
        "callback_candidates": callback_candidates,
        "note": "RVA = va - elf_min_vaddr（模块内相对偏移）；func_rva 为回扫序言得到的候选函数起点，需动态验证",
    }
    out = args.out or os.path.join(os.path.dirname(path), "login_contract.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=1)

    print(f"[locate] binary={os.path.basename(path)} sha256={summary['sha256'][:16]}… size={len(data)}")
    print(f"[locate] min_vaddr=0x{min_vaddr:x} strings_hit={sum(len(v) for v in string_hits.values())} lea_refs={len(refs)}")
    print("[locate] 字符串命中（rva）:")
    for key, arr in string_hits.items():
        print(f"  {key}: {len(arr)} 处, 首个 rva=0x{arr[0]['rva']:x} ctx={arr[0]['ctx'][:90]!r}")
    print("[locate] 回调转换器候选（同函数引用 pngBase64QrcodeData+qrcodeUrl）:")
    for c in callback_candidates[:10]:
        print(f"  func_rva=0x{c['func_rva']:x} keys={c['keys']}")
    print("[locate] 各接口 LEA 引用候选函数:")
    for key in TARGETS:
        arr = by_target.get(key, [])
        if not arr:
            continue
        uniq = []
        for it in arr:
            if it["func_rva"] is not None and it["func_rva"] not in [u["func_rva"] for u in uniq]:
                uniq.append({"func_rva": it["func_rva"], "insn_rva": it["insn_rva"]})
            if len(uniq) >= 6:
                break
        print(f"  {key}: " + ", ".join(f"func=0x{u['func_rva']:x}" for u in uniq))
    print(f"[locate] 契约 JSON -> {out}")


if __name__ == "__main__":
    main()
