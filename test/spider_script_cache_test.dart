import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/services/nodejs_manager.dart';
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

  // ── 2026-10-31：上面 4 条只锁住了"原语"，没锁住"有没有被调用" ──────
  //
  // 用户追问「猫源脚本和本地 JS 订阅串这个解决了吗？」时发现：10-30 那轮
  // 只在 `setHomeSource`（**用户手动换源**）里加了 `resetScriptCache()`，
  // 而**切换订阅**走的是另一条路：
  //   loadConfigs → _parseConfig → _restoreHomeSource → 直接赋值 homeSourceBean
  // 那条路换了主页源却不清槽位 ⇒ 引擎里驻留的还是上一个订阅 / 本地 JS 的
  // 脚本，槽位记忆却说"已载入" ⇒ 跳过 loadSource ⇒ 新订阅页面全是旧源内容。
  //
  // 这类 bug 的共同形状是「**新增一个换源入口，忘了清槽位**」——
  // 原语测一万遍也测不出来，因为它压根没被调用。所以这里直接钉住入口：
  group('换源入口必须作废脚本槽位', () {
    test('api_config 里只允许两处直接赋值 homeSourceBean.value', () {
      final f = File('lib/services/api_config.dart');
      expect(f.existsSync(), isTrue, reason: '找不到 ${f.path}（测试的工作目录应是项目根）');
      final lines = f.readAsLinesSync();
      final hits = <String>[];
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('homeSourceBean.value =')) {
          hits.add('${i + 1}: ${lines[i].trim()}');
        }
      }
      // 只允许：`_adoptHomeSource`（配置解析期）与 `setHomeSource`（用户手动换源）。
      // 两者都会作废脚本槽位；其它任何地方直接赋值都会让"引擎里驻留着谁"的
      // 记忆与主页源脱节 —— 就是「串」。
      expect(
        hits.length,
        2,
        reason: '直接赋值 homeSourceBean.value 的地方变成了 ${hits.length} 处：\n'
            '${hits.join('\n')}\n'
            '新增换源入口请走 _adoptHomeSource(source)，它会顺带 resetScriptCache()。',
      );
    });

    test('_adoptHomeSource 里确实调了 resetScriptCache', () {
      final src = File('lib/services/api_config.dart').readAsStringSync();
      final start = src.indexOf('void _adoptHomeSource(');
      expect(start, greaterThan(-1), reason: '_adoptHomeSource 被删了？');
      // 取到下一个方法声明为止（够用：这两个方法之间没有别的方法）
      final end = src.indexOf('Future<void> setHomeSource(', start);
      expect(end, greaterThan(start));
      final body = src.substring(start, end);
      expect(
        body.contains('resetScriptCache()'),
        isTrue,
        reason: '_adoptHomeSource 换完主页源却没作废脚本槽位 ⇒ 又会出现「串」',
      );
    });
  });

  group('纯查询不能有副作用', () {
    test('isScriptLoaded 不该顺手把 Node 引擎拉起来', () {
      // 背景：4923048 为了对齐槽位，在 isScriptLoaded 里调了
      // _syncSlotFromEngine()，而它直接取 `NodeJSManager.instance` ——
      // 那是懒加载单例，构造里会 initialize 平台通道。
      // 后果：查一次「载入了吗」= 拉起整个 Node 引擎（几百 MB + 端口），
      // 在没有 WidgetsBinding 的环境里还会直接抛断言（本文件 3 条用例全红）。
      if (NodeJSManager.existing != null) {
        // 本进程里引擎已经被别的用例建起来了，这条没法验
        return;
      }
      SpiderService.instance.isScriptLoaded('https://example.com/a.js');
      expect(
        NodeJSManager.existing,
        isNull,
        reason: 'isScriptLoaded 是热路径（每次页面请求都问），'
            '它只能读引擎状态，不能创建引擎',
      );
    });
  });
}
