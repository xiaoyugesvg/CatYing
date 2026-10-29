import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/services/translate_service.dart';

/// 翻译服务的真实链路验证（本地起 HTTP mock，不走外网、不需要真 Key）。
///
/// 覆盖：
///   · OpenAI 兼容接口：请求体（model / messages）、```json 围栏解析、行数对齐
///   · 百度翻译：form 参数（q / appid / salt / sign）、trans_result 解析
///   · 行级缓存：同一批文本第二次不再发请求
///   · 错误码：能抛出可读异常
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late String base;
  var openAiCalls = 0;
  var baiduCalls = 0;
  var lastOpenAiBody = '';
  var lastBaiduBody = '';
  var openAiReplyCount = 2;
  var baiduError = false;

  setUp(() async {
    // flutter_test 默认会把所有 HttpClient 请求替换成"返回 400"的 mock，
    // 这里要连本机 mock server，必须关掉它。
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    TranslateService.instance.clearCache();
    openAiCalls = 0;
    baiduCalls = 0;
    lastOpenAiBody = '';
    lastBaiduBody = '';
    openAiReplyCount = 2;
    baiduError = false;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    TranslateService.baiduEndpoint = '$base/api/trans/vip/translate';

    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      if (req.uri.path == '/v1/chat/completions') {
        openAiCalls++;
        lastOpenAiBody = body;
        final arr = List<String>.generate(openAiReplyCount, (i) => i == 0 ? '你好' : '世界$i');
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': '```json\n${jsonEncode(arr)}\n```'},
            }
          ],
        }));
      } else if (req.uri.path == '/api/trans/vip/translate') {
        baiduCalls++;
        lastBaiduBody = body;
        req.response.headers.contentType = ContentType.json;
        if (baiduError) {
          req.response.write(jsonEncode(
              {'error_code': '54003', 'error_msg': 'Invalid Access Limit'}));
        } else {
          req.response.write(jsonEncode({
            'from': 'ja',
            'to': 'zh',
            'trans_result': [
              {'src': 'こんにちは', 'dst': '你好'},
              {'src': '世界', 'dst': '世界'},
            ],
          }));
        }
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  });

  tearDown(() async {
    TranslateService.baiduEndpoint =
        'https://fanyi-api.baidu.com/api/trans/vip/translate';
    await server.close(force: true);
  });

  test('OpenAI 兼容：请求体正确、能解析 ```json 围栏、保持行数', () async {
    await TranslateSettings.save(
      engine: 'openai',
      openAiBase: '$base/v1',
      openAiKey: 'test-key',
      openAiModel: 'test-model',
      from: 'ja',
      to: 'zh',
    );

    final out = await TranslateService.instance
        .translateLines(const ['こんにちは', '世界']);

    expect(out, ['你好', '世界1']);
    expect(openAiCalls, 1);

    final m = jsonDecode(lastOpenAiBody) as Map<String, dynamic>;
    expect(m['model'], 'test-model');
    final msgs = m['messages'] as List;
    expect(msgs.length, 2);
    expect((msgs[1] as Map)['content'], jsonEncode(['こんにちは', '世界']));
  });

  test('OpenAI：模型多返回一条时按原行数截断，不越界', () async {
    openAiReplyCount = 3;
    await TranslateSettings.save(
      engine: 'openai',
      openAiBase: '$base/v1',
      openAiKey: 'k',
      openAiModel: 'm',
      from: 'ja',
      to: 'zh',
    );
    final out = await TranslateService.instance
        .translateLines(const ['a', 'b']);
    expect(out.length, 2);
  });

  test('缓存：同一批文本第二次不再请求', () async {
    await TranslateSettings.save(
      engine: 'openai',
      openAiBase: '$base/v1',
      openAiKey: 'k',
      openAiModel: 'm',
      from: 'ja',
      to: 'zh',
    );
    await TranslateService.instance.translateLines(const ['こんにちは', '世界']);
    await TranslateService.instance.translateLines(const ['こんにちは', '世界']);
    expect(openAiCalls, 1);
  });

  test('百度：参数齐全（q/appid/salt/sign）且能解析 trans_result', () async {
    await TranslateSettings.save(
      engine: 'baidu',
      baiduAppId: 'appid-1',
      baiduSecret: 'secret-1',
      from: 'ja',
      to: 'zh',
    );

    final out = await TranslateService.instance
        .translateLines(const ['こんにちは', '世界']);

    expect(out, ['你好', '世界']);
    expect(baiduCalls, 1);

    final params = Uri.splitQueryString(lastBaiduBody);
    expect(params['appid'], 'appid-1');
    expect(params['q'], 'こんにちは\n世界');
    expect(params['from'], 'ja');
    expect(params['to'], 'zh');
    expect((params['sign'] ?? '').length, 32); // md5 hex
  });

  test('百度：错误码能抛出可读异常', () async {
    baiduError = true;
    await TranslateSettings.save(
      engine: 'baidu',
      baiduAppId: 'appid-1',
      baiduSecret: 'secret-1',
      from: 'ja',
      to: 'zh',
    );

    expect(
      () => TranslateService.instance.translateLines(const ['こんにちは']),
      throwsA(predicate((e) => e.toString().contains('54003'))),
    );
  });

  group('语种判定（needsTranslation）', () {
    test('中文 / 纯符号 → 不翻', () {
      expect(TranslateService.needsTranslation('今天想听点什么？'), isFalse);
      expect(TranslateService.needsTranslation('   123 .,!?  '), isFalse);
      expect(TranslateService.needsTranslation(''), isFalse);
    });

    test('英文 → 翻', () {
      expect(TranslateService.needsTranslation('Hello world'), isTrue);
      expect(TranslateService.needsTranslation('Oppenheimer 4K'), isTrue);
    });

    test('假名（日语）→ 翻（原来被当成中文跳过）', () {
      expect(TranslateService.needsTranslation('こんにちは、世界。'), isTrue);
      expect(TranslateService.needsTranslation('東京大学に行く'), isTrue);
      expect(TranslateService.needsTranslation('カタカナ'), isTrue);
    });

    test('谚文（韩语）→ 翻', () {
      expect(TranslateService.needsTranslation('안녕하세요'), isTrue);
    });

    test('繁中 / 汉字为主 → 不翻', () {
      expect(TranslateService.needsTranslation('這是一部紀錄片'), isFalse);
    });
  });
}
