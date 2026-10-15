import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../common/theme.dart';
import '../widgets/app_toast.dart';

/// 「Webhtv → WebHome 扩展」（第 3 步，用户 2026-10-15）。
///
/// 对齐 WebHomeTV 的「WebHome 扩展」：**给真实网页注入用户脚本**。本项目的注入
/// 宿主是「Webhtv」模块那个 WebView（`WebHomePage`）—— 它本来就会在页面加载完
/// 注入 `window.ant` SDK 与 `window.fm` 垫片，这一步只是把**用户自己的脚本**
/// 按匹配规则追加进去。
///
/// ── 本版做了什么 ────────────────────────────────────────────────
///   · 扩展的增删改查 + 启用开关（落盘持久化）
///   · 来源三种：**直接代码** / **远程链接**（注入 `<script src>`）/ **本地文件**
///     （从「文件」选入并复制进 App 目录，重启/清理后仍可用）
///   · 匹配范围：全部网页 / 网址包含 / 网址正则 / 站点 Key
///   · **真的注入**：Webhtv 的 WebView 每次页面加载完，按当前网址 + 当前网页源
///     解析出命中的扩展并执行
///
/// ── 未接入（页面上有明确标注，不做假 UI）────────────────────────
///   · 调试工作台（Web 预览 / Console / Network / Elements）
///   · 从源配置里多选 WebHome 站点（当前用「站点 Key」文本匹配代替）

/// 扩展脚本的来源形态。
enum ExtSource {
  code('直接代码'),
  url('远程链接'),
  file('本地文件');

  const ExtSource(this.label);
  final String label;
}

/// 匹配范围。
enum ExtMatch {
  any('全部网页'),
  urlContains('网址包含'),
  urlRegex('网址正则'),
  sourceKey('站点 Key');

  const ExtMatch(this.label);
  final String label;
}

class WebhtvExtension {
  const WebhtvExtension({
    required this.id,
    required this.name,
    this.enabled = true,
    this.source = ExtSource.code,
    this.content = '',
    this.match = ExtMatch.any,
    this.matchValue = '',
  });

  final String id;
  final String name;
  final bool enabled;
  final ExtSource source;

  /// `code` = JS 源码；`url` = 远程 JS 地址；`file` = App 目录里的绝对路径
  final String content;

  final ExtMatch match;

  /// 匹配值（`any` 时忽略）
  final String matchValue;

  WebhtvExtension copyWith({
    String? name,
    bool? enabled,
    ExtSource? source,
    String? content,
    ExtMatch? match,
    String? matchValue,
  }) =>
      WebhtvExtension(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        source: source ?? this.source,
        content: content ?? this.content,
        match: match ?? this.match,
        matchValue: matchValue ?? this.matchValue,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'source': source.name,
        'content': content,
        'match': match.name,
        'matchValue': matchValue,
      };

  static WebhtvExtension? fromJson(Map<String, dynamic> j) {
    final id = (j['id'] ?? '').toString();
    if (id.isEmpty) return null;
    ExtSource src = ExtSource.code;
    for (final v in ExtSource.values) {
      if (v.name == '${j['source']}') src = v;
    }
    ExtMatch mt = ExtMatch.any;
    for (final v in ExtMatch.values) {
      if (v.name == '${j['match']}') mt = v;
    }
    return WebhtvExtension(
      id: id,
      name: (j['name'] ?? '未命名').toString(),
      enabled: j['enabled'] != false,
      source: src,
      content: (j['content'] ?? '').toString(),
      match: mt,
      matchValue: (j['matchValue'] ?? '').toString(),
    );
  }

  /// 这条扩展是否命中当前页面
  bool matches({required String url, required String sourceKey}) {
    final v = matchValue.trim();
    switch (match) {
      case ExtMatch.any:
        return true;
      case ExtMatch.urlContains:
        return v.isNotEmpty && url.contains(v);
      case ExtMatch.urlRegex:
        if (v.isEmpty) return false;
        try {
          return RegExp(v).hasMatch(url);
        } catch (_) {
          return false;
        }
      case ExtMatch.sourceKey:
        return v.isNotEmpty && sourceKey == v;
    }
  }
}

/// 扩展的存储 + 注入脚本组装（单例）。
class WebhtvExtensionStore extends ChangeNotifier {
  WebhtvExtensionStore._();
  static final WebhtvExtensionStore instance = WebhtvExtensionStore._();

  static const String _kExtKey = 'webhtv_webhome_extensions';

  List<WebhtvExtension> _items = [];
  bool _loaded = false;

  List<WebhtvExtension> get items => List.unmodifiable(_items);
  bool get loaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kExtKey) ?? const <String>[];
      _items = raw
          .map((e) {
            try {
              final m = jsonDecode(e);
              return m is Map
                  ? WebhtvExtension.fromJson(Map<String, dynamic>.from(m))
                  : null;
            } catch (_) {
              return null;
            }
          })
          .whereType<WebhtvExtension>()
          .toList();
    } catch (_) {
      // ⚠️ 失败时**不要**把 `_items` 置空：随后任何一次 `_save()`（比如用户新增
      //   一条扩展）就会用这份空表**覆盖掉磁盘上原有的扩展**。
      //   也不置 `_loaded` ⇒ 下次进入本页会重试。
      return;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          _kExtKey, _items.map((e) => jsonEncode(e.toJson())).toList());
    } catch (_) {}
    notifyListeners();
  }

  Future<void> upsert(WebhtvExtension ext) async {
    final i = _items.indexWhere((e) => e.id == ext.id);
    if (i >= 0) {
      _items[i] = ext;
    } else {
      _items.add(ext);
    }
    await _save();
  }

  Future<void> remove(String id) async {
    _items.removeWhere((e) => e.id == id);
    await _save();
  }

  /// 给某个页面组装要注入的脚本（命中的扩展合成**一段** IIFE，逐个 try/catch，
  /// 某一个报错不影响其它扩展）。返回空串 = 没有命中任何扩展。
  Future<String> resolveFor({
    required String url,
    required String sourceKey,
  }) async {
    if (!_loaded) await load();
    final parts = <String>[];
    for (final e in _items) {
      if (!e.enabled) continue;
      if (!e.matches(url: url, sourceKey: sourceKey)) continue;
      final c = e.content.trim();
      if (c.isEmpty) continue;
      switch (e.source) {
        case ExtSource.code:
          parts.add(c);
        case ExtSource.url:
          // 远程链接：注入一个 <script src>，让它自己加载
          final u = jsonEncode(c);
          parts.add('(function(){var s=document.createElement("script");'
              's.src=$u;document.documentElement.appendChild(s);})();');
        case ExtSource.file:
          try {
            final f = File(c);
            if (await f.exists()) {
              final txt = await f.readAsString();
              if (txt.trim().isNotEmpty) parts.add(txt);
            }
          } catch (_) {}
      }
    }
    if (parts.isEmpty) return '';
    final body = parts
        .map((p) =>
            'try{\n$p\n}catch(e){console.warn("[Webhtv ext]", e && e.message);}')
        .join('\n');
    return ';(function(){try{\n$body\n}catch(e){}})();';
  }
}

// ============================================================
// 管理页
// ============================================================

class WebhtvExtensionPage extends StatefulWidget {
  const WebhtvExtensionPage({super.key});

  @override
  State<WebhtvExtensionPage> createState() => _WebhtvExtensionPageState();
}

class _WebhtvExtensionPageState extends State<WebhtvExtensionPage> {
  final _store = WebhtvExtensionStore.instance;

  @override
  void initState() {
    super.initState();
    _store.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _edit([WebhtvExtension? src]) async {
    final isNew = src == null;
    final nameC = TextEditingController(text: src?.name ?? '');
    final matchC = TextEditingController(text: src?.matchValue ?? '');
    final codeC = TextEditingController(
        text: src != null && src.source == ExtSource.code ? src.content : '');
    final urlC = TextEditingController(
        text: src != null && src.source == ExtSource.url ? src.content : '');
    var source = src?.source ?? ExtSource.code;
    var match = src?.match ?? ExtMatch.any;
    var enabled = src?.enabled ?? true;
    var filePath = src != null && src.source == ExtSource.file ? src.content : '';

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final isDark = Theme.of(ctx).brightness == Brightness.dark;
          final fg = isDark ? Colors.white : AppTheme.textPrimary;
          final sub = isDark
              ? Colors.white.withValues(alpha: 0.55)
              : AppTheme.textSecondary;
          Widget field(String label, TextEditingController c,
                  {String? hint, int maxLines = 1}) =>
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            fontSize: AppTheme.fontSubhead, color: fg)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: c,
                      maxLines: maxLines,
                      style: TextStyle(
                          fontSize: AppTheme.fontFootnote, color: fg),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: hint,
                        hintStyle: TextStyle(
                            fontSize: AppTheme.fontFootnote, color: sub),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              );
          Widget seg<T>(List<T> values, T cur, String Function(T) label,
                  ValueChanged<T> onPick) =>
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final v in values)
                    GestureDetector(
                      onTap: () => setLocal(() => onPick(v)),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: v == cur
                              ? AppTheme.accentSurface
                              : AppTheme.backgroundTertiary,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: v == cur
                                ? AppTheme.accentOnSurface
                                    .withValues(alpha: 0.5)
                                : Colors.transparent,
                          ),
                        ),
                        child: Text(label(v),
                            style: TextStyle(
                                fontSize: AppTheme.fontFootnote,
                                fontWeight: v == cur
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: v == cur
                                    ? AppTheme.accentOnSurface
                                    : fg)),
                      ),
                    ),
                ],
              );

          return Container(
            padding: EdgeInsets.fromLTRB(
                20, 16, 20, 16 + MediaQuery.of(ctx).viewInsets.bottom),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.backgroundSecondary : Colors.white,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(isNew ? '新增扩展' : '编辑扩展',
                      style: TextStyle(
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w600,
                          color: fg)),
                  const SizedBox(height: 14),
                  field('名称', nameC, hint: '如 去广告 / 净化'),
                  Text('来源',
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead, color: fg)),
                  const SizedBox(height: 6),
                  seg(ExtSource.values, source, (v) => v.label,
                      (v) => source = v),
                  const SizedBox(height: 12),
                  if (source == ExtSource.code)
                    field('JS 代码', codeC,
                        hint: 'document.querySelectorAll("video").length',
                        maxLines: 6)
                  else if (source == ExtSource.url)
                    field('远程链接', urlC, hint: 'https://…/ext.js')
                  else
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            filePath.isEmpty
                                ? '未选择文件'
                                : filePath.split('/').last,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: AppTheme.fontFootnote, color: sub),
                          ),
                        ),
                        TextButton(
                          onPressed: () async {
                            final p = await _pickFile();
                            if (p != null) setLocal(() => filePath = p);
                          },
                          child: const Text('选择文件'),
                        ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  Text('匹配范围',
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead, color: fg)),
                  const SizedBox(height: 6),
                  seg(ExtMatch.values, match, (v) => v.label,
                      (v) => match = v),
                  if (match != ExtMatch.any) ...[
                    const SizedBox(height: 10),
                    field(
                        match == ExtMatch.sourceKey
                            ? '站点 Key'
                            : (match == ExtMatch.urlRegex ? '正则' : '包含的文本'),
                        matchC,
                        hint: match == ExtMatch.sourceKey
                            ? '当前网页源的 id'
                            : (match == ExtMatch.urlRegex
                                ? r'例：^https://www\.xxx\.com/'
                                : '例：xxx.com')),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: Text('启用',
                            style: TextStyle(
                                fontSize: AppTheme.fontSubhead, color: fg)),
                      ),
                      Switch(
                          value: enabled,
                          onChanged: (v) => setLocal(() => enabled = v)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text('取消',
                              style: TextStyle(color: AppTheme.textTertiary)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.accentSurface,
                            foregroundColor: AppTheme.accentOnSurface,
                          ),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('保存'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (ok != true) return;

    final content = source == ExtSource.code
        ? codeC.text
        : (source == ExtSource.url ? urlC.text.trim() : filePath);
    if (content.trim().isEmpty) {
      AppToast.message('内容不能为空');
      return;
    }
    await _store.upsert(WebhtvExtension(
      id: src?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: nameC.text.trim().isEmpty ? '未命名' : nameC.text.trim(),
      enabled: enabled,
      source: source,
      content: content,
      match: match,
      matchValue: matchC.text.trim(),
    ));
    if (mounted) {
      setState(() {});
      AppToast.message('已保存');
    }
  }

  /// 选本地 JS 文件并复制进 App 目录（沙箱外的临时路径重启后就没了）
  Future<String?> _pickFile() async {
    try {
      final res = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['js', 'txt', 'css'],
      );
      if (res.isEmpty) return null;
      final f = res.first;
      var bytes = const <int>[];
      try {
        bytes = await f.readAsBytes();
      } catch (_) {
        final p = f.path;
        if (p == null) return null;
        bytes = await File(p).readAsBytes();
      }
      if (bytes.isEmpty) return null;
      final dir = await getApplicationSupportDirectory();
      final extDir = Directory('${dir.path}/webhome/ext');
      if (!await extDir.exists()) await extDir.create(recursive: true);
      final safe = f.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final dst = File('${extDir.path}/${DateTime.now().millisecondsSinceEpoch}_$safe');
      await dst.writeAsBytes(bytes);
      return dst.path;
    } catch (e) {
      AppToast.error('选文件失败：$e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppTheme.textPrimary;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : AppTheme.textSecondary;
    final items = _store.items;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        iconTheme: IconThemeData(color: fg),
        title: Text('WebHome 扩展',
            style: TextStyle(
                color: fg,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: '新增扩展',
            onPressed: () => _edit(),
            icon: Icon(Icons.add_rounded, color: fg),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          Text(
            '命中的扩展会在「Webhtv」网页每次加载完成后注入执行（与 window.ant / '
            'window.fm 同一时机）。',
            style:
                TextStyle(fontSize: AppTheme.fontCaption, color: sub, height: 1.5),
          ),
          const SizedBox(height: 6),
          Text(
            '⚠️ 调试工作台（Web 预览 / Console / Network / Elements）尚未接入。',
            style:
                TextStyle(fontSize: AppTheme.fontCaption, color: sub, height: 1.5),
          ),
          const SizedBox(height: 14),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text('还没有扩展，点右上角「+」新增',
                    style:
                        TextStyle(fontSize: AppTheme.fontSubhead, color: sub)),
              ),
            )
          else
            for (final e in items) _card(e, fg, sub, isDark),
        ],
      ),
    );
  }

  Widget _card(WebhtvExtension e, Color fg, Color sub, bool isDark) {
    final matchDesc = e.match == ExtMatch.any
        ? '全部网页'
        : '${e.match.label}：${e.matchValue}';
    final srcDesc = switch (e.source) {
      ExtSource.code => '直接代码',
      ExtSource.url => '远程链接',
      ExtSource.file => '本地文件',
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFF4F5F7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: e.enabled
              ? AppTheme.accentOnSurface.withValues(alpha: 0.35)
              : (isDark ? Colors.white12 : Colors.black12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(e.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600,
                        color: fg)),
              ),
              Switch(
                value: e.enabled,
                onChanged: (v) async {
                  await _store.upsert(e.copyWith(enabled: v));
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          Text('$srcDesc · $matchDesc',
              style: TextStyle(fontSize: AppTheme.fontCaption, color: sub)),
          Row(
            children: [
              const Spacer(),
              IconButton(
                tooltip: '编辑',
                onPressed: () => _edit(e),
                icon: Icon(Icons.edit_outlined, size: 18, color: sub),
              ),
              IconButton(
                tooltip: '删除',
                onPressed: () async {
                  await _store.remove(e.id);
                  if (mounted) setState(() {});
                },
                icon: Icon(Icons.delete_outline, size: 18, color: sub),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
