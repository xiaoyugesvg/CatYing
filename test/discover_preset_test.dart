import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/theme/discover_preset.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';

/// 发现页**视觉预设与全局主题的统一性**契约测试。
///
/// ── 这个测试存在的唯一理由（用户明确要求"主题要统一"）────────────
/// 三套预设（aurora / paper / midnight）是从 Beans 抄来的。
/// Beans 原版让每套预设**自带一套配色与平台品牌色**；
/// 如果照抄那一点，会出现：
///   · 换全局主题时**只有发现页不变色** → 界面上两套色系打架
///   · 全局浅色时某套预设仍是深色 → 违反"全局说了算"
///
/// 所以本项目约定：**预设只改"怎么画"（背景/材质），不改配色**。
/// 所有颜色从 `MusicTheme`（即 `JellyPalette`）派生。
///
/// 下面这些断言就是**守住这个约定**的护栏。
void main() {
  // ⚠️ **必须注册 palette bridge**，否则 `MusicTheme.palette` 会命中
  // `MusicPaletteBridge` 的"未注册"断言直接抛（#13 的保护）——
  // 那个断言是**故意的**（防止启动顺序被改坏后主题静默退回水墨书香）。
  // 测试里没有 main.dart 的启动流程，所以手动注册成默认水墨书香。
  setUpAll(() {
    MusicPaletteBridge.register(() => const JellyPalette.ink());
  });

  group('预设枚举', () {
    test('三套都在（aurora / paper / midnight）', () {
      expect(DiscoverPreset.values.length, 3);
      expect(DiscoverPreset.values.map((e) => e.name).toList(),
          ['aurora', 'paper', 'midnight']);
    });

    test('每套都有中文标签（设置页要显示）', () {
      for (final p in DiscoverPreset.values) {
        expect(p.label.trim(), isNotEmpty, reason: '${p.name} 缺 label');
      }
      print('  labels: ${DiscoverPreset.values.map((e) => e.label).join(" / ")}');
    });

    test('fromName 容错：未知/空 → aurora（默认）', () {
      expect(DiscoverPreset.fromName('paper'), DiscoverPreset.paper);
      expect(DiscoverPreset.fromName('midnight'), DiscoverPreset.midnight);
      expect(DiscoverPreset.fromName('不存在'), DiscoverPreset.aurora);
      expect(DiscoverPreset.fromName(null), DiscoverPreset.aurora);
      expect(DiscoverPreset.fromName(''), DiscoverPreset.aurora);
    });
  });

  group('🔴 主题统一：预设必须只改材质，不改配色', () {
    test('三套预设的强调色**完全相同**（都来自全局主题）', () {
      // 这是最关键的一条：如果某套预设自带强调色，这里就会不等。
      final accents =
          DiscoverPreset.values.map((p) => DiscoverStyle.of(p).accent).toSet();
      expect(accents.length, 1,
          reason: '预设不得自带强调色 —— 否则换全局主题时发现页不会跟着变，'
              '界面上会出现两套色系。实测值：$accents');
      print('  全局强调色（三套一致）: ${accents.first}');
    });

    test('三套预设的主文字色 / 辅助色也一致', () {
      final primaries =
          DiscoverPreset.values.map((p) => DiscoverStyle.of(p).primary).toSet();
      final blues =
          DiscoverPreset.values.map((p) => DiscoverStyle.of(p).blue).toSet();
      expect(primaries.length, 1, reason: '主文字色必须来自全局主题');
      expect(blues.length, 1, reason: '辅助色必须来自全局主题');
    });

    test('卡片填充色也一致（材质靠 alpha 区分，不是换颜色）', () {
      final fills =
          DiscoverPreset.values.map((p) => DiscoverStyle.of(p).cardFill).toSet();
      expect(fills.length, 1, reason: '卡片底色应来自全局 palette.card*');
    });

    test('预设之间**确实有差异** —— 差异在材质开关与透明度上', () {
      final aurora = DiscoverStyle.of(DiscoverPreset.aurora);
      final paper = DiscoverStyle.of(DiscoverPreset.paper);
      final midnight = DiscoverStyle.of(DiscoverPreset.midnight);

      // aurora / midnight 有光斑+粒子，paper 没有（最省电）
      expect(aurora.blobs, isTrue);
      expect(aurora.particles, isTrue);
      expect(midnight.blobs, isTrue);
      expect(paper.blobs, isFalse, reason: 'paper 应是最省的纯色底');
      expect(paper.particles, isFalse);
      expect(paper.fillAlpha, 1.0,
          reason: 'paper 用实心卡片；玻璃系才靠半透明');

      // 三套的 fillAlpha 不应全同（否则"材质差异"名存实亡）
      final alphas = {aurora.fillAlpha, paper.fillAlpha, midnight.fillAlpha};
      expect(alphas.length, greaterThan(1),
          reason: '三套预设的卡片不透明度应有差异');
      print('  fillAlpha: aurora=${aurora.fillAlpha} '
          'paper=${paper.fillAlpha} midnight=${midnight.fillAlpha}');
    });

    test('每套预设的字段都有意义（非空、alpha 合法）', () {
      for (final p in DiscoverPreset.values) {
        final s = DiscoverStyle.of(p);
        expect(s.preset, p);
        // fillAlpha 必须在 0–1（超出会抛运行时异常）
        expect(s.fillAlpha, inInclusiveRange(0.0, 1.0),
            reason: '${p.name} 的 fillAlpha=${s.fillAlpha} 越界');
        // 不能是透明色（否则卡片/文字看不见）
        expect(s.primary.a, greaterThan(0), reason: '${p.name} 主文字色全透明');
        expect(s.accent.a, greaterThan(0), reason: '${p.name} 强调色全透明');
        expect(s.cardFill.a, greaterThan(0), reason: '${p.name} 卡片色全透明');
        expect(s.backdrop.a, greaterThan(0), reason: '${p.name} 底色全透明');
      }
    });
  });
}
