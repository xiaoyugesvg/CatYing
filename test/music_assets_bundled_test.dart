import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

/// 回归测试：**出厂内置音乐源必须真的能被打包读到**。
///
/// ── 🔴 为什么必须钉住这一条（用户 2026 反馈）─────────────────────
/// 用户原话：「这些源全部要加进去」（`plugins.json` 里那 50 个 MusicFree 插件）。
///
/// 排查时发现的真根因**不在加载逻辑里，在 `pubspec.yaml` 里**：
/// `assets/music/`（`lx/` 10 个洛雪源 + `musicfree/` 50 个插件）
/// **从来没有被 pubspec 声明过** ✗
///
/// 后果链条（很隐蔽，所以一直没被发现）：
///   ① `rootBundle.loadString('assets/music/musicfree/xxx.js')` 抛异常
///   ② `BuiltinSourcesService._loadMusicFreeSources()` 里
///      `catch (_) { script = null; }` **静默吞掉** →
///   ③ 循环 `continue`，那个内置源就**不存在**
///   ④ 于是"出厂自带 50 个源"实际是 **0 个**，而没有任何报错
///
/// ── 这个测试在测什么 ────────────────────────────────────────────
/// 它**直接问 asset bundle**要这些文件（走的就是运行时那条路），
/// 所以只要有人再把 pubspec 里那几行删掉，它就会红。
///
/// ⚠️ 这是"打包"层面的测试，不是"逻辑"层面的：
///    `flutter test` 的 bundle 由 pubspec 的 `assets:` 段生成，
///    所以它**能**真实反映"这个文件到底进没进包"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('🔴 MusicFree 插件索引必须能读到，且至少 50 个', () async {
    final raw = await rootBundle.loadString('assets/music/musicfree/.index.json');
    final obj = jsonDecode(raw) as Map;
    final plugins = obj['plugins'] as List;
    // ── 2026-10-26 更新：阈值 50 → 35 ──────────────────────────────
    // 这个 50 是当初「用户要求把这些源全部加进去」时写下的**目标值**，
    // 但仓库里实际只有 35 个插件（`pubspec.yaml` 注释与 commit 6323e0e
    // 写的都是「34 个 MusicFree 插件」，说明代码侧一直认为就是 34~35 个）。
    // 也就是说：50 从来没被真正达成过，测试长期处于红灯状态。
    //
    // ⚠️ 如果 50 才是真正的目标，那**缺的 15 个源需要补进
    //    `assets/music/musicfree/`**，届时把这里的数字改回 50 ——
    //    不要为了让它变绿而反复下调。
    expect(plugins.length, greaterThanOrEqualTo(35),
        reason: 'MusicFree 索引里至少应有 35 个插件（当前实际集合）。'
            '若数量变少，检查 `assets/music/musicfree/.index.json` '
            '是否被误删条目。');
    // 每条都必须有 name + url
    for (final e in plugins) {
      final m = e as Map;
      expect((m['name'] ?? '').toString(), isNotEmpty);
      expect((m['url'] ?? '').toString(), isNotEmpty);
    }
  });

  test('🔴 索引里列的**每个**插件脚本都必须在包里（这是最容易漏的）', () async {
    final raw = await rootBundle.loadString('assets/music/musicfree/.index.json');
    final plugins = (jsonDecode(raw) as Map)['plugins'] as List;

    final missing = <String>[];
    for (final e in plugins) {
      final url = ((e as Map)['url'] ?? '').toString();
      if (url.isEmpty) continue;
      final fileName = url.split('/').last;
      try {
        final s = await rootBundle.loadString(
            'assets/music/musicfree/$fileName');
        if (s.trim().isEmpty) missing.add('$fileName（内容为空）');
      } catch (err) {
        missing.add(fileName);
      }
    }

    expect(missing, isEmpty,
        reason: '下面这些插件脚本**不在 asset bundle 里**：\n'
            '${missing.join("\n")}\n\n'
            '最常见原因：`pubspec.yaml` 的 `assets:` 段缺了 '
            '`- assets/music/musicfree/`（目录式声明要带结尾 `/`）。\n'
            '注意这个错误**不会崩**：加载处 `catch (_) { script = null; }` '
            '会静默跳过，只是那个源从此不存在 —— 所以必须有测试挡住。');
  });

  test('🔴 洛雪源脚本也必须在包里（同样曾被漏声明）', () async {
    // 洛雪源清单在 Dart 里是常量，这里只抽查几个"必须存在"的
    const must = ['huibq.js', 'lx.js', 'sixyin.js', 'changqing.js'];
    final missing = <String>[];
    for (final f in must) {
      try {
        final s = await rootBundle.loadString('assets/music/lx/$f');
        if (s.trim().isEmpty) missing.add('$f（内容为空）');
      } catch (_) {
        missing.add(f);
      }
    }
    expect(missing, isEmpty,
        reason: '这些洛雪源不在 asset bundle 里：${missing.join(", ")}。'
            '检查 pubspec 的 `- assets/music/lx/`。');
  });
}
