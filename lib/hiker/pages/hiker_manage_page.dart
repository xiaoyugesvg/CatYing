import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../reading/source/global_proxy.dart';
import '../../services/app_log.dart';
import '../../widgets/app_toast.dart';
import '../models/hiker_source.dart';
import '../services/hiker_builtin.dart';
import '../services/hiker_files.dart';
import '../services/hiker_prefs.dart';
import '../services/hiker_store.dart';

/// 「海阔源管理」—— 导入 / 启停 / 删除 / 逐源配置。
///
/// 从「海阔设置 → 海阔源管理」进入；本页只动 `HikerStore`，与其它模块无关。
class HikerManagePage extends StatefulWidget {
  const HikerManagePage({super.key});

  @override
  State<HikerManagePage> createState() => _HikerManagePageState();
}

class _HikerManagePageState extends State<HikerManagePage> {
  final _store = HikerStore.instance;
  final _prefs = HikerPrefs.instance;

  bool _busy = false;
  String _group = ''; // 空 = 全部分组
  bool _usableOnly = false;

  /// 源诊断的输入：随包资源名 + 用户文件区里的文件（相对路径）
  Set<String> _bundledAssets = const {};
  Set<String> _importedFiles = const {};

  /// 诊断结果缓存（key = 源 id）——列表重建时不重复扫规则文本
  final Map<String, List<HikerSourceDiagnosis>> _diagCache = {};

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChanged);
    _prefs.addListener(_onChanged);
    if (!_store.loaded) {
      _store.load().then((_) {
        if (mounted) setState(() {});
      });
    }
    _loadDiagnosisInputs();
  }

  /// 诊断要用的两份清单（随包资源 / 文件区）。
  /// 读失败就保持空集合：宁可少标，也不误报「缺文件」。
  Future<void> _loadDiagnosisInputs() async {
    try {
      final assets = await HikerBuiltin.assetNames();
      final files = await HikerFiles.list();
      if (!mounted) return;
      setState(() {
        _bundledAssets = assets.toSet();
        _importedFiles =
            files.map((e) => e.path.replaceAll('\\', '/')).toSet();
        _diagCache.clear();
      });
    } catch (e) {
      AppLog.instance.log('[Hiker] 载入诊断清单失败: $e');
    }
  }

  @override
  void dispose() {
    _store.removeListener(_onChanged);
    _prefs.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    // 源 / 配置变了 ⇒ 诊断结果作废（"需填配置"要跟着消失）
    _diagCache.clear();
    if (mounted) setState(() {});
  }

  // ── 导入 ──────────────────────────────────────────────

  Future<void> _doImport(String text, {String from = ''}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final (added, updated, total) = await _store.importFromText(text);
      if (added == 0 && updated == 0) {
        AppToast.error('没解析出任何源（确认是海阔导出的 JSON 数组）');
      } else {
        AppToast.message('导入完成：新增 $added、更新 $updated，共 $total 个');
      }
    } catch (e) {
      AppToast.error('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importFromClipboard() async {
    final text = await _textDialog(
      title: '粘贴海阔小程序 JSON',
      hint: '[{"title":"…","find_rule":"js:…"}]',
      confirm: '导入',
    );
    if (text == null || text.trim().isEmpty) return;
    await _doImport(text, from: '粘贴');
  }

  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt'],
      );
      if (result.isEmpty) return;
      final path = result.first.path;
      if (path == null) {
        AppToast.message('读不出这个文件（没有本地路径）');
        return;
      }
      await _doImport(await File(path).readAsString(), from: '文件');
    } catch (e) {
      AppToast.error('选择文件失败：$e');
    }
  }

  /// 从 URL 导入：海阔的"导出全部"常挂在网盘/图床直链上，直接抓文本再解析。
  /// 走**全局代理**（与项目其它网络请求一致，开代理时也能拉到）。
  Future<void> _importFromUrl() async {
    final url = await _textDialog(
      title: '从网址导入',
      hint: 'https://…/hiker.json',
      confirm: '下载导入',
    );
    if (url == null || url.trim().isEmpty) return;
    if (_busy) return;
    setState(() => _busy = true);
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      responseType: ResponseType.plain,
    ));
    applyGlobalProxy(dio);
    try {
      final resp = await dio.get<String>(url.trim());
      final text = (resp.data ?? '').toString();
      if (text.trim().isEmpty) {
        AppToast.error('下载到的内容是空的');
        return;
      }
      await _doImport(text, from: '网址');
    } catch (e) {
      AppToast.error('下载失败：$e');
    } finally {
      dio.close(force: true);
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── 逐源配置（规则里的 config.xxx）─────────────────────

  Future<void> _editConfig(HikerSource s) async {
    final existing = _store.configOf(s.id);
    final ctrl = TextEditingController(
      text: existing.isEmpty ? '' : const JsonEncoder.withIndent('  ').convert(existing),
    );
    // 从规则里榨出用到的 config 键，给用户一个"要填什么"的提示
    final keys = s.configKeys;

    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundCard,
        title: Text('源配置 · ${s.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: AppTheme.textPrimary, fontSize: AppTheme.fontHeadline)),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                keys.isEmpty
                    ? '这个源的规则没有用到 config.xxx。'
                    : '规则用到的配置键：${keys.map((k) => 'config.$k').join('、')}',
                style: TextStyle(
                    color: keys.isEmpty ? AppTheme.textTertiary : AppTheme.accentOnSurface,
                    fontSize: AppTheme.fontCaption,
                    height: 1.5),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                maxLines: 6,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: AppTheme.fontFootnote),
                decoration: InputDecoration(
                  hintText: '{\n  "host": "https://xxx.com"\n}',
                  hintStyle: TextStyle(color: AppTheme.textTertiary),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 6),
              Text('留空 = 清空该源配置；必须是 JSON 对象。',
                  style: TextStyle(
                      color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: Text('保存', style: TextStyle(color: AppTheme.accentOnSurface)),
          ),
        ],
      ),
    );
    if (saved == null) return;
    if (!isJsonObjectText(saved)) {
      AppToast.error('不是合法的 JSON 对象');
      return;
    }
    final t = saved.trim();
    final cfg = t.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(t) as Map);
    await _store.saveConfig(s.id, cfg);
    if (mounted) AppToast.message(cfg.isEmpty ? '已清空该源配置' : '已保存源配置');
  }

  // ── 通用小弹窗 ────────────────────────────────────────

  Future<String?> _textDialog({
    required String title,
    required String hint,
    required String confirm,
  }) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundCard,
        title: Text(title,
            style: TextStyle(
                color: AppTheme.textPrimary, fontSize: AppTheme.fontHeadline)),
        content: TextField(
          controller: ctrl,
          maxLines: 6,
          style: TextStyle(color: AppTheme.textPrimary, fontSize: AppTheme.fontFootnote),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: AppTheme.textTertiary),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: Text(confirm, style: TextStyle(color: AppTheme.accentOnSurface)),
          ),
        ],
      ),
    );
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundCard,
        title: Text('清空全部海阔源？',
            style: TextStyle(
                color: AppTheme.textPrimary, fontSize: AppTheme.fontHeadline)),
        content: Text('只影响「海阔」模块，其它模块不受影响。',
            style: TextStyle(
                color: AppTheme.textSecondary, fontSize: AppTheme.fontSubhead)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('清空', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store.clearAll();
    AppToast.message('已清空');
  }

  // ── UI ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final total = _store.sources.length;
    var list = _store.filterSources(group: _group);
    if (_usableOnly) list = list.where((s) => s.usable).toList();
    final groups = _store.groups;

    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        foregroundColor: AppTheme.textPrimary,
        elevation: 0,
        title: Text('海阔源管理',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: '清空',
            onPressed: total == 0 ? null : _clearAll,
            icon: Icon(Icons.delete_sweep_outlined, color: AppTheme.textSecondary),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _statsCard(total),
          const SizedBox(height: 12),

          // 三种导入方式
          Row(
            children: [
              Expanded(
                child: _actionButton(
                  icon: Icons.content_paste_rounded,
                  label: '粘贴',
                  onTap: _busy ? null : _importFromClipboard,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _actionButton(
                  icon: Icons.folder_open_rounded,
                  label: '文件',
                  onTap: _busy ? null : _importFromFile,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _actionButton(
                  icon: Icons.link_rounded,
                  label: '网址',
                  onTap: _busy ? null : _importFromUrl,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 分组筛选 + 仅可用
          if (total > 0) _filterBar(groups, list.length),
          const SizedBox(height: 8),

          if (total == 0)
            _emptyTip()
          else if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text('这个筛选下没有源',
                    style: TextStyle(
                        color: AppTheme.textTertiary, fontSize: AppTheme.fontSubhead)),
              ),
            )
          else
            ...list.map((s) => _sourceCard(s)),
        ],
      ),
    );
  }

  Widget _statsCard(int total) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Row(
        children: [
          _stat('源总数', '$total'),
          _stat('可运行', '${_store.usableCount}'),
          _stat('已启用', '${_store.enabledCount}'),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Expanded(
        child: Column(
          children: [
            Text(value,
                style: TextStyle(
                    color: AppTheme.accentOnSurface,
                    fontSize: AppTheme.fontTitle2,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
          ],
        ),
      );

  Widget _filterBar(List<String> groups, int shown) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 30,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _chip('全部', _group.isEmpty, () => setState(() => _group = '')),
              ...groups.map((g) => _chip(g, _group == g, () => setState(() => _group = g))),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text('显示 $shown 个',
                style: TextStyle(
                    color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
            const Spacer(),
            Text('仅看可用',
                style: TextStyle(
                    color: AppTheme.textSecondary, fontSize: AppTheme.fontCaption)),
            Switch(
              value: _usableOnly,
              activeThumbColor: AppTheme.accentColor,
              onChanged: (v) => setState(() => _usableOnly = v),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
      ],
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? AppTheme.accentSurface : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label,
            style: TextStyle(
                color: on ? AppTheme.accentOnSurface : AppTheme.textSecondary,
                fontSize: AppTheme.fontCaption,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: AppTheme.accentSurface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: AppTheme.accentOnSurface),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    color: AppTheme.accentOnSurface,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _emptyTip() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.backgroundTertiary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        '还没有海阔源。用上面的「粘贴 / 文件 / 网址」把海阔导出的 JSON（数组）导进来。\n\n'
        '⚠️ 依赖海阔内置页面模块或宿主能力（WebView 抓页）的源会被标记为不可用 —— 这是导入时就判定好的，不会等点了才报错。',
        style: TextStyle(
            color: AppTheme.textSecondary, fontSize: AppTheme.fontFootnote, height: 1.6),
      ),
    );
  }

  /// 这个源的诊断结果（带缓存；配置/文件清单变化时由 [_onChanged] 清掉）
  List<HikerSourceDiagnosis> _diagOf(HikerSource s) => _diagCache.putIfAbsent(
        s.id,
        () => s.diagnose(
          bundledAssets: _bundledAssets,
          importedFiles: _importedFiles,
          config: _store.configOf(s.id),
        ),
      );

  Widget _sourceCard(HikerSource s) {
    final isCurrent = _store.currentId == s.id;
    final hasCfg = _store.configOf(s.id).isNotEmpty;
    final issues = _diagOf(s);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isCurrent
              ? AppTheme.accentColor.withValues(alpha: 0.55)
              : AppTheme.borderLight,
          width: isCurrent ? 1.4 : 1,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _store.setCurrent(s.id),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: AppTheme.fontBody,
                                fontWeight: FontWeight.w600)),
                      ),
                      if (isCurrent) ...[
                        const SizedBox(width: 6),
                        _tag('当前', AppTheme.accentSurface, AppTheme.accentOnSurface),
                      ],
                      if (hasCfg) ...[
                        const SizedBox(width: 4),
                        _tag('已配置', AppTheme.backgroundTertiary, AppTheme.textSecondary),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${s.author}'
                    '${s.version > 0 ? ' · v${s.version}' : ''}'
                    ' · ${s.groupLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption),
                  ),
                  _diagTags(s, issues),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '源配置（规则里的 config）',
            onPressed: () => _editConfig(s),
            icon: Icon(Icons.tune_rounded, size: 18, color: AppTheme.textSecondary),
          ),
          Switch(
            value: _store.isEnabled(s),
            activeThumbColor: AppTheme.accentColor,
            onChanged: (v) => _store.setEnabled(s.id, v),
          ),
          IconButton(
            tooltip: '删除',
            onPressed: () => _store.remove(s.id),
            icon: Icon(Icons.close_rounded, size: 18, color: AppTheme.textTertiary),
          ),
        ],
      ),
    );
  }

  /// 诊断标签行：直接标出「缺 Apollo / 缺 lazy / 缺文件 / 需填配置」…
  /// 点标签看具体说明与补法（不再等点进源才看到一句报错）。
  Widget _diagTags(HikerSource s, List<HikerSourceDiagnosis> issues) {
    if (issues.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Wrap(
        spacing: 6,
        runSpacing: 5,
        children: [
          for (final d in issues)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _showDiagnosis(s, d),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: d.blocking
                      ? Colors.orange.withValues(alpha: 0.14)
                      : AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      d.blocking
                          ? Icons.error_outline_rounded
                          : Icons.info_outline_rounded,
                      size: 11,
                      color: d.blocking
                          ? Colors.orange.shade400
                          : AppTheme.textSecondary,
                    ),
                    const SizedBox(width: 3),
                    Text(d.label,
                        style: TextStyle(
                            color: d.blocking
                                ? Colors.orange.shade400
                                : AppTheme.textSecondary,
                            fontSize: AppTheme.fontCaption)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 诊断详情：说明缺什么、去哪儿补
  void _showDiagnosis(HikerSource s, HikerSourceDiagnosis d) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundCard,
        title: Row(
          children: [
            Icon(
              d.blocking ? Icons.error_outline_rounded : Icons.info_outline_rounded,
              size: 18,
              color: d.blocking ? Colors.orange.shade400 : AppTheme.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${d.label} · ${s.title}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontHeadline)),
            ),
          ],
        ),
        content: Text(
          d.detail,
          style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontSubhead,
              height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('知道了',
                style: TextStyle(color: AppTheme.accentOnSurface)),
          ),
        ],
      ),
    );
  }

  Widget _tag(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(color: fg, fontSize: AppTheme.fontCaption)),
      );
}
