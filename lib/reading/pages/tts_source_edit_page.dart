import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../models/tts_source.dart';
import '../services/tts_source_store.dart';
import '../theme/jelly_theme.dart';
import '../../common/theme.dart';

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
    } else if (_s.type == 'easyvoice') {
      if (_endpoint.text.trim().isEmpty) problems.add('接口地址没填');
      if (_voice.text.trim().isEmpty) problems.add('音色没填');
    }
    if (_apiKey.text.trim().isEmpty &&
        _s.type != 'easyvoice') {
      problems.add('API Key 没填');
    }
    if (problems.isNotEmpty) {
      setState(() {
        _testResult = '还差这些：\n· ${problems.join('\n· ')}';
      });
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

  /// EasyVoice 合成：POST /api/v1/tts/generateJson → mp3 字节。
  /// 返回 null 表示响应为空。
  Future<List<int>?> _requestEasyVoice(String text,
      {int? timeoutSec}) async {
    final base = _endpoint.text.trim().replaceAll(RegExp(r'/+$'), '');
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: Duration(seconds: timeoutSec ?? 20),
    ));
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
            ] else if (_s.type == 'easyvoice') ...[
              _row('接口地址', _endpoint,
                  hint: 'http://ip:3000（自部署）或公共实例地址'),
              _row('音色', _voice, hint: 'zh-CN-XiaoxiaoNeural'),
            ] else ...[
              _row('接口地址', _endpoint,
                  hint: _s.type == 'mimo'
                      ? 'https://api.xiaomimimo.com/v1'
                      : 'https://.../v1（末尾到 v1 即可）'),
              _row('模型 ID', _modelId,
                  hint: _s.type == 'mimo' ? 'mimo-v2.5-tts' : '如 tts-1'),
            ],
            if (_s.type == 'easyvoice')
              _note('EasyVoice 是免费的 Edge-TTS 服务，无需 API Key。'
                  '自部署：docker run -d -p 3000:3000 cosincox/easyvoice:latest。'
                  '保存后自动设为「当前使用」，朗读面板点播放即走本源。')
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
              _row('情绪风格', TextEditingController(text: _s.emotion),
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
              _row('音频格式', TextEditingController(text: _s.audioFormat),
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
          else if (_s.type == 'easyvoice')
            _card(isDark, '音色', [
              _row('音色', _voice, hint: 'zh-CN-XiaoxiaoNeural', chevron: true),
              _note('Edge 神经音色，免费。常用：zh-CN-XiaoxiaoNeural（晓晓）、'
                  'zh-CN-YunxiNeural（云希）、zh-CN-YunyangNeural（云扬）。\n'
                  '朗读面板的语速 / 音调滑杆会映射为请求里的 rate / pitch。'),
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
        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('拉取音色列表需要该服务的鉴权请求，还没接'),
              duration: Duration(seconds: 2)),
        ),
        child: Text(text, style: const TextStyle(fontSize: AppTheme.fontSubhead)),
      ),
    );
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
