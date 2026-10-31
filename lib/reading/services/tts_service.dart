import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

import 'package:tvbox/reading/models/tts_source.dart';
import 'package:tvbox/reading/services/ai_service.dart';
import 'package:tvbox/reading/source/global_proxy.dart';
import 'package:tvbox/reading/services/tts_now_playing.dart';
import 'package:tvbox/reading/services/tts_source_store.dart';
import 'package:tvbox/services/nodejs_manager.dart';

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
/// ── 网络朗读源 ────────────────────────────────────────────────
/// 「朗读引擎」页里把某个网络源设为「当前使用」后，朗读会改走
/// **HTTP 合成 + media_kit 播放**（dio / media_kit 都已在项目依赖里，
/// 零新增原生插件）：
///   · `easyvoice` POST `/api/v1/tts/generateJson`（Edge-TTS 免费音色）拿 mp3；
///   · `http`      按 URL 模板直接 GET/POST 拿音频字节；
///   · `edge`      走 App 内置 Node（`/tts/edge`），免地址免 Key；
///   · `mimo`      小米 MiMo **chat 接口**，正文走 assistant 消息，
///                 音频按 base64 返回（固定 wav）；
///   · `openai`    `/audio/speech` 通用形状；
///   · `azure`     Azure 语音 REST（SSML）；
///   · media_kit 播放音频，念完自动下一段，高亮照旧；
///   · 暂停 / 继续 / 停止 / 跳段 / 倍速全部由播放器接管；
///   · 合成失败时按源的「失败自动降级」开关切回系统朗读继续读。
///
/// ⚠️ 2026-10-29 之前 `mimo` / `openai` / `azure` 只做了配置校验、
/// **合成没接**，用户把它们设成「使用中」后实际仍走系统引擎，
/// 表现就是「设置成功但一点效果都没有」。现已全部接入。
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

  /// 走网络合成（HTTP + media_kit 播放）的类型。
  ///
  /// 2026-10-29 补：原来只有 easyvoice / http / edge 三种能真正发声，
  /// `mimo` / `openai` / `azure` 虽然在「朗读引擎」页里能配、能设成
  /// 「使用中」，但 `_netSource` 的判定把它们排除在外 → 静默回落系统朗读。
  /// 用户看到的就是「设置成功但没效果」。现在六种全部接上。
  static const Set<String> _networkTypes = {
    'easyvoice',
    'http',
    'edge',
    'mimo',
    'openai',
    'azure',
  };

  /// 正在朗读
  final isSpeaking = false.obs;

  /// 暂停中（可继续）
  final isPaused = false.obs;

  /// 当前念到第几段（高亮 + 自动滚动用）
  final currentIndex = 0.obs;

  /// **当前这一段**念到哪了（0~1）。跟读翻页用。
  ///
  /// ── 为什么需要它（用户 2026-10-31）────────────────────────────
  /// 「听书为啥已经播放到下一页了，但是没有自动翻页过去」。
  ///
  /// 原生只回 `onDone`（一段念完），没有段内进度 ⇒ 阅读器只能"一段一翻"。
  /// 而网文一段常常半屏甚至更长，**段跨页**时：
  ///   · 念到第 2 页了，但 `currentIndex` 还没变；
  ///   · 阅读器算出的目标页还是这段的**首页** == 当前页；
  ///   · ⇒ 画面纹丝不动，直到整段念完才跳一下。
  ///
  /// 这里补一个**估算**的段内进度：中文 TTS 正常语速约 4.5 字/秒，
  /// 段总时长 ≈ `字数 / (4.5 × rate)`，再用单调时钟算比例。
  /// 误差在 ±15% 量级，而翻页只需要判断"有没有跨过半页"，够用；
  /// 网络源有真实播放器 position 时优先用真实值（见 [_netProgress]）。
  final segmentProgress = 0.0.obs;

  /// 段内进度计时器（只在朗读中跑）
  Timer? _segTimer;
  DateTime? _segStartedAt;
  Duration _segPausedAcc = Duration.zero;
  DateTime? _segPausedAt;
  int _segChars = 0;

  /// 中文 TTS 默认语速：每秒约几个字（@`rate = 0.5`，即系统默认语速）。
  ///
  /// 取 4.5 的依据：系统 AVSpeechSynthesizer 中文默认语速实测约 4.3~4.8 字/秒，
  /// 各家网络源（Edge / Azure）落在同一区间。估算只需量级正确。
  static const double _kCharsPerSecond = 4.5;

  /// 系统 TTS 的"正常语速"基准值（AVSpeechUtteranceDefaultSpeechRate）。
  static const double _kNormalRate = 0.5;

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

  /// 定时关闭剩余秒数（0 = 未开启）
  final sleepRemaining = 0.obs;

  Timer? _sleepTimer;
  String _npTitle = '听书';
  String _npSubtitle = '';

  List<String> _segments = [];
  bool _stopRequested = false;

  // ── 网络朗读源（EasyVoice）──────────────
  /// 构造 EasyVoice 合成/请求用的 Dio，并**挂上「网络代理」**（本轮接上 ✓）。
  ///
  /// 为什么 ✗：**easyVoice 是网络朗读源** ✓（它要 POST `/api/v1/tts/generateJson` 拿 mp3 ✓）——
  /// 用户开了「网络代理」后**朗读却照样直连** ✗，于是"能搜到书但念不出来"✓。
  /// 手法与 `zlibrary_service._createDio()` ✓、`comic_api` 构造函数里那处 ✓ **完全一致** ✓
  /// （先构造 ✓ 再 `applyGlobalProxy` ✓）—— 不发明新机制 ✗。
  /// ⚠️ 本服务**无自定义适配器/UA** ✓（只有两个超时 ✓）→ 直接挂**安全** ✓✓
  /// · 代理**关闭** ✓ → 返回 false ✓ **一字不改** ✓（与从前完全一致 ✓✓）
  static Dio _createDio() {
    // ⚠️ 不能写 `Dio(const BaseOptions(...))` ✗ —— **`BaseOptions` 不是 const 构造** ✓，
    //   会报 "The constructor being called isn't a const constructor" ✗（本轮闸门**再次当场抓到** ✓✓）。
    //   注意里面两个 `const Duration` 是**可以** const 的 ✓（那才是常量 ✓）。
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 25),
    ));
    applyGlobalProxy(dio);
    return dio;
  }

  final Dio _dio = _createDio();
  /// 当前激活的 easyvoice 源（null = 走系统原生朗读）
  TtsSource? _netSource;
  Player? _netPlayer;
  StreamSubscription<bool>? _netCompleteSub;
  /// 上一段合成的临时文件（下一段开播前删掉，避免 tmp 堆积）
  File? _netTmpFile;
  bool _netSynthesizing = false;

  /// 本章是否已从网络源**降级**成系统朗读。
  ///
  /// 用户 2026-10-29：「AI听书为啥读一段下一段又是系统朗读？」
  /// 根因有两个，这是第二个：
  ///   · ①（主因）`_onSegmentDone` 无条件走系统朗读 —— 见那里的注释；
  ///   · ② 合成**偶发**失败时，只给失败的那一段回落系统朗读，下一段又去试网络源，
  ///     于是整章变成「AI 音 / 系统音」交替。
  /// 所以：**一段失败就整章统一走系统**（同一章里绝不混两种声音），
  /// 下一章 `speak()` 时重置，重新给网络源机会。
  bool _netDegraded = false;

  /// 本次朗读**实际**是否走网络合成（有源 + 没降级）
  ///
  /// 所有「分支走网络还是走原生」的判断都必须用它，不要再用 `_netSource != null` ——
  /// 那会让降级后的暂停 / 倍速 / 跳段仍然去操作已经停用的播放器。
  bool get _useNet => _netSource != null && !_netDegraded;

  /// 当前实际在用的引擎名（朗读面板 / 引擎页展示用）
  String get activeEngineLabel {
    if (!_useNet) return '系统朗读';
    final s = _netSource!;
    return s.name.trim().isEmpty ? _labelOf(s) : s.name.trim();
  }

  /// 重新对齐「当前用哪个源」——**每个段落开始时都要调**。
  ///
  /// 这样用户在朗读过程中去「朗读引擎」页换了源，下一段就生效，
  /// 而不是必须停掉重念才认（原来的行为，用户觉得"设置没反应"）。
  void _syncNetSource() {
    final active = TtsSourceStore.instance.active;
    final next = (active != null && _networkTypes.contains(active.type))
        ? active
        : null;
    final nextId = next?.id ?? '';
    if (nextId != (_netSource?.id ?? '')) {
      // 换了源 → 之前的降级结论作废，重新给它一次机会
      _netDegraded = false;
    }
    _netSource = next;
  }

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
    // 锁屏 / 控制中心：远程按键统一交给本服务
    TtsNowPlaying.instance.onRemote = _handleRemote;
    TtsNowPlaying.instance.init();
  }

  @override
  void onClose() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    // 释放网络播放器与订阅（service 为 permanent，正常不触发，
    // 但 Get 清空时会走这里，避免播放器/订阅泄漏）
    _netCompleteSub?.cancel();
    _netCompleteSub = null;
    _netPlayer?.dispose();
    _netPlayer = null;
    super.onClose();
  }

  // ============================================================
  // 定时关闭 / 锁屏控制
  // ============================================================

  /// 设置听书标题（锁屏/控制中心显示）。
  void setNowPlayingMeta(String title, [String subtitle = '']) {
    _npTitle = title.trim().isEmpty ? '听书' : title.trim();
    _npSubtitle = subtitle.trim();
    _updateNowPlaying();
  }

  /// 定时关闭：到点自动暂停朗读。
  void startSleep(Duration d) {
    _sleepTimer?.cancel();
    var secs = d.inSeconds;
    if (secs <= 0) {
      cancelSleep();
      return;
    }
    sleepRemaining.value = secs;
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      secs--;
      sleepRemaining.value = secs < 0 ? 0 : secs;
      if (secs <= 0) {
        t.cancel();
        _sleepTimer = null;
        sleepRemaining.value = 0;
        pause();
      }
    });
  }

  void cancelSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepRemaining.value = 0;
  }

  Future<void> _updateNowPlaying({bool? playing}) async {
    await TtsNowPlaying.instance.update(
      title: _npTitle,
      subtitle: _npSubtitle,
      position: currentIndex.value,
      duration: totalSegments.value,
      playing: playing ?? isSpeaking.value,
    );
  }

  Future<void> _handleRemote(String action) async {
    switch (action) {
      case 'play':
        if (isPaused.value) await resume();
        break;
      case 'pause':
        await pause();
        break;
      case 'toggle':
        if (isPaused.value) {
          await resume();
        } else if (isSpeaking.value) {
          await pause();
        }
        break;
      case 'stop':
        await stop();
        break;
      case 'next':
        await jumpTo(currentIndex.value + 1);
        break;
      case 'previous':
        await jumpTo(currentIndex.value - 1);
        break;
    }
  }

  // ============================================================
  // 对外
  // ============================================================

  /// 开始朗读整段文本
  Future<void> speak(String text,
      {int startAt = 0, List<String?>? segmentVoices}) async {
    // 刷新当前朗读源：朗读引擎页里选中的网络源生效，否则原生
    await TtsSourceStore.instance.init();
    _syncNetSource();
    // 新的一次朗读（换章 / 重念）→ 清掉上一章的降级结论，重新试网络源
    _netDegraded = false;
    var segs = splitSegments(text);
    // EasyVoice「AI 推荐配音」：一次 AI 分析给一段才有意义，
    // 把小段合并成 ~1500 字大段再发（服务端内部会再按角色切）
    if (_netSource != null &&
        _netSource!.useAiVoice &&
        _netSource!.aiVoiceAvailable) {
      segs = _mergeSegmentsForAi(segs);
    }
    if (segs.isEmpty) {
      lastError.value = '没有可朗读的内容';
      return;
    }
    await stop();
    _segments = segs;
    // A4 双音色：与 _segments 对齐的逐段音色覆盖（null = 用源默认音色）✓
    _segmentVoices = segmentVoices;
    totalSegments.value = segs.length;
    currentIndex.value = startAt.clamp(0, segs.length - 1);
    _stopRequested = false;
    isSpeaking.value = true;
    isPaused.value = false;
    await TtsNowPlaying.instance.activate();
    _updateNowPlaying(playing: true);
    if (_useNet) {
      await _speakNetworkCurrent();
    } else {
      await _speakCurrent();
    }
  }

  /// 把小段合并成 ≤2000 字的大段（AI 推荐配音用，避免每 120 字调一次大模型）
  static List<String> _mergeSegmentsForAi(List<String> segs) {
    const limit = 2000;
    final out = <String>[];
    final buf = StringBuffer();
    for (final s in segs) {
      if (buf.length > 0 && buf.length + s.length > limit) {
        out.add(buf.toString().trim());
        buf.clear();
      }
      buf.write(s);
      buf.write('\n');
    }
    final rest = buf.toString().trim();
    if (rest.isNotEmpty) out.add(rest);
    return out;
  }

  Future<void> pause() async {
    if (!isSpeaking.value) return;
    // 段内进度计时暂停（否则暂停期间也被算成"在念"，恢复后会一下跳好几页）
    if (_segPausedAt == null) _segPausedAt = DateTime.now();
    if (_useNet && !_netSynthesizing) {
      try {
        await _netPlayer?.pause();
      } catch (_) {}
      isPaused.value = true;
      isSpeaking.value = false;
      _updateNowPlaying(playing: false);
      return;
    }
    try {
      await _ch.invokeMethod<bool>('pause');
    } catch (_) {}
    isPaused.value = true;
    isSpeaking.value = false;
    _updateNowPlaying(playing: false);
  }

  Future<void> resume() async {
    if (!isPaused.value) return;
    // 把暂停期间从"已念时长"里扣掉
    final pausedAt = _segPausedAt;
    if (pausedAt != null) {
      _segPausedAcc += DateTime.now().difference(pausedAt);
      _segPausedAt = null;
    }
    isSpeaking.value = true;
    isPaused.value = false;
    _updateNowPlaying(playing: true);
    if (_useNet) {
      // 合成中暂停的：直接等当前段合成完开播即可
      if (!_netSynthesizing) {
        try {
          await _netPlayer?.play();
        } catch (_) {}
      }
      return;
    }
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
    _stopSegClock();
    // ⚠️ 这里判 `_netPlayer`（而不是 `_useNet`）：降级后 `_useNet` 已经是 false，
    //   但播放器可能还留着上一段的声音、临时文件也还没删 —— 都得收干净。
    if (_netSource != null || _netPlayer != null) {
      _netSynthesizing = false;
      try {
        await _netPlayer?.stop();
      } catch (_) {}
      _clearNetTmp();
    }
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
    isSpeaking.value = false;
    isPaused.value = false;
    _updateNowPlaying(playing: false);
    await TtsNowPlaying.instance.deactivate();
  }

  /// 跳到某一段并继续念
  Future<void> jumpTo(int index) async {
    if (_segments.isEmpty) return;
    currentIndex.value = index.clamp(0, _segments.length - 1);
    _stopRequested = false;
    isSpeaking.value = true;
    isPaused.value = false;
    _updateNowPlaying(playing: true);
    if (_useNet) {
      _netSynthesizing = false;
      try {
        await _netPlayer?.stop();
      } catch (_) {}
      _clearNetTmp();
      await _speakNetworkCurrent();
    } else {
      await _speakCurrent();
    }
  }

  Future<void> setRate(double v) async {
    rate.value = v.clamp(0.1, 1.0);
    if (_useNet) {
      // 正在播的段用播放器实时变速（已合成段的请求参数不再回传）
      if (isSpeaking.value && !_netSynthesizing) {
        try {
          await _netPlayer?.setRate(_netPlaybackRate());
        } catch (_) {}
      }
      return;
    }
    // 语速变更后从当前段重念，让效果立刻可感知
    if (isSpeaking.value) await _speakCurrent();
  }

  Future<void> setPitch(double v) async {
    pitch.value = v.clamp(0.5, 2.0);
    // 网络源：音调只影响之后新合成的段；正在播的段不重念
    if (_useNet) return;
    if (isSpeaking.value) await _speakCurrent();
  }

  // ============================================================
  // 内部
  // ============================================================

  /// 逐段音色覆盖（A4 双音色，与 [_segments] 对齐；null = 用源默认音色）
  List<String?>? _segmentVoices;

  // ── 段内进度计时（跟读翻页用）──────────────────────────────────

  /// 一段开始念：重置并启动段内进度计时。
  ///
  /// 只统计**非空白字符**（标点算在内 —— 它们也要占朗读时间）。
  void _startSegClock(String text) {
    _segTimer?.cancel();
    _segStartedAt = DateTime.now();
    _segPausedAcc = Duration.zero;
    _segPausedAt = null;
    _segChars = text.replaceAll(RegExp(r'\s'), '').length;
    segmentProgress.value = 0;
    if (_segChars <= 0) return;
    _segTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _tickSegClock(),
    );
  }

  void _tickSegClock() {
    if (!isSpeaking.value || isPaused.value) return;
    final started = _segStartedAt;
    if (started == null) return;
    final total = _estimatedSegDuration();
    if (total.inMilliseconds <= 0) return;
    final elapsed = DateTime.now().difference(started) - _segPausedAcc;
    final p = elapsed.inMilliseconds / total.inMilliseconds;
    // 估算只用于"跨没跨过半页"，封顶 1.0 就够（真念完会走 _onSegmentDone）
    segmentProgress.value = p.clamp(0.0, 1.0);
  }

  /// 段总时长估算。`rate` 的 0.5 = 正常语速，按比例缩放。
  Duration _estimatedSegDuration() {
    if (_segChars <= 0) return Duration.zero;
    final r = rate.value <= 0 ? _kNormalRate : rate.value;
    final cps = _kCharsPerSecond * (r / _kNormalRate);
    if (cps <= 0) return Duration.zero;
    return Duration(milliseconds: (_segChars / cps * 1000).round());
  }

  void _stopSegClock() {
    _segTimer?.cancel();
    _segTimer = null;
    _segStartedAt = null;
    _segPausedAcc = Duration.zero;
    _segPausedAt = null;
    _segChars = 0;
    segmentProgress.value = 0;
  }

  Future<void> _speakCurrent() async {
    if (_stopRequested) return;
    final i = currentIndex.value;
    if (i < 0 || i >= _segments.length) return;
    final seg = _segments[i];
    if (seg.trim().isEmpty) {
      _onSegmentDone();
      return;
    }
    // 新的一段开始 → 段内进度归零重算（跟读翻页依赖它判断跨页）
    _startSegClock(seg);
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
  // 网络朗读源（EasyVoice）—— HTTP 合成 + media_kit 播放
  // ══════════════════════════════════════════════════════════════
  // 不新增任何原生插件：dio 发请求、media_kit 播 mp3，两者都已在
  // 项目依赖里（main.dart 已 MediaKit.ensureInitialized()）。

  /// 网络分支：合成当前段并播放
  Future<void> _speakNetworkCurrent() async {
    if (_stopRequested) return;
    final i = currentIndex.value;
    if (i < 0 || i >= _segments.length) return;
    final seg = _segments[i];
    if (seg.trim().isEmpty) {
      _onSegmentDone();
      return;
    }
    final src = _netSource;
    if (src == null || _netDegraded) {
      await _speakCurrent();
      return;
    }
    _netSynthesizing = true;
    try {
      // A4 双音色：取本段音色覆盖（无则走源默认）
      final segVoice =
          (_segmentVoices != null && i < _segmentVoices!.length)
              ? _segmentVoices![i]
              : null;
      final List<int>? bytes;
      switch (src.type) {
        case 'http':
          bytes = await _synthesizeHttp(src, seg, rate.value);
          break;
        case 'edge':
          bytes = await _synthesizeEdge(src, seg);
          break;
        case 'mimo':
          bytes = await _synthesizeMimo(src, seg);
          break;
        case 'openai':
          bytes = await _synthesizeOpenAi(src, seg, voiceOverride: segVoice);
          break;
        case 'azure':
          bytes = await _synthesizeAzure(src, seg, voiceOverride: segVoice);
          break;
        default:
          bytes = await _synthesizeEasyVoice(src, seg, voiceOverride: segVoice);
      }
      _netSynthesizing = false;
      if (_stopRequested) return;
      if (bytes == null || bytes.isEmpty) throw '服务返回空音频';
      if (!isSpeaking.value) return; // 合成期间被暂停/停止
      // MiMo 固定返回 wav，其余按源的格式给扩展名（media_kit 靠它选解复用器）
      //
      // 段内进度计时**放在真正开播这一刻**：合成要花 0.3~3s，若在函数入口就
      // 起表，这段"还没出声"的时间会被算成已念 ⇒ 跟读翻页会提前翻。
      _startSegClock(seg);
      await _playNetBytes(bytes,
          ext: src.type == 'mimo' ? 'wav' : _extOf(src.audioFormat));
    } catch (e) {
      _netSynthesizing = false;
      if (_stopRequested) return;
      if (src.fallbackToSystem) {
        // 合成失败 → 按源开关切回系统朗读继续读。
        //
        // ⚠️ 用户 2026-10-29：「读一段下一段又是系统朗读」的另一半原因就在这里：
        //   原来只让**失败的那一段**走系统，下一段又去试网络源 → 整章 AI 音 /
        //   系统音交替。现在失败一次就**整章**统一走系统（`_netDegraded`），
        //   声音保持一致；下一章 `speak()` 会重置再试。
        _netDegraded = true;
        lastError.value = '${_labelOf(src)}失败，本章已切回系统朗读：$e';
        isSpeaking.value = true;
        isPaused.value = false;
        await _speakCurrent();
      } else {
        lastError.value = '合成失败：$e';
        isSpeaking.value = false;
      }
    }
  }

  static String _labelOf(TtsSource src) {
    switch (src.type) {
      case 'edge':
        return '内置朗读';
      case 'mimo':
        return '小米 MiMo 朗读';
      case 'azure':
        return 'Azure 朗读';
      case 'openai':
        return 'OpenAI 兼容朗读';
      default:
        return '网络朗读';
    }
  }

  /// 朗读源连通性自检：**真合成一句**再回来报结果。
  ///
  /// 之前「测试连接」对 mimo / openai / azure 只做「字段填了没」的
  /// 静态检查，还口口声声说"配置完整" —— 用户以为通了，一播还是
  /// 系统声音。现在这几类一律真发一次请求，拿不到音频就如实报错。
  Future<String> probeSource(TtsSource src) async {
    const text = '这是一个测试。';
    final List<int>? bytes;
    try {
      switch (src.type) {
        case 'mimo':
          bytes = await _synthesizeMimo(src, text);
          break;
        case 'openai':
          bytes = await _synthesizeOpenAi(src, text);
          break;
        case 'azure':
          bytes = await _synthesizeAzure(src, text);
          break;
        case 'http':
          bytes = await _synthesizeHttp(src, text, rate.value);
          break;
        default:
          bytes = await _synthesizeEasyVoice(src, text);
      }
    } catch (e) {
      return '请求失败：$e';
    }
    if (bytes == null || bytes.isEmpty) {
      return '服务返回了空音频 —— 接口地址或模型 ID 可能不对。';
    }
    final kb = (bytes.length / 1024).toStringAsFixed(0);
    final head = bytes.take(4).toList();
    final looksAudio = head.isNotEmpty &&
        ((head[0] == 0x49 && head.length > 1 && head[1] == 0x44) || // ID3
            (head[0] == 0xFF) || // mp3 frame
            (head[0] == 0x52 && head[1] == 0x49 && head[2] == 0x46)); // RIFF/wav
    return looksAudio
        ? '连通：返回 $kb KB 音频，可以正常朗读。'
        : '返回了内容但不是音频（$kb KB，首字节 ${head.map((b) => b.toRadixString(16)).join(' ')}）。'
            '多半是接口地址指向了网页或错误页。';
  }

  /// 音频扩展名归一（mp3 / wav / opus / aac / flac）
  static String _extOf(String fmt) {
    final f = fmt.trim().toLowerCase();
    if (f.isEmpty) return 'mp3';
    if (f == 'pcm') return 'wav';
    return f;
  }

  /// 读源的 API Key（存在独立键里，不在源配置里）
  Future<String> _keyOf(TtsSource src) =>
      TtsSourceStore.instance.apiKey(src.id);

  /// 解析本源实际要用的「接口地址 / Key / 模型」。
  ///
  /// 打开 [TtsSource.useAiConfig] 时直接取「AI 管理」那一份 ——
  /// 用户在设置里配过一次就够，不必在朗读源里再抄一遍。
  Future<({String base, String key, String model})> _resolveConn(
      TtsSource src, String defaultModel,
      {bool borrowModel = true}) async {
    if (src.useAiConfig && src.aiConfigAvailable) {
      final ai = AiService();
      if (!ai.isConfigured) {
        throw '已开启「复用 AI 管理」，但 AI 管理里还没填 API Key';
      }
      // 只有 MiMo 才借用 AI 管理的模型名 —— 它本来就是一个 chat 模型；
      // OpenAI 兼容的 /audio/speech 是**独立的 TTS 模型**，
      // 拿 AI 管理里的对话模型去打必然 404，所以那边只用地址和 Key。
      final m = src.modelId.trim().isNotEmpty
          ? src.modelId.trim()
          : (borrowModel && ai.model.trim().isNotEmpty
              ? ai.model.trim()
              : defaultModel);
      return (
        base: _chatBase(ai.baseUrl),
        key: ai.apiKey.trim(),
        model: m,
      );
    }
    return (
      base: _chatBase(src.endpoint),
      key: (await _keyOf(src)).trim(),
      model: src.modelId.trim().isEmpty ? defaultModel : src.modelId.trim(),
    );
  }

  /// 从 chat / speech 响应里把 base64 音频抠出来。
  ///
  /// MiMo 按 OpenAI 音频输出形状返回 `choices[0].message.audio.data`；
  /// 不同兼容服务还会把音频塞在 `data` / `audio` / `result.audio` 里，
  /// 这里按已知路径依次试，都不中就再全局扫一遍找最长的 base64 串。
  static String? _pickBase64Audio(dynamic json) {
    if (json is! Map) return null;
    final paths = <List<String>>[
      ['choices', '0', 'message', 'audio', 'data'],
      ['choices', '0', 'message', 'audio'],
      ['choices', '0', 'delta', 'audio', 'data'],
      ['choices', '0', 'message', 'content'],
      ['data', 'audio'],
      ['data'],
      ['audio'],
      ['result', 'audio'],
      ['audio_content'],
    ];
    for (final p in paths) {
      dynamic cur = json;
      for (final k in p) {
        if (cur is Map) {
          cur = cur[k];
        } else if (cur is List && int.tryParse(k) != null) {
          final idx = int.parse(k);
          cur = idx < cur.length ? cur[idx] : null;
        } else {
          cur = null;
        }
        if (cur == null) break;
      }
      if (cur is String && cur.trim().length > 64) return cur.trim();
      if (cur is Map) {
        final b = cur['data'];
        if (b is String && b.trim().length > 64) return b.trim();
      }
    }
    // 兜底：递归找最长的、看起来像 base64 的字符串
    String? best;
    void walk(dynamic v) {
      if (v is String) {
        final s = v.trim();
        if (s.length > 64 &&
            !s.contains(' ') &&
            RegExp(r'^[A-Za-z0-9+/=\r\n]+$').hasMatch(s)) {
          if (best == null || s.length > best!.length) best = s;
        }
      } else if (v is Map) {
        for (final e in v.values) {
          walk(e);
        }
      } else if (v is List) {
        for (final e in v) {
          walk(e);
        }
      }
    }

    walk(json);
    return best;
  }

  /// 小米 MiMo：**chat 接口**，不是 `/audio/speech`。
  ///
  /// 协议（见 [TtsSource] 类文档，来自官方说明）：
  ///   · 风格指令 → `user` 消息
  ///   · 正文     → `assistant` 消息
  ///   · 没有语速字段（语速写进风格指令）
  ///   · 音频按 base64 返回，格式固定 wav
  Future<List<int>?> _synthesizeMimo(TtsSource src, String text) async {
    final conn = await _resolveConn(src, 'mimo-v2.5-tts');
    final base = conn.base;
    if (base.isEmpty) throw '接口地址为空';
    final key = conn.key;
    if (key.isEmpty) throw '未填 API Key';

    // 风格标签加在正文最前（「(开心) 今天天气不错」）
    final tag = src.styleTag.trim();
    final body = text.trim();
    final content = tag.isEmpty ? body : '$tag$body';
    final prompt = src.stylePrompt.trim().isEmpty
        ? '请用自然、适合有声书朗读的语气念下面这段文字。'
        : src.stylePrompt.trim();

    final messages = <Map<String, String>>[
      {'role': 'user', 'content': prompt},
      {'role': 'assistant', 'content': content},
    ];

    final data = <String, dynamic>{
      'model': conn.model,
      'messages': messages,
      'stream': false,
      // 要求返回音频（OpenAI 音频输出形状）；不认这个字段的服务会忽略它
      'modalities': ['text', 'audio'],
      'audio': {
        'format': 'wav',
        if (src.voice.trim().isNotEmpty) 'voice': src.voice.trim(),
        if (src.hiFi) 'sample_rate': 48000,
      },
    };
    // 附加参数（JSON 对象）合并进去，给用户留一个逃生口
    final extra = _jsonObject(src.extraParams);
    if (extra != null) data.addAll(extra);

    final dio = _synthDio(src, key);
    try {
      final r = await dio.post<dynamic>(
        '$base/chat/completions',
        data: data,
        options: Options(
          headers: {'Content-Type': 'application/json'},
          responseType: ResponseType.json,
          sendTimeout: Duration(seconds: src.timeoutSec),
          receiveTimeout: Duration(seconds: src.timeoutSec + 25),
        ),
      );
      final b64 = _pickBase64Audio(r.data);
      if (b64 == null) {
        throw '接口没有返回音频（响应里找不到 base64 音频字段）';
      }
      return base64Decode(b64.replaceAll(RegExp(r'\s'), ''));
    } on DioException catch (e) {
      throw _dioMsg(e);
    } finally {
      dio.close(force: true);
    }
  }

  /// OpenAI /audio/speech 兼容形状（siliconflow、gpt-sovits 网关等都照这个）
  Future<List<int>?> _synthesizeOpenAi(TtsSource src, String text,
      {String? voiceOverride}) async {
    final conn = await _resolveConn(src, 'tts-1', borrowModel: false);
    final base = conn.base;
    if (base.isEmpty) throw '接口地址为空';
    final key = conn.key;
    if (key.isEmpty) throw '未填 API Key';

    final voice = (voiceOverride != null && voiceOverride.trim().isNotEmpty)
        ? voiceOverride.trim()
        : (src.voice.trim().isEmpty ? 'alloy' : src.voice.trim());
    final fmt = _extOf(src.audioFormat);

    final data = <String, dynamic>{
      'model': conn.model,
      'input': text,
      'voice': voice,
      'response_format': fmt,
      // 只有用户明确打开「发送语速参数」才带 speed ——
      // 有的服务不认这个字段会整体 400
      if (src.sendsSpeed)
        'speed': (0.25 + rate.value * 1.75).clamp(0.25, 4.0),
    };
    final extra = _jsonObject(src.extraParams);
    if (extra != null) data.addAll(extra);

    final dio = _synthDio(src, key);
    try {
      final r = await dio.post<List<int>>(
        '$base/audio/speech',
        data: data,
        options: Options(
          headers: {'Content-Type': 'application/json'},
          responseType: ResponseType.bytes,
          sendTimeout: Duration(seconds: src.timeoutSec),
          receiveTimeout: Duration(seconds: src.timeoutSec + 25),
          validateStatus: (c) => c != null && c < 400,
        ),
      );
      return r.data;
    } on DioException catch (e) {
      throw _dioMsg(e);
    } finally {
      dio.close(force: true);
    }
  }

  /// Azure 语音服务 REST（SSML）。
  Future<List<int>?> _synthesizeAzure(TtsSource src, String text,
      {String? voiceOverride}) async {
    final key = await _keyOf(src);
    if (key.isEmpty) throw '未填 API Key';
    final voice = (voiceOverride != null && voiceOverride.trim().isNotEmpty)
        ? voiceOverride.trim()
        : (src.voice.trim().isEmpty
            ? 'zh-CN-XiaoxiaoNeural'
            : src.voice.trim());
    // 语速映射成 SSML prosody rate（0.5 → +0%，1.0 → +100%）
    final ratePct = ((rate.value - 0.5) / 0.5 * 100).round();
    final rateAttr = '${ratePct >= 0 ? '+' : ''}$ratePct%';
    final emotion = src.emotion.trim();
    final inner = '<prosody rate="$rateAttr">${_xmlEscape(text)}</prosody>';
    final ssml = '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" '
        'xmlns:mstts="https://www.w3.org/2001/mstts" xml:lang="zh-CN">'
        '<voice name="$voice">'
        '${emotion.isEmpty ? inner : '<mstts:express-as style="$emotion">$inner</mstts:express-as>'}'
        '</voice></speak>';

    final fmt = src.hiFi
        ? 'audio-48khz-96kbitrate-mono-mp3'
        : 'audio-24khz-48kbitrate-mono-mp3';

    final dio = _synthDio(src, key);
    try {
      final r = await dio.post<List<int>>(
        '${src.azureHost}/cognitiveservices/v1',
        data: ssml,
        options: Options(
          headers: {
            'Content-Type': 'application/ssml+xml',
            'X-Microsoft-OutputFormat': fmt,
            'User-Agent': 'TvBoxTts',
          },
          responseType: ResponseType.bytes,
          sendTimeout: Duration(seconds: src.timeoutSec),
          receiveTimeout: Duration(seconds: src.timeoutSec + 25),
          validateStatus: (c) => c != null && c < 400,
        ),
      );
      return r.data;
    } on DioException catch (e) {
      throw _dioMsg(e);
    } finally {
      dio.close(force: true);
    }
  }

  /// 合成用的 Dio：带 Bearer 鉴权 + 全局代理
  Dio _synthDio(TtsSource src, String key) {
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: src.timeoutSec),
      receiveTimeout: Duration(seconds: src.timeoutSec + 25),
      headers: {'Authorization': 'Bearer $key'},
    ));
    applyGlobalProxy(dio);
    return dio;
  }

  /// 把 `https://host/v1/` 归一成 `https://host/v1`；
  /// 用户填到 `/chat/completions` 或 `/audio/speech` 也一并削掉。
  static String _chatBase(String raw) {
    var b = raw.trim().replaceAll(RegExp(r'/+$'), '');
    const suffixes = [
      '/chat/completions',
      '/audio/speech',
      '/v1/audio/speech',
    ];
    for (final s in suffixes) {
      if (b.toLowerCase().endsWith(s)) {
        b = b.substring(0, b.length - s.length);
        break;
      }
    }
    return b.replaceAll(RegExp(r'/+$'), '');
  }

  /// 附加参数：合法 JSON 对象才合并，否则忽略（不阻塞朗读）
  static Map<String, dynamic>? _jsonObject(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    try {
      final m = jsonDecode(t);
      if (m is Map) return Map<String, dynamic>.from(m);
    } catch (_) {}
    return null;
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// 内置 Edge 朗读：直接打 App 自带的 Node（`/tts/edge`）。
  ///
  /// 不用填地址、不要 Key —— 协议和 DRM 令牌都在 Node 侧
  /// （`assets/nodejs-project/src/tts/`）。**不能挂全局代理**：
  /// 这是本机回环地址，走代理只会连不上。
  Future<List<int>?> _synthesizeEdge(TtsSource src, String text) async {
    final port = NodeJSManager.instance.managementPort;
    if (port <= 0) throw '内置服务未就绪，请稍后重试';
    final uri = Uri.parse('http://127.0.0.1:$port/tts/edge').replace(
      queryParameters: {
        'text': text,
        'voice': src.voice.trim().isEmpty
            ? 'zh-CN-XiaoxiaoNeural'
            : src.voice.trim(),
        'rate': _signedPct(((rate.value - 0.5) / 0.5 * 100).round()),
        'pitch': _signedHz(((pitch.value - 1.0) * 10).round()),
      },
    );
    final dio = Dio(
      BaseOptions(
        connectTimeout: Duration(seconds: src.timeoutSec),
        receiveTimeout: Duration(seconds: src.timeoutSec),
        responseType: ResponseType.bytes,
        validateStatus: (c) => c != null && c < 400,
      ),
    );
    try {
      final r = await dio.get<List<int>>(uri.toString());
      return r.data;
    } on DioException catch (e) {
      throw '内置合成失败：HTTP ${e.response?.statusCode ?? ''} ${e.message ?? e}';
    } finally {
      dio.close(force: true);
    }
  }

  /// 通用 HTTP 朗读源（2026-10-22，对齐 legado 的 httpTTS）：
  /// [TtsSource.endpoint] 直接写 URL 模板，支持占位符
  /// `{{speakText}}` / `{{text}}`（自动 URL 编码）与
  /// `{{speakSpeed}}` / `{{speed}}`（当前语速，如 1.00）。
  /// [TtsSource.extraParams] 可填 JSON 对象作为请求头。
  /// 返回音频字节（mp3/wav 均可，交给 media_kit 播放）。
  Future<List<int>?> _synthesizeHttp(
    TtsSource src,
    String text,
    double speed,
  ) async {
    final tpl = src.endpoint.trim();
    if (tpl.isEmpty) throw '未配置接口模板';
    final enc = Uri.encodeComponent(text);
    final sp = speed.toStringAsFixed(2);
    final url = tpl
        .replaceAll('{{speakText}}', enc)
        .replaceAll('{{text}}', enc)
        .replaceAll('{{speakSpeed}}', sp)
        .replaceAll('{{speed}}', sp);
    Map<String, dynamic> headers = const {};
    final hp = src.extraParams.trim();
    if (hp.isNotEmpty) {
      try {
        final m = jsonDecode(hp);
        if (m is Map) headers = Map<String, dynamic>.from(m);
      } catch (_) {
        // 头配置不是合法 JSON → 忽略，不阻塞朗读
      }
    }
    final dio = Dio(
      BaseOptions(
        connectTimeout: Duration(seconds: src.timeoutSec),
        receiveTimeout: Duration(seconds: src.timeoutSec),
        responseType: ResponseType.bytes,
        headers: headers,
        validateStatus: (c) => c != null && c < 400,
      ),
    );
    applyGlobalProxy(dio);
    try {
      final r = await dio.get<List<int>>(url);
      return r.data;
    } on DioException catch (e) {
      throw 'HTTP ${e.response?.statusCode ?? ''} ${e.message ?? e}';
    } finally {
      dio.close(force: true);
    }
  }

  /// EasyVoice 地址归一化：用户可能填
  /// `http://ip:3000`、`http://ip:3000/api/v1`、`http://ip:3000/api/v1/tts`
  /// 甚至完整复制到 `…/generateJson` —— 一律收敛成纯主机部分。
  ///
  /// 为什么要这个：EasyVoice 的路由现在**全部**在 `/api/v1/tts` 下
  /// （`routes/index.ts` 里 `app.use('/api/v1/tts', ttsRoutes)`），
  /// 用户按 README 填了带 `/api/v1` 的地址就会拼成 `/api/v1/api/v1/...`。
  static String easyVoiceBase(String raw) {
    var b = raw.trim().replaceAll(RegExp(r'/+$'), '');
    const suffixes = ['/api/v1/tts/generateJson', '/api/v1/tts', '/api/v1'];
    for (final s in suffixes) {
      if (b.toLowerCase().endsWith(s)) {
        b = b.substring(0, b.length - s.length);
        break;
      }
    }
    return b.replaceAll(RegExp(r'/+$'), '');
  }

  /// 语速必须是**带符号**的百分比（EasyVoice / Edge 都按这个解析）：
  /// `+20%` / `-40%` / `+0%`。原来发的是 `20%`，会被拒。
  static String _signedPct(int v) => '${v > 0 ? '+' : ''}$v%';

  /// 音调同理：`+10Hz` / `-20Hz` / `+0Hz`
  static String _signedHz(int v) => '${v > 0 ? '+' : ''}${v}Hz';

  /// 把 DioException 里的**服务端错误正文**带出来
  /// （EasyVoice 用 zod 校验，400 会返回 {errors:[{message,path}]}，
  ///  只显示 "status code of 400" 等于什么都没说）。
  static String _dioMsg(Object e) {
    if (e is DioException) {
      final d = e.response?.data;
      var body = '';
      if (d is List<int>) {
        body = utf8.decode(d, allowMalformed: true);
      } else if (d != null) {
        body = d.toString();
      }
      body = body.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (body.length > 300) body = '${body.substring(0, 300)}…';
      final code = e.response?.statusCode;
      if (body.isEmpty) return 'HTTP ${code ?? ''} ${e.message ?? ''}'.trim();
      return 'HTTP ${code ?? ''} · $body';
    }
    return '$e';
  }

  /// EasyVoice 合成：AI 推荐配音走任务接口，否则走 generateJson 直出 mp3
  /// [voiceOverride]（A4）：本段指定的音色（对话/旁白），非空时优先于源默认。
  Future<List<int>?> _synthesizeEasyVoice(TtsSource src, String text,
      {String? voiceOverride}) async {
    if (src.useAiVoice && src.aiVoiceAvailable) {
      try {
        return await _synthesizeEasyVoiceAi(src, text,
            voiceOverride: voiceOverride);
      } catch (e) {
        // AI 推荐要服务端配 OPENAI_BASE_URL / OPENAI_API_KEY / MODEL_NAME；
        // 没配或接口不可用就**自动回退普通合成**，至少能出声。
        lastError.value = 'AI 推荐配音不可用，已改用普通合成：${_dioMsg(e)}';
      }
    }
    final base = easyVoiceBase(src.endpoint);
    if (base.isEmpty) throw '接口地址为空';
    final ratePct = _signedPct(((rate.value - 0.5) / 0.5 * 100).round());
    final pitchHz = _signedHz(((pitch.value - 1.0) * 10).round());
    final voice = (voiceOverride != null && voiceOverride.trim().isNotEmpty)
        ? voiceOverride.trim()
        : (src.voice.trim().isEmpty ? 'zh-CN-XiaoxiaoNeural' : src.voice.trim());
    try {
      final r = await _dio.post<List<int>>(
        '$base/api/v1/tts/generateJson',
        data: {
          'data': [
            {
              // A4 双音色：有覆盖标「对话」，否则「旁白」（EasyVoice 语义）
              'desc': voiceOverride == null ? '旁白' : '对话',
              'text': text,
              'voice': voice,
              'rate': ratePct,
              'pitch': pitchHz,
              'volume': '+0%',
            },
          ],
        },
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Content-Type': 'application/json'},
          sendTimeout: Duration(seconds: src.timeoutSec),
          receiveTimeout: Duration(seconds: src.timeoutSec + 10),
        ),
      );
      return r.data;
    } catch (e) {
      throw _dioMsg(e);
    }
  }

  /// EasyVoice「AI 智能推荐配音」（useLLM=true）：
  /// GET  /api/v1/tts/llmConfig 探服务端有没有配大模型 →
  /// POST /api/v1/tts/create 建任务 → 轮询 /api/v1/tts/task/{id} →
  /// 完成后 GET /api/v1/tts/download/{file} 取整段 mp3（多角色有声书）。
  Future<List<int>?> _synthesizeEasyVoiceAi(TtsSource src, String text,
      {String? voiceOverride}) async {
    final base = easyVoiceBase(src.endpoint);
    if (base.isEmpty) throw '接口地址为空';

    // 先探一下服务端的大模型配置：没配的话 /create 必然 400，
    // 直接给出人话，省得用户对着一串 zod 报错发愣。
    try {
      final cfg = await _dio.get<Map<String, dynamic>>(
        '$base/api/v1/tts/llmConfig',
        options: Options(receiveTimeout: const Duration(seconds: 10)),
      );
      final data = cfg.data?['data'];
      if (data is Map && data['available'] == false) {
        throw '自建实例没有配置大模型（需要环境变量 OPENAI_BASE_URL / '
            'OPENAI_API_KEY / MODEL_NAME）';
      }
    } catch (e) {
      if (e is String) rethrow;
      // 老版本没有 /llmConfig 接口 → 忽略探测，照旧试 /create
    }

    final body = <String, dynamic>{
      'text': text,
      'useLLM': true,
    };
    // 用户手填了音色 → 带上让服务端优先用；空则由大模型推荐
    // A4：本段有音色覆盖（对话/旁白）时优先传它
    final v = (voiceOverride != null && voiceOverride.trim().isNotEmpty)
        ? voiceOverride.trim()
        : src.voice.trim();
    if (v.isNotEmpty) body['voice'] = v;

    final create = await _dio.post<Map<String, dynamic>>(
      '$base/api/v1/tts/create',
      data: body,
      options: Options(
        headers: {'Content-Type': 'application/json'},
        sendTimeout: Duration(seconds: src.timeoutSec),
        receiveTimeout: Duration(seconds: src.timeoutSec + 10),
      ),
    );
    final cdata = create.data;
    final taskId = (cdata?['data'] is Map)
        ? ((cdata!['data'] as Map)['id']?.toString() ?? '')
        : '';
    if (taskId.isEmpty) throw 'EasyVoice 未返回任务 ID';

    // 轮询任务状态（2s 间隔，最长 180s）
    final deadline = DateTime.now().add(const Duration(seconds: 180));
    while (DateTime.now().isBefore(deadline)) {
      if (_stopRequested) throw '已停止朗读';
      await Future.delayed(const Duration(seconds: 2));
      final r = await _dio.get<Map<String, dynamic>>(
        '$base/api/v1/tts/task/$taskId',
        options: Options(receiveTimeout: const Duration(seconds: 20)),
      );
      final d = r.data?['data'];
      if (d is! Map) continue;
      final status = (d['status']?.toString() ?? '').toLowerCase();
      final result = d['result'];
      if (result is Map) {
        final file = result['file']?.toString() ??
            result['audio']?.toString() ??
            '';
        if (file.isNotEmpty) {
          final dl = await _dio.get<List<int>>(
            '$base/api/v1/tts/download/$file',
            options: Options(
              responseType: ResponseType.bytes,
              receiveTimeout: const Duration(seconds: 90),
            ),
          );
          return dl.data;
        }
      }
      if (status == 'failed' || status == 'error') {
        final msg = d['message']?.toString() ?? '合成失败';
        throw 'EasyVoice 任务失败：$msg';
      }
      if (status == 'completed' || status == 'done' || status == 'success') {
        throw 'EasyVoice 任务完成但没有音频文件';
      }
    }
    throw 'EasyVoice 合成超时（180s），请稍后重试';
  }

  /// 把合成好的 mp3 写临时文件交给 media_kit 播放
  Future<void> _playNetBytes(List<int> bytes, {String ext = 'mp3'}) async {
    final p = _ensureNetPlayer();
    final f = File(
        '${Directory.systemTemp.path}/tts_${DateTime.now().millisecondsSinceEpoch}.$ext');
    await f.writeAsBytes(bytes, flush: true);
    _clearNetTmp();
    _netTmpFile = f;
    await p.open(Media(f.uri.toString()), play: true);
    await p.setRate(_netPlaybackRate());
  }

  /// 懒建网络播放器；播放完成回调推进到下一段
  Player _ensureNetPlayer() {
    if (_netPlayer != null) return _netPlayer!;
    final p = Player();
    _netCompleteSub = p.stream.completed.listen((done) {
      if (done) _onSegmentDone();
    });
    _netPlayer = p;
    return p;
  }

  void _clearNetTmp() {
    final f = _netTmpFile;
    _netTmpFile = null;
    if (f != null && f.existsSync()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }

  /// 朗读面板语速 0.1~1.0（0.5=正常）→ 播放器倍速（1.0=正常）
  double _netPlaybackRate() {
    final r = rate.value.clamp(0.1, 1.0) / 0.5;
    return r.clamp(0.2, 2.0);
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
      _stopSegClock();
      _updateNowPlaying(playing: false);
      final cb = onFinished;
      if (cb != null) cb();
      return;
    }
    currentIndex.value = next;
    // 上一段念完：段内进度清零，等 `_speakCurrent` / `_speakNetworkCurrent`
    // 真正开口时再起表（网络源合成还要几百毫秒，不能提前算）。
    segmentProgress.value = 0;
    _updateNowPlaying();
    // 🔴🔴 这里原来**无条件**调 `_speakCurrent()`（= 系统朗读）🔴🔴
    //
    // 用户 2026-10-29：「AI听书为啥读一段下一段又是系统朗读？」
    // 就是这行造成的：`speak()` 的第一段走 `_speakNetworkCurrent()`（AI 音色），
    // 播完之后进到这里 → 直接切系统朗读念第二段 → 再进这里 → 系统朗读第三段…
    // 于是"只有第一段是 AI"，听起来就是「读一段、下一段变系统朗读」。
    //
    // 正确做法：**每个段落开始时重新对齐一次当前源**（用户在朗读过程中换了引擎
    // 也能从下一段生效），再按 `_useNet` 决定走哪条分支。
    _syncNetSource();
    if (_useNet) {
      // 网络合成是异步的，不能 await（这里在原生/播放器回调里）
      unawaited(_speakNetworkCurrent());
    } else {
      _speakCurrent();
    }
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
