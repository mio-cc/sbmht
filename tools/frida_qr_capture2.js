// miohh M1 焦点探针 v2：监听回调触发时扫描/抓取二维码 PNG（按 PNG 魔数），并解析 N-API 属性定义
'use strict';

const RVAS = {
  getQRCodePicture: 0x34eee83,
  getLoginList: 0x34efe55,
  addKernelLoginListener: 0x34ee6e1,
  nodeListener: 0x350a375,
  nodeListener2: 0x3509c55,
  converter: 0x350ff33
};
const SCAN_PATS = ['89 50 4e 47 0d 0a 1a 0a', '69 56 42 4f 52', '71 72 63 6f 64 65']; // PNG magic / iVBOR / qrcode
const SCAN_CAP = 250 * 1024 * 1024;
let mod = null, installed = false, captured = 0;
let napiGetStr = null, napiIsBuf = null, napiGetBuf = null;

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
function sendPngFrom(addr, len, tag) {
  try {
    if (captured >= 3) return;
    captured++;
    const data = new Uint8Array(addr.readByteArray(len));
    send({ type: 'qr-png-captured', tag: tag, addr: addr.toString(), len: len }, data);
  } catch (e) { sendErr('sendPng', e); }
}

function scanForPng(tag) {
  let bytes = 0, ranges = 0;
  try {
    const rs = Process.enumerateRanges('rw-').filter(r => !r.file).sort((a, b) => b.size - a.size);
    for (const r of rs) {
      if (r.size < 4096 || r.size > 256 * 1024 * 1024) continue;
      if (bytes + r.size > SCAN_CAP) break;
      bytes += r.size; ranges++;
      for (const pat of SCAN_PATS) {
        let ms = [];
        try { ms = Memory.scanSync(r.base, r.size, pat).slice(0, 3); } catch (e) { continue; }
        for (const m of ms) {
          let ctxHex = '';
          try { ctxHex = Array.from(new Uint8Array(m.address.readByteArray(16))).map(x => x.toString(16).padStart(2, '0')).join(''); } catch (e) {}
          send({ type: 'scan-hit', tag: tag, pattern: pat, addr: m.address.toString(), ctxHex: ctxHex });
          if (pat === SCAN_PATS[0]) {
            // PNG：向后找 IEND 估算长度，截取前 256KB
            try {
              const win = new Uint8Array(m.address.readByteArray(262144));
              let end = -1;
              for (let i = win.length - 8; i >= 4; i--) {
                if (win[i] === 0x49 && win[i + 1] === 0x45 && win[i + 2] === 0x4e && win[i + 3] === 0x44) { end = i + 8; break; }
              }
              const len = end > 0 ? end : 65536;
              sendPngFrom(m.address, len, tag);
            } catch (e) { sendErr('pngSize', e); }
          }
        }
      }
    }
  } catch (e) { sendErr('scan:' + tag, e); }
  send({ type: 'scan-done', tag: tag, ranges: ranges, bytes: bytes });
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
function valueInfo(env, value) {
  try {
    if (napiGetStr) {
      const buf = Memory.alloc(65536), outLen = Memory.alloc(8);
      if (napiGetStr(env, value, buf, 65535, outLen) === 0) {
        const s = readCStr(buf, 16384);
        if (s && s.length >= 4) return { kind: 'string', len: s.length, head: s.slice(0, 120) };
      }
    }
    if (napiIsBuf && napiGetBuf) {
      const isB = Memory.alloc(4);
      if (napiIsBuf(env, value, isB) === 0 && isB.readU8() !== 0) {
        const dp = Memory.alloc(8), lp = Memory.alloc(8);
        if (napiGetBuf(env, value, dp, lp) === 0) {
          const len = lp.readU64().toNumber();
          const p = dp.readPointer();
          const head = Array.from(new Uint8Array(p.readByteArray(16))).map(x => x.toString(16).padStart(2, '0')).join('');
          if (head.indexOf('89504e470d0a1a0a') === 0 && captured < 3) sendPngFrom(p, Math.min(len, 262144), 'napi-buffer');
          return { kind: 'buffer', len: len, headHex: head };
        }
      }
    }
  } catch (e) {}
  return null;
}

function hookNapi() {
  const defProps = findExportAnywhere('napi_define_properties');
  if (defProps) Interceptor.attach(defProps, { onEnter(args) {
    try {
      const count = args[2].toUInt32 ? args[2].toUInt32() : 0;
      const arr = args[3];
      for (let i = 0; i < Math.min(count, 64); i++) {
        const desc = arr.add(i * 64);
        const name = readCStr(desc.readPointer(), 96);
        if (!name || !/qrcode|png|image|login|url|base64/i.test(name)) continue;
        const value = desc.add(40).readPointer();
        const info = valueInfo(args[0], value);
        send({ type: 'napi-defprop', field: name, info: info });
      }
    } catch (e) {}
  }});
  const setProp = findExportAnywhere('napi_set_property');
  if (setProp && napiGetStr) Interceptor.attach(setProp, { onEnter(args) {
    try {
      const buf = Memory.alloc(4096), outLen = Memory.alloc(8);
      if (napiGetStr(args[0], args[2], buf, 4095, outLen) === 0) {
        const key = readCStr(buf, 200);
        if (key && /qrcode|png|image|login|url|base64/i.test(key)) {
          const info = valueInfo(args[0], args[3]);
          send({ type: 'napi-setprop', field: key, info: info });
        }
      }
    } catch (e) {}
  }});
  for (const name of ['napi_create_buffer', 'napi_create_buffer_copy', 'napi_create_external_buffer']) {
    const a = findExportAnywhere(name); if (!a) continue;
    Interceptor.attach(a, { onEnter(args) {
      try {
        if (name === 'napi_create_buffer_copy') {
          const len = args[1].toUInt32 ? args[1].toUInt32() : 0;
          if (len >= 1000 && len <= 4 * 1024 * 1024) {
            const head = Array.from(new Uint8Array(args[2].readByteArray(8))).map(x => x.toString(16).padStart(2, '0')).join('');
            send({ type: 'buffer-copy', len: len, headHex: head });
            if (head === '89504e470d0a1a0a') sendPngFrom(args[2], len, 'buffer_copy');
          }
        } else {
          const len = args[1].toUInt32 ? args[1].toUInt32() : 0;
          if (len >= 1000) send({ type: 'buffer-create', fn: name, len: len });
        }
      } catch (e) {}
    }});
  }
  for (const name of ['napi_create_string_utf8', 'napi_create_string_utf16']) {
    const a = findExportAnywhere(name); if (!a) continue;
    Interceptor.attach(a, { onEnter(args) {
      try {
        const len = args[2].toUInt32 ? args[2].toUInt32() : 0;
        if (len < 8 || len > 4 * 1024 * 1024) return;
        let s = null;
        if (name === 'napi_create_string_utf16') { try { s = args[1].readUtf16String(Math.min(len, 300)); } catch (e) {} }
        else s = readCStr(args[1], Math.min(len, 400));
        if (s && /qrcode|pngBase64|iVBOR|data:image|qm\.qq\.com|login/i.test(s)) send({ type: 'qr-string', fn: name, len: len, head: s.slice(0, 120) });
      } catch (e) {}
    }});
  }
}

function tryInstall() {
  if (installed) return;
  for (const m of Process.enumerateModules()) { if (/wrapper\.node$/i.test(m.name)) { mod = m; break; } }
  if (!mod) return;
  installed = true;
  send({ type: 'module', base: mod.base.toString() });
  initHelpers();
  hookNapi();
  for (const [name, rva] of Object.entries(RVAS)) {
    try {
      Interceptor.attach(mod.base.add(rva), {
        onEnter(args) { send({ type: 'hit', name: name, a0: args[0].toString(), a1: args[1].toString() }); },
        onLeave() { try { if (name !== 'getLoginList') scanForPng(name); } catch (e) { sendErr('scan-leave', e); } }
      });
      send({ type: 'rva-hooked', name: name });
    } catch (e) { sendErr('rva:' + name, e); }
  }
  send({ type: 'ready' });
}

try {
  const a = findExportAnywhere('dlopen');
  if (a) Interceptor.attach(a, { onLeave() { try { tryInstall(); } catch (e) {} } });
  tryInstall();
  try { setInterval(tryInstall, 200); } catch (e) {}
} catch (e) { sendErr('main', e); }
