// lib/music/pages/plugin_variables_page.dart
//
// 「插件变量 / 登录」页 —— 2026-10-21 第三期。
//
// MusicFree 插件可以在导出里声明：
//   userVariables: [{ key: 'biliCookie', name: 'B站 Cookie', hint: '…' }]
// 运行时通过 `global.env.getUserVariables()` 读取。
//
// 这里把声明读出来渲染成输入框，用户填的值存进
// `ThirdPartySource.variables`，之后每次加载插件都会注入沙箱。

import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../widgets/app_toast.dart';
import '../models/third_party_source.dart';
import '../services/music_api.dart';
import '../theme/music_theme.dart';

class PluginVariablesPage extends StatefulWidget {
  const PluginVariablesPage({super.key, required this.source});

  final ThirdPartySource source;

  @override
  State<PluginVariablesPage> createState() => _PluginVariablesPageState();
}

class _PluginVariablesPageState extends State<PluginVariablesPage> {
  bool _loading = true;
  String _error = '';

  /// key → 输入框（初始值来自已保存的 variables）
  final Map<String, TextEditingController> _ctrls = {};
  List<({String key, String name, String hint})> _fields = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final fields = await MusicApi.instance.musicFreeVariables(widget.source);
      if (!mounted) return;
      for (final f in fields) {
        _ctrls[f.key] = TextEditingController(
          text: widget.source.variables[f.key] ?? '',
        );
      }
      setState(() {
        _fields = fields;
        _loading = false;
        if (fields.isEmpty) {
          _error = '该插件没有声明可配置的变量（不需要登录/卡密）';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _save() async {
    final values = <String, String>{};
    _ctrls.forEach((k, c) {
      final v = c.text.trim();
      if (v.isNotEmpty) values[k] = v;
    });
    await ThirdPartySourceStore.instance.upsert(
      widget.source.copyWith(variables: values),
    );
    if (!mounted) return;
    AppToast.success('已保存，重启 App 后完全生效');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        backgroundColor: MusicTheme.background,
        appBar: AppBar(
          backgroundColor: MusicTheme.background,
          elevation: 0,
          iconTheme: IconThemeData(color: MusicTheme.label),
          title: Text(
            '${widget.source.name} · 变量',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontHeadline,
            ),
          ),
          actions: [
            if (!_loading && _fields.isNotEmpty)
              TextButton(
                onPressed: _save,
                child: Text(
                  '保存',
                  style: TextStyle(color: MusicTheme.tint),
                ),
              ),
          ],
        ),
        body: _loading
            ? Center(child: CircularProgressIndicator(color: MusicTheme.tint))
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                children: [
                  Text(
                    '这些值会注入到插件的 global.env.getUserVariables()；'
                    '登录态（Cookie/Token）只保存在本机。'
                    '部分插件在加载时决定音质档位，填完重启 App 才完全生效。',
                    style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontFootnote,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (_error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        _error,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontSubhead,
                        ),
                      ),
                    ),
                  for (final f in _fields) _fieldCard(f),
                ],
              ),
      ),
    );
  }

  Widget _fieldCard(({String key, String name, String hint}) f) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: MusicTheme.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            f.name,
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (f.hint.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              f.hint,
              style: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontFootnote,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 10),
          TextField(
            controller: _ctrls[f.key],
            maxLines: 2,
            minLines: 1,
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontSubhead,
            ),
            cursorColor: MusicTheme.tint,
            decoration: InputDecoration(
              hintText: '未配置（key: ${f.key}）',
              hintStyle: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontSubhead,
              ),
              filled: true,
              fillColor: MusicTheme.fill,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
