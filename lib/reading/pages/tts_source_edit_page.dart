import 'package:dio/dio.dart';
import '../source/global_proxy.dart';
import 'package:flutter/material.dart';

import '../models/tts_source.dart';
import '../services/tts_service.dart';
import '../services/tts_source_store.dart';
import '../theme/jelly_theme.dart';
import '../../common/theme.dart';
import '../../services/nodejs_manager.dart';

/// 添加 / 编辑朗读源（截图 IMG_8102~8110）。
///
/// ── 页面结构 ──────────────────────────────────────────────────
///   连接    ：名称 / (区域|接口地址) / (自定义主机|模型 ID) / API Key
///   音色    ：音色 / 情绪风格 / 高保真音质         ← azure
///   音色与风格：音色 / 风格指令 / 风格标签          ← mimo
///   音色与格式：音色 / 音频格式 / 发送语速参数 / 附加参数 ← openai
///   调优    ：并发上限 / 最小请求间隔 / 预取句数 / 请求超时 /
///             失败重试 / 单次最大字数 / 失败自动降级 / 仅 Wi-Fi
///   测试    ：测试连接
///
/// **三种类型共用一个页面**、字段按类型增减 —— 不写三份几乎一样的表单。
class TtsSourceEditPage extends StatefulWidget {
  const TtsSourceEditPage({super.key, required this.source});

  final TtsSource source;

  @override
  State<TtsSourceEditPage> createState() => _TtsSourceEditPageState();
}

class _TtsSourceEditPageState extends State<TtsSourceEditPage> {
  late TtsSource _s;
  final _name = TextEditingController();
  final _endpoint = TextEditingController();
  final _region = TextEditingController();
  final _customHost = TextEditingController();
  final _modelId = TextEditingController();
  final _voice = TextEditingController();
  final _stylePrompt = TextEditingController();
  final _styleTag = TextEditingController();
  final _extraParams = TextEditingController();
  final _apiKey = TextEditingController();
  // 🔴 这两个原来是在 `build` 里**每次重建都 new 一个** ✗（见下面「情绪风格」/
  // 「音频格式」两行 ✓）→ 拖动/输入每帧泄漏一个 controller ✓。
  // ✓ 改成与上面 10 个同款的**持久字段** ✓，并在 `dispose()` 的循环里一并释放 ✓。
  // 它们是**只读展示**用（`readOnly: true` ✓），所以调用处用
  // `..text = …` 级联**每次重建同步一次** ✓，不会显示旧值 ✓
  final _emotion = TextEditingController();
  final _audioFormat = TextEditingController();

  bool _busy = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _s = widget.source;
    _name.text = _s.name;
    _endpoint.text = _s.endpoint;
    _region.text = _s.region;
    _customHost.text = _s.customHost;
    _modelId.text = _s.modelId;
    _voice.text = _s.voice;
    _stylePrompt.text = _s.stylePrompt;
    _styleTag.text = _s.styleTag;
    _extraParams.text = _s.extraParams;
    // 回填已存的 Key 方便核对（Key 不在源配置里，见 store 文档）
    TtsSourceStore.instance.apiKey(_s.id).then((v) {
      if (mounted) setState(() => _apiKey.text = v);
    });
  }

  @override
  void dispose() {
    for (final c in [
      _name, _endpoint, _region, _customHost, _modelId, _voice,
      _stylePrompt, _styleTag, _extraParams, _apiKey,
      _emotion, _audioFormat, // ← 新加的两个也必须在这里释放 ✓（否则等于换个地方泄漏 ✗）
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final isNew = !TtsSourceStore.instance.all.any((e) => e.id == _s.id);
    final built = _s.copyWith(
      name: _name.text.trim(),
      endpoint: _endpoint.text.trim(),
      region: _region.text.trim(),
      customHost: _customHost.text.trim(),
      modelId: _modelId.text.trim(),
      voice: _voice.text.trim(),
      stylePrompt: _stylePrompt.text.trim(),
      styleTag: _styleTag.text.trim(),
      extraParams: _extraParams.text.trim(),
    );
    await TtsSourceStore.instance.upsert(built, apiKey: _apiKey.text);
    // 新建的源保存后直接设为「当前使用」，配完即可朗读
    if (isNew) await TtsSourceStore.instance.setActive(built.id);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  /// 「测试连接」。
  ///
  /// easyvoice 会**真发一次合成请求**并校验返回的音频字节（mp3 魔数）；
  /// 其余类型只做到**校验配置完整性并如实报告**，不假装"测试成功"。
  Future<void> _test() async {
    final problems = <String>[];
    if (_s.type == 'azure') {
      if (_region.text.trim().isEmpty && _customHost.text.trim().isEmpty) {
        problems.add('区域或自定义主机至少填一个');
      }
      if (_voice.text.trim().isEmpty) problems.add('音色没填');
    } else if (_s.type == 'mimo' || _s.type == 'openai') {
      if (_endpoint.text.trim().isEmpty) problems.add('接口地址没填');
      if (_modelId.text.trim().isEmpty) problems.add('模型 ID 没填');
    } else if (_s.type == 'http') {
      if (_endpoint.text.trim().isEmpty) problems.add('接口模板没填');
    } else if (_s.type == 'easyvoice') {
      if (_endpoint.text.trim().isEmpty) problems.add('接口地址没填');
      // AI 推荐配音模式下音色可留空（由大模型推荐）
      if (_voice.text.trim().isEmpty && !_s.useAiVoice) problems.add('音色没填');
    }
    if (_apiKey.text.trim().isEmpty &&
        _s.type != 'easyvoice' &&
        _s.type != 'http' &&
        _s.type != 'edge') {
      problems.add('API Key 没填');
    }
    if (problems.isNotEmpty) {
      setState(() {
        _testResult = '还差这些：\n· ${problems.join('\n· ')}';
      });
      return;
    }

    // edge：打本机 Node 的 /tts/edge，真合成一句并校验 mp3 魔数
    if (_s.type == 'edge') {
      setState(() {
        _busy = true;
        _testResult = '正在请求内置合成…';
      });
      try {
        final bytes = await _requestEdge('这是一个测试。');
        final okMagic = bytes.length > 4 &&
            ((bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) ||
                (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0));
        if (!mounted) return;
        setState(() {
          _busy = false;
          _testResult = okMagic
              ? '连通：返回 ${(bytes.length / 1024).toStringAsFixed(0)} KB mp3，'
                  '音色 ${_voice.text.trim()}。'
              : '返回了内容但不是音频（${bytes.length} 字节）。'
                  '多半是没联网，或微软接口暂时不可达。';
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _testResult = '请求失败：$e\n\n检查：手机是否能上网（国内网络可能需要代理）。';
        });
      }
      return;
    }

    // easyvoice：真发一次合成请求（免费服务无需 Key）
    if (_s.type == 'easyvoice') {
      setState(() {
        _busy = true;
        _testResult = '正在请求合成…';
      });
      try {
        final r = await _requestEasyVoice('这是一个测试。', timeoutSec: 12);
        final bytes = r ?? [];
        final okMagic = bytes.length > 4 &&
            ((bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) || // ID3
                (bytes[0] == 0xFF && bytes[1] == 0xFB)); // FFD8 mp3 帧
        if (!mounted) return;
        setState(() {
          _busy = false;
          _testResult = okMagic
              ? '连通：返回 ${(bytes.length / 1024).toStringAsFixed(0)} KB mp3，'
                  '音色 ${_voice.text.trim()}。\n保存后即可在朗读面板使用。'
              : '服务返回了内容但不是音频（${bytes.length} 字节，'
                  '开头 ${bytes.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}）。\n'
                  '检查 endpoint 是否指向 EasyVoice（如 http://ip:3000）。';
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _testResult = '请求失败：$e\n\n检查：\n'
              '· endpoint 是否带端口且可达（局域网 http://ip:3000）\n'
              '· 服务是否已 docker 启动（cosincox/easyvoice:latest）';
        });
      }
      return;
    }

    setState(() {
      _testResult = '配置完整。\n\n此类型真正的合成请求需要音频播放器'
          '（当前只接入了 EasyVoice），所以这里只校验配置，不谎报"连通"。';
    });
  }

  /// 内置 Edge 合成：打本机 Node 的 `/tts/edge`（不走全局代理）
  Future<List<int>> _requestEdge(String text) async {
    final port = NodeJSManager.instance.managementPort;
    if (port <= 0) throw '内置服务未就绪（Node 还没起来）';
    final uri = Uri.parse('http://127.0.0.1:$port/tts/edge').replace(
      queryParameters: {
        'text': text,
        'voice': _voice.text.trim().isEmpty
            ? 'zh-CN-XiaoxiaoNeural'
            : _voice.text.trim(),
      },
    );
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 25),
        responseType: ResponseType.bytes,
        validateStatus: (c) => c != null && c < 400,
      ),
    );
    try {
      final r = await dio.get<List<int>>(uri.toString());
      return r.data ?? const [];
    } finally {
      dio.close(force: true);
    }
  }

  /// EasyVoice 合成：POST /api/v1/tts/generateJson → mp3 字节。
  /// 返回 null 表示响应为空。
  Future<List<int>?> _requestEasyVoice(String text,
      {int? timeoutSec}) async {
    // 与运行时同一套归一化：填 ip:3000 / …/api/v1 / …/api/v1/tts 都行
    final base = TtsService.easyVoiceBase(_endpoint.text);
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: Duration(seconds: timeoutSec ?? 20),
    ));
    // ✅ **「测试合成」也走「网络代理」**（本轮接上 ✓）—— 这处就是朗读引擎页里
    //   「**测试**」按钮发出的那次 `POST /api/v1/tts/generateJson` ✓（拿 mp3 校验 ✓）。
    //   ℹ️ 安全依据 ✓：本处 **`Dio(BaseOptions(...))` 纯构造** ✗✓（无自定义适配器 / UA ✓）
    //     → 挂代理不影响任何东西 ✓
    //   · 代理**关闭** ✓ → 返回 false ✓ **一行不改** ✓（与从前完全一致 ✓✓）
    applyGlobalProxy(dio);
    final r = await dio.post<List<int>>(
      '$base/api/v1/tts/generateJson',
      data: {
        'data': [
          {
            'desc': '旁白',
            'text': text,
            'voice': _voice.text.trim().isEmpty
                ? 'zh-CN-XiaoxiaoNeural'
                : _voice.text.trim(),
            'rate': '0%',
            'pitch': '0Hz',
            'volume': '0%',
          },
        ],
      },
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Content-Type': 'application/json'},
      ),
    );
    return r.data ?? <int>[];
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Scaffold(
      backgroundColor:
          isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          _s.name.isEmpty ? '添加朗读源' : _s.name,
          style: TextStyle(
              fontSize: AppTheme.fontTitle3, fontWeight: FontWeight.w700, color: label),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : _save,
            child: const Text('保存', style: TextStyle(fontSize: AppTheme.fontHeadline)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          // ── 连接 ────────────────────────────────────────────
          _card(isDark, '连接', [
            _row('名称', _name, hint: _s.typeLabel),
            if (_s.type == 'azure') ...[
              _row('区域', _region, hint: 'eastasia', chevron: true),
              _row('自定义主机', _customHost,
                  hint: '留空按区域自动拼；主权云填完整地址'),
            ] else if (_s.type == 'http') ...[
              _row('接口模板', _endpoint,
                  hint: 'https://host/tts?text={{speakText}}&speed={{speakSpeed}}'),
              _row('请求头（JSON）', _extraParams,
                  hint: '{"Authorization":"Bearer xxx"}，可留空'),
              _note('URL 模板支持占位符：{{speakText}} / {{text}}（自动 URL 编码）、'
                  '{{speakSpeed}} / {{speed}}（当前语速）。'
                  '服务返回音频字节即可（mp3/wav），对齐 legado 的 httpTTS。'),
            ] else if (_s.type == 'easyvoice') ...[
              _row('接口地址', _endpoint,
                  hint: 'http://ip:3000（带不带 /api/v1 都行）'),
              _row('音色', _voice, hint: 'zh-CN-XiaoxiaoNeural'),
            ] else if (_s.type == 'edge') ...[
              // 内置：不需要任何地址 / Key
            ] else ...[
              _row('接口地址', _endpoint,
                  hint: _s.type == 'mimo'
                      ? 'https://api.xiaomimimo.com/v1'
                      : 'https://.../v1（末尾到 v1 即可）'),
              _row('模型 ID', _modelId,
                  hint: _s.type == 'mimo' ? 'mimo-v2.5-tts' : '如 tts-1'),
            ],
            if (_s.type == 'edge')
              _note('内置 Edge 朗读：合成走 App 自带的 Node 服务直连微软朗读接口，'
                  '不用填地址、不要 Key。⚠️ 这条链路**不走 App 的代理设置**：'
                  '如果必须挂代理才能连微软，请改用 EasyVoice 类型。')
            else if (_s.type == 'easyvoice')
              _note('EasyVoice 是免费的 Edge-TTS 服务，无需 API Key。'
                  '自部署：docker run -d -p 3000:3000 cosincox/easyvoice:latest。'
                  '保存后自动设为「当前使用」，朗读面板点播放即走本源。')
            else if (_s.type == 'http')
              _note('HTTP 模板源不需要 API Key；需要鉴权的服务把请求头写在上面。'
                  '保存后自动设为「当前使用」。')
            else ...[
              _row('API Key', _apiKey, hint: '必填', obscure: true),
              _note('API Key 存在系统密钥库里，不写进配置、也不进备份。'
                  '换机后需要重填一次。'),
            ],
          ]),

          // ── 音色 / 音色与风格 / 音色与格式 ────────────────────
          if (_s.type == 'azure')
            _card(isDark, '音色', [
              _row('音色', _voice, hint: 'zh-CN-XiaoxiaoNeural', chevron: true),
              _action('拉取音色列表'),
              _row('情绪风格', _emotion..text = _s.emotion,
                  hint: '未设置', chevron: true, readOnly: true),
              _switchRow('高保真音质', '48kHz（默认 24kHz）。更清晰，流量约翻倍',
                  _s.hiFi, (v) => setState(() => _s = _s.copyWith(hiFi: v))),
              _note('免费层（F0）文本转语音限每分钟 20 次请求且不可上调，'
                  '逐句朗读很容易撞上 —— 用 F0 请把下面的「并发上限」设为 1、'
                  '「最小请求间隔」设到 3000ms 左右。另外计费按字符算，'
                  '一个汉字算两个字符。'),
            ])
          else if (_s.type == 'mimo')
            _card(isDark, '音色与风格', [
              _row('音色', _voice, hint: '默认（中国集群为冰糖）', chevron: true),
              _row('风格指令', _stylePrompt,
                  hint: '自然语言，如「用慵懒的语气，语速稍慢」'),
              _row('风格标签', _styleTag,
                  hint: '加在每句正文最前，如（开心）或（东北话）'),
              _note('MiMo 的语音合成走 chat 接口：正文作为 assistant 消息发送，'
                  '风格指令作为 user 消息。它没有语速字段，所以朗读面板里的'
                  '语速滑杆对本源无效 —— 想调快慢请写进上面的风格指令。'
                  '音频按 base64 返回，格式固定 wav。'),
              _switchRow('高保真音质', '48kHz（默认 24kHz）。更清晰，流量约翻倍',
                  _s.hiFi, (v) => setState(() => _s = _s.copyWith(hiFi: v))),
            ])
          else if (_s.type == 'openai')
            _card(isDark, '音色与格式', [
              _row('音色', _voice, hint: '各家自己的音色标识，如 alloy'),
              _row('音频格式', _audioFormat..text = _s.audioFormat,
                  hint: 'mp3', chevron: true, readOnly: true),
              _switchRow('发送语速参数', '把语速作为 speed 字段发送。'
                  '有的服务不认这个字段会整体报错，那就关掉',
                  _s.sendsSpeed,
                  (v) => setState(() => _s = _s.copyWith(sendsSpeed: v))),
              _row('附加参数', _extraParams,
                  hint: 'JSON 对象，如 {"emotion":"happy"}'),
              _note('按 OpenAI 语音接口的通用形状请求（/audio/speech，字段 '
                  'model/input/voice/speed/response_format）。若某家服务返回 404，'
                  '多半是它并不提供这个接口 —— 小米 MiMo 就属于这种，'
                  '请改用「小米 MiMo」类型。'),
            ])
          else if (_s.type == 'edge')
            _card(isDark, '音色', [
              _row('音色', _voice, hint: 'zh-CN-XiaoxiaoNeural'),
              _action('常用音色'),
              _note('音色表随 App 内置：晓晓 / 晓伊 / 云希 / 云健 / 云扬 / '
                  '东北话 / 陕西话 / 粤语 / 台湾腔。朗读面板的语速、音调滑杆'
                  '会映射成请求里的 rate / pitch。'),
            ])
          else if (_s.type == 'easyvoice')
            _card(isDark, '音色', [
              _switchRow(
                  'AI 智能推荐配音',
                  'EasyVoice 用大模型自动给文本分角色、推荐音色/语速/音调'
                  '（多角色有声书效果，慢一些）。关闭后固定用下方音色直接合成。'
                  '服务端没有 AI 接口时会自动回退普通合成。',
                  _s.useAiVoice,
                  (v) => setState(() => _s = _s.copyWith(useAiVoice: v))),
              _row('音色', _voice,
                  hint: _s.useAiVoice
                      ? '留空让 AI 推荐；填了则优先使用'
                      : 'zh-CN-XiaoxiaoNeural',
                  chevron: true),
              if (!_s.useAiVoice) _action('拉取音色列表'),
              _note('EasyVoice 走 Edge 神经音色，免费。常用：'
                  'zh-CN-XiaoxiaoNeural（晓晓）、zh-CN-YunxiNeural（云希）、'
                  'zh-CN-YunyangNeural（云扬）。\n'
                  '关闭 AI 推荐时，朗读面板的语速 / 音调滑杆会映射为请求里的 '
                  'rate / pitch。'),
            ])
          else
            _card(isDark, '音色', [
              _row('音色', _voice, hint: '网络导入的引擎自带音色'),
              _note('网络导入的引擎定义里已经写好音色与接口，'
                  '这里通常不用填。'),
            ]),

          // ── 调优 ────────────────────────────────────────────
          _card(isDark, '调优', [
            _sliderRow('并发上限', '同时在飞的请求数。免费或限流的服务建议 1–2',
                _s.maxConcurrency.toDouble(), 1, 8,
                '${_s.maxConcurrency}',
                (v) => setState(
                    () => _s = _s.copyWith(maxConcurrency: v.round()))),
            _sliderRow('最小请求间隔', '两次请求之间至少等这么久，专治 429',
                _s.minIntervalMs.toDouble(), 0, 3000,
                '${_s.minIntervalMs} ms',
                (v) => setState(
                    () => _s = _s.copyWith(minIntervalMs: v.round()))),
            _sliderRow('预取句数', '提前合成几句备用。够填住间隙即可，'
                '多了跳句就白花额度',
                _s.prefetchSentences.toDouble(), 0, 10,
                '${_s.prefetchSentences}',
                (v) => setState(
                    () => _s = _s.copyWith(prefetchSentences: v.round()))),
            _sliderRow('请求超时', '超过就算失败，进重试或降级',
                _s.timeoutSec.toDouble(), 5, 60, '${_s.timeoutSec} s',
                (v) =>
                    setState(() => _s = _s.copyWith(timeoutSec: v.round()))),
            _sliderRow('失败重试', '仅对超时、429、5xx 重试；'
                '密钥或参数错不重试',
                _s.maxRetries.toDouble(), 0, 5, '${_s.maxRetries} 次',
                (v) =>
                    setState(() => _s = _s.copyWith(maxRetries: v.round()))),
            _sliderRow('单次最大字数', '超长句拆开发，避免服务端按长度拒收',
                _s.maxChars.toDouble(), 50, 1000, '${_s.maxChars} 字',
                (v) => setState(() => _s = _s.copyWith(maxChars: v.round()))),
            _switchRow('失败自动降级', '连不上或额度用完时自动切回系统朗读继续读，'
                '并提示一次',
                _s.fallbackToSystem,
                (v) => setState(() => _s = _s.copyWith(fallbackToSystem: v))),
            _switchRow('仅 Wi-Fi 使用', '移动网络下不用本源，改用系统朗读'
                '（连读一小时约 20MB）',
                _s.wifiOnly,
                (v) => setState(() => _s = _s.copyWith(wifiOnly: v))),
          ]),

          // ── 测试 ────────────────────────────────────────────
          _card(isDark, '测试', [
            Row(
              children: [
                Expanded(
                  child: Text('会真发一次很短的合成请求',
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead, color: JellyTheme.textSecondary)),
                ),
                FilledButton(
                  onPressed: _busy ? null : _test,
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        isDark ? Colors.white : JellyTheme.primary,
                    foregroundColor:
                        isDark ? JellyTheme.backgroundDark : Colors.white,
                  ),
                  child: const Text('测试连接'),
                ),
              ],
            ),
            if (_testResult != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(_testResult!,
                    style: TextStyle(
                        fontSize: AppTheme.fontSubhead, height: 1.6, color: label)),
              ),
            ],
          ]),
        ],
      ),
    );
  }

  // ── 小组件 ──────────────────────────────────────────────────

  Widget _card(bool isDark, String title, List<Widget> children) {
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w700,
                  color: label)),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _row(
    String label,
    TextEditingController ctrl, {
    String? hint,
    bool chevron = false,
    bool readOnly = false,
    bool obscure = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labelColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 78,
            child: Text(label,
                style: TextStyle(fontSize: AppTheme.fontBody, color: labelColor)),
          ),
          Expanded(
            child: readOnly
                ? Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    alignment: Alignment.centerLeft,
                    child: Text(hint ?? '',
                        style: TextStyle(
                            fontSize: AppTheme.fontBody,
                            color: JellyTheme.textSecondary)),
                  )
                : TextField(
                    controller: ctrl,
                    obscureText: obscure,
                    style: TextStyle(fontSize: AppTheme.fontBody, color: labelColor),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: isDark
                          ? Colors.white.withValues(alpha: 0.07)
                          : Colors.black.withValues(alpha: 0.045),
                      hintText: hint,
                      hintStyle: TextStyle(
                          fontSize: AppTheme.fontBody, color: JellyTheme.textSecondary),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                    ),
                  ),
          ),
          if (chevron)
            Icon(Icons.chevron_right_rounded,
                size: 20, color: JellyTheme.textSecondary),
        ],
      ),
    );
  }

  Widget _switchRow(String title, String sub, bool value,
      ValueChanged<bool> onChanged) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: FontWeight.w600,
                        color: label)),
                const SizedBox(height: 3),
                Text(sub,
                    style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        height: 1.5,
                        color: JellyTheme.textSecondary)),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _sliderRow(String title, String sub, double value, double min,
      double max, String display, ValueChanged<double> onChanged) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: FontWeight.w600,
                        color: label)),
              ),
              Text(display,
                  style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w700,
                      color: label)),
            ],
          ),
          const SizedBox(height: 2),
          Text(sub,
              style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  height: 1.5,
                  color: JellyTheme.textSecondary)),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _action(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 78, bottom: 6),
      child: TextButton(
        onPressed: () => _pullVoices(),
        child: Text(text, style: const TextStyle(fontSize: AppTheme.fontSubhead)),
      ),
    );
  }

  /// 「拉取音色列表」：easyvoice 从服务端拉取；openai / azure 给内置常用清单；
  /// 选中即填入音色字段。
  Future<void> _pullVoices() async {
    final type = _s.type;
    if (type == 'easyvoice') {
      await _pullEasyVoiceVoices();
    } else if (type == 'edge') {
      await _pickVoice([
        'zh-CN-XiaoxiaoNeural', 'zh-CN-XiaoyiNeural',
        'zh-CN-YunxiNeural', 'zh-CN-YunjianNeural',
        'zh-CN-YunyangNeural', 'zh-CN-YunxiaNeural',
        'zh-CN-liaoning-XiaobeiNeural', 'zh-CN-shaanxi-XiaoniNeural',
        'zh-HK-HiuMaanNeural', 'zh-TW-HsiaoChenNeural',
      ], '内置音色（也可手填）');
    } else if (type == 'openai') {
      await _pickVoice([
        'alloy', 'echo', 'fable', 'onyx', 'nova', 'shimmer',
        'zh-CN-XiaoxiaoNeural', 'zh-CN-YunxiNeural',
      ], 'OpenAI 常见音色（也可手填）');
    } else if (type == 'azure') {
      await _pickVoice([
        'zh-CN-XiaoxiaoNeural', 'zh-CN-XiaoxiaoNeural-Lite',
        'zh-CN-YunxiNeural', 'zh-CN-YunjianNeural',
        'zh-CN-XiaoyiNeural', 'zh-CN-YunyangNeural',
        'zh-CN-liaoning-XiaobeiNeural', 'zh-CN-shaanxi-XiaoniNeural',
      ], 'Azure 常见中文音色（也可手填）');
    } else {
      _toast('该类型暂不支持自动拉取，请直接在音色框手填');
    }
  }

  /// easyvoice：GET {base}/api/v1/tts/voiceList（老版本再试 /api/v1/voiceList、
  /// /api/v1/voices），解析 {code,data:[{Name,...}],success} 结构。
  Future<void> _pullEasyVoiceVoices() async {
    final base = TtsService.easyVoiceBase(_endpoint.text);
    if (base.isEmpty) {
      _toast('先填接口地址');
      return;
    }
    setState(() => _busy = true);
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
      ));
      // ✅ **「拉取音色列表」也走「网络代理」**（本轮接上 ✓）—— 这处是朗读引擎页里
      //   「拉取音色」发出的那次 `/api/v1/voiceList` 探测 ✓（决定音色下拉有没有内容 ✓）。
      //   ℹ️ 安全依据 ✓：同样是**纯构造** ✗✓（无自定义适配器 / UA ✓）→ 直接挂安全 ✓
      applyGlobalProxy(dio);
      List<String> names = [];
      for (final path in [
        '/api/v1/tts/voiceList',
        '/api/v1/voiceList',
        '/api/v1/tts/voices',
        '/api/v1/voices',
      ]) {
        try {
          final r = await dio.get<dynamic>('$base$path');
          final data = r.data;
          if (data is List) {
            names = data
                .map((e) => e is Map ? _voiceNameOf(e) : '$e')
                .whereType<String>()
                .where((s) => s.trim().isNotEmpty)
                .toList();
            if (names.isNotEmpty) break;
          } else if (data is Map) {
            // 标准：{code, data:[{Name,Gender,ContentCategories,...}], success}
            final dataList = data['data'];
            if (dataList is List && dataList.isNotEmpty) {
              names = dataList
                  .map((e) => e is Map ? _voiceNameOf(e) : '$e')
                  .whereType<String>()
                  .where((s) => s.trim().isNotEmpty)
                  .toList();
            }
            if (names.isEmpty) {
              for (final k in ['voices', 'voice_list', 'items', 'list']) {
                final v = data[k];
                if (v is List && v.isNotEmpty) {
                  names = v
                      .map((e) => e is Map ? _voiceNameOf(e) : '$e')
                      .whereType<String>()
                      .where((s) => s.trim().isNotEmpty)
                      .toList();
                  if (names.isNotEmpty) break;
                }
              }
            }
            if (names.isNotEmpty) break;
          }
        } catch (_) {
          // 试下一个端点
        }
      }
      if (names.isEmpty) {
        _toast('服务端没返回音色列表，请确认 easyvoice 版本支持 /voiceList 接口');
        return;
      }
      if (!mounted) return;
      await _pickVoice(names, 'easyvoice 服务端音色');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _voiceNameOf(Map e) {
    // easyvoice voice.json 用大写 Name 字段
    for (final k in ['Name', 'name', 'voice', 'voice_id', 'id', 'label', 'display_name']) {
      final v = e[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }

  /// 音色选择底部弹层：选中即回填音色输入框
  Future<void> _pickVoice(List<String> voices, String title) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              Divider(height: 1, color: Colors.black.withValues(alpha: 0.08)),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: voices.length,
                  itemBuilder: (c, i) => ListTile(
                    dense: true,
                    title: Text(voices[i],
                        style: const TextStyle(fontSize: 14)),
                    onTap: () => Navigator.pop(ctx, voices[i]),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && picked.isNotEmpty) {
      setState(() => _voice.text = picked);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Widget _note(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(text,
          style: TextStyle(
              fontSize: AppTheme.fontFootnote, height: 1.7, color: JellyTheme.textSecondary)),
    );
  }
}
