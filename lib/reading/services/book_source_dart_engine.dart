/// 书源 **Dart 原生引擎**接入层（P4）：让 `BookSourceService._call` 的 `bs*`
/// 动作走恢复出来的原生 legado 引擎（`lib/reading/novel_source/*`），
/// 从而让**含 `@js:` / `<js>` 的书源也能在 Dart 侧跑**（不再必须依赖 Node）。
///
/// ── 为什么需要它 ─────────────────────────────────────────────
/// 现有分层（`book_source_service.dart`）是：
///   1. config 明文源 → `ConfigBookSource`（Dart）
///   2. **非 JS** legado 源 → `ConfigBookSource(legadoToConfig(raw))`（Dart，绕行）
///   3. 其余（**含 JS 的源**）→ Node（`bs*` 动作）
///
/// 第 2、3 层的门槛是 `legadoNeedsNode(raw)`，其注释写着"Dart 跑不了 JS"。
/// 现在 Dart 侧已有 **quickjs 引擎 + 同步宿主桥 + 宿主方法表**（补丁 0005/0007/0008），
/// 这个前提不再成立 ⇒ 第 3 层的源可以改走原生 legado 引擎（语义比
/// `legadoToConfig` 绕行更完整）。
///
/// ── 接法（最小侵入）──────────────────────────────────────────
/// **只替换传输层**：在 `_call(body)` 开头先试本类，返回 `null` 即回落 Node。
/// 因此 `searchOne` / `explore` / `bookInfoChecked` / `toc` / `content` /
/// `healthCheck` 等**全部调用方一行都不用改**，契约形状保持一致：
///
/// | action | 返回形状 |
/// |---|---|
/// | `bsSearch` | `{ok:true, list:[{name,author,bookUrl,coverUrl,intro,kind,lastChapter,wordCount}]}` |
/// | `bsBookInfo` | `{ok:true, info:{name,author,coverUrl,intro,lastChapter}}` |
/// | `bsToc` | `{ok:true, list:[{name,url}]}` |
/// | `bsContent` | `{ok:true, content:'…'}` 或 `{ok:true, type:'images', images:[…]}` |
///
/// ── 安全设计：失败/未接管返回 null；"成功但为空"返回 empty 标记 ──
/// · `null` = 本层没接管（扁平规则、解析异常）⇒ 回落下一层；
/// · `{ok:true, list:[], empty:true}` = 本层跑通但没有结果。
///   `_call` 见到 empty 只再回落 **Node 一次**（跳过 Python / QuickJS，
///   它们会对同一站点、同一套规则重复抓取），Node 也没内容就交回这份空结果。
///   2026-10-23 之前空结果直接返回 null ⇒ 同一关键词最多打 4 次站点。
///
/// ── 已知取舍（如实标注）──────────────────────────────────────
/// · 六个动作（bsSearch / bsExplore / bsBookInfo / bsToc / bsContent / bsLogin）
///   均已接管；失败/异常返回 null，空结果返回 `empty: true`（见上）。
/// · `bsLogin` 仅处理表单 POST + Set-Cookie 提取；登录态写在 body 里的站点
///   （如返回 token JSON）会因无 Set-Cookie ⇒ 返回 null ⇒ 回落 Node。
/// · `bsContent` **同时回 `content` 与 `images`**（不再二选一）✓ ——
///   客户端按「正文是否为空」（漫画源则「有没有图」）判定是否进图片模式 ✓。
/// · 目录字段名差异已处理：引擎给 `title`，服务契约要 `name`。
library;

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

// ⚠️ 本文件在 lib/reading/services/ 下，而引擎在 lib/reading/novel_source/
// ⇒ 相对路径必须带 novel_source/ 前缀（首次交付时漏了，导致 19 个
//   uri_does_not_exist / undefined_class 编译错误 —— 已修）
import 'package:tvbox/reading/novel_source/model/book_source.dart';
import 'package:tvbox/reading/novel_source/model/search_book.dart';
import 'package:tvbox/reading/novel_source/model/xiaoshuo_book.dart';
import 'package:tvbox/reading/novel_source/novel_block.dart';
import 'package:tvbox/reading/novel_source/web_book/web_book.dart';
import 'package:tvbox/reading/novel_source/web_book/runner_isolate.dart';
import 'package:tvbox/reading/source/global_proxy.dart';

/// 书源 Dart 原生引擎接入层（进程级单例）。
class BookSourceDartEngine {
  BookSourceDartEngine._();
  static final BookSourceDartEngine instance = BookSourceDartEngine._();

  /// 是否启用。
  ///
  /// **默认 true**：先走 Dart，异常/空结果自动回落 Node
  /// （见文件头"安全设计"）。要回退到补丁前行为，置 false 即可。
  static bool enabled = true;

  /// 本层接管的动作（其余一律返回 null 交给 Node）。
  static const Set<String> _supported = {
    'bsSearch',
    'bsExplore',
    'bsBookInfo',
    'bsToc',
    'bsContent',
    'bsLogin',
  };

  /// 登录专用 Dio：关重定向（302 响应头才有 Set-Cookie）、短超时、
  /// 宽松状态码（登录失败常返回 4xx，要取响应体判断）。
  static Dio? _loginDio;
  static Dio get _loginClient {
    if (_loginDio == null) {
      final d = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        followRedirects: false,
        validateStatus: (s) => s != null && s < 600,
      ));
      d.options.headers.addAll({
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        'Accept': '*/*',
      });
      // ✅ 与 `BookSourceService._createDio()` / `SourceSubscriptionStore` 同口径：
      //   用户开了「网络代理」时登录请求也要走代理 —— 否则"能搜到书、
      //   登录接口却直连不通"（很多书源站需要登录才给正文）。
      //   本 Dio 没有自定义 HttpClient 工厂（UA 在 header 里），挂代理安全。
      applyGlobalProxy(d);
      _loginDio = d;
    }
    return _loginDio!;
  }

  /// 处理一个 `bs*` 动作；**返回 null 表示"交给 Node"**。
  Future<Map<String, dynamic>?> handle(Map<String, dynamic> body) async {
    if (!enabled) return null;
    final action = body['action']?.toString() ?? '';
    if (!_supported.contains(action)) return null;
    final raw = body['source'];
    if (raw is! Map) return null;

    // 扁平 Legado 源（老式字段：ruleSearchUrl / ruleSearchList /
    // ruleChapterList / ruleBookContent …）不在本引擎的解析范围内：
    // `XiaoshuoBookSource` 只读嵌套 ruleSearch/ruleToc/ruleContent。
    // 直接交给 Node —— 那边的 normalizeLegadoSource 会做扁平→嵌套归一化，
    // 且支持 `@Header:` / `searchKey` / `-` 倒序等老式写法。
    final hasFlatRules = raw['ruleSearchUrl'] != null ||
        raw['ruleSearchList'] != null ||
        raw['ruleChapterList'] != null ||
        raw['ruleBookContent'] != null;
    final hasNestedRules = raw['ruleSearch'] is Map ||
        raw['ruleToc'] is Map ||
        raw['ruleContent'] is Map;
    if (hasFlatRules && !hasNestedRules) return null;

    final XiaoshuoBookSource source;
    try {
      source = XiaoshuoBookSource.fromJson(raw.cast<String, dynamic>());
    } catch (e) {
      debugPrint('[书源/Dart引擎] 书源解析失败，回落 Node：$e');
      return null;
    }

    try {
      switch (action) {
        case 'bsSearch':
          final list = await BookSourceRunner.instance.searchBook(
            source: source,
            key: body['keyword']?.toString() ?? '',
            page: body['page'] is int ? body['page'] as int : 1,
          );
          // 空结果不再返回 null：null 的含义是"本层没接管"，会被 Python /
          // QuickJS / Node 各自重新打一次同一个站点（同一关键词最多 4 次请求）。
          // 这里如实返回 `{ok:true, list:[], empty:true}`，由 `_call` 只再回落
          // Node **一次**（Node 也没有内容时才把这份空结果交回上层）。
          if (list.isEmpty) {
            return <String, dynamic>{
              'ok': true,
              'list': const <Map<String, dynamic>>[],
              'empty': true,
            };
          }
          return <String, dynamic>{
            'ok': true,
            'list': list.map(_searchItem).toList(),
          };

        case 'bsExplore':
          // [PATCH-13] 发现页。两种形态（契约见 book_source_service.dart）：
          //   · categoryUrl 为空 ⇒ 解析 exploreUrl 返回 {categories:[{title,url}]}
          //     （**纯解析、无网络** ⇒ 主 isolate 直接算，不必 spawn isolate）
          //   · categoryUrl 非空 ⇒ 抓分类页返回 {list:[…]}
          final categoryUrl = body['categoryUrl']?.toString() ?? '';
          if (categoryUrl.isEmpty) {
            final cats = WebBook().getExploreCategories(source);
            if (cats.isEmpty) return null; // 无分类 ⇒ 交给 Node
            return <String, dynamic>{
              'ok': true,
              'categories': cats
                  .map((c) => <String, dynamic>{'title': c.name, 'url': c.url})
                  .toList(),
            };
          }
          final books = await BookSourceRunner.instance.exploreBooks(
            source: source,
            categoryUrl: categoryUrl,
            page: body['page'] is int ? body['page'] as int : 1,
          );
          if (books.isEmpty) {
            // 同 bsSearch：如实标记"成功但为空"，只让 `_call` 回落一次 Node
            return <String, dynamic>{
              'ok': true,
              'list': const <Map<String, dynamic>>[],
              'empty': true,
            };
          }
          return <String, dynamic>{
            'ok': true,
            'list': books.map(_bookItem).toList(),
          };

        case 'bsBookInfo':
          final b = await BookSourceRunner.instance.getBookInfo(
            source: source,
            bookUrl: body['bookUrl']?.toString() ?? '',
          );
          return <String, dynamic>{
            'ok': true,
            'info': <String, dynamic>{
              'name': b.name,
              'author': b.author,
              'coverUrl': b.coverUrl ?? '',
              'intro': b.intro ?? '',
              'lastChapter': b.lastChapter ?? '',
              // 详情页「更新时间」用：引擎已按 ruleBookInfo.updateTime 解析进
              // `book.updateTime`，但原先没透传 ⇒ 详情页永远拿不到（
              // 页面上读的键是 updatedAt/lastUpdate，也对不上）。
              'updateTime': b.updateTime ?? '',
              // 详情页解析出的目录地址：为空说明该源的 ruleBookInfo.tocUrl
              // 没算出结果（很多榜单类 bookUrl 不是详情接口 ⇒ 目录必然空）
              'tocUrl': b.tocUrl ?? '',
            },
          };

        case 'bsToc':
          // 契约给的是 `tocUrl`；引擎的 `getChapterList` 读
          // `book.tocUrl ?? book.bookUrl` ⇒ 放进 bookUrl 即可生效。
          final tocUrl = body['tocUrl']?.toString() ?? '';
          final chapters = await BookSourceRunner.instance.getChapterList(
            source: source,
            book: XiaoshuoBook(bookUrl: tocUrl, name: ''),
          );
          if (chapters.isEmpty) {
            // 目录为空通常是"规则没解析出来"：保留 Node 兜底（历史上
            // QQ 阅读等源只有 Node 能解析，见 book_source_service 的 PATCH-24），
            // 但用 empty 标记让 `_call` **只回落一次**，不再走 py/qjs 重复抓。
            return <String, dynamic>{
              'ok': true,
              'list': const <Map<String, dynamic>>[],
              'empty': true,
            };
          }
          return <String, dynamic>{
            'ok': true,
            'list': chapters
                .map((c) => <String, dynamic>{'name': c.title, 'url': c.url})
                .toList(),
          };

        case 'bsContent':
          final r = await BookSourceRunner.instance.getContent(
            source: source,
            chapterUrl: body['chapterUrl']?.toString() ?? '',
          );
          final text = r.blocks
              .whereType<NovelTextBlock>()
              .map((b) => b.text)
              .join('\n')
              .trim();
          final imgs = r.blocks
              .whereType<NovelImageBlock>()
              .map((b) => b.url)
              .where((u) => u.isNotEmpty)
              .toList();
          // ✅ **同时回 content 与 images**（不再二选一）：
          //   原来「有文字就丢图、纯图才回 images」✗ ⇒ 契约无法表达图文混排，
          //   且客户端只能靠「images 非空」猜是否图片章 ⇒ 有插图的文字章被
          //   整章渲染成图片、正文全丢 ✗。
          //   现在由**客户端**按「正文是否为空」判定纯图（见阅读器 `_loadChapter`）✓
          if (text.isEmpty && imgs.isEmpty) {
            // 空正文：保留 Node 兜底（规则差异），但标记 empty 只回落一次
            return <String, dynamic>{
              'ok': true,
              'content': '',
              'empty': true,
            };
          }
          return <String, dynamic>{
            'ok': true,
            'content': text,
            if (imgs.isNotEmpty) 'type': 'images',
            if (imgs.isNotEmpty) 'images': imgs,
          };

        case 'bsLogin':
          // 表单登录：POST 到登录接口，从 Set-Cookie 响应头提取 Cookie。
          // 契约：{ok, cookie, error}；调用方把 cookie 写进书源 header。
          // ⚠️ 登录接口常返回 302 并在响应头带 Set-Cookie ⇒ 必须关重定向，
          //   否则 Dio 跟随跳转后最终响应里拿不到 Set-Cookie。
          final loginUrl = body['url']?.toString() ?? '';
          if (loginUrl.isEmpty) return null;
          final method = (body['method']?.toString() ?? 'POST').toUpperCase();
          final contentType =
              body['contentType']?.toString() ??
                  'application/x-www-form-urlencoded';
          final fields = body['body'];
          final reqHeaders = <String, String>{};
          if (body['headers'] is Map) {
            for (final e in (body['headers'] as Map).entries) {
              reqHeaders[e.key.toString()] = e.value.toString();
            }
          }
          Object? reqData;
          if (fields is Map) {
            if (contentType.contains('json')) {
              reqData = fields.map(
                  (k, v) => MapEntry(k.toString(), v));
            } else {
              // form-urlencoded：Dio 自动编码
              reqData = fields.map(
                  (k, v) => MapEntry(k.toString(), v.toString()));
            }
          }
          final opts = Options(
            method: method,
            headers: {
              ...reqHeaders,
              'Content-Type': contentType,
            },
          );
          final resp = await _loginClient.request(
            loginUrl,
            data: reqData,
            options: opts,
          );
          // 从所有响应头提取 Set-Cookie（Dio 把同名多值合成 List）
          final setCookies = resp.headers['set-cookie'] ?? <String>[];
          final cookieParts = <String>[];
          for (final sc in setCookies) {
            // 只取第一个 ; 之前的 name=value（丢弃 expires/path/domain 等属性）
            final first = sc.split(';').first.trim();
            if (first.isNotEmpty) cookieParts.add(first);
          }
          final cookie = cookieParts.join('; ');
          if (cookie.isEmpty) {
            // 没有 Set-Cookie 不算成功 ⇒ 回落 Node（有些站登录态在 body 里，
            // Node 引擎可能有更完整的处理）
            return null;
          }
          return <String, dynamic>{
            'ok': true,
            'cookie': cookie,
          };
      }
    } catch (e) {
      debugPrint('[书源/Dart引擎] $action 失败，回落 Node：$e');
      return null;
    }
    return null;
  }

  /// `SearchBook` → 服务契约的搜索条目。
  ///
  /// 字段名对照（已核实 `search_book.dart` 的 `toJson`）：
  /// 引擎 `bookUrl/name/author/coverUrl/kind/lastChapter/wordCount`
  /// ↔ 契约 `bookUrl/name/author/coverUrl/kind/lastChapter/wordCount`
  /// （`intro` 引擎侧没有 ⇒ 空串，与 Node 路径缺字段时的行为一致）。
  /// `XiaoshuoBook` → 服务契约的书籍条目（发现页用；字段对照 `toJson`）。
  static Map<String, dynamic> _bookItem(XiaoshuoBook b) => <String, dynamic>{
        'name': b.name,
        'author': b.author,
        'bookUrl': b.bookUrl,
        'coverUrl': b.coverUrl ?? '',
        'intro': b.intro ?? '',
        'kind': b.kind ?? '',
        'lastChapter': b.lastChapter ?? '',
        'wordCount': b.wordCount ?? '',
      };

  static Map<String, dynamic> _searchItem(SearchBook b) => <String, dynamic>{
        'name': b.name,
        'author': b.author,
        'bookUrl': b.bookUrl,
        'coverUrl': b.coverUrl ?? '',
        'kind': b.kind ?? '',
        'lastChapter': b.lastChapter ?? '',
        'wordCount': b.wordCount ?? '',
      };
}
