// REXENC 加密容器识别 + 主密钥归一化（2026-10-31）
//
// 用户拿来的 15 个模块里有 10 个不是明文 JS，而是 `REXENC` 容器：
//
//   REXENC
//   {"v":2,"mkv":"rex-1","alg":"A256GCM","iv":"…","kb":"…"}
//   <base64 密文>
//
// Dart 侧不解密（那是 Node 的活，见 rex_engine.js），但**必须能认出来**：
// 认不出来就会走到 Node 编译那一步，用户看到的是
// 「模块代码无法解析：Unexpected token」——完全看不出该去填密钥。

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/rex/rex_keys.dart';

/// 从真实模块（dy.js）里抄的头部，字段与长度都保持原样
const _realHeader =
    '{"v":2,"mkv":"rex-1","alg":"A256GCM","iv":"Z+hyhxrR6KHEe6y4",'
    '"kb":"x0Z4rb5oPnOBo2yKYdyCnQ/ig9bplAW+PpnXYymLey87lmd+msXuyngO5Ks0NF9pZotl8ZSHp5I9d47A"}';

String _enc([String header = _realHeader, String body = 'AAAA']) =>
    'REXENC\n$header\n$body';

void main() {
  group('RexEnvelope.isEncrypted', () {
    test('普通 JS 模块不算加密', () {
      expect(RexEnvelope.isEncrypted('WidgetMetadata = {id:"a"}'), isFalse);
      expect(RexEnvelope.isEncrypted('// REXENC 只是注释'), isFalse);
    });

    test('REXENC 容器算加密', () {
      expect(RexEnvelope.isEncrypted(_enc()), isTrue);
    });

    test('官方 FWENC2 也算（同一套布局，只有 mkv 不同）', () {
      // 2026-10-31 用官方公开加密 API（widgetencrypt.inchmade.ai）
      // 加密一段最小模块拿到的真实头部
      const fw = 'FWENC2\n{"v":2,"mkv":"1","alg":"A256GCM",'
          '"iv":"UfL0fxejv9pVeNNL",'
          '"kb":"nXOBBtmqAxh9prf4OuFtw2fHjeWY+4KpunzHQ/0d5yy0u1Go8caetSQuwY8PBRzXgQhUdIihHmJv54oo"}\n'
          'X+lxcSRG7YuJNlfa90epxvRsZLe6Giuj2AULsT5Hh451drboThYuKhyNwM0teg5rq8IgZ8KEEJmURZnXaVGAX9QBXW7tFELouPMbsbzCdRX2ev+r1B2Ii+dmLMeIUxEiL2aW/bG+ict38+O93yQ';
      expect(RexEnvelope.isEncrypted(fw), isTrue);
      final e = RexEnvelope.tryParse(fw);
      expect(e, isNotNull);
      expect(e!.magic, 'FWENC2');
      expect(e.masterKeyId, '1');
      expect(e.supported, isTrue);
    });

    test('带 UTF-8 BOM 也认（编辑器另存常见）', () {
      expect(RexEnvelope.isEncrypted('\uFEFF${_enc()}'), isTrue);
    });
  });

  group('RexEnvelope.tryParse', () {
    test('真实头部：版本 / 算法 / 主密钥标识都对', () {
      final e = RexEnvelope.tryParse(_enc());
      expect(e, isNotNull);
      expect(e!.magic, 'REXENC');
      expect(e.version, 2);
      expect(e.algorithm, 'A256GCM');
      expect(e.masterKeyId, 'rex-1');
      expect(e.supported, isTrue);
      expect(e.label, contains('rex-1'));
    });

    test('带 BOM 也能解析', () {
      final e = RexEnvelope.tryParse('\uFEFF${_enc()}');
      expect(e?.version, 2);
    });

    test('没有第二行 ⇒ null（不是「假装成功」）', () {
      expect(RexEnvelope.tryParse('REXENC'), isNull);
      expect(RexEnvelope.tryParse('REXENC\n{"v":2}'), isNull);
    });

    test('头部不是 JSON ⇒ null', () {
      expect(RexEnvelope.tryParse('REXENC\nnot-json\nAAAA'), isNull);
    });

    test('头部是 JSON 但不是对象 ⇒ null', () {
      expect(RexEnvelope.tryParse('REXENC\n[1,2]\nAAAA'), isNull);
    });

    test('不认识的版本 ⇒ supported = false', () {
      final e = RexEnvelope.tryParse(_enc('{"v":3,"mkv":"rex-2","alg":"A256GCM"}'));
      expect(e, isNotNull);
      expect(e!.supported, isFalse);
      expect(e.version, 3);
    });

    test('不认识的算法 ⇒ supported = false', () {
      final e = RexEnvelope.tryParse(_enc('{"v":2,"mkv":"rex-1","alg":"CHACHA"}'));
      expect(e!.supported, isFalse);
    });

    test('算法大小写不敏感', () {
      final e = RexEnvelope.tryParse(_enc('{"v":2,"mkv":"rex-1","alg":"a256gcm"}'));
      expect(e!.supported, isTrue);
    });

    test('明文模块 ⇒ null', () {
      expect(RexEnvelope.tryParse('var a = 1;\nvar b = 2;'), isNull);
    });
  });

  group('RexKeys.normalize', () {
    final hex = List.generate(32, (i) => i.toRadixString(16).padLeft(2, '0')).join();
    // 上面是 00 01 02 … 1f 的 hex，正好 64 位

    test('64 位 hex 原样（转小写）', () {
      expect(RexKeys.normalize(hex.toUpperCase()), hex);
    });

    test('带空格 / 换行 / 引号 / 0x 前缀都能洗掉', () {
      final messy = '  0x${hex.toUpperCase()}\n';
      expect(RexKeys.normalize(messy), hex);
      expect(RexKeys.normalize('"$hex"'), hex);
      expect(RexKeys.normalize('$hex'.split('').join(' ')), hex);
    });

    test('44 位 base64（含 =）原样保留', () {
      const b64 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
      expect(RexKeys.normalize(b64), b64);
    });

    test('43 位 base64 自动补 =', () {
      const b64 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
      expect(RexKeys.normalize(b64), '$b64=');
    });

    test('32 字节原文按原文收', () {
      const raw = 'abcdefghijklmnopqrstuvwxyz012345';
      expect(RexKeys.normalize(raw), raw);
    });

    test('空串 = 清除，返回空串而不是 null', () {
      expect(RexKeys.normalize('   '), '');
    });

    test('认不出来的写法返回 null（界面据此拦一下）', () {
      expect(RexKeys.normalize('hello'), isNull);
      expect(RexKeys.normalize('123'), isNull);
      // 63 位 hex（少一位）不能当密钥
      expect(RexKeys.normalize(hex.substring(1)), isNull);
    });
  });

  group('RexKeys.mask', () {
    test('只露头尾，长度不变', () {
      final m = RexKeys.mask('0123456789abcdef0123456789abcdef');
      expect(m.startsWith('0123'), isTrue);
      expect(m.endsWith('cdef'), isTrue);
      expect(m.contains('0123456789abcdef01234567'), isFalse);
      expect(m.length, 16);
    });

    test('短串整体打码', () {
      expect(RexKeys.mask('abc'), '•••');
    });

    test('空串不报错', () {
      expect(RexKeys.mask(''), '');
    });
  });

  group('RexKeys 存取', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      // 缓存是静态的，用例之间要复位
      RexKeys.save('');
    });

    test('没填过 = 空串', () async {
      expect(await RexKeys.master(), '');
    });

    test('保存后再读，拿到归一化后的值', () async {
      await RexKeys.save('  0x0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF ');
      final v = await RexKeys.master();
      expect(v, '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef');
    });

    test('存空串 = 清除', () async {
      await RexKeys.save('a' * 64);
      expect(await RexKeys.master(), isNotEmpty);
      await RexKeys.save('');
      expect(await RexKeys.master(), '');
    });

    test('认不出来的写法不拦死（原样存，可能是新版格式）', () async {
      await RexKeys.save('some-new-format-key');
      expect(await RexKeys.master(), 'some-new-format-key');
    });
  });
}
