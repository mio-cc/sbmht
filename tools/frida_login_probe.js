// miohh M0/M1 动态探针 v8：spawn 模式 + dlopen 等待 wrapper.node + 回调后扫描
'use strict';

const RVAS = { getQRCodePicture: 0x34eee83, getLoginList: 0x34efe55, listener: 0x3509c55, converter: 0x350ff33 };
const SCAN_PATTERNS = ['iVBORw0KGgo', 'data:image/png;base64', 'pngBase64QrcodeData', 'qm.qq.com', 'qrcode'];
const QR_FIELD_RX = /^(pngBase64QrcodeData|qrcodeUrl)$/;
const SCAN_CAP = 400 * 1024 * 1024;

let mod = null, installed = false, servicePtr = null;
let napiGetStr = null, napiIsBuf = null, napiGetBuf = null;

function sendErr(w, e) { send({ type: 'script-error', where: w, error: String(e), stack: e && e.stack ? String(e.stack) : '' }); }
function findExportAnywhere(name) {
  try { if (typeof Module.getGlobalExportByName === 'function') { const g = Module.getGlobalExportByName(name); if (g) return g; } } catch (e) {}
  for (const m of Process.enumerateModules()) { try { if (typeof m.findExportByName === 'function') { const a = m.findExportByName(name); if (a) return a; } } catch (e) {} }
  return null;
}
function readCStr(p, max) {
  try {
    if (!p || (p.isNull && p.isNull())) return null;
    const b = new Uint8Array(p.readByteArray(Math.min(max || 64, 16384)));
    let e = b.indexOf(0); if (e < 0) e = b.length;
    let s = ''; for (let i = 0; i < e; i++) s += String.fromCharCode(b[i]);
    return s;
  } catch (e) { return null; }
}

function scanLight(tag) {
  const hits = []; let bytes = 0, scanned = 0;
  try {
    const ranges = Process.enumerateRanges('rw-').filter(r => !r.file).sort((a, b) => b.size - a.size);
    for (const r of ranges) {
      if (r.size < 4096 || r.size > 256 * 1024 * 1024) continue;
      if (bytes + r.size > SCAN_CAP) break;
      bytes += r.size; scanned++;
      for (const pat of SCAN_PATTERNS) {
        let ms = [];
        try { ms = Memory.scanSync(r.base, r.size, pat).slice(0, 6); } catch (e) { continue; }
        for (const m of ms) {
          let ctx = '';
          try { ctx = readCStr(m.address.sub(48), 400) || ''; } catch (e) {}
          hits.push({ pattern: pat, addr: m.address.toString(), ctx: ctx.slice(0, 200) });
          send({ type: 'scan-hit', tag: tag, pattern: pat, addr: m.address.toString(), ctx: ctx.slice(0, 160) });
        }
        if (hits.length >= 12) break;
      }
      if (hits.length >= 12) break;
    }
  } catch (e) { sendErr('scan:' + tag, e); }
  send({ type: 'scan-done', tag: tag, ranges: scanned, bytes: bytes, hits: hits.length });
}

function initHelpers() {
  const a = findExportAnywhere('napi_get_value_string_utf8');
  const b = findExportAnywhere('napi_is_buffer');
  const c = findExportAnywhere('napi_get_buffer_info');
  if (a) napiGetStr = new NativeFunction(a, 'int', ['pointer', 'pointer', 'pointer', 'size_t', 'pointer']);
  if (b) napiIsBuf = new NativeFunction(b, 'int', ['pointer', 'pointer', 'pointer']);
  if (c) napiGetBuf = new NativeFunction(c, 'int', ['pointer', 'pointer', 'pointer', 'pointer']);
  send({ type: 'helpers', getStr: !!a, isBuf: !!b, getBuf: !!c });
}

function readNapiValue(env, value, name) {
  try {
    if (napiGetStr) {
      const buf = Memory.alloc(65536), outLen = Memory.alloc(8);
      if (napiGetStr(env, value, buf, 65535, outLen) === 0) {
        const s = readCStr(buf, 16384);
        if (s && s.length >= 6) { send({ type: 'qr-string', field: name, len: s.length, head: s.slice(0, 120) }); return; }
      }
    }
    if (napiIsBuf && napiGetBuf) {
      const isB = Memory.alloc(4);
      if (napiIsBuf(env, value, isB) === 0 && isB.readU8() !== 0) {
        const dp = Memory.alloc(8), lp = Memory.alloc(8);
        if (napiGetBuf(env, value, dp, lp) === 0) send({ type: 'qr-buffer', field: name, len: lp.readU64().toNumber() });
      }
    }
  } catch (e) { sendErr('napiValue', e); }
}

function installHooks() {
  for (const name of ['napi_set_named_property', 'napi_create_string_utf8', 'napi_create_string_utf16']) {
    const addr = findExportAnywhere(name);
    if (!addr) { send({ type: 'noexport', name }); continue; }
    Interceptor.attach(addr, { onEnter(args) {
      try {
        if (name === 'napi_set_named_property') {
          const field = readCStr(args[2], 64);
          if (field && QR_FIELD_RX.test(field)) { send({ type: 'qr-prop', field: field }); readNapiValue(args[0], args[3], field); }
          return;
        }
        const len = args[2].toUInt32 ? args[2].toUInt32() : 0;
        if (name === 'napi_create_string_utf16') {
          if (len >= 256) { try { send({ type: 'napi-str16', len: len, head: args[1].readUtf16String(Math.min(len, 100)).slice(0, 100) }); } catch (e) {} }
        } else if (len >= 256) {
          const s = readCStr(args[1], Math.min(len, 300));
          if (s && (s.indexOf('iVBOR') === 0 || s.indexOf('data:image') === 0 || s.indexOf('http') === 0)) send({ type: 'napi-str', len: len, head: s.slice(0, 120) });
        }
      } catch (e) {}
    }});
    send({ type: 'hook', name });
  }

  for (const [k, rva] of Object.entries(RVAS)) {
    try {
      Interceptor.attach(mod.base.add(rva), {
        onEnter(args) {
          try {
            if ((k === 'getQRCodePicture' || k === 'getLoginList') && !servicePtr) {
              servicePtr = args[0];
              send({ type: 'service-ptr', from: k, ptr: args[0].toString() });
            }
            send({ type: 'rva-hit', name: k, rva: '0x' + rva.toString(16), a0: args[0].toString() });
          } catch (e) {}
        },
        onLeave() {
          try {
            send({ type: 'rva-leave', name: k });
            if (k === 'getQRCodePicture' || k === 'listener' || k === 'converter') scanLight(k);
          } catch (e) { sendErr('leave:' + k, e); }
        }
      });
      send({ type: 'rva-hooked', name: k, rva: '0x' + rva.toString(16) });
    } catch (e) { sendErr('rva:' + k, e); }
  }
}

function tryInstall() {
  if (installed) return;
  for (const m of Process.enumerateModules()) {
    if (/wrapper\.node$/i.test(m.name)) { mod = m; break; }
  }
  if (!mod) return;
  installed = true;
  send({ type: 'module', base: mod.base.toString(), size: mod.size });
  initHelpers();
  installHooks();
  send({ type: 'ready' });
  scanLight('post-load');
}

function main() {
  // 1) dlopen：等待 wrapper.node 被加载后立刻安装钩子
  for (const name of ['dlopen', 'dlmopen']) {
    const a = findExportAnywhere(name);
    if (!a) { send({ type: 'noexport', name }); continue; }
    try { Interceptor.attach(a, { onLeave() { try { tryInstall(); } catch (e) { sendErr('dlopen', e); } } }); send({ type: 'dlopen-hooked', name }); } catch (e) { sendErr('dlopen', e); }
  }
  // 2) 若已加载（attach 模式）立即安装
  tryInstall();
  // 3) 兜底轮询（部分 Frida 版本 setTimeout 可用）
  try {
    const iv = setInterval(tryInstall, 200);
    setTimeout(() => { try { clearInterval(iv); } catch (e) {} }, 30000);
    send({ type: 'poll-timer', ok: true });
  } catch (e) { send({ type: 'poll-timer', ok: false, err: String(e) }); }
}

try { main(); } catch (e) { sendErr('main', e); }
