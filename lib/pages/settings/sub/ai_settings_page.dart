import 'package:flutter/material.dart';

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
    'glm-4-flash',
    '有免费额度',
  ),
  // OpenCode Zen：OpenAI 兼容网关，部分模型限时免费。
  // ⚠️ 免费模型名单与名字会变，以官方为准；这里只是一个可改的起点。
  _Provider(
    'OpenCode',
    'https://opencode.ai/zen/v1',
    'qwen3-coder',
    '有免费模型',
  ),
  // 自建反代（用户自己的服务器）：路径以你实际的反代配置为准
  _Provider(
    'OpenCode(自建)',
    'https://opencodeai.cn/v1',
    'qwen3-coder',
    '自己的服务器',
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
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await _ai.init();
    } catch (_) {}
    _base.text = _ai.baseUrl;
    _key.text = _ai.apiKey;
    _model.text = _ai.model;
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
    );
    if (!mounted) return true;
    setState(() {
      _ok = true;
      _msg = '已保存，全 App 的 AI 功能都会用这份配置';
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 管理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 30),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                '这里是全 App 唯一的 AI 配置。填一次 Key，宠物对话、以及后续接入 '
                'AI 的模块都共用，不用到处重复配置。\n\n'
                'Key 只保存在本机，不会上传。阅读模块原有的 AI 功能不受影响。',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '服务商',
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in _providers)
                ChoiceChip(
                  label: Text(p.name),
                  selected: _selected == p.name,
                  onSelected: (_) => _pick(p),
                ),
            ],
          ),
          const SizedBox(height: 16),
          _field(
            _base,
            '接口地址',
            hint: '如 https://api.deepseek.com',
            keyboard: TextInputType.url,
          ),
          const SizedBox(height: 12),
          _field(
            _key,
            'API Key',
            hint: 'sk-...',
            obscure: _obscure,
            suffix: IconButton(
              icon: Icon(
                _obscure ? Icons.visibility_off : Icons.visibility,
                size: 18,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          const SizedBox(height: 12),
          _field(_model, '模型', hint: '如 deepseek-chat'),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: _testing ? null : () => _test(),
                  child: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('测试连接'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => _save(),
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
          if (_msg != null) ...[
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _ok ? Icons.check_circle_outline : Icons.error_outline,
                  size: 16,
                  color: _ok ? Colors.green : scheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _msg!,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: _ok ? scheme.onSurface : scheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Text(
            '说明：所有服务商都按 OpenAI 兼容协议调用。若你的服务商地址以 '
            '/v4 或 /v1 结尾会被自动补全；也可以直接填完整的 '
            '.../chat/completions。',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.6,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 20),
          // AI 底座之上的第一个实际用途：日志诊断
          Card(
            child: ListTile(
              leading: const Icon(Icons.troubleshoot),
              title: const Text('日志诊断'),
              subtitle: const Text('读运行日志，让 AI 给出优化建议'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const LogDiagnosisPage(),
                ),
              ),
            ),
          ),
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
    return TextField(
      controller: c,
      obscureText: obscure,
      keyboardType: keyboard,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: suffix,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        isDense: true,
      ),
    );
  }
}
