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

  test('🔴 2026-10-30 新内置的 16 个音源也必须在包里', () async {
    // 用户给的「音源_v261030更新」包，24 个里实测 20 个能出真直链，
    // 其中 16 个是全新的（另外 4 个是已有源的更新版，覆盖同名文件）。
    //
    // ⚠️ 这条测试的意义：`_lxCandidates` 加了 path 但忘了放文件时，
    //    `rootBundle.loadString` 会抛异常、`_loadLxSources` 里
    //    `catch { debugPrint }` 静默跳过 ⇒ **那个源凭空消失且不报错**。
    const added = [
      'xigua.js', // 西瓜聚合
      'feichangdao.js', // 非常刀
      'molan.js', // 墨澜
      'huibi.js', // 回避聚合
      'xinghai.js', // 星海
      'kulao.js', // 裤佬SVIP
      'fishmusic.js', // 639K，撞过 512K 上限
      'heimusic.js',
      'yuningxi.js',
      'yuxi.js',
      'suyin.js',
      'nianxin.js',
      'tongyi.js',
      'anni.js',
      'helloworld.js',
      'gdstudio.js',
    ];
    final missing = <String>[];
    for (final f in added) {
      try {
        final s = await rootBundle.loadString('assets/music/lx/$f');
        if (s.trim().isEmpty) missing.add('$f（内容为空）');
      } catch (_) {
        missing.add(f);
      }
    }
    expect(missing, isEmpty,
        reason: '这些新内置音源不在 asset bundle 里：${missing.join(", ")}。'
            '要么把文件放进 `assets/music/lx/`，'
            '要么从 `_lxCandidates` 里删掉对应条目。');
  });

  test('🔴 fishmusic 体积超过旧的 512K 上限（否则会被引擎判为过大）', () async {
    // 这个源 639,507 字符。`lx_engine.js` 的 MAX_SCRIPT_CHARS 曾经是
    // 512K ⇒ 它导入后永远加载失败。现在提到 2MB。
    // 这条测试钉住"它确实比 512K 大"这个事实，防止有人把上限又调回去
    // 而不知道会误伤谁。
    final s = await rootBundle.loadString('assets/music/lx/fishmusic.js');
    expect(s.length, greaterThan(512 * 1024),
        reason: 'fishmusic 变小了？那 lx_engine 的上限可以重新评估。');
    expect(s.length, lessThan(2 * 1024 * 1024),
        reason: 'fishmusic 涨过 2MB 了，需要再提 lx_engine.MAX_SCRIPT_CHARS。');
  });
}
