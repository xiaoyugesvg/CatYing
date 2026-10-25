// 微软 Edge「大声朗读」的 DRM 令牌（Sec-MS-GEC v2）
// ============================================================
// 2025 年起微软把这个令牌从 v1 换成了 v2：
//   `<CS64 十六进制 8 字节>-<自定义 SHA-256 摘要>`
// 只有 MS 自己的前端算得出来，所以老实现（包括 npm 上的 msedge-tts）
// 现在握手一律 403。这里是按 edge-tts 的参考实现逐行移植的纯算法，
// 不含任何网络行为 —— 校验方式是拿固定时间戳对比参考实现输出。
//
// ⚠️ 改这个文件前先跑一遍自测：`node src/tts/edge_drm.selftest.mjs`

const MASK = 0xffffffffn;
const U32 = 0xffffffff;

export const TRUSTED_CLIENT_TOKEN = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
const WIN_EPOCH = 11644473600;

const SHA256_INITIAL = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];
const SHA256_STATE = [
    0xfd9fbea2, 0x91243ce7, 0xbe499094, 0xcd2e1e0a,
    0x6c006f49, 0x04bd35ab, 0xfeb0a7e4, 0x03effbd2,
];
const SHA256_SCHEDULE = [
    0xeb24bf9e, 0x1558691f, 0xa0c09ee2, 0x0cfa32ba,
    0xa622ee8c, 0xd1dd9491, 0xc0dd25a0, 0xf9e70ab6,
    0xf0c31573, 0x7058ce4e, 0x7188e606, 0x00e5ab33,
    0xd258b060, 0x72766564,
];
const SHA256_ROUND_CONSTANTS = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];
const SHA256_ADJUSTMENT = 0xc9dc06a7;
const SHA256_BLOCK_CONSTANTS = [
    ...SHA256_ROUND_CONSTANTS.slice(0, 14),
    SHA256_ADJUSTMENT,
    ...SHA256_ROUND_CONSTANTS.slice(15),
];
const SHA256_SIGMA0_ADJUSTMENT = 0x059c0b80;
const SHA256_SIGMA1_ADJUSTMENT = 0x000b92c0;

const CS64_COEFFICIENTS = [
    [0xe82e91b1, 0xb32700d0], [0x44de24c6, 0x88dff51d],
    [0x3beb65bc, 0x29514038], [0xc89c5933, 0xb328cbdf],
    [0x8d1ec211, 0xd405b4d5], [0x314ef5d5, 0x26e55f3c],
    [0xe92491b1, 0x607801c6], [0xf0a5b9d5, 0x82b2c1fb],
    [0x06064cf3, 0xfa51a3da], [0xda79fa60, 0x207cc464],
    [0xbed20560, 0x3c3c74f3], [0x89f9c9f8, 0xd2d14b61],
    [0x35fa38c6, 0xbb04a2c1], [0xcb49e3c6, 0xc5626167],
];
const CS64_FACTOR = 0x82893933;
const CS64_ADJUSTMENT0 = 0xf2f90b1a;
const CS64_ADJUSTMENT1 = 0x0b1a0000;

const rotr = (x, n) => ((x >>> n) | (x << (32 - n))) >>> 0;
const rol16 = (x) => (((x << 16) | (x >>> 16)) & U32) >>> 0;

const sigma0 = (v) => (rotr(v, 7) ^ rotr(v, 18) ^ (v >>> 3)) >>> 0;
const sigma1 = (v) => (rotr(v, 17) ^ rotr(v, 19) ^ (v >>> 10)) >>> 0;

/** SHA-256 轮函数（对应参考实现的 unrolled 版本，数学等价） */
function sha256Rounds(state, words, firstRound) {
    let [a, b, c, d, e, f, g, h] = state;
    const K = firstRound === 14 ? SHA256_BLOCK_CONSTANTS : SHA256_ROUND_CONSTANTS;
    for (let i = firstRound; i < 64; i++) {
        const t1 = (h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) +
            (g ^ (e & (f ^ g))) + K[i] + words[i]) >>> 0;
        const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) +
            ((a & b) | (c & (a | b)))) >>> 0;
        h = g; g = f; f = e; e = (d + t1) >>> 0;
        d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    return [a, b, c, d, e, f, g, h];
}

function expandSchedule(words, firstWord) {
    for (let i = firstWord; i < 64; i++) {
        words[i] = (sigma1(words[i - 2]) + words[i - 7] +
            sigma0(words[i - 15]) + words[i - 16]) >>> 0;
    }
}

function sha256Init(data) {
    const words = new Array(64).fill(0);
    words[14] = ((data[0] << 16) | (data[1] << 8) | data[2]) >>> 0;
    words[15] = ((data[3] << 24) | (data[4] << 16) | (data[5] << 8) | data[6]) >>> 0;
    for (let i = 16; i <= 29; i++) {
        let value = SHA256_SCHEDULE[i - 16];
        if (i - 2 >= 14) {
            value += i === 16
                ? (sigma1(words[i - 2]) ^ SHA256_SIGMA1_ADJUSTMENT)
                : sigma1(words[i - 2]);
        }
        if (i - 7 >= 14) value += words[i - 7];
        if (i - 15 >= 14) {
            value += i === 29
                ? (sigma0(words[i - 15]) ^ SHA256_SIGMA0_ADJUSTMENT)
                : sigma0(words[i - 15]);
        }
        words[i] = value >>> 0;
    }
    words[30] = (sigma1(words[28]) + words[23] + sigma0(words[15]) + words[14] +
        SHA256_ADJUSTMENT - SHA256_ROUND_CONSTANTS[14]) >>> 0;
    expandSchedule(words, 31);
    const working = sha256Rounds(SHA256_STATE, words, 14);
    return working.map((v, i) => (v + SHA256_INITIAL[i]) >>> 0);
}

function sha256Digest(data) {
    const length = 57 + data.length;
    const tail = [];
    for (let i = 7; i < data.length; i++) tail.push(data[i]);
    tail.push(0x80);
    const pad = (((55 - length) % 64) + 64) % 64;
    for (let i = 0; i < pad; i++) tail.push(0);
    const bits = BigInt(length) * 8n;
    for (let i = 7; i >= 0; i--) tail.push(Number((bits >> BigInt(i * 8)) & 0xffn));

    let state = sha256Init(data.slice(0, 7));
    for (let off = 0; off < tail.length; off += 64) {
        const words = new Array(64).fill(0);
        for (let i = 0; i < 16; i++) {
            const p = off + i * 4;
            words[i] = ((tail[p] << 24) | (tail[p + 1] << 16) |
                (tail[p + 2] << 8) | tail[p + 3]) >>> 0;
        }
        expandSchedule(words, 16);
        const working = sha256Rounds(state, words, 0);
        state = state.map((v, i) => (v + working[i]) >>> 0);
    }
    return state;
}

/** 小端 32 位字数组（不足补 0，且保证偶数个） */
function wordsLe4Even(bytes) {
    const padded = Array.from(bytes);
    while (padded.length % 4) padded.push(0);
    const words = [];
    for (let i = 0; i < padded.length; i += 4) {
        words.push((padded[i] | (padded[i + 1] << 8) |
            (padded[i + 2] << 16) | (padded[i + 3] << 24)) >>> 0);
    }
    if (words.length % 2) words.push(0);
    return words;
}

const bswap32 = (x) => (((x & 0xff) << 24) | ((x & 0xff00) << 8) |
    ((x >>> 8) & 0xff00) | ((x >>> 24) & 0xff)) >>> 0;

function cs64Digest(data, digest) {
    // Python 侧 digest 是 pack('>8I')，这里按 <II 读 ⇒ 等价于每个字做字节序翻转
    let keyA = BigInt(bswap32(digest[0]));
    let keyB = BigInt(bswap32(digest[1]));
    keyA |= 1n;
    keyB |= 1n;
    const factors = [(keyA * BigInt(CS64_FACTOR)) & MASK, (keyB * BigInt(CS64_FACTOR)) & MASK];

    const terms = CS64_COEFFICIENTS.map(([coef], i) =>
        (BigInt(coef) * factors[i % 2]) & MASK);
    const offsets = CS64_COEFFICIENTS.map(([, off]) => BigInt(off));

    const raw = wordsLe4Even(Uint8Array.from([0, ...data]));
    raw.forEach((word, index) => {
        const w = BigInt(word);
        let term = w * (index % 2 === 0 ? keyA : keyB);
        let offset = BigInt(rol16(word)) *
            (index % 2 === 0 ? 0xef0569fbn : 0xc31713dbn);
        if (index === 0) {
            term += BigInt(CS64_ADJUSTMENT0) * factors[0];
            offset += BigInt(CS64_ADJUSTMENT1);
        }
        terms.push(term & MASK);
        offsets.push(offset & MASK);
    });

    let swapAcc = 0n;
    let swapLast = 0n;
    let state = 0n;
    let acc = 0n;
    for (let i = 0; i < terms.length; i += 2) {
        const x = terms[i];
        const y = terms[i + 1];
        let t = BigInt(rol16(Number((offsets[i] + x) & MASK)));
        let q = (t * 0x76f50f34n) & MASK;
        swapAcc += (BigInt(rol16(Number(q))) * 0xc3efea97n + q) & MASK;
        t = BigInt(rol16(Number((offsets[i + 1] + y) & MASK)));
        q = (t * 0x1881ce3cn) & MASK;
        swapLast = (BigInt(rol16(Number(q))) * 0x35bd1ec9n + q) & MASK;
        swapAcc = (swapAcc + swapLast) & MASK;

        state = (state * keyA + x) & MASK;
        state = (BigInt(rol16(Number(state))) * 0xcf98b111n) & MASK;
        state = (BigInt(rol16(Number(state))) * 0x87085b9fn) & MASK;
        state = (BigInt(rol16(Number(state))) * 0x12ceb96dn) & MASK;
        state = (BigInt(rol16(Number(state))) * 0x257e1d83n) & MASK;
        acc += state;
        t = (state * keyB + y) & MASK;
        t = (BigInt(rol16(Number(t))) * 0xa27416f5n) & MASK;
        t = (BigInt(rol16(Number(t))) * 0xd38396ffn) & MASK;
        state = (BigInt(rol16(Number((BigInt(rol16(Number(t))) * 0x7c932b89n) & MASK))) *
            0xbfa49f69n) & MASK;
        acc = (acc + state) & MASK;
    }
    return [swapLast ^ state, swapAcc ^ acc];
}

function hex8(v) {
    return v.toString(16).padStart(8, '0').toUpperCase();
}

/** 32 位按小端铺成 4 字节，再取两位宽的大写 hex（对应 Python 的 pack('<I')） */
function leHex8(v) {
    const n = Number(v & 0xffffffffn);
    const bytes = [n & 0xff, (n >>> 8) & 0xff, (n >>> 16) & 0xff, (n >>> 24) & 0xff];
    return bytes.map((b) => b.toString(16).padStart(2, '0')).join('').toUpperCase();
}

/** 生成 v2 令牌：`<cs64>-<sha256>` */
export function generateSecMsGec(unixTimestamp) {
    let ticks = unixTimestamp == null ? Date.now() / 1000 : unixTimestamp;
    ticks += WIN_EPOCH;
    ticks -= ticks % 300;
    ticks *= 1e7;
    const str = `${ticks.toFixed(0)}${TRUSTED_CLIENT_TOKEN}`;
    const data = Array.from(Buffer.from(str, 'ascii'));
    const digest = sha256Digest(data);
    const [a, b] = cs64Digest(data, digest);
    // Python: struct.pack("<II", a, b).hex().upper()
    const cs64 = leHex8(a) + leHex8(b);
    const sha = digest.map(hex8).join('');
    return `${cs64}-${sha}`;
}
