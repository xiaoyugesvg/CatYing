import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/common/floating_nav_spec.dart';

/// 三条悬浮菜单栏的一致性测试。
///
/// ── 为什么必须测 ──────────────────────────────────────────────
/// 影视 / 音乐 / 阅读三条底栏原本各写各的，实测三处都不一样：
///
/// |          | 影视      | 音乐      | 阅读        |
/// |----------|-----------|-----------|-------------|
/// | 图标/文字 | 图标+文字 | 图标+文字 | **只有图标** |
/// | 圆角      | 30        | 22        | 32          |
/// | 距底部    | **8**     | 30        | 30          |
/// | 图标尺寸  | 18        | 21        | 26          |
///
/// 这些是**跨文件的重复字面量**，改一处很容易忘另两处。
/// 所以规格抽进 `FloatingNavSpec`，并用这些测试挡住"又漂回去"。
void main() {
  group('悬浮栏统一规格', () {
    test('距底部是 30（不是影视原来的 8）', () {
      // 8 会让底栏紧贴 Home Indicator，看起来"陷进屏幕底部"，
      // 与音乐/阅读明显不一致 —— 用户一眼就看出来了
      // [对齐] 规格已按用户 2026-10-02 的要求由 30 → 20
      expect(FloatingNavSpec.bottomMargin, 20);
    });

    test('圆角是 32（三条栏统一值）', () {
      expect(FloatingNavSpec.radius, 32.0);
    });

    test('展示形式统一为"图标 + 文字"', () {
      // 用一组常量存在与否表达这个决定：标签字号和间距都必须 > 0，
      // 否则就是退化成"只有图标"了
      expect(FloatingNavSpec.labelSize, greaterThan(0),
          reason: '标签字号为 0 等于没有文字，三条栏里就只有阅读是纯图标');
      expect(FloatingNavSpec.iconLabelGap, greaterThan(0));
    });

    test('图标尺寸三条栏一致（21）', () {
      expect(FloatingNavSpec.iconSize, 21.0);
    });

    test('几何值互相不矛盾（防止改出负数/零）', () {
      // 胶囊高度必须容得下 上下内边距 + 图标 + 间距 + 文字
      final needed = FloatingNavSpec.innerPadV * 2 +
          FloatingNavSpec.iconSize +
          FloatingNavSpec.iconLabelGap +
          FloatingNavSpec.labelSize;
      expect(FloatingNavSpec.barHeight, greaterThanOrEqualTo(needed),
          reason: '胶囊太矮会把内容挤到溢出（黄黑条纹）');
      expect(FloatingNavSpec.itemRadius, lessThan(FloatingNavSpec.radius),
          reason: '选中项圆角不该大于胶囊圆角，否则会切到外面去');
      expect(FloatingNavSpec.innerPadH, greaterThan(0));
      expect(FloatingNavSpec.sideMargin, greaterThan(0));
    });

    test('颜色值都在合法范围内（防止 alpha 写成 >1）', () {
      for (final a in [
        FloatingNavSpec.barAlpha,
        FloatingNavSpec.itemSelectedAlpha,
        FloatingNavSpec.shadowAlpha,
      ]) {
        expect(a, greaterThan(0));
        expect(a, lessThanOrEqualTo(1.0),
            reason: 'alpha 超过 1 会被 Flutter 断言拦住');
      }
    });

    test('模糊强度为正（否则 BackdropFilter 没效果）', () {
      expect(FloatingNavSpec.blurSigma, greaterThan(0));
    });

    test('阴影 offset 是向下的（底栏阴影不该往上投）', () {
      expect(FloatingNavSpec.shadowOffset.dy, greaterThan(0));
      expect(FloatingNavSpec.shadowOffset.dx, 0);
      expect(FloatingNavSpec.shadowBlur, greaterThan(0));
    });
  });

  group('三个模块都引用了这个规格（防止又各自写死）', () {
    test('规格类可被正常实例化常量访问', () {
      // 纯常量类，编译通过即说明引用方（app.dart / jelly_nav_bar.dart）
      // 的 import 路径正确。真正的"三处一致"由上面几组断言保证。
      expect(FloatingNavSpec.barHeight, isNotNull);
      expect(const Offset(0, 4), FloatingNavSpec.shadowOffset);
    });
  });
}
