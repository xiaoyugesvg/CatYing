/// 书源核心引擎**离线自测**（不依赖外网、不依赖 Node、不依赖 UI）。
///
/// 运行：
/// ```
/// flutter test test/reading_book_source_engine_selftest_test.dart
/// ```
/// （`test/` 在本仓库的 `.gitignore` 里被 `test*` 忽略 ⇒ 提交需要
///  `git add -f test/reading_book_source_engine_selftest_test.dart`；
///  只想跑不想提交则无需任何操作。）
///
/// ── 为什么要有它 ─────────────────────────────────────────────
/// 补丁 0001/0005/0006/0007/0008/0009 的验证全部止步于"静态证据"
/// （`git apply` 真应用 + `node --check` 真编译 JS + 词法括号配对），
/// **Dart 编译与运行时行为没有任何覆盖**。本文件补上这一层：
///
/// | 组 | 验证内容 | 依赖 |
/// |---|---|---|
/// | 1 | 两类宿主协议标记的解析（纯函数） | 无 |
/// | 2 | **同步 HTTP 桥真的能抓到本机响应**（`java.ajax` 的传输层） | `dart:io` 本机服务器 |
/// | 3 | 规则解析核心语义（索引后缀 / `##` 替换 / 相对 URL / HTML 实体） | 无 |
/// | 4 | JS 引擎 + 宿主调用重放 + **`java.ajax` 端到端** | 需 quickjs 原生库 |
/// | 5 | 诊断输出（JSON 路径 / CSS / 纯 `<js>`）——只打印不断言 | 视情况 |
///
/// 第 4 组在 `flutter test` 里需要 quickjs 原生库可加载
/// （`quickjs_engine` 的 `_openTestLib()` 会找包内构建产物，或读环境变量
/// `LIBQUICKJSC_TEST_PATH`）。**加载不到时本组自动跳过并打印原因**，
/// 不会产生假失败 —— 先 `flutter run -d windows` 构建一次即可让库出现。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/reading/novel_source/analyze/analyze_rule.dart';
import 'package:tvbox/reading/novel_source/analyze/host_bridge.dart';
import 'package:tvbox/reading/novel_source/analyze/cookie_store.dart';
import 'package:tvbox/reading/novel_source/analyze/http_proxy.dart';
import 'package:tvbox/reading/services/book_source_dart_engine.dart';
import 'package:tvbox/reading/novel_source/analyze/js_engine.dart';
import 'package:tvbox/reading/novel_source/analyze/sync_http_bridge.dart';

const String _html = '''
<html><body>
<div class="list">
  <div class="item"><a class="name" href="/book/1">书名一</a><span class="author">作者一</span></div>
  <div class="item"><a class="name" href="/book/2">书名二</a><span class="author">作者二</span></div>
  <div class="item"><a class="name" href="/book/3">书名三</a><span class="author">作者三</span></div>
  <div class="item"><a class="name" href="/book/4">书名&amp;四</a><span class="author">作者四</span></div>
</div>
<div class="intro">简介&nbsp;文本</div>
</body></html>
''';

/// 组7（接入层端到端）需要 **App 插件环境**（它经 isolate 走 WebBook →
/// AnalyzeUrl → 设置/代理/SharedPreferences）。`flutter test` 里没有插件实现
/// ⇒ isolate 不会返回，每个用例会干等到 60s 超时（6 个就是 6 分钟，实测会"挂住"）。
/// 因此默认**跳过**，要用时显式打开：
/// ```
/// $env:BOOK_SOURCE_E2E=1 ; flutter test test/reading_book_source_engine_selftest_test.dart
/// ```
final bool _runE2E = Platform.environment['BOOK_SOURCE_E2E'] == '1';

void main() {
  // ── 组 1：宿主协议标记解析（纯函数，必然可跑）──────────────
  group('组1 宿主协议标记解析', () {
    test('SyncHttpBridge.pendingRequest 解析同步 HTTP 请求', () {
      const err = 'Error: __LEGADO_NEED__'
          '{"k":"GET http://a.example/b","m":"GET","u":"http://a.example/b",'
          '"h":{"Referer":"http://a.example/"},"b":null}';
      final need = SyncHttpBridge.pendingRequest(err);
      expect(need, isNotNull, reason: '含 __LEGADO_NEED__ 的错误文本必须能解析出请求');
      expect(need!.url, 'http://a.example/b');
      expect(need.method, 'GET');
      expect(need.key, 'GET http://a.example/b');
      expect(need.headers['Referer'], 'http://a.example/');
    });

    test('SyncHttpBridge.pendingRequest 对无关文本返回 null', () {
      expect(SyncHttpBridge.pendingRequest('TypeError: x is not a function'),
          isNull);
      expect(SyncHttpBridge.pendingRequest(null), isNull);
    });

    test('HostBridge.pendingCall 解析宿主调用', () {
      const err = 'Error: __LEGADO_CALL__'
          '{"k":"getString|[\\"class.author.1@text\\"]","o":"getString",'
          '"a":["class.author.1@text"]}';
      final call = HostBridge.pendingCall(err);
      expect(call, isNotNull, reason: '含 __LEGADO_CALL__ 的错误文本必须能解析出调用');
      expect(call!.op, 'getString');
      expect(call.arg0, 'class.author.1@text');
    });

    test('HostBridge.normalize 把不可序列化值转成字符串', () {
      expect(HostBridge.normalize('a'), 'a');
      expect(HostBridge.normalize(1), 1);
      expect(HostBridge.normalize(<String, Object?>{'k': <Object?>[1, 'x']}),
          <String, Object?>{'k': <Object?>[1, 'x']});
      expect(HostBridge.normalize(Object()), isA<String>(),
          reason: '任意对象必须退化成字符串，否则注入 JS 时会崩');
    });

    test('未实现方法返回可读错误（不是静默空串）', () {
      final u = HostBridge.unsupported('createSymmetricCrypto');
      expect('${u['__error']}', contains('createSymmetricCrypto'));
    });
  });

  // ── 组 2：同步 HTTP 桥（java.ajax 的传输层，端到端本机验证）──
  group('组2 同步 HTTP 桥（经本机代理）', () {
    late int targetPort; // 目标站（独立 isolate；故意用 chunked 传输）
    late int proxyPort; // 本机代理（本 isolate，即"主 isolate"角色）

    setUpAll(() async {
      // ⚠️ 两条"必须分开 isolate"的硬约束（都实测撞过）：
      //  1. 同步 socket 阻塞所在 isolate 的事件循环 ⇒ 目标站不能与本 isolate 同体，
      //     否则服务器永远无法响应（实测死锁满 10 分钟直到套件超时）；
      //  2. 代理也不能与"发起同步请求的 isolate"同体 ⇒ 生产里代理在主 isolate、
      //     同步请求在 worker isolate；测试里结构完全相同（见 _syncFetchInWorker）。
      targetPort = await _startLoopbackServer();
      proxyPort = await LegadoHttpProxy.ensureStarted();
    });

    tearDownAll(() async {
      await LegadoHttpProxy.stop();
    });

    test('闸门关闭时不发请求、写入可读错误（防卡 UI）', () {
      SyncHttpBridge.allowBlockingOnCurrentIsolate = false;
      final need = SyncNeeds(
        key: 'GET http://127.0.0.1:$targetPort/gated',
        method: 'GET',
        url: 'http://127.0.0.1:$targetPort/gated',
        headers: const {},
        body: null,
      );
      expect(SyncHttpBridge.instance.fetch(need), isTrue);
      final v = SyncHttpBridge.instance.cache[need.key];
      expect(v, isA<Map>(), reason: '闸门关闭时应写入 {__error: …}');
      expect('${(v as Map)['__error']}', contains('闸门'));
    });

    test('闸门开 + 代理就绪 ⇒ 真的同步抓到响应（并覆盖 chunked 传输）', () async {
      // 目标站故意不设 Content-Length ⇒ Dart HttpServer 用 chunked。
      // sync_http 直连时会抛 'only identity transfer encoding is accepted'，
      // 经本机代理（Dio 异步、自设 Content-Length）就该正常 —— 这条正是修验证。
      final body = await _syncFetchInWorker(
          'http://127.0.0.1:$targetPort/sync', proxyPort);
      expect(body, contains('/sync'), reason: '应回显请求路径：$body');
      expect(body, contains('世界'), reason: 'UTF-8 中文不能乱码：$body');
    });

    test('同一 key 只抓一次（缓存生效，避免重复请求）', () async {
      final r = await _syncFetchInWorker(
          'http://127.0.0.1:$targetPort/cached', proxyPort, cacheProbe: true);
      expect(r, '已被改写', reason: '已命中缓存时不应重新抓取');
    });

    test('连不上的目标写入 __error（不抛异常、不死循环）', () async {
      final body = await _syncFetchInWorker('http://127.0.0.1:1/refused', proxyPort);
      expect(body, contains('__error'), reason: body);
    });

    test('代理未就绪时明确报错（而不是直连目标站）', () async {
      final body = await _syncFetchInWorker(
          'http://127.0.0.1:$targetPort/whatever', 0);
      expect(body, contains('代理未就绪'), reason: body);
    });
  });

  // ── 组 3：规则解析核心语义（实测 4878 个规则字段里的主力语法）──
  group('组3 规则解析核心语义', () {
    late AnalyzeRule rule;

    setUp(() {
      rule = AnalyzeRule()..setContent(_html, 'http://example.com/root/');
    });

    test('索引后缀 .N@ 取第 N 个（实测 872 字段 / 153 条源）', () {
      expect(rule.getString('class.author.0@text'), '作者一');
      expect(rule.getString('class.author.1@text'), '作者二');
      expect(rule.getString('class.author.2@text'), '作者三');
    });

    test('负索引 .-1@ 取最后一个', () {
      expect(rule.getString('class.author.-1@text'), '作者四');
    });

    test('class. 前缀（实测 592 字段 / 88 条源）', () {
      expect(rule.getString('class.intro@text').replaceAll('\u00a0', ' '),
          contains('简介'));
    });

    test('相对 URL 归一化（isUrl）', () {
      expect(rule.getString('tag.a.0@href', isUrl: true),
          'http://example.com/book/1');
    });

    test('## 正则替换（实测 678 字段 / 180 条源）', () {
      expect(rule.getString('class.author.0@text##作者##著者'), '著者一');
      expect(rule.getString('class.author.1@text##[一二三四]##X'), '作者X');
    });

    test('HTML 实体反转义（unescape 默认开）', () {
      final v = rule.getString('tag.a.3@text');
      expect(v, contains('&'), reason: '&amp; 应还原为 &');
    });

    // [PATCH-11] 方括号索引：legado 的 `tag.a[N]` / `[a:b]` 写法。
    // 实测 129 个规则字段 / 83 条源在用；补丁前它会被当成
    // `getElementsByTagName('a[1]')` ⇒ 空结果。
    test('方括号索引 tag.a[N]（补丁 0011）', () {
      expect(rule.getString('tag.a[0]@text'), '书名一');
      expect(rule.getString('tag.a[1]@text'), '书名二');
    });

    test('方括号区间 tag.a[1:3]（补丁 0011）', () {
      final list = rule.getStringList('tag.a[1:3]@text');
      // ⚠️ 实测：`[1:3]` 取 **3** 个（含端点 1,2,3）—— 这是本引擎
      //    `_applyIndexFilter` 的现有语义。legado 上游对 `[a:b]` 是否含右端点
      //    尚未与本引擎逐一核对（实测只有 4 个字段/4 条源用这种写法）。
      //    若上游是"半开区间"，这里应改成 2 个，并同步修 `_applyIndexFilter`。
      expect(list.length, 3, reason: '当前实现：含端点');
      expect(list.first, '书名二');
      expect(list.last, '书名&四', reason: '第 4 个 a 是 书名&amp;四（已反转义）');
    });

    test('方括号索引不误吃 CSS 属性选择器（补丁 0011）', () {
      // [property$=x] / [href] 不是索引，不能被摘掉
      final r = AnalyzeRule()
        ..setContent('<p property="a">甲</p><p>乙</p>', 'http://e.com/');
      // 属性选择器应仍能命中第 1 个 p（若被误当索引，会变成取 index 0 的第二个 p）
      expect(r.getString('[property]@text'), '甲');
    });

    // [PATCH-17] 回归：legado 前缀选择器不能被误判成 CSS
    test('legado 前缀选择器的元素获取（补丁 0017）', () {
      // class./tag. 这类写法若被判成 CSS，会走 querySelectorAll('class.item')
      // ⇒ 0 个元素 ⇒ 书源 bookList/chapterList 全空（这是"书源不好用"的根因）
      expect(rule.getElements('class.item').length, 4,
          reason: 'class. 前缀应走 legado 解析路径');
      expect(rule.getElements('tag.div').length, greaterThanOrEqualTo(4),
          reason: 'tag. 前缀同上');
      expect(rule.getElements('div.item').length, 4,
          reason: '纯 CSS 选择器仍走 CSS 路径');
      expect(rule.getElements('class.item@tag.a').length, 4,
          reason: '含 @ 的多步规则不受影响');
    });

    test('多元素规则返回多行（getStringList 长度）', () {
      final list = rule.getStringList('class.author@text');
      expect(list.length, greaterThanOrEqualTo(4),
          reason: '4 个 class.author 元素应返回 4 条');
    });
  });

  // ── 组 4：JS 引擎 + 宿主调用重放（需 quickjs 原生库）────────
  group('组4 JS 引擎与宿主桥', () {
    // ⚠️ `flutter test`（无原生库）下这里会**卡住**而不是优雅跳过：探针实测
    //    flutter_tester 10 分钟只涨 16s CPU，日志 0 字节。原因是 quickjs 原生库
    //    在 `flutter test` 里不可用，`JsEngine.shared` 的初始化会阻塞。
    //    因此本组与组7 一样改成**集成模式专用**（BOOK_SOURCE_E2E=1）。
    if (!_runE2E) {
      test('组4 已跳过（需要 quickjs 原生库：先 flutter run -d windows 构建一次）', () {
        // ignore: avoid_print
        print('[自测] 组4 跳过：quickjs 原生库在 flutter test 下不可用；'
            '设 BOOK_SOURCE_E2E=1 并在有原生库的环境运行');
      });
      return;
    }
    late bool jsOk;
    late int port;

    setUpAll(() async {
      // 同组2：服务器必须在独立 isolate（同步 socket 会阻塞本 isolate）
      port = await _startLoopbackServer();

      // ⚠️ 必须看**返回值**：`JsEngine.eval` 内部会捕获异常并返回空串
      //（无原生库时打日志 "Failed to load dynamic library
      //  'quickjs_c_bridge_plugin.dll'" 后返回 ''），try/catch 探测不到。
      jsOk = JsEngine.shared.eval('1 + 1') == '2';
      if (!jsOk) {
        // ignore: avoid_print
        print('[自测] quickjs 原生库不可用 ⇒ 组4 跳过；'
            '先执行一次 `flutter run -d windows` 把它构建出来即可。');
      }
    });

    // 服务器 isolate 随进程退出；无需显式关闭。

    test('java.put / java.get（52 + 28 次调用）', () {
      if (!jsOk) return;
      final r = AnalyzeRule();
      r.evalJs('java.put("k1", "v1")', null);
      expect(r.evalJs('java.get("k1")', null), 'v1');
    });

    test('java.base64Encode（纯 JS 实现，不依赖宿主）', () {
      if (!jsOk) return;
      expect(AnalyzeRule().evalJs('java.base64Encode("你好")', null), '5L2g5aW9');
    });

    test('java.getString 走宿主调用重放（头号方法：122 次 / 26 条源）', () {
      if (!jsOk) return;
      HostBridge.instance.clear();
      final r = AnalyzeRule()
        ..setContent(_html, 'http://example.com/root/');
      expect(r.evalJs('java.getString("class.author.1@text")', null), '作者二');
    });

    test('java.getString 带第二参（内容覆盖）', () {
      if (!jsOk) return;
      HostBridge.instance.clear();
      final r = AnalyzeRule()..setContent('<p>无关</p>', 'http://example.com/');
      final out = r.evalJs(
          'java.getString("class.author.0@text", ${_jsString(_html)})', null);
      expect(out, '作者一');
    });

    test('java.ajax 端到端：JS → 标记 → Dart 同步抓取 → 回填 JS', () {
      if (!jsOk) return;
      SyncHttpBridge.instance.clear();
      SyncHttpBridge.allowBlockingOnCurrentIsolate = true;
      final r = AnalyzeRule();
      final out = r.evalJs('java.ajax("http://127.0.0.1:$port/e2e")', null);
      expect(out, contains('fromAjax'),
          reason: '这一条是整个 java.ajax 链路的端到端证明');
      expect(out, contains('你好'), reason: '响应体必须原样回到 JS');
    });

    // [PATCH-12] 对称加密走句柄通道（实测 10 次调用）。
    // 这里只验「接线通不通」（返回数字句柄 / 非法输入不抛）；真正的
    // **已知答案向量**（固定 key+iv+密文 → 固定明文）建议后续用 openssl 造。
    test('java.createSymmetricCrypto 返回数字句柄（补丁 0012）', () {
      if (!jsOk) return;
      HostBridge.instance.clear();
      final out = AnalyzeRule().evalJs(
          'java.createSymmetricCrypto("AES/CBC/PKCS7Padding", "0123456789abcdef")',
          null);
      expect(out.isNotEmpty, isTrue, reason: '应返回句柄');
      expect(int.tryParse(out), isNotNull, reason: '句柄应是数字（__handle 已提取）');
      expect(int.parse(out), greaterThan(0));
    });

    test('java.cryptoOp 对未知句柄返回空串而不是抛异常（补丁 0012）', () {
      if (!jsOk) return;
      HostBridge.instance.clear();
      final out = AnalyzeRule()
          .evalJs('java.cryptoOp(999999, "Base64Decode", "AAAA")', null);
      expect(out, '', reason: '未知句柄应静默返回空串（与 Dart 侧既有行为一致）');
    });

    test('java.aesBase64DecodeToString 对非法输入返回空串（补丁 0012）', () {
      if (!jsOk) return;
      HostBridge.instance.clear();
      final out = AnalyzeRule().evalJs(
          'java.aesBase64DecodeToString("!!!not-base64!!!", "0123456789abcdef")',
          null);
      expect(out, '', reason: '非法输入不能抛异常，否则整段规则失败');
    });

    // ── AES 已知答案向量（用本机 Node v22 `crypto` 算出，反向自检通过）──
    //   明文 = '你好，Cmbok 测试'
    //   key  = 'cmbok-test-key!!'  （UTF-8 16B；含 '-' 不是合法 base64 ⇒ 走 UTF-8 分支）
    //   iv   = 'cmbok-test-iv!!!'  （UTF-8 16B）
    //   算法 = AES-128-CBC + PKCS7
    // 这三条验的是**加密正确性**（不只是接线）：如果 padding / IV / 密钥长度
    // 处理有偏差，解密结果就不会逐字节等于明文。
    test('AES/CBC/PKCS7 已知答案向量（显式 IV）', () {
      if (!jsOk) return;
      HostBridge.instance.clear();
      const cipher = 'wto8X3752KQcxA5ARiDpKzUl7I5irJNlPksl47cWmK4=';
      final out = AnalyzeRule().evalJs(
          'java.aesBase64DecodeToString("$cipher", "cmbok-test-key!!", '
          '"AES/CBC/PKCS7Padding", "cmbok-test-iv!!!")',
          null);
      expect(out, '你好，Cmbok 测试',
          reason: '与 Node crypto 算出的向量不一致 ⇒ padding/IV 处理有问题');
    });

    test('AES 已知答案向量（iv 传空串 ⇒ _padIv 补零 ⇒ 等价零 IV）', () {
      if (!jsOk) return;
      HostBridge.instance.clear();
      const cipherZeroIv = 'aG7PNoQ55FlnRP9at8Aq4yZmJalREQUhAwqxmzI2Rao=';
      final out = AnalyzeRule().evalJs(
          'java.aesBase64DecodeToString("$cipherZeroIv", "cmbok-test-key!!", '
          '"AES/CBC/PKCS7Padding", "")',
          null);
      expect(out, '你好，Cmbok 测试',
          reason: 'iv 为空时必须补零（_padIv），不能用未初始化缓冲区');
    });

    test('句柄路径 cryptoOp 使用传入的 IV（需补丁 0014）', () {
      if (!jsOk) return;
      HostBridge.instance.clear();
      const cipherExplicitIv = 'wto8X3752KQcxA5ARiDpKzUl7I5irJNlPksl47cWmK4=';
      // 补丁 0014 之前：`createSymmetricCrypto` 丢弃 iv、`cryptoOp` 恒传
      // iv=null ⇒ 句柄路径永远是零 IV，这条会**失败** —— 这正是它的意义：
      // 钉住「IV 必须生效」这个修复。
      final out = AnalyzeRule().evalJs(
          '(function(){var h=java.createSymmetricCrypto("AES/CBC/PKCS7Padding", '
          '"cmbok-test-key!!", "cmbok-test-iv!!!");'
          'return java.cryptoOp(h, "String", "$cipherExplicitIv");})()',
          null);
      expect(out, '你好，Cmbok 测试',
          reason: '句柄里存的 IV 必须生效（补丁 0014）');
    });

    test('java.ajax 结果可被 JSON.parse（真实用法）', () {
      if (!jsOk) return;
      SyncHttpBridge.instance.clear();
      SyncHttpBridge.allowBlockingOnCurrentIsolate = true;
      final r = AnalyzeRule();
      final out = r.evalJs(
          'JSON.parse(java.ajax("http://127.0.0.1:$port/json")).fromAjax', null);
      expect(out, '你好');
    });
  });

  // ── 组 6：Cookie 存储（补丁 0015；纯 Dart，不需要 JS 引擎）──
  group('组6 Cookie 存储', () {
    setUp(() => SourceCookieStore.instance.clear());

    test('setCookie / getCookie 按 host 分组隔离', () {
      SourceCookieStore.instance.setCookie('https://a.example/x', 'k1=v1; k2=v2');
      SourceCookieStore.instance.setCookie('https://b.example/y', 'k3=v3');
      expect(SourceCookieStore.instance.getCookie('https://a.example/z'),
          'k1=v1; k2=v2');
      expect(SourceCookieStore.instance.getCookie('https://b.example/y'), 'k3=v3');
      expect(SourceCookieStore.instance.getCookie('https://c.example/'), '',
          reason: '不同 host 不能串 cookie');
    });

    test('Set-Cookie 的属性片段被丢弃、同 name 覆盖', () {
      SourceCookieStore.instance.ingestResponseHeader(
          'https://a.example/', 'sid=1; Path=/; HttpOnly; Max-Age=3600');
      expect(SourceCookieStore.instance.getCookie('https://a.example/'), 'sid=1',
          reason: 'Path/HttpOnly/Max-Age 不是 cookie 名');
      SourceCookieStore.instance.setCookie('https://a.example/', 'sid=2');
      expect(SourceCookieStore.instance.getCookie('https://a.example/'), 'sid=2');
    });

    test('合并成一个 header 的多条 Set-Cookie 能拆开', () {
      SourceCookieStore.instance.ingestResponseHeader(
          'https://a.example/', 'a=1; Path=/, b=2; Path=/');
      final c = SourceCookieStore.instance.getCookie('https://a.example/');
      expect(c.contains('a=1'), isTrue, reason: c);
      expect(c.contains('b=2'), isTrue, reason: c);
    });

    test('getKey 返回 host（近似 legado cookie.getKey 语义）', () {
      expect(SourceCookieStore.instance.getKey('https://m.jjwxc.net/book/1'),
          'm.jjwxc.net');
    });

    test('removeCookie 支持删单个与清空该 host', () {
      SourceCookieStore.instance
          .setCookie('https://a.example/', 'x=1; y=2');
      SourceCookieStore.instance.removeCookie('https://a.example/', 'x');
      expect(SourceCookieStore.instance.getCookie('https://a.example/'), 'y=2');
      SourceCookieStore.instance.removeCookie('https://a.example/');
      expect(SourceCookieStore.instance.getCookie('https://a.example/'), '');
    });

    test('JS 全局 cookie 对象走宿主调用（需 JS 引擎）', () {
      // ⚠️ 不能用 try/catch 探测：`JsEngine.eval` **内部捕获异常并返回空串**
      //（实测无原生库时打日志 "Failed to load dynamic library
      //  'quickjs_c_bridge_plugin.dll'" 后返回 ''），所以必须看**返回值**。
      if (JsEngine.shared.eval('1 + 1') != '2') return;
      HostBridge.instance.clear();
      final r = AnalyzeRule();
      r.evalJs('cookie.setCookie("https://a.example/", "js=1")', null);
      expect(r.evalJs('cookie.getCookie("https://a.example/")', null), 'js=1',
          reason: 'JS 全局 cookie 必须与 Dart 侧存储打通（补丁 0015）');
    });
  });

  // ── 组 7：Dart 引擎接入层端到端（补丁 0008/0009/0013）────────────
  //
  // 这一组用**本机 HTTP 服务器 + 合成书源**跑通整条新链路：
  //   BookSourceDartEngine.handle(契约) → BookSourceRunner(worker isolate)
  //   → 闸门打开 → WebBook 原生 legado 引擎 → CSS 规则解析
  //   → JSON 回传 → 契约映射
  //
  // 合成源**只用纯 CSS 规则**（无 @js）⇒ 不需要 quickjs ⇒ 本组必定能跑。
  // 它验的是"我的适配代码对不对"（字段名、title→name、isUrl 绝对化、回落语义），
  // 而不是 legado 语义本身（那由组 3 覆盖）。
  group('组7 Dart 引擎接入层端到端', () {
    // 见文件头 _runE2E 说明：默认跳过（flutter test 无插件环境）
    if (!_runE2E) {
      test('组7 已跳过（需要 App 插件环境）', () {
        // ignore: avoid_print
        print('[自测] 组7 跳过：设置 BOOK_SOURCE_E2E=1 且在有插件的环境（如集成测试）下运行');
      });
      return;
    }
    late HttpServer server;
    late int port;

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      server.listen((req) async {
        final path = req.uri.path;
        String body;
        if (path.startsWith('/search')) {
          // 单行：排除标签间换行/文本节点对子规则的影响
          body = '<html><body>'
              '<div class="item"><a href="/book/1">书名一</a><span class="author">作者一</span><span class="kind">玄幻</span><span class="last">第一章 起始</span></div>'
              '<div class="item"><a href="/book/2">书名二</a><span class="author">作者二</span><span class="kind">都市</span><span class="last">第二章 转折</span></div>'
              '</body></html>';
        } else if (path.startsWith('/toc')) {
          body = '<html><body>'
              '<div class="chapter"><a href="/chapter/1">第1章 开始</a></div>'
              '<div class="chapter"><a href="/chapter/2">第2章 继续</a></div>'
              '</body></html>';
        } else if (path.startsWith('/chapter/')) {
          body = '<html><body><div id="content">正文第一段<br>正文第二段</div></body></html>';
        } else {
          body = '<html><body>nope</body></html>';
        }
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
          ..write(body);
        await req.response.close();
      });
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    setUp(() => BookSourceDartEngine.enabled = true);
    tearDown(() => BookSourceDartEngine.enabled = true);

    Map<String, dynamic> syntheticSource() => <String, dynamic>{
          'bookSourceName': '自测源',
          'bookSourceUrl': 'http://127.0.0.1:$port/',
          'bookSourceType': 0,
          'searchUrl': 'http://127.0.0.1:$port/search',
          'ruleSearch': <String, dynamic>{
            'bookList': 'class.item',
            'name': 'tag.a@text',
            'author': 'class.author@text',
            'bookUrl': 'tag.a@href',
            'kind': 'class.kind@text',
            'lastChapter': 'class.last@text',
          },
          'ruleToc': <String, dynamic>{
            'chapterList': 'class.chapter',
            'chapterName': 'tag.a@text',
            'chapterUrl': 'tag.a@href',
          },
          'ruleContent': <String, dynamic>{
            'content': 'id.content@html',
          },
        };

    test('bsSearch：走 worker isolate + 本机 HTTP + 契约字段映射', () async {
      final r = await BookSourceDartEngine.instance.handle(<String, dynamic>{
        'action': 'bsSearch',
        'source': syntheticSource(),
        'keyword': '书',
        'page': 1,
      });
      expect(r, isNotNull, reason: '纯 CSS 源必须被 Dart 引擎接管');
      expect(r!['ok'], true);
      final list = r['list'];
      expect(list, isA<List>(), reason: '契约字段是 list');
      final items = (list as List).cast<Map>();
      expect(items.length, 2, reason: '两个 class.item');
      expect(items[0]['name'], '书名一', reason: 'name 字段');
      expect(items[0]['kind'], '玄幻', reason: 'kind 字段');
      expect(items[0]['lastChapter'], '第一章 起始', reason: 'lastChapter 字段');
      // [PATCH-17] 修复前这里恒为''：`class.author@text` 会被 `_looksLikeCss`
      // 误判成 CSS ⇒ querySelectorAll('class.author') ⇒ 0 个元素。
      expect(items[0]['author'], '作者一', reason: 'author 字段（补丁 0017）');
      expect('${items[0]['bookUrl']}', contains('/book/1'),
          reason: 'bookUrl 应被解析为绝对地址');
      expect('${items[0]['bookUrl']}', startsWith('http://127.0.0.1:$port'),
          reason: '相对 URL 必须绝对化（分析层 isUrl）');
    });

    test('bsToc：章节契约是 name（引擎给的是 title）', () async {
      final r = await BookSourceDartEngine.instance.handle(<String, dynamic>{
        'action': 'bsToc',
        'source': syntheticSource(),
        'tocUrl': 'http://127.0.0.1:$port/toc',
      });
      expect(r, isNotNull, reason: '补丁 0017 后目录规则应能命中元素');
      expect(r!['ok'], true);
      final items = (r['list'] as List).cast<Map>();
      // [PATCH-17] 修复前 `class.chapter` 会被判成 CSS ⇒ 0 个元素 ⇒ 目录恒空
      expect(items.length, 2, reason: 'class.chapter 应命中 2 章（补丁 0017）');
      expect(items[0]['name'], '第1章 开始',
          reason: 'title→name 映射（契约要 name，引擎给 title）');
      expect('${items[0]['url']}', contains('/chapter/1'));
    });

    test('bsContent：返回 {ok, content} 文本契约', () async {
      final r = await BookSourceDartEngine.instance.handle(<String, dynamic>{
        'action': 'bsContent',
        'source': syntheticSource(),
        'chapterUrl': 'http://127.0.0.1:$port/chapter/1',
      });
      expect(r, isNotNull);
      expect(r!['ok'], true);
      expect('${r['content']}', contains('正文第一段'),
          reason: 'id.content@html 的正文');
    });

    test('未接管的动作返回 null（⇒ 调用方回落 Node）', () async {
      final r = await BookSourceDartEngine.instance.handle(<String, dynamic>{
        'action': 'bsLogin',
        'source': syntheticSource(),
      });
      expect(r, isNull, reason: 'bsLogin 未接管，必须回落 Node');
    });

    test('enabled=false 时一律返回 null（零风险开关）', () async {
      BookSourceDartEngine.enabled = false;
      final r = await BookSourceDartEngine.instance.handle(<String, dynamic>{
        'action': 'bsSearch',
        'source': syntheticSource(),
        'keyword': '书',
      });
      expect(r, isNull, reason: '关掉开关必须完全回到补丁前行为');
    });

    test('源解析失败返回 null 而不是抛异常（健壮性）', () async {
      final r = await BookSourceDartEngine.instance.handle(<String, dynamic>{
        'action': 'bsSearch',
        'source': <String, dynamic>{'bookSourceName': '坏源'},
        'keyword': '书',
      });
      // 要么解析成功但取不到数据返回 null，要么解析失败返回 null；都不许抛
      expect(r, anyOf(isNull, isA<Map>()),
          reason: '任何异常都必须被吞掉并回落 Node');
    });
  });

  // ── 组 5：诊断输出（只打印，用于把真机行为反馈回来）────────
  group('组5 诊断（不断言，只看输出）', () {
    test('打印若干规则的真实求值结果', () {
      final rule = AnalyzeRule()
        ..setContent(
            '{"data":{"list":[{"name":"甲"},{"name":"乙"}]}}', 'http://e.com/');
      // ignore: avoid_print
      print('[诊断] \$.data.list[0].name = "${rule.getString(r'$.data.list[0].name')}"');
      // ignore: avoid_print
      print('[诊断] \$.data.list[*].name = "${rule.getString(r'$.data.list[*].name')}"');

      final html = AnalyzeRule()..setContent(_html, 'http://example.com/');
      // ignore: avoid_print
      print('[诊断] @css:.list .author.1 = "${html.getString('@css:.author.1@text')}"');
      // ignore: avoid_print
      print('[诊断] tag.span.1@text = "${html.getString('tag.span.1@text')}"');
    });
  });
}

/// 在**独立 isolate** 里做一次同步抓取 —— 与生产一致：
/// 代理在主 isolate，同步请求在 worker isolate。
Future<String> _syncFetchInWorker(String url, int proxyPort,
    {bool cacheProbe = false}) async {
  final rp = ReceivePort();
  await Isolate.spawn(
      _syncFetchWorkerMain, <Object?>[rp.sendPort, url, proxyPort, cacheProbe]);
  final v = await rp.first;
  rp.close();
  return '$v';
}

/// worker 入口：开闸门 → 设置代理端口 → 同步抓取 → 回传缓存值。
///
/// `SyncHttpBridge.proxyPort` 是 **per-isolate 静态**（主 isolate 设的看不到），
/// 所以端口必须像生产一样**显式传进来**。
void _syncFetchWorkerMain(List<Object?> args) {
  final reply = args[0] as SendPort;
  final url = args[1] as String;
  final proxyPort = args[2] as int;
  final cacheProbe = args[3] as bool;
  SyncHttpBridge.allowBlockingOnCurrentIsolate = true;
  SyncHttpBridge.proxyPort = proxyPort;
  SyncHttpBridge.instance.clear();
  final need = SyncNeeds(
      key: 'GET $url', method: 'GET', url: url, headers: const {}, body: null);
  SyncHttpBridge.instance.fetch(need);
  if (cacheProbe) {
    SyncHttpBridge.instance.cache[need.key] = '已被改写';
    SyncHttpBridge.instance.fetch(need);
  }
  reply.send('${SyncHttpBridge.instance.cache[need.key]}');
}

/// 在**独立 isolate** 里起一个本机 HTTP 回显服务器，返回端口。
///
/// 为什么必须独立 isolate：`SyncHttpClient` 阻塞当前 isolate 的事件循环，
/// 同 isolate 的 HttpServer 无法响应（会死锁）。
Future<int> _startLoopbackServer() async {
  final rp = ReceivePort();
  await Isolate.spawn(_loopbackServerMain, rp.sendPort);
  final port = await rp.first;
  rp.close();
  return port as int;
}

/// 服务器 isolate 入口：绑定随机端口后把端口回传，然后持续回显。
void _loopbackServerMain(SendPort reply) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  reply.send(server.port);
  await for (final req in server) {
    final body = '{"path":"${req.uri.path}","text":"世界"}';
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType('application', 'json', charset: 'utf-8')
      ..write(body);
    await req.response.close();
  }
}

/// 把 HTML 转成 JS 字符串字面量（组 4 用）。
String _jsString(String s) {
  final buf = StringBuffer("'");
  for (final r in s.runes) {
    if (r == 0x27) {
      buf.write(r"\'");
    } else if (r == 0x5C) {
      buf.write(r'\\');
    } else if (r == 0x0A) {
      buf.write(r'\n');
    } else if (r == 0x0D) {
      buf.write(r'\r');
    } else {
      buf.writeCharCode(r);
    }
  }
  buf.write("'");
  return buf.toString();
}
