// miohh M0/M1 宽钩子探针（自动生成）
'use strict';
const FUNCS = [{"rva": 48043498, "keys": ["setAutoLogin", "setAutoLogin_candidates"]}, {"rva": 54287914, "keys": ["quickLoginWithUin", "quickLoginWithUin_candidates"]}, {"rva": 54289466, "keys": ["quickLoginWithUin", "quickLoginWithUin_candidates"]}, {"rva": 54290458, "keys": ["getLoginList", "getLoginList_candidate_service"]}, {"rva": 54318355, "keys": ["setAutoLogin", "setAutoLogin_candidates"]}, {"rva": 54349895, "keys": ["quickLoginWithUin", "quickLoginWithUin_candidates"]}, {"rva": 55502561, "keys": ["addKernelLoginListener", "addKernelLoginListener_candidate"]}, {"rva": 55504515, "keys": ["getQRCodePicture", "getQRCodePicture_candidate"]}, {"rva": 55504787, "keys": ["startPolling"]}, {"rva": 55505059, "keys": ["abortPolling"]}, {"rva": 55508565, "keys": ["getLoginList", "getLoginList_candidate_service"]}, {"rva": 55509829, "keys": ["quickLoginWithUin", "quickLoginWithUin_candidates"]}, {"rva": 55510547, "keys": ["getMachineGuid", "getMachineGuid_candidate"]}, {"rva": 55512961, "keys": ["setAutoLogin", "setAutoLogin_candidates"]}, {"rva": 55614549, "keys": ["NodeIKernelLoginListener", "listener_dispatch_candidates"]}, {"rva": 55615461, "keys": ["NodeIKernelLoginListener"]}, {"rva": 55616373, "keys": ["NodeIKernelLoginListener"]}, {"rva": 55617511, "keys": ["NodeIKernelLoginListener", "listener_dispatch_candidates", "onQRCodeGetPicture"]}, {"rva": 55618503, "keys": ["NodeIKernelLoginListener"]}, {"rva": 55619623, "keys": ["NodeIKernelLoginListener", "listener_dispatch_candidates", "onQRCodeSessionUserScaned"]}, {"rva": 55620679, "keys": ["NodeIKernelLoginListener"]}, {"rva": 55622887, "keys": ["listener_dispatch_candidates", "onQRCodeSessionFailed"]}, {"rva": 55639859, "keys": ["callback-converter", "pngBase64QrcodeData", "qrcodeUrl", "qrcode_callback_converter_candidate"]}, {"rva": 60845973, "keys": ["setAutoLogin", "setAutoLogin_candidates"]}, {"rva": 129365541, "keys": ["startPolling"]}, {"rva": 133718529, "keys": ["startPolling"]}];
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
