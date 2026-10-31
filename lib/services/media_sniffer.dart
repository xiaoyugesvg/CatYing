import 'dart:convert';

/// 网页媒体**嗅探**（从播放页里把真正的媒体地址挖出来）。
///
/// ── 解决什么问题 ──────────────────────────────────────────────
/// 很多源的播放地址是一个**网页**（`https://xxx.com/play/123.html`），
/// 页面里再用 JS 拼出 m3u8 交给 `<video>`。这种地址丢给播放器只能当网页开，
/// 一旦页面有广告 / 需要点击 / 弹层，就卡在那。
///
/// 这里给网页播放页加一层"嗅探"：注入一段脚本钩住 XHR / fetch、
/// 监听 DOM 与 `performance` 资源，把出现的媒体地址收集起来，
/// 再按「m3u8 > mpd > mp4」排序推荐一个。
///
/// ── 为什么不做网络层抓包 ──────────────────────────────────────
/// 本项目用 `webview_flutter`，没有 `shouldInterceptRequest` 之类的能力，
/// 所以只能在页面内注入 JS 采集 —— 与参考实现（huoyi 的 MediaSniffer）同一思路。
class MediaSniffer {
  MediaSniffer._();

  /// 媒体地址正则（m3u8 / mpd / mp4 / m4v / mov / flv / m4s）
  static final RegExp mediaUrlPattern = RegExp(
    r'''https?://[^\s"'<>\\]+?\.(?:m3u8|mpd|mp4|m4v|mov|flv|m4s)(?:\?[^\s"'<>\\]*)?''',
    caseSensitive: false,
  );

  /// `hlsUrl: "https://..."` / `source = 'https://...'` 这类赋值写法
  static final RegExp _assignmentPattern = RegExp(
    r'''(?:hlsUrl|source|videoUrl|playUrl|url)\s*[:=]\s*["'](https?://[^"']+)["']''',
    caseSensitive: false,
  );

  /// 页面型路径（`.html` / `.htm` / `.shtml`）—— 这些**永远不是**媒体文件。
  ///
  /// 为什么必须单独判：大量 CMS 的播放器 iframe 长这样
  ///   `https://x.com/static/player/artplayer.html?url=https%3A%2F%2Fcdn%2Fa%2Findex.m3u8`
  /// 整个 URL 结尾正好是 `.m3u8`，[mediaUrlPattern] 会当成媒体直链 —— 但它
  /// 是个 HTML 页，交给播放器必挂。实测 `szctv.com` 就是这样被误判的。
  ///
  /// 只列 html/htm/shtml，**不含 `.php`**：`get.php?f=a.m3u8` 这类
  /// 「脚本出口 + 参数指文件」是真实存在的媒体地址，不能一刀切。
  static final RegExp _pagePathPattern =
      RegExp(r'\.(?:html?|shtml)$', caseSensitive: false);

  static bool looksLikePlayerPage(String url) {
    final path = url.toLowerCase().split('?').first.split('#').first;
    return _pagePathPattern.hasMatch(path);
  }

  /// 把「播放器页 URL 里塞着真地址」拆出来。
  ///
  /// `artplayer.html?url=<百分号编码的真地址>` 这种写法在 CMS 站里极常见，
  /// 真地址就在 `url` / `v` / `src` 这类参数里。拆出来用真地址，
  /// 而不是把整个页面 URL 当直链。
  ///
  /// 拆不出来就原样返回（不猜）。
  static const List<String> _embedKeys = [
    'url',
    'v',
    'src',
    'video',
    'm3u8',
    'playurl',
    'videourl',
  ];

  static String unwrapEmbeddedUrl(String url) {
    if (!url.contains('=')) return url;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.queryParameters.isEmpty) return url;
    for (final e in uri.queryParameters.entries) {
      if (!_embedKeys.contains(e.key.toLowerCase())) continue;
      final v = e.value.trim();
      if (v.isEmpty || !v.startsWith('http')) continue;
      if (!mediaUrlPattern.hasMatch(v)) continue;
      if (looksLikePlayerPage(v)) continue;
      return v;
    }
    return url;
  }

  static bool isMediaUrl(String url) =>
      !looksLikePlayerPage(url) && mediaUrlPattern.hasMatch(url);

  /// 从一段文本（页面源码 / JSON 响应 / JS 片段）里抽媒体地址
  static List<String> extractFromText(String text) {
    final found = <String>{};
    for (final m in mediaUrlPattern.allMatches(text)) {
      found.add(m.group(0)!);
    }
    for (final m in _assignmentPattern.allMatches(text)) {
      final c = m.group(1);
      if (c != null && isMediaUrl(c)) found.add(c);
    }
    return found.toList();
  }

  /// 注入到页面里的采集脚本（幂等：重复注入不会重复挂钩子）。
  ///
  /// 三路采集：
  ///   ① 钩 `XMLHttpRequest.open` 与 `fetch`（JS 自己拼出来的地址）；
  ///   ② `MutationObserver` + 扫 `video` / `source` 的 `src`（DOM 里写死的）；
  ///   ③ `performance.getEntriesByType('resource')`（已经发出去的请求）。
  static const String probeScript = r'''
(function () {
  if (window.__tbSnifferInstalled) return;
  window.__tbSnifferInstalled = true;
  window.__tbSniffedMedia = [];
  var pattern = /\.(m3u8|mpd|mp4|m4v|mov|flv|m4s)(\?|#|$)/i;
  function report(url) {
    if (typeof url !== 'string' || !pattern.test(url)) return;
    if (window.__tbSniffedMedia.indexOf(url) < 0) window.__tbSniffedMedia.push(url);
  }
  try {
    var open = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      report(url);
      return open.apply(this, arguments);
    };
  } catch (e) {}
  try {
    var fetchOriginal = window.fetch;
    if (fetchOriginal) {
      window.fetch = function (input) {
        report(typeof input === 'string' ? input : (input && input.url));
        return fetchOriginal.apply(this, arguments);
      };
    }
  } catch (e) {}
  function scanDom() {
    try {
      document.querySelectorAll('video, source').forEach(function (node) {
        report(node.currentSrc || node.src);
      });
      if (window.performance && performance.getEntriesByType) {
        performance.getEntriesByType('resource').forEach(function (entry) {
          report(entry.name);
        });
      }
    } catch (e) {}
  }
  try {
    new MutationObserver(scanDom).observe(document.documentElement, {
      childList: true, subtree: true, attributes: true, attributeFilter: ['src']
    });
  } catch (e) {}
  scanDom();
})();
''';

  /// 读取采集结果的 JS 表达式
  static const String readScript =
      'JSON.stringify(window.__tbSniffedMedia || [])';

  /// 把页面里的 `<video>` 换源播放（嗅探到地址后原地播放，不跳页）
  static String playInPageScript(String url) {
    final safe = jsonEncode(url);
    return '''
(function () {
  var url = $safe;
  try {
    var nodes = document.querySelectorAll('video');
    if (!nodes.length) return false;
    for (var i = 0; i < nodes.length; i++) {
      var v = nodes[i];
      try { v.pause(); } catch (e) {}
      v.src = url;
      try { v.load(); v.play(); } catch (e) {}
    }
    return true;
  } catch (e) { return false; }
})();
''';
  }

  /// 解析 `runJavaScriptReturningResult` 的返回值（可能是 JSON 字符串或 List）
  static List<String> parseSniffedResult(Object? result) {
    if (result is List) return result.whereType<String>().toList();
    if (result is String) {
      try {
        final decoded = jsonDecode(result);
        if (decoded is List) return decoded.whereType<String>().toList();
      } catch (_) {}
    }
    return const [];
  }

  /// 推荐度：m3u8 最优先（可切码率、体积小），其次 mpd、mp4，最后其它
  static int score(String url) {
    final path = url.toLowerCase().split('?').first.split('#').first;
    if (path.endsWith('.m3u8')) return 0;
    if (path.endsWith('.mpd')) return 1;
    if (path.endsWith('.mp4')) return 2;
    return 3;
  }
}

/// 一次嗅探会话的候选列表（去重 + 推荐）
class SnifferSession {
  SnifferSession({Iterable<String> initial = const []}) {
    addAll(initial);
  }

  final List<String> _candidates = [];

  List<String> get candidates => List.unmodifiable(_candidates);

  bool get isEmpty => _candidates.isEmpty;

  bool add(String url) {
    final t = url.trim();
    if (t.isEmpty || !MediaSniffer.isMediaUrl(t)) return false;
    if (_candidates.contains(t)) return false;
    _candidates.add(t);
    return true;
  }

  /// 返回是否真的有新增（调用方据此决定要不要刷新 UI）
  bool addAll(Iterable<String> urls) {
    var changed = false;
    for (final u in urls) {
      if (add(u)) changed = true;
    }
    return changed;
  }

  void clear() => _candidates.clear();

  /// 推荐地址（按 m3u8 > mpd > mp4 > 其它 排序后的第一条）
  String? get preferred {
    if (_candidates.isEmpty) return null;
    final ordered = [..._candidates]
      ..sort((a, b) => MediaSniffer.score(a).compareTo(MediaSniffer.score(b)));
    return ordered.first;
  }
}
