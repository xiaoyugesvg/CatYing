import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../services/ai_service.dart';
import '../theme/jelly_theme.dart';
import 'pet_service.dart';

/// 桌宠 AI 闲聊（2026-10-22）。
///
/// 参考 QQ 宠物复刻的「AI 闲聊」：宠物用自己的口吻回话，
/// 并把当前等级 / 心情 / 饱食度塞进 system prompt，让回答贴合养成状态。
/// 走用户自己的 OpenAI 兼容接口（复用阅读模块的 [AiService] 配置）。
class PetChatSheet extends StatefulWidget {
  const PetChatSheet({super.key});

  @override
  State<PetChatSheet> createState() => _PetChatSheetState();
}

class _PetChatSheetState extends State<PetChatSheet> {
  final _ai = AiService();
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// (是否用户, 文本)
  final List<({bool me, String text})> _messages = [];
  bool _busy = false;
  bool _showConfig = false;

  // 配置表单（未配置时展示）
  final _base = TextEditingController();
  final _key = TextEditingController();
  final _model = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ai.init().then((_) {
      if (!mounted) return;
      setState(() {
        _showConfig = !_ai.isConfigured;
        _base.text = _ai.baseUrl;
        _model.text = _ai.model;
      });
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _base.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  String get _systemPrompt {
    final p = PetService.instance;
    final sp = p.species.name;
    return '你是一只名叫「$sp」的桌面宠物，说话简短、活泼、带一点撒娇，'
        '每次回复不超过 80 字，不要用列表和 Markdown。'
        '当前状态：等级 ${p.level}，饱食度 ${p.hunger.round()}，'
        '心情 ${p.mood.round()}，猫币 ${p.coins}。'
        '如果饱食度低就小声提醒喂饭，心情低就要求陪玩。';
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _messages.add((me: true, text: text));
      _busy = true;
    });
    _input.clear();
    _jumpBottom();
    try {
      // AiService 只接受单轮，这里把最近 6 条上下文拼进 user
      final recent = _messages.length > 7
          ? _messages.sublist(_messages.length - 7, _messages.length - 1)
          : _messages.sublist(0, _messages.length - 1);
      final ctx = recent
          .map((m) => '${m.me ? "主人" : "我"}：${m.text}')
          .join('\n');
      final user = ctx.isEmpty ? text : '$ctx\n主人：$text\n我：';
      final reply = await _ai.chat(system: _systemPrompt, user: user);
      if (!mounted) return;
      setState(() => _messages.add((me: false, text: reply)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _messages.add((me: false, text: '（说不出话）$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
      _jumpBottom();
    }
  }

  void _jumpBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _saveConfig() async {
    await _ai.saveConfig(
      baseUrl: _base.text,
      apiKey: _key.text,
      model: _model.text,
    );
    if (!mounted) return;
    setState(() => _showConfig = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
    final maxH = MediaQuery.of(context).size.height * 0.72;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        constraints: BoxConstraints(maxHeight: maxH),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: JellyTheme.textSecondary.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 12, 4),
                child: Row(
                  children: [
                    Icon(Icons.chat_bubble_outline_rounded,
                        size: 20, color: JellyTheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      '和宠物聊聊',
                      style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : AppTheme.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    if (!_showConfig)
                      IconButton(
                        tooltip: '接口设置',
                        icon: const Icon(Icons.settings_outlined, size: 20),
                        onPressed: () => setState(() => _showConfig = true),
                      ),
                  ],
                ),
              ),
              if (_showConfig)
                _configForm(isDark)
              else ...[
                Expanded(
                  child: _messages.isEmpty
                      ? _emptyHint(isDark)
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          itemCount: _messages.length + (_busy ? 1 : 0),
                          itemBuilder: (context, i) {
                            if (i == _messages.length) {
                              return _bubble(false, '…', isDark);
                            }
                            final m = _messages[i];
                            return _bubble(m.me, m.text, isDark);
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(
                            hintText: '说点什么…',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                            filled: true,
                            fillColor: isDark
                                ? Colors.white.withValues(alpha: 0.06)
                                : Colors.black.withValues(alpha: 0.04),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: _busy ? null : _send,
                        icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyHint(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          '它现在饿着肚子也能陪你聊几句。\n试试：「今天心情怎么样？」',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: AppTheme.fontBody,
            height: 1.6,
            color: JellyTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _bubble(bool me, String text, bool isDark) {
    final fg = me ? Colors.white : (isDark ? Colors.white : Colors.black87);
    final bub = me
        ? JellyTheme.primary
        : (isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.05));
    return Align(
      alignment: me ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        decoration: BoxDecoration(
          color: bub,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: AppTheme.fontBody, height: 1.45, color: fg),
        ),
      ),
    );
  }

  Widget _configForm(bool isDark) {
    Widget field(TextEditingController c, String label, {bool obscure = false}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          obscureText: obscure,
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '填入任意 OpenAI 兼容接口即可（默认 DeepSeek）。Key 只存本机。',
            style: TextStyle(
              fontSize: AppTheme.fontCaption,
              height: 1.5,
              color: JellyTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          field(_base, '接口地址（如 https://api.deepseek.com）'),
          field(_key, 'API Key', obscure: true),
          field(_model, '模型（如 deepseek-chat）'),
          const SizedBox(height: 4),
          FilledButton(
            onPressed: _saveConfig,
            child: const Text('保存并开始聊天'),
          ),
        ],
      ),
    );
  }
}
