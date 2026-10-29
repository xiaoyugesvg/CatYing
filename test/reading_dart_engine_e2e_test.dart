import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/reading/novel_source/analyze/js_engine.dart';
import 'package:tvbox/reading/novel_source/model/book_source.dart';
import 'package:tvbox/reading/novel_source/web_book/web_book.dart';

/// **决定性验证：Dart 原生引擎（含 quickjs @js）到底能不能用。**
///
/// ── 为什么需要它 ────────────────────────────────────────────────
/// "Dart 引擎能用了么"这件事**不能靠读代码回答** ——
/// 本项目已经出现过一次假象：`flutter test` 缺
/// `quickjs_c_bridge_plugin.dll` 时，`JsEngine.eval` 每次返回空、
/// `lastError=null`，看起来**和"@js 规则没生效"一模一样** ✗
///
/// ⇒ 判据必须是**真的跑通一个带 @js 的源**：
///   1. `tocUrl` 是 `@js:` 规则（`/xs/88675.html` → `/shu/88675/`）
///   2. 目录能解析出几十章
///
/// ⚠️ 依赖外网 + 本机需能加载 quickjs 原生库；不满足时**跳过而非失败**
///    （避免变成脆弱测试），但会把原因打出来。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Dart 引擎：带 @js 的真实书源，搜索→详情→目录', () async {
    // ── ① 前置：quickjs 原生库可用吗（否则 JS 路径全是假的）──
    String probe;
    try {
      probe = JsEngine.shared.eval('1+1');
    } catch (e) {
      // ignore: avoid_print
      print('[probe] ⚠️ 跳过：quickjs 原生库加载失败 → $e\n'
          '         （把 quickjs_c_bridge_plugin.dll 放到项目根目录即可在本机测 @js）');
      return;
    }
    if (probe != '2') {
      // ignore: avoid_print
      print('[probe] ⚠️ 跳过：quickjs 求值拿不到结果（eval("1+1")="$probe"）'
          ' → 缺原生库或引擎不可用');
      return;
    }
    // ignore: avoid_print
    print('[probe] ✅ quickjs 可用（eval("1+1")=2）');

    final raw = await rootBundle.loadString('assets/config/legado_sources.json');
    final all = (jsonDecode(raw) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final pick = all
        .firstWhere((e) => '${e['bookSourceName'] ?? ''}'.contains('绿色小说'));

    final xs = XiaoshuoBookSource.fromJson(pick);
    final wb = WebBook();

    // ── ② 搜索 ──
    final list = await wb.searchBook(source: xs, key: '剑');
    // ignore: avoid_print
    print('[probe] 搜索返回 ${list.length} 条');
    expect(list, isNotEmpty, reason: 'Dart 引擎应当能搜到结果');

    // ── ③ 详情（tocUrl 由 @js 规则算出）──
    final info =
        await wb.getBookInfo(source: xs, bookUrl: '${list.first.bookUrl}');
    // ignore: avoid_print
    print('[probe] 详情: name=${info.name}  tocUrl=${info.tocUrl}');
    expect('${info.tocUrl}', contains('/shu/'),
        reason: 'tocUrl 规则是 '
            "@js:baseUrl.replace(/\\/xs\\/(\\d+)\\.html/, '/shu/\$1/') "
            '⇒ 必须变成 /shu/<id>/；若仍是 /xs/... 说明 @js 没生效');

    // ── ④ 目录（"Dart 引擎能用"的核心判据）──
    final chapters = await wb.getChapterList(source: xs, book: info);
    // ignore: avoid_print
    print('[probe] ✅ 目录 ${chapters.length} 章');
    for (final c in chapters.take(3)) {
      // ignore: avoid_print
      print('[probe]      ${c.title} → ${c.url}');
    }
    expect(chapters.length, greaterThan(10),
        reason: '该书有几百章；解析出个位数说明目录规则没跑对');
  }, timeout: const Timeout(Duration(seconds: 180)));
}
