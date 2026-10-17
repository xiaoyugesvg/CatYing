import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

import '../models/tts_source.dart';
import '../source/global_proxy.dart';
import 'tts_now_playing.dart';
import 'tts_source_store.dart';

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
/// ── 网络朗读源（EasyVoice）─────────────────────────────────────
/// 「朗读引擎」页里把某个 `easyvoice` 源设为「当前使用」后，朗读会改走
/// **HTTP 合成 + media_kit 播放**（dio / media_kit 都已在项目依赖里，
/// 零新增原生插件）：
///   · 每段 POST `/api/v1/tts/generateJson`（Edge-TTS 免费音色）拿 mp3；
///   · media_kit 播放该 mp3，念完自动下一段，高亮照旧；
///   · 暂停 / 继续 / 停止 / 跳段 / 倍速全部由播放器接管；
///   · 合成失败时按源的「失败自动降级」开关切回系统朗读继续读。
/// 其余类型（azure/mimo/openai）只做了配置校验，合成尚未接入，
/// 朗读始终走系统引擎。
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
    // 刷新当前朗读源：朗读引擎页里选中的 easyvoice 源生效，否则原生
    await TtsSourceStore.instance.init();
    final active = TtsSourceStore.instance.active;
    _netSource = (active != null && active.type == 'easyvoice') ? active : null;
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
    if (_netSource != null) {
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
    if (_netSource != null && !_netSynthesizing) {
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
    isSpeaking.value = true;
    isPaused.value = false;
    _updateNowPlaying(playing: true);
    if (_netSource != null) {
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
    if (_netSource != null) {
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
    if (_netSource != null) {
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
    if (_netSource != null) {
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
    if (_netSource != null) return;
    if (isSpeaking.value) await _speakCurrent();
  }

  // ============================================================
  // 内部
  // ============================================================

  /// 逐段音色覆盖（A4 双音色，与 [_segments] 对齐；null = 用源默认音色）
  List<String?>? _segmentVoices;

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
    if (src == null) {
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
      final bytes = await _synthesizeEasyVoice(src, seg,
          voiceOverride: segVoice);
      _netSynthesizing = false;
      if (_stopRequested) return;
      if (bytes == null || bytes.isEmpty) throw '服务返回空音频';
      if (!isSpeaking.value) return; // 合成期间被暂停/停止
      await _playNetBytes(bytes);
    } catch (e) {
      _netSynthesizing = false;
      if (_stopRequested) return;
      if (src.fallbackToSystem) {
        // 合成失败 → 按源开关切回系统朗读继续读，提示一次
        lastError.value = 'EasyVoice 合成失败，已切回系统朗读：$e';
        isSpeaking.value = true;
        isPaused.value = false;
        await _speakCurrent();
      } else {
        lastError.value = '合成失败：$e';
        isSpeaking.value = false;
      }
    }
  }

  /// EasyVoice 合成：AI 推荐配音走任务接口，否则走 generateJson 直出 mp3
  /// [voiceOverride]（A4）：本段指定的音色（对话/旁白），非空时优先于源默认。
  Future<List<int>?> _synthesizeEasyVoice(TtsSource src, String text,
      {String? voiceOverride}) async {
    if (src.useAiVoice && src.aiVoiceAvailable) {
      return _synthesizeEasyVoiceAi(src, text,
          voiceOverride: voiceOverride);
    }
    final base = src.endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) throw '接口地址为空';
    final ratePct = '${(((rate.value - 0.5) / 0.5) * 100).round()}%';
    final pitchHz = '${((pitch.value - 1.0) * 10).round()}Hz';
    final voice = (voiceOverride != null && voiceOverride.trim().isNotEmpty)
        ? voiceOverride.trim()
        : (src.voice.trim().isEmpty ? 'zh-CN-XiaoxiaoNeural' : src.voice.trim());
    final r = await _dio.post<List<int>>(
      '$base/api/v1/tts/generateJson',
      data: {
        'data': [
          {
            // A4 双音色：有覆盖标「对话」，否则「旁白」（EasyVoice 语义）✓
            'desc': voiceOverride == null ? '旁白' : '对话',
            'text': text,
            'voice': voice,
            'rate': ratePct,
            'pitch': pitchHz,
            'volume': '0%',
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
  }

  /// EasyVoice「AI 智能推荐配音」（useLLM=true）：
  /// POST /api/v1/create 建任务 → 轮询 /api/v1/task/{id} →
  /// 完成后 GET /api/v1/download/{file} 取整段 mp3（多角色有声书）。
  Future<List<int>?> _synthesizeEasyVoiceAi(TtsSource src, String text,
      {String? voiceOverride}) async {
    final base = src.endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) throw '接口地址为空';
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
      '$base/api/v1/create',
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
        '$base/api/v1/task/$taskId',
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
            '$base/api/v1/download/$file',
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
  Future<void> _playNetBytes(List<int> bytes) async {
    final p = _ensureNetPlayer();
    final f = File(
        '${Directory.systemTemp.path}/tts_${DateTime.now().millisecondsSinceEpoch}.mp3');
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
      _updateNowPlaying(playing: false);
      final cb = onFinished;
      if (cb != null) cb();
      return;
    }
    currentIndex.value = next;
    _updateNowPlaying();
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
