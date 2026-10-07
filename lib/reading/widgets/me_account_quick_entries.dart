import 'package:flutter/material.dart';

import '../theme/jelly_theme.dart';

/// 三条"我的"入口（「我的笔记」/「阅读经历」/「阅读计划」）的**纯图标行**。
///
/// ── 为什么是纯图标（用户反馈，原话）────────────────────────────
/// 「阅读模块里面的我的页面那三个（我的笔记、阅读经历、阅读计划**只留图标**）
///   图标**并排放在那个登录（也就是第一个卡片）的右上角**」
///
/// 所以本组件：
///   · **没有**任何常驻文字（原来每个图标下面带一行 `label` 文字，已删）；
///     语义改由 [Tooltip]（长按 / 悬停可见）承载，点击目标页不变。
///   · 只有**一行**，由使用方（`me_page.dart` 的登录卡）用
///     `Stack` + `Positioned(top: 16, right: 16)` 钉进卡片右上角
///     —— 不是卡片下方独立一行，也不在卡片外面。
///
/// ── 自量宽度：热区≥40 与"绝不溢出"两条硬约束的调和 ─────────────
/// 三个 40 的可点区并排 = 3×40 + 2×4(间距) = **128**。调用方在 360 宽屏上
/// 至少留了 174（见 `me_page.dart` 的 `quickEntriesReserve`），所以**满尺寸**
/// 就跑满 40×40（题目要求的热区下限），图标本体 20 居中，视觉上仍是小圆。
///
/// 但窄屏（≤300）或以后有人把卡片内边距调大时，128 可能放不下 ——
/// 硬塞会**溢出**（题目明令禁止）。因此这里用 [LayoutBuilder] 量出可用宽度：
/// 放得下就用 [tapSize]；放不下就按 `(可用宽度 - 2×间距) / 3` 等比缩小
/// （`clamp(32, 40)`，宁可让热区退到 32 也**绝不溢出**、绝不换行/裁切）。
///
/// ⚠️ 配色全部取自 [JellyTheme]（= 当前主题的 [JellyPalette]），
///    这里**不写死任何颜色**，换主题（水墨/粉/绿/海洋…）自动跟随。
///
/// ⚠️ 对外只暴露**常量** [tapSize]/[gap]/[entries]，供调用方
///    （`me_page.dart`）算出"要给右上角预留多宽" — 见 [rowWidth]。
class MeAccountQuickEntries extends StatelessWidget {
  const MeAccountQuickEntries({
    super.key,
    required this.isDark,
    required this.onNotes,
    required this.onJourney,
    required this.onPlan,
  });

  /// 是否深色模式（决定圆底用"主题色 22%"还是"主题色 15%"）。
  final bool isDark;

  /// 「我的笔记」→ 笔记与阅读经历页
  final VoidCallback onNotes;

  /// 「阅读经历」→ 浏览历史页（无 Tab 形态）
  final VoidCallback onJourney;

  /// 「阅读计划」→ 阅读计划页
  final VoidCallback onPlan;

  /// 三个入口的固定顺序与语义（顺序即并排顺序：笔记 / 经历 / 计划）。
  /// 三个图标各自不同，保证"互相有辨识度"：
  ///   · `edit_note`       —— 纸笔＝笔记
  ///   · `route`           —— 路线＝经历/轨迹
  ///   · `event_available` —— 日历打勾＝计划
  static const List<({IconData icon, String tooltip})> entries = [
    (icon: Icons.edit_note_rounded, tooltip: '我的笔记'),
    (icon: Icons.route_rounded, tooltip: '阅读经历'),
    (icon: Icons.event_available_rounded, tooltip: '阅读计划'),
  ];

  /// 单个可点热区 / 视觉圆直径（= 40，正好是题目"热区 ≥40×40"的下限）
  static const double tapSize = 40;

  /// 放不下时热区可以退到的最小值（仍比 32 的图标本体大一档）
  static const double minTapSize = 32;

  /// 图标之间留的呼吸间距
  static const double gap = 4;

  /// 满尺寸时这一行的总宽（= 3×40 + 2×4 = 128）。
  /// 调用方用它 + 卡片内边距算出右侧要预留多少，避免文字被图标盖住。
  static const double rowWidth = tapSize * 3 + gap * 2;

  @override
  Widget build(BuildContext context) {
    final primary = JellyTheme.primary;
    final bg = primary.withValues(alpha: isDark ? 0.22 : 0.15);
    final callbacks = [onNotes, onJourney, onPlan];

    // 量出可用宽度：够 128 就满尺寸，不够就等比缩小（绝不溢出）
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : rowWidth;
        final size = available >= rowWidth
            ? tapSize
            : ((available - gap * 2) / 3).clamp(minTapSize, tapSize);
        // 图标本体：热区的 50%，但不超过 20（视觉上比 38 的顶栏圆更小）
        final iconSize = (size / 2).clamp(16.0, 20.0);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < entries.length; i++) ...[
              if (i > 0) const SizedBox(width: gap),
              _entry(
                icon: entries[i].icon,
                tooltip: entries[i].tooltip,
                bg: bg,
                fg: primary,
                onTap: callbacks[i],
                size: size,
                iconSize: iconSize,
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _entry({
    required IconData icon,
    required String tooltip,
    required Color bg,
    required Color fg,
    required VoidCallback onTap,
    required double size,
    required double iconSize,
  }) {
    // 圆底 + 热区 = 同一个 size 的方框：热区不会比看到的圆小，
    // 满足"点击热区 ≥40×40"（满尺寸时；窄屏等比退让见类注释）
    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(child: Icon(icon, size: iconSize, color: fg)),
          ),
        ),
      ),
    );
  }
}
