import 'dart:convert';

/// 出厂内置书源（首次启动播种一次；用户删除后不再自动恢复）。
///
/// 目前只有一条：**看漫画（m.manhuagui.com）** 的 Legado 漫画源。
/// 规则**原样保留**（扁平字段 + `@js:` 解码器 + `@Header:`），由 Node
/// 书源引擎执行：扁平字段归一化、`searchKey/searchPage`、目录 `-` 倒序、
/// `@js:` 里的 `||`、`@Header` 图片请求头都已支持。
///
/// 为什么用 JSON 文本而不是 Dart Map：规则里大量正则/引号/反斜杠，
/// 直接保留源文件原文最不容易在转写时改坏（raw string 不做任何转义）。
const String kBuiltinBookSourcesJson = r'''[
  {
    "bookSourceName": "看漫画",
    "bookSourceUrl": "https://m.manhuagui.com",
    "bookSourceGroup": "漫画",
    "bookSourceType": "漫画",
    "enabled": true,
    "customOrder": -100,
    "sourceRemark": "看漫画手机版（内置）",
    "weight": 1000,
    "httpUserAgent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36",
    "ruleSearchUrl": "https://m.manhuagui.com/s/searchKey.html",
    "ruleSearchList": "[id=detail] li",
    "ruleSearchName": "h3@text",
    "ruleSearchCoverUrl": "img@data-src",
    "ruleSearchNoteUrl": "a@href",
    "ruleBookName": ".main-bar h1@text",
    "ruleCoverUrl": ".book-detail .thumb img@src",
    "ruleBookAuthor": "a[href^='/author/']@text",
    "ruleIntroduce": "[id=bookIntro]@text",
    "ruleChapterUrl": "",
    "ruleChapterList": "-.chapter-list li a",
    "ruleChapterName": "b@text",
    "ruleContentUrl": "href",
    "ruleBookContent": "@js:// ================= manhuagui 阅读页解码器 =================\n// 阅读页里那段 packer 是**诱饵**（第 4 个参数用 '…'['splic'](...)，浏览器里也会抛错），\n// 真数据是 packer 的第 1 个参数（payload）+ 第 4 个参数（lz-string 压缩的关键字表）。\n// 流程：lz-string 解压关键字表 → 按 | 切开 → 生成 token 字典 → 替换 payload 里的 token\n//       → 得到 SMH.imgData({...}) / SMH.reader({...})，里面就有 files/path/images 和签名 e/m。\n// 参考实现：github.com/lanyeeee/manhuagui-downloader-wails 的 backend/decoder/decoder.go\nfunction mhgDecode(s) {\n  var m = s.match(/}\\('([\\s\\S]*?)',(\\d+),(\\d+),'([\\w|+\\/=]*)'/);\n  if (!m) return [];\n  var payload = m[1], a = parseInt(m[2], 10), c = parseInt(m[3], 10), blob = m[4];\n  var K = \"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=\", rev = {}, q;\n  for (q = 0; q < K.length; q++) rev[K.charAt(q)] = q;\n\n  function lz(b) {\n    var dic = [], enl = 4, ds = 4, nb = 3, entry = \"\", res = [], w, x, d, rv;\n    d = { v: rev[b.charAt(0)] || 0, p: 32, i: 1 };\n    for (q = 0; q < 3; q++) dic[q] = q;\n    function rb(n) {\n      var t = 0, mm = Math.pow(2, n), pp = 1;\n      while (pp != mm) {\n        rv = d.v & d.p;\n        d.p >>= 1;\n        if (d.p == 0) { d.p = 32; d.v = rev[b.charAt(d.i++)] || 0; }\n        t += (rv > 0 ? 1 : 0) * pp;\n        pp <<= 1;\n      }\n      return t;\n    }\n    x = rb(2);\n    if (x == 0) { w = String.fromCharCode(rb(8)); }\n    else if (x == 1) { w = String.fromCharCode(rb(16)); }\n    else { return \"\"; }\n    dic[3] = w;\n    res.push(w);\n    while (true) {\n      if (d.i > b.length) return \"\";\n      x = rb(nb);\n      if (x == 0) { dic[ds] = String.fromCharCode(rb(8)); x = ds; ds++; enl--; }\n      else if (x == 1) { dic[ds] = String.fromCharCode(rb(16)); x = ds; ds++; enl--; }\n      else if (x == 2) return res.join(\"\");\n      if (enl == 0) { enl = Math.pow(2, nb); nb++; }\n      entry = dic[x] ? dic[x] : (x == ds ? w + w.charAt(0) : null);\n      if (entry === null) return \"\";\n      res.push(entry);\n      dic[ds] = w + entry.charAt(0);\n      ds++;\n      enl--;\n      w = entry;\n      if (enl == 0) { enl = Math.pow(2, nb); nb++; }\n    }\n  }\n\n  var plain = lz(blob);\n  if (!plain) return [];\n  var data = plain.split(\"|\");\n  function ee(n) {\n    var cc = n % a;\n    var ch = (cc > 35 ? String.fromCharCode(cc + 29) : cc.toString(36));\n    if (n < a) return ch;\n    return ee(parseInt(n / a, 10)) + ch;\n  }\n  var dict = {}, i, kk;\n  for (i = c - 1; i >= 0; i--) {\n    kk = ee(i);\n    dict[kk] = (data[i] === \"\" || data[i] === undefined) ? kk : data[i];\n  }\n  var out = payload.replace(/\\b\\w+\\b/g, function (t) {\n    return dict[t] !== undefined ? dict[t] : t;\n  });\n\n  var pe = out.match(/\"e\":(\\d+)/), pm = out.match(/\"m\":\"([^\"]*)\"/);\n  if (!pe || !pm) return [];\n  var paths = [], im = out.match(/\"images\":\\[([^\\]]*)\\]/), pt = out.match(/\"path\":\"([^\"]*)\"/), fl;\n  if (im) {\n    paths = im[1].replace(/\"/g, \"\").split(\",\");\n  } else if (pt) {\n    fl = out.match(/\"files\":\\[([^\\]]*)\\]/);\n    if (!fl) return [];\n    fl = fl[1].replace(/\"/g, \"\").split(\",\");\n    for (i = 0; i < fl.length; i++) paths.push(pt[1] + fl[i]);\n  } else {\n    return [];\n  }\n  var urls = [];\n  for (i = 0; i < paths.length; i++) {\n    // 路径里的中文要转义，但已经 %XX 过的部分不能二次转义 —— 所以只动非 ASCII\n    var p = paths[i].replace(/[^\\x00-\\x7F]/g, function (ch) { return encodeURIComponent(ch); });\n    urls.push(\"https://i.hamreus.com\" + p + \"?e=\" + pe[1] + \"&m=\" + pm[1]);\n  }\n  return urls;\n}\nmhgDecode(String(result))@Header:{\"Referer\": \"https://m.manhuagui.com/\", \"User-Agent\": \"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36\"}",
    "ruleFindUrl": "最近更新::https://m.manhuagui.com/update/?page=searchPage\n排行榜::https://m.manhuagui.com/rank/\n全部漫画::https://m.manhuagui.com/list/?page=searchPage\n日本漫画::https://m.manhuagui.com/list/japan/?page=searchPage\n韩国漫画::https://m.manhuagui.com/list/korea/?page=searchPage\n港台漫画::https://m.manhuagui.com/list/hongkong/?page=searchPage\n内地漫画::https://m.manhuagui.com/list/china/?page=searchPage"
  },
  {
    "bookSourceName": "漫小肆韓漫🔞",
    "bookSourceUrl": "https://www.jjmhw9.top",
    "bookSourceGroup": "18🈲",
    "bookSourceType": "漫画",
    "enabled": true,
    "customOrder": -90,
    "sourceRemark": "韩漫聚合站（内置）",
    "weight": 1000,
    "httpUserAgent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36",
    "ruleSearchUrl": "https://www.jjmhw9.top/search?keyword=searchKey",
    "ruleSearchList": ".mh-item",
    "ruleSearchName": "a@title",
    "ruleSearchCoverUrl": ".mh-cover@style@js:(String(result).match(/url\\(([^)]+)\\)/)||[])[1]||''",
    "ruleSearchNoteUrl": "a@href",
    "ruleBookName": "h1@text",
    "ruleCoverUrl": ".banner_detail_form .cover img@src",
    "ruleBookAuthor": "class.subtitle.1@text@js:result.replace('作者：','')",
    "ruleBookKind": "class.ticai@text@js:result.replace('地区：','')",
    "ruleIntroduce": ".banner_detail_form .content@text",
    "ruleChapterUrl": "",
    "ruleChapterList": ".detail-list-select a",
    "ruleChapterName": "text",
    "ruleContentUrl": "href",
    "ruleBookContent": ".comiclist img@data-original",
    "ruleFindUrl": "最近更新::https://www.jjmhw9.top/update?page=searchPage\n排行榜::https://www.jjmhw9.top/rank\n全部漫画::https://www.jjmhw9.top/booklist?page=searchPage\n连载中::https://www.jjmhw9.top/booklist?end=0&page=searchPage\n已完结::https://www.jjmhw9.top/booklist?end=1&page=searchPage\n韩国漫画::https://www.jjmhw9.top/booklist?area=1&page=searchPage\n日本漫画::https://www.jjmhw9.top/booklist?area=2&page=searchPage"
  }
]''';

/// 解析内置书源 JSON（失败返回空列表，绝不阻断启动）。
List<Map<String, dynamic>> decodeBuiltinBookSources() {
  try {
    final decoded = jsonDecode(kBuiltinBookSourcesJson);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList(growable: false);
  } catch (_) {
    return const [];
  }
}
