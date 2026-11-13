// miohh M1 焦点探针：捕获二维码 PNG Buffer（napi_create_buffer_copy）+ 关键函数
'use strict';

const RVAS = { getQRCodePicture: 0x34eee83, getLoginList: 0x34efe55, addKernelLoginListener: 0x34ee6e1, listener: 0x350a375, listener2: 0x3509c55, converter: 0x350ff33 };
const PNG_MAGIC = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
let mod = null, installed = false, sent = 0;

function sendErr(w, e) { send({ type: 'script-error', where: w, error: String(e), stack: e && e.stack ? String(e.stack) : '' }); }
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
function bytesToArray(p, len) { try { return Array.from(new Uint8Array(p.readByteArray(len))); } catch (e) { return []; } }
function isPng(head) { for (let i = 0; i < PNG_MAGIC.length; i++) if (head[i] !== PNG_MAGIC[i]) return false; return true; }

function captureBuffer(tag, len, ptr) {
  try {
    if (len < 1000 || len > 4 * 1024 * 1024) return;
    const head = bytesToArray(ptr, 16);
    const looksPng = isPng(head);
    send({ type: 'buffer-seen', tag: tag, len: len, headHex: head.map(x => x.toString(16).padStart(2, '0')).join(''), png: looksPng });
    if (looksPng && sent < 3) {
      sent++;
      try {
        const data = new Uint8Array(ptr.readByteArray(len));
        send({ type: 'qr-png-buffer', tag: tag, len: len }, data);
      } catch (e) { sendErr('send-buffer', e); }
    }
  } catch (e) { sendErr('capture:' + tag, e); }
}

function hookNapi() {
  const copy = findExportAnywhere('napi_create_buffer_copy');
  if (copy) {
    Interceptor.attach(copy, { onEnter(args) {
      try {
        const len = args[1].toUInt32 ? args[1].toUInt32() : parseInt(args[1].toString(), 16);
        captureBuffer('buffer_copy', len, args[2]);
      } catch (e) {}
    }});
    send({ type: 'hook', name: 'napi_create_buffer_copy' });
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
  const setNamed = findExportAnywhere('napi_set_named_property');
  if (setNamed) Interceptor.attach(setNamed, { onEnter(args) {
    try { const f = readCStr(args[2], 96); if (f && /pngBase64QrcodeData|qrcodeUrl|imageUrl|localLoginInfoList|LocalLoginInfoList/i.test(f)) send({ type: 'napi-prop', field: f }); } catch (e) {}
  }});
}

function tryInstall() {
  if (installed) return;
  for (const m of Process.enumerateModules()) { if (/wrapper\.node$/i.test(m.name)) { mod = m; break; } }
  if (!mod) return;
  installed = true;
  send({ type: 'module', base: mod.base.toString() });
  hookNapi();
  for (const [name, rva] of Object.entries(RVAS)) {
    try {
      Interceptor.attach(mod.base.add(rva), { onEnter(args) {
        send({ type: 'hit', name: name, rva: '0x' + rva.toString(16), a0: args[0].toString(), a1: args[1].toString() });
      }});
      send({ type: 'rva-hooked', name: name });
    } catch (e) { sendErr('rva:' + name, e); }
  }
  send({ type: 'ready' });
}

try {
  tryInstall();
  try { setInterval(tryInstall, 200); } catch (e) {
    for (const nm of ['dlopen', 'dlmopen']) { const a = findExportAnywhere(nm); if (a) Interceptor.attach(a, { onLeave() { try { tryInstall(); } catch (e) {} } }); }
  }
} catch (e) { sendErr('main', e); }
