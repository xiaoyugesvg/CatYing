import 'dart:async';

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
