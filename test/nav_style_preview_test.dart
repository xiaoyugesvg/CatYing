// 底栏六种风格的出图预览（2026-10-31）
//
// ── 为什么要这个文件 ────────────────────────────────────────────
// 用户看完成品后说：「你在 github 里面找找它们风格相关的代码呢，
// 你看看你写的什么玩意」——六种风格是照印象画的，不是照真实实现。
//
// 光改代码不够：**"看着假"这件事只有出图才能判断**。
// 所以这里把**真实的** `JellyNavBar` 按真实版式拼出来渲染成 PNG，
// 不是设计稿、不是示意图，组件和取色就是线上那一套。
//
// ── 背景为什么要画彩条 ─────────────────────────────────────────
// 玻璃类风格（macOS / iOS / 云母）的质感全靠"背景被模糊后透上来"。
// 纯色背景上 BackdropFilter 模糊前后**一模一样**，什么也看不出来。
// 所以底衬放五条高饱和大色块：模糊有没有生效、顶部高光有没有画、
// 描边粗细、指示器光晕，一眼就能看出来。
//
// ── 生成方式（会写 outputs/nav_styles/ 下的 PNG）────────────────
//   NAV_STYLE_PREVIEW=1 "C:/Users/24647/Flutter/bin/flutter" test \
//       test/nav_style_preview_test.dart
//
// ⚠️ 默认**跳过**：图里依赖 `C:\Windows\Fonts\Deng.ttf` 与
//    MaterialIcons 字体，CI（ubuntu）上没有，必然出成方块。
//    所以只在显式设了环境变量时才跑。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/floating_nav_spec.dart';
import 'package:tvbox/reading/services/settings_service.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';
import 'package:tvbox/reading/widgets/jelly_nav_bar.dart';

/// 测试环境默认只有 Ahem 字体（所有字渲染成方块），必须塞一份真字体
const _fontFamily = 'PreviewCJK';

Future<void> _loadCjkFont() async {
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

/// 图标同理：`Icon(Icons.xxx)` 用 MaterialIcons 字体，不加载全是方块
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

/// 每个小格的尺寸：只截底栏那一段，不画整屏（否则六种风格要滚很久）
const double _cellW = 390;
const double _cellH = 220;

/// 拍摄目标
final GlobalKey _shotKey = GlobalKey();

/// 五条栏目（和阅读/影视底栏的真实项数与内容一致）
const List<JellyNavItem> _items = <JellyNavItem>[
  JellyNavItem(icon: Icons.live_tv_rounded, label: '影视'),
  JellyNavItem(icon: Icons.music_note_rounded, label: '音乐'),
  JellyNavItem(icon: Icons.menu_book_rounded, label: '阅读'),
  JellyNavItem(icon: Icons.collections_bookmark_rounded, label: '书架'),
  JellyNavItem(icon: Icons.person_rounded, label: '我的'),
];

/// 底衬：渐变壁纸 + 五条高饱和大色块。
///
/// 色块必须**压在底栏后面**——底栏是半透明的，色块被模糊后的样子
/// 才是"玻璃感"的全部来源。色块放上面就什么也照不出来了。
Widget _backdrop(bool dark) {
  return Stack(
    fit: StackFit.expand,
    children: [
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: dark
                ? const [
                    Color(0xFF101A33),
                    Color(0xFF3B1E52),
                    Color(0xFF0B2E2A),
                  ]
                : const [
                    Color(0xFFD7E6FF),
                    Color(0xFFFFDDC9),
                    Color(0xFFC4F2DC),
                  ],
          ),
        ),
      ),
      const Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: 150,
        child: Column(
          // ⚠️ 必须 stretch：Column 交叉轴默认 center，给子节点的宽度约束是
          // 0..maxWidth，而无子节点的 ColoredBox 会取 smallest = 0 宽 ⇒
          // 五条彩条全都画成 0 宽，底栏背后一片空白，玻璃/模糊什么都照不出来。
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: ColoredBox(color: Color(0xFFE8467C))),
            Expanded(child: ColoredBox(color: Color(0xFF2AC7A8))),
            Expanded(child: ColoredBox(color: Color(0xFFF2C94C))),
            Expanded(child: ColoredBox(color: Color(0xFF5B6BF0))),
            Expanded(child: ColoredBox(color: Color(0xFF23A6F0))),
          ],
        ),
      ),
    ],
  );
}

/// 一小格 = 一块壁纸 + 一条**真实**的悬浮底栏
Widget _cell(
  FloatingNavStyle style, {
  required bool dark,
  required JellyPalette palette,
}) {
  return SizedBox(
    width: _cellW,
    height: _cellH,
    child: MediaQuery(
      data: const MediaQueryData(
        size: Size(_cellW, _cellH),
        devicePixelRatio: 2,
      ),
      child: Theme(
        data: ThemeData(
          useMaterial3: true,
          fontFamily: _fontFamily,
          brightness: dark ? Brightness.dark : Brightness.light,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(child: _backdrop(dark)),
              Positioned(
                left: 10,
                top: 8,
                child: Text(
                  '${style.label} · ${dark ? '深色' : '浅色'}',
                  style: TextStyle(
                    fontFamily: _fontFamily,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: dark ? Colors.white : const Color(0xFF14161A),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: JellyNavBar(
                  floating: true,
                  // 选中第 3 项（阅读）：指示器在中间，两侧都有"未选中"对照
                  currentIndex: 2,
                  onTap: (_) {},
                  items: _items,
                  palette: palette,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 一行 = 深色 + 浅色并排（同一风格的两套明暗放一起才比得出来）
Widget _row(FloatingNavStyle style, JellyPalette palette) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: RepaintBoundary(
      key: _shotKey,
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _cell(style, dark: true, palette: palette),
            const SizedBox(
              width: 2,
              height: _cellH,
              child: ColoredBox(color: Color(0xFF000000)),
            ),
            _cell(style, dark: false, palette: palette),
          ],
        ),
      ),
    ),
  );
}

/// 出图用的两套配色。
///
/// ── 为什么要两套（2026-10-31 实测发现）────────────────────────
/// 默认配色是「水墨」，它的 `primary` 是 `0xFF3A3A3A`（近黑灰）。
/// 而鸿蒙/澎湃/云母这三种风格的差异**几乎全靠主题色** ⇒
/// 用灰配色出图时，三者在深浅两套明暗下都会退化成"同一个灰胶囊"，
/// 看上去像没做。换成彩色配色（`jelly` 靛蓝）才看得出设计意图。
///
/// 两张图都要出：一张是**用户实际看到的默认观感**，一张是设计意图。
const Map<String, JellyPalette> _palettes = <String, JellyPalette>{
  'ink': JellyPalette.ink(),
  'jelly': JellyPalette.jelly(),
};

void main() {
  final bool enabled = Platform.environment['NAV_STYLE_PREVIEW'] == '1';

  setUpAll(() async {
    if (!enabled) return;
    await _loadCjkFont();
    await _loadIconFont();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('导出六种底栏风格预览图', (tester) async {
    tester.view.physicalSize = const Size(_cellW * 2 + 2, _cellH) * 2;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    // 背景动画默认是开的，而它是**直接关掉 BackdropFilter** 的
    // （见 jelly_nav_bar.dart 的 `useBlur = !bgAnim && ...`）。
    // 出图要看玻璃质感 ⇒ 必须关掉背景动画，否则模糊层根本不画。
    await SettingsService().setBackgroundAnimation(false);

    for (final entry in _palettes.entries) {
      final palette = entry.value;
      final rows = <ui.Image>[];
      for (final style in FloatingNavStyle.values) {
        await SettingsService().setNavStyle(style.id);
        await tester.pumpWidget(_row(style, palette));
        // 等果冻指示器落位（ElasticOutCurve 的余震在 600ms 内结束）
        await tester.pump(const Duration(milliseconds: 600));

        final boundary =
            tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
        final img = await tester.runAsync(() => boundary.toImage(pixelRatio: 2));
        expect(img, isNotNull, reason: '${entry.key}/${style.id} 拍不出图');
        rows.add(img!);
      }

      // 六行竖着拼成一张对比图
      final rowPx = rows.first.width;
      final rowPxH = rows.first.height;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (var i = 0; i < rows.length; i++) {
        canvas.drawImage(rows[i], Offset(0, (i * rowPxH).toDouble()), Paint());
      }
      final composed = await tester.runAsync(
        () => recorder.endRecording().toImage(rowPx, rowPxH * rows.length),
      );
      expect(composed, isNotNull);

      final bytes = await tester.runAsync(
        () => composed!.toByteData(format: ui.ImageByteFormat.png),
      );
      expect(bytes, isNotNull);

      final out = File('outputs/nav_styles/nav_style_preview_${entry.key}.png');
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(bytes!.buffer.asUint8List());

      // 顺手把六张单风格图也落盘，方便单独放大看
      for (var i = 0; i < rows.length; i++) {
        final b = await tester.runAsync(
          () => rows[i].toByteData(format: ui.ImageByteFormat.png),
        );
        if (b == null) continue;
        File('outputs/nav_styles/${entry.key}_'
                '${FloatingNavStyle.values[i].id}.png')
            .writeAsBytesSync(b.buffer.asUint8List());
      }
    }
  }, skip: !enabled);
}
