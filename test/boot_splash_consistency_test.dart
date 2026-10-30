import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/common/theme_mode_store.dart';
import 'package:tvbox/widgets/app_splash_backdrop.dart';
import 'package:tvbox/widgets/circular_logo_progress.dart';

/// 启动首帧与加载页必须**画同一个画面**。
///
/// 背景（两次踩坑的现场记录）：
///   ① 首帧画金色 logo、加载页画墨灰 logo ⇒ 用户「为啥有两个这种」；
///   ② 干脆把首帧的 logo 删掉、只留写死的深色底 ⇒ 用户「一打开就是黑屏，
///      然后才出加载页」。
///
/// 所以这里锁死两条不变量：
///   · 两处背景只能来自 `AppSplashBackdrop`（不许各写一份渐变）；
///   · 首帧不许再出现写死的底色（`0xFF1C1C1E` / `0xFFF7F5F1`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String read(String relative) => File(relative).readAsStringSync();

  group('首帧明暗预读（ThemeModeStore.preloadSync）', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tvbox_appearance_');
      ThemeModeStore.debugAppearancePathOverride = '${tmp.path}/appearance.txt';
    });

    tearDown(() {
      ThemeModeStore.debugAppearancePathOverride = null;
      // 复原全局状态，避免污染同文件后续用例
      ThemeModeStore.notifier.value = ThemeMode.system;
      AppBrightness.isLight.value = false;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('mode → 文本 → mode 往返不丢信息', () {
      for (final m in ThemeMode.values) {
        expect(ThemeModeStore.textToMode(ThemeModeStore.modeToText(m)), m);
      }
      // 未知/脏内容一律回「跟随系统」，不能猜成深色
      expect(ThemeModeStore.textToMode('  LIGHT '), ThemeMode.light);
      expect(ThemeModeStore.textToMode('whatever'), ThemeMode.system);
      expect(ThemeModeStore.textToMode(''), ThemeMode.system);
    });

    test('文件里是 light → 首帧就是浅色（这是"黑屏"的根因修复）', () {
      File(ThemeModeStore.debugAppearancePathOverride!)
          .writeAsStringSync('light');

      ThemeModeStore.preloadSync();

      expect(ThemeModeStore.mode, ThemeMode.light);
      expect(AppBrightness.isLight.value, isTrue);
    });

    test('文件里是 dark → 首帧就是深色', () {
      File(ThemeModeStore.debugAppearancePathOverride!)
          .writeAsStringSync('dark');

      ThemeModeStore.preloadSync();

      expect(ThemeModeStore.mode, ThemeMode.dark);
      expect(AppBrightness.isLight.value, isFalse);
    });

    test('文件缺失（首次安装）→ 跟随系统，不抛异常', () {
      expect(File(ThemeModeStore.debugAppearancePathOverride!).existsSync(),
          isFalse);

      expect(ThemeModeStore.preloadSync, returnsNormally);
      expect(ThemeModeStore.mode, ThemeMode.system);
    });

    test('文件内容损坏 → 跟随系统，不抛异常', () {
      File(ThemeModeStore.debugAppearancePathOverride!)
          .writeAsStringSync('{"broken":');

      expect(ThemeModeStore.preloadSync, returnsNormally);
      expect(ThemeModeStore.mode, ThemeMode.system);
    });
  });

  group('AppSplashBackdrop（启动期背景的唯一实现）', () {
    testWidgets('铺满全屏 + 用 AppTheme 的径向渐变', (tester) async {
      AppBrightness.isLight.value = true;
      addTearDown(() => AppBrightness.isLight.value = false);

      await tester.pumpWidget(const MaterialApp(
        home: AppSplashBackdrop(child: SizedBox.expand()),
      ));

      final size = tester.getSize(find.byType(AppSplashBackdrop));
      expect(size.width, greaterThan(0));
      expect(size.height, greaterThan(0));

      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(AppSplashBackdrop),
          matching: find.byType(DecoratedBox),
        ).first,
      );
      final gradient = (box.decoration as BoxDecoration).gradient;
      expect(gradient, isA<RadialGradient>());
      // 最后一档必须是不透明的页面底色，否则渐变中心会透出窗口黑底
      expect((gradient as RadialGradient).colors.last, AppTheme.backgroundPrimary);
      expect((box.decoration as BoxDecoration).color, isNull);
    });

    testWidgets('内层有不透明兜底底色（backgroundTertiary 是半透明的）',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: AppSplashBackdrop(child: SizedBox.expand()),
      ));

      final coloredBox = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byType(AppSplashBackdrop),
          matching: find.byType(ColoredBox),
        ).first,
      );
      expect(coloredBox.color, AppTheme.backgroundPrimary);
      expect(coloredBox.color.a, 1.0);
    });
  });

  group('首帧画面 = 加载页画面（源码级不变量）', () {
    final mainSrc = read('lib/main.dart');
    final loadingSrc = read('lib/widgets/app_loading_view.dart');

    test('main() 在 runApp 之前就同步预读了明暗', () {
      final preloadAt = mainSrc.indexOf('ThemeModeStore.preloadSync()');
      final runAppAt = mainSrc.indexOf('runApp(_BootGate');
      expect(preloadAt, greaterThan(0), reason: '必须调用 preloadSync()');
      expect(runAppAt, greaterThan(0));
      expect(preloadAt, lessThan(runAppAt),
          reason: '预读必须早于 runApp，否则首帧还是按深色画');
    });

    test('_BootSplash 用同一套背景 + logo 组件', () {
      final bootAt = mainSrc.indexOf('class _BootSplash');
      expect(bootAt, greaterThan(0));
      final bootSrc = mainSrc.substring(bootAt);
      expect(bootSrc, contains('AppSplashBackdrop'));
      expect(bootSrc, contains('CircularLogoProgress'));
    });

    test('_BootSplash 不再写死底色（黑屏的直接原因）', () {
      final bootSrc = mainSrc.substring(mainSrc.indexOf('class _BootSplash'));
      // 0xFF1C1C1E 深色底 / 0xFFF7F5F1 浅色底 —— 一旦重新出现，就又是
      // "首帧一块纯色、加载页一片渐变"的老毛病。
      expect(bootSrc, isNot(contains('0xFF1C1C1E')));
      expect(bootSrc, isNot(contains('0xFFF7F5F1')));
      expect(bootSrc, isNot(contains('ColoredBox')));
    });

    test('加载页背景也走 AppSplashBackdrop，不许自己再写渐变', () {
      expect(loadingSrc, contains('AppSplashBackdrop'));
      expect(loadingSrc, isNot(contains('RadialGradient')),
          reason: '两处各写一份渐变迟早会改漏一处，必须同源');
    });

    test('_BootSplash 跟着调色板/明暗/字号变化重画', () {
      final bootSrc = mainSrc.substring(mainSrc.indexOf('class _BootSplash'));
      expect(bootSrc, contains('AppTheme.paletteRevision'));
      expect(bootSrc, contains('AppBrightness.isLight'));
      expect(bootSrc, contains('AppTheme.fontScale'));
    });
  });

  group('CircularLogoProgress（首帧唯一 logo）', () {
    testWidgets('不确定态也能画出来，且只出现一次「猫影」', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: AppSplashBackdrop(
          child: Center(
            child: CircularLogoProgress(
              progress: null,
              percentText: '',
              caption: '',
              indeterminate: true,
            ),
          ),
        ),
      ));

      expect(find.text('猫影'), findsOneWidget);
      expect(find.byIcon(Icons.pets), findsOneWidget);
      // 无文案时不该凭空多出一个 caption 占位
      expect(find.byType(Text), findsOneWidget);
    });
  });
}
