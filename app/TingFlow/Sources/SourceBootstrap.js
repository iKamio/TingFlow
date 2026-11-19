'use strict';
(() => {
  const nativeSend = __tfSend, nativeHTTP = __tfHTTP, nativeCancel = __tfCancel;
  const nativeTimer = __tfTimer, nativeClearTimer = __tfClearTimer;
  const nativeFinish = __tfFinish, nativeCrypto = __tfCrypto;
  const scriptInfo = Object.freeze(__tfInfo);
  const requests = new Map(), timers = new Map();
  let handler = null, initialized = false, counter = 0;
  const uid = () => String(++counter);
  const fail = message => { throw new Error(message); };
  const maxBytes = 262144;
  const bytes = (input, encoding = 'utf8') => {
    let result;
    if (typeof input !== 'string') {
      if (input instanceof ArrayBuffer) result = new Uint8Array(input);
      else if (ArrayBuffer.isView(input)) result = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
      else if (Array.isArray(input) && input.every(v => Number.isInteger(v) && v >= 0 && v <= 255)) result = new Uint8Array(input);
      else return fail('Unsupported buffer input');
    } else if (encoding === 'utf8' || encoding === 'utf-8') {
      result = new Uint8Array(Array.from(unescape(encodeURIComponent(input)), c => c.charCodeAt(0)));
    } else if (encoding === 'hex') {
      if (input.length % 2 || !/^[0-9a-f]*$/i.test(input)) return fail('Invalid hex');
      result = new Uint8Array(input.match(/.{2}/g)?.map(v => parseInt(v, 16)) || []);
    } else if (encoding === 'base64') {
      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      const clean = input.replace(/\s/g, '');
      if (!/^[A-Za-z0-9+/]*={0,2}$/.test(clean) || clean.length % 4) return fail('Invalid base64');
      const out = []; let bits = 0, accumulator = 0;
      for (const c of clean.replace(/=+$/, '')) {
        accumulator = (accumulator << 6) | alphabet.indexOf(c); bits += 6;
        if (bits >= 8) { bits -= 8; out.push((accumulator >> bits) & 255); }
      }
      result = new Uint8Array(out);
    } else return fail('Unsupported buffer encoding');
    if (result.byteLength > maxBytes) return fail('Buffer too large');
    return result;
  };
  const string = (input, format = 'utf8') => {
    const data = bytes(input);
    if (format === 'hex') return Array.from(data, b => b.toString(16).padStart(2, '0')).join('');
    if (format === 'base64') {
      const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'; let out = '';
      for (let i = 0; i < data.length; i += 3) {
        const n = (data[i] << 16) | ((data[i + 1] || 0) << 8) | (data[i + 2] || 0);
        out += abc[(n >> 18) & 63] + abc[(n >> 12) & 63] + (i + 1 < data.length ? abc[(n >> 6) & 63] : '=') + (i + 2 < data.length ? abc[n & 63] : '=');
      }
      return out;
    }
    if (format !== 'utf8' && format !== 'utf-8') return fail('Unsupported buffer format');
    let text = '';
    for (let i = 0; i < data.length; i += 4096) text += String.fromCharCode(...data.subarray(i, i + 4096));
    return decodeURIComponent(escape(text));
  };
  const cryptoCall = (operation, argumentsValue) => {
    const value = JSON.parse(nativeCrypto(operation, JSON.stringify(argumentsValue)));
    if (value.error) return fail('Unsupported or invalid crypto operation');
    return value.value;
  };
  const crypto = Object.freeze({
    md5: value => cryptoCall('md5', [String(value)]),
    randomBytes: size => new Uint8Array(cryptoCall('random', [size])),
    aesEncrypt: (input, mode, key, iv) => new Uint8Array(cryptoCall('aes', [Array.from(bytes(input)), mode, Array.from(bytes(key)), iv == null ? [] : Array.from(bytes(iv))])),
    rsaEncrypt: () => fail('RSA is explicitly unsupported by this host')
  });
  const lx = Object.freeze({
    version: '2.0.0', env: 'mobile', currentScriptInfo: scriptInfo,
    EVENT_NAMES: Object.freeze({ request: 'request', inited: 'inited', updateAlert: 'updateAlert' }),
    utils: Object.freeze({ buffer: Object.freeze({ from: bytes, bufToString: string }), crypto }),
    on(event, callback) {
      if (event !== 'request' || typeof callback !== 'function') return Promise.reject(new Error('Unsupported event'));
      handler = callback; nativeSend('registered', '{}'); return Promise.resolve();
    },
    send(event, value) {
      if (event === 'inited') {
        if (initialized || !handler) return Promise.reject(new Error('Invalid initialization order'));
        initialized = true;
      } else if (event !== 'updateAlert') return Promise.reject(new Error('Unsupported event'));
      return nativeSend(event, JSON.stringify(value)) ? Promise.resolve() : Promise.reject(new Error('Invalid initialization'));
    },
    request(url, options, callback) {
      if (typeof callback !== 'function') return fail('Callback required');
      const id = uid(); requests.set(id, callback);
      nativeHTTP(id, String(url), JSON.stringify(options || {}));
      return () => { const callback = requests.get(id); requests.delete(id); nativeCancel(id); if (callback) callback(new Error('Cancelled'), null, null); };
    }
  });
  Object.defineProperty(globalThis, 'lx', { value: lx, configurable: false, writable: false });
  globalThis.setTimeout = (callback, ms = 0, ...args) => {
    if (typeof callback !== 'function' || !Number.isFinite(ms)) return fail('Invalid timer');
    const id = uid(); timers.set(id, () => callback(...args)); nativeTimer(id, Math.min(60000, Math.max(0, ms))); return id;
  };
  globalThis.clearTimeout = id => { timers.delete(String(id)); nativeClearTimer(String(id)); };
  globalThis.__tfDeliverHTTP = (id, error, payload) => {
    const callback = requests.get(id); requests.delete(id); if (!callback) return;
    if (error) callback(new Error('Source request failed'), null, null);
    else { const response = JSON.parse(payload); callback(null, response, response.body); }
  };
  globalThis.__tfDeliverTimer = id => { const callback = timers.get(id); timers.delete(id); if (callback) callback(); };
  globalThis.__tfReset = () => { requests.clear(); timers.clear(); };
  globalThis.__tfRun = (ticket, request) => {
    try {
      if (!initialized || !handler) return fail('Not initialized');
      const result = handler(request);
      if (!result || typeof result.then !== 'function') return fail('Handler must return a Promise');
      result.then(value => nativeFinish(ticket, true, JSON.stringify(value))).catch(() => nativeFinish(ticket, false, ''));
    } catch (_) { nativeFinish(ticket, false, ''); }
  };
  for (const name of ['__tfSend', '__tfHTTP', '__tfCancel', '__tfTimer', '__tfClearTimer', '__tfFinish', '__tfCrypto', '__tfInfo']) delete globalThis[name];
})();
