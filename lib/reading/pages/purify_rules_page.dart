import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/reading/models/reading_settings.dart';
import 'package:tvbox/reading/theme/jelly_theme.dart';

/// 「我的 → 净化规则」：照 Legado 的**替换净化**管理页做的全局规则面板。
///
/// 为什么单独一页（用户 2026-10-25：「阅读的净化管理和导入不在这个阅读模块的
/// 我的页面么？」）：
///   · 原来只能在**打开一本书 → 功能面板 → 正文净化**里管，换本书就得重新找；
///   · 规则其实是**全局**的（存在 `reading.settings` 的 `purifyRules`），
///     本来就不该藏在某本书的面板里。
///
/// 读写的就是阅读器那一份设置：`SharedPreferences['reading.settings']`，
/// 改完下次打开书即生效（阅读器每次进页面都会读这一份）。
class PurifyRulesPage extends StatefulWidget {
  const PurifyRulesPage({super.key});

  @override
  State<PurifyRulesPage> createState() => _PurifyRulesPageState();
}

class _PurifyRulesPageState extends State<PurifyRulesPage> {
  List<PurifyRule> _rules = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 读全局阅读设置里的规则（缺失就用默认集）
  Future<void> _load() async {
    List<PurifyRule> list = defaultPurifyRules;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('reading.settings');
      if (raw != null && raw.isNotEmpty) {
        final rs = ReadingSettings.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>(),
        );
        list = rs.purifyRules;
      }
    } catch (_) {
      // 设置坏了就用默认规则，别让入口打不开
    }
    if (!mounted) return;
    setState(() {
      _rules = List<PurifyRule>.from(list);
      _loading = false;
    });
  }

  /// 写回全局设置（只动 purifyRules，其它设置原样保留）
  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      var rs = ReadingSettings();
      final raw = p.getString('reading.settings');
      if (raw != null && raw.isNotEmpty) {
        rs = ReadingSettings.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>(),
        );
      }
      await p.setString(
        'reading.settings',
        jsonEncode(rs.copyWith(purifyRules: List.from(_rules)).toJson()),
      );
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));
  }

  // ── 规则增删改 ─────────────────────────────────────────────

  Future<void> _editRule({PurifyRule? origin}) async {
    final nameC = TextEditingController(text: origin?.name ?? '');
    final patC = TextEditingController(text: origin?.pattern ?? '');
    final repC = TextEditingController(text: origin?.replacement ?? '');
    final scopeC = TextEditingController(text: origin?.bookScope ?? '');
    final exclC = TextEditingController(text: origin?.excludeScope ?? '');
    var isRegex = origin?.isRegex ?? true;
    var forTitle = origin?.applyToTitle ?? false;
    var forContent = origin?.applyToContent ?? true;
    var enabled = origin?.enabled ?? true;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  origin == null ? '新增净化规则' : '编辑规则',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                _field(nameC, '名称（可空，列表里显示）'),
                const SizedBox(height: 10),
                _field(patC, isRegex ? '正则（匹配要清除的文本）' : '文本（匹配要清除的内容）'),
                const SizedBox(height: 10),
                _field(repC, '替换为（留空 = 删除）'),
                const SizedBox(height: 10),
                _field(scopeC, '生效范围：书名包含这个词（可空 = 所有书）'),
                const SizedBox(height: 10),
                _field(exclC, '排除范围：书名包含这个词就跳过（可空）'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _chip('正则', isRegex, (v) => setSheet(() => isRegex = v)),
                    _chip('用于正文', forContent, (v) => setSheet(() => forContent = v)),
                    _chip('用于标题', forTitle, (v) => setSheet(() => forTitle = v)),
                    _chip('启用', enabled, (v) => setSheet(() => enabled = v)),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    final pattern = patC.text.trim();
    if (pattern.isEmpty) {
      _toast('正则/文本不能为空');
      return;
    }
    if (isRegex) {
      try {
        RegExp(pattern);
      } catch (e) {
        _toast('正则不合法：$e');
        return;
      }
    }
    final rule = PurifyRule(
      name: nameC.text.trim(),
      group: origin?.group ?? '自定义',
      pattern: pattern,
      replacement: repC.text,
      enabled: enabled,
      isRegex: isRegex,
      bookScope: scopeC.text.trim(),
      excludeScope: exclC.text.trim(),
      applyToTitle: forTitle,
      applyToContent: forContent,
    );
    setState(() {
      if (origin == null) {
        _rules = [..._rules, rule];
      } else {
        final i = _rules.indexOf(origin);
        if (i >= 0) {
          final list = List<PurifyRule>.from(_rules);
          list[i] = rule;
          _rules = list;
        }
      }
    });
    await _save();
    _toast(origin == null ? '已添加规则' : '已保存');
  }

  Widget _field(TextEditingController c, String label) {
    return TextField(
      controller: c,
      style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
        isDense: true,
        filled: true,
        fillColor: AppTheme.backgroundTertiary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _chip(String label, bool selected, ValueChanged<bool> onTap) {
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: onTap,
      selectedColor: JellyTheme.primary.withValues(alpha: 0.18),
      checkmarkColor: JellyTheme.primary,
      labelStyle: TextStyle(
        color: selected ? JellyTheme.primary : AppTheme.textSecondary,
      ),
      side: BorderSide(color: AppTheme.borderLight, width: 0.6),
      backgroundColor: AppTheme.backgroundTertiary,
    );
  }

  // ── 导入 / 导出 ────────────────────────────────────────────

  Future<void> _export() async {
    final json = const JsonEncoder.withIndent('  ')
        .convert(_rules.map((r) => r.toJson()).toList());
    await Clipboard.setData(ClipboardData(text: json));
    _toast('已复制 ${_rules.length} 条规则到剪贴板');
  }

  Future<void> _import() async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          '导入替换净化',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 16),
        ),
        content: TextField(
          controller: c,
          maxLines: 8,
          minLines: 4,
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
          decoration: InputDecoration(
            hintText: '粘贴 legado 的 replaceRule JSON，\n'
                '或 json 的 http(s) 链接，\n'
                '或 legado://import/replaceRule?src=...',
            hintStyle: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
            filled: true,
            fillColor: AppTheme.backgroundTertiary,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    var raw = c.text.trim();
    if (raw.isEmpty) return;
    // legado://import/replaceRule?src=<urlencoded JSON/URL>
    if (raw.startsWith('legado://')) {
      final q = Uri.tryParse(raw)?.queryParameters;
      raw = (q?['src'] ?? '').trim();
      if (raw.isEmpty) {
        _toast('链接里没有 src 参数');
        return;
      }
      raw = Uri.decodeComponent(raw);
    }
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      _toast('正在下载规则…');
      try {
        raw = await _fetchText(raw);
      } catch (e) {
        _toast('下载失败：$e');
        return;
      }
    }
    try {
      final skipped = <String>[];
      final parsed = parseLegadoReplaceRules(jsonDecode(raw), skipped: skipped);
      if (parsed.isEmpty) {
        _toast(skipped.isEmpty
            ? '没有解析到规则'
            : '解析到 ${skipped.length} 条，但都是 JS 脚本/仅标题规则');
        return;
      }
      final exist = _rules.map((e) => e.pattern).toSet();
      var added = 0;
      final list = List<PurifyRule>.from(_rules);
      for (final r in parsed) {
        if (exist.add(r.pattern)) {
          list.add(r);
          added++;
        }
      }
      setState(() => _rules = list);
      await _save();
      _toast('已导入 $added 条'
          '${skipped.isEmpty ? '' : '，跳过 ${skipped.length} 条（@js 脚本/仅标题）'}');
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  /// 拉远程规则集（第三方静态文件，不挂全局代理）
  Future<String> _fetchText(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw 'HTTP ${res.statusCode}';
      }
      final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }

  // ── 页面 ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final enabled = _rules.where((r) => r.enabled).length;
    return Scaffold(
        appBar: AppBar(
          title: const Text('净化规则'),
          actions: [
            IconButton(
              tooltip: '导入',
              icon: const Icon(Icons.file_download_outlined),
              onPressed: _import,
            ),
            IconButton(
              tooltip: '导出（复制 JSON）',
              icon: const Icon(Icons.file_upload_outlined),
              onPressed: _export,
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _editRule(),
          icon: const Icon(Icons.add_rounded),
          label: const Text('新增规则'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '共 ${_rules.length} 条 · 已启用 $enabled 条\n'
                      '正则替换章节正文里的站点残留文案；'
                      '「范围」按书名包含关键词匹配，空 = 所有书。',
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: 11.5,
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final r in _rules) _ruleCard(r),
                ],
              ),
    );
  }

  Widget _ruleCard(PurifyRule r) {
    final title = r.name.trim().isEmpty ? r.pattern : r.name;
    final sub = r.replacement.isEmpty
        ? (r.isRegex ? '正则 · 删除匹配内容' : '文本 · 删除匹配内容')
        : '→ ${r.replacement}';
    final tags = <String>[
      if (r.applyToContent) '正文',
      if (r.applyToTitle) '标题',
      if (r.bookScope.trim().isNotEmpty) '范围:${r.bookScope}',
      if (r.excludeScope.trim().isNotEmpty) '排除:${r.excludeScope}',
      if (!r.isRegex) '纯文本',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _editRule(origin: r),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: 11.5,
                        fontFamily: r.isRegex ? 'monospace' : null,
                      ),
                    ),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        tags.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Switch(
                value: r.enabled,
                onChanged: (v) async {
                  final i = _rules.indexOf(r);
                  if (i < 0) return;
                  final list = List<PurifyRule>.from(_rules);
                  list[i] = r.copyWith(enabled: v);
                  setState(() => _rules = list);
                  await _save();
                },
              ),
              IconButton(
                tooltip: '删除',
                icon: Icon(Icons.delete_outline_rounded,
                    size: 20, color: AppTheme.textTertiary),
                onPressed: () async {
                  final i = _rules.indexOf(r);
                  if (i < 0) return;
                  final list = List<PurifyRule>.from(_rules)..removeAt(i);
                  setState(() => _rules = list);
                  await _save();
                  _toast('已删除');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
