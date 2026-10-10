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
/// ── 安全设计：失败/空结果一律返回 null ───────────────────────
/// ⇒ 回落 Node（现行为不变）。所以开启本层**不会让原本能用的源变坏**，
/// 只会让"Node 跑不通、Dart 引擎跑得通"的源多一条路。
///
/// ── 已知取舍（如实标注）──────────────────────────────────────
/// · `bsExplore`（发现页）**暂未接管** ⇒ 返回 null 走 Node（其分类/列表契约
///   与 `ExploreResult` 的映射还需单独核对）。
/// · `bsContent` **同时回 `content` 与 `images`**（不再二选一）✓ ——
///   客户端按「正文是否为空」（漫画源则「有没有图」）判定是否进图片模式 ✓。
/// · 目录字段名差异已处理：引擎给 `title`，服务契约要 `name`。
library;

import 'package:flutter/foundation.dart';

// ⚠️ 本文件在 lib/reading/services/ 下，而引擎在 lib/reading/novel_source/
// ⇒ 相对路径必须带 novel_source/ 前缀（首次交付时漏了，导致 19 个
//   uri_does_not_exist / undefined_class 编译错误 —— 已修）
import '../novel_source/model/book_source.dart';
import '../novel_source/model/search_book.dart';
import '../novel_source/model/xiaoshuo_book.dart';
import '../novel_source/novel_block.dart';
import '../novel_source/web_book/web_book.dart';
import '../novel_source/web_book/runner_isolate.dart';

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
  };

  /// 处理一个 `bs*` 动作；**返回 null 表示"交给 Node"**。
  Future<Map<String, dynamic>?> handle(Map<String, dynamic> body) async {
    if (!enabled) return null;
    final action = body['action']?.toString() ?? '';
    if (!_supported.contains(action)) return null;
    final raw = body['source'];
    if (raw is! Map) return null;

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
          if (list.isEmpty) return null; // 空结果 ⇒ 交给 Node（现行为不变）
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
          if (books.isEmpty) return null; // 空结果 ⇒ 交给 Node（现行为不变）
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
          if (chapters.isEmpty) return null;
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
          if (text.isEmpty && imgs.isEmpty) return null; // 空正文 ⇒ 交给 Node
          return <String, dynamic>{
            'ok': true,
            'content': text,
            if (imgs.isNotEmpty) 'type': 'images',
            if (imgs.isNotEmpty) 'images': imgs,
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
