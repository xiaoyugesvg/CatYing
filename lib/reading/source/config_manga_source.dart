// 配置驱动的站点源：按 SiteConfig（DOM 选择器 + 取图模式）实现 MangaSource 契约。
//
// 详情/章节用 Dio + html 包解析章节页 HTML；取图分双路径：
//   useFrame=0 直连：Dio 章节页 + imgDom/imgAttr 提取（+ 翻页，2b）
//   useFrame=1 iframe/懒加载：WebViewImageFetcher（WebView 快取 + 前缀过滤）
//
// 搜索：site.searchUrl 有则 Dio + html 解析结果；无则抛 UnsupportedSearchError，
// 由搜索页捕获并提示「用 URL 兜底入口」。

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';

import 'manga_source.dart';
import 'models.dart';
import 'cover_cache.dart';
import 'site_config.dart';
import 'webview_image_fetcher.dart';
import 'package:gbk_codec/gbk_codec.dart';
import '../services/settings_service.dart';

/// 配置源不支持搜索时抛出（UI 提示用 URL 兜底入口）。
class UnsupportedSearchError implements Exception {
  final String message;
  UnsupportedSearchError(this.message);
  @override
  String toString() => message;
}

/// 配置驱动的站点源。
class ConfigMangaSource extends MangaSource {
  final SiteConfig site;
  ConfigMangaSource(this.site);

  @override
  String get id => 'config:${site.name}';

  @override
  String get name => site.name;

  @override
  String get lang => 'zh';

  @override
  bool get supportsLatest => false;

  @override
  Map<String, String> get imageHeaders => const {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  };

  @override
  String? get referer {
    // imgReferer: 空=site.url（默认），'none'=不发（g-mh.online 防盗链反直觉：
    // 有 Referer 重定向错误图，无 Referer 301 到 c-nd3 CDN 200），其他=自定义值
    if (site.imgReferer == 'none') return null;
    if (site.imgReferer.isNotEmpty) return site.imgReferer;
    return site.url;
  }

  /// 配置源章节级 Referer：章节 URL 非空时用章节页作 Referer，
  /// 适配按具体页面校验防盗链的图床（如摸摸漫画 blob 站的 CDN）。
  @override
  String? refererForChapter(CChapter chapter) {
    final chapterUrl = chapter.url;
    if (chapterUrl != null && chapterUrl.isNotEmpty) {
      return chapterUrl;
    }
    return referer;
  }

  @override
  bool get chapterSortByOrder => site.chapterSortByOrder;

  /// config 源 order=DOM 遍历顺序：chapterOrder=0(倒序,最新在前)时降序排得「第1话在前」，
  /// =1(正序,第1话在前)时升序。复用现有 chapterOrder 配置作方向。
  @override
  bool get chapterOrderDescending => site.chapterOrder == 0;

  void _log(String message) => debugPrint('[ConfigMangaSource:$name] $message');

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: true,
    ),
  )..httpClientAdapter = _adapterForGlobalProxy();

  /// 漫画源未配单源代理时回退全局代理（通用设置 → 网络代理）。
  static HttpClientAdapter _adapterForGlobalProxy() {
    final s = SettingsService();
    if (!s.globalProxyEnabled) return IOHttpClientAdapter();
    final p = s.globalProxy.trim();
    final parts = p.split(':');
    if (parts.length != 2) return IOHttpClientAdapter();
    final host = parts[0].trim();
    final port = int.tryParse(parts[1].trim()) ?? 0;
    if (host.isEmpty || port <= 0) return IOHttpClientAdapter();
    return IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient()
          ..findProxy = (uri) => 'PROXY $host:$port';
        return client;
      },
    );
  }

  /// 把相对 URL（或完整 URL）解析为绝对 URL，base 默认站点首页。
  String _resolveUrl(String idOrUrl, [String? base]) {
    if (idOrUrl.startsWith('http://') || idOrUrl.startsWith('https://')) {
      return idOrUrl;
    }
    return Uri.parse(base ?? site.url).resolve(idOrUrl).toString();
  }

  /// 应用 urlRewrites（封面/章节图主机被防盗链或地理拦截时换可达主机）。
  String _rewriteUrl(String url) {
    final rw = site.urlRewrites;
    if (rw == null || rw.isEmpty || url.isEmpty) return url;
    var r = url;
    for (final entry in rw.entries) {
      r = r.replaceAll(entry.key, entry.value);
    }
    return r;
  }

  /// ✅ **搜索支持 POST**（本轮新增 ✓ —— 兼容用 POST 搜索的 Legado 漫画源 ✓）。
  ///
  /// 为什么要有它 ✗：`_fetchHtml` 是**纯 GET** ✓，而部分 Legado 源把搜索写成
  /// **POST + 请求体** ✓（编辑器里那两行也如实写着"**搜索仅支持 GET**"✓，不是谎话 ✓）。
  /// 本方法**逐条照抄 `_fetchHtml` 的结构** ✓（同一套 headers/Referer ✓、同一套 gbk/utf8 解码 ✓），
  /// 只把 `get` 换成 `post` 并带上请求体 ✓ —— **不发明新机制** ✗。
  /// ⚠️ WebView 抓取那条路**只支持 GET** ✗（它按 URL 打开页面 ✓）→ POST 时**如实走 Dio** ✓
  ///   并记一条日志 ✓，**不静默把 POST 变成 GET** ✗（那会骗人 ✓）。
  Future<String> _fetchHtmlByPost(String url, String body) async {
    if (site.useWebViewFetch) {
      _log('该源配置了 WebView 抓取（仅 GET）；本次搜索按 Dio POST 发出');
    }
    final resp = await _dio.post<List<int>>(
      url,
      data: utf8.encode(body),
      options: Options(
        headers: {
          ...imageHeaders,
          'Referer': site.url,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        responseType: ResponseType.bytes,
      ),
    );
    final bytes = resp.data ?? const <int>[];
    final enc = (site.pageEncoding ?? 'utf-8').toLowerCase();
    if (enc == 'gb2312' || enc == 'gbk') {
      return gbk_bytes.decode(bytes);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<String> _fetchHtml(String url) async {
    // Cloudflare 防护站（Dio 被拦）：走 WebView 抓渲染后 HTML，搜索/分类/详情/章节统一经此。
    if (site.useWebViewFetch) {
      return WebViewImageFetcher().fetchHtml(url);
    }
    final resp = await _dio.get<List<int>>(
      url,
      options: Options(
        headers: {...imageHeaders, 'Referer': site.url},
        responseType: ResponseType.bytes,
      ),
    );
    final bytes = resp.data ?? const <int>[];
    final enc = (site.pageEncoding ?? 'utf-8').toLowerCase();
    if (enc == 'gb2312' || enc == 'gbk') {
      return gbk_bytes.decode(bytes);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// ── JSON 章节 API 直连模式（声明式章节接口，如热辣漫画 /api/v3/comic/.../chapters）──
  /// 详情 URL 经 chapterUrlIdRegex 提取捕获组 -> 替换 chapterApiUrl 模板占位
  /// （{offset} 页码，其余 {xxx} 按出现顺序用捕获组）-> Dio GET/POST ->
  /// chapterListField 点路径取列表 -> chapterJsonFields 映射 name/url ->
  /// 模板含 {offset} 时按 chapterPageSize 翻页，直到结果数 < pageSize 或无新增。
  Future<List<Map<String, String>>> _fetchChaptersFromJsonApi(
    String detailUrl,
  ) async {
    final captures = _captureGroups(detailUrl, site.chapterUrlIdRegex);
    var offset = 0;
    final out = <Map<String, String>>[];
    var prevCount = -1;
    while (true) {
      // ✅ **同样兼容 Legado 双花括号**（本轮 ✓ 与搜索处同一根因 ✓）：
      //   Legado 源常写 `{{offset}}` ✓，原来**只认单花括号** ✗ ⇒ 占位符不被替换 ✗
      //   ⇒ URL 里带字面量花括号 ✓ → 章节接口 500 / 返回空 ✗（表现为"**详情有、目录打不开**"✗）
      //   ⚠️ **先双后单** ✓；单括号保留 ✓（老源自定义写法不变 ✓）
      var url = site.chapterApiUrl
          .replaceAll('{{offset}}', offset.toString())
          .replaceAll('{offset}', offset.toString());
      url = _fillRemaining(url, captures);
      url = _resolveUrl(url, site.url);
      final text = await _fetchJsonText(url);
      if (text == null || text.isEmpty) break;
      Object? obj;
      try {
        obj = jsonDecode(text);
      } catch (_) {
        _log('章节 JSON 解析失败: $url');
        break;
      }
      final list = _diveJson(obj, site.chapterListField);
      if (list is! List || list.isEmpty) break;
      for (final item in list) {
        if (item is! Map) continue;
        final name = _mapFieldValue(item, site.chapterJsonFields?['name'] ?? '');
        var u = _mapFieldValue(item, site.chapterJsonFields?['url'] ?? '');
        if (u.isNotEmpty) u = _fillRemaining(u, captures);
        if (u.isEmpty) continue;
        out.add({'name': name, 'url': u});
      }
      if (!site.chapterApiUrl.contains('{offset}')) break;
      if (out.length == prevCount) break; // 无新增，防死循环
      prevCount = out.length;
      if (site.chapterPageSize > 0 && list.length < site.chapterPageSize) break;
      offset += site.chapterPageSize > 0 ? site.chapterPageSize : 1;
      if (offset > 200000) break; // 安全上限
    }
    return out;
  }

  /// 从输入文本按正则提取捕获组（组1..N）。
  List<String> _captureGroups(String input, String regex) {
    if (regex.isEmpty) return const [];
    final m = RegExp(regex).firstMatch(input);
    if (m == null) return const [];
    return [for (var i = 1; i <= m.groupCount; i++) m.group(i) ?? ''];
  }

  /// 把模板中 {xxx} 占位（{offset}/{page} 保留）按出现顺序替换为捕获组。
  String _fillRemaining(String template, List<String> captures) {
    if (captures.isEmpty) return template;
    var idx = 0;
    return template.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (m) {
      final name = m.group(1)!;
      if (name == 'offset' || name == 'page') return m.group(0)!;
      if (idx < captures.length) return captures[idx++];
      return m.group(0)!;
    });
  }

  /// 字段映射取值：字段名 / 点路径 / Field[0] / {Field} 模板。
  /// 模板中条目里真实存在的字段先替换（未命中保留占位，交给捕获组）。
  String _mapFieldValue(Map<dynamic, dynamic> item, String spec) {
    if (spec.isEmpty) return '';
    if (spec.contains('{')) {
      return spec.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (m) {
        final v = _diveJson(item, m.group(1)!);
        if (v is String || v is num) return v.toString();
        return m.group(0)!;
      });
    }
    final v = _diveJson(item, spec);
    if (v is String) return v;
    if (v is num) return v.toString();
    return '';
  }

  /// 点路径下钻（支持 arr[0] 段；空路径返回 root 本身）。
  Object? _diveJson(Object? root, String path) {
    if (path.isEmpty) return root;
    var cur = root;
    for (final seg in path.split('.')) {
      final m = RegExp(r'^(.+)\[(\d+)\]$').firstMatch(seg);
      if (m != null) {
        final key = m.group(1)!;
        final idx = int.parse(m.group(2)!);
        if (key.isNotEmpty && cur is Map) cur = cur[key];
        if (cur is List) {
          cur = (idx >= 0 && idx < cur.length) ? cur[idx] : null;
        } else {
          cur = null;
        }
      } else if (cur is Map) {
        cur = cur[seg];
      } else {
        cur = null;
      }
      if (cur == null) return null;
    }
    return cur;
  }

  /// 请求 JSON 文本（GET 默认；chapterApiMethod=POST 时 POST）。
  Future<String?> _fetchJsonText(String url) async {
    try {
      final opts = Options(
        headers: {...imageHeaders, 'Referer': site.url},
        responseType: ResponseType.bytes,
      );
      final method = site.chapterApiMethod.toUpperCase();
      final resp = method == 'POST'
          ? await _dio.post<List<int>>(url, options: opts)
          : await _dio.get<List<int>>(url, options: opts);
      final data = resp.data;
      if (data == null || data.isEmpty) return null;
      return utf8.decode(data, allowMalformed: true);
    } catch (e) {
      _log('章节 JSON 请求失败: $url -> $e');
      return null;
    }
  }

  /// 封面终处理：
  ///   1) cover_url_pattern 非空（如摸摸）：渲染 DOM 里封面是 blob/_ipx 地址
  ///      不可直连，从漫画 URL 提取 comicId 按模板生成直连封面 URL；
  ///   2) 加密/base64 站（imgAesKey/imgBodyBase64，如漫蛙封面同章节密文）：
  ///      SourceCoverCache 下载还原落地，返回本地路径（失败保留原值）。
  /// [comicUrlForId] 用于 cover_id_regex 提取 comicId。
  Future<String> _finalizeCover(String cover, String comicUrlForId) async {
    var c = cover;
    if (site.coverUrlPattern.isNotEmpty) {
      final m = RegExp(site.coverIdRegex).firstMatch(comicUrlForId);
      if (m != null) {
        // ✅ 封面模板也兼容双花括号 ✓（同款 ✓ 先双后单 ✓）—— 否则封面地址会带字面量 `{{comicId}}` ✗
        return site.coverUrlPattern
            .replaceAll('{{comicId}}', m.group(1)!)
            .replaceAll('{comicId}', m.group(1)!);
      }
    }
    if (c.isEmpty || c.startsWith('data:') || c.startsWith('blob:')) return c;
    if (SourceCoverCache.needsRestore(site)) {
      final local = await SourceCoverCache.instance.localize(c, site);
      if (local != null) return local;
    }
    return c;
  }

  @override
  Future<MangasPage> search(
    String query, {
    int page = 0,
    FilterList filters = const FilterList(),
  }) async {
    final tpl = site.searchUrl;
    if (tpl == null || tpl.isEmpty) {
      throw UnsupportedSearchError('源「${site.name}」暂不支持搜索');
    }
    final enc = (site.searchEncoding ?? 'utf-8').toLowerCase();
    String q;
    if (enc == 'gb2312' || enc == 'gbk') {
      // Empire CMS 等站搜索关键词需 gb2312 编码后 percent-encode
      final sb = StringBuffer();
      for (final b in gbk_bytes.encode(query)) {
        sb.write('%');
        sb.write(b.toRadixString(16).padLeft(2, '0'));
      }
      q = sb.toString();
    } else {
      q = Uri.encodeQueryComponent(query);
    }
    var url = tpl
        // ✅ **Legado 双花括号兼容**（本轮 ✓ 与书源侧同一根因 ✓）：
        //   Legado 漫画源常用 `{{key}}` / `{{page}}` ✓，而引擎原来**只认单花括号** ✗
        //   ⇒ 占位符不被替换 ✗ → URL 带字面量花括号 ✓ → 站点 500 / 无结果 ✗
        //   ⚠️ **先双后单** ✓（否则 `{{key}}` 会被 `{q}` 那条拆坏 ✗）；单括号**保留** ✓（向后兼容 ✓）
        .replaceAll('{{key}}', q)
        .replaceAll('{{q}}', q)
        .replaceAll('{{page}}', (page + 1).toString())
        .replaceAll('{q}', q)
        .replaceAll('{page}', (page + 1).toString());
    if (!url.startsWith('http')) url = _resolveUrl(url);
    // ✅ **按源配置决定 GET / POST**（本轮接上 ✓，兼容 POST 搜索的 Legado 源 ✓）：
    //   分派方式**照本文件章节接口的现成写法** ✓（`_fetchJsonText` 的三元 ✓）。
    //   · `site.searchMethod == 'POST'` → 请求体取 `searchPostBody` ✓，并把 `{q}` / `{page}`
    //     **用同一套替换**再走一遍 ✓（与上面 URL 的替换规则一致 ✓）；WebView 只支持 GET ✓，
    //     那种情况下 `_fetchHtmlByPost` 会如实走 Dio 并记日志 ✓（不静默降级 ✗）。
    //   · 否则 → **原样 GET** ✓（向后兼容 ✓ 已有源行为一字不改 ✓）。
    final String html;
    if (site.searchMethod.toUpperCase() == 'POST') {
      final body = site.searchPostBody
          // ✅ 请求体里**同样**兼容双花括号 ✓（规则与上面 URL **完全一致** ✓ 免得两处不一致 ✗）
          .replaceAll('{{key}}', q)
          .replaceAll('{{q}}', q)
          .replaceAll('{{page}}', (page + 1).toString())
          .replaceAll('{q}', q)
          .replaceAll('{page}', (page + 1).toString());
      html = await _fetchHtmlByPost(url, body);
    } else {
      html = await _fetchHtml(url);
    }
    final doc = parse(html);
    final items = <CManga>[];
    final resultDom = site.searchResultDom;
    if (resultDom != null && resultDom.isNotEmpty) {
      for (final r in doc.querySelectorAll(resultDom)) {
        var title = _elText(r, site.searchTitleDom);
        // searchMangaUrlDom 为空 = 列表项本身就是链接元素，直接取自身 href
        final href =
            site.searchMangaUrlDom != null && site.searchMangaUrlDom!.isNotEmpty
            ? (_elAttr(r, site.searchMangaUrlDom, 'href') ?? '')
            : (r.attributes['href'] ?? '');
        if (title.isEmpty && href.isEmpty) continue;
        // 标题空时兜底用封面 img 的 alt（mycomic 卡标题仅在 alt）
        if (title.isEmpty &&
            site.searchCoverDom != null &&
            site.searchCoverDom!.isNotEmpty) {
          title = _elAttr(r, site.searchCoverDom, 'alt') ?? '';
        }
        String cover = '';
        if (site.searchCoverDom != null && site.searchCoverDom!.isNotEmpty) {
          cover = _imgUrl(r.querySelector(site.searchCoverDom!)) ?? '';
        }
        // 归一化：相对路径(/logo/x.jpg)或协议相对(//host/x)封面按当前页 URL 解析为绝对
        if (cover.isNotEmpty && !cover.startsWith('http')) {
          cover = _resolveUrl(cover, url);
        }
        if (cover.isNotEmpty) {
          cover = _rewriteUrl(cover);
        }
        items.add(
          CManga(
            id: href,
            sourceId: id,
            title: title,
            cover: cover,
            url: href.isEmpty ? '' : _resolveUrl(href),
          ),
        );
      }
    }
    // 封面终处理并发执行（落地下载串行会拖慢整页列表）
    if (items.isNotEmpty) {
      final covers = await Future.wait(
        items.map((m) => _finalizeCover(m.cover, m.id)),
      );
      for (var i = 0; i < items.length; i++) {
        if (covers[i] != items[i].cover) {
          items[i] = items[i].copyWith(cover: covers[i]);
        }
      }
    }
    // 分页（{page} 占位 + hasNextPage 判断）2b 逐站补
    if (items.isNotEmpty) {
      _log('搜索 ${items.length} 条, 首封面: ${items.first.cover}');
    }
    return MangasPage(items: items, hasNextPage: false);
  }

  @override
  Future<MangasPage> getPopular({int page = 0}) async =>
      const MangasPage(items: [], hasNextPage: false);

  @override
  Future<MangasPage> getLatestUpdates({int page = 0}) async =>
      const MangasPage(items: [], hasNextPage: false);

  @override
  bool get supportsCategories => site.normalizedCategoryGroups.isNotEmpty;

  @override
  Future<List<FilterGroup>> fetchCategories() async {
    final groupsMap = site.normalizedCategoryGroups;
    if (groupsMap.isEmpty) return const [];
    final result = <FilterGroup>[];
    groupsMap.forEach((key, options) {
      if (options.isEmpty) return;
      result.add(
        FilterGroup(
          key: key,
          title: site.categoryGroupTitle(key),
          options: options,
          selected: options.first,
        ),
      );
    });
    return result;
  }

  @override
  Future<MangasPage> getCategoryList(
    List<FilterGroup> groups, {
    int page = 0,
  }) async {
    final groupsMap = site.normalizedCategoryGroups;
    if (groupsMap.isEmpty) {
      return const MangasPage(items: [], hasNextPage: false);
    }

    // 按 key 收集选中值（没传的组取第一个默认值），同时兼容旧版 {slug} 占位
    final values = <String, String>{};
    for (final entry in groupsMap.entries) {
      final key = entry.key;
      final list = entry.value;
      String? selected;
      for (final g in groups) {
        if (g.key == key) {
          selected = g.selected?.value;
          break;
        }
      }
      values[key] = selected ?? (list.isNotEmpty ? list.first.value : '');
    }
    // 旧版兼容：{slug} 等价于 {theme}
    final slugVal = values['theme'] ?? values.values.first;

    // 拼 URL：page==0 用 categoryUrl，page>=1 用 categoryPageUrl（{page} 1-based）
    final urlTpl = page == 0 ? site.categoryUrl : site.categoryPageUrl;
    if (urlTpl == null) {
      return const MangasPage(items: [], hasNextPage: false);
    }
    String url = urlTpl; // urlTpl 已在上方 null 检查
    // 替换所有 {key} 占位符
    values.forEach((key, value) {
      url = url.replaceAll('{$key}', value);
    });
    url = url
        // ✅ **兼容 Legado 双花括号**（本轮 ✓ 先双后单 ✓）—— 否则分类分页会带字面量 `{{slug}}`/`{{page}}` ✗
        .replaceAll('{{slug}}', slugVal)
        .replaceAll('{{page}}', (page + site.categoryPageStart).toString())
        .replaceAll('{slug}', slugVal) // 旧版兼容
        .replaceAll('{page}', (page + site.categoryPageStart).toString());
    if (!url.startsWith('http')) url = _resolveUrl(url);

    final html = await _fetchHtml(url);
    final doc = parse(html);
    final items = <CManga>[];
    final listDom = site.categoryListDom;
    if (listDom != null && listDom.isNotEmpty) {
      for (final r in doc.querySelectorAll(listDom)) {
        // categoryUrlDom 为空 = 列表项本身就是链接元素（如 <a class="comic">），直接取自身 href
        final href =
            site.categoryUrlDom != null && site.categoryUrlDom!.isNotEmpty
            ? (_elAttr(r, site.categoryUrlDom, 'href') ?? '')
            : (r.attributes['href'] ?? '');
        if (href.isEmpty) continue;
        String cover = '';
        if (site.categoryCoverDom != null &&
            site.categoryCoverDom!.isNotEmpty) {
          cover = _imgUrl(r.querySelector(site.categoryCoverDom!)) ?? '';
        }
        // 归一化：相对路径(/logo/x.jpg)或协议相对(//host/x)封面按当前页 URL 解析为绝对
        if (cover.isNotEmpty && !cover.startsWith('http')) {
          cover = _resolveUrl(cover, url);
        }
        if (cover.isNotEmpty) {
          cover = _rewriteUrl(cover);
        }
        var title = _elText(r, site.categoryTitleDom);
        if (title.isEmpty) {
          // 兜底用 img alt
          title = _elAttr(r, site.categoryCoverDom, 'alt') ?? '';
        }
        items.add(
          CManga(
            id: href,
            sourceId: id,
            title: title,
            cover: cover,
            url: href.isEmpty ? '' : _resolveUrl(href),
          ),
        );
      }
    }
    // 封面终处理并发执行（落地下载串行会拖慢整页列表）
    if (items.isNotEmpty) {
      final covers = await Future.wait(
        items.map((m) => _finalizeCover(m.cover, m.id)),
      );
      for (var i = 0; i < items.length; i++) {
        if (covers[i] != items[i].cover) {
          items[i] = items[i].copyWith(cover: covers[i]);
        }
      }
    }

    // hasNextPage：链接式（来漫画）查下一页链接；计数式（mycomic 等 &page=N 站）满页即有下一页
    var hasNext = false;
    final nextDom = site.categoryNextPageDom;
    if (nextDom != null && nextDom.isNotEmpty) {
      final nextHref = doc.querySelector(nextDom)?.attributes['href'];
      hasNext =
          nextHref != null &&
          nextHref.isNotEmpty &&
          nextHref != '#' &&
          !nextHref.toLowerCase().startsWith('javascript');
    } else if (site.categoryPageSize > 0) {
      hasNext = items.length >= site.categoryPageSize;
    }
    _log(
      '分类[${values.values.join("/")}] page=$page: ${items.length} 条, hasNext=$hasNext'
      '${items.isNotEmpty ? ", 首封面: ${items.first.cover}" : ""}',
    );
    return MangasPage(items: items, hasNextPage: hasNext);
  }

  @override
  Future<({CManga manga, List<CChapter> chapters})> getMangaDetailsAndChapters(
    CManga manga,
  ) async {
    final detailUrl = _resolveUrl(manga.id);
    final html = await _fetchHtml(detailUrl);
    final doc = parse(html);

    String title = manga.title;
    if (site.comicNameDom.isNotEmpty) {
      final el = doc.querySelector(site.comicNameDom);
      if (el != null && el.text.trim().isNotEmpty) title = el.text.trim();
    }
    String cover = manga.cover;
    if (site.comicCoverDom.isNotEmpty) {
      final el = doc.querySelector(site.comicCoverDom);
      if (el != null) {
        cover = _imgUrl(el) ?? cover;
      }
    }
    final coverRaw = cover;
    if (cover.isNotEmpty) {
      cover = _rewriteUrl(cover);
    }
    _log('详情封面: $coverRaw -> $cover');
    String? author = manga.author;
    if (site.comicAuthorDom.isNotEmpty) {
      final label = site.authorLabel;
      if (label != null && label.isNotEmpty) {
        // 标签式：找含 label 的元素，取去 label+冒号 后的剩余文本（来漫画 .info p.w260）
        for (final el in doc.querySelectorAll(site.comicAuthorDom)) {
          final txt = el.text.trim();
          if (txt.contains(label)) {
            final rest = txt
                .replaceFirst(label, '')
                .replaceFirst(RegExp(r'^[：:\s]+'), '')
                .trim();
            if (rest.isNotEmpty) {
              author = rest;
              break;
            }
          }
        }
      } else {
        final parts = <String>[];
        for (final el in doc.querySelectorAll(site.comicAuthorDom)) {
          var t = el.text.trim();
          // 排除嵌套的「作家信息」等噪声链接文本
          t = t.replaceAll('作家信息', '').replaceAll('详情', '').trim();
          if (t.isNotEmpty) parts.add(t);
        }
        if (parts.isNotEmpty) author = parts.join(', ');
      }
    }
    String? description = manga.description;
    if (site.comicDescDom.isNotEmpty) {
      final el = doc.querySelector(site.comicDescDom);
      if (el != null) {
        final c = el.attributes['content']?.trim();
        final t = el.text.trim();
        if (c != null && c.isNotEmpty) {
          description = c;
        } else if (t.isNotEmpty) {
          description = t;
        }
      }
    }

    // 🔴 **批次 3 补**：状态 / 标签 / 热度 —— 这 3 个选择器**内置源 JSON 里本来就有** ✓
    //   （`comic_status_dom` 12 个源 / `comic_tags_dom` 12 个 / `comic_hot_dom` 3 个 ✓），
    //   但引擎**从来没解析过** ✗ → 详情页的**状态、标签、热度恒为空** ✗
    //   （而编辑页却能填它们 ✓ = 假开关 ✓）。
    //   ℹ️ 管道其实早就通了 ✓：`CManga` 有这三个字段 ✓（`models.dart:18-21` ✓）、
    //      `comicToCManga` / `cmangaToComic` 都已映射 ✓（`adapter.dart:19-22 / 40-43` ✓）、
    //      连 `manhuaren_source` / `zaimanhua_source` 都早就在填 ✓ → 只差这里 ✓。
    String? status;
    if (site.comicStatusDom.isNotEmpty) {
      final el = doc.querySelector(site.comicStatusDom);
      final t = el?.text.trim() ?? '';
      if (t.isNotEmpty) status = t;
    }
    // ✅ **`status_label` 兜底**（本轮实现 ✓）—— 上面抓不到状态时用它 ✓：
    //   · 抓到 → **以站点文本为准** ✓（不改 ✓）
    //   · 抓不到 **且** 源填了 `status_label` → 用该标签 ✓（如「连载中」✓，详情页不留空白 ✓）
    //   · 都没填 → `status` 仍为 null ✓ → `:803` 处 `status ?? manga.status` ✓ **行为不变** ✓
    //   ⇒ **留空即零影响** ✓✓（现有源全部不受影响 ✓）
    if (status == null && site.statusLabel.trim().isNotEmpty) {
      status = site.statusLabel.trim();
    }
    // tags 的类型是 `List<String>?` ✓ → 选择器匹配到**多个**元素就收集成列表 ✓
    //（这也是 `tags_split` 那个键的用途分界 ✓：它服务"单元素里塞了一串"的源 ✗，
    //  而内置 config 源用的是**多元素选择器** ✓，不需要拆分 ✓）
    // ✅ **`tags_split` 已实现**（本轮 ✓）—— 原来这里只做"**多元素 → 列表**" ✓，
    //   而有的源把一串标签塞在**一个元素**里（如 `热血,冒险,战斗` ✓）→ 选择器只命中 1 个 ✗
    //   → 列表就**只有 1 项** ✗（本该 3 项 ✓）。现在**收集之后**再按 `tagsSplit` 拆一次 ✓✓。
    //   · `tagsSplit` 留空 ✓ → **行为与从前完全一致** ✓（向后兼容 ✓ 内置那 30+ 个 config 源
    //     用的都是**多元素选择器** ✓，不受任何影响 ✓）。
    final tags = site.comicTagsDom.isEmpty
        ? null
        : doc
              .querySelectorAll(site.comicTagsDom)
              .map((e) => e.text.trim())
              .where((e) => e.isNotEmpty)
              .expand((t) {
                final sep = site.tagsSplit.trim();
                if (sep.isEmpty) return [t];
                return t
                    .split(sep)
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty);
              })
              .toList();
    int? popular;
    if (site.comicHotDom.isNotEmpty) {
      // 热度只取其中的数字 ✓（站点文案常是"1234 人气"之类 ✓）；取不到就不设 ✓
      final el = doc.querySelector(site.comicHotDom);
      final m = RegExp(r'\d+').firstMatch(el?.text ?? '');
      if (m != null) popular = int.tryParse(m.group(0)!);
    }

    // 章节列表
    final chapters = <CChapter>[];
    final seen = <String>{};
    if (site.chapterScript.isNotEmpty) {
      // chapterScript 模式：SSR 无章节（骨架屏），3 阶段直连取章节
      // 阶段1 详情页 chapterScript 返回 {apiUrl,linkBase}；阶段2 loadRequest(apiUrl) 直连
      // 取 JSON（浏览器绕 CORS/TLS 拦截，如 godamh v2.apikk.top）；阶段3 chapterJsonScript 映射
      final list = await WebViewImageFetcher().fetchChapters(
        detailUrl,
        site.chapterScript,
        site.chapterJsonScript,
        // ✅ **`chapter_click_dom` 真正生效**（本轮接上 ✓）—— 该源填了就"先点开目录再取" ✓；
        //   没填则传空串 ✓ → WebView 侧**整段跳过** ✓（与从前完全一致 ✓ 零影响 ✓）
        site.chapterClickDom,
      );
      var order = 0;
      for (final c in list) {
        final chapterUrl = _resolveUrl(c['url'] ?? '', detailUrl);
        if (chapterUrl.isEmpty || !seen.add(chapterUrl)) continue;
        chapters.add(
          CChapter(
            id: chapterUrl,
            sourceId: id,
            mangaId: manga.id,
            name: c['name'] ?? '',
            url: chapterUrl,
            order: order++,
          ),
        );
      }
    } else if (site.chapterApiUrl.isNotEmpty) {
      // JSON 章节 API 直连模式（热辣漫画等声明式章节接口）：
      // 详情 URL 经 chapterUrlIdRegex 提取捕获组 -> 模板拼 URL -> Dio GET/POST
      // -> chapterListField 点路径取列表 -> chapterJsonFields 映射 name/url -> 分页。
      final apiList = await _fetchChaptersFromJsonApi(detailUrl);
      var order = 0;
      for (final c in apiList) {
        final chapterUrl = _resolveUrl(c['url'] ?? '', site.url);
        if (chapterUrl.isEmpty || !seen.add(chapterUrl)) continue;
        chapters.add(
          CChapter(
            id: chapterUrl,
            sourceId: id,
            mangaId: manga.id,
            name: c['name'] ?? '',
            url: chapterUrl,
            order: order++,
          ),
        );
      }
      _log('章节 JSON API: $detailUrl -> ${chapters.length} 章');
    } else {
      var order = _parseChapters(doc, detailUrl, manga, chapters, seen, 0);
      if (site.chapterPageCountDom.isNotEmpty &&
          site.chapterPagedUrl.isNotEmpty) {
        final base = _pagedBaseUrl(doc, detailUrl);
        final pageCount = _maxPage(doc, site.chapterPageCountDom);
        _log('章节分页: base=$base, 总页数=$pageCount');
        for (var p = 2; p <= pageCount; p++) {
          final pageUrl = site.chapterPagedUrl
              // ✅ **兼容 Legado 双花括号**（本轮 ✓ 先双后单 ✓）—— 章节分页同款隐患 ✗
              .replaceAll('{{base}}', base)
              .replaceAll('{{page}}', p.toString())
              .replaceAll('{base}', base)
              .replaceAll('{page}', p.toString());
          try {
            final before = chapters.length;
            order = _parseChapters(
              parse(await _fetchHtml(pageUrl)),
              pageUrl,
              manga,
              chapters,
              seen,
              order,
            );
            if (chapters.length == before) {
              _log('分页第 $p 页无新增，停止');
              break; // 超页返回最后一页，无新增即终止
            }
          } catch (e) {
            _log('分页第 $p 页失败: $e');
            break;
          }
        }
      }
    }
    // 单行本兜底：无章节列表（如摸摸漫画单行本只有「开始阅读」按钮），
    // 取配置的兜底按钮 href 作为唯一章节。
    if (chapters.isEmpty && site.chapterFallbackLinkDom.isNotEmpty) {
      final fb = doc.querySelector(site.chapterFallbackLinkDom);
      final href = fb?.attributes['href'] ?? '';
      if (href.isNotEmpty && !href.startsWith('javascript:')) {
        final chapterUrl = _resolveUrl(href, detailUrl);
        // 单行本只有一话，章节名固定为「第一话」（避免用按钮文字「开始阅读」）
        chapters.add(
          CChapter(
            id: chapterUrl,
            sourceId: id,
            mangaId: manga.id,
            name: '第一话',
            url: chapterUrl,
            order: 0,
          ),
        );
        _log('单行本兜底章节: $chapterUrl');
      }
    }
    // chapterOrder: 0=倒序 1=正序（DOM 顺序按站点实际，按配置调整）
    if (site.chapterOrder == 0) {
      chapters.sort((a, b) => b.order.compareTo(a.order));
    }
    _log('详情+章节: $detailUrl, 章节数 ${chapters.length}');
    return (
      // ✅ 把上面解析出的状态/标签/热度**带进去** ✓ —— `CManga.copyWith` 本来就支持
      //    这三个字段 ✓（`models.dart:53-73` ✓）；传 null 时保持原值 ✓ = 安全 ✓
      manga: manga.copyWith(
        status: status ?? manga.status,
        tags: tags ?? manga.tags,
        popular: popular ?? manga.popular,
        title: title,
        cover: await _finalizeCover(cover, detailUrl),
        author: author,
        description: description,
        url: detailUrl,
        initialized: true,
      ),
      chapters: chapters,
    );
  }

  /// 解析一页章节列表，追加到 chapters（seen 去重），返回更新后的 order。
  int _parseChapters(
    Document doc,
    String pageUrl,
    CManga manga,
    List<CChapter> chapters,
    Set<String> seen,
    int order,
  ) {
    if (site.chapterLinkDom.isEmpty) return order;
    for (final a in doc.querySelectorAll(site.chapterLinkDom)) {
      final href = a.attributes['href'] ?? '';
      if (href.isEmpty || href.startsWith('javascript:')) continue;
      // 章节链接 href 模式过滤（空=不过滤；mycomic 详情页 .mt-8.mb-12 区混有推荐等非章节链接）
      if (site.chapterUrlPattern.isNotEmpty &&
          !href.contains(site.chapterUrlPattern)) {
        continue;
      }
      final chapterUrl = _resolveUrl(href, pageUrl);
      if (!seen.add(chapterUrl)) continue; // 跨页去重
      String name = a.text.trim();
      if (name.isEmpty && site.chapterNameDom.isNotEmpty) {
        final ne = a.querySelector(site.chapterNameDom);
        if (ne != null) name = ne.text.trim();
      }
      chapters.add(
        CChapter(
          id: chapterUrl,
          sourceId: id,
          mangaId: manga.id,
          name: name,
          url: chapterUrl,
          order: order++,
        ),
      );
    }
    return order;
  }

  /// 分页基础 URL：优先 chapterPagedBaseDom（meta content），否则用详情页 URL；去掉已有 page 参数。
  String _pagedBaseUrl(Document doc, String detailUrl) {
    String base = detailUrl;
    if (site.chapterPagedBaseDom.isNotEmpty) {
      final el = doc.querySelector(site.chapterPagedBaseDom);
      final c = el?.attributes['content'];
      if (c != null && c.isNotEmpty) base = c;
    }
    return base.replaceFirst(RegExp(r'[?&]page=\d+'), '');
  }

  /// 从分页容器内取最大页码数字。
  int _maxPage(Document doc, String selector) {
    final el = doc.querySelector(selector);
    if (el == null) return 1;
    var max = 1;
    for (final m in RegExp(r'\d+').allMatches(el.text)) {
      final n = int.tryParse(m.group(0)!) ?? 0;
      if (n > max) max = n;
    }
    return max;
  }

  @override
  Future<CManga> getMangaDetails(CManga manga) async =>
      (await getMangaDetailsAndChapters(manga)).manga;

  @override
  Future<List<CChapter>> getChapterList(CManga manga) async =>
      (await getMangaDetailsAndChapters(manga)).chapters;

  @override
  Future<List<String>> getChapterImages(CManga manga, CChapter chapter) async {
    final url = chapter.url ?? _resolveUrl(chapter.id);
    // 章节页 HTML 内嵌密文解密取图（imgDecodeRegex 非空，如追更漫画）：
    // 章节页嵌 base64(iv+密文)，AES-CBC 解密出图片 URL 数组 JSON。优先于 DOM/WebView 路径。
    if (site.imgDecodeRegex.isNotEmpty) {
      final decoded = await _decryptChapterImages(url);
      if (decoded.isNotEmpty) {
        _log('章节图密文解密: $url, ${decoded.length} 张');
        return site.urlRewrites == null || site.urlRewrites!.isEmpty
            ? decoded
            : decoded.map(_rewriteUrl).toList();
      }
      _log('章节图密文解密失败，回退 DOM/WebView 路径');
    }
    // URL 规律直下（imgUrlPattern 非空，如摸摸）：跳过 WebView/直连解析，
    // 失败回退原路径
    if (site.imgUrlPattern.isNotEmpty) {
      final direct = await WebViewImageFetcher().fetchByPattern(url, site);
      if (direct.isNotEmpty) return direct;
      _log('URL 规律直下失败，回退 WebView/直连取图');
    }
    if (site.useFrame == 0) {
      return _directImages(url);
    }
    final imgs = await WebViewImageFetcher().fetch(url, site);
    return site.urlRewrites == null || site.urlRewrites!.isEmpty
        ? imgs
        : imgs.map(_rewriteUrl).toList();
  }

  /// 章节页 HTML 内嵌密文解密取图（追更漫画系协议）：
  /// 章节页 HTML 里嵌 `base64(iv16+密文)` 变量，AES-CBC(key=site.imgDecodeKey) 解密
  /// 出图片 URL 数组 JSON（或 {images:[...]}，字段 site.imgDecodeDataField）。
  Future<List<String>> _decryptChapterImages(String chapterUrl) async {
    try {
      final html = await _fetchHtml(chapterUrl);
      final m = RegExp(site.imgDecodeRegex).firstMatch(html);
      if (m == null || m.groupCount < 1) {
        _log('章节图密文解密: 未匹配到密文变量');
        return [];
      }
      final bytes = base64.decode(m.group(1)!.trim());
      if (bytes.length < 16) {
        _log('章节图密文解密: 密文过短 ${bytes.length}B');
        return [];
      }
      final key = enc.Key(utf8.encode(site.imgDecodeKey));
      final iv = enc.IV(bytes.sublist(0, 16));
      final decrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
      final plain = decrypter.decryptBytes(enc.Encrypted(bytes.sublist(16)), iv: iv);
      final text = utf8.decode(plain, allowMalformed: true).trim();
      if (text.isEmpty) return [];
      final obj = jsonDecode(text);
      final urls = <String>[];
      void collect(List<dynamic> arr) {
        for (final e in arr) {
          if (e is String && e.isNotEmpty) {
            urls.add(e);
          } else if (e is Map) {
            final u = e['url'];
            if (u is String && u.isNotEmpty) urls.add(u);
          }
        }
      }

      if (obj is List) {
        collect(obj);
      } else if (obj is Map) {
        if (site.imgDecodeDataField.isNotEmpty) {
          final arr = obj[site.imgDecodeDataField];
          if (arr is List) collect(arr);
        } else if (obj['url'] is String) {
          urls.add(obj['url'] as String);
        }
      }
      return urls;
    } catch (e) {
      _log('章节图密文解密失败: $e');
      return [];
    }
  }

  /// 直连取图：Dio 章节页 HTML + imgDom/imgAttr 提取。
  ///
  /// imgLoadMode=3（站一页一图）：循环点「下一页」（nextPageSelector）
  /// 合并所有页图片，直到没有下一页 / URL 重复（防死循环）/ 超过 80 页。
  Future<List<String>> _directImages(String chapterUrl) async {
    final urls = <String>[];
    final seen = <String>{};
    var cur = chapterUrl;
    for (var p = 0; p < 80; p++) {
      final html = await _fetchHtml(cur);
      final doc = parse(html);
      if (site.imgDom.isNotEmpty) {
        for (final img in doc.querySelectorAll(site.imgDom)) {
          final u = site.imgAttr.isNotEmpty
              ? (img.attributes[site.imgAttr] ?? '')
              : (img.attributes['src'] ?? '');
          if (u.isNotEmpty && u.indexOf('data:') != 0) {
            final abs = _resolveUrl(u, cur);
            if (seen.add(abs)) urls.add(abs);
          }
        }
      }
      // 翻页合并
      if (site.imgLoadMode == 3 && site.nextPageSelector.isNotEmpty) {
        final next = doc.querySelector(site.nextPageSelector);
        final nh = next?.attributes['href'] ?? '';
        if (nh.isEmpty || nh.startsWith('javascript:')) break;
        final nu = _resolveUrl(nh, cur);
        if (nu == cur || !seen.add('__page__$nu')) break; // 防死循环
        cur = nu;
      } else {
        break;
      }
    }
    _log('直连取图: $chapterUrl, ${urls.length} 张');
    return urls;
  }

  String _elText(Element el, String? selector) {
    if (selector == null || selector.isEmpty) return '';
    return el.querySelector(selector)?.text.trim() ?? '';
  }

  String? _elAttr(Element el, String? selector, String attr) {
    if (selector == null || selector.isEmpty) return null;
    return el.querySelector(selector)?.attributes[attr];
  }

  /// 取图片真实 URL：依次试 src/data-src/data-original/data-lazy-src/data-url，
  /// 跳过空值、data: 占位与 blob:（blob 仅在 WebView 上下文有效，Dio 外不可加载；
  /// 对应站需配置 useWebViewFetch 并由 WebViewImageFetcher 把真实地址写回 data-original）。
  String? _imgUrl(Element? img) {
    if (img == null) return null;
    for (final attr in const [
      'src',
      'data-src',
      'data-original',
      'data-lazy-src',
      'data-url',
    ]) {
      final v = img.attributes[attr];
      if (v != null &&
          v.isNotEmpty &&
          !v.startsWith('data:') &&
          !v.startsWith('blob:')) {
        return v;
      }
    }
    return img.attributes['src']; // 全占位/空时回退 src，保留原行为兜底
  }
}
