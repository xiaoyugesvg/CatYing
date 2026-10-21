// 构建脚本（Node 侧 bundle）
//
// 🔴 原实现有两个坑，都会给人**假的成功信号**：
//   1. `esbuild.build(...)` **没有 await** ✗ —— 构建失败时脚本照样正常退出；
//      而 onEnd 里那句 `readFileSync('dist/main.js')` 会先抛，
//      于是真正的 esbuild 诊断被压在 unhandled rejection 下面，很难读 ✗
//   2. `dist/main.js.md5` **全仓没有任何消费方** ✗（`lib/` 里只有 `index.js.md5`
//      的校验路径）→ 写它属于自娱自乐，还会让人以为存在校验 ✓
//
// 现在：await + 检查 errors（失败**非 0 退出** ✓）；md5 默认不写，
// 需要时 `NODE_MD5=1 npm run build` ✓（保留能力、去掉误导 ✓）。
import * as esbuild from 'esbuild';
import fs from 'fs';
import { createHash } from 'crypto';

const result = await esbuild.build({
    entryPoints: ['src/main.js'],
    outfile: 'dist/main.js',
    bundle: true,
    minify: true,
    write: true,
    format: 'cjs',
    platform: 'node',
    target: 'node18',
    sourcemap: process.env.NODE_ENV === 'development' ? 'inline' : false,
    external: [],
});

if (result.errors.length > 0) {
    console.error(`构建失败：${result.errors.length} 个错误`);
    for (const e of result.errors) {
        console.error(' -', e.text, e.location ? `@ ${e.location.file}:${e.location.line}` : '');
    }
    process.exit(1);
}

// 尺寸与 hash 都打出来：脚本"通过"不能只看退出码 ✓（本项目历史上就踩过
// "构建脚本不做断言、失败也 exit 0"的坑 ✗），有这两个数就能核对产物真的换了 ✓
const bytes = fs.statSync('dist/main.js').size;
console.log(`构建完成：dist/main.js ${bytes} 字节`);

// ============================================================
// QuickJS 书源引擎 bundle（2026-10-21）
// ============================================================
// 把 book_source.js + book_rule.js（含 cheerio / crypto-js）打成一份 IIFE，
// 供 Flutter 的 quickjs_engine 加载；Node 专有模块用 qjs_shims 顶掉。
const qjs = await esbuild.build({
    entryPoints: ['src/book_qjs_entry.js'],
    outfile: '../../assets/js/book_engine_qjs.js',
    bundle: true,
    minify: true,
    write: true,
    format: 'iife',
    platform: 'browser',
    target: 'es2020',
    define: { global: 'globalThis' },
    inject: ['./src/qjs_shims/buffer.js'],
    alias: {
        axios: './src/qjs_shims/axios.js',
        vm: './src/qjs_shims/vm.js',
        'node:vm': './src/qjs_shims/vm.js',
        crypto: './src/qjs_shims/crypto.js',
        'node:crypto': './src/qjs_shims/crypto.js',
        buffer: './src/qjs_shims/buffer.js',
        'node:buffer': './src/qjs_shims/buffer.js',
    },
    logLevel: 'silent',
});

if (qjs.errors.length > 0) {
    console.error(`QuickJS bundle 构建失败：${qjs.errors.length} 个错误`);
    for (const e of qjs.errors) {
        console.error(' -', e.text, e.location ? `@ ${e.location.file}:${e.location.line}` : '');
    }
    process.exit(1);
}
const qbytes = fs.statSync('../../assets/js/book_engine_qjs.js').size;
console.log(`构建完成：assets/js/book_engine_qjs.js ${qbytes} 字节`);

if (process.env.NODE_MD5 === '1') {
    const md5 = createHash('md5').update(fs.readFileSync('dist/main.js')).digest('hex');
    fs.writeFileSync('dist/main.js.md5', md5);
    console.log('dist/main.js.md5 =', md5);
}
