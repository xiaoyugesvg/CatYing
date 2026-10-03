// lx_engine 能力回归验证（本地自建 HTTP 服务，不依赖外网）
//
// 为什么留这个脚本：LX 音源的 crypto/request 能力一旦缺一个，
// 表现只是"音源跑不通、报一句看不懂的错"，很难定位。
// 跑一遍这个脚本就能确认引擎侧是好的：
//
//     cd assets/nodejs-project
//     node scripts/verify-lx-engine.mjs
//
import http from 'node:http';
import crypto from 'node:crypto';
import { loadScript, runAction, engineInfo } from '../src/lx_engine.js';

// ---- 本地测试服务器：回显请求；/bin 返回二进制 ----
const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    if (req.url.startsWith('/bin')) {
      res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
      res.end(Buffer.from([1, 2, 3, 4, 5]));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      url: req.url,
      ct: req.headers['content-type'] || '',
      raw: Buffer.concat(chunks).toString('utf8'),
    }));
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;

// ---- 生成一对 RSA 密钥，验证 rsaEncrypt 真能加密 ----
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const pubPem = publicKey.export({ type: 'spki', format: 'pem' }).toString();
const privPem = privateKey.export({ type: 'pkcs1', format: 'pem' }).toString();

const script = `
lx.on('musicUrl', async () => {
  const out = {};
  out.sha256 = lx.utils.crypto.sha256('abc');
  out.sha1 = lx.utils.crypto.sha1('abc');
  out.stringToBuf_isBuffer = Buffer.isBuffer(lx.utils.buffer.stringToBuf('hi'));
  out.stringToHex = lx.utils.buffer.stringToHex('hi');
  out.bufConcat = lx.utils.buffer.bufConcat('a', 'b', 'c').toString('utf8');
  out.str2b64 = lx.utils.str2b64('hi');
  out.b64toStr = lx.utils.b64toStr('aGk=');
  out.rsaEnc = lx.utils.crypto.rsaEncrypt('secret', \`${pubPem}\`).toString('base64');
  out.formResp = await new Promise((res, rej) => {
    lx.request('http://127.0.0.1:${port}/form', { method: 'POST', form: { a: 1, b: 'x' } },
      (err, resp, body) => err ? rej(err) : res(body));
  });
  out.paramsResp = await new Promise((res, rej) => {
    lx.request('http://127.0.0.1:${port}/q', { params: { k: 'v', n: 2 } },
      (err, resp, body) => err ? rej(err) : res(JSON.parse(body).url));
  });
  out.binLen = await new Promise((res, rej) => {
    lx.request('http://127.0.0.1:${port}/bin', { binary: true },
      (err, resp, body) => err ? rej(err) : res(Buffer.isBuffer(body) ? body.length : -1));
  });
  return out;
});
`;

const r = await runAction((await loadScript(script)).handlers, 'musicUrl', {});
if (!r.ok) {
  console.log('❌ 脚本执行失败:', r.error);
  server.close();
  process.exit(1);
}
const o = r.result;
let decrypted = '';
try {
  decrypted = crypto.privateDecrypt(
    { key: privPem, padding: crypto.constants.RSA_PKCS1_PADDING },
    Buffer.from(o.rsaEnc, 'base64'),
  ).toString('utf8');
} catch (e) {
  decrypted = '解密失败: ' + e.message;
}
const formOk = (() => {
  try {
    const b = JSON.parse(o.formResp);
    return String(b.raw).includes('a=1') && String(b.ct).includes('urlencoded');
  } catch (_) {
    return false;
  }
})();

const checks = [
  ['sha256("abc")', o.sha256 === crypto.createHash('sha256').update('abc').digest('hex')],
  ['sha1("abc")', o.sha1 === crypto.createHash('sha1').update('abc').digest('hex')],
  ['stringToBuf 返回 Buffer', o.stringToBuf_isBuffer === true],
  ['stringToHex("hi") == 6869', o.stringToHex === '6869'],
  ['bufConcat 拼成 "abc"', o.bufConcat === 'abc'],
  ['str2b64("hi") == aGk=', o.str2b64 === 'aGk='],
  ['b64toStr("aGk=") == hi', o.b64toStr === 'hi'],
  ['rsaEncrypt 能私钥解回 "secret"', decrypted === 'secret'],
  ['form POST 发出 urlencoded 且带 a=1', formOk],
  ['params 拼进 query', String(o.paramsResp).includes('k=v') && String(o.paramsResp).includes('n=2')],
  ['binary 响应是 Buffer 且长度 5', o.binLen === 5],
];
let bad = 0;
for (const [name, ok] of checks) {
  console.log(`${ok ? '✅' : '❌'} ${name}`);
  if (!ok) bad++;
}
console.log('engineInfo:', JSON.stringify(engineInfo()));
server.close();
console.log(bad === 0 ? '\n全部通过 ✅' : `\n${bad} 项失败 ❌`);
process.exit(bad === 0 ? 0 : 1);
