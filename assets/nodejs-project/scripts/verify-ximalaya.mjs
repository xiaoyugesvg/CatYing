// 喜马拉雅数据源的**本机真跑验收**（真联网）。
//
//     cd assets/nodejs-project
//     node scripts/verify-ximalaya.mjs
//
// 关键实测结论（脚本里注释了原因）：
//   · 分类列表**不能**按 vip 预过滤 —— "免费"专辑的音频地址大量为空（版权受限），
//     而 VIP 专辑反而给得出完整直链。所以可播性必须在**单集层面**判断。
//   · 专辑单集要按 `maxPageId` 翻完（实测某专辑 5991 集）。
import {
    ximalayaCategories,
    ximalayaCategory,
    ximalayaAlbum,
    ximalayaSearch,
    ximalayaUrl,
    ximalayaSelfTest,
} from '../src/ximalaya_source.js';

const line = (t) => console.log('\n' + '─'.repeat(66) + '\n' + t + '\n' + '─'.repeat(66));
let bad = 0;
const check = (name, ok, extra = '') => {
    console.log(`${ok ? '✅' : '❌'} ${name}${extra ? '  ' + extra : ''}`);
    if (!ok) bad++;
};

line('0) selfTest');
const st = ximalayaSelfTest();
console.log('  ' + JSON.stringify(st.hosts) + `  categories=${st.categories}`);
check('selfTest.ok', st.ok === true);

line('1) 分类');
const cats = await ximalayaCategories();
check('分类数量 = 8', cats.list.length === 8, `实际 ${cats.list.length}`);

line('2) 分类「有声书」下的专辑');
const cat = await ximalayaCategory('youshengshu', 1);
check('ok', cat.ok === true, cat.error || '');
console.log(`  返回 ${cat.list?.length ?? 0} 个专辑（含免费/VIP 标记），前 3：`);
(cat.list || []).slice(0, 3).forEach((a) =>
    console.log(`    [${a.remark}] id=${a.id}  ${a.name.slice(0, 30)}`));

line('3) 找一张**有可播单集**的专辑（含 maxPageId 分页）');
let al = null;
let tried = 0;
for (const cand of (cat.list || []).slice(0, 8)) {
    tried++;
    const r = await ximalayaAlbum(cand.id);
    const n = r.list?.length ?? 0;
    if (r.ok && n > 0) {
        al = r;
        console.log(`  ✅ 第 ${tried} 个可用：「${r.album?.name?.slice(0, 34)}」`);
        console.log(`     可播 ${n} 集，跳过（无直链）${r.skipped} 集`);
        break;
    }
    console.log(`  ⏭ 跳过「${cand.name.slice(0, 24)}」：${r.error || r.message || '无可播单集'}`);
}
check('找到可播专辑', !!al, tried ? `试了 ${tried} 个` : '（分类为空）');
if (al) {
    (al.list || []).slice(0, 3).forEach((t) =>
        console.log(`    id=${t.id}  ${t.name.slice(0, 30)}  ${t.duration}s`));
}

line('4) 取播放直链（来自专辑列表缓存，无需额外请求）');
const first = al?.list?.[0];
if (first) {
    const u = await ximalayaUrl(first.id);
    check('ok', u.ok === true, u.error || '');
    check('带 User-Agent（否则服务端拒绝）', !!(u.headers && u.headers['User-Agent']));
    check('是 https 直链', String(u.url || '').startsWith('https://'), (u.url || '').slice(0, 60));
}

line('5) 搜索（第三方聚合站，非官方）');
const se = await ximalayaSearch('庆余年');
check('ok', se.ok === true, se.error || '');
check('有结果', (se.list?.length ?? 0) > 0, `共 ${se.list?.length ?? 0} 条`);

console.log(bad === 0 ? '\n全部通过 ✅' : `\n${bad} 项失败 ❌`);
process.exit(bad === 0 ? 0 : 1);
