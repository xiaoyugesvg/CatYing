import 'dart:convert';

import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../models/source_bean.dart';
import '../services/api_config.dart';
import '../widgets/app_toast.dart';

/// 「Webhtv → 站点注入」（第 2 步，用户 2026-10-15）。
///
/// 对齐 WebHomeTV 的「站点注入」：添加自定义 WebHome / CSP 站点，**独立表单**里
/// 维护「启用状态 / 插入位置 / 首页 / 搜索与换源行为」；顶部「识别」可粘贴单个或
/// 多个松散站点 JSON 片段并自动归类追加。
///
/// 注入落到本项目已有的「用户线路」存储（`ApiConfig.addUserVideoSource` →
/// `user_video_sources`），它会在每次线路表整表替换后**自动合并回来**，
/// 所以切订阅也不会丢 —— 不需要另起一套机制。
///
/// ⚠️ 诚实说明：`homePage`（用网页当这个站点的首页）**本版只落库、尚未接入渲染**，
///    表单里已明确标注；其余字段（启用 / 插入位置 / 搜索三开关 / 类型 / 接口）
///    都是**真实生效**的。
class WebhtvSiteInjectPage extends StatefulWidget {
  const WebhtvSiteInjectPage({super.key});

  @override
  State<WebhtvSiteInjectPage> createState() => _WebhtvSiteInjectPageState();
}

class _WebhtvSiteInjectPageState extends State<WebhtvSiteInjectPage> {
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await ApiConfig.instance.userInjectedSites();
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
    });
  }

  /// 把一条（可能来自"识别"的松散）JSON 落库。
  Future<void> _saveMap(Map<String, dynamic> m, {bool? enabled}) async {
    final api = (m['api'] ?? '').toString().trim();
    final key = (m['key'] ?? m['name'] ?? m['api'] ?? '')
        .toString()
        .trim();
    if (key.isEmpty) return;
    final bean = SourceBean(
      key: key,
      name: (m['name'] ?? key).toString(),
      api: api,
      type: (m['type'] as num?)?.toInt() ??
          (api.toLowerCase().startsWith('csp_') ? 3 : 3),
      searchable: (m['searchable'] as num?)?.toInt() ?? 1,
      quickSearch: (m['quickSearch'] as num?)?.toInt() ?? 0,
      filterable: (m['filterable'] as num?)?.toInt() ?? 0,
      indexs: (m['indexs'] as num?)?.toInt() ?? 0,
      playerType: 0,
      ext: m['ext']?.toString(),
    );
    await ApiConfig.instance.addUserVideoSource(
      bean,
      enabled: enabled ?? (m['enabled'] != false),
      homePage: (m['homePage'] ?? '').toString(),
    );
  }

  // ============================================================
  // 表单（新增 / 编辑）
  // ============================================================

  Future<void> _edit([Map<String, dynamic>? src]) async {
    final isNew = src == null;
    final nameC = TextEditingController(text: (src?['name'] ?? '').toString());
    final keyC = TextEditingController(text: (src?['key'] ?? '').toString());
    final apiC = TextEditingController(text: (src?['api'] ?? '').toString());
    final homeC =
        TextEditingController(text: (src?['homePage'] ?? '').toString());
    var type = (src?['type'] as num?)?.toInt() ?? 3;
    var indexs = (src?['indexs'] as num?)?.toInt() ?? 0;
    var enabled = src?['enabled'] != false;
    var searchable = ((src?['searchable'] as num?)?.toInt() ?? 1) == 1;
    var quick = ((src?['quickSearch'] as num?)?.toInt() ?? 0) == 1;
    var filterable = ((src?['filterable'] as num?)?.toInt() ?? 0) == 1;

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
                        style: TextStyle(fontSize: AppTheme.fontSubhead, color: fg)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: c,
                      maxLines: maxLines,
                      style: TextStyle(fontSize: AppTheme.fontSubhead, color: fg),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: hint,
                        hintStyle:
                            TextStyle(fontSize: AppTheme.fontSubhead, color: sub),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              );
          Widget sw(String label, bool v, ValueChanged<bool> onChanged) => Row(
                children: [
                  Expanded(
                    child: Text(label,
                        style:
                            TextStyle(fontSize: AppTheme.fontSubhead, color: fg)),
                  ),
                  Switch(value: v, onChanged: onChanged),
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
                  Text(isNew ? '新增站点' : '编辑站点',
                      style: TextStyle(
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w600,
                          color: fg)),
                  const SizedBox(height: 14),
                  field('名称', nameC, hint: '如 Nostr推荐'),
                  field('Key', keyC, hint: '站点唯一标识，如 Nostr'),
                  field('接口 api', apiC,
                      hint: 'csp_Nostr / https://…/x.js / /spider/xxx/3'),
                  field('首页 homePage（可选）', homeC, hint: 'https://…/nostr.html'),
                  Text('⚠️ homePage 本版只保存、尚未接入渲染',
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption, color: sub)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text('类型',
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead, color: fg)),
                      const SizedBox(width: 12),
                      _seg(fg, 'CatVod/JS(3)', type == 3,
                          () => setLocal(() => type = 3)),
                      const SizedBox(width: 8),
                      _seg(fg, 'TVBox(4)', type == 4,
                          () => setLocal(() => type = 4)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text('插入位置',
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead, color: fg)),
                      const SizedBox(width: 12),
                      _seg(fg, '末尾', indexs != -1,
                          () => setLocal(() => indexs = 0)),
                      const SizedBox(width: 8),
                      _seg(fg, '最前', indexs == -1,
                          () => setLocal(() => indexs = -1)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  sw('启用', enabled, (v) => setLocal(() => enabled = v)),
                  sw('参与搜索', searchable,
                      (v) => setLocal(() => searchable = v)),
                  sw('快速搜索', quick, (v) => setLocal(() => quick = v)),
                  sw('参与筛选', filterable,
                      (v) => setLocal(() => filterable = v)),
                  const SizedBox(height: 12),
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
                          onPressed: () {
                            if (keyC.text.trim().isEmpty &&
                                nameC.text.trim().isEmpty) {
                              AppToast.message('Key 和名称至少要填一个');
                              return;
                            }
                            Navigator.pop(ctx, true);
                          },
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

    final key = keyC.text.trim().isEmpty ? nameC.text.trim() : keyC.text.trim();
    await _saveMap({
      'key': key,
      'name': nameC.text.trim().isEmpty ? key : nameC.text.trim(),
      'api': apiC.text.trim(),
      'type': type,
      'indexs': indexs,
      'enabled': enabled,
      'searchable': searchable ? 1 : 0,
      'quickSearch': quick ? 1 : 0,
      'filterable': filterable ? 1 : 0,
      'homePage': homeC.text.trim(),
      'ext': src?['ext'],
    });
    await _reload();
    if (mounted) AppToast.message('已保存「$key」');
  }

  Widget _seg(Color fg, String label, bool on, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: on ? AppTheme.accentSurface : AppTheme.backgroundTertiary,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: on
                  ? AppTheme.accentOnSurface.withValues(alpha: 0.5)
                  : Colors.transparent,
            ),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                  color: on ? AppTheme.accentOnSurface : fg)),
        ),
      );

  // ============================================================
  // 「识别」：粘贴松散 JSON 片段，自动归类追加
  // ============================================================

  Future<void> _recognize() async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('识别站点', style: TextStyle(color: AppTheme.textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '把站点 JSON 粘进来即可（单个 / 数组 / 一行一条都行），'
                  '缺的字段会自动补默认值：\n'
                  '{"key":"Nostr","name":"Nostr推荐","type":3,'
                  '"api":"csp_Nostr","homePage":"https://…/nostr.html"}',
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: AppTheme.textTertiary,
                      height: 1.5),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: c,
                  maxLines: 8,
                  style:
                      TextStyle(fontSize: AppTheme.fontFootnote, color: AppTheme.textPrimary),
                  decoration: const InputDecoration(
                    hintText: '粘贴 JSON…',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('追加',
                style: TextStyle(color: AppTheme.accentOnSurface)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final list = _parseLoose(c.text);
    if (list.isEmpty) {
      AppToast.message('没识别出站点：请确认是 JSON');
      return;
    }
    for (final m in list) {
      await _saveMap(m);
    }
    await _reload();
    if (mounted) AppToast.message('已追加 ${list.length} 个站点');
  }

  /// 解析"松散"JSON：整体数组 / 单个对象 / 一行一条 / 少个逗号都能兜
  static List<Map<String, dynamic>> _parseLoose(String raw) {
    final out = <Map<String, dynamic>>[];
    void take(dynamic v) {
      if (v is Map) {
        final m = Map<String, dynamic>.from(v);
        final id = (m['key'] ?? m['name'] ?? m['api'] ?? '').toString().trim();
        if (id.isNotEmpty) out.add(m);
      } else if (v is List) {
        for (final e in v) {
          take(e);
        }
      }
    }

    final t = raw.trim();
    if (t.isEmpty) return out;
    try {
      take(jsonDecode(t));
      if (out.isNotEmpty) return out;
    } catch (_) {}
    try {
      take(jsonDecode('[$t]'));
      if (out.isNotEmpty) return out;
    } catch (_) {}
    for (final line in t.split(RegExp(r'\n+'))) {
      final s = line.trim().replaceAll(RegExp(r',$'), '');
      if (s.isEmpty) continue;
      try {
        take(jsonDecode(s));
      } catch (_) {}
    }
    return out;
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppTheme.textPrimary;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : AppTheme.textSecondary;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        iconTheme: IconThemeData(color: fg),
        title: Text('站点注入',
            style: TextStyle(
                color: fg,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: '识别（粘贴 JSON）',
            onPressed: _recognize,
            icon: Icon(Icons.auto_fix_high_rounded, color: fg),
          ),
          IconButton(
            tooltip: '新增站点',
            onPressed: () => _edit(),
            icon: Icon(Icons.add_rounded, color: fg),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                Text(
                  '注入的站点会并入线路表（切订阅也会自动合并回来）。'
                  '关闭「启用」只是不显示，配置仍保留。',
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption, color: sub, height: 1.5),
                ),
                const SizedBox(height: 12),
                if (_items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                      child: Text('还没有注入站点，点右上角「+」新增，或「识别」粘贴 JSON',
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead, color: sub)),
                    ),
                  )
                else
                  for (final m in _items) _card(m, fg, sub, isDark),
              ],
            ),
    );
  }

  Widget _card(
      Map<String, dynamic> m, Color fg, Color sub, bool isDark) {
    final key = (m['key'] ?? '').toString();
    final name = (m['name'] ?? key).toString();
    final api = (m['api'] ?? '').toString();
    final enabled = m['enabled'] != false;
    final type = (m['type'] as num?)?.toInt() ?? 3;
    final tags = <String>[
      'type=$type',
      if ((m['searchable'] as num?)?.toInt() == 1) '搜索',
      if ((m['quickSearch'] as num?)?.toInt() == 1) '快速搜索',
      if ((m['filterable'] as num?)?.toInt() == 1) '筛选',
      if ((m['indexs'] as num?)?.toInt() == -1) '插最前',
      if ((m['homePage'] ?? '').toString().isNotEmpty) '带首页*',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFF4F5F7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: enabled
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
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600,
                        color: fg)),
              ),
              Switch(
                value: enabled,
                onChanged: (v) async {
                  await _saveMap(m, enabled: v);
                  await _reload();
                },
              ),
            ],
          ),
          if (api.isNotEmpty)
            Text(api,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppTheme.fontCaption, color: sub)),
          const SizedBox(height: 4),
          Text(tags.join(' · '),
              style: TextStyle(fontSize: AppTheme.fontCaption, color: sub)),
          Row(
            children: [
              const Spacer(),
              IconButton(
                tooltip: '编辑',
                onPressed: () => _edit(m),
                icon: Icon(Icons.edit_outlined, size: 18, color: sub),
              ),
              IconButton(
                tooltip: '删除',
                onPressed: () async {
                  await ApiConfig.instance.removeUserVideoSource(key);
                  await _reload();
                  if (mounted) AppToast.message('已删除「$key」');
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
