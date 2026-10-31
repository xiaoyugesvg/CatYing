// 守卫测试：KSPlayer（FF 核心）→ AetherEngine 的迁移。
//
// ── 用户 2026-11-01 ───────────────────────────────────────────
// 「帮我加个 AetherEngine 内核呢」→「用 6.x 版本的行不？」→「全量」。
//
// ── 为什么必须"换"而不是"加" ──────────────────────────────────
//   · KSPlayer      → kingslay/FFmpegKit （一整套 FFmpeg 二进制包）
//   · AetherEngine  → FFmpegBuild        （另一整套 FFmpeg 二进制包）
// 两个静态库都导出 `avcodec_* / avformat_* / avutil_* / swresample_*`，
// 同时链接必然 duplicate symbol。所以只能二选一。
//
// ── 为什么是 6.x ─────────────────────────────────────────────
//   AetherEngine 7.0.0 起 `platforms: [.iOS(.v18)]`；
//   6.x（最后一个 6.89.0，2026-09-15）是 `.iOS(.v16)`。
// 本项目因此把最低系统从 14.0 提到 16.0。
//
// 这条测试盯着四件事别再被改回去：
//   ① SPM 依赖是 AetherEngine 6.89.0（upToNextMinor，绝不能自动升到 7.x）
//   ② 工程里不再有 KSPlayer / FFmpegKit
//   ③ 最低系统三处都是 16.0（pbxproj）+ Podfile 16.0
//   ④ Dart 与原生两侧的通道名 / 视图名对齐
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relative) => File(relative).readAsStringSync();

void main() {
  final pbx = _read('ios/Runner.xcodeproj/project.pbxproj');
  final podfile = _read('ios/Podfile');
  final appDelegate = _read('ios/Runner/AppDelegate.swift');
  final bridge = _read('ios/Runner/AetherEngineBridge.swift');
  final dartPlayer = _read('lib/widgets/aether_player.dart');
  final engineModel = _read('lib/models/player_engine.dart');
  final pip = _read('lib/widgets/video_player_pip.dart');

  group('SPM 依赖换成 AetherEngine 6.x', () {
    test('仓库地址是 AetherEngine', () {
      expect(
        pbx.contains('https://github.com/superuser404notfound/AetherEngine.git'),
        isTrue,
      );
    });

    test('锁在 6.89.0 且只允许 patch 升级（7.x 要 iOS 18，绝不能飘上去）', () {
      expect(pbx.contains('kind = upToNextMinorVersion;'), isTrue);
      expect(pbx.contains('minimumVersion = 6.89.0;'), isTrue);
    });

    test('KSPlayer / FFmpegKit 彻底消失', () {
      expect(pbx.contains('KSPlayer'), isFalse);
      expect(pbx.contains('FFmpegKit'), isFalse);
    });

    test('产品依赖名是 AetherEngine', () {
      expect(pbx.contains('productName = AetherEngine;'), isTrue);
      expect(pbx.contains('AetherEngine in Frameworks'), isTrue);
    });
  });

  group('最低系统提到 iOS 16', () {
    test('pbxproj 三处构建配置都是 16.0', () {
      final n = RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = 16\.0;').allMatches(pbx).length;
      expect(n, 3, reason: 'Debug / Release / Profile 三个配置都要改');
      expect(pbx.contains('IPHONEOS_DEPLOYMENT_TARGET = 14.0;'), isFalse);
    });

    test('Podfile 平台也是 16.0', () {
      expect(podfile.contains("platform :ios, '16.0'"), isTrue);
    });
  });

  group('原生桥接', () {
    test('新文件在编译列表里，旧 KSEngine.swift 不在', () {
      expect(pbx.contains('AetherEngineBridge.swift in Sources'), isTrue);
      expect(pbx.contains('KSEngine.swift'), isFalse);
      expect(File('ios/Runner/AetherEngineBridge.swift').existsSync(), isTrue);
      expect(File('ios/Runner/KSEngine.swift').existsSync(), isFalse);
    });

    test('AppDelegate 注册桥接与平台视图', () {
      expect(appDelegate.contains('AetherEngineBridge.shared.register'), isTrue);
      expect(appDelegate.contains('AetherPlayerViewFactory'), isTrue);
      expect(appDelegate.contains('withId: "aether_player_view"'), isTrue);
      expect(appDelegate.contains('KSEngine'), isFalse);
    });

    test('通道协议与旧 ks_player 逐方法对齐（Dart 侧不用改协议）', () {
      for (final m in [
        '"open"',
        '"play"',
        '"pause"',
        '"seek"',
        '"setRate"',
        '"setVolume"',
        '"setMuted"',
        '"getState"',
        '"getSubtitleTracks"',
        '"selectSubtitleTrack"',
        '"enterPip"',
        '"exitPip"',
        '"close"',
      ]) {
        expect(bridge.contains('case $m'), isTrue, reason: '缺少方法 $m');
      }
      for (final e in [
        '"onPlaying"',
        '"onPosition"',
        '"onDuration"',
        '"onReady"',
        '"onBuffering"',
        '"onCompleted"',
        '"onError"',
      ]) {
        expect(bridge.contains(e), isTrue, reason: '缺少事件 $e');
      }
    });

    test('小窗事件仍走 pip_manager（与 AVPlayer 路径共用状态机）', () {
      expect(bridge.contains('FlutterMethodChannel(name: "pip_manager"'), isTrue);
      expect(bridge.contains('onPipStarted'), isTrue);
      expect(bridge.contains('onPipStopped'), isTrue);
    });
  });

  group('Dart 侧', () {
    test('播放器通道与视图名对齐原生', () {
      expect(dartPlayer.contains("MethodChannel('aether_player')"), isTrue);
      expect(dartPlayer.contains("viewType: 'aether_player_view'"), isTrue);
      expect(dartPlayer.contains('class AetherPlayer extends AppPlayer'), isTrue);
    });

    test('内核枚举 aether 沿用 value 3（老用户的 prefs 照样落到这个内核）', () {
      expect(engineModel.contains('aether(3,'), isTrue);
      expect(engineModel.contains('ksplayer'), isFalse);
      expect(engineModel.contains('PlayerEngine.aether'), isTrue);
    });

    test('PiP 走 aether_player 通道', () {
      expect(pip.contains("MethodChannel('aether_player')"), isTrue);
    });

    test('全仓不再有 ks_player 通道 / ks_player_view', () {
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((x) => x.path.endsWith('.dart'))) {
        final src = f.readAsStringSync();
        expect(
          src.contains("MethodChannel('ks_player')"),
          isFalse,
          reason: '${f.path} 还指向旧通道',
        );
        expect(
          src.contains('ks_player_view'),
          isFalse,
          reason: '${f.path} 还指向旧平台视图',
        );
      }
    });
  });
}
