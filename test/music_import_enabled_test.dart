import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/music/services/source_import_parser.dart';

/// 回归测试：导入音源时 `enabled` 字段是**字符串/数字**不能崩。
///
/// ── 为什么要有这个测试 ──────────────────────────────────────────
/// 原来的写法是 `enabled: dict['enabled'] as bool? ?? true`（硬转换），
/// 而用户从别的 App 导出的 JSON 里 `"enabled": "false"` / `"enabled": 0`
/// 很常见 → 抛 `type 'String' is not a subtype of type 'bool?'`：
///   · **整个导入失败**
///   · UI 只能显示这句英文类型错误，用户完全不知道是哪个字段的问题
///
/// ⚠️ 讽刺的是 `third_party_source.dart` 里**同一个写法**
///    早就改成了宽容解析 `_asBool`（注释还专门写了这段教训：
///    "一条脏数据就把整个音源列表废掉"），
///    而 `source_import_parser.dart` 是**另一份拷贝**，当时漏改了。
///
/// 这个测试同时锁住两件事：
///   ① 脏 `enabled` **不抛异常**（整个导入不失败）
///   ② 语义正确（`"false"`/`0` → false，`"true"`/1 → true，看不懂 → true）
void main() {
  /// 一份最小可用的洛雪（LX）音源 JSON。
  ///
  /// [enabled] 传 `null` = **不带这个字段**（测默认值）；
  /// 传字符串会被加引号（`"false"`），传数字/bool 直接写。
  String lxJson(Object? enabled) {
    final enabledField = enabled == null
        ? ''
        : ',\n  "enabled": ${enabled is String ? '"$enabled"' : enabled}';
    return '''
{
  "name": "测试音源",
  "description": "单元测试用",
  "version": "1.0.0",
  "script": "const m = { musicUrl: async () => '' };"
  $enabledField
}
''';
  }

  /// 便于失败时看清是哪一种输入
  List<dynamic> parseOf(Object? enabled) =>
      SourceImportParser.parse(lxJson(enabled));

  group('导入音源：enabled 字段宽容解析', () {
    test('字符串 "false" / "true"：不崩，且语义正确', () {
      final f = parseOf('false');
      expect(f, isNotEmpty,
          reason: '"enabled":"false" 应该能正常导入（宽容解析），'
              '而不是抛 CastError 让整个导入失败');
      expect(f.first.enabled, isFalse, reason: '字符串 "false" → false');

      final t = parseOf('true');
      expect(t, isNotEmpty);
      expect(t.first.enabled, isTrue, reason: '字符串 "true" → true');
    });

    test('数字 0 / 1：不崩，且语义正确', () {
      final f = parseOf(0);
      expect(f, isNotEmpty, reason: '数字 0 应该能正常导入');
      expect(f.first.enabled, isFalse, reason: '0 → false');

      final t = parseOf(1);
      expect(t, isNotEmpty);
      expect(t.first.enabled, isTrue, reason: '1 → true');
    });

    test('真正的 bool 照常工作', () {
      final f = parseOf(false);
      expect(f, isNotEmpty);
      expect(f.first.enabled, isFalse);
    });

    test('缺失 enabled 字段 → 默认 true（不崩）', () {
      final r = parseOf(null);
      expect(r, isNotEmpty, reason: '没有 enabled 字段应该能导入');
      expect(r.first.enabled, isTrue, reason: '没写 enabled 就是默认启用');
    });

    test('看不懂的值 → 退回默认 true，不抛异常', () {
      final r = parseOf('maybe');
      expect(r, isNotEmpty, reason: '无法识别的 enabled 不该让导入失败');
      expect(r.first.enabled, isTrue);
    });
  });
}
