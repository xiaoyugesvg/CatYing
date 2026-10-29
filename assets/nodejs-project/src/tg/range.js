// HTTP Range 解析（纯函数，可单测）
// ============================================================
// 为什么要单独一个文件：这段逻辑埋在 `streamTo` 里时**没法验证** ——
// 它决定了 206/Content-Range 的字节区间，错一个字节播放器就"能出画面、
// 然后卡死"。抽出来之后 `node src/tg/range.test.mjs` 能直接跑断言。
//
// 之前（2026-10-29 之前）的写法有三个真缺陷：
//   1. **后缀区间 `bytes=-500`**（要最后 500 字节）被当成 `0-500`，
//      返回的是**开头** 501 字节 —— 播放器拿它找 mp4 的 moov 就会读到垃圾，
//      表现正是「第一帧出来了，然后一直缓冲到超时」。
//   2. `size === 0`（总长未知）时仍然标记 `partial = true`，
//      于是回一个**没有 Content-Range 的 206** —— 违反 RFC 7233，
//      AVPlayer / libmpv 都会认为响应非法而挂住。
//   3. 区间不可满足（`start >= size`）时被夹成"返回 1 个字节"，
//      正确做法是 416，让播放器立刻知道该换请求，而不是拿到错位数据。

/**
 * @typedef {object} RangeSpec
 * @property {number} start   起始偏移（含）
 * @property {number} end     结束偏移（含）
 * @property {number} len     字节数（size 未知时为 0）
 * @property {boolean} partial       是否该回 206
 * @property {boolean} unsatisfiable 区间不可满足 → 该回 416
 */

/**
 * 解析 `Range` 头。
 *
 * @param {string|undefined|null} header 原始头（如 `bytes=0-1023`）
 * @param {number} size 资源总字节数，0 表示未知
 * @returns {RangeSpec}
 */
export function parseRange(header, size) {
    const total = Number.isFinite(size) && size > 0 ? Math.floor(size) : 0;
    /** 整段响应（200） */
    const whole = {
        start: 0,
        end: total > 0 ? total - 1 : 0,
        len: total,
        partial: false,
        unsatisfiable: false,
    };
    if (!header) return whole;

    // 只认 bytes 单位；其它单位（罕见）按 RFC 允许的方式忽略 Range、回整段
    const m = /^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)/i.exec(String(header));
    if (!m) return whole;
    if (m[1] === '' && m[2] === '') return whole;

    // ⚠️ 总长未知时**不能**声称 partial：没有 Content-Range 可写，
    //   回一个 206 就是非法响应（播放器直接挂住）。只能老老实实回 200。
    if (total === 0) return whole;

    let start;
    let end;
    if (m[1] === '') {
        // 后缀区间：bytes=-N ⇒ 最后 N 个字节
        const n = parseInt(m[2], 10);
        if (!Number.isFinite(n) || n <= 0) {
            return { ...whole, unsatisfiable: true };
        }
        start = Math.max(0, total - n);
        end = total - 1;
    } else {
        start = parseInt(m[1], 10);
        end = m[2] === '' ? total - 1 : parseInt(m[2], 10);
    }

    if (!Number.isFinite(start) || !Number.isFinite(end)) return whole;
    if (start < 0) start = 0;
    if (end > total - 1) end = total - 1;
    // 起点越界 / 区间反向 ⇒ 416（不要夹成 1 字节，那是错位数据）
    if (start > end || start >= total) {
        return { ...whole, unsatisfiable: true };
    }
    return {
        start,
        end,
        len: end - start + 1,
        partial: true,
        unsatisfiable: false,
    };
}

/**
 * 单次 `upload.getFile` 要多少字节。
 *
 * 播放器（尤其 AVPlayer）起播前会发 `Range: bytes=0-1` 探一下 —— 只想要
 * **2 字节**。原来固定 256KB ⇒ 为了回 2 字节先从 Telegram 拖 256KB，
 * 慢网下这一下就要好几秒，探流直接超时（用户 2026-10-29「加载出来画面
 * 但播放超时」的其中一环）。这里按实际需要收窄，只留 4KB 下限。
 *
 * @param {number} len 本次要发的字节数（0 = 未知/整段）
 * @param {number} [cap] 单次上限
 */
export function requestSizeFor(len, cap = 256 * 1024) {
    if (!Number.isFinite(len) || len <= 0) return cap;
    return Math.min(cap, Math.max(4096, len));
}
