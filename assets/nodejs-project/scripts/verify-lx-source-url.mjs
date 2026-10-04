// 用**真实的第三方音源脚本**验证我们的 LX 引擎：能不能加载、有哪些动作、报什么错。
//
//     cd assets/nodejs-project
//     node scripts/verify-lx-source-url.mjs "https://..../xxx.js"
//
// 为什么要这个：用户导入的源"用不了"时，报错往往是
// `Cannot read properties of undefined (reading 'version')`
// 这类**宿主 shim 缺字段**的问题 —— 光看消息没法定位，必须拿到**脚本的报错位置**。
// 这个脚本就用真源跑一遍，把 `error`（现在带 stack 前几帧 ✓）与动作列表打出来。
import axios from 'axios';
import { loadScript, runAction, engineInfo } from '../src/lx_engine.js';

const url = process.argv[2] || 'https://zrcdy.dpdns.org/lx/xinghai-music-sourcev2.3.14.js';

console.log('=== 1) 下载脚本 ===');
console.log('  URL:', url);
let src = '';
try {
    const r = await axios.get(url, {
        timeout: 20000,
        responseType: 'text',
        transformResponse: [(v) => v], // 不要自动 JSON.parse（它就是 JS）
        headers: { 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)' },
        maxRedirects: 5,
        validateStatus: (c) => c >= 200 && c < 400,
    });
    src = typeof r.data === 'string' ? r.data : String(r.data);
    console.log(`  ✅ HTTP ${r.status}，长度 ${src.length} 字符`);
    console.log('  开头 120 字:', JSON.stringify(src.slice(0, 120)));
} catch (e) {
    console.log('  ❌ 下载失败:', e.message);
    process.exit(1);
}

console.log('\n=== 2) 引擎信息 ===');
console.log('  ', JSON.stringify(engineInfo()));

console.log('\n=== 3) 用我们的沙箱加载它 ===');
const loaded = await loadScript(src);
console.log('  ok =', loaded.ok);
if (!loaded.ok) {
    console.log('  ❌ error =', loaded.error);
    if (loaded.stack) console.log('  stack:\n' + loaded.stack);
    console.log('\n👉 这段报错位置就是"缺哪个宿主字段"的线索');
    process.exit(2);
}
console.log('  ✅ 加载成功，注册的动作 =', JSON.stringify(loaded.actions));
console.log('  inited =', loaded.inited);

console.log('\n=== 4) 冒烟调用每个动作（空 payload，只看会不会崩） ===');
for (const a of loaded.actions) {
    if (String(a).startsWith('__')) continue;
    try {
        // 真实签名：runAction(handlers, action, payload)
        const r = await runAction(loaded.handlers, a, {});
        const brief =
            r && typeof r === 'object'
                ? JSON.stringify(r).slice(0, 160)
                : String(r).slice(0, 160);
        console.log(`  ${a} → ok=${r && r.ok}  ${brief}`);
    } catch (e) {
        console.log(`  ${a} → 抛异常: ${e && e.message}`);
    }
}

console.log('\n=== 5) 结论 ===');
console.log('  能加载 ✓ = 引擎 shim 与这个源兼容（至少顶层）');
console.log('  加载失败 ✗ = shim 缺字段，看上面 stack 定位');
