import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/theme/discover_preset.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/discover_sections.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';

/// 发现页三个区块组件的**渲染契约测试**。
///
/// ── 为什么这些测试值得写 ──────────────────────────────────────
/// 这三块都是**横向/网格布局 + 固定像素尺寸**（108 封面 / 52 行封面 /
/// 144 网格封面），最容易出的问题是：
///   · 布局溢出（RenderFlex overflow）—— 在真机上表现为黄黑条纹
///   · 系统大字号时文字把卡片挤爆
/// Flutter 的 widget 测试会**把 overflow 当异常抛出**，所以这里能挡住。
///
/// 另外锁住三套预设**都能渲染**（预设只改材质，不该有某套渲染不出来）。
void main() {
  setUpAll(() {
    // `MusicTheme.palette` 需要 bridge（未注册会命中 #13 的断言）
    MusicPaletteBridge.register(() => const JellyPalette.ink());
  });

  Song song(int i, {bool vip = false, String? cover}) => Song(
        id: i,
        name: '测试歌曲 $i',
        artists: '歌手 $i',
        album: '专辑 $i',
        coverUrl: cover,
        duration: 200,
        fee: vip ? 1 : 0,
      );

  TopList rank(int i) =>
      TopList(id: i, name: '榜单 $i', updateFrequency: '每天更新');

  Playlist playlist(int i) =>
      Playlist(id: i, name: '歌单 $i', trackCount: 30);

  group('三套预设都能渲染（预设不该有"某套渲染不出来"）', () {
    for (final p in DiscoverPreset.values) {
      testWidgets('${p.label}：每日推荐 + 排行榜 + 歌单广场', (tester) async {
        final style = DiscoverStyle.of(p);
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 390,
                child: Column(
                  children: [
                    DailySongsRow(
                      style: style,
                      songs: List.generate(8, song),
                      playingKey: null,
                      isPlaying: false,
                      onPlay: (_) {},
                    ),
                    RankListCard(
                      style: style,
                      items: List.generate(12, rank),
                      onTap: (_) {},
                    ),
                    PlaylistGrid(
                      style: style,
                      items: List.generate(10, playlist),
                      onTap: (_) {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ));
        // ⚠️ 必须 pump 一个有长度的时长（不能用无参 pump）：
        // `DailySongsRow` 里有个常驻的均衡器动画（`repeat(reverse:true)`），
        // 只 pump 一帧时动画调度还挂着，测试结束会在
        // "finalizing the widget tree" 阶段抛异常。
        await tester.pump(const Duration(milliseconds: 40));
        // 三块都要在（能渲染 = 没抛 overflow / 没崩）
        expect(find.byType(DailySongsRow), findsOneWidget);
        expect(find.byType(RankListCard), findsOneWidget);
        expect(find.byType(PlaylistGrid), findsOneWidget);
        print('  ${p.label}: fillAlpha=${style.fillAlpha} 渲染 OK');
      });
    }
  });

  group('每日推荐', () {
    testWidgets('VIP 歌显示 VIP 标', (tester) async {
      final style = DiscoverStyle.of(DiscoverPreset.aurora);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DailySongsRow(
            style: style,
            songs: [song(1, vip: true), song(2)],
            playingKey: null,
            isPlaying: false,
            onPlay: (_) {},
          ),
        ),
      ));
      // ⚠️ 必须 pump 一个有长度的时长（不能用无参 pump）：
        // `DailySongsRow` 里有个常驻的均衡器动画（`repeat(reverse:true)`），
        // 只 pump 一帧时动画调度还挂着，测试结束会在
        // "finalizing the widget tree" 阶段抛异常。
        await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('VIP'), findsOneWidget, reason: '只有 VIP 那首该有标');
    });

    testWidgets('最多只渲染 maxCount 张（默认 8）', (tester) async {
      final style = DiscoverStyle.of(DiscoverPreset.aurora);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DailySongsRow(
            style: style,
            songs: List.generate(30, song),
            playingKey: null,
            isPlaying: false,
            onPlay: (_) {},
          ),
        ),
      ));
      // ⚠️ 必须 pump 一个有长度的时长（不能用无参 pump）：
        // `DailySongsRow` 里有个常驻的均衡器动画（`repeat(reverse:true)`），
        // 只 pump 一帧时动画调度还挂着，测试结束会在
        // "finalizing the widget tree" 阶段抛异常。
        await tester.pump(const Duration(milliseconds: 40));
      // 只找得到前 8 首（横向 ListView 惰性构建，但前几首一定在）
      expect(find.text('测试歌曲 0'), findsOneWidget);
      expect(find.text('测试歌曲 20'), findsNothing,
          reason: 'maxCount=8 时不该渲染第 21 张');
    });

    testWidgets('空列表不崩（返回 shrink）', (tester) async {
      final style = DiscoverStyle.of(DiscoverPreset.aurora);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DailySongsRow(
            style: style,
            songs: const [],
            playingKey: null,
            isPlaying: false,
            onPlay: (_) {},
          ),
        ),
      ));
      // ⚠️ 必须 pump 一个有长度的时长（不能用无参 pump）：
        // `DailySongsRow` 里有个常驻的均衡器动画（`repeat(reverse:true)`），
        // 只 pump 一帧时动画调度还挂着，测试结束会在
        // "finalizing the widget tree" 阶段抛异常。
        await tester.pump(const Duration(milliseconds: 40));
      expect(tester.takeException(), isNull);
    });
  });

  group('排行榜（收起 3 / 展开）', () {
    testWidgets('收起时只渲染 3 行 + 有展开按钮', (tester) async {
      final style = DiscoverStyle.of(DiscoverPreset.aurora);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RankListCard(
            style: style,
            items: List.generate(12, rank),
            onTap: (_) {},
          ),
        ),
      ));
      // ⚠️ 必须 pump 一个有长度的时长（不能用无参 pump）：
        // `DailySongsRow` 里有个常驻的均衡器动画（`repeat(reverse:true)`），
        // 只 pump 一帧时动画调度还挂着，测试结束会在
        // "finalizing the widget tree" 阶段抛异常。
        await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('榜单 0'), findsOneWidget);
      expect(find.text('榜单 2'), findsOneWidget);
      expect(find.text('榜单 3'), findsNothing, reason: '收起时第 4 行不该在');
      expect(find.textContaining('展开全部'), findsOneWidget);
    });

    testWidgets('点展开 → 显示到第 10 行', (tester) async {
      final style = DiscoverStyle.of(DiscoverPreset.aurora);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RankListCard(
              style: style,
              items: List.generate(12, rank),
              onTap: (_) {},
            ),
          ),
        ),
      ));
      // ⚠️ 必须 pump 一个有长度的时长（不能用无参 pump）：
        // `DailySongsRow` 里有个常驻的均衡器动画（`repeat(reverse:true)`），
        // 只 pump 一帧时动画调度还挂着，测试结束会在
        // "finalizing the widget tree" 阶段抛异常。
        await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.textContaining('展开全部'));
      await tester.pumpAndSettle();
      expect(find.text('榜单 9'), findsOneWidget, reason: '展开后第 10 行应在');
      expect(find.text('榜单 10'), findsNothing,
          reason: 'maxCount=10，第 11 行不该在');
      expect(find.text('收起'), findsOneWidget);
    });

    testWidgets('不足收起数时**不给**展开按钮', (tester) async {
      final style = DiscoverStyle.of(DiscoverPreset.aurora);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RankListCard(
            style: style,
            items: List.generate(2, rank),
            onTap: (_) {},
          ),
        ),
      ));
      // ⚠️ 必须 pump 一个有长度的时长（不能用无参 pump）：
        // `DailySongsRow` 里有个常驻的均衡器动画（`repeat(reverse:true)`），
        // 只 pump 一帧时动画调度还挂着，测试结束会在
        // "finalizing the widget tree" 阶段抛异常。
        await tester.pump(const Duration(milliseconds: 40));
      expect(find.textContaining('展开全部'), findsNothing,
          reason: '只有 2 个还显示"展开"是假按钮');
    });
  });

  group('歌单广场（收起 6 / 展开）', () {
    testWidgets('收起时只渲染 6 个', (tester) async {
      final style = DiscoverStyle.of(DiscoverPreset.aurora);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PlaylistGrid(
              style: style,
              items: List.generate(10, playlist),
              onTap: (_) {},
            ),
          ),
        ),
      ));
      // ⚠️ 必须 pump 一个有长度的时长（不能用无参 pump）：
        // `DailySongsRow` 里有个常驻的均衡器动画（`repeat(reverse:true)`），
        // 只 pump 一帧时动画调度还挂着，测试结束会在
        // "finalizing the widget tree" 阶段抛异常。
        await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('歌单 0'), findsOneWidget);
      expect(find.text('歌单 6'), findsNothing, reason: '收起时第 7 个不该在');
    });
  });
}
