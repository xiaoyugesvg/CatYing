import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../models/source_bean.dart';
import '../reading/source/global_proxy.dart';
import '../services/api_config.dart';
import '../widgets/app_toast.dart';
import 'webhome_site_page.dart';

/// **内置的默认配置链接**（用户 2026-10-16 给的两份）。
///
/// 两份都是 TVBox / CatVod 形态，`sites[]` 正是「站点注入」吃的格式；
/// 实测 `api.json` 里带 `homePage`（= 用网页当这个站点首页）的是 `Nostr` / `Nostr2`。
/// 用户不用手打地址，弹窗里点一下就能填进去。
const List<({String label, String url})> kDefaultTvboxConfigs = [
  (
    label: '推荐 · WebHome 站点',
    url: 'https://www.252035.xyz/xs/tvbox/api.json',
  ),
  (
    label: 'FongMi 配置',
    url: 'https://www.252035.xyz/z/FongMi.json',
  ),
];

/// 从 **TVBox / FongMi 配置**里抠出站点数组（`{sites:[{key,name,type,api,homePage?}]}`）。
///
/// 用户 2026-10-16 给的 `…/z/FongMi.json`（17 KB）与 `…/xs/tvbox/api.json`（53 KB）
/// 就是这种配置：顶层 `spider/wallpaper/sites/lives/parses/flags…`，
/// **116 条 sites 全是 `type:3`（CSP）**，其中带 `homePage` 的只有 2 条
/// —— 那 2 条才是 WebHomeTV 语义里的"用网页当这个站点首页"。
///
/// ── 容错（实测踩到的）────────────────────────────────────────
///   · 配置可能**带 BOM / 前导空白**（FongMi.json 就是）→ 直接 `jsonDecode` 会抛
///   · 也可能前后夹着说明文字 → 退一步只取第一个 `{` 到最后一个 `}`
///   · 还兼容：顶层就是数组、或单条站点对象（手写片段）
List<Map<String, dynamic>> parseTvboxConfigSites(String rawText) {
  final t = rawText.replaceFirst('\uFEFF', '').trim();
  if (t.isEmpty) return const [];

  List<Map<String, dynamic>> mapsOf(dynamic v) {
    if (v is List) {
      return v
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (v is Map) return [Map<String, dynamic>.from(v)];
    return const [];
  }

  dynamic j;
  try {
    j = jsonDecode(t);
  } catch (_) {
    // 夹了说明文字：只取最外层那对花括号
    final a = t.indexOf('{');
    final b = t.lastIndexOf('}');
    if (a >= 0 && b > a) {
      try {
        j = jsonDecode(t.substring(a, b + 1));
      } catch (_) {}
    }
  }
  if (j is! Map && j is! List) return const [];

  if (j is List) return mapsOf(j);
  final sites = j['sites'];
  if (sites is List) return mapsOf(sites);
  // 单条站点对象（`{key,name,type,api,homePage}`）
  final m = Map<String, dynamic>.from(j);
  final id = (m['key'] ?? m['name'] ?? m['api'] ?? '').toString().trim();
  return id.isEmpty ? const [] : [m];
}

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
/// ⚠️ `homePage`（用网页当这个站点的首页）由**本模块自己的列表**渲染：
///    列表里带 `homePage` 的站点会出现「打开网页首页」按钮 →
///    [WebHomeSitePage]（注入 `window.ant` / `window.fm` + 去广告小猫球）。
///    其余字段（启用 / 插入位置 / 搜索三开关 / 类型 / 接口）都是**真实生效**的。
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
                  Text('填了就会在列表里出现「打开网页首页」（在本模块内打开，注入 ant/fm 桥 + 去广告）',
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
  // 「从配置导入」：TVBox / FongMi 配置网址（或粘贴整段 JSON）
  // ============================================================

  /// 导入 **TVBox / FongMi 配置**里的站点（用户 2026-10-16：
  /// 「`…/z/FongMi.json`、`…/xs/tvbox/api.json` 这种怎么弄进 webhtv」）。
  ///
  /// 为什么要给两种导入口径：实测那份 `api.json` 有 **116 条站点**，但带
  /// `homePage`（= 用网页当这个站点首页，WebHomeTV 的核心玩法）的只有 2 条。
  /// 全量灌进线路表会把列表冲垮，所以默认推荐「只导入带首页的」。
  ///
  /// [presetUrl] 不为空时跳过弹窗，直接按「只导入带首页的」跑内置/指定链接
  /// （空态里那个「导入内置配置」按钮走这条路）。
  Future<void> _importFromConfig({String? presetUrl}) async {
    final c = TextEditingController(text: presetUrl ?? '');
    String? choice = presetUrl != null ? 'webhome' : null;
    if (choice == null) {
      choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.backgroundSecondary,
          title: Text('从 TVBox 配置导入',
              style: TextStyle(color: AppTheme.textPrimary)),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '填一个配置网址（如 `https://…/z/FongMi.json`、`…/xs/tvbox/api.json`），'
                    '也可以直接把整段 JSON 粘进来。\n\n'
                    '· 这种配置里的站点就是「站点注入」吃的格式：'
                    '`key / name / type / api / homePage`\n'
                    '· `homePage` 才是"用网页当这个站点的首页"，'
                    '没写 homePage 的只是普通 CSP 站点',
                    style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: AppTheme.textTertiary,
                        height: 1.5),
                  ),
                  const SizedBox(height: 10),
                  // 内置默认配置：点一下自动填入，不用手打地址
                  Text('内置配置（点一下填入）',
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: AppTheme.textTertiary)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final d in kDefaultTvboxConfigs)
                        GestureDetector(
                          onTap: () => c.text = d.url,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: AppTheme.backgroundTertiary,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: AppTheme.borderLight, width: 0.5),
                            ),
                            child: Text(d.label,
                                style: TextStyle(
                                    fontSize: AppTheme.fontCaption,
                                    color: AppTheme.accentOnSurface)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: c,
                    maxLines: 6,
                    style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: AppTheme.textPrimary),
                    decoration: const InputDecoration(
                      hintText: '配置网址，或粘贴 JSON…',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'all'),
              child: Text('全部导入',
                  style: TextStyle(color: AppTheme.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'webhome'),
              child: Text('只导入带首页的',
                  style: TextStyle(color: AppTheme.accentOnSurface)),
            ),
          ],
        ),
      );
    }
    if (choice == null) return;
    final input = c.text.trim();
    if (input.isEmpty) return;

    String text = input;
    // 网址就下载（走全局代理，与项目其它请求一致）
    if (input.startsWith('http://') || input.startsWith('https://')) {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
        responseType: ResponseType.plain,
      ));
      applyGlobalProxy(dio);
      try {
        final resp = await dio.get<String>(input);
        text = (resp.data ?? '').toString();
      } catch (e) {
        AppToast.error('下载失败：${e.toString().split('\n').first}');
        return;
      } finally {
        dio.close(force: true);
      }
    }

    final all = parseTvboxConfigSites(text);
    if (all.isEmpty) {
      AppToast.error('没解析出站点：确认是 TVBox / FongMi 配置');
      return;
    }
    final webHome = all
        .where((m) => (m['homePage'] ?? '').toString().trim().isNotEmpty)
        .toList();
    final picked = choice == 'webhome' ? webHome : all;
    if (picked.isEmpty) {
      AppToast.message('这份配置里没有带 homePage 的站点（可以试「全部导入」）');
      return;
    }
    for (final m in picked) {
      await _saveMap(m);
    }
    await _reload();
    if (!mounted) return;
    AppToast.message('已导入 ${picked.length} 个站点'
        '（共 ${all.length} 条，其中带首页的 ${webHome.length} 个）');
  }

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
            tooltip: '从 TVBox 配置导入（网址 / JSON）',
            onPressed: _importFromConfig,
            icon: Icon(Icons.cloud_download_rounded, color: fg),
          ),
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
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Column(
                      children: [
                        Text(
                            '还没有注入站点，点右上角「+」新增，或「识别」粘贴 JSON',
                            style: TextStyle(
                                fontSize: AppTheme.fontSubhead, color: sub)),
                        const SizedBox(height: 14),
                        // 一键导入内置配置（含 homePage 的那几个站点）
                        FilledButton.tonalIcon(
                          onPressed: () => _importFromConfig(
                              presetUrl: kDefaultTvboxConfigs.first.url),
                          icon: const Icon(Icons.cloud_download_rounded, size: 18),
                          label: const Text('导入内置配置'),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          kDefaultTvboxConfigs.first.url,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              color: AppTheme.textTertiary),
                        ),
                      ],
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
      if ((m['homePage'] ?? '').toString().isNotEmpty) '网页首页',
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
              // 带 `homePage` 的站点：在本模块内直接打开它的网页首页
              //（WebHomeTV 的核心玩法；不借用影视/阅读模块的界面）
              if ((m['homePage'] ?? '').toString().trim().isNotEmpty)
                IconButton(
                  tooltip: '打开网页首页',
                  onPressed: () {
                    final url = (m['homePage'] ?? '').toString().trim();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            WebHomeSitePage(url: url, title: name),
                      ),
                    );
                  },
                  icon: Icon(Icons.public_rounded,
                      size: 18, color: AppTheme.accentOnSurface),
                ),
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
