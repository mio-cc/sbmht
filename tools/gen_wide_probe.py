#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从契约 JSON 生成"宽钩子"探针：hook 所有引用登录/二维码字符串的候选函数 + N-API 属性路径。"""
import json
import os
import sys


def main():
    contract = sys.argv[1] if len(sys.argv) > 1 else r"D:\整理\nc\packages\miohh\contracts\qq-3.2.32-52194.json"
    out_js = sys.argv[2] if len(sys.argv) > 2 else r"D:\整理\nc\packages\miohh\tools\frida_wide_probe.js"
    j = json.load(open(contract, encoding="utf-8"))
    funcs = {}
    for key, arr in (j.get("refs_by_key") or {}).items():
        for it in arr:
            fr = it.get("func_rva")
            if fr is None:
                continue
            f = funcs.setdefault(fr, {"rva": fr, "keys": set()})
            f["keys"].add(key)
    for c in j.get("callback_candidates") or []:
        fr = c.get("func_rva")
        if fr is None:
            continue
        f = funcs.setdefault(fr, {"rva": fr, "keys": set()})
        f["keys"].add("callback-converter")
    # 补充：getLoginList/QR 相关函数（来自 m0_status.key_functions）
    kf = (j.get("m0_status") or {}).get("key_functions") or {}
    extra = []
    for k, v in kf.items():
        if isinstance(v, str):
            extra.append((int(v, 16), k))
        elif isinstance(v, list):
            for x in v:
                extra.append((int(x, 16), k))
    for rva, k in extra:
        f = funcs.setdefault(rva, {"rva": rva, "keys": set()})
        f["keys"].add(k)
    items = [{"rva": v["rva"], "keys": sorted(v["keys"])} for v in sorted(funcs.values(), key=lambda x: x["rva"])]
    js = r"""// miohh M0/M1 宽钩子探针（自动生成）
'use strict';
const FUNCS = __FUNCS__;
const NAPI_STR_RX = /qrcode|pngBase64|iVBOR|data:image|wwlogin|qq\.com|login/i;
const B64_RX = /^[A-Za-z0-9+/=_-]{180,}$/;

let mod = null, installed = false, hits = {}, napiHits = {};
function sendErr(w, e) { send({ type: 'script-error', where: w, error: String(e) }); }
function findExportAnywhere(name) {
  try { if (typeof Module.getGlobalExportByName === 'function') { const g = Module.getGlobalExportByName(name); if (g) return g; } } catch (e) {}
  for (const m of Process.enumerateModules()) { try { if (typeof m.findExportByName === 'function') { const a = m.findExportByName(name); if (a) return a; } } catch (e) {} }
  return null;
}
function readCStr(p, max) {
  try {
    if (!p || (p.isNull && p.isNull())) return null;
    const b = new Uint8Array(p.readByteArray(Math.min(max || 64, 20000)));
    let e = b.indexOf(0); if (e < 0) e = b.length;
    let s = ''; for (let i = 0; i < e; i++) s += String.fromCharCode(b[i]);
    return s;
  } catch (e) { return null; }
}
function noteNapi(name, detail) {
  napiHits[name] = (napiHits[name] || 0) + 1;
  if (napiHits[name] <= 4) send({ type: 'napi-hit', name: name, detail: detail });
}

function hookNAPI() {
  const setNamed = findExportAnywhere('napi_set_named_property');
  if (setNamed) Interceptor.attach(setNamed, { onEnter(args) {
    try { const f = readCStr(args[2], 96); if (f && NAPI_STR_RX.test(f)) noteNapi('set_named_property', f); } catch (e) {}
  }});
  const setProp = findExportAnywhere('napi_set_property');
  if (setProp) Interceptor.attach(setProp, { onEnter(args) {
    try { noteNapi('set_property', ''); } catch (e) {}
  }});
  for (const name of ['napi_create_string_utf8', 'napi_create_string_latin1', 'napi_create_string_utf16']) {
    const a = findExportAnywhere(name); if (!a) continue;
    Interceptor.attach(a, { onEnter(args) {
      try {
        const len = args[2].toUInt32 ? args[2].toUInt32() : 0;
        if (len < 12 || len > 4 * 1024 * 1024) return;
        let s = null;
        if (name === 'napi_create_string_utf16') { try { s = args[1].readUtf16String(Math.min(len, 300)); } catch (e) {} }
        else s = readCStr(args[1], Math.min(len, 400));
        if (!s) return;
        if (NAPI_STR_RX.test(s) || (s.length >= 180 && B64_RX.test(s))) {
          noteNapi(name, { len: len, head: s.slice(0, 100), tail: s.slice(-30) });
        }
      } catch (e) {}
    }});
  }
  for (const name of ['napi_create_buffer', 'napi_create_buffer_copy']) {
    const a = findExportAnywhere(name); if (!a) continue;
    Interceptor.attach(a, { onEnter(args) {
      try { const len = args[1].toUInt32 ? args[1].toUInt32() : 0; if (len >= 300) noteNapi(name, { len: len }); } catch (e) {}
    }});
  }
}

function tryInstall() {
  if (installed) return;
  for (const m of Process.enumerateModules()) { if (/wrapper\.node$/i.test(m.name)) { mod = m; break; } }
  if (!mod) return;
  installed = true;
  send({ type: 'module', base: mod.base.toString(), size: mod.size, funcs: FUNCS.length });
  hookNAPI();
  for (const f of FUNCS) {
    const name = '0x' + f.rva.toString(16);
    try {
      Interceptor.attach(mod.base.add(f.rva), { onEnter(args) {
        try {
          hits[name] = (hits[name] || 0) + 1;
          if (hits[name] <= 2) send({ type: 'hit', name: name, keys: f.keys, a0: args[0].toString(), a1: args[1].toString() });
        } catch (e) {}
      }});
    } catch (e) { sendErr('hook:' + name, e); }
  }
  send({ type: 'ready', hooked: FUNCS.length });
  setInterval(() => { send({ type: 'hit-summary', funcHits: hits, napi: napiHits }); }, 10000);
}

try {
  for (const name of ['dlopen', 'dlmopen']) {
    const a = findExportAnywhere(name);
    if (a) Interceptor.attach(a, { onLeave() { try { tryInstall(); } catch (e) { sendErr('dlopen', e); } } });
  }
  tryInstall();
  try { const iv = setInterval(tryInstall, 200); setTimeout(() => { try { clearInterval(iv); } catch (e) {} }, 30000); } catch (e) { send({ type: 'no-timer' }); }
} catch (e) { sendErr('main', e); }
"""
    js = js.replace("__FUNCS__", json.dumps(items, ensure_ascii=False))
    open(out_js, "w", encoding="utf-8").write(js)
    print("wrote", out_js, "funcs:", len(items))


if __name__ == "__main__":
    main()
