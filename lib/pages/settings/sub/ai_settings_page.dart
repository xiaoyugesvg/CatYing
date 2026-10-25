import 'package:flutter/material.dart';

import '../../../common/theme.dart';
import '../../../reading/services/ai_service.dart';
import 'log_diagnosis_page.dart';

/// 一家 AI 服务商的预设（都是 OpenAI 兼容接口）
class _Provider {
  const _Provider(this.name, this.baseUrl, this.model, this.hint);
  final String name;
  final String baseUrl;
  final String model;
  final String hint;
}

const List<_Provider> _providers = [
  _Provider('DeepSeek', 'https://api.deepseek.com', 'deepseek-chat', '便宜、中文好'),
  _Provider('OpenAI', 'https://api.openai.com', 'gpt-4o-mini', '需外网'),
  _Provider(
    '通义千问',
    'https://dashscope.aliyuncs.com/compatible-mode/v1',
    'qwen-plus',
    '阿里云',
  ),
  _Provider('Kimi', 'https://api.moonshot.cn', 'moonshot-v1-8k', '长文本'),
  _Provider(
    '智谱',
    'https://open.bigmodel.cn/api/paas/v4',
    // 2026-10 官方免费模型：GLM-4.7-Flash（输入/输出/缓存全免费，200K 上下文）
    'glm-4.7-flash',
    '免费（glm-4.7-flash）',
  ),
  // ── 2026-10-25：补几家**真免费**的（都不用绑卡）────────────────
  // 用户问「有没有免费的 AI」，这三家是当下最省事的：
  //   · Groq：免费 30 次/分、1000 次/天，速度极快，但需外网；
  //   · Gemini：Google AI Studio 免费层，需外网（模型名可改成更新的 flash）；
  //   · 硅基流动：国内直连，站内标了「免费」的小模型可用。
  _Provider(
    'Groq（免费）',
    'https://api.groq.com/openai/v1',
    'openai/gpt-oss-120b',
    '免费 1000 次/天 · 需外网',
  ),
  _Provider(
    'Gemini（免费）',
    'https://generativelanguage.googleapis.com/v1beta/openai',
    'gemini-2.5-flash',
    '有免费层 · 需外网',
  ),
  _Provider(
    '硅基流动（免费）',
    'https://api.siliconflow.cn/v1',
    'Qwen/Qwen2-7B-Instruct',
    '国内直连 · 有免费模型',
  ),
  // OpenRouter：聚合网关，带 `:free` 后缀的模型真免费（有限速）。
  _Provider(
    'OpenRouter',
    'https://openrouter.ai/api/v1',
    'deepseek/deepseek-chat-v3-0324:free',
    '有免费模型',
  ),
];

/// 「AI 管理」——**全 App 唯一的 AI Key 配置入口**。
///
/// 设计要点（用户 2026-10-25）：
///   • 只做**配置与连通性测试**，不重复实现请求逻辑 —— 底层仍走
///     [AiService]（OpenAI 兼容）。宠物对话、各模块 AI 天然共用同一份配置；
///   • 阅读模块原有的 AI 功能与它的界面**不改**：它读的也是这份配置；
///   • Key 只存本机 prefs，不上传、不内置。
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  final AiService _ai = AiService();
  final TextEditingController _base = TextEditingController();
  final TextEditingController _key = TextEditingController();
  final TextEditingController _model = TextEditingController();

  // 阅读独立配置（宠物永远用上面那份）
  final TextEditingController _rBase = TextEditingController();
  final TextEditingController _rKey = TextEditingController();
  final TextEditingController _rModel = TextEditingController();
  bool _readerSeparate = false;

  String? _selected;
  bool _obscure = true;
  bool _testing = false;
  String? _msg;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _base.dispose();
    _key.dispose();
    _model.dispose();
    _rBase.dispose();
    _rKey.dispose();
    _rModel.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await _ai.init();
    } catch (_) {}
    _base.text = _ai.baseUrl;
    _key.text = _ai.apiKey;
    _model.text = _ai.model;
    _rBase.text = _ai.readerBaseUrl;
    _rKey.text = _ai.readerApiKey;
    _rModel.text = _ai.readerModel;
    _readerSeparate = _ai.readerSeparate;
    for (final p in _providers) {
      if (_ai.baseUrl.startsWith(p.baseUrl)) {
        _selected = p.name;
        break;
      }
    }
    if (mounted) setState(() {});
  }

  void _pick(_Provider p) {
    setState(() {
      _selected = p.name;
      _base.text = p.baseUrl;
      _model.text = p.model;
      _msg = null;
    });
  }

  Future<bool> _save() async {
    if (_key.text.trim().isEmpty) {
      setState(() {
        _ok = false;
        _msg = '请先填写 API Key';
      });
      return false;
    }
    await _ai.saveConfig(
      baseUrl: _base.text,
      apiKey: _key.text,
      model: _model.text,
      readerSeparate: _readerSeparate,
      readerBaseUrl: _rBase.text,
      readerApiKey: _rKey.text,
      readerModel: _rModel.text,
    );
    if (!mounted) return true;
    setState(() {
      _ok = true;
      _msg = _readerSeparate && _rKey.text.trim().isNotEmpty
          ? '已保存：宠物用上面的配置，阅读用下面的独立配置'
          : '已保存，宠物与各模块都用这份配置';
    });
    return true;
  }

  Future<void> _test() async {
    if (_testing) return;
    final saved = await _save();
    if (!saved) return;
    setState(() {
      _testing = true;
      _msg = '正在连接…';
      _ok = false;
    });
    try {
      final r = await _ai.chat(
        system: '这是一次连通性测试，只回复 OK。',
        user: 'ping',
        timeout: const Duration(seconds: 30),
      );
      if (!mounted) return;
      setState(() {
        _ok = true;
        _msg = '连接成功：${r.length > 40 ? '${r.substring(0, 40)}…' : r}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _msg = '连接失败：$e';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(
          'AI 管理',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          _statusCard(),
          const SizedBox(height: 18),
          _label('服务商'),
          _providerChips(),
          const SizedBox(height: 14),
          _surface(
            Column(
              children: [
                _field(
                  _base,
                  '接口地址',
                  hint: 'https://api.deepseek.com',
                  keyboard: TextInputType.url,
                ),
                const SizedBox(height: 10),
                _field(
                  _key,
                  'API Key',
                  hint: 'sk-...',
                  obscure: _obscure,
                  suffix: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                      color: AppTheme.textTertiary,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                const SizedBox(height: 10),
                _field(_model, '模型', hint: 'deepseek-chat'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _button(
                  _testing ? '连接中…' : '测试连接',
                  tonal: true,
                  busy: _testing,
                  onTap: _testing ? null : _test,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: _button('保存', onTap: () => _save())),
            ],
          ),
          if (_msg != null) _msgRow(),
          const SizedBox(height: 16),
          _readerCard(),
          const SizedBox(height: 14),
          _surface(
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LogDiagnosisPage()),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: AppTheme.backgroundTertiary,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(Icons.troubleshoot_rounded,
                          size: 18, color: AppTheme.accentOnSurface),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('日志诊断',
                              style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textPrimary)),
                          const SizedBox(height: 2),
                          Text('读运行日志，让 AI 给出优化建议',
                              style: TextStyle(
                                  fontSize: 11.5, color: AppTheme.textTertiary)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        size: 18, color: AppTheme.textTertiary),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '所有服务商都按 OpenAI 兼容协议调用。地址以 /v1、/v4 结尾会自动补全，'
            '也可以直接填完整的 .../chat/completions。',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.6,
              color: AppTheme.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  // ── 组件 ───────────────────────────────────────────────
  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Text(t,
            style: TextStyle(fontSize: 11.5, color: AppTheme.textTertiary)),
      );

  Widget _surface(Widget child) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(16),
        ),
        child: child,
      );

  Widget _statusCard() {
    final name = _selected ?? (_key.text.trim().isEmpty ? '未配置' : '自定义');
    final ok = _key.text.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: ok
                      ? AppTheme.accentOnSurface.withValues(alpha: 0.14)
                      : AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: 19,
                  color: ok ? AppTheme.accentOnSurface : AppTheme.textTertiary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('当前使用',
                        style: TextStyle(
                            fontSize: 11, color: AppTheme.textTertiary)),
                    const SizedBox(height: 2),
                    Text(
                      '$name · ${_model.text.trim().isEmpty ? '未填模型' : _model.text.trim()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: ok
                      ? const Color(0x1F2E9E5B)
                      : AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  ok ? '已配置' : '未配置',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: ok ? const Color(0xFF2E9E5B) : AppTheme.textTertiary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '宠物对话固定用这份配置；阅读可以单独配一套。Key 只存本机。',
            style: TextStyle(
                fontSize: 11.5, height: 1.55, color: AppTheme.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _providerChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in _providers)
          GestureDetector(
            onTap: () => _pick(p),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              decoration: BoxDecoration(
                color: _selected == p.name
                    ? AppTheme.accentOnSurface
                    : AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                p.name,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: _selected == p.name
                      ? FontWeight.w600
                      : FontWeight.w400,
                  color: _selected == p.name
                      ? Colors.white
                      : AppTheme.textSecondary,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _button(
    String text, {
    bool tonal = false,
    bool busy = false,
    VoidCallback? onTap,
  }) {
    return Material(
      color: tonal ? AppTheme.backgroundTertiary : AppTheme.accentOnSurface,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Center(
            child: busy
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.textSecondary,
                    ),
                  )
                : Text(
                    text,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: tonal ? AppTheme.textPrimary : Colors.white,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _msgRow() {
    final ok = _ok;
    return Padding(
      padding: const EdgeInsets.only(top: 12, left: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 15,
            color: ok ? const Color(0xFF2E9E5B) : const Color(0xFFD25757),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _msg!,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: ok ? AppTheme.textSecondary : const Color(0xFFD25757),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _readerCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('阅读使用独立 AI',
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary)),
                    const SizedBox(height: 2),
                    Text('只影响阅读的总结 / 问答，宠物不受影响',
                        style: TextStyle(
                            fontSize: 11.5, color: AppTheme.textTertiary)),
                  ],
                ),
              ),
              Switch.adaptive(
                value: _readerSeparate,
                activeTrackColor: AppTheme.accentOnSurface,
                onChanged: (v) => setState(() => _readerSeparate = v),
              ),
            ],
          ),
          if (_readerSeparate) ...[
            const SizedBox(height: 10),
            _field(_rBase, '阅读接口地址',
                hint: 'https://api.deepseek.com',
                keyboard: TextInputType.url),
            const SizedBox(height: 10),
            _field(_rKey, '阅读 API Key', hint: 'sk-...', obscure: true),
            const SizedBox(height: 10),
            _field(_rModel, '阅读模型', hint: 'deepseek-chat'),
          ],
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    TextInputType? keyboard,
    bool obscure = false,
    Widget? suffix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 5),
          child: Text(label,
              style: TextStyle(fontSize: 10.5, color: AppTheme.textTertiary)),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.backgroundTertiary,
            borderRadius: BorderRadius.circular(13),
          ),
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: TextField(
            controller: c,
            obscureText: obscure,
            keyboardType: keyboard,
            onChanged: (_) => setState(() {}),
            style: TextStyle(fontSize: 13.5, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle:
                  TextStyle(fontSize: 13, color: AppTheme.textTertiary),
              suffixIcon: suffix,
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 13),
            ),
          ),
        ),
      ],
    );
  }
}
