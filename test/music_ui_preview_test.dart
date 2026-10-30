// 音乐模块 UI 预览图（2026-10-31）
//
// 用途：用户要看「音乐模块的 UI 界面长什么样」。仓库里 `outputs/music_ui/`
// 那批 PNG 是 10-30 的设计稿，早于按 Mei 仓库重构的发现页，已经过时。
//
// 这里**不用设计稿**，直接把真实的组件按真实版式拼出来渲染成 PNG：
// 组件全部来自 `lib/music/widgets/mei_cards.dart` 与 `music_components.dart`，
// 尺寸/间距/字阶就是线上那一套，所以图里看到的就是 App 里的样子。
//
// 生成方式（会覆盖 test/goldens/ 下的 PNG）：
//   MUSIC_UI_PREVIEW=1 flutter test --update-goldens test/music_ui_preview_test.dart
//
// ⚠️ 默认**跳过**：golden 对比依赖字体与平台，CI 上没有
//    `C://Windows//Fonts//Deng.ttf`，渲染结果必然不同 ⇒ 会把构建打红。
//    所以只在显式设了环境变量时才跑断言。
//
// ⚠️ 封面是**占位图**：测试环境没有网络，`CoverImage` 会走它自己的
//    「无封面」兜底。版式、配色、字阶、圆角都是真的，只有图是空的。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/mei_cards.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';

/// 测试环境默认只有 Ahem 字体（所有字都渲染成方块），必须塞一份真字体进来
const _fontFamily = 'PreviewCJK';

Future<void> _loadCjkFont() async {
  // Windows 自带「等线」，是 ttf 不是 ttc（ttc 字体集合 FontLoader 吃不下）
  for (final path in const [
    r'C:\Windows\Fonts\Deng.ttf',
    r'C:\Windows\Fonts\simhei.ttf',
    r'/System/Library/Fonts/PingFang.ttc',
  ]) {
    final f = File(path);
    if (!f.existsSync()) continue;
    final bytes = await f.readAsBytes();
    final loader = FontLoader(_fontFamily)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    return;
  }
}

/// 图标同理：`Icon(Icons.xxx)` 用的是 MaterialIcons 字体，
/// 不加载的话「全部 ›」的箭头、播放量前面那个耳机全渲染成方块。
Future<void> _loadIconFont() async {
  final f = File(
    'C:/Users/24647/Flutter/bin/cache/artifacts/material_fonts/'
    'materialicons-regular.otf',
  );
  if (!f.existsSync()) return;
  final bytes = await f.readAsBytes();
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

/// 手机上的一屏：390 × 844
Widget _phone(Widget body) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: _fontFamily,
      scaffoldBackgroundColor: MusicTheme.background,
    ),
    home: Scaffold(
      backgroundColor: MusicTheme.background,
      body: MediaQuery(
        data: const MediaQueryData(size: Size(390, 844), devicePixelRatio: 2),
        child: SizedBox(width: 390, height: 844, child: body),
      ),
    ),
  );
}

/// 页面大标题（各页顶部那一块，和 MusicPageHeader 同一套字阶）
Widget _hero(String title, String sub) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            color: MusicTheme.label,
            fontSize: AppTheme.fontPageTitle,
            fontWeight: FontWeight.w700,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          sub,
          style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontSubhead),
        ),
      ],
    ),
  );
}

Widget _pills(List<String> labels, int selected) {
  return SizedBox(
    height: 48,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: labels.length,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (_, i) => MeiFilterPill(
        label: labels[i],
        selected: i == selected,
        onTap: () {},
      ),
    ),
  );
}

Widget _shelf(List<String> titles, {double width = 128, int count = 4}) {
  return SizedBox(
    height: 214,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: count,
      separatorBuilder: (_, __) => const SizedBox(width: 12),
      itemBuilder: (_, i) => MeiArtworkCard(
        coverUrl: '',
        title: titles[i % titles.length],
        subtitle: '${(i + 2) * 137} 首',
        width: width,
        badge: MeiPlayCountBadge(count: 12000 * (i + 1)),
      ),
    ),
  );
}

const _playlists = [
  '华语流行精选合集',
  '深夜一个人的歌',
  '通勤路上听什么',
  '八十年代金曲',
  '民谣与诗',
  '轻音乐助眠',
];

/// 只有显式要求时才跑（见文件头注释）
final bool _enabled = Platform.environment['MUSIC_UI_PREVIEW'] == '1';

void main() {
  setUpAll(() async {
    MusicPaletteBridge.register(() => const JellyPalette.ink());
    await _loadCjkFont();
    await _loadIconFont();
  });

  testWidgets('发现页', (tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_phone(ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _hero('发现音乐', '按语种、风格、场景挑歌单'),
        MeiSectionHeader(title: '探索歌单', onShowAll: () {}),
        const SizedBox(height: 4),
        _pills(const ['全部', '华语', '流行', '摇滚', '民谣', '电子', '说唱'], 1),
        const SizedBox(height: 8),
        _shelf(_playlists),
        const SizedBox(height: 12),
        MeiSectionHeader(title: '排行榜', onShowAll: () {}),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: const [
              MeiChartRow(
                coverUrl: '',
                name: '飙升榜',
                updateFrequency: '每天更新',
                tracks: ['起风了', '孤勇者', '晴天'],
              ),
              MeiChartRow(
                coverUrl: '',
                name: '新歌榜',
                updateFrequency: '每天更新',
                tracks: ['如果的事', '晚风心里吹', '花海'],
              ),
              MeiChartRow(
                coverUrl: '',
                name: '原创榜',
                updateFrequency: '每周更新',
                tracks: ['小城夏天', '可能', '漠河舞厅'],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        MeiSectionHeader(title: '新歌速递', onShowAll: () {}),
        const SizedBox(height: 4),
        _shelf(const ['如果的事', '晚风心里吹', '花海', '可能']),
      ],
    )));

    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/music_discover.png'),
    );
  }, skip: !_enabled);

  testWidgets('全部歌单页', (tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_phone(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _hero('华语', '共 128 个歌单'),
        _pills(const ['推荐', '最新', '最热'], 0),
        const SizedBox(height: 12),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 16,
              crossAxisSpacing: 12,
              childAspectRatio: 0.62,
            ),
            itemCount: 6,
            itemBuilder: (_, i) => MeiArtworkCard(
              coverUrl: '',
              title: _playlists[i],
              subtitle: '${(i + 3) * 89} 首 · 播放 ${(i + 1) * 12}.${i}万',
              width: 167,
              reserveSubtitleSpace: true,
            ),
          ),
        ),
      ],
    )));

    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/music_playlists.png'),
    );
  }, skip: !_enabled);
}
