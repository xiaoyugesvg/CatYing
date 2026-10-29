// 书源引擎 QuickJS 方案验证：真 XPath + JSONPath 过滤器 + java.* 桥
import 'dart:convert';
import 'package:encrypt/encrypt.dart' as dkenc;
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/reading/novel_source/analyze/analyze_xpath.dart';
import 'package:tvbox/reading/novel_source/analyze/analyze_json.dart';
import 'package:tvbox/reading/novel_source/analyze/analyze_rule.dart';

void main() {
  group('真 XPath（xpath_selector）', () {
    const html = '<html><body>'
        '<div class="book-list">'
        '<div class="book"><h2 class="name">剑来</h2><a class="link" href="/book/jianlai.html">进入</a><span class="author">烽火戏诸侯</span></div>'
        '<div class="book"><h2 class="name">诡秘之主</h2><a class="link" href="/book/guimi.html">进入</a><span class="author">爱潜水的乌贼</span></div>'
        '</div></body></html>';

    test('谓词 [@class] + 相对路径取属性', () {
      final xp = AnalyzeByXPath(html);
      final urls = xp
          .getElements('//div[@class="book"]')
          .map((e) => AnalyzeByXPath.of(e).getString('.//a[@class="link"]/@href'))
          .toList();
      expect(urls, ['/book/jianlai.html', '/book/guimi.html']);
    });

    test('contains() 谓词', () {
      final xp = AnalyzeByXPath(html);
      final names = xp.getStringList('//div[contains(@class,"book")]//h2[@class="name"]');
      expect(names, ['剑来', '诡秘之主']);
    });

    test('位置谓词 [1]（第二个 book）', () {
      final xp = AnalyzeByXPath(html);
      final name = xp.getString('(//div[@class="book"])[2]//h2');
      expect(name, '诡秘之主');
    });

    test('CSS 节点（Element）继续 XPath 查询', () {
      final xp = AnalyzeByXPath(html);
      final els = xp.getElements('//div[@class="book"]');
      expect(els.length, 2);
      // 元素喂回 XPath 解析器
      final first = AnalyzeByXPath(els.first);
      expect(first.getString('.//span[@class="author"]'), '烽火戏诸侯');
    });
  });

  group('JSONPath 过滤器 [?(...)]', () {
    test('@.type 等值过滤', () {
      final jp = AnalyzeByJson({
        'data': {
          'items': [
            {'name': '剑来', 'type': 'book'},
            {'name': '动画', 'type': 'video'},
            {'name': '雪中', 'type': 'book'},
          ]
        }
      });
      final names = jp
          .getList(r'$.data.items[?(@.type=='"'"'book'"'"')]')
          .map((e) => (e as Map)['name'])
          .toList();
      expect(names, ['剑来', '雪中']);
    });

    test('比较运算 + && 组合', () {
      final jp = AnalyzeByJson({
        'list': [
          {'id': 1, 'hot': 100},
          {'id': 2, 'hot': 500},
          {'id': 3, 'hot': 300},
        ]
      });
      final ids = jp
          .getList(r'$.list[?(@.hot >= 300 && @.id > 1)]')
          .map((e) => (e as Map)['id'])
          .toList();
      expect(ids, [2, 3]);
    });

    test('存在性过滤', () {
      final jp = AnalyzeByJson({
        'rows': [
          {'title': 'a'},
          {'title': 'b', 'flag': true},
          {'title': 'c', 'flag': false},
        ]
      });
      final titles = jp
          .getList(r'$.rows[?(@.flag)]')
          .map((e) => (e as Map)['title'])
          .toList();
      expect(titles, ['b']);
    });
  });

  group('java.* 桥', () {
    test('md5Encode16', () {
      final rule = AnalyzeRule();
      expect(rule.md5Encode16('abc').length, 16);
      expect(rule.md5Encode('abc').length, 32);
    });

    test('AES-CBC base64 加解密回路（createSymmetricCrypto + cryptoOp）', () {
      final rule = AnalyzeRule();
      // ⚠️ key / iv 按 **legado 语义**传明文：
      //   `createSymmetricCrypto(transformation, key, iv, mode)` 里 key/iv
      //   走 `getBytes()`（见 _decodeKeyBytes：长度 16/24/32 视为明文），
      //   不是 base64。早先这里传 base64 串，16 字节 IV 编码后正好 24 个
      //   字符，被当成 24 字节明文再截断 → 两侧 IV 不一致 → 解出乱码。
      const key = '0123456789abcdef0123456789abcdef'; // 32 字节 → AES-256
      const ivStr = '0123456789abcdef'; // 16 字节
      const plain = '你好世界';
      final enc = _aesEncrypt(plain, key, ivStr);
      final handle =
          rule.createSymmetricCrypto('AES/CBC/PKCS7Padding', key, ivStr, 0);
      final dec = rule.cryptoOp(handle['__handle']!, 'Base64Decode', enc);
      expect(dec, plain);
    });

    test('base64/hex/randomUUID', () {
      final rule = AnalyzeRule();
      expect(rule.base64Decode('aGVsbG8='), 'hello');
      expect(rule.hexEncodeToString('AB'), '4142');
      expect(rule.hexDecodeToString('4142'), 'AB');
      expect(rule.randomUUID().length, 36);
    });

    test('jsoupParse + jsoupSelect', () {
      final rule = AnalyzeRule();
      final doc = rule.jsoupParse('<ul><li class="x">一</li><li class="x">二</li></ul>');
      expect(rule.jsoupSelect(doc['__handle']!, 'li.x'), ['一', '二']);
    });
  });
}

String _aesEncrypt(String plain, String keyUtf8, String ivUtf8) {
  // 用 encrypt 包做 AES-CBC 加密验证回路（与 legado 一致：key/iv 取 UTF-8 字节）
  final key = dkenc.Key.fromUtf8(keyUtf8);
  final iv = dkenc.IV.fromUtf8(ivUtf8);
  final enc = dkenc.Encrypter(dkenc.AES(key, mode: dkenc.AESMode.cbc));
  return base64.encode(enc.encrypt(plain, iv: iv).bytes);
}
