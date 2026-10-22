import 'package:flutter/foundation.dart';

/// 一个「朗读源」—— 系统朗读之外的第二条发声路径。
///
/// ── 为什么要有这个 ────────────────────────────────────────────
/// 系统 TTS 免费、离线，但音色一般。截图里那 4 种源就是为了音色：
///
///   | 类型 | 协议 | 特点 |
///   |---|---|---|
///   | `network`  | 网络导入 engine.json | 别人配好的引擎定义 |
///   | `azure`    | Azure 语音服务 REST   | 音色多、稳定，要 API Key |
///   | `mimo`     | 小米 MiMo chat 接口   | **没有语速字段**（见下）|
///   | `openai`   | OpenAI /audio/speech  | 通用形状，各家兼容服务都能接 |
///   | `easyvoice`| EasyVoice 免费服务（Edge-TTS）| 自部署或公共实例，HTTP 返回 mp3，无需 API Key |
///
/// ⚠️ **MiMo 的关键差异**（截图里的原话）：
///   "MiMo 的语音合成走 chat 接口：正文作为 assistant 消息发送，
///    风格指令作为 user 消息。它**没有语速字段**，所以朗读面板里的
///    语速滑杆对本源无效 —— 想调快慢请写进上面的风格指令。
///    音频按 base64 返回，格式固定 wav。"
///
/// 所以「发送语速参数」这个开关只对 openai 类型有意义（见 [sendsSpeed]）。
@immutable
class TtsSource {
  const TtsSource({
    required this.id,
    required this.type,
    required this.name,
    this.endpoint = '',
    this.region = '',
    this.customHost = '',
    this.modelId = '',
    this.voice = '',
    this.audioFormat = 'mp3',
    this.stylePrompt = '',
    this.styleTag = '',
    this.emotion = '',
    this.extraParams = '',
    this.hiFi = false,
    this.sendsSpeed = false,
    // EasyVoice「AI 智能推荐配音」：让服务端用大模型自动分角色/音色
    this.useAiVoice = false,
    // ── 调优 ────────────────────────────────────────────────
    this.maxConcurrency = 2,
    this.minIntervalMs = 200,
    this.prefetchSentences = 3,
    this.timeoutSec = 15,
    this.maxRetries = 2,
    this.maxChars = 300,
    this.fallbackToSystem = true,
    this.wifiOnly = false,
  });

  /// 稳定 id（新建时按时间戳生成）
  final String id;

  /// `network` / `azure` / `mimo` / `openai` / `easyvoice`
  final String type;

  final String name;

  /// 接口地址（openai / mimo / network 用）
  final String endpoint;

  /// Azure 区域（如 `eastasia`）
  final String region;

  /// Azure 自定义主机（留空按区域自动拼；主权云填完整地址）
  final String customHost;

  /// 模型 ID
  final String modelId;

  /// 音色标识（如 `zh-CN-XiaoxiaoNeural` / `alloy`）
  final String voice;

  /// 音频格式（openai 用）
  final String audioFormat;

  /// MiMo 风格指令（自然语言，如「用慵懒的语气，语速稍慢」）
  final String stylePrompt;

  /// MiMo 风格标签（加在每句正文最前，如「(开心)」）
  final String styleTag;

  /// Azure 情绪风格
  final String emotion;

  /// 附加参数（JSON 对象，如 `{"emotion":"happy"}`）
  final String extraParams;

  /// 高保真音质（48kHz，默认 24kHz，流量约翻倍）
  final bool hiFi;

  /// 是否把语速作为 `speed` 字段发送。
  ///
  /// ⚠️ 有的服务不认这个字段会**整体报错**，那就关掉。
  /// MiMo 永远不发送（它没有语速字段，见类文档）。
  final bool sendsSpeed;

  /// EasyVoice「AI 智能推荐配音」（useLLM=true）。
  ///
  /// 开启后朗读交给 EasyVoice 的大模型：自动把文本按角色分段、
  /// 推荐音色/语速/音调（多角色有声书效果）；关闭则用 [voice]
  /// 固定音色直接合成（更快）。
  final bool useAiVoice;

  /// 只有 easyvoice 支持 AI 推荐配音
  bool get aiVoiceAvailable => type == 'easyvoice';

  // ── 调优 ──────────────────────────────────────────────────
  /// 并发上限：同时在飞的请求数
  final int maxConcurrency;
  /// 最小请求间隔（ms）：两次请求之间至少等这么久，专治 429
  final int minIntervalMs;
  /// 预取句数：提前合成几句备用
  final int prefetchSentences;
  /// 请求超时（秒）
  final int timeoutSec;
  /// 失败重试次数（仅超时 / 429 / 5xx 重试）
  final int maxRetries;
  /// 单次最大字数（超长句拆开发）
  final int maxChars;
  /// 失败自动降级：连不上或额度用完时切回系统朗读
  final bool fallbackToSystem;
  /// 仅 Wi-Fi 使用
  final bool wifiOnly;

  /// MiMo 走 chat 接口，没有语速字段 —— 语速滑杆对它无效。
  bool get speedIsMeaningful => type != 'mimo';

  /// 这个类型才需要「发送语速参数」开关（截图里只有 OpenAI 兼容有）。
  bool get showSpeedToggle => type == 'openai';

  /// Azure 的实际请求主机
  String get azureHost {
    if (customHost.trim().isNotEmpty) return customHost.trim();
    final r = region.trim().isEmpty ? 'eastasia' : region.trim();
    return 'https://$r.tts.speech.microsoft.com';
  }

  /// 每种类型的默认值（「朗读源类型」弹层里选完就带出这些）
  static TtsSource blank(String type) {
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    switch (type) {
      case 'azure':
        return TtsSource(
          id: ts,
          type: type,
          name: '微软 Azure',
          region: 'eastasia',
          voice: 'zh-CN-XiaoxiaoNeural',
          maxRetries: 2,
        );
      case 'mimo':
        return TtsSource(
          id: ts,
          type: type,
          name: '小米 MiMo',
          endpoint: 'https://api.xiaomimimo.com/v1',
          modelId: 'mimo-v2.5-tts',
          audioFormat: 'wav',
          sendsSpeed: false,
        );
      case 'openai':
        return TtsSource(
          id: ts,
          type: type,
          name: 'OpenAI 兼容',
          endpoint: 'https://.../v1',
          modelId: 'tts-1',
          voice: 'alloy',
          audioFormat: 'mp3',
          extraParams: '{"emotion":"happy"}',
        );
      case 'easyvoice':
        return TtsSource(
          id: ts,
          type: type,
          name: 'EasyVoice 免费',
          endpoint: 'http://192.168.1.100:3000',
          voice: 'zh-CN-XiaoxiaoNeural',
          audioFormat: 'mp3',
          useAiVoice: true, // 默认打开 AI 智能推荐配音（多角色有声书）
          maxRetries: 2,
        );
      case 'http':
        return TtsSource(
          id: ts,
          type: type,
          name: '自定义 HTTP',
          endpoint: 'https://host/tts?text={{speakText}}&speed={{speakSpeed}}',
          audioFormat: 'mp3',
          timeoutSec: 20,
        );
      default: // network
        return TtsSource(id: ts, type: 'network', name: '网络导入');
    }
  }

  String get typeLabel {
    switch (type) {
      case 'azure':
        return '微软 Azure 语音服务';
      case 'mimo':
        return '小米 MiMo（限时免费）';
      case 'openai':
        return 'OpenAI 兼容（/audio/speech 接口）';
      case 'easyvoice':
        return 'EasyVoice（免费 Edge-TTS 服务）';
      case 'http':
        return '自定义 HTTP（URL 模板）';
      default:
        return '网络导入';
    }
  }

  TtsSource copyWith({
    String? name,
    String? endpoint,
    String? region,
    String? customHost,
    String? modelId,
    String? voice,
    String? audioFormat,
    String? stylePrompt,
    String? styleTag,
    String? emotion,
    String? extraParams,
    bool? hiFi,
    bool? sendsSpeed,
    bool? useAiVoice,
    int? maxConcurrency,
    int? minIntervalMs,
    int? prefetchSentences,
    int? timeoutSec,
    int? maxRetries,
    int? maxChars,
    bool? fallbackToSystem,
    bool? wifiOnly,
  }) {
    return TtsSource(
      id: id,
      type: type,
      name: name ?? this.name,
      endpoint: endpoint ?? this.endpoint,
      region: region ?? this.region,
      customHost: customHost ?? this.customHost,
      modelId: modelId ?? this.modelId,
      voice: voice ?? this.voice,
      audioFormat: audioFormat ?? this.audioFormat,
      stylePrompt: stylePrompt ?? this.stylePrompt,
      styleTag: styleTag ?? this.styleTag,
      emotion: emotion ?? this.emotion,
      extraParams: extraParams ?? this.extraParams,
      hiFi: hiFi ?? this.hiFi,
      sendsSpeed: sendsSpeed ?? this.sendsSpeed,
      useAiVoice: useAiVoice ?? this.useAiVoice,
      maxConcurrency: maxConcurrency ?? this.maxConcurrency,
      minIntervalMs: minIntervalMs ?? this.minIntervalMs,
      prefetchSentences: prefetchSentences ?? this.prefetchSentences,
      timeoutSec: timeoutSec ?? this.timeoutSec,
      maxRetries: maxRetries ?? this.maxRetries,
      maxChars: maxChars ?? this.maxChars,
      fallbackToSystem: fallbackToSystem ?? this.fallbackToSystem,
      wifiOnly: wifiOnly ?? this.wifiOnly,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'name': name,
        'endpoint': endpoint,
        'region': region,
        'customHost': customHost,
        'modelId': modelId,
        'voice': voice,
        'audioFormat': audioFormat,
        'stylePrompt': stylePrompt,
        'styleTag': styleTag,
        'emotion': emotion,
        'extraParams': extraParams,
        'hiFi': hiFi,
        'sendsSpeed': sendsSpeed,
        'useAiVoice': useAiVoice,
        'maxConcurrency': maxConcurrency,
        'minIntervalMs': minIntervalMs,
        'prefetchSentences': prefetchSentences,
        'timeoutSec': timeoutSec,
        'maxRetries': maxRetries,
        'maxChars': maxChars,
        'fallbackToSystem': fallbackToSystem,
        'wifiOnly': wifiOnly,
        // ⚠️ API Key **不写进这里** —— 截图原话：
        // "API Key 存在系统密钥库里，不写进配置、也不进备份。
        //  换机后需要重填一次。"
      };

  static TtsSource fromJson(Map<String, dynamic> j) => TtsSource(
        id: (j['id'] ?? '').toString(),
        type: (j['type'] ?? 'network').toString(),
        name: (j['name'] ?? '未命名').toString(),
        endpoint: (j['endpoint'] ?? '').toString(),
        region: (j['region'] ?? '').toString(),
        customHost: (j['customHost'] ?? '').toString(),
        modelId: (j['modelId'] ?? '').toString(),
        voice: (j['voice'] ?? '').toString(),
        audioFormat: (j['audioFormat'] ?? 'mp3').toString(),
        stylePrompt: (j['stylePrompt'] ?? '').toString(),
        styleTag: (j['styleTag'] ?? '').toString(),
        emotion: (j['emotion'] ?? '').toString(),
        extraParams: (j['extraParams'] ?? '').toString(),
        hiFi: j['hiFi'] == true,
        sendsSpeed: j['sendsSpeed'] == true,
        useAiVoice: j['useAiVoice'] == true,
        maxConcurrency: (j['maxConcurrency'] as num?)?.toInt() ?? 2,
        minIntervalMs: (j['minIntervalMs'] as num?)?.toInt() ?? 200,
        prefetchSentences: (j['prefetchSentences'] as num?)?.toInt() ?? 3,
        timeoutSec: (j['timeoutSec'] as num?)?.toInt() ?? 15,
        maxRetries: (j['maxRetries'] as num?)?.toInt() ?? 2,
        maxChars: (j['maxChars'] as num?)?.toInt() ?? 300,
        fallbackToSystem: j['fallbackToSystem'] != false,
        wifiOnly: j['wifiOnly'] == true,
      );
}
