import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:get/get.dart';

import 'app_log.dart';

/// 语音朗读（听书）
///
/// 用 flutter_tts 走**系统 TTS 引擎**（iOS 是 AVSpeechSynthesizer）——
/// 不自己实现语音合成，也不必申请额外权限。
///
/// 朗读策略：把整章文本按段落切开，**一段一段念**（而不是整段丢给引擎）。
/// 原因：
///   · 系统引擎对超长文本的处理不一致（有的会截断、有的会卡）；
///   · 逐段才能做到"念完自动下一段"和"高亮当前段"。
class TtsService extends GetxService {
  static TtsService get instance {
    if (!Get.isRegistered<TtsService>()) {
      Get.put<TtsService>(TtsService(), permanent: true);
    }
    return Get.find<TtsService>();
  }

  final _tts = FlutterTts();

  /// 正在朗读
  final isSpeaking = false.obs;

  /// 暂停中（暂停后可以继续）
  final isPaused = false.obs;

  /// 当前念到第几段（用于高亮 + 自动滚动）
  final currentIndex = 0.obs;

  /// 总段数
  final totalSegments = 0.obs;

  /// 语速 0.1~1.0（iOS 的 AVSpeechUtterance 常规语速约 0.5）
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
  VoidCallback? onChapterFinished;

  @override
  void onInit() {
    super.onInit();
    _initEngine();
  }

  Future<void> _initEngine() async {
    try {
      // 中文优先；取不到就用系统默认，不阻塞
      try {
        await _tts.setLanguage('zh-CN');
      } catch (_) {
        await _tts.setLanguage('zh');
      }
      await _tts.setSpeechRate(rate.value);
      await _tts.setPitch(pitch.value);
      await _tts.setVolume(1.0);

      // 念完一段 → 自动念下一段；全部念完 → 回调
      _tts.setCompletionHandler(() => _onSegmentDone());
      _tts.setErrorHandler((msg) {
        lastError.value = '语音引擎出错：$msg';
        AppLog.instance.log('[TTS] error: $msg');
        // 出错时不要卡死，当作这一段念完
        _onSegmentDone();
      });
      _tts.setCancelHandler(() {
        isSpeaking.value = false;
        isPaused.value = false;
      });
      available.value = true;
    } catch (e) {
      available.value = false;
      lastError.value = '设备没有可用的语音引擎（iOS：设置 → 辅助功能 → 朗读内容）';
      AppLog.instance.log('[TTS] 初始化失败: $e');
    }
  }

  // ============================================================
  // 对外
  // ============================================================

  /// 开始朗读整章文本
  Future<void> speak(String text, {int startAt = 0}) async {
    final segs = splitSegments(text);
    if (segs.isEmpty) {
      lastError.value = '这一章没有可朗读的内容';
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

  /// 暂停（可继续）
  Future<void> pause() async {
    if (!isSpeaking.value) return;
    try {
      await _tts.pause();
    } catch (_) {/* 部分平台 pause 不生效，用 stop 兜底 */}
    isPaused.value = true;
    isSpeaking.value = false;
  }

  /// 继续
  Future<void> resume() async {
    if (!isPaused.value) return;
    isSpeaking.value = true;
    isPaused.value = false;
    try {
      await _tts.speak(_segments[currentIndex.value]);
    } catch (e) {
      await _speakCurrent();
    }
  }

  /// 停止并清空
  Future<void> stop() async {
    _stopRequested = true;
    try {
      await _tts.stop();
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
    try {
      await _tts.setSpeechRate(rate.value);
    } catch (_) {}
    // 语速变更后从当前段重念，让效果立刻可感知
    if (isSpeaking.value) await _speakCurrent();
  }

  Future<void> setPitch(double v) async {
    pitch.value = v.clamp(0.5, 2.0);
    try {
      await _tts.setPitch(pitch.value);
    } catch (_) {}
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
      // 空段直接跳过，避免引擎对空串报错
      _onSegmentDone();
      return;
    }
    try {
      await _tts.speak(seg);
    } catch (e) {
      lastError.value = '朗读失败：$e';
      isSpeaking.value = false;
    }
  }

  void _onSegmentDone() {
    if (_stopRequested || !isSpeaking.value) return;
    final next = currentIndex.value + 1;
    if (next >= _segments.length) {
      // 整章念完 → 交给上层决定是否连播下一章
      isSpeaking.value = false;
      final cb = onChapterFinished;
      if (cb != null) cb();
      return;
    }
    currentIndex.value = next;
    _speakCurrent();
  }

  /// 把章节文本切成适合朗读的片段
  ///
  /// 规则：按空行/换行切段 → 过滤纯符号与超短行 → 过长的段按句号再切
  /// （系统引擎对超长文本会截断，必须自己切）。
  static List<String> splitSegments(String text) {
    final out = <String>[];
    for (final raw in text.split(RegExp(r'\n+'))) {
      var s = raw.trim();
      if (s.isEmpty) continue;
      // 去掉纯装饰行（分隔符、网址等）
      if (RegExp(r'^[\s\-=*_~#·—]+$').hasMatch(s)) continue;
      if (s.length < 2) continue;

      // 过长段落再按句末标点切，每片控制在 ~180 字以内
      if (s.length <= 180) {
        out.add(s);
        continue;
      }
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
