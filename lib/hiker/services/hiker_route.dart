/// 「海阔」链接协议分流 —— **依据海阔官方源码与官方文档**建立。
///
/// 权威来源（本机 hikerView 开源副本）：
///   · `ui/home/ArticleListFragment.java` → `dealWithUrl()`：点条目后的**分流顺序**
///   · `ui/browser/model/UrlDetector.java` → `isImage()` / `isVideoOrMusic()`：判定规则
///   · `app/src/main/assets/help_link.json` → 官方**全部链接协议**清单
///
/// ── 为什么必须单独一层（这是本轮查出来的真实缺口）────────────────
/// 海阔的"播放地址"**根本不只有 http 视频**，官方 `help_link.json` 里明确还有：
///   · `pics://图1&&图2`   —— 多图模式（类似漫画），下拉自动下一章
///   · `toast://文本`      —— 只弹提示
///   · `copy://内容`       —— 复制到剪贴板
///   · `x5Play://http://…` —— 强制用播放器播
///   · `video://https://…` —— 进播放器自动提取视频
///   · `javascript:…` / `web://` / `x5://` —— 各种网页
/// 之前我们只有"直链 / 网页"两分支，于是漫画、小说、提示类条目一律被丢给
/// WebView，表现就是**打开是一片空白或一堆乱码**。
///
/// ── 单一事实来源 ────────────────────────────────────────────
/// 图片列表（`pics://`）与正文（`novel://`）的解析**复用影视侧同一实现**
/// （`play_route.parseImageListUrl` / `parseNovelUrl`），不在这里再写一份，
/// 避免两边漂移。
library;

import 'dart:convert';

import 'package:tvbox/services/play_route.dart' as play_route;
import 'package:tvbox/services/sniff_filter.dart';

/// 链接类别 —— 与官方 [dealWithUrl] 的分支一一对应（顺序也照抄官方）。
enum HikerLinkKind {
  /// `hiker://…` 官方内部页面（二级页面 / 设置 / 搜索 / 收藏…），本模块不支持跳转
  hikerPage,

  /// `hiker://search?rule=<源名>&s=<关键词>` —— 官方「在某个源里搜索」的深链。
  ///
  /// 实测「聚阅√」这类聚合源的首页搜索框 / 条目地址就是它（
  /// `return "hiker://search?rule=" + r + "&s=" + input`）。
  /// 以前一律当 `hikerPage` ⇒ 点了只弹「海阔内部页面，本版不支持」，
  /// 用户看到的就是「没抓到直链，反而给出一个内置搜索链接」。
  search,

  /// `javascript:` 官方叫"彩蛋模式"，点击后跳浏览器执行这段 JS
  js,

  /// `pics://图1&&图2` 多图模式（类似漫画）
  pics,

  /// `novel://{title,content}` 正文（项目内 TVBox 约定，与 pics 同一层处理）
  novel,

  /// 图片地址（官方 `UrlDetector.isImage` 的后缀集合）→ 图集/大图预览
  image,

  /// 影视直链（当前生效清单，见 [SniffFilter.isDirectMedia]）→ 原生播放器
  media,

  /// 海阔的**播放地址 JSON**（`{"urls":[…],"headers":{…}}`）—— 见 [hikerPlayJson]。
  /// 里面可能是直链（→ 播放器）也可能是网页（→ 内嵌 WebView）。
  playJson,

  /// `x5://` / `x5WebView://` —— X5 全屏网页
  x5,

  /// `web://` —— 强制网页，忽略二级解析规则
  web,

  /// `x5Play://http://…` —— 强制用播放器播该地址
  x5Play,

  /// `video://https://…` —— 官方行为是进播放器**自动提取**网页里的视频
  videoSniff,

  /// `toast://文本` —— 只弹提示
  toast,

  /// `copy://内容` —— 复制到剪贴板
  copyLink,

  /// `download://http://…` —— 直接下载
  download,

  /// `magnet:` / `thunder` / `ftp` / `ed2k` —— 交给第三方软件
  external,

  /// `.apk` 安装包
  apk,

  /// 普通 http(s) 网页
  http,

  /// 官方兜底也是 `Toast("未知链接：" + url)`
  unknown,
}

/// 官方 `UrlDetector` 的**图片后缀**集合（原样照抄，含它的大小写重复项）。
///
/// ⚠️ 与 [SniffFilter.mediaExtensions] **不重叠**：那是"影视直链"（视频+音频，
/// 用户可自定义）；这里只判"这是不是一张图"，用来决定进图集阅读器还是播放器。
const List<String> kHikerImageExtensions = [
  '.ico',
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
];

/// 该地址是不是图片（官方 `UrlDetector.isImage` 的等价实现）。
///
/// 官方这里有三个前置守卫，照抄：
///   · `x5Play://` 开头 → 不是图片（那是强制播放）
///   · 含 `@rule=` / `@lazyRule=` → 不是图片（那是规则入口，要等规则求值）
///   · 含 `ignoreImg=true` → 主动声明不是图片
bool hikerIsImageUrl(String url) {
  final s = url.trim();
  if (s.isEmpty) return false;
  final lower = s.toLowerCase();
  if (lower.startsWith('x5play://')) return false;
  if (s.contains('@rule=') || s.contains('@lazyRule=')) return false;
  if (s.contains('ignoreImg=true')) return false;
  for (final ext in kHikerImageExtensions) {
    if (lower.contains(ext)) return true;
  }
  return false;
}

/// 多图/漫画链接（`pics://图1&&图2`）→ 图片列表；不是则 null。
///
/// 官方文档原文：
///   「即 pics:// 开头，后面为多张图片地址用 && 连接；
///     视界将会识别为多图模式（类似漫画），下拉会尝试执行下一集的动态解析」
/// 解析复用影视侧同一实现（也兼容 `mange://` 等同族写法）。
List<String>? hikerPicList(String url) => play_route.parseImageListUrl(url);

/// 正文链接（`novel://{title,content}`）→ (标题, 正文)；不是则 null。
({String title, String content})? hikerNovelContent(String url) =>
    play_route.parseNovelUrl(url);

/// 海阔的**播放地址 JSON** —— 官方的播放约定，长这样：
///   `{"urls":["https://hls…/index.m3u8","备用"],"names":["HLS"],
///     "headers":{"Referer":"…"},"parse":0}`
///
/// ⚠️ 以前只在**整条规则的返回值**里解析它（引擎侧），**列表条目**里的这坨 JSON
/// 会原样透到详情页 ⇒ 既不是 http 也不是任何已知协议 ⇒ 被判成"未知链接"，
/// 详情页上一排「提示」按钮点了没反应（用户 2026-10-16 的截图：
/// 选集 1/2/3 的地址就是 `{"urls":["https://hls.tpbbwcc.cn/…m3u8"]}`）。
///
/// 返回 (urls, headers)；不是播放 JSON 则 null。
({List<String> urls, Map<String, String> headers})? hikerPlayJson(String raw) {
  final s = raw.trim();
  if (!s.startsWith('{') || !s.contains('"urls"')) return null;
  try {
    final j = jsonDecode(s);
    if (j is! Map) return null;
    final urls = <String>[];
    final rawUrls = j['urls'];
    if (rawUrls is List) {
      for (final u in rawUrls) {
        final t = u.toString().trim();
        if (t.isNotEmpty) urls.add(t);
      }
    } else if (j['url'] != null) {
      final t = j['url'].toString().trim();
      if (t.isNotEmpty) urls.add(t);
    }
    if (urls.isEmpty) return null;
    final headers = <String, String>{};
    final h = j['headers'];
    if (h is Map) {
      h.forEach((k, v) => headers[k.toString()] = v.toString());
    }
    return (urls: urls, headers: headers);
  } catch (_) {
    return null;
  }
}

/// 拆 `hiker://search?rule=<源名>&s=<关键词>`（官方「在某个源里搜索」深链）。
///
/// 参数名兼容：`rule` / `source` / `title` 指定源；`s` / `keyword` / `q` / `wd`
/// 指定关键词。没有关键词时返回空串（调用方打开搜索页让用户输入）。
/// 不是 `hiker://search` 则返回 null（普通 `hiker://` 内部页继续走 [HikerLinkKind.hikerPage]）。
({String rule, String keyword})? parseHikerSearchUrl(String raw) {
  final s = raw.trim();
  final lower = s.toLowerCase();
  const prefix = 'hiker://search';
  if (!lower.startsWith(prefix)) return null;
  // 严格一点：`hiker://searching…` 之类不是搜索深链
  final rest = s.substring(prefix.length);
  if (rest.isNotEmpty &&
      !rest.startsWith('?') &&
      !rest.startsWith('&') &&
      !rest.startsWith('#') &&
      !rest.startsWith('/')) {
    return null;
  }
  // 用正则而不是 Uri.queryParameters：源里常有**未编码的中文/空格/√**，
  // Uri 解析失败会整条丢掉（关键词就没了）。
  final q = s.contains('?') ? s.substring(s.indexOf('?') + 1) : '';
  String pick(List<String> keys) {
    for (final k in keys) {
      final m = RegExp('(?:^|&)${RegExp.escape(k)}=([^&]*)').firstMatch(q);
      if (m == null) continue;
      String v = m.group(1) ?? '';
      try {
        v = Uri.decodeComponent(v);
      } catch (_) {
        /* 不是合法百分号编码 → 原文 */
      }
      v = v.trim();
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  return (
    rule: pick(const ['rule', 'source', 'title']),
    keyword: pick(const ['s', 'keyword', 'q', 'wd']),
  );
}

/// 按官方 `dealWithUrl()` 的**判定顺序**给链接分类。
///
/// 顺序不能乱 —— 官方就是按这个顺序短路返回的：
///   hiker:// → javascript: → x5:// → web:// → pics:// → 图片 → 直链 → …
/// 例如 `pics://https://a.com/1.jpg` 必须**先**命中 pics（它是多图），
/// 若先判图片后缀就会退化成"单张大图预览"。
HikerLinkKind hikerLinkKind(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return HikerLinkKind.unknown;
  final lower = s.toLowerCase();

  // ① 官方内部页面（搜索深链单独一支 —— 本模块能真的打开它）
  if (parseHikerSearchUrl(s) != null) return HikerLinkKind.search;
  if (lower.startsWith('hiker://')) return HikerLinkKind.hikerPage;

  // ② 彩蛋模式（一段 JS，官方跳浏览器执行）
  if (lower.startsWith('javascript:')) return HikerLinkKind.js;

  // ③ X5 全屏 / 刷新式 X5
  if (lower.startsWith('x5://') || lower.startsWith('x5webview://')) {
    return HikerLinkKind.x5;
  }

  // ④ 强制网页（忽略二级解析规则）
  if (lower.startsWith('web://')) return HikerLinkKind.web;

  // ⑤ 多图模式（类似漫画）—— 必须排在"图片"之前
  if (hikerPicList(s) != null) return HikerLinkKind.pics;

  // ⑥ 正文（小说源约定，与 pics 同一层）
  final novel = hikerNovelContent(s);
  if (novel != null && novel.content.trim().isNotEmpty) {
    return HikerLinkKind.novel;
  }

  // ⑥' 播放地址 JSON —— 必须排在"图片"之前：里面那个 url 可能是 `…/1.jpg`，
  //     先判图片就会把一坨播放 JSON 当成单张大图。
  if (hikerPlayJson(s) != null) return HikerLinkKind.playJson;

  // ⑦ 提示 / 复制 / 下载 / 选择框这类"无页面"协议
  if (lower.startsWith('toast://')) return HikerLinkKind.toast;
  if (lower.startsWith('copy://')) return HikerLinkKind.copyLink;
  if (lower.startsWith('confirm://') ||
      lower.startsWith('input://') ||
      lower.startsWith('select://')) {
    // 官方是弹原生对话框；本模块没有对应交互，按"提示原文"处理，至少不静默
    return HikerLinkKind.toast;
  }
  if (lower.startsWith('download://')) return HikerLinkKind.download;

  // ⑧ 强制播放 / 自动提取视频
  if (lower.startsWith('x5play://')) return HikerLinkKind.x5Play;
  if (lower.startsWith('video://')) return HikerLinkKind.videoSniff;

  // ⑨ 图片（官方 UrlDetector.isImage）
  if (hikerIsImageUrl(s)) return HikerLinkKind.image;

  // ⑩ 影视直链 → 原生播放器（全项目唯一事实来源）
  if (SniffFilter.isDirectMedia(s)) return HikerLinkKind.media;

  // ⑩' 音频直链（音乐源）：影视清单之外的 [kAudioExtensions] 补判 —— 与
  //     `parse_service._isDirectMedia` / `detail/view` 是**同一口径**
  //     （那两处也是这么补的，别在这里自创第三种写法）。
  final path = Uri.tryParse(s)?.path.toLowerCase() ?? '';
  for (final ext in play_route.kAudioExtensions) {
    if (path.endsWith(ext)) return HikerLinkKind.media;
  }

  // ⑪ 交给第三方软件
  if (lower.startsWith('magnet:') ||
      lower.startsWith('thunder') ||
      lower.startsWith('ftp:') ||
      lower.startsWith('ed2k:')) {
    return HikerLinkKind.external;
  }

  // ⑫ 安装包
  if (lower.startsWith('http') && lower.split('?').first.endsWith('.apk')) {
    return HikerLinkKind.apk;
  }

  // ⑬ 普通网页
  if (lower.startsWith('http') || lower.startsWith('file://')) {
    return HikerLinkKind.http;
  }

  return HikerLinkKind.unknown;
}

/// 去掉官方"外壳协议"得到真实地址；没有外壳则原样返回。
///
///   · `x5Play://http://a.com/1.mp4` → `http://a.com/1.mp4`（官方=强制播放它）
///   · `video://https://a.com/p.html` → `https://a.com/p.html`
///   · `x5://` / `x5WebView://` / `web://` → 里面的 http 地址
String hikerStripScheme(String url) {
  final s = url.trim();
  final lower = s.toLowerCase();
  for (final p in const [
    'x5play://',
    'x5webview://',
    'x5://',
    'web://',
    'video://',
    'download://',
  ]) {
    if (lower.startsWith(p)) return s.substring(p.length);
  }
  return s;
}

/// 取协议体（`toast://文本` → `文本`，`copy://内容.js:'x'` → `内容`）
String _hikerPayloadOf(String url) {
  final i = url.indexOf('://');
  var body = i >= 0 ? url.substring(i + 3) : url;
  // 官方的 `copy://内容.js:'…'` 尾巴要去掉
  final dot = body.indexOf(".js:");
  if (dot >= 0) body = body.substring(0, dot);
  return body;
}

/// 剥掉海阔条目地址上的 **`@Referer=…`** 尾巴。
///
/// 海阔里给条目拼 `'…/1.jpg' + '@Referer='` 是「加载这张图时带上来源页 Referer」的
/// 约定（空值 = 用所在页面地址）。直接拿去下载会把 `@Referer=` 当成 URL 的一部分，
/// 表现为**整章图片全部加载失败**。返回 (纯地址, 显式 Referer)。
({String url, String referer}) splitHikerReferer(String raw) {
  final s = raw.trim();
  const mark = '@Referer=';
  final i = s.lastIndexOf(mark);
  if (i < 0) return (url: s, referer: '');
  return (
    url: s.substring(0, i).trim(),
    referer: s.substring(i + mark.length).trim(),
  );
}

/// 条目地址里的**内联规则**：`真实地址#flags#@rule=js:<code>` / `@lazyRule=.js:<code>`。
///
/// 这是海阔「二级页面」的另一种主要写法（漫画/短剧源最常用）：页面不是独立模块，
/// 而是把 JS 直接挂在条目地址尾巴上。实测「漫小肆」：
///   漫画条目 → `https://site/manga/123#immersiveTheme##autoCache#@rule=js:$.require("er")`
///   章节条目 → `https://site/chapter/1 + $('').lazyRule(fn)`（这个仍走 lazy 链路）
class HikerInlineRule {
  /// 去掉 flag 与 `@rule=` 尾巴后的**真实地址**（规则里的 `MY_URL` / `input`）
  final String base;

  /// JS 正文（可能还带 `.js:` 前缀，引擎侧会再剥一次）
  final String code;

  /// `@lazyRule=`（点开才执行）还是 `@rule=`（打开即执行）——
  /// 对详情页入口来说两者都是"点进来了就执行"，仅用于文案区分。
  final bool lazy;

  const HikerInlineRule(this.base, this.code, {this.lazy = false});
}

/// 从条目地址里拆出内联规则；没有则 null。
HikerInlineRule? splitHikerInlineRule(String url) {
  final lazyIdx = url.indexOf('@lazyRule=');
  final ruleIdx = url.indexOf('@rule=');
  var idx = -1;
  var lazy = false;
  if (lazyIdx >= 0 && (ruleIdx < 0 || lazyIdx <= ruleIdx)) {
    idx = lazyIdx;
    lazy = true;
  } else if (ruleIdx >= 0) {
    idx = ruleIdx;
  }
  if (idx < 0) return null;
  final code = url
      .substring(idx + (lazy ? '@lazyRule='.length : '@rule='.length))
      .trim();
  if (code.isEmpty) return null;
  // 去掉海阔的 flag 尾巴（`#immersiveTheme##autoCache#` / `#noHistory#`）——
  // 它们是**指令**，不是 URL 的一部分，留着会让 MY_URL / 缓存键全带脏尾巴
  var base = url.substring(0, idx).trim();
  base = base.replaceFirst(RegExp(r'(?:#[A-Za-z][A-Za-z0-9_]*#)+$'), '').trim();
  return HikerInlineRule(base, code, lazy: lazy);
}

/// 把地址翻成**人话 + 它到底是什么内容**（详情页「地址」行与候选卡片都用它）。
///
/// 用户 2026-10-16：「上面的地址就有问题……点击取地址获取也不是我真正想要的，
/// 图片、正文、视频直链等等」——
/// `hiker://lazy#14uwff4`、`{"urls":[…]}` 这些都是**中间态**，直接印在界面上
/// 等于什么都没说。这里统一翻成「类型 + 真内容」：
///   图片 → 共 N 张图｜正文 → 共 N 字｜视频 → 真直链｜网页 → 剥壳后的地址。
({String kind, String detail}) describeHikerLink(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return (kind: '空', detail: '这一步没有地址');
  if (s.startsWith('hiker://empty')) {
    // 老写法 `hiker://empty##<地址>##<规则>`：把中间那段真地址露出来
    final parts = s.split('##').where((x) => x.isNotEmpty);
    final inner = parts.firstWhere(
      (x) => x.startsWith('http') || x.startsWith('x5://'),
      orElse: () => '',
    );
    return (
      kind: '提示',
      detail: inner.isEmpty ? '这一步只有文字说明，没有可打开的内容' : inner,
    );
  }
  if (s.startsWith('hiker://lazy#')) {
    return (kind: '延迟规则', detail: '源把 JS 放在地址里，点一次才算得出真地址');
  }
  // 条目地址自带内联规则（`… #flags#@rule=js:…`）：别把整段 JS 印到界面上
  if (s.contains('@rule=') || s.contains('@lazyRule=')) {
    return (kind: '内联规则', detail: '点一下执行源里的 JS（排序 / 切换线路等）');
  }
  switch (hikerLinkKind(s)) {
    case HikerLinkKind.pics:
      final n = hikerPicList(s)?.length ?? 0;
      return (
        kind: '图片列表',
        detail: n > 0 ? '共 $n 张图' : '图片列表（但解析不出图）',
      );
    case HikerLinkKind.image:
      return (kind: '图片', detail: hikerStripScheme(s));
    case HikerLinkKind.novel:
      final c = hikerNovelContent(s)?.content ?? '';
      return (kind: '正文', detail: '共 ${c.length} 字');
    case HikerLinkKind.media:
      return (kind: '视频直链', detail: s);
    case HikerLinkKind.playJson:
      final j = hikerPlayJson(s);
      final u = (j != null && j.urls.isNotEmpty) ? j.urls.first : '';
      return (kind: '播放 JSON', detail: u.isEmpty ? s : u);
    case HikerLinkKind.x5Play:
      return (kind: '视频（强制播放器）', detail: hikerStripScheme(s));
    case HikerLinkKind.videoSniff:
      return (kind: '视频（需嗅探）', detail: hikerStripScheme(s));
    case HikerLinkKind.x5:
    case HikerLinkKind.web:
      return (kind: '网页', detail: hikerStripScheme(s));
    case HikerLinkKind.toast:
      return (kind: '提示', detail: _hikerPayloadOf(s));
    case HikerLinkKind.copyLink:
      return (kind: '复制内容', detail: _hikerPayloadOf(s));
    case HikerLinkKind.js:
      return (kind: '脚本', detail: '需要浏览器执行这段 JS');
    case HikerLinkKind.hikerPage:
      return (kind: '海阔内部页', detail: '官方内部页面，本版不支持打开');
    case HikerLinkKind.search:
      final sp = parseHikerSearchUrl(s);
      final kw = sp?.keyword ?? '';
      final rule = sp?.rule ?? '';
      final where = rule.isEmpty ? '全源' : rule;
      return (
        kind: '搜索',
        detail: kw.isEmpty ? '在「$where」里搜索' : '在「$where」里搜索「$kw」',
      );
    default:
      return (kind: '其它', detail: s);
  }
}

/// 单行文案版（详情页顶部「地址」行）：`类型 · 真内容`
String describeHikerLinkText(String raw) {
  final d = describeHikerLink(raw);
  return d.detail.isEmpty ? d.kind : '${d.kind} · ${d.detail}';
}
