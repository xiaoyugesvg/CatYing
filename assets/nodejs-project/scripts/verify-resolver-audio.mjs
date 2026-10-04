// 模板法"形状校验"的回归测试 —— **直接测真函数**（不是镜像一份逻辑）。
//
//     cd assets/nodejs-project && node scripts/verify-resolver-audio.mjs
//
// 背景：模板法在 urlPath 与常见字段都没命中时，会 `findUrlDeep` 深度搜一个
// http(s) 串当播放地址 —— 而响应里通常还有封面/头像/分享页。
// 第一版规则**把网易封面 `p1.music.126.net/xx.jpg` 判成了音频**（因为主机名里
// 有 `music`）✗ 这个脚本就是为了把这类误判钉死。
import { looksAudio } from '../src/source_resolver.js';

const cases = [
    // [URL, 期望, 说明]
    ['http://p1.music.126.net/xx.jpg', false, '网易封面（主机名含 music）→ 必须拒'],
    ['https://x.com/cover.png', false, '封面 png → 必须拒'],
    ['https://x.com/a.webp?size=240', false, '封面 webp 带参 → 必须拒'],
    ['https://x.com/a.mp3', true, '裸 .mp3 → 收'],
    ['https://x.com/a.m4a?token=1', true, '带参 .m4a → 收'],
    ['https://x.com/live.m3u8', true, 'HLS → 收'],
    ['https://x.com/getPlayUrl?id=1', true, '路径含 play → 收'],
    ['https://x.com/api/audio/1', true, '路径含 audio → 收'],
    ['https://x.com/song/123', true, '路径含 song → 收'],
    ['https://x.com/abcdef', false, '无任何线索 → 必须拒（宁可不猜）'],
];

let bad = 0;
for (const [url, want, desc] of cases) {
    const got = looksAudio(url);
    const ok = got === want;
    if (!ok) bad++;
    console.log(`${ok ? '✅' : '❌'} ${desc}\n     ${url}  →  ${got}`);
}

console.log(bad === 0 ? '\n全部通过 ✅' : `\n${bad} 项失败 ❌`);
process.exit(bad === 0 ? 0 : 1);
