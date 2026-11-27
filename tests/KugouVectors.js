'use strict';
// Pure offline vectors. Only Node built-ins; no HTTP, account, environment or crypto-js access.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const md5 = s => crypto.createHash('md5').update(s).digest('hex');
const web = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';
const android = 'OIlwieks28dk2k092lksi2UIkp';
function sign(p, body, kind) {
  const fields = kind === 'web' ? Object.keys(p).map(k => `${k}=${p[k]}`).sort()
    : Object.keys(p).sort().map(k => `${k}=${p[k]}`);
  const salt = kind === 'web' ? web : android;
  return md5(salt + fields.join('') + body + salt);
}
const defaults = {dfid:'-', mid:'123456789012345678', uuid:'-', appid:'1005', clientver:'20489', clienttime:'1700000000'};
const qr = {...defaults, appid:'1014', type:'1', plat:'4', srcappid:'2919', qrcode_txt:'https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=1005&'};
const check = {...defaults, plat:'4', srcappid:'2919', qrcode:'synthetic-key', dev:'A'.repeat(32)};
const credential = {userid:42, token:'synthetic-token'};
const listsBody = JSON.stringify({...credential, total_ver:979, type:2, page:1, pagesize:100});
const tracksBody = JSON.stringify({listid:9, userid:42, type:0, page:1, pagesize:100, area_code:1, allplatform:1, show_cover:1, token:'synthetic-token'});
const cases = [
  ['qr-web', qr, '', 'web'],
  ['qr-check-web', check, '', 'web'],
  ['playlists-android', {...defaults, userid:'42', token:'synthetic-token', plat:'1'}, listsBody, 'android'],
  ['tracks-android', {...defaults, userid:'42', token:'synthetic-token'}, tracksBody, 'android'],
  // Prefix keys demonstrate why Web sorts the complete key=value strings, not just keys.
  ['web-full-fields', {a:'z', aa:'a', 'a-':'&+=中文'}, '', 'web']
];
assert.equal(sign({appid:'1001', clienttime:'1700000000', mid:'12345678'}, '', 'web'), '010c2efb8355bbbe23a9febcbfc02948');
assert.equal(sign({appid:'1005', userid:'42'}, JSON.stringify(credential), 'android'), '52386dbe51fdbd11eee0dde98eb17e3d');
assert.notEqual(sign({'a':'z','aa':'a','a-':'&+=中文'}, '', 'web'), sign({'a':'z','aa':'a','a-':'&+=中文'}, '', 'android'));
// When the supplied reference is available, execute its actual helper through a restricted
// require shim. It receives only synthetic inputs and MD5; no dependency can make requests.
let reference = false;
const file = '/tmp/kugou-reference/util/helper.js';
if (fs.existsSync(file)) {
  const sandbox = {module:{exports:{}}, Buffer, process:{env:{}}, require(name) {
    if (name === 'crypto-js') return {};
    if (name === './crypto') return {cryptoMd5:md5};
    if (name === './config.json') return {appid:1005, clientver:20489, liteAppid:3116, liteClientver:11440};
    throw new Error('Unexpected offline reference dependency');
  }};
  vm.runInNewContext(fs.readFileSync(file, 'utf8'), sandbox, {timeout:1000});
  for (const [name,p,b,k] of cases) {
    const fn = k === 'web' ? sandbox.module.exports.signatureWebParams : sandbox.module.exports.signatureAndroidParams;
    assert.equal(fn(p,b), sign(p,b,k), name + ' matches supplied helper');
  }
  reference = true;
}
const fixture = path.join(__dirname, 'fixtures', 'KugouSignatureVectors.json');
const result = cases.map(([name, parameters, body, kind]) => ({name, parameters, body, kind, signature:sign(parameters,body,kind)}));
if (process.argv.includes('--write')) {
  fs.writeFileSync(fixture, JSON.stringify(result,null,2) + '\n');
} else {
  assert.deepEqual(JSON.parse(fs.readFileSync(fixture, 'utf8')), result, 'committed synthetic vectors');
}
console.log(`PASS: ${result.length} offline KuGou signature vectors; supplied helper ${reference ? 'matched' : 'not present (fixture-only)'}.`);
