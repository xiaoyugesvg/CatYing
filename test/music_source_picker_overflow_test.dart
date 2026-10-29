import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/module_theme_store.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/models/third_party_source.dart';
import 'package:tvbox/music/services/unblock_service.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/pages/music_bottom_chrome.dart';
import 'package:tvbox/music/widgets/source_picker_sheet.dart';
import 'package:tvbox/services/main_tab_controller.dart';
import 'package:tvbox/widgets/video_player_pip.dart';
import 'package:get/get.dart';

/// 回归测试：**换源弹窗（SourcePickerSheet）不能有布局溢出**。
///
/// ── 为什么（用户实测反馈）──────────────────────────────────────
/// 用户原话：「还有源切换显示的那个弹窗也是双黄线呢？」
///
/// 双黄线的颜色是 Flutter 的 `0xFFFFFF00` 叠在底色上 —— 那是
/// **`RenderFlex` 溢出标记**（框架报错原文：
/// "marked in the rendering with a yellow and black striped pattern"）。
///
/// 发现页的入口卡已经因为"写死高度 + 文字随字号放大"溢出过一次
///（见 `music_bottom_overflow_test`），这里用同样的方法把弹窗也扫一遍：
/// **多种机型 × 多档系统字号 × 多条目数**，全部不许有 overflow。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    MusicPaletteBridge.register(
        () => ModuleThemeStore.instance.paletteFor(ModuleThemeStore.music));
    await ModuleThemeStore.instance.init();
    await MusicThemeStore.instance.init();
    // 弹窗本身不依赖 MainTabController，但"底栏+弹窗同屏"那个用例要
    if (!Get.isRegistered<MainTabController>()) {
      Get.put(MainTabController(), permanent: true);
    }
  });

  Song song() => Song(
        id: 88001,
        name: '测试歌曲名字比较长一点用来占位',
        artists: '某歌手',
        source: SongSource.qq,
      );

  SourceResolveResult res(int i) => SourceResolveResult(
        ok: true,
        url: 'https://example.invalid/$i.mp3',
        kind: 'musicfree',
        source: ThirdPartySource(
          id: 'src-$i',
          name: '音源 ${i + 1} 名字也可能很长很长',
          kind: 'musicfree',
          template: '',
          quality: '320k',
          enabled: true,
        ),
      );

  /// 打开弹窗并收集溢出异常
  Future<List<Object>> openAndCollect(
    WidgetTester tester, {
    required double textScale,
    required int count,
    required Size screen,
    String failedNote = '',
  }) async {
    tester.view.physicalSize = Size(screen.width * 3, screen.height * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    late BuildContext ctx;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: MaterialApp(
          home: Builder(builder: (c) {
            ctx = c;
            return const Scaffold(body: Center(child: Text('page')));
          }),
        ),
      ),
    );
    await tester.pump();

    // 打开弹窗（不 await —— 它会挂到关闭为止）
    // ignore: unawaited_futures
    SourcePickerSheet.show(
      ctx,
      song: song(),
      results: List.generate(count, res),
      failedNote: failedNote,
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 60));

    final errs = <Object>[];
    for (var ex = tester.takeException(); ex != null;
        ex = tester.takeException()) {
      errs.add(ex);
    }
    return errs;
  }

  testWidgets('🔴 换源弹窗：多字号 × 多条目数 × 多机型都不许溢出', (tester) async {
    const screens = <String, Size>{
      'SE1 320×568': Size(320, 568),
      '14 390×844': Size(390, 844),
      '用户机 428×926': Size(428, 926),
    };
    final scales = <double>[1.0, 1.3, 1.5, 2.0];
    final counts = <int>[1, 2, 5, 12];

    final failures = <String>[];
    var combos = 0;

    for (final sc in screens.entries) {
      for (final ts in scales) {
        for (final n in counts) {
          combos++;
          final errs = await openAndCollect(
            tester,
            textScale: ts,
            count: n,
            screen: sc.value,
          );
          for (final e in errs) {
            final s = e.toString();
            if (s.contains('overflow')) {
              failures.add('${sc.key} 字号x$ts $n条: '
                  '${s.split('\n').first}');
            }
          }
        }
      }
    }
    // ignore: avoid_print
    print('[probe] 共测 $combos 种组合，溢出 ${failures.length} 处');

    expect(failures, isEmpty,
        reason: '换源弹窗在下列组合下**溢出了**（这就是用户看到的双黄线）:\n'
            '${failures.join('\n')}');
  });

  testWidgets('🔴 带「失败摘要」时也不能溢出（那段文字最长）', (tester) async {
    final failures = <String>[];
    for (final ts in <double>[1.0, 1.5, 2.0]) {
      final errs = await openAndCollect(
        tester,
        textScale: ts,
        count: 12,
        screen: const Size(320, 568),
        // 最长的失败摘要（3 行 maxLines）
        failedNote: '另有 12 个音源试过但没拿到地址（详情见日志）'
            '；内置接口没有免费音源；car_conv2: GD接口失败: ClientException…',
      );
      for (final e in errs) {
        final s = e.toString();
        if (s.contains('overflow')) {
          failures.add('字号x$ts: ${s.split('\n').first}');
        }
      }
    }
    // ignore: avoid_print
    print('[probe] 失败摘要场景：溢出 ${failures.length} 处');
    expect(failures, isEmpty,
        reason: '带失败摘要时弹窗溢出了:\n${failures.join('\n')}');
  });

  testWidgets('弹窗叠在全局底栏之上时也不能溢出（真机场景）', (tester) async {
    // 真机上换源弹窗不是开在空白页上的 —— 它开在音乐模块里，
    // 底部还压着全局 MusicBottomChrome（迷你条 + 导航栏）。
    final failures = <String>[];
    for (final ts in <double>[1.0, 1.3, 1.5, 2.0]) {
      for (final n in <int>[1, 6, 12]) {
        tester.view.physicalSize = const Size(320 * 3, 568 * 3);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);

        late BuildContext ctx;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(ts)),
            child: MaterialApp(
              navigatorKey: VideoPlayerPip.navigatorKey,
              home: Scaffold(
                body: Stack(children: [
                  Builder(builder: (c) {
                    ctx = c;
                    return const SizedBox.expand();
                  }),
                  const Positioned(
                      left: 0, right: 0, bottom: 0, child: MusicBottomChrome()),
                ]),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 60));

        // ignore: unawaited_futures
        SourcePickerSheet.show(
          ctx,
          song: song(),
          results: List.generate(n, res),
          failedNote: '另有 $n 个音源试过但没拿到地址（详情见日志）',
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 80));

        final errs = <Object>[];
        for (var ex = tester.takeException(); ex != null;
            ex = tester.takeException()) {
          errs.add(ex);
        }
        for (final e in errs) {
          final s = e.toString();
          if (s.contains('overflow')) {
            failures.add('字号x$ts $n条: ${s.split('\n').first}');
          }
        }
      }
    }
    // ignore: avoid_print
    print('[probe] 底栏+弹窗同屏: 溢出 ${failures.length} 处');
    expect(failures, isEmpty, reason: '弹窗与全局底栏同屏时溢出了');
  });
}
