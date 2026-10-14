// lib/rss/widgets/rss_login_sheet.dart
//
// `loginUi` 登录表单（Legado 订阅源/书源规范字段）。
//
// 文档来源：https://mgz0227.github.io/The-tutorial-of-Legado/Rule/rss.html
//
// `loginUi` 是一个 JSON 数组，每项形如：
//   { "name": "选择影视源站", "type": "select",
//     "chars": ["0-红牛资源", "1-光速资源", …], "default": "0-红牛资源" }
//   { "name": "调试模式", "type": "toggle", "chars": ["🔳关闭", "✅开启"],
//     "default": "🔳关闭", "style": { … } }
//
// 用户填完之后由源自己的 jsLib 钩子（约定名 `upLoginData`）写回
// `source.setLoginInfoMap(...)`，源的 `sortUrl` / `searchUrl` 再通过
// `source.getLoginInfoMap()` 读它来选源站 —— 这就是「切影视源站」的实现方式。
//
// ⚠️ `toggle` 必须传**真布尔值**（不是 "true"/"false" 字符串）：
//   源里写的是 `!!formData["调试模式"]`，而 JS 里任何非空字符串都是 truthy，
//   传字符串会让开关永远判成 true。

import 'dart:convert';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../widgets/common_widgets.dart';

/// `loginUi` 里的一项。
class RssLoginField {
  RssLoginField({
    required this.name,
    required this.type,
    required this.chars,
    required this.defaultValue,
  });

  final String name;

  /// `select` / `toggle` / `text` / `password` / `button`
  final String type;
  final List<String> chars;
  final String defaultValue;

  bool get isSelect => type == 'select' && chars.isNotEmpty;
  bool get isToggle => type == 'toggle';

  /// 解析 `loginUi`（解析不出来就返回空表，调用方据此隐藏入口）。
  static List<RssLoginField> parse(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return const [];
    try {
      final d = jsonDecode(t);
      if (d is! List) return const [];
      final out = <RssLoginField>[];
      for (final e in d) {
        if (e is! Map) continue;
        final name = (e['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        final chars =
            (e['chars'] is List) ? (e['chars'] as List).map((x) => '$x').toList() : <String>[];
        out.add(RssLoginField(
          name: name,
          type: (e['type'] ?? 'text').toString().trim().toLowerCase(),
          chars: chars,
          defaultValue: (e['default'] ?? '').toString(),
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}

/// 弹出登录表单；返回用户填的值（`toggle` 是真布尔），取消返回 null。
Future<Map<String, dynamic>?> showRssLoginSheet(
  BuildContext context, {
  required String title,
  required List<RssLoginField> fields,
  required Map<String, dynamic> initial,
}) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.backgroundSecondary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _RssLoginSheet(
      title: title,
      fields: fields,
      initial: initial,
    ),
  );
}

class _RssLoginSheet extends StatefulWidget {
  const _RssLoginSheet({
    required this.title,
    required this.fields,
    required this.initial,
  });

  final String title;
  final List<RssLoginField> fields;
  final Map<String, dynamic> initial;

  @override
  State<_RssLoginSheet> createState() => _RssLoginSheetState();
}

class _RssLoginSheetState extends State<_RssLoginSheet> {
  /// 逐字段当前值：select/text → String，toggle → bool
  final Map<String, dynamic> _values = {};

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      final cur = widget.initial[f.name];
      if (f.isToggle) {
        // 兼容三种历史形态：真布尔 / "true" / 两个 chars 文案之一
        var on = cur == true ||
            '$cur'.toLowerCase() == 'true' ||
            (f.chars.length > 1 && '$cur' == f.chars[1]);
        if (cur == null) {
          on = f.chars.isNotEmpty && f.defaultValue == f.chars[1];
        }
        _values[f.name] = on;
      } else {
        var v = cur == null ? '' : '$cur';
        if (v.isEmpty) v = f.defaultValue;
        if (f.isSelect && v.isNotEmpty && !f.chars.contains(v)) {
          // 源改过 options：老值不在列表里 ⇒ 回落到默认/首项
          v = f.chars.contains(f.defaultValue)
              ? f.defaultValue
              : (f.chars.isNotEmpty ? f.chars.first : v);
        }
        _values[f.name] = v;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHandle(),
              const SizedBox(height: 14),
              Text('登录 / 源站设置',
                  style: TextStyle(
                      fontSize: AppTheme.fontTitle3,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 4),
              Text(widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: AppTheme.textTertiary)),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final f in widget.fields) _field(f),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, _values),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(RssLoginField f) {
    final label = Text(f.name,
        style: TextStyle(
            fontSize: AppTheme.fontSubhead, color: AppTheme.textPrimary));
    if (f.isToggle) {
      final on = _values[f.name] == true;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Expanded(child: label),
            Switch(
              value: on,
              activeThumbColor: AppTheme.accentColor,
              onChanged: (v) => setState(() => _values[f.name] = v),
            ),
          ],
        ),
      );
    }
    if (f.isSelect) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label,
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.borderLight, width: 0.5),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: '${_values[f.name]}',
                  isExpanded: true,
                  dropdownColor: AppTheme.backgroundSecondary,
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: AppTheme.textPrimary),
                  items: [
                    for (final c in f.chars)
                      DropdownMenuItem<String>(
                          value: c,
                          child: Text(c,
                              maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _values[f.name] = v ?? ''),
                ),
              ),
            ),
          ],
        ),
      );
    }
    // text / password / button（button 当只读说明处理）
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label,
          const SizedBox(height: 6),
          TextFormField(
            initialValue: '${_values[f.name]}',
            obscureText: f.type == 'password',
            style: TextStyle(
                fontSize: AppTheme.fontSubhead, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: AppTheme.backgroundTertiary,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
            onChanged: (v) => _values[f.name] = v,
          ),
        ],
      ),
    );
  }
}
