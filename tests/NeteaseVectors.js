// Offline oracle only. Not a backend, no network or account access.
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.join(__dirname, '../app/TingFlow/Netease');
const swift = fs.readFileSync(path.join(root, 'NeteaseCrypto.swift'), 'utf8');
const base64 = swift.match(/let publicSPKI = "([^"]+)"/)[1];
const der = Buffer.from(base64, 'base64');
assert.equal(der.length, 162);
const publicKey = crypto.createPublicKey({ key: der, type: 'spki', format: 'der' });
const pkcs1 = publicKey.export({ type: 'pkcs1', format: 'der' });
assert.deepEqual(pkcs1, der.subarray(22));
assert.equal(pkcs1.length, 140);
function aes(text, key) {
  const cipher = crypto.createCipheriv('aes-128-cbc', Buffer.from(key), Buffer.from('0102030405060708'));
  return Buffer.concat([cipher.update(text, 'utf8'), cipher.final()]).toString('base64');
}
const secret = '0123456789abcdef';
const block = Buffer.concat([Buffer.alloc(112), Buffer.from(secret.split('').reverse().join(''))]);
const rsa = crypto.publicEncrypt({ key: publicKey, padding: crypto.constants.RSA_NO_PADDING }, block).toString('hex');
const jwk = publicKey.export({ format: 'jwk' });
function big(bytes) { return BigInt('0x' + Buffer.from(bytes).toString('hex')); }
function pow(base, exponent, modulus) {
  let result = 1n;
  while (exponent > 0n) { if (exponent & 1n) result = result * base % modulus; base = base * base % modulus; exponent >>= 1n; }
  return result;
}
const independentRSA = pow(big(block), big(Buffer.from(jwk.e, 'base64url')), big(Buffer.from(jwk.n, 'base64url'))).toString(16).padStart(256, '0');
assert.equal(rsa, independentRSA);
const params = aes(aes('{}', '0CoJUm6Qyw8W8jud'), secret);
const checks = fs.existsSync(path.join(__dirname, 'NeteaseChecks.swift')) ? fs.readFileSync(path.join(__dirname, 'NeteaseChecks.swift'), 'utf8') : '';
if (checks) { assert.ok(checks.includes(params)); assert.ok(checks.includes(rsa)); }
for (const name of ['NeteaseClient.swift', 'NeteaseStore.swift', 'NeteaseCrypto.swift', 'NeteaseXEAPI.swift', 'NeteaseXEAPISession.swift']) {
  const source = fs.readFileSync(path.join(root, name), 'utf8');
  assert.ok(!/\b(?:print|debugPrint|NSLog)\s*\(/.test(source), 'no credential/body logging');
  assert.ok(!/URLSession\.shared|URLSessionConfiguration\.default/.test(source), 'no shared sessions');
}
console.log(JSON.stringify({params, encSecKey: rsa}));
console.log('PASS: PKCS#1 extraction, AES fixture, independent RSA modular exponentiation, source privacy checks');
