import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/pages/player_page.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';

/// 播放页布局回归测试 —— 守住 2026-10-30 这次整体重做的结构。
///
/// ── 为什么需要它 ────────────────────────────────────────────────
/// 播放页是**一屏定高**的：顶部顶栏 + 中间 `Expanded` 封面区 + 底部控制区，
/// 三段都是固定高度。底部控制区这次从"三行"变成"四段"
///（标题 64 + 进度 46 + 播放行 72 + 动作行 44），
/// 一旦某一段长高，最先出事的就是**小屏（iPhone SE 375×667）**：
/// `RenderFlex overflowed` 黄黑条，或者封面被压到看不见。
///
/// 这个测试把三种常见屏宽/屏高都跑一遍，并显式检查：
///   1. 不出现 `ErrorWidget`（任一分支画崩就会整屏变白板）
///   2. 不出现 overflow（`tester.takeException()` 为空）
///   3. 关键内容真的在：歌名 / 歌手 / 时间 / 进度 / 播放键
///   4. 封面 ⇄ 歌词切换后**歌词视图也不溢出**
///
/// ⚠️ 不 pumpAndSettle：封面旋转与氛围脉冲是**无限动画**，
/// `pumpAndSettle` 会一直等下去直到超时。这里只推进有限时长。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 测试环境没有 main.dart 的启动流程，`MusicTheme.palette` 会走
  // `MusicPaletteBridge.current()` —— 未注册时 music_theme.dart 里的断言会抛。
  setUp(() {
    MusicPaletteBridge.register(() => const JellyPalette.ink());
    // playing: false —— 让 `_spin` 走"减速停下"（有限时长）而不是 repeat
    MusicPlayerManager.instance.debugSetPlayingForTest(
      const Song(
        id: 4242,
        name: '一首名字比较长的测试歌曲用来验证省略号',
        artists: '测试歌手',
        duration: 245,
      ),
      playing: false,
    );
  });

  tearDown(() {
    MusicPlayerManager.instance.debugSetPlayingForTest(null);
  });

  Future<void> pumpPage(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Theme(
          data: MusicTheme.themeData(),
          child: const MusicPlayerPage(),
        ),
      ),
    );
    // 封面旋转要 900ms 才停稳；再给 AnimatedSwitcher / AnimatedScale 留余量
    await tester.pump(const Duration(milliseconds: 1100));
  }

  /// 遍历元素树找 ErrorWidget —— 它一旦出现，页面就是一块白板，
  /// 但**不会**抛异常，只看 takeException 是抓不到的。
  int countErrorWidgets(WidgetTester tester) {
    var n = 0;
    var visited = 0;
    void visit(Element e) {
      if (++visited > 20000) return;
      if (e.widget is ErrorWidget) n++;
      e.visitChildren(visit);
    }

    tester.allElements.forEach(visit);
    return n;
  }

  const sizes = <String, Size>{
    'iPhone SE 375×667': Size(375, 667),
    'iPhone 14 390×844': Size(390, 844),
    'iPhone 15 Pro Max 430×932': Size(430, 932),
  };

  for (final entry in sizes.entries) {
    testWidgets('播放页在 ${entry.key} 上不溢出、内容齐全', (tester) async {
      await pumpPage(tester, entry.value);

      expect(tester.takeException(), isNull,
          reason: '${entry.key} 上播放页抛异常（多半是底部控制区超高 '
              '或封面区算出的尺寸为负）');
      expect(countErrorWidgets(tester), 0,
          reason: '${entry.key} 上出现了 ErrorWidget —— 有分支出错');

      // 歌名 / 歌手（左对齐标题区）
      expect(find.textContaining('一首名字比较长的测试歌曲'), findsOneWidget,
          reason: '标题区丢了歌名');
      expect(find.text('测试歌手'), findsOneWidget, reason: '标题区丢了歌手');

      // 进度条两端的时间（测试环境没真的播放，两端都是 0:00）
      expect(find.text('0:00'), findsNWidgets(2),
          reason: '进度条两侧的时间不见了（当前 / 总时长）');

      // 播放键（暂停态显示 play_arrow）
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget,
          reason: '播放行丢了主播放键');

      // 动作行五项（快退/音量/歌词/快进/设置）
      expect(find.byIcon(Icons.replay_10_rounded), findsOneWidget);
      expect(find.byIcon(Icons.forward_10_rounded), findsOneWidget);
      expect(find.byIcon(Icons.lyrics_rounded), findsOneWidget);
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);

      // 收藏在标题区右侧
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    });
  }

  testWidgets('点中间区域切到歌词视图 —— 同样不溢出', (tester) async {
    const size = Size(375, 667); // 最紧的那档
    await pumpPage(tester, size);

    // 中间区域（封面/歌词切换的热区）在屏幕中上部
    await tester.tapAt(Offset(size.width / 2, size.height * 0.38));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull, reason: '切到歌词后溢出了');
    expect(countErrorWidgets(tester), 0);
    // 这首歌没有歌词 → 空态文案
    expect(find.text('暂无歌词'), findsOneWidget, reason: '歌词视图没渲染出来');
  });
}
