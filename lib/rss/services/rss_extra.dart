// lib/rss/services/rss_extra.dart
//
// RSS 模块的「Legado 兼容」补充能力（2026-10-22）：
//   · 已读 / 未读（Legado 订阅源阅读后置为已读）
//   · 列表离线缓存 + 上次刷新时间（进页面先用缓存秒开，再静默刷新）
//   · `searchUrl` 源内搜索（`{{key}}` / `{{keyword}}` / `{{searchKey}}`）
//   · 全部订阅源批量刷新
//
// 只依赖 SharedPreferences，不新增插件。

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/rss/models/rss_article.dart';
import 'package:tvbox/rss/models/rss_source.dart';
import 'package:tvbox/rss/services/rss_reader.dart';
import 'package:tvbox/rss/services/rss_store.dart';

class RssExtra {
  RssExtra._();

  static const _kReadIds = 'rss_read_ids_v1';
  static const _kCachePrefix = 'rss_cache_v2_';
  static const _kLastRefreshPrefix = 'rss_last_refresh_v2_';

  // ── 已读 / 未读 ───────────────────────────────────────────

  /// 文章稳定 key：优先用链接（同源内唯一），没有链接退化到标题。
  static String articleKey(RssArticle a) {
    final l = a.link.trim();
    return l.isNotEmpty ? l : '${a.sourceId}|${a.title}';
  }

  static Future<Set<String>> readIds() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return (sp.getStringList(_kReadIds) ?? const []).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> markRead(String key) async {
    if (key.trim().isEmpty) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final list = (sp.getStringList(_kReadIds) ?? const []).toList();
      if (list.contains(key)) return;
      list.add(key);
      // 只留最近 2000 条，避免无限增长
      if (list.length > 2000) list.removeRange(0, list.length - 2000);
      await sp.setStringList(_kReadIds, list);
    } catch (_) {}
  }

  static Future<void> markAllRead(Iterable<RssArticle> arts) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final list = (sp.getStringList(_kReadIds) ?? const []).toSet();
      for (final a in arts) {
        list.add(articleKey(a));
      }
      var all = list.toList();
      if (all.length > 2000) all = all.sublist(all.length - 2000);
      await sp.setStringList(_kReadIds, all);
    } catch (_) {}
  }

  // ── 离线缓存 ─────────────────────────────────────────────

  static String _cacheKey(RssSource s, String channelUrl) =>
      '$_kCachePrefix${s.id}|$channelUrl';

  static List<Map<String, dynamic>> _encode(List<RssArticle> list) => [
        for (final a in list)
          {
            'title': a.title,
            'link': a.link,
            'image': a.image,
            'pubDate': a.pubDate,
            'description': a.description,
            'sourceId': a.sourceId,
            'sourceName': a.sourceName,
            'contentHtml': a.contentHtml,
          }
      ];

  static List<RssArticle> _decode(List raw) => [
        for (final e in raw)
          if (e is Map)
            RssArticle(
              title: (e['title'] ?? '').toString(),
              link: (e['link'] ?? '').toString(),
              image: (e['image'] ?? '').toString(),
              pubDate: (e['pubDate'] ?? '').toString(),
              description: (e['description'] ?? '').toString(),
              sourceId: (e['sourceId'] ?? '').toString(),
              sourceName: (e['sourceName'] ?? '').toString(),
              contentHtml: (e['contentHtml'] ?? '').toString(),
            )
      ];

  static Future<List<RssArticle>?> readCache(
    RssSource s,
    String channelUrl,
  ) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_cacheKey(s, channelUrl));
      if (raw == null || raw.isEmpty) return null;
      final j = jsonDecode(raw);
      if (j is! List || j.isEmpty) return null;
      return _decode(j);
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeCache(
    RssSource s,
    String channelUrl,
    List<RssArticle> list,
  ) async {
    if (list.isEmpty) return;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _cacheKey(s, channelUrl),
        jsonEncode(_encode(list)),
      );
      await sp.setInt(
        '$_kLastRefreshPrefix${s.id}',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  static Future<DateTime?> lastRefresh(RssSource s) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final ms = sp.getInt('$_kLastRefreshPrefix${s.id}');
      if (ms == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  /// 超过 [ttl] 没刷新过 ⇒ 视为过期（进页面时后台静默刷新）
  static Future<bool> isStale(
    RssSource s, {
    Duration ttl = const Duration(minutes: 30),
  }) async {
    final t = await lastRefresh(s);
    if (t == null) return true;
    return DateTime.now().difference(t) > ttl;
  }

  // ── searchUrl 源内搜索 ───────────────────────────────────

  /// 源配了 `searchUrl` 就返回替换好的地址，否则返回空串。
  ///
  /// 真正的求值在 [RssReader.searchUrlFor]（支持模板占位符 + `<js>` / `@js:`）。
  static String searchUrlFor(RssSource s, String keyword) =>
      RssReader.searchUrlFor(s, keyword);

  /// 源内搜索：有 `searchUrl` 走远端；**远端不可用/无结果时返回 null**，
  /// 调用方据此退回"当前列表标题过滤"。
  static Future<List<RssArticle>?> search(
    RssSource s,
    String keyword,
  ) async {
    final url = searchUrlFor(s, keyword);
    if (url.isEmpty) return null;
    try {
      final res = await RssReader.fetchArticles(
        s,
        channel: RssChannel('搜索', url),
        page: 1,
        ignoreCache: true,
      );
      // 站点型（返回 HTML 外壳）/ 被拦 / 真的没结果 → 交给调用方本地过滤，
      // 而不是让页面直接显示"没搜到"（契约见方法头注释）
      if (res.siteLike || res.articles.isEmpty) return null;
      return res.articles;
    } catch (_) {
      // 403 / 超时 / 解析失败同理：退回本地标题过滤
      return null;
    }
  }

  // ── 批量刷新 ─────────────────────────────────────────────

  /// 按批（3 路并发）刷新已启用订阅源的第一页，顺便写缓存。
  /// 返回成功条数；[onProgress] 用于进度提示。
  static Future<int> refreshAll({
    void Function(int done, int total)? onProgress,
  }) async {
    final all = RssStore.instance.enabledSources;
    if (all.isEmpty) return 0;
    var ok = 0;
    var done = 0;
    // 并发 3：串行时几十个源要排队等很久；全并发又会同时打几十个站点。
    // 单个源失败只影响自己（_refreshOne 内部 catch）。
    const concurrency = 3;
    for (var i = 0; i < all.length; i += concurrency) {
      final end = i + concurrency < all.length ? i + concurrency : all.length;
      final batch = all.sublist(i, end);
      final results = await Future.wait(batch.map((s) async {
        final r = await _refreshOne(s);
        done++;
        onProgress?.call(done, all.length);
        return r;
      }));
      ok += results.where((e) => e).length;
    }
    return ok;
  }

  /// 刷新单个源；站点型（SiteOnly）没有频道可刷，直接算成功
  static Future<bool> _refreshOne(RssSource s) async {
    try {
      if (s.isSiteOnly) return true;
      final ch = s.channels.isNotEmpty ? s.channels.first : null;
      if (ch == null) return false;
      final res = await RssReader.fetchArticles(
        s,
        channel: ch,
        page: 1,
        ignoreCache: true,
      );
      if (res.articles.isEmpty) return false;
      await writeCache(s, ch.url, res.articles);
      return true;
    } catch (_) {
      return false;
    }
  }
}
