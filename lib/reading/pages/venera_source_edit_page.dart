// Venera 漫画源「脚本编辑」页。
//
// Venera 源的形态跟配置源完全不同：它不是一组选择器，而是一整段
// `class Xxx extends ComicSource { … }` 的 JS。所以不能塞进
// `ComicSourceEditPage` 的字段表单里（那里会要求填 URL、选择器，
// 看起来就像"只有一个名称"）。这里给一个真正的脚本编辑器：
//   · 名称 / 标识 / 版本 / 来源 只读展示，确认脚本确实已入库；
//   · 脚本全文可编辑（等宽字体、整屏铺满），保存前校验
//     `class … extends ComicSource` 是否还在；
//   · 保存写回 `SourceConfigStore` 后 reload，立即生效。
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../source/source_config_store.dart';
import '../source/source_definition.dart';
import '../source/source_manager.dart';
import '../theme/jelly_theme.dart';

class VeneraSourceEditPage extends StatefulWidget {
  const VeneraSourceEditPage({super.key, required this.definition});

  final SourceDefinition definition;

  @override
  State<VeneraSourceEditPage> createState() => _VeneraSourceEditPageState();
}

class _VeneraSourceEditPageState extends State<VeneraSourceEditPage> {
  static final RegExp _classRe = RegExp(
    r'class\s+[A-Za-z_$][A-Za-z0-9_$]*\s+extends\s+ComicSource\b',
  );

  late final Map<String, dynamic> _config;
  late final TextEditingController _name;
  late final TextEditingController _script;

  bool _saving = false;
  String? _scriptError;

  @override
  void initState() {
    super.initState();
    _config = Map<String, dynamic>.of(widget.definition.config);
    _name = TextEditingController(text: '${_config['name'] ?? ''}');
    _script = TextEditingController(text: '${_config['script'] ?? ''}');
  }

  @override
  void dispose() {
    _name.dispose();
    _script.dispose();
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _toast('名称不能为空');
      return;
    }
    final js = _script.text;
    if (!_classRe.hasMatch(js)) {
      setState(
        () => _scriptError = '脚本里没有 class Xxx extends ComicSource，保存后无法运行',
      );
      _toast('脚本不完整：找不到 extends ComicSource 的类');
      return;
    }
    setState(() {
      _saving = true;
      _scriptError = null;
    });
    try {
      final next = Map<String, dynamic>.from(_config);
      next['name'] = name;
      next['script'] = js;
      final def = SourceDefinition(
        id: widget.definition.id,
        type: widget.definition.type,
        engine: widget.definition.engine,
        config: next,
        needsMagic: widget.definition.needsMagic,
      );
      final store = SourceConfigStore();
      final local = await store.loadLocal();
      final out = <SourceDefinition>[];
      var replaced = false;
      for (final d in local) {
        if (d.id == widget.definition.id) {
          out.add(def);
          replaced = true;
        } else {
          out.add(d);
        }
      }
      if (!replaced) out.add(def);
      await store.saveLocal(out);
      await SourceManager().reload();
      if (!mounted) return;
      _toast('脚本已保存（${js.length} 字节）');
      Navigator.of(context).pop('saved');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败：${'$e'.split('\n').first}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scriptUrl = '${_config['scriptUrl'] ?? ''}'.trim();
    final card = _isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
    final fg = _isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '编辑脚本 · ${_config['name'] ?? ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) => Navigator.of(context).pop(v),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'test', child: Text('测试源')),
              const PopupMenuItem(value: 'settings', child: Text('源设置')),
              if (scriptUrl.isNotEmpty)
                const PopupMenuItem(value: 'refresh', child: Text('重新下载脚本')),
            ],
          ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _metaCard(card, fg, scriptUrl),
            const SizedBox(height: 10),
            TextField(
              controller: _name,
              style: TextStyle(fontSize: AppTheme.fontBody, color: fg),
              decoration: InputDecoration(
                labelText: '名称',
                hintText: '源显示名称',
                isDense: true,
                labelStyle: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: JellyTheme.textSecondary,
                ),
                border: UnderlineInputBorder(
                  borderSide: BorderSide(
                    color: JellyTheme.textSecondary.withValues(alpha: 0.25),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  '脚本',
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
                const SizedBox(width: 8),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _script,
                  builder: (_, v, __) => Text(
                    '${v.text.length} 字节',
                    style: TextStyle(
                      fontSize: 11,
                      color: JellyTheme.textSecondary,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  'class … extends ComicSource',
                  style: TextStyle(
                    fontSize: 11,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
            if (_scriptError != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _scriptError!,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Colors.redAccent,
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: card,
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: TextField(
                  controller: _script,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.5,
                    color: fg,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                  ),
                  onChanged: (v) {
                    if (_scriptError != null && _classRe.hasMatch(v)) {
                      setState(() => _scriptError = null);
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '脚本原样由内置 JS 运行时执行；保存后立即重载该源。',
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: JellyTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metaCard(Color card, Color fg, String scriptUrl) {
    final key = '${_config['key'] ?? ''}'.trim();
    final rows = <(String, String)>[
      ('标识', key.isEmpty ? widget.definition.id : key),
      (
        '版本',
        '${_config['version'] ?? ''}'.trim().isEmpty
            ? '—'
            : '${_config['version']}',
      ),
      if (scriptUrl.isNotEmpty) ('来源', scriptUrl),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(
                      r.$1,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: JellyTheme.textSecondary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      r.$2,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: fg),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
