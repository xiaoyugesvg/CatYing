// 书源编辑页：修改书源名称 / 分组 / 注释 / 启用状态，并可查看完整源内容。
//
// 与漫画源仓库的编辑能力对齐（漫画源仓库只允许改名称/内容）：
// 这里开放名称、分组、注释、URL 四项文本编辑，规则内容以只读 JSON 展示，
// 完整规则编辑留待后续（进入阅读器后逐源调试）。

import 'dart:convert';

import 'package:flutter/material.dart';

import '../novel_source/shuyuan_source_service.dart';
import '../services/shuyuan_source_store.dart';
import '../theme/jelly_theme.dart';

class ShuyuanSourceEditPage extends StatefulWidget {
  final ShuyuanSource source;

  const ShuyuanSourceEditPage({super.key, required this.source});

  @override
  State<ShuyuanSourceEditPage> createState() => _ShuyuanSourceEditPageState();
}

class _ShuyuanSourceEditPageState extends State<ShuyuanSourceEditPage> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _groupCtrl;
  late final TextEditingController _commentCtrl;
  late final TextEditingController _urlCtrl;
  late bool _enabled;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.source.bookSourceName);
    _groupCtrl =
        TextEditingController(text: widget.source.bookSourceGroup ?? '');
    _commentCtrl =
        TextEditingController(text: widget.source.bookSourceComment ?? '');
    _urlCtrl = TextEditingController(text: widget.source.bookSourceUrl);
    _enabled = widget.source.enabled;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _groupCtrl.dispose();
    _commentCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('名称不能为空')));
      return;
    }
    setState(() => _busy = true);
    final old = widget.source;
    final updated = ShuyuanSource(
      bookSourceName: name,
      bookSourceUrl: _urlCtrl.text.trim().isEmpty
          ? old.bookSourceUrl
          : _urlCtrl.text.trim(),
      bookSourceType: old.bookSourceType,
      bookSourceGroup: _groupCtrl.text.trim().isEmpty
          ? null
          : _groupCtrl.text.trim(),
      bookSourceComment: _commentCtrl.text.trim().isEmpty
          ? null
          : _commentCtrl.text.trim(),
      enabled: _enabled,
      searchUrl: old.searchUrl,
      exploreUrl: old.exploreUrl,
      header: old.header,
      tocUrl: old.tocUrl,
      ruleSearch: old.ruleSearch,
      ruleBookInfo: old.ruleBookInfo,
      ruleToc: old.ruleToc,
      ruleContent: old.ruleContent,
      ruleExplore: old.ruleExplore,
      filters: old.filters,
      homeSections: old.homeSections,
    );
    await ShuyuanSourceStore.instance.addSource(updated);
    if (mounted) {
      setState(() => _busy = false);
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑书源'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '源名称',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
              isDense: true,
              hintText: '书源名称',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 14),
          Text(
            '源地址（URL）',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _urlCtrl,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'https://example.com',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 14),
          Text(
            '分组',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _groupCtrl,
            decoration: InputDecoration(
              isDense: true,
              hintText: '如：自制 / 精选',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 14),
          Text(
            '注释',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _commentCtrl,
            maxLines: 3,
            minLines: 2,
            decoration: InputDecoration(
              isDense: true,
              hintText: '书源说明',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 14),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用该源'),
            subtitle: const Text('关闭后不参与聚搜与浏览'),
            value: _enabled,
            activeThumbColor: JellyTheme.primary,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 20),
          Text(
            '源内容（只读预览）',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? JellyTheme.cardDark
                  : JellyTheme.cardLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              _prettyJson(widget.source.toJson()),
              style: const TextStyle(fontSize: 11, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  String _prettyJson(Map<String, dynamic> map) {
    final encoder = const JsonEncoder.withIndent('  ');
    return encoder.convert(map);
  }
}
