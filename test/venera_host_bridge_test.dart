import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/reading/source/venera/venera_host_bridge.dart';

/// Venera 兼容层的宿主桥（纯 Dart 部分）回归测试。
///
/// JS 侧协议见 `lib/reading/source/venera/venera_js_prelude.dart`：
/// 二进制参数统一用 `{__bytes: base64}` 传递，返回值可以是 Uint8List。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late VeneraHostBridge bridge;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    bridge = VeneraHostBridge(sourceKey: 'unit', prefs: prefs);
  });

  Map<String, dynamic> bytes(String raw) =>
      {'__bytes': base64Encode(utf8.encode(raw))};

  test('md5 / sha256 走 base64 二进制通道且结果正确', () {
    final md5 = bridge.handle({
      'method': 'convert',
      'type': 'md5',
      'value': bytes('abc'),
      'isEncode': true,
    }) as Uint8List;
    expect(md5, crypto.md5.convert(utf8.encode('abc')).bytes);

    final sha = bridge.handle({
      'method': 'convert',
      'type': 'sha256',
      'value': bytes('abc'),
      'isEncode': true,
    }) as Uint8List;
    expect(sha, crypto.sha256.convert(utf8.encode('abc')).bytes);
  });

  test('hmacString 返回十六进制串', () {
    final out = bridge.handle({
      'method': 'convert',
      'type': 'hmac',
      'hash': 'sha256',
      'key': bytes('secret'),
      'value': bytes('123'),
      'isEncode': true,
      'isString': true,
    });
    final expected =
        crypto.Hmac(crypto.sha256, utf8.encode('secret')).convert(utf8.encode('123')).toString();
    expect(out, expected);
  });

  test('base64 / gbk / gzip 往返', () {
    final raw = base64Encode(utf8.encode('你好'));
    final decoded = bridge.handle({
      'method': 'convert',
      'type': 'base64',
      'value': raw,
      'isEncode': false,
    }) as Uint8List;
    expect(utf8.decode(decoded), '你好');

    final gbk = bridge.handle({
      'method': 'convert',
      'type': 'gbk',
      'value': '中文',
      'isEncode': true,
    }) as Uint8List;
    final back = bridge.handle({
      'method': 'convert',
      'type': 'gbk',
      'value': {'__bytes': base64Encode(gbk)},
      'isEncode': false,
    });
    expect(back, '中文');

    final gz = bridge.handle({
      'method': 'convert',
      'type': 'gzip',
      'value': bytes('hello gzip'),
      'isEncode': true,
    }) as Uint8List;
    final ungz = bridge.handle({
      'method': 'convert',
      'type': 'gzip',
      'value': {'__bytes': base64Encode(gz)},
      'isEncode': false,
    }) as Uint8List;
    expect(utf8.decode(ungz), 'hello gzip');
  });

  test('AES-CBC 加解密往返', () {
    final key = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
    final iv = Uint8List.fromList(List<int>.generate(16, (i) => i + 11));
    final cipher = bridge.handle({
      'method': 'convert',
      'type': 'aes-cbc',
      'value': bytes('venera comic payload'),
      'key': {'__bytes': base64Encode(key)},
      'iv': {'__bytes': base64Encode(iv)},
      'isEncode': true,
    }) as Uint8List;
    expect(cipher, isNotEmpty);
    final plain = bridge.handle({
      'method': 'convert',
      'type': 'aes-cbc',
      'value': {'__bytes': base64Encode(cipher)},
      'key': {'__bytes': base64Encode(key)},
      'iv': {'__bytes': base64Encode(iv)},
      'isEncode': false,
    }) as Uint8List;
    expect(utf8.decode(plain), 'venera comic payload');
  });

  test('HtmlDocument 句柄：选择器 / 文本 / 属性 / 子元素', () {
    final docId = bridge.handle({
      'method': 'html',
      'function': 'parse',
      'data': '<div class="list"><a class="item" href="/c/1">漫画A</a>'
          '<a class="item" href="/c/2">漫画B</a></div>',
    }) as int;

    final items = bridge.handle({
      'method': 'html',
      'function': 'querySelectorAll',
      'key': docId,
      'query': 'a.item',
    }) as List;
    expect(items.length, 2);

    final first = items.first as int;
    expect(bridge.handle({
      'method': 'html',
      'function': 'getText',
      'key': first,
    }), '漫画A');
    final attrs = bridge.handle({
      'method': 'html',
      'function': 'getAttributes',
      'key': first,
    }) as Map;
    expect(attrs['href'], '/c/1');
    expect(attrs['class'], 'item');

    final parent = bridge.handle({
      'method': 'html',
      'function': 'getParent',
      'key': first,
    }) as int;
    expect(bridge.handle({
      'method': 'html',
      'function': 'getLocalName',
      'key': parent,
    }), 'div');
  });

  test('load_data / save_data 持久化', () {
    bridge.handle({
      'method': 'save_data',
      'key': 'unit',
      'data_key': 'token',
      'data': {'v': 42},
    });
    final loaded = bridge.handle({
      'method': 'load_data',
      'key': 'unit',
      'data_key': 'token',
    });
    expect(loaded, {'v': 42});
  });

  test('Cookie 按 host 存取', () {
    bridge.handle({
      'method': 'cookie',
      'function': 'set',
      'url': 'https://example.com/path',
      'cookies': [
        {'name': 'sid', 'value': 'abc', 'domain': 'example.com'},
      ],
    });
    final list = bridge.handle({
      'method': 'cookie',
      'function': 'get',
      'url': 'https://example.com/other',
    }) as List;
    expect(list.length, 1);
    expect((list.first as Map)['value'], 'abc');
  });
}
