// ─────────────────────────────────────────────────────────────
// 咪咕音乐（Cookie 版）— MusicFree 插件
//
// 和随包的官方版咪咕插件（混淆、免登录）不同，这一份是**可读源码**，
// 并且把登录态（Cookie / userId）做成插件变量，用来尝试走会员音质。
//
// 已实测可用的部分：
//   · 搜索：`MIGUM2.0/v1.0/content/search_all.do`（返回 songResultData.result）
//   · 歌词：搜索结果里的 `lyricUrl`（OSS 直链文本）
//
// 播放：
//   · 走 `content/sub/listenSong.do`，带 Cookie / userId；
//   · 咪咕对播放接口有设备签名校验（不带签名会返回
//     `{"code":"200002","info":"PE参数格式错误"}`）。
//     所以**能不能播取决于你的 Cookie 是否包含有效的 mtoken / userId**；
//     失败时会抛错，播放器会自动换下一个音源（不会卡住）。
//
// 变量：
//   · miguCookie —— 从 music.migu.cn 登录后复制的整段 Cookie
//   · miguUserId —— 可选，咪咕账号 userId（Cookie 里通常能看到）
// ─────────────────────────────────────────────────────────────

function vars() {
  try {
    if (typeof globalThis !== 'undefined' && globalThis.env) {
      return globalThis.env.getUserVariables() || {};
    }
  } catch (e) {}
  return {};
}

function v(key, fallback) {
  var x = vars()[key];
  return x === undefined || x === null || x === '' ? fallback : String(x);
}

var UA_WEB =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) ' +
  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1';

function headers(extra) {
  var h = {
    'User-Agent': UA_WEB,
    Referer: 'https://music.migu.cn/',
    Origin: 'https://music.migu.cn',
    Accept: 'application/json, text/plain, */*',
  };
  var cookie = v('miguCookie', '');
  if (cookie) h['Cookie'] = cookie;
  if (extra) {
    for (var k in extra) h[k] = extra[k];
  }
  return h;
}

function enc(s) {
  return encodeURIComponent(s == null ? '' : String(s));
}

// ── 搜索 ──────────────────────────────────────────────────────
async function search(keyword, page, type) {
  if (type && type !== 'music' && type !== 'song') {
    return { isEnd: true, data: [] };
  }
  var kw = String(keyword == null ? '' : keyword).trim();
  if (!kw) return { isEnd: true, data: [] };
  var p = parseInt(page, 10);
  if (!p || p < 1) p = 1;
  var size = 20;

  var url =
    'https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do' +
    '?text=' + enc(kw) +
    '&pageNo=' + p +
    '&pageSize=' + size +
    '&isCorrect=1&sort=1' +
    '&searchSwitch=' + enc(JSON.stringify({ song: 1 }));

  var res = await axios.get(url, { headers: headers(), timeout: 15000 });
  var body = res && res.data ? res.data : {};
  if (typeof body === 'string') {
    try { body = JSON.parse(body); } catch (e) { body = {}; }
  }
  var d = body.songResultData || {};
  var arr = d.result || [];
  var total = parseInt(d.totalCount, 10) || 0;

  var out = [];
  for (var i = 0; i < arr.length; i++) {
    var it = arr[i] || {};
    var singers = [];
    if (it.singers && it.singers.length) {
      for (var j = 0; j < it.singers.length; j++) {
        if (it.singers[j] && it.singers[j].name) singers.push(it.singers[j].name);
      }
    }
    var album = '';
    if (it.albums && it.albums.length && it.albums[0]) album = it.albums[0].name || '';
    var pic = '';
    if (it.imgItems && it.imgItems.length) {
      var pick = null;
      for (var k = 0; k < it.imgItems.length; k++) {
        if (it.imgItems[k] && it.imgItems[k].imgSizeType === '02') { pick = it.imgItems[k]; break; }
      }
      pick = pick || it.imgItems[0];
      pic = (pick && pick.img) || '';
    }
    var vip = it.vipType === '1' || it.chargeAuditions === '1';
    out.push({
      // primaryKey：用 copyrightId（同一首歌的不同音质共用一个 copyrightId）
      id: String(it.copyrightId || it.contentId || it.id || ''),
      title: String(it.name || ''),
      artist: singers.join('/'),
      album: String(album),
      artwork: String(pic),
      duration: 0,
      _meta: {
        mediaId: String(it.id || ''),
        contentId: String(it.contentId || ''),
        copyrightId: String(it.copyrightId || ''),
        lyricUrl: String(it.lyricUrl || ''),
        vip: vip,
      },
    });
  }
  return { isEnd: p * size >= total || out.length === 0, data: out };
}

// ── 播放地址 ──────────────────────────────────────────────────
var QUALITY_FLAG = {
  low: 'LQ',
  '128k': 'PQ',
  '320k': 'HQ',
  flac: 'SQ',
  flac24bit: 'ZQ',
};

function pickUrl(body) {
  if (!body) return '';
  if (typeof body === 'string') {
    var t = body.trim();
    if (/^https?:\/\//i.test(t)) return t;
    try { body = JSON.parse(t); } catch (e) { return ''; }
  }
  var cands = [
    body.audioUrl,
    body.url,
    body.playUrl,
    body.data && body.data.audioUrl,
    body.data && body.data.url,
    body.data && body.data.playUrl,
  ];
  for (var i = 0; i < cands.length; i++) {
    if (typeof cands[i] === 'string' && /^https?:\/\//i.test(cands[i])) return cands[i];
  }
  return '';
}

async function getMediaSource(musicItem, quality) {
  var m = (musicItem && musicItem._meta) || {};
  var flag = QUALITY_FLAG[String(quality || '320k')] || 'HQ';
  var mediaId = m.mediaId || String((musicItem && musicItem.id) || '');
  var copyrightId = m.copyrightId || '';
  var contentId = m.contentId || '';
  if (!mediaId && !copyrightId) throw new Error('咪咕：缺少歌曲 id');

  var userId = v('miguUserId', '');
  var qs =
    'toneFlag=' + flag +
    '&netType=00' +
    '&userId=' + enc(userId) +
    '&ua=Android_migu' +
    '&version=6.0.4' +
    '&mediaId=' + enc(mediaId) +
    '&copyrightId=' + enc(copyrightId) +
    '&contentId=' + enc(contentId) +
    // channel 必填：0140001 = 咪咕音乐 Android 渠道（填 0 会报 PE 参数错误）
    '&resourceType=2&channel=0140001';

  var urls = [
    'https://app.c.nf.migu.cn/MIGUM3.0/v1.0/content/sub/listenSong.do?' + qs,
    'https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/sub/listenSong.do?' + qs,
  ];

  var lastMsg = '';
  for (var i = 0; i < urls.length; i++) {
    try {
      var res = await axios.get(urls[i], {
        headers: headers({
          ua: 'Android_migu',
          version: '6.0.4',
          channel: '0140001',
        }),
        timeout: 15000,
      });
      var u = pickUrl(res && res.data);
      if (u) return { url: u, headers: {} };
      var b = res && res.data;
      if (b && typeof b === 'object') lastMsg = String(b.info || b.code || '');
    } catch (e) {
      lastMsg = String((e && e.message) || e);
    }
  }
  throw new Error(
    '咪咕 Cookie 版拿不到播放地址' + (lastMsg ? '（' + lastMsg + '）' : '') +
    '；请确认 miguCookie 里有有效的登录态，或改用随包的「咪咕音乐」'
  );
}

// ── 歌词 ──────────────────────────────────────────────────────
async function getLyric(musicItem) {
  var m = (musicItem && musicItem._meta) || {};
  var u = m.lyricUrl || '';
  if (!u) return { lyric: '' };
  try {
    var res = await axios.get(u, { headers: headers(), timeout: 12000 });
    return { lyric: String((res && res.data) || '') };
  } catch (e) {
    return { lyric: '' };
  }
}

module.exports = {
  platform: '咪咕音乐',
  name: '咪咕音乐（Cookie 版）',
  version: '1.0.0',
  srcUrl: 'https://github.com/xiaoyugesvg/CatYing',
  author: 'CatYing',
  description:
    '可填咪咕登录 Cookie 的咪咕音乐插件：搜索 / 歌词走公开接口，播放走 listenSong（带 Cookie）。' +
    '咪咕对播放接口有设备签名校验，若 Cookie 里没有有效 mtoken，可能只能播免费曲目。',
  primaryKey: ['id'],
  supportedSearchType: ['music'],
  supportedQualities: ['128k', '320k', 'flac', 'flac24bit'],
  cacheControl: 'no-cache',
  userVariables: [
    {
      key: 'miguCookie',
      name: '咪咕 Cookie',
      hint:
        '电脑浏览器打开 music.migu.cn 并登录，F12 → Network → 任意请求 → 复制完整 Cookie；' +
        '重点是要包含登录票据（如 mtoken / userId）。不填只能播免费曲目。',
    },
    {
      key: 'miguUserId',
      name: '咪咕 userId（可选）',
      hint: 'Cookie 里形如 userId=1234567 的那串数字；填了会一起带给播放接口。',
    },
  ],
  search: search,
  getMediaSource: getMediaSource,
  getLyric: getLyric,
};
