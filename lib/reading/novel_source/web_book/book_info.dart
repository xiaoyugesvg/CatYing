/// 书籍详情解析：依据书源 `ruleBookInfo` 解析书名/作者/简介/封面/目录 URL 等字段。
library;

import '../model/book_source.dart';
import '../model/xiaoshuo_book.dart';
import '../analyze/analyze_rule.dart';
import '../../../services/app_log.dart';

class BookInfo {
  static void analyzeBookInfo({
    required XiaoshuoBookSource bookSource,
    required XiaoshuoBook book,
    required String baseUrl,
    required String? redirectUrl,
    required String body,
    bool canReName = true,
  }) {
    final bookInfoRule = bookSource.getBookInfoRule();
    final analyzeRule = AnalyzeRule(book: book)
      ..setContent(body, redirectUrl ?? baseUrl)
      ..setBaseUrl(baseUrl)
      ..setRedirectUrl(redirectUrl ?? baseUrl);

    if (bookInfoRule.init != null && bookInfoRule.init!.isNotEmpty) {
      try {
        var initContent = analyzeRule.getElement(bookInfoRule.init!);
        // JS 返回对象时 QuickJS 只给 `[object Object]`：用 JSON.stringify
        // 再求值一次，拿到 `{a:…}` 供后续字段按 key 取值（官方 init 约定）。
        if ('$initContent' == '[object Object]') {
          final json = analyzeRule.evalJsObjectJson(bookInfoRule.init!);
          if (json.isNotEmpty) initContent = json;
        }
        if (initContent != null) {
          analyzeRule.setContent(initContent);
          AppLog.instance
              .d('[书源详情] init规则命中: ${initContent.toString().length}字符');
        } else {
          AppLog.instance.w('[书源详情] init规则未命中: ${bookInfoRule.init}');
        }
      } catch (e) {
        AppLog.instance.w('[书源详情] init规则异常: ${bookInfoRule.init} → $e');
      }
    }

    // Legado 官方逻辑（BookInfo.kt）：
    //   mCanReName = canReName && !infoRule.canReName.isNullOrBlank()
    // 即「canReName 字段**非空**」才允许用详情页书名/作者覆盖；为空则保留
    // 搜索页拿到的书名/作者。此前条件写反了（非空反而不覆盖），导致
    // 声明了 canReName 的源永远更新不了书名/作者。
    final canReNameFlag =
        canReName && (bookInfoRule.canReName?.trim().isNotEmpty ?? false);

    if (bookInfoRule.name != null && bookInfoRule.name!.isNotEmpty) {
      try {
        final name = _formatBookName(analyzeRule.getString(bookInfoRule.name!));
        if (name.isNotEmpty && (canReNameFlag || book.name.isEmpty)) {
          book.name = name;
        }
      } catch (_) {}
    }

    if (bookInfoRule.author != null && bookInfoRule.author!.isNotEmpty) {
      try {
        final author = _formatBookAuthor(analyzeRule.getString(bookInfoRule.author!));
        if (author.isNotEmpty && (canReNameFlag || book.author.isEmpty)) {
          book.author = author;
        }
      } catch (_) {}
    }

    if (bookInfoRule.kind != null && bookInfoRule.kind!.isNotEmpty) {
      try {
        final kinds = analyzeRule.getStringList(bookInfoRule.kind!);
        if (kinds.isNotEmpty) {
          book.kind = kinds.join(',');
          if (book.kind!.length > 1000) book.kind = book.kind!.substring(0, 1000);
        }
      } catch (_) {}
    }

    if (bookInfoRule.lastChapter != null && bookInfoRule.lastChapter!.isNotEmpty) {
      try {
        final lastChapter = analyzeRule.getString(bookInfoRule.lastChapter!);
        if (lastChapter.isNotEmpty) {
          book.lastChapter = lastChapter;
        }
      } catch (_) {}
    }

    if (bookInfoRule.intro != null && bookInfoRule.intro!.isNotEmpty) {
      try {
        final intro = analyzeRule.getString(bookInfoRule.intro!);
        if (intro.isNotEmpty) {
          // 🔴 还原源站简介里的**字面 `\n`**（实测「📂无极书院」：
          //    `intro = "class.nrjj@class.e@text"` 抓到的原文含 `\n　`，
          //    直接显示出来就是"…妖魔横行！\n林长青一朝穿越…" ✗
          //    —— 详情页那个 `intro.contains('\n')` 判断本就假设有真换行 ✓）
          final clean = unescapeLineBreaks(intro);
          book.intro = clean.length > 5000 ? clean.substring(0, 5000) : clean;
        }
      } catch (_) {}
    }

    if (bookInfoRule.bookStatus != null && bookInfoRule.bookStatus!.isNotEmpty) {
      try {
        final bookStatus = analyzeRule.getString(bookInfoRule.bookStatus!);
        if (bookStatus.isNotEmpty) {
          book.bookStatus = bookStatus;
        }
      } catch (_) {}
    }

    if (bookInfoRule.updateTime != null && bookInfoRule.updateTime!.isNotEmpty) {
      try {
        final updateTime = analyzeRule.getString(bookInfoRule.updateTime!);
        if (updateTime.isNotEmpty) {
          book.updateTime = updateTime;
        }
      } catch (_) {}
    }

    if (bookInfoRule.wordCount != null && bookInfoRule.wordCount!.isNotEmpty) {
      try {
        final wordCount = analyzeRule.getString(bookInfoRule.wordCount!);
        if (wordCount.isNotEmpty) {
          book.wordCount = wordCount;
        }
      } catch (_) {}
    }

    if (bookInfoRule.recommendations != null &&
        bookInfoRule.recommendations!.isNotEmpty) {
      try {
        final recommendations =
            analyzeRule.getStringList(bookInfoRule.recommendations!);
        if (recommendations.isNotEmpty) {
          book.recommendations = recommendations
              .where((s) => s.trim().isNotEmpty)
              .map((s) => s.trim())
              .toList();
        }
      } catch (_) {}
    }

    if (bookInfoRule.coverUrl != null && bookInfoRule.coverUrl!.isNotEmpty) {
      try {
        final coverUrl = analyzeRule.getString(bookInfoRule.coverUrl!, isUrl: true);
        if (coverUrl.isNotEmpty) {
          book.coverUrl = coverUrl;
        }
      } catch (_) {}
    }

    if (bookInfoRule.tocUrl != null && bookInfoRule.tocUrl!.isNotEmpty) {
      try {
        final tocUrl = analyzeRule.getString(bookInfoRule.tocUrl!, isUrl: true);
        if (tocUrl.isNotEmpty) {
          book.tocUrl = tocUrl;
        }
      } catch (_) {}
    }

    if (book.tocUrl == null || book.tocUrl!.isEmpty) {
      book.tocUrl = redirectUrl ?? baseUrl;
    }

    // 汇总日志：书名/作者/简介/封面/目录URL 最终结果（便于真机排查
    // 「详情页解析不全」——哪一项为空一目了然）。
    AppLog.instance.d('[书源详情] 源=${bookSource.bookSourceName} '
        '书名=${book.name.isEmpty ? '(空)' : book.name} '
        '作者=${book.author.isEmpty ? '(空)' : book.author} '
        '简介=${(book.intro ?? '').length}字符 '
        '封面=${(book.coverUrl ?? '').isEmpty ? '(空)' : book.coverUrl} '
        'toc=${(book.tocUrl ?? '').isEmpty ? '(空)' : book.tocUrl}');
  }

  static String _formatBookName(String name) {
    if (name.isEmpty) return name;
    return name
        .replaceAll(RegExp(r'[【［【\[\(（]([^【［【\[\(（]*?)[】］】\]\)）]'), '')
        .replaceAll(RegExp(r'^\s*[\-_—–]+'), '')
        .replaceAll(RegExp(r'[\-_—–]+\s*$'), '')
        .trim();
  }

  static String _formatBookAuthor(String author) {
    if (author.isEmpty) return author;
    return author
        // 去除 "作者:" / "作者：" 前缀（与 book_list.formatBookAuthor 一致，
        // 用字面序列匹配而非字符类 [作者：]，后者只删首字"作"）
        .replaceAll(RegExp(r'^\s*作\s*者\s*[:：]\s*'), '')
        .replaceAll(RegExp(r'^\s*[\-_—–]+'), '')
        .replaceAll(RegExp(r'[\-_—–]+\s*$'), '')
        .trim();
  }
}

/// 把文本里**明确是转义**的换行还原为真实换行。
///
/// ── 为什么要做 ──────────────────────────────────────────────────
/// 部分书源站的简介在 HTML 里就存成**转义形态**（实测 `📂无极书院`
/// 的 `class.nrjj@class.e@text`），抓下来带的是字面的 `\n`。
/// 详情页直接 `Text(intro)` 渲染 ⇒ 用户看到"…妖魔横行！\n林长青…" ✗
///
/// ── ⚠️ 必须防的坑 ───────────────────────────────────────────────
/// 天真的 `replaceAll(r'\n', '\n')` 会**破坏含反斜杠的正常文本**：
/// ```
/// C:\Users\abc\docs\readme.txt  →  C:\Users\abc\docs<换行>eadme.txt  ✗✗
/// ```
/// （`readme` 里的 `\r` 被当成回车。）
///
/// ⇒ 判据：`\n` / `\r\n` 之后**不能紧跟字母或数字**（即处于词边界），
///    这样 `C:\new`、`C:\readme` 这类真实路径不会被误伤 ✓
///    （有对应回归测试：`test/reading_intro_unescape_test.dart`）
String unescapeLineBreaks(String s) {
  if (!s.contains(r'\')) return s;
  return s
      // \r\n → \n（先处理，避免变成两次换行）
      .replaceAll(RegExp(r'\\r\\n(?![A-Za-z0-9])'), '\n')
      // \n → 真换行（后面不能跟字母/数字）
      .replaceAll(RegExp(r'\\n(?![A-Za-z0-9])'), '\n')
      // 单独的 \r → 换行（同样要求词边界）
      .replaceAll(RegExp(r'\\r(?![A-Za-z0-9])'), '\n');
}
