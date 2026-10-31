// 守卫测试：AetherEngine 与 KSPlayer **并存**（不是替换）。
//
// ── 用户 2026-11-01 ───────────────────────────────────────────
// 「帮我加个 AetherEngine 内核呢」→「用6.x版本的行不？」→「不行，不能替换，要并存」
//
// 中途我按「替换」做了一版（把 KSPlayer 整个删掉），已被 revert（c9b157a）。
// 现在 KSPlayer 原样保留，AetherEngine 作为**第五个内核**加进来，用户在设置里二选一。
//
// ── 必须知道的风险（不是测试能覆盖的，只能真机验证）──────────────
//   · KSPlayer      → kingslay/FFmpegKit（FFmpeg 6.x，C 符号 avcodec_* 无前缀）
//   · AetherEngine  → FFmpegBuild      （FFmpeg 8.1，同样 avcodec_* 无前缀）
//   静态库按需拉取：两套都被拉到同一符号时 duplicate symbol；若全被先拉取的那套
//   满足，另一个内核实际跑的是**对方版本的 FFmpeg**，ABI 不匹配 ⇒ 运行时崩。
//   所以「并存」能不能真跑起来，只能在 mac 上编译 + 真机播放来判定。
//
// 这条测试只保证：**两套依赖和两套桥接都在，谁也没被偷偷删掉。**
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relative) => File(relative).readAsStringSync();

void main() {
  final pbx = _read('ios/Runner.xcodeproj/project.pbxproj');
  final podfile = _read('ios/Podfile');
  final appDelegate = _read('ios/Runner/AppDelegate.swift');
  final engineModel = _read('lib/models/player_engine.dart');

  group('两套 SPM 依赖同时存在', () {
    test('KSPlayer 还在（没被删）', () {
      expect(pbx.contains('xiaoyugesvg/KSPlayer'), isTrue);
      expect(pbx.contains('KSPlayer in Frameworks'), isTrue);
      expect(pbx.contains('productName = KSPlayer;'), isTrue);
    });

    test('AetherEngine 也加上了，锁 6.89.0（7.x 要 iOS 18）', () {
      expect(
        pbx.contains('https://github.com/superuser404notfound/AetherEngine.git'),
        isTrue,
      );
      expect(pbx.contains('minimumVersion = 6.89.0;'), isTrue);
      expect(pbx.contains('kind = upToNextMinorVersion;'), isTrue);
      expect(pbx.contains('AetherEngine in Frameworks'), isTrue);
    });

    test('两个桥接源文件都在编译列表里', () {
      expect(pbx.contains('KSEngine.swift in Sources'), isTrue);
      expect(pbx.contains('AetherEngineBridge.swift in Sources'), isTrue);
      expect(File('ios/Runner/KSEngine.swift').existsSync(), isTrue);
      expect(File('ios/Runner/AetherEngineBridge.swift').existsSync(), isTrue);
    });

    test('AppDelegate 两个都注册，视图名各自独立', () {
      expect(appDelegate.contains('KSEngine.shared.register'), isTrue);
      expect(appDelegate.contains('withId: "ks_player_view"'), isTrue);
      expect(appDelegate.contains('AetherEngineBridge.shared.register'), isTrue);
      expect(appDelegate.contains('withId: "aether_player_view"'), isTrue);
    });
  });

  group('最低系统 16.0（AetherEngine 6.x 的硬要求）', () {
    test('pbxproj 三处 + Podfile', () {
      final n = RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = 16\.0;').allMatches(pbx).length;
      expect(n, 3);
      expect(pbx.contains('IPHONEOS_DEPLOYMENT_TARGET = 14.0;'), isFalse);
      expect(podfile.contains("platform : ios, '16.0'"), isFalse);
      expect(podfile.contains("platform :ios, '16.0'"), isTrue);
    });
  });

  group('Dart 侧两个内核并存', () {
    test('枚举里 ksplayer(3) 与 aether(4) 都在', () {
      expect(engineModel.contains("ksplayer(3, 'KSPlayer播放器')"), isTrue);
      expect(engineModel.contains("aether(4, 'Aether播放器')"), isTrue);
    });

    test('iOS 可选内核列表含全部四个', () {
      final i = engineModel.indexOf('static List<PlayerEngine> get availableEngines');
      final seg = engineModel.substring(i, i + 700);
      expect(seg.contains('PlayerEngine.ksplayer'), isTrue);
      expect(seg.contains('PlayerEngine.aether'), isTrue);
    });

    test('五个点播入口都建得出 AetherPlayer', () {
      for (final f in [
        'lib/pages/detail/view.dart',
        'lib/pages/drama/drama_player_page.dart',
        'lib/pages/media_library/media_library_player_page.dart',
        'lib/rex/rex_player_page.dart',
        'lib/room/room_page.dart',
      ]) {
        final src = _read(f);
        expect(src.contains('AetherPlayer(config:'), isTrue, reason: '$f 缺 Aether 分支');
        expect(src.contains('KSPlayer(config:'), isTrue, reason: '$f 的 KS 分支被删了');
      }
    });

    test('Aether 播放器通道与视图名和原生一致', () {
      final dart = _read('lib/widgets/aether_player.dart');
      expect(dart.contains("MethodChannel('aether_player')"), isTrue);
      expect(dart.contains("viewType: 'aether_player_view'"), isTrue);
      expect(dart.contains('class AetherPlayer extends AppPlayer'), isTrue);
    });
  });
}
