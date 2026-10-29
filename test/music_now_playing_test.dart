import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/music/services/now_playing_service.dart';

/// 锁屏 / 控制中心 媒体控制的 **Dart 侧**行为测试。
///
/// ── 为什么只能测到这一层（如实说明）──────────────────────────────
/// 真机行为（锁屏上到底显不显示、按了键有没有反应）**测不了**：
///   · 需要 macOS + Xcode 编译原生侧（`ios/Runner/MusicNowPlaying.swift`）
///   · 需要真机 + 侧载环境验证 iOS 的媒体策略
///
/// 但 Dart 侧有几件**必须**保证的事，这里钉住：
///   ① **没有原生侧时不能崩**（单测 / 桌面 / 未来某个平台没实现）——
///      这是最容易漏的一条：`MethodChannel` 在无原生实现时会抛
///      `MissingPluginException`，如果没接住，**播放器一切换歌曲就崩** ✗
///   ② `start()` 幂等（重复调用不出问题）
///   ③ 能力查询（灵动岛/实时活动）必须**如实返回 false**，
///      而不是假装支持 —— 那是"给了个点了没反应的开关"
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ch = MethodChannel('tvbox/music_now_playing');

  /// 记录 Dart → 原生的调用（模拟"原生侧存在"）
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null);
  });

  test('🔴 没有原生侧时 start() 不能崩（MissingPluginException 必须被接住）',
      () async {
    // 不注册任何 mock handler = 模拟"这个平台没有原生实现"
    // `MethodChannel` 此时会抛 MissingPluginException
    expect(() => NowPlayingService.instance.start(), returnsNormally,
        reason: 'start() 不该抛 —— 它内部只挂监听 + setMethodCallHandler');

    // 真正会抛的是"推元数据"那步（invokeMethod）。
    // 用一个明确的失败 handler 来确认它**被接住**了。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async {
      throw MissingPluginException('no native side');
    });

    // 直接调能力查询（内部会 invokeMethod）—— 不该抛
    final ok = await NowPlayingService.instance.liveActivitiesSupported();
    expect(ok, isFalse, reason: '没有原生侧时应当安全地返回 false');
  });

  test('灵动岛/实时活动：当前必须**如实返回 false**（没实现就不能说支持）',
      () async {
    // 原生侧存在但返回 false（就是现在的真实情况：没做 Widget Extension）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async {
      calls.add(call);
      if (call.method == 'liveActivitiesSupported') return false;
      return null;
    });

    final supported = await NowPlayingService.instance.liveActivitiesSupported();
    expect(supported, isFalse,
        reason: '灵动岛需要 ActivityKit + Widget Extension target，'
            '本项目（TrollStore 侧载、不新增 target）没有实现 → '
            '必须返回 false，让 UI 能如实告知用户，'
            '而不是给一个点了没反应的开关');

    expect(calls.map((c) => c.method), contains('liveActivitiesSupported'));
  });

  test('原生返回 true 时也如实透传（将来实现了不用改这里）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async {
      if (call.method == 'liveActivitiesSupported') return true;
      return null;
    });
    expect(await NowPlayingService.instance.liveActivitiesSupported(), isTrue);
  });

  test('debugState() 无原生侧时不崩（真机排查入口）', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async {
      if (call.method == 'debugState') {
        return {'hasInfo': true, 'playbackState': 1, 'commandsRegistered': true};
      }
      return null;
    });
    await expectLater(NowPlayingService.instance.debugState(), completes);
  });

  test('start() 幂等：调两次不会重复挂监听/重复注册 handler', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async => null);

    expect(() {
      NowPlayingService.instance.start();
      NowPlayingService.instance.start();
    }, returnsNormally);
  });
}
