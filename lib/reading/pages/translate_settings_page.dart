import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../services/translate_service.dart';
import '../../widgets/app_toast.dart';

/// 「翻译设置」—— 漫画 / 字幕翻译用的引擎与语言配置。
///
/// 两种引擎都保留（用户 2026-10-17 选 C）：
///   · AI 翻译（OpenAI 兼容：DeepSeek / 智谱 / 自建…）—— 质量最好
///   · 百度翻译开放平台 —— 便宜稳定
class TranslateSettingsPage extends StatefulWidget {
  const TranslateSettingsPage({super.key});

  @override
  State<TranslateSettingsPage> createState() => _TranslateSettingsPageState();
}

class _TranslateSettingsPageState extends State<TranslateSettingsPage> {
  String _engine = 'openai';
  String _from = 'auto';
  String _to = 'zh';
  bool _loaded = false;
  bool _testing = false;

  final _openAiBase = TextEditingController();
  final _openAiKey = TextEditingController();
  final _openAiModel = TextEditingController();
  final _baiduAppId = TextEditingController();
  final _baiduSecret = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final e = await TranslateSettings.engine();
    final from = await TranslateSettings.from();
    final to = await TranslateSettings.to();
    final base = await TranslateSettings.openAiBase();
    final key = await TranslateSettings.openAiKey();
    final model = await TranslateSettings.openAiModel();
    final appId = await TranslateSettings.baiduAppId();
    final secret = await TranslateSettings.baiduSecret();
    if (!mounted) return;
    setState(() {
      _engine = e;
      _from = from;
      _to = to;
      _openAiBase.text = base;
      _openAiKey.text = key;
      _openAiModel.text = model;
      _baiduAppId.text = appId;
      _baiduSecret.text = secret;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _openAiBase.dispose();
    _openAiKey.dispose();
    _openAiModel.dispose();
    _baiduAppId.dispose();
    _baiduSecret.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await TranslateSettings.save(
      engine: _engine,
      openAiBase: _openAiBase.text,
      openAiKey: _openAiKey.text,
      openAiModel: _openAiModel.text,
      baiduAppId: _baiduAppId.text,
      baiduSecret: _baiduSecret.text,
      from: _from,
      to: _to,
    );
    if (mounted) AppToast.message('已保存');
  }

  Future<void> _test() async {
    if (_testing) return;
    setState(() => _testing = true);
    try {
      await _save();
      final missing = await TranslateSettings.missingReason();
      if (missing.isNotEmpty) {
        AppToast.error(missing);
        return;
      }
      final r = await TranslateService.instance
          .translateLines(const ['こんにちは、世界。']);
      AppToast.message('测试结果：${r.isEmpty ? '(空)' : r.first}');
    } catch (e) {
      AppToast.error('测试失败：${e.toString().split('\n').first}');
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
        foregroundColor: AppTheme.textPrimary,
        elevation: 0,
        title: const Text('翻译设置'),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                _hint('漫画：阅读器底栏「翻译」按钮 → 识别当前页文字 → 译文盖回原位置。\n'
                    'OCR 使用系统自带的 Apple Vision，离线、不上传图片；只有识别出的文字会发给翻译接口。'),
                const SizedBox(height: 16),
                _section('翻译引擎'),
                _engineSelector(),
                const SizedBox(height: 12),
                if (_engine == 'openai') ..._openAiFields() else ..._baiduFields(),
                const SizedBox(height: 18),
                _section('语言'),
                _langRow('源语言', _from, const [
                  ('auto', '自动识别'),
                  ('ja', '日语'),
                  ('ko', '韩语'),
                  ('en', '英语'),
                  ('zh', '简体中文'),
                  ('zh-TW', '繁体中文'),
                ], (v) => setState(() => _from = v)),
                const SizedBox(height: 10),
                _langRow('目标语言', _to, const [
                  ('zh', '简体中文'),
                  ('zh-TW', '繁体中文'),
                  ('en', '英语'),
                  ('ja', '日语'),
                ], (v) => setState(() => _to = v)),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.accentOnSurface,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _save,
                        child: const Text('保存'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: AppTheme.borderMedium),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _testing ? null : _test,
                        child: Text(_testing ? '测试中…' : '测试翻译'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _hint('提示：AI 翻译需要兼容 OpenAI 的接口；百度翻译需要开放平台的 APPID 与密钥。'
                    '密钥只保存在本机，不会随导出配置带出。'),
              ],
            ),
    );
  }

  Widget _hint(String text) => Text(
        text,
        style: TextStyle(
          color: AppTheme.textTertiary,
          fontSize: AppTheme.fontCaption,
          height: 1.6,
        ),
      );

  Widget _section(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 2),
        child: Text(text,
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.bold)),
      );

  Widget _engineSelector() {
    Widget item(String value, String label, String desc) {
      final on = _engine == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _engine = value),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
            decoration: BoxDecoration(
              color: on
                  ? AppTheme.accentSurface
                  : AppTheme.backgroundSecondary,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: on ? AppTheme.accentOnSurface : AppTheme.borderLight),
            ),
            child: Column(
              children: [
                Text(label,
                    style: TextStyle(
                        color: on ? AppTheme.accentOnSurface : AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(desc,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: 10,
                        height: 1.4)),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        item('openai', 'AI 翻译', 'OpenAI 兼容\nDeepSeek / 自建'),
        item('baidu', '百度翻译', '官方 API\n便宜稳定'),
      ],
    );
  }

  List<Widget> _openAiFields() => [
        _field(_openAiBase, '接口地址',
            hint: 'https://api.deepseek.com/v1'),
        const SizedBox(height: 10),
        _field(_openAiKey, 'API Key', obscure: true),
        const SizedBox(height: 10),
        _field(_openAiModel, '模型名', hint: 'deepseek-chat / gpt-4o-mini'),
      ];

  List<Widget> _baiduFields() => [
        _field(_baiduAppId, 'APPID'),
        const SizedBox(height: 10),
        _field(_baiduSecret, '密钥', obscure: true),
      ];

  Widget _field(TextEditingController c, String label,
      {String? hint, bool obscure = false}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      style: TextStyle(color: AppTheme.textPrimary, fontSize: AppTheme.fontSubhead),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
        labelStyle: TextStyle(color: AppTheme.textSecondary),
        filled: true,
        fillColor: AppTheme.backgroundSecondary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }

  Widget _langRow(String label, String value, List<(String, String)> options,
      ValueChanged<String> onChanged) {
    return Row(
      children: [
        SizedBox(
          width: 76,
          child: Text(label,
              style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: AppTheme.fontSubhead)),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppTheme.backgroundSecondary,
              borderRadius: BorderRadius.circular(12),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                isExpanded: true,
                dropdownColor: AppTheme.backgroundSecondary,
                icon: Icon(Icons.expand_more_rounded,
                    color: AppTheme.textSecondary),
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead),
                items: [
                  for (final (v, t) in options)
                    DropdownMenuItem(value: v, child: Text(t)),
                ],
                onChanged: (v) {
                  if (v != null) onChanged(v);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
