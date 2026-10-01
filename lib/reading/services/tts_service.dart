import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 语音朗读（听书）。
///
/// ── 走原生 channel，**不用第三方插件** ─────────────────────────
/// iOS 侧 `ios/Runner/TtsEngine.swift` 用系统自带的 `AVSpeechSynthesizer`
/// 实现，Dart 通过 `tts_engine` 频道调用。
///
/// 为什么不引 flutter_tts：本项目是 iOS TrollStore 侧载，硬约束是
/// "不新增原生插件"。**新增 pub 依赖若没重新 `pod install`，插件原生库
/// 不会被链接** → Flutter 启动时找不到插件 → **装完就闪退**
/// （flutter_tts 就是这么崩的）。TTS 是系统自带能力，没必要为它引插件。
///
/// ── 分段策略 ──────────────────────────────────────────────────
/// 把整章按段落切开、**一段一段念**（不是整段丢给引擎）：
///   · 系统引擎对超长文本的处理不一致（有的截断、有的卡住）
///   · 逐段才能做到"念完自动下一段 + 高亮当前段"
class TtsService extends GetxService {
  static TtsService get instance {
    if (!Get.isRegistered<TtsService>()) {
      Get.put<TtsService>(TtsService(), permanent: true);
    }
    return Get.find<TtsService>();
  }

  static const MethodChannel _ch = MethodChannel('tts_engine');

  /// 正在朗读
  final isSpeaking = false.obs;

  /// 暂停中（可继续）
  final isPaused = false.obs;

  /// 当前念到第几段（高亮 + 自动滚动用）
  final currentIndex = 0.obs;

  /// 总段数
  final totalSegments = 0.obs;

  /// 语速 0.1~1.0
  final rate = 0.5.obs;

  /// 音调 0.5~2.0
  final pitch = 1.0.obs;

  /// 引擎是否可用
  final available = true.obs;

  /// 出错信息
  final lastError = ''.obs;

  List<String> _segments = [];
  bool _stopRequested = false;

  /// 念完最后一段时回调（用于"自动连播下一章"）
  VoidCallback? onFinished;

  @override
  void onInit() {
    super.onInit();
    // 原生侧每念完一段回调 onDone，据此推进下一段
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onDone') _onSegmentDone();
      return null;
    });
  }

  // ============================================================
  // 对外
  // ============================================================

  /// 开始朗读整段文本
  Future<void> speak(String text, {int startAt = 0}) async {
    final segs = splitSegments(text);
    if (segs.isEmpty) {
      lastError.value = '没有可朗读的内容';
      return;
    }
    await stop();
    _segments = segs;
    totalSegments.value = segs.length;
    currentIndex.value = startAt.clamp(0, segs.length - 1);
    _stopRequested = false;
    isSpeaking.value = true;
    isPaused.value = false;
    await _speakCurrent();
  }

  Future<void> pause() async {
    if (!isSpeaking.value) return;
    try {
      await _ch.invokeMethod<bool>('pause');
    } catch (_) {}
    isPaused.value = true;
    isSpeaking.value = false;
  }

  Future<void> resume() async {
    if (!isPaused.value) return;
    isSpeaking.value = true;
    isPaused.value = false;
    try {
      final ok = await _ch.invokeMethod<bool>('resume') ?? false;
      // continueSpeaking 被系统回收时会返回 false：这时从当前段重念，
      // 保证"继续"一定有反应，而不是静默失败。
      if (!ok) await _speakCurrent();
    } catch (_) {
      await _speakCurrent();
    }
  }

  Future<void> stop() async {
    _stopRequested = true;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
    isSpeaking.value = false;
    isPaused.value = false;
  }

  /// 跳到某一段并继续念
  Future<void> jumpTo(int index) async {
    if (_segments.isEmpty) return;
    currentIndex.value = index.clamp(0, _segments.length - 1);
    _stopRequested = false;
    isSpeaking.value = true;
    isPaused.value = false;
    await _speakCurrent();
  }

  Future<void> setRate(double v) async {
    rate.value = v.clamp(0.1, 1.0);
    // 语速变更后从当前段重念，让效果立刻可感知
    if (isSpeaking.value) await _speakCurrent();
  }

  Future<void> setPitch(double v) async {
    pitch.value = v.clamp(0.5, 2.0);
    if (isSpeaking.value) await _speakCurrent();
  }

  // ============================================================
  // 内部
  // ============================================================

  Future<void> _speakCurrent() async {
    if (_stopRequested) return;
    final i = currentIndex.value;
    if (i < 0 || i >= _segments.length) return;
    final seg = _segments[i];
    if (seg.trim().isEmpty) {
      _onSegmentDone();
      return;
    }
    try {
      await _ch.invokeMethod('speak', {
        'text': seg,
        'rate': rate.value,
        'pitch': pitch.value,
      });
    } on MissingPluginException {
      // 原生侧没注册（非 iOS 平台，或构建没包含 TtsEngine.swift）
      available.value = false;
      isSpeaking.value = false;
      lastError.value = '当前构建不含语音引擎（非 iOS 平台或原生代码未编译）';
    } catch (e) {
      lastError.value = '朗读失败：$e';
      isSpeaking.value = false;
    }
  }

  // ══════════════════════════════════════════════════════════════
  // 平台能力（复用同一个原生 TtsEngine.swift，**不新增原生文件**）
  // ══════════════════════════════════════════════════════════════
  //
  // ⚠️ 为什么不各开一个新 channel：
  //   新增 Swift 文件必须改 `ios/Runner.xcodeproj/project.pbxproj`
  //   的 Build Phase —— 那是在 Windows 上改 Xcode 工程，风险极高
  //   （UUID 写错整个项目打不开）。
  //   `TtsEngine.swift` **已经在 pbxproj 里注册过**，所以往它的
  //   `handle` switch 里加 case 是纯增量、零工程文件改动。
  //   一个 channel 支持任意多个方法名，不需要开新 channel。

  /// 禁止息屏（阅读器的「永不息屏」）
  ///
  /// ⚠️ 用完**必须** [allowSleep]，否则用户离开阅读器后屏幕永远不灭。
  Future<void> keepAwake() async {
    try {
      await _ch.invokeMethod('keepAwake');
    } catch (_) {}
  }

  /// 恢复系统息屏
  Future<void> allowSleep() async {
    try {
      await _ch.invokeMethod('allowSleep');
    } catch (_) {}
  }

  /// 电量百分比（取不到返回 null）。
  ///
  /// ⚠️ 别写 `MethodChannel('dsh/battery')` 这种想当然的频道名 ——
  /// 原生端没注册的话 invokeMethod 会抛 MissingPluginException，
  /// 界面上永远显示不出值，而且不容易发现是这个原因。
  Future<int?> batteryLevel() async {
    try {
      return await _ch.invokeMethod<int>('battery');
    } catch (_) {
      return null;
    }
  }

  /// 把一张图片的字节存进相册。
  ///
  /// Dart 侧负责下载（要带 Referer/UA 才能过某些图床的防盗链），
  /// 原生只做「解码 + 写相册」。
  /// 返回 (ok, error)。
  Future<({bool ok, String? error})> saveImageToAlbum(
      List<int> bytes) async {
    try {
      await _ch.invokeMethod('saveImage', {
        'bytes': base64Encode(bytes),
      });
      return (ok: true, error: null);
    } on PlatformException catch (e) {
      return (ok: false, error: e.message ?? e.code);
    } catch (e) {
      return (ok: false, error: '$e');
    }
  }

  void _onSegmentDone() {
    if (_stopRequested || !isSpeaking.value) return;
    final next = currentIndex.value + 1;
    if (next >= _segments.length) {
      isSpeaking.value = false;
      final cb = onFinished;
      if (cb != null) cb();
      return;
    }
    currentIndex.value = next;
    _speakCurrent();
  }

  /// 把文本切成适合朗读的片段。
  ///
  /// 规则：按换行切段 → 过滤纯符号与超短行 → 过长的段按句末标点再切
  /// （系统引擎对超长文本会截断，必须自己切）。
  static List<String> splitSegments(String text) {
    final out = <String>[];
    for (final raw in text.split(RegExp(r'\n+'))) {
      final s = raw.trim();
      if (s.isEmpty) continue;
      // 跳过纯装饰行（分隔符等）
      if (RegExp(r'^[\s\-=*_~#·—]+$').hasMatch(s)) continue;
      if (s.length < 2) continue;

      if (s.length <= 180) {
        out.add(s);
        continue;
      }
      // 过长段落按句末标点切，每片约 120 字
      final buf = StringBuffer();
      for (final ch in s.split('')) {
        buf.write(ch);
        if (buf.length >= 120 && '。！？；.!?;'.contains(ch)) {
          out.add(buf.toString().trim());
          buf.clear();
        }
      }
      final rest = buf.toString().trim();
      if (rest.isNotEmpty) out.add(rest);
    }
    return out;
  }
}
