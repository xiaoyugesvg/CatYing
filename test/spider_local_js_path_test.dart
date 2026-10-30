import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/services/spider_service.dart';

/// 「本地 JS 源请求路径拼错」的回归测试（2026-10-30）。
///
/// ── 用户报的两个现象 ────────────────────────────────────────────
/// 1. 「本地JS还是没有内容」
/// 2. 「切换 JS 订阅后发现所有的 JS 订阅里面全是那个本地 JS 的内容」
///
/// ── 同一个根因 ──────────────────────────────────────────────────
/// `spiderApiBase()`（原 `_nodeBase`）只排除 `csp_` 与 `http`，
/// **其余一律当成路径基址**。而本地 JS 源的 api 是 `ljs_xxx.js` ——
/// 于是拼出：
///     POST http://127.0.0.1:<port>/ljs_xxx.js/home
/// 引擎的真实路由却是 `/spider/<key>/<type>/<action>` ⇒ **必然 404**
/// ⇒ 本地 JS「没有内容」。
///
/// 而 404 会触发 `_dispatchScript` 的「强制重载」自愈，重载的还是那个本地脚本
/// ⇒ 引擎槽位**反复被本地 JS 占着**；订阅线路（api 为空 / `csp_` 占位）
/// 于是也全都落到它身上 ⇒「订阅里全是本地 JS 的内容」。
void main() {
  group('spiderApiBase：脚本地址不是路径基址', () {
    test('本地 JS 源 ljs_xxx.js → 空串（走标准 /spider/<key>/<type>/<action>）', () {
      expect(spiderApiBase('ljs_ab12cd34ef56.js'), '');
    });

    test('远端 .js → 空串', () {
      expect(spiderApiBase('https://a.example.com/spider/index.js'), '');
      expect(spiderApiBase('https://a.example.com/spider/index.js.md5'), '');
    });

    test('csp_ 占位 → 空串', () {
      expect(spiderApiBase('csp_makka'), '');
    });

    test('空 api → 空串', () {
      expect(spiderApiBase(''), '');
    });

    test('OmniBox 私有协议 /spider/<key>/<type> → 保留（这才是路径基址）', () {
      expect(
        spiderApiBase('/spider/omnibox_Makka聚合/3'),
        '/spider/omnibox_Makka聚合/3',
      );
    });

    test('反引号包裹的远端脚本也要归一化后判定为空串', () {
      // 配置里常见 "api": "`https://x/index.js`"
      expect(spiderApiBase('`https://x.example.com/index.js`'), '');
    });
  });

  group('composeSpiderPath', () {
    test('本地 JS：拼出 /spider/<key>/<type>/<action>', () {
      final base = spiderApiBase('ljs_ab12cd34ef56.js');
      expect(
        composeSpiderPath('ljs_ab12cd34ef56', 3, base, 'home'),
        '/spider/ljs_ab12cd34ef56/3/home',
      );
    });

    test('OmniBox：api 自带基址，只接 action', () {
      expect(
        composeSpiderPath('omnibox_Makka聚合', 3, '/spider/omnibox_Makka聚合/3', 'home'),
        '/spider/omnibox_Makka聚合/3/home',
      );
    });

    test('nodejs_ 前缀要去掉（客户端显示前缀，引擎不认）', () {
      expect(
        composeSpiderPath('nodejs_abc', 3, '', 'home'),
        '/spider/abc/3/home',
      );
    });
  });

  group('localScriptKeyOf：本地脚本的引擎 key', () {
    test('ljs_xxx.js → ljs_xxx', () {
      expect(localScriptKeyOf('ljs_ab12cd34ef56.js'), 'ljs_ab12cd34ef56');
    });

    test('不是本地脚本 → null', () {
      expect(localScriptKeyOf('https://x/index.js'), isNull);
      expect(localScriptKeyOf('localjs_ljs_abc'), isNull);
      expect(localScriptKeyOf(''), isNull);
    });
  });

  group('SourceBean.isLocalScriptApi：选主源时要跳过它', () {
    SourceBean bean(String api, {String key = 'k'}) =>
        SourceBean(key: key, name: 'n', api: api, type: 3);

    test('ljs_xxx.js 是本地脚本', () {
      expect(bean('ljs_ab12.js').isLocalScriptApi, isTrue);
    });

    test('file:// 是本地脚本', () {
      expect(bean('file:///a/b.js').isLocalScriptApi, isTrue);
    });

    test('http(s) 订阅脚本不是', () {
      expect(bean('https://x/index.js').isLocalScriptApi, isFalse);
      expect(bean('http://x/index.js').isLocalScriptApi, isFalse);
    });

    test('空 api 不是（那是 csp_/占位形态，另有分支处理）', () {
      expect(bean('').isLocalScriptApi, isFalse);
    });
  });
}
