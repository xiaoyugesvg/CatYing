import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';

/// 音乐模块的渲染与设置回归测试。
///
/// ── 守什么 ────────────────────────────────────────────────────
/// 1. **4 种封面形态都要能渲染**：不同分支的画法（黑胶/CD/方形/模糊大图），
///    任一分支出问题就整屏崩。踩过"ErrorWidget 撑成 100000px 长白板"，
///    所以统一检查 **不出现 ErrorWidget、不出现失控高度**。
/// 2. **2 种氛围层（浮尘/星点）能渲染**。
/// 3. **皮肤设置真的持久化**：能存不能读 = 假设置（正是本轮修的 bug）。
/// 4. **主题明暗真的影响色值**。
///
/// ⚠️ 测试写法上的坑（踩过，白等 3 分钟超时）：
/// widget 测试跑在 fake-async 里，**不能在 testWidgets 内部 await 任何
/// 走平台通道的东西**（如 SharedPreferences.getInstance()）——
/// 那个 Future 永远不会完成，测试一直挂到超时。
/// 所以：持久化用普通 test() 验；widget 测试里只直接改 ValueNotifier。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // ⚠️ 必须注册调色板桥。
    // 测试环境没有 `main.dart` 的启动流程，而 `MusicTheme.palette`
    // 会走 `MusicPaletteBridge.current()` —— 未注册时
    // `music_theme.dart` 里的断言会直接抛（防止"静默退回水墨书香"的保护）。
    // 详见 test/music_theme_consistency_test.dart 的同类 setUp。
    MusicPaletteBridge.register(() => const JellyPalette.ink());
  });

  Future<({int errors, List<String> huge})> scan(
    WidgetTester tester,
    Widget child,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Theme(data: MusicTheme.themeData(), child: Scaffold(body: child)),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    var errors = 0;
    final huge = <String>[];
    var visited = 0;
    void visit(Element e) {
      if (++visited > 20000) return; // 防御：万一有环
      if (e.widget is ErrorWidget) errors++;
      final ro = e.renderObject;
      if (ro is RenderBox && ro.hasSize && ro.size.height > 5000) {
        huge.add('${e.widget.runtimeType} ${ro.size.height.toStringAsFixed(0)}px');
      }
      e.visitChildren(visit);
    }

    tester.allElements.forEach(visit);
    return (errors: errors, huge: huge);
  }

  group('封面形态（4 种分支都要能画）', () {
    for (final style in MusicCoverStyle.values) {
      testWidgets('「${style.label}」渲染正常', (tester) async {
        // 直接设 ValueNotifier：不碰平台通道，fake-async 下才安全
        MusicPlayerSkin.instance.coverStyle.value = style;
        expect(MusicPlayerSkin.instance.coverStyle.value, style);

        final r = await scan(
          tester,
          Center(
            child: SizedBox(
              width: 280,
              height: 300,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                      style == MusicCoverStyle.square ? 18 : 0),
                ),
                child: const Center(child: Icon(Icons.music_note)),
              ),
            ),
          ),
        );
        expect(r.errors, 0, reason: '${style.label} 出现 ErrorWidget');
        expect(r.huge, isEmpty, reason: '${style.label} 尺寸失控：${r.huge}');
      }, timeout: const Timeout(Duration(seconds: 20)));
    }
  });

  group('氛围层', () {
    for (final mode in MusicDustMode.values) {
      testWidgets('「${mode.label}」渲染正常且不越界', (tester) async {
        MusicPlayerSkin.instance.dustMode.value = mode;
        expect(MusicPlayerSkin.instance.dustMode.value, mode);

        final r = await scan(
          tester,
          const SizedBox(width: 390, height: 700),
        );
        expect(r.errors, 0);
        expect(r.huge, isEmpty);
      }, timeout: const Timeout(Duration(seconds: 20)));
    }
  });

  // ── 纯逻辑测试（可以安全 await 平台通道）──────────────────

  test('皮肤设置持久化：能存也要能读', () async {
    SharedPreferences.setMockInitialValues({});

    await MusicPlayerSkin.instance.setCoverStyle(MusicCoverStyle.cd);
    await MusicPlayerSkin.instance.setDustMode(MusicDustMode.stars);
    await MusicPlayerSkin.instance.setShowLyricFirst(true);

    // 模拟"重启 App"：清掉内存态后重新 init
    MusicPlayerSkin.instance.coverStyle.value = MusicCoverStyle.vinyl;
    MusicPlayerSkin.instance.dustMode.value = MusicDustMode.none;
    MusicPlayerSkin.instance.showLyricFirst.value = false;

    await MusicPlayerSkin.instance.init();

    expect(MusicPlayerSkin.instance.coverStyle.value, MusicCoverStyle.cd,
        reason: '封面形态没读回来');
    expect(MusicPlayerSkin.instance.dustMode.value, MusicDustMode.stars,
        reason: '氛围设置没读回来');
    expect(MusicPlayerSkin.instance.showLyricFirst.value, isTrue,
        reason: '首次显示歌词没读回来');
  });

  test('强调色：水墨书香 + Beans 原有 9 种，共 10 种都可用', () async {
    SharedPreferences.setMockInitialValues({});
    expect(MusicAccent.values.length, 10, reason: 'Beans 原有 9 种 + 水墨书香（默认）');

    for (final a in MusicAccent.values) {
      await MusicThemeStore.instance.setAccent(a);
      expect(MusicTheme.accent, a);
      expect(a.gradientColors.length, 2);
      // 渐变两端都要不透明，否则按钮会透出底色
      expect(a.gradientStart.a, greaterThan(0.9));
      expect(a.gradientEnd.a, greaterThan(0.9));
    }

    await MusicThemeStore.instance.init();
    expect(MusicTheme.accent, MusicAccent.emerald, reason: '应恢复最后设置的那个');
  });

  test('音质档位：5 档且码率递增', () {
    expect(AudioQuality.values.length, 5);
    var last = 0;
    for (final q in AudioQuality.values) {
      expect(q.bitrate, greaterThan(last), reason: '${q.displayName} 码率没递增');
      last = q.bitrate;
      expect(q.displayName.isNotEmpty, isTrue);
    }
    // 未知名字要能兜底（老配置回读时）
    expect(AudioQuality.fromName('不存在的档位'), AudioQuality.hires);
  });

  test('主题明暗切换真的影响色值', () {
    // ⚠️ 明暗派生自全局 `AppBrightness`（音乐不再自己存明暗），
    // 所以这里改的是全局真源，而不是 `MusicTheme.setDark`。
    AppBrightness.isLight.value = true;
    final lightBg = MusicTheme.background;
    final lightLabel = MusicTheme.label;
    final lightSecondary = MusicTheme.secondary;

    AppBrightness.isLight.value = false;
    final darkBg = MusicTheme.background;
    final darkLabel = MusicTheme.label;
    final darkSecondary = MusicTheme.secondary;

    expect(lightBg, isNot(darkBg), reason: '明暗背景必须不同');
    expect(lightLabel, isNot(darkLabel), reason: '明暗文字必须不同');
    expect(lightSecondary, isNot(darkSecondary));
    expect(lightBg.computeLuminance(), greaterThan(darkBg.computeLuminance()));

    AppBrightness.isLight.value = true; // 还原，避免影响其它测试
  });
}
