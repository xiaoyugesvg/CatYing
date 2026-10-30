import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/services/spider_service.dart';

/// 「换源后脚本槽位记忆」的回归测试（2026-10-30）。
///
/// 用户原话：
/// 「订阅JS脚本源为啥和本地JS这个切换总是出问题了，本地JS加载不出来，
///   但是在订阅JS这个里面又出现了，并且订阅里面所有的全是这个本地JS的内容」
///
/// 根因：`SpiderService` 用一组**单槽位**字段记录"引擎里现在驻留着哪个脚本"
/// （`_loadedScriptUrl` / `_loadedScriptKey` / `mainScriptUrl`）。而 Node 是
/// 单源架构 —— 换源、引擎重启、音乐/阅读模块借 Node 跑脚本都会把槽位换掉，
/// 这份记忆却不会跟着变。于是：
///   · 切到本地 JS：缓存说"已载入"⇒ 跳过 loadSource ⇒ 请求打到旧脚本上 ⇒ 404；
///   · 切回订阅：`_tryDeriveMainScript` 又把本地 JS 当成主源 ⇒ 整页都是它的内容。
///
/// 这条测试锁住"换源必须作废记忆"这个契约。
void main() {
  test('markScriptLoaded 之后 isScriptLoaded 为真', () {
    final s = SpiderService.instance;
    s.resetScriptCache();
    expect(s.isScriptLoaded('https://a.example/catvod.js'), isFalse);
    s.markScriptLoaded('https://a.example/catvod.js');
    expect(s.isScriptLoaded('https://a.example/catvod.js'), isTrue);
    expect(s.isScriptLoaded('ljs_ab12cd34ef56.js'), isFalse);
  });

  test('resetScriptCache 清掉槽位记忆与主源登记', () {
    final s = SpiderService.instance;
    s.mainScriptUrl = 'https://a.example/catvod.js';
    s.markScriptLoaded('https://a.example/catvod.js');
    expect(s.isScriptLoaded('https://a.example/catvod.js'), isTrue);

    s.resetScriptCache();

    expect(s.mainScriptUrl, isEmpty, reason: '换源后主源登记必须清空，否则会把旧源当主源');
    expect(
      s.isScriptLoaded('https://a.example/catvod.js'),
      isFalse,
      reason: '换源后不能再声称"引擎里驻留着旧脚本"',
    );
  });

  test('换源后本地 JS 不会被当成"已载入的订阅主源"', () {
    final s = SpiderService.instance;
    // 模拟：上一轮用本地 JS，槽位里驻留着 ljs_xxx.js
    s.resetScriptCache();
    s.markScriptLoaded('ljs_ab12cd34ef56.js');
    expect(s.isScriptLoaded('ljs_ab12cd34ef56.js'), isTrue);

    // 用户切回订阅（AppState.setHomeSource → resetScriptCache）
    s.resetScriptCache();

    // 此时任何"本地 JS 已载入"的断言都必须为假 —— 否则订阅请求会
    // 命中本地 JS 的 key，整页显示本地 JS 的内容。
    expect(s.isScriptLoaded('ljs_ab12cd34ef56.js'), isFalse);
    expect(s.mainScriptUrl, isEmpty);
  });

  test('空 url 一律视为未载入（防止空串命中缓存）', () {
    final s = SpiderService.instance;
    s.resetScriptCache();
    expect(s.isScriptLoaded(''), isFalse);
    expect(s.isScriptLoaded('   '), isFalse);
  });
}
