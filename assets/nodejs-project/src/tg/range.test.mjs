// Range 解析的断言（node src/tg/range.test.mjs）
// 不依赖任何框架，跑完打印 OK；失败则 exit 1。
import assert from 'node:assert/strict';
import { parseRange, requestSizeFor } from './range.js';

const cases = [];
const t = (name, fn) => cases.push([name, fn]);

t('无 Range ⇒ 整段 200', () => {
    const r = parseRange(undefined, 1000);
    assert.deepEqual(r, { start: 0, end: 999, len: 1000, partial: false, unsatisfiable: false });
});

t('bytes=0-1 ⇒ 2 字节 206', () => {
    const r = parseRange('bytes=0-1', 1000);
    assert.equal(r.start, 0);
    assert.equal(r.end, 1);
    assert.equal(r.len, 2);
    assert.equal(r.partial, true);
});

t('bytes=100- ⇒ 到结尾', () => {
    const r = parseRange('bytes=100-', 1000);
    assert.equal(r.len, 900);
    assert.equal(r.end, 999);
});

t('末尾区间超出 ⇒ 夹到 size-1', () => {
    const r = parseRange('bytes=900-5000', 1000);
    assert.equal(r.end, 999);
    assert.equal(r.len, 100);
});

t('后缀 bytes=-500 ⇒ 最后 500 字节（原来错成开头 501 字节）', () => {
    const r = parseRange('bytes=-500', 1000);
    assert.equal(r.start, 500);
    assert.equal(r.end, 999);
    assert.equal(r.len, 500);
    assert.equal(r.partial, true);
});

t('后缀比文件还大 ⇒ 整段', () => {
    const r = parseRange('bytes=-5000', 1000);
    assert.equal(r.start, 0);
    assert.equal(r.len, 1000);
});

t('size 未知时不能声称 206（原来会回非法 206）', () => {
    const r = parseRange('bytes=0-1', 0);
    assert.equal(r.partial, false);
    assert.equal(r.unsatisfiable, false);
});

t('起点越界 ⇒ 416', () => {
    const r = parseRange('bytes=5000-', 1000);
    assert.equal(r.unsatisfiable, true);
});

t('反向区间 ⇒ 416', () => {
    const r = parseRange('bytes=800-200', 1000);
    assert.equal(r.unsatisfiable, true);
});

t('非法头 ⇒ 忽略 Range 回整段', () => {
    assert.equal(parseRange('items=0-1', 1000).partial, false);
    assert.equal(parseRange('bytes=-', 1000).partial, false);
});

t('requestSizeFor：探流只要 2 字节时别去拖 256KB', () => {
    assert.equal(requestSizeFor(2), 4096);          // 下限 4KB
    assert.equal(requestSizeFor(200 * 1024), 200 * 1024);
    assert.equal(requestSizeFor(0), 256 * 1024);    // 未知 ⇒ 用上限
    assert.equal(requestSizeFor(9 << 20), 256 * 1024); // 超上限 ⇒ 夹住
});

let failed = 0;
for (const [name, fn] of cases) {
    try {
        fn();
        console.log('  ✓', name);
    } catch (e) {
        failed++;
        console.log('  ✗', name, '\n    ', e.message);
    }
}
console.log(failed === 0 ? `\nOK (${cases.length} cases)` : `\nFAILED ${failed}/${cases.length}`);
process.exit(failed === 0 ? 0 : 1);
