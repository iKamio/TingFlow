#!/usr/bin/env node
'use strict';
// Independent XEAPI vectors: Node built-in crypto/zlib/assert only.
// Synthetic offline-only keys and payloads; no network or account material.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const fs = require('node:fs');
const path = require('node:path');
const STATIC = Buffer.from('ab1d5a430f6bb04a3f01e81ddd72bd916d5ce591248ac128714806d7f8fb1b84', 'hex');
const EAPI = Buffer.from('e82ckenh8dichen8', 'ascii');
const SIGN = Buffer.from('mUHCwVNWJbunMqAHf5MImuirT6plvs6VSFW62MGHstFQxhBGdEoIhLItH3djc4+FB/OKty3+lL2rGeoFBpVe5g==', 'ascii');
const FIXED = {
  timestamp: '1700000000123', nonce: '0123456789012345', device: 'fixture-device',
  peerPrivate: '24'.repeat(32), dynamicKey: '00112233445566778899aabbccddeeff',
  mask: 'f0e1d2c3b4a5968778695a4b3c2d1e0f',
  ephemeralPrivate: '42'.repeat(32), gcmNonce: '000102030405060708090a0b',
  payload: { title: 'A b~*😀', flag: true, count: 12, nil: null,
    list: [1, null, 'x'], object: { a: 1 }, e_r: 'caller-must-not-override' },
  response: { code: 200, data: { ok: true, note: 'synthetic fixture' } },
  gzipResponse: { code: 200, data: { gzip: 'synthetic fixture' } },
  version: 'fixture-v1', sk: 'synthetic-sk-not-a-credential'
};
function rawPrivate(hex) {
  return crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(hex, 'hex')]), format: 'der', type: 'pkcs8' });
}
function rawPublic(privateKey) { return crypto.createPublicKey(privateKey).export({ format: 'der', type: 'spki' }).subarray(-32); }
function aes(key, input, decrypt = false) {
  const c = decrypt ? crypto.createDecipheriv(`aes-${key.length * 8}-ecb`, key, null) : crypto.createCipheriv(`aes-${key.length * 8}-ecb`, key, null);
  return Buffer.concat([c.update(input), c.final()]);
}
function formValue(v, array = false) {
  if (v === null) return array ? '' : 'null';
  if (Array.isArray(v)) return v.map(x => formValue(x, true)).join(',');
  if (typeof v === 'object') return '[object Object]';
  return String(v);
}
function component(s) {
  // WHATWG URLSearchParams form percent-encode set; encodeURIComponent differs (~/*).
  const b = Buffer.from(s, 'utf8'); let out = '';
  for (const x of b) {
    if ((x >= 65 && x <= 90) || (x >= 97 && x <= 122) || (x >= 48 && x <= 57) || [42,45,46,95].includes(x)) out += String.fromCharCode(x);
    else if (x === 32) out += '+';
    else out += '%' + x.toString(16).toUpperCase().padStart(2, '0');
  }
  return out;
}
function requestPlaintext(p) {
  const keys = Object.keys(p).filter(k => k !== 'e_r').sort();
  const content = keys.map(k => component(k) + '=' + component(formValue(p[k]))).join('&');
  return Buffer.from(JSON.stringify({ ...(content ? { content } : {}), queryString: 'e_r=true' }));
}
function sign(timestamp, nonce) { return crypto.createHmac('sha256', SIGN).update(timestamp + nonce, 'utf8').digest(); }
function hkdf16(shared, eph) {
  const prk = crypto.createHmac('sha256', Buffer.alloc(32)).update(shared.length ? shared : Buffer.alloc(32)).digest();
  return crypto.createHmac('sha256', prk).update(Buffer.concat([eph, Buffer.from([1])])).digest().subarray(0, 16);
}
function portableGzip(input, options) {
  const compressed = zlib.gzipSync(input, options);
  // RFC 1952 OS is informational. Linux emits 3 and Darwin emits 19;
  // freeze it as Unix so exact cipher fixtures stay portable without
  // relaxing any request, signature, plaintext or decompression assertion.
  compressed[9] = 3;
  return compressed;
}
function makeVector() {
  const peerPriv = rawPrivate(FIXED.peerPrivate), peerPub = rawPublic(peerPriv);
  const ephPriv = rawPrivate(FIXED.ephemeralPrivate), ephPub = rawPublic(ephPriv);
  const dyn = Buffer.from(FIXED.dynamicKey, 'hex'), mask = Buffer.from(FIXED.mask, 'hex');
  const inner = aes(STATIC, requestPlaintext(FIXED.payload));
  const x = Buffer.from(inner.map((v, i) => v ^ mask[i & 15]));
  const rotation = (mask[0] & 15) % x.length;
  const mid = Buffer.concat([mask, x.subarray(rotation), x.subarray(0, rotation)]);
  const C = aes(dyn, mid).toString('base64url');
  const shared = crypto.diffieHellman({ privateKey: ephPriv, publicKey: crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), peerPub]), format: 'der', type: 'spki' }) });
  const gcmKey = hkdf16(shared, ephPub);
  const cipher = crypto.createCipheriv('aes-128-gcm', gcmKey, Buffer.from(FIXED.gcmNonce, 'hex'));
  const sPlain = Buffer.from(`${dyn.toString('base64')}|android|${FIXED.sk}`);
  const sBody = Buffer.concat([cipher.update(sPlain), cipher.final()]);
  const S = Buffer.concat([ephPub, Buffer.from(FIXED.gcmNonce, 'hex'), sBody, cipher.getAuthTag()]).toString('base64');
  const R = aes(STATIC, Buffer.from(FIXED.version + '|')).toString('base64');
  const registration = {
    appVersion: '9.5.61', currentKeyVersion: '', deviceId: FIXED.device, nonce: FIXED.nonce,
    os: 'android', requestType: 'active', signature: sign(FIXED.timestamp, FIXED.nonce).toString('base64'),
    t1: '', t2: '', timestamp: FIXED.timestamp, uid: ''
  };
  const keyDocument = { publicKey: peerPub.toString('base64'), version: FIXED.version, sk: FIXED.sk };
  const encryptedKeyDocument = aes(STATIC, Buffer.from(JSON.stringify(keyDocument)));
  const signedKeyResponse = {
    code: 200,
    data: { encryptedData: encryptedKeyDocument.toString('base64'), timestamp: FIXED.timestamp,
      signature: sign(FIXED.timestamp, FIXED.nonce).toString('base64') }
  };
  // A full AES block ending in 0x11 cannot be valid PKCS#7 padding.
  // Encrypt without padding so this fixture tests a real decode failure,
  // not an arbitrary byte sequence that a platform JSON parser may classify.
  const invalidPadCipher = crypto.createCipheriv('aes-128-ecb', EAPI, null);
  invalidPadCipher.setAutoPadding(false);
  const invalidPadding = Buffer.concat([invalidPadCipher.update(Buffer.alloc(16, 0x11)), invalidPadCipher.final()]);
  const responseBytes = Buffer.from(JSON.stringify(FIXED.response));
  const compressed = portableGzip(Buffer.from(JSON.stringify(FIXED.gzipResponse)), { level: 9, mtime: 0 });
  const overLimitPlain = Buffer.from(JSON.stringify({ code: 200, data: { value: 'A'.repeat(2 * 1024 * 1024 + 1) } }));
  const overLimitGzip = portableGzip(overLimitPlain, { level: 9, mtime: 0 });
  return {
    provenance: 'synthetic; independently generated with Node built-in crypto/zlib; no service access',
    inputs: FIXED, expected: { peerPublic: peerPub.toString('base64'), requestPlaintext: requestPlaintext(FIXED.payload).toString(),
      C, S, R, registration, signedKeyResponse,
      invalidPaddingResponse: invalidPadding.toString('base64'),
      encryptedResponse: aes(EAPI, responseBytes).toString('base64'),
      encryptedGzipResponse: aes(EAPI, compressed).toString('base64'),
      encryptedOversizeGzipResponse: aes(EAPI, overLimitGzip).toString('base64'),
      oversizeGzipExpandedBytes: overLimitPlain.length,
      responseJSON: FIXED.response, gzipResponseJSON: FIXED.gzipResponse }
  };
}
function run() {
  const file = path.join(__dirname, 'fixtures', 'NeteaseXEAPIVectors.json');
  const actual = makeVector();
  if (process.argv.includes('--write-fixture')) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(actual, null, 2) + '\n');
    console.log('Wrote deterministic synthetic XEAPI fixture'); return;
  }
  const expected = JSON.parse(fs.readFileSync(file, 'utf8'));
  // Deflate block choices can differ between zlib versions even with the same
  // level/header. Compare all crypto vectors exactly; compare gzip envelopes by
  // their independently decrypted, decompressed bytes without rewriting fixtures.
  const gzipFields = ['encryptedGzipResponse', 'encryptedOversizeGzipResponse'];
  function withoutGzip(vector) {
    const stable = structuredClone(vector);
    for (const field of gzipFields) delete stable.expected[field];
    return stable;
  }
  assert.deepEqual(withoutGzip(actual), withoutGzip(expected), 'independent Node crypto vector must match frozen fixture');
  for (const field of gzipFields) {
    const expand = vector => zlib.gunzipSync(aes(EAPI, Buffer.from(vector.expected[field], 'base64'), true));
    assert.deepEqual(expand(actual), expand(expected), `${field}: exact decompressed plaintext must match frozen fixture`);
  }
  assert.equal(aes(STATIC, Buffer.from(expected.expected.signedKeyResponse.data.encryptedData, 'base64'), true).toString(),
    JSON.stringify({ publicKey: expected.expected.peerPublic, version: FIXED.version, sk: FIXED.sk }));
  assert.throws(() => aes(EAPI, Buffer.from(expected.expected.invalidPaddingResponse, 'base64'), true), 'explicit invalid PKCS#7 padding');
  assert.deepEqual(JSON.parse(aes(EAPI, Buffer.from(expected.expected.encryptedResponse, 'base64'), true)), FIXED.response);
  assert.deepEqual(JSON.parse(zlib.gunzipSync(aes(EAPI, Buffer.from(expected.expected.encryptedGzipResponse, 'base64'), true))), FIXED.gzipResponse);
  const oversized = zlib.gunzipSync(aes(EAPI, Buffer.from(expected.expected.encryptedOversizeGzipResponse, 'base64'), true));
  assert.equal(oversized.length, expected.expected.oversizeGzipExpandedBytes);
  assert.ok(oversized.length > 2 * 1024 * 1024, 'fixture genuinely exceeds decompression cap');
  const mac = Buffer.from(expected.expected.signedKeyResponse.data.signature, 'base64');
  assert.equal(crypto.timingSafeEqual(mac, sign(FIXED.timestamp, FIXED.nonce)), true);
  assert.notEqual(crypto.timingSafeEqual(mac, sign(FIXED.timestamp, '0123456789012346')), true);
  const wrongKeyMac = crypto.createHmac('sha256', Buffer.from(SIGN.toString(), 'base64')).update(FIXED.timestamp + FIXED.nonce).digest();
  assert.notEqual(crypto.timingSafeEqual(mac, wrongKeyMac), true, 'sign key is ASCII, not base64-decoded');
  assert.equal(expected.expected.registration.signature, sign(FIXED.timestamp, FIXED.nonce).toString('base64'));
  assert.equal(aes(STATIC, Buffer.from(expected.expected.R, 'base64'), true).toString(), FIXED.version + '|');
  assert.match(expected.expected.C, /^[A-Za-z0-9_-]+$/, 'C uses unpadded base64url');

  // Independently unpack C and recover the exact pre-encryption JSON.
  const dyn = Buffer.from(FIXED.dynamicKey, 'hex'), mask = Buffer.from(FIXED.mask, 'hex');
  const mid = aes(dyn, Buffer.from(expected.expected.C, 'base64url'), true);
  assert.deepEqual(mid.subarray(0, 16), mask);
  assert.equal(expected.expected.requestPlaintext.includes('title=A+b%7E*%F0%9F%98%80'), true);
  const rotated = mid.subarray(16), rotation = (mask[0] & 15) % rotated.length;
  const xored = Buffer.alloc(rotated.length);
  for (let i = 0; i < rotated.length; i++) xored[(i + rotation) % rotated.length] = rotated[i];
  const inner = Buffer.from(xored.map((v, i) => v ^ mask[i & 15]));
  assert.equal(aes(STATIC, inner, true).toString(), expected.expected.requestPlaintext);

  // Independently authenticate/decrypt S with the recipient's private fixture key.
  const packed = Buffer.from(expected.expected.S, 'base64');
  const ephRaw = packed.subarray(0, 32), nonce = packed.subarray(32, 44);
  const ephPub = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), ephRaw]), format: 'der', type: 'spki' });
  const shared = crypto.diffieHellman({ privateKey: rawPrivate(FIXED.peerPrivate), publicKey: ephPub });
  const key = hkdf16(shared, ephRaw), decipher = crypto.createDecipheriv('aes-128-gcm', key, nonce);
  decipher.setAuthTag(packed.subarray(-16));
  assert.equal(Buffer.concat([decipher.update(packed.subarray(44, -16)), decipher.final()]).toString(),
    `${dyn.toString('base64')}|android|${FIXED.sk}`);
  const broken = Buffer.from(packed); broken[broken.length - 1] ^= 1;
  const bad = crypto.createDecipheriv('aes-128-gcm', key, nonce); bad.setAuthTag(broken.subarray(-16));
  assert.throws(() => { bad.update(broken.subarray(44, -16)); bad.final(); });
  console.log('PASS: independent deterministic XEAPI vectors (C/S/R, HMAC, AES, gzip and malformed-tag checks)');
}
run();
