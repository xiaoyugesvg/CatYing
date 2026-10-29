import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';

/// 「水墨书香」主题的回归测试。
///
/// ── 为什么必须测 ──────────────────────────────────────────────
/// 「水墨书香」是**全 App 的默认主题**（影视/直播/音乐的配色基准）。
/// 它一旦出问题，后果不是"少一个主题"而是：
///   · `fromPreset('ink')` 落到 default → 静默变成「魅力紫色」，
///     **不报错**，只是全 App 颜色不对 —— 最难查的那种
///   · 默认值被改回 'jelly' → 新用户看到的是紫色而不是水墨
///   · 背景画笔没注册 → 背景一片空白（也不报错）
///
/// ── 关于配色意图（避免以后又被"优化"错）───────────────────────
/// 用户要的是主题列表里名为**「水墨书香」**的那一项（色块为 墨/灰/白）。
/// 所以：
///   · **是**水墨调：墨灰主色 + 宣纸米白底 + 赭石点缀
///   · **不是**纯黑纯白的"极简黑白 UI" —— 我一度改成近黑主色 + 中性灰白底，
///     那是把"水墨书香"理解错了，这里有一条专门挡住这种回归
void main() {
  group('水墨书香调色板', () {
    const p = JellyPalette.ink();

    test('浅色：宣纸米白底（偏暖）+ 墨色文字', () {
      // 书香 = 纸感：底色是暖米白，不是纯白
      expect(p.backgroundLight, isNot(equals(const Color(0xFFFFFFFF))));
      // 偏暖：红分量 >= 蓝分量（宣纸的观感）
      expect(p.backgroundLight.r, greaterThanOrEqualTo(p.backgroundLight.b),
          reason: '底应偏暖（宣纸）；偏冷就变成"冷灰 UI"了，不是水墨书香');
      // 文字比底色深得多（可读性下限）
      expect(p.textPrimaryLight.computeLuminance(),
          lessThan(p.backgroundLight.computeLuminance()));
      // 卡片纯白，浮在米白底上分层
      expect(p.cardLight, equals(const Color(0xFFFFFFFF)));
    });

    test('深色：墨夜深灰（非纯黑）+ 浅色文字', () {
      // 水墨的"夜"是墨夜，不是纯黑屏幕
      expect(p.backgroundDark, isNot(equals(const Color(0xFF000000))));
      expect(p.backgroundDark, isNot(equals(const Color(0xFFFFFFFF))));
      expect(p.textPrimaryDark.computeLuminance(),
          greaterThan(p.backgroundDark.computeLuminance()));
    });

    test('主色是墨灰（水墨的"墨"），不是纯黑也不是纯白', () {
      // 纯黑作主色/图标色太硬，与正文同色还会失去层次
      expect(p.primary, isNot(equals(const Color(0xFF000000))));
      expect(p.primary, isNot(equals(const Color(0xFFFFFFFF))));
      // 但也要足够深，才像"墨"（不能变成浅灰）
      expect(p.primary.computeLuminance(), lessThan(0.15),
          reason: '墨灰要有墨的分量，太浅就成浅灰了');
      // 与浅色底对比足够（按钮边界看得见）
      final diff = (p.primary.computeLuminance() -
              p.backgroundLight.computeLuminance())
          .abs();
      expect(diff, greaterThan(0.3), reason: '主色与底色太接近会看不出按钮边界');
    });

    test('强调色是低饱和赭石（水墨画里的印章色）', () {
      expect(p.accent, isNot(equals(p.primary)));
      // 赭石偏暖：R > B
      expect(p.accent.r, greaterThan(p.accent.b),
          reason: '赭石/赭黄是暖色（红分量大于蓝分量）');
      // 低饱和 —— 不能是刺眼的橙
      final mx = [p.accent.r, p.accent.g, p.accent.b]
          .reduce((a, b) => a > b ? a : b);
      final mn = [p.accent.r, p.accent.g, p.accent.b]
          .reduce((a, b) => a < b ? a : b);
      final sat = mx == 0 ? 0.0 : (mx - mn) / mx;
      expect(sat, lessThan(0.6), reason: '赭石应低饱和，不能抢眼');
    });

    test('整体以无彩色为主（水墨）—— 只有强调色带暖', () {
      for (final c in [p.primary, p.textPrimaryLight, p.backgroundLight]) {
        final rr = (c.r * 255).round();
        final bb = (c.b * 255).round();
        expect((rr - bb).abs(), lessThanOrEqualTo(12),
            reason: '水墨调里除强调色外都该接近中性色');
      }
    });

    test('语义色保留（功能色不能也变灰）', () {
      // 用户必须能分辨"下载失败"
      expect(p.success, isNot(equals(p.error)));
      expect(p.warning, isNot(equals(p.error)));
      expect(p.success, isNot(equals(p.warning)));
    });

    test('深浅两套色齐全（白天/黑夜都能用）', () {
      for (final c in [
        p.backgroundLight,
        p.backgroundDark,
        p.cardLight,
        p.cardDark,
        p.textPrimaryLight,
        p.textPrimaryDark,
        p.textSecondary,
        p.navSelectedBg,
        p.navSelectedFg,
        p.navUnselected,
      ]) {
        expect(c, isNotNull);
      }
    });
  });

  group('预设解析（解析错会静默变成别的主题）', () {
    test("fromPreset('ink') 解析到水墨书香，而不是回退到 jelly", () {
      final ink = JellyPalette.fromPreset('ink');
      final fallback = JellyPalette.fromPreset('__不存在__');
      expect(ink.backgroundLight, isNot(equals(fallback.backgroundLight)),
          reason: '若 ink 没注册，fromPreset 会落到 default=jelly，颜色就错了');
      expect(ink.backgroundLight, const JellyPalette.ink().backgroundLight);
      expect(ink.primary, const JellyPalette.ink().primary);
    });

    test('未知 id 仍在回退（不会崩）', () {
      expect(() => JellyPalette.fromPreset('乱写的'), returnsNormally);
      expect(() => JellyPalette.fromPreset(''), returnsNormally);
    });

    test('预设列表里 水墨书香 排第一（截图里它是第一项）', () {
      expect(themePresets, isNotEmpty);
      expect(themePresets.first.id, 'ink');
      expect(themePresets.first.name, '水墨书香');
    });

    test('预设名唯一（重名会让用户选错）', () {
      final names = themePresets.map((e) => e.name).toList();
      expect(names.toSet().length, names.length);
      expect(names, contains('水墨书香'));
    });

    test('旧预设都还在（不能因为新增而弄丢）', () {
      final ids = themePresets.map((e) => e.id).toSet();
      for (final id in [
        'ink',
        'jelly',
        'pink',
        'green',
        'ocean',
        'sunset',
        'sky',
      ]) {
        expect(ids, contains(id), reason: '预设 $id 丢了');
      }
    });

    test('每个预设的 id 唯一（重复会让选中态错乱）', () {
      final ids = themePresets.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length);
    });
  });

  group('默认主题与白天/黑夜模式', () {
    test('默认预设是 ink（水墨书香）排第一且可解析', () {
      expect(themePresets.first.id, 'ink');
      expect(
        () => JellyPalette.fromPreset(themePresets.first.id),
        returnsNormally,
      );
    });

    test('深浅两套色的明暗方向正确（防止写反）', () {
      const p = JellyPalette.ink();
      expect(p.backgroundDark.computeLuminance(),
          lessThan(p.backgroundLight.computeLuminance()),
          reason: '暗色底必须比亮色底暗，否则白天/黑夜模式反了');
      expect(p.cardDark.computeLuminance(),
          lessThan(p.cardLight.computeLuminance()));
    });

    test('深色模式的卡片比底更亮（保持"卡片浮起"的层次）', () {
      const p = JellyPalette.ink();
      expect(p.cardDark.computeLuminance(),
          greaterThan(p.backgroundDark.computeLuminance()),
          reason: '深色下也要能看出卡片边界');
    });
  });
}
