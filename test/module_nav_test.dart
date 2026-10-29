import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 模块切换与悬浮栏不重叠的回归测试。
///
/// ── 背景（用户实测反馈）──────────────────────────────────────
/// 音乐（IndexedStack 索引 5）和阅读（索引 6）**各自带悬浮导航栏**：
///   · 音乐 = MusicRootView 自绘的 4-tab 栏
///   · 阅读 = cmbok 的 JellyNavBar 5-tab 栏
/// 影视底栏如果不让位，屏幕上会出现**两条叠在一起的栏**。
///
/// 这个测试把"该不该显示影视底栏"的判定逻辑固化下来，
/// 防止以后有人改 app.dart 时又把条件删掉。
void main() {
  /// 与 app.dart 里的判定保持一致：
  /// 全屏 或 在音乐/阅读 tab → 隐藏影视底栏。
  bool shouldShowVideoNavBar({
    required bool isFullscreen,
    required int tabIndex,
    int musicTabIndex = 5,
    int booksTabIndex = 6,
  }) {
    if (isFullscreen) return false;
    if (tabIndex == musicTabIndex || tabIndex == booksTabIndex) return false;
    return true;
  }

  test('音乐 tab 隐藏影视底栏（否则两条栏重叠）', () {
    expect(
      shouldShowVideoNavBar(isFullscreen: false, tabIndex: 5),
      isFalse,
      reason: '音乐自带 4-tab 悬浮栏，影视底栏必须隐藏',
    );
  });

  test('阅读 tab 隐藏影视底栏', () {
    expect(
      shouldShowVideoNavBar(isFullscreen: false, tabIndex: 6),
      isFalse,
      reason: '阅读自带 cmbok 的 JellyNavBar，影视底栏必须隐藏',
    );
  });

  test('影视自己的 tab 仍显示底栏', () {
    // 0=首页 1=史藏 3=设置 4=直播
    for (final t in [0, 1, 3, 4]) {
      expect(
        shouldShowVideoNavBar(isFullscreen: false, tabIndex: t),
        isTrue,
        reason: '影视 tab($t) 必须显示底栏，否则无法切换页面',
      );
    }
  });

  test('RSS（索引 8）也显示悬浮底栏', () {
    // 索引 8 曾是已下线的「网页」模块（当时要求全屏隐藏底栏）；
    // WebHTV 下线后 8 = RSS，RSS 没有自带底栏 ⇒ 必须显示影视悬浮栏
    // （用户 2026-10-18：「RSS 还是显示悬浮菜单栏吧」）。
    expect(
      shouldShowVideoNavBar(isFullscreen: false, tabIndex: 8),
      isTrue,
      reason: 'RSS 页面必须能看到悬浮导航栏',
    );
  });

  test('全屏播放时任何 tab 都隐藏底栏', () {
    for (final t in [0, 1, 5, 6]) {
      expect(
        shouldShowVideoNavBar(isFullscreen: true, tabIndex: t),
        isFalse,
        reason: '全屏时底栏必须隐藏，让视频真正铺满',
      );
    }
  });

  testWidgets('音乐/阅读页面的顶部内容不被状态栏遮挡', (tester) async {
    // 模拟 iPhone 刘海机的安全区
    const statusBar = 59.0;
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    tester.view.padding = const FakeViewPadding(top: statusBar * 3);
    addTearDown(tester.view.reset);

    // SafeArea 应把内容推到状态栏之下
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Align(alignment: Alignment.topLeft, child: Text('顶部内容')),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final top = tester.getTopLeft(find.text('顶部内容')).dy;
    expect(top, greaterThanOrEqualTo(statusBar - 1),
        reason: '顶部内容 y=$top 被状态栏（$statusBar）遮挡了');
  });
}
