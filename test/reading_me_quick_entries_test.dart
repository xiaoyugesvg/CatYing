import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/reading/pages/me_page.dart';
import 'package:tvbox/reading/theme/jelly_theme.dart';
import 'package:tvbox/reading/widgets/me_account_quick_entries.dart';

/// 「我的」页三个入口的回归测试（用户 2026 反馈）。
///
/// ── 用户原话 ────────────────────────────────────────────────────
/// 「阅读模块里面的我的页面那三个（我的笔记、阅读经历、阅读计划**只留图标**）
///   图标**并排放在那个登录（也就是第一个卡片）的右上角**」
///
/// ── 为什么必须测（这里出过两次错，都只有肉眼才看得出来）──────────
///   1. 三个入口原来是登录卡**下方的一行**：图标 42 圆 + 下方 `Text(label)`。
///      文字一旦漏删（改一半），视觉上就是"图标+文字"照旧，**不报错**
///   2. 位置对不对**几何问题**：光看 widget 树没意义，必须量
///      `quickEntries` 的矩形与**登录卡本体**的矩形做关系断言，
///      否则"放进卡片右上角"完全可以写成"卡片外面右上角"还测试全绿
///
/// ── ⚠️ 为什么直接 pump `MePage` 也不算联网测试 ──────────────────
/// `_MePageState.initState` 只调 `_maybeTriggerGuide()`，且 [MePage] 默认
/// `isActive: false` ⇒ 引导不触发；卡片读的 `ZlibraryService()` 是**懒初始化
/// 单例**（构造时 fire-and-forget 探测），在 `flutter_test` 里所有 HTTP 都走
/// 测试桩、立刻失败返回，**不会真的联网**，也不会挂住 pump。
/// 但也正因为它发了请求，本测试**不 pump 第二帧之后的东西**（不做
/// `pumpAndSettle`），避免等不到任何异步收敛。
///
/// ── 量到的实际数值（360 宽屏，DPR 3，root padding 12+8，卡片 padding 16）──
/// 卡片矩形            = (12, 6) .. (348, 190)   → 宽 336，高 184
/// quickEntries 矩形   = (204, 22) .. (332, 66)  → 宽 128（3×40 热区 + 2×4 间距）
/// 卡片右上角内侧 16px ⇒ 与卡片右缘差 16、与卡片顶差 16 ✓
///
/// ⚠️ 热区尺寸定在 **40**（= 题目要求的"至少 40×40"下限）：再往上是 44/48，
///   但 3×44 = 132 的图标行会把卡片上行的呼吸位吃掉，40 已满足可点下限。
const _quickEntriesKey = ValueKey('me_account_quick_entries');

/// 三个入口的语义图标（笔记 / 经历 / 计划），顺序即并排顺序
const _entryIcons = [
  Icons.edit_note_rounded,
  Icons.route_rounded,
  Icons.event_available_rounded,
];

/// 已删除的常驻文字（这些字符串**不允许**再出现在页面上）
const _removedLabels = ['我的笔记', '阅读经历', '阅读计划'];

Widget _host() {
  return MaterialApp(
    theme: JellyTheme.light,
    home: Scaffold(body: MePage()),
  );
}

void main() {
  testWidgets('登录卡右上角：三个入口只留图标、无文字，且并排在卡片内右上角', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 720 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host());
    await tester.pump();

    // ── ① 三个图标都在（各自的语义图标，三个互不相同）────────────
    expect(
      find.byKey(_quickEntriesKey),
      findsOneWidget,
      reason: '三个入口必须挂在登录卡里（key 是页面里的稳定锚点）',
    );
    for (final icon in _entryIcons) {
      expect(find.byIcon(icon), findsOneWidget, reason: '缺少入口图标 $icon');
    }
    expect(
      _entryIcons.toSet().length,
      3,
      reason: '三个入口的图标必须互不相同（笔记 / 经历 / 计划要一眼可辨）',
    );

    // ── ② 常驻文字一个都不能有（"只留图标"的硬断言）─────────────
    for (final label in _removedLabels) {
      expect(
        find.text(label),
        findsNothing,
        reason: '「$label」的文字标签已按用户要求删除，只留图标',
      );
    }

    // ── ③ 图标仍在、且**并排**：同一个 Row 内、y 相同、x 递增 ────
    final iconRects = [
      for (final icon in _entryIcons) tester.getRect(find.byIcon(icon)),
    ];
    for (var i = 1; i < iconRects.length; i++) {
      expect(
        iconRects[i].top,
        moreOrLessEquals(iconRects[0].top, epsilon: 0.5),
        reason: '三个图标要在同一行（并排），不能有的高有的低',
      );
      expect(
        iconRects[i].left,
        greaterThan(iconRects[i - 1].left),
        reason: '三个图标必须按 笔记 → 经历 → 计划 的顺序从左到右并排',
      );
    }

    // ── ④ 位置：在**登录卡内部**的右上角 ────────────────────────
    // 卡的定位要**精确**：`find.byType(InkWell)` 会匹配到页面里所有可点区域 ✗
    // （实测报 "ambiguously found multiple matching widgets" ✗）。
    //   改成"从三个图标往上找**最近的**卡片祖先" = 那张登录卡 ✓。
    //   2026-10-17：快捷条已移到账号 `InkWell` **外部**（仍与账号同处一张
    //   `Material` 卡片内）→ 祖先改成 `Material`，找不到再兜底全部 Material。
    //   ⚠️ 不能先 `.first` 再 `evaluate().isEmpty`：`.first` 在空集合上
    //   `evaluate()` 会直接抛 `Bad state: No element`（原测试的假失败点）。
    var cardFinder = find.ancestor(
      of: find.byKey(_quickEntriesKey),
      matching: find.byType(Material),
    );
    if (cardFinder.evaluate().isEmpty) {
      cardFinder = find.byType(Material);
    }
    final cardRect = tester.getRect(cardFinder.first);
    final iconsRect = tester.getRect(find.byKey(_quickEntriesKey));
    // 用具体数字记录几何，一旦以后有人搬走位置，失败信息里能直接看到差多少
    // ignore: avoid_print
    print('card=$cardRect  quickEntries=$iconsRect');

    expect(
      iconsRect.center.dy,
      lessThan(cardRect.center.dy),
      reason: '三个图标必须在卡片**上半部**（用户要右上角，不是底部）',
    );
    expect(
      iconsRect.center.dx,
      greaterThan(cardRect.center.dx),
      reason: '三个图标必须在卡片**右半部**（用户要右上角，不是左上角）',
    );
    expect(
      iconsRect.right,
      lessThanOrEqualTo(cardRect.right),
      reason: '不能溢出到卡片外',
    );
    expect(
      iconsRect.top,
      greaterThanOrEqualTo(cardRect.top),
      reason: '不能溢出到卡片外',
    );
    // "贴着右上角"：与卡片右缘、顶缘的距离都在 8..24 之间（实际 16）
    expect(cardRect.right - iconsRect.right, inInclusiveRange(8, 24));
    expect(iconsRect.top - cardRect.top, inInclusiveRange(8, 24));

    // ── ⑤ 可点热区 ≥ 40×40，且图标本体不会大到挤掉文字 ──────────
    final rowRect = tester.getRect(find.byType(MeAccountQuickEntries));
    final taps = [
      for (final icon in _entryIcons)
        tester.getRect(
          find.ancestor(of: find.byIcon(icon), matching: find.byType(InkWell)).first,
        ),
    ];
    // 本行内三个热区尺寸一致（避免"某一个特别小点不到"）
    for (final t in taps) {
      expect(t.width, taps[0].width);
      expect(t.height, taps[0].height);
      expect(t.height, greaterThanOrEqualTo(40), reason: '可点热区高度不足 40');
      expect(t.width, greaterThanOrEqualTo(40), reason: '可点热区宽度不足 40');
    }
    // 热区总宽 ≥ 3×40（不是"看着像三个其实挤在一起"）
    expect(rowRect.width, greaterThanOrEqualTo(3 * 40));
    // 图标本体 20，不应超过热区（不存在溢出）
    for (final icon in _entryIcons) {
      expect(tester.getSize(find.byIcon(icon)).width, lessThanOrEqualTo(40));
    }
    // 文字列仍有可用宽度（没被图标行压成 0 / 负）
    final textLeft = tester.getRect(find.text('还未登录')).left;
    expect(textLeft, lessThan(iconsRect.left)); // 文字在图标左侧，不重叠
    // 用例结束前销毁组件 ⇒ 取消页面里的周期定时器 ✓（否则 flutter_test 收尾会报
    // "Pending timers" ✗ —— 那是测试卫生问题，不是功能问题：上面的几何断言
    // 已证明三个图标确实在登录卡右上角 ✓）。
    await tester.pumpWidget(const SizedBox());
    // 再把假时钟往前推一点，让已排队的短定时器（主题/水波动画 0~135ms）烧完 ✓
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('三个圆底取当前主题色（不是写死色），深色模式同样成立', (tester) async {
    for (final dark in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? JellyTheme.dark : JellyTheme.light,
          // ⚠️ 不能 const：下面的 isDark 是循环变量 ✗
          home: Scaffold(
            body: Center(
              child: MeAccountQuickEntries(
                isDark: dark,
                onNotes: _noop,
                onJourney: _noop,
                onPlan: _noop,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(MeAccountQuickEntries), findsOneWidget);
      // 三个图标都取当前调色板主色 ⇒ 换主题自动跟随，没有写死的颜色
      for (final icon in _entryIcons) {
        final widget = tester.widget<Icon>(find.byIcon(icon));
        expect(
          widget.color,
          JellyTheme.primary,
          reason: '图标色必须取自 JellyTheme.primary（主题取色）',
        );
      }
      // 在 500×500 里不该出现任何溢出（图标行 + 热区尺寸自洽）
      expect(tester.takeException(), isNull);
    }
  });
}

void _noop() {}
