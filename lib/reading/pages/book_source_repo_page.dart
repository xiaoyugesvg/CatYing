import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import '../source/global_proxy.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book_source.dart';
import '../services/book_source_compatibility.dart';
import '../services/book_source_import_parser.dart';
import '../services/book_source_service.dart';
import '../source/source_manager.dart';
import 'book_source_editor_page.dart';
import 'book_source_health_page.dart';
import 'book_source_login_page.dart';
import 'book_source_qr_scan_page.dart';
import 'source_warehouse_page.dart';
// cloud_book_source_page 的 import 已移除（云端网页入口迁到书源页）
// ✅ **补齐缺失的 import** ✗✓（本轮修的 8 条 error 全因它们 ✗）：
//   · `JellySearchBar` / `JellySlidingActions`(+`JellyAction`)
//     是**共用组件** ✓ —— 我之前误以为"能被传递导出"✗，那是因为**闸门跑错了目录** ✗✗
//     （`dart analyze` 没带仓库根 → 分析的是别的项目 ✓ → 假绿 ✓）。
//   （书源页本身不再提供「浏览记录 / 收藏」入口，如需查看请到漫画/图书搜索页或“我的”页。）
import '../widgets/jelly_search_bar.dart';
import '../widgets/swipe_action_tile.dart';
import '../theme/jelly_theme.dart';
import '../../common/theme.dart';
import '../../services/python_manager.dart';
import '../../services/python_sources_service.dart';

/// 书源仓库 —— 小说书源（Legado 格式）的导入与管理。
///
/// ── 界面参照 ──────────────────────────────────────────────────
/// 按 **cmbok V2.0.7** 的书源页重做（用户提供截图）：
///   · 标题「书源」+ 右侧搜索框「搜索书源图书」
///   · 空态：「还没有书源 / 用地址、口令或本地文件导入书源」+「+ 去导入书源」
///   · 导入三种方式：**地址 / 口令 / 本地文件**（截图原文）
///
/// ── 为什么早期判断失误（记下来免得再错）────────────────────────
/// 开源仓库 hlning/cmbok_app 的快照停在 **V2.0.3**，而书源仓库是
/// **V2.0.7** 新增的功能（其更新说明明确列出"书源仓库：多选删除、分享"、
/// "书源页/仓库：分组功能"、"书源体检"、"书源编辑"、"书源变量"），
/// 之后源码不再开源 —— 所以源码里搜不到，但发布版里确实有。
/// **教训：判断某功能是否存在，不能只看开源快照，要看发布说明。**
///
/// ── 与「漫画源仓库」的关系 ────────────────────────────────────
/// 两个**独立**页面，不共用任何代码：
///   · 漫画源仓库 = SiteConfig（取图片）+ SourceConfigStore
///   · 本页       = Legado BookSource（取文字）+ BookSourceStore
class BookSourceRepoPage extends StatefulWidget {
  const BookSourceRepoPage({super.key});

  @override
  State<BookSourceRepoPage> createState() => _BookSourceRepoPageState();
}

class _BookSourceRepoPageState extends State<BookSourceRepoPage> {
  final store = BookSourceStore.instance;

  bool _busy = false;
  bool _selectMode = false;
  String _keyword = '';
  bool _autoImportHandled = false;
  final Set<String> _selected = {};

  // ── 主列表的筛选与分组 ──────────────────────────────────
  /// 页面内「筛选已导入的书源」输入框（搜索栏已从 AppBar 移到页面内）
  final _filterCtrl = TextEditingController();

  /// 分组 chip 当前选中项：null = 「全部」
  String? _pickedGroup;

  /// 被「隐藏组」的组名（不显示其书源）
  final Set<String> _hiddenGroups = {};

  /// 书源体检结果（id → 健康度）。「体检」按钮跑完填这里，
  /// 卡片上会显示徽标 —— 不用逐个点进去看。
  final Map<String, BookSourceHealth> _health = {};

  /// 体检进行中（按钮转圈 + 禁用重复点击）
  bool _healthChecking = false;

  @override
  void initState() {
    super.initState();
    if (store.isEmpty) store.init();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 带 {action:'import'} 进入时直接弹导入（供"去导入书源"类入口复用）。
    // 只用一次，避免每次依赖变化都弹。
    if (_autoImportHandled) return;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['action'] == 'import') {
      _autoImportHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showImportSheet();
      });
    }
  }

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _card => _isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
  Color get _titleColor => _isDark ? Colors.white : JellyTheme.textPrimaryLight;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// 导入内容里如果有漫画源，同步刷新漫画源管理器。
  ///
  /// 漫画脚本现在不在书源列表展示（见 [_visible]），如果这里不 reload，
  /// 用户导入后在「漫画源仓库」看不到，会以为导入失败。
  Future<void> _reloadComicSourcesIfNeeded(List<BookSource> parsed) async {
    if (!parsed.any((s) => s.isComicSource)) return;
    await SourceManager().reload();
  }

  /// 搜索过滤结果。
  ///
  /// 只显示**书源仓**名下的源：书源 + 从书源仓导入的漫画源（图片模式阅读）。
  /// 漫源仓库里的源不会出现在这里（用户 2026-10-18：「从哪个仓订阅就用哪个」）。
  List<BookSource> get _visible {
    final all = store.sorted().where((s) => s.belongsToBook).toList();
    if (_keyword.isEmpty) return all;
    final k = _keyword.toLowerCase();
    return all
        .where(
          (s) =>
              s.name.toLowerCase().contains(k) ||
              s.url.toLowerCase().contains(k) ||
              s.group.toLowerCase().contains(k),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _isDark
          ? JellyTheme.backgroundDark
          : JellyTheme.backgroundLight,
      appBar: _buildAppBar(),
      body: ListenableBuilder(
        listenable: store.revision,
        builder: (context, _) {
          final list = _visible;
          // 「有没有书源」只看本仓（书源 + 从书源仓导入的漫画源）；
          // 漫源仓库的源不参与，避免只剩另一边时误显示「无匹配」。
          final noBooks = store.sorted().every((s) => !s.belongsToBook);
          return Column(
            children: [
              // 搜索 + 分组操作固定在顶栏下面（不随列表滚动）
              if (!noBooks) _pinnedFilters(list),
              Expanded(
                child: noBooks
                    ? _emptyState()
                    : (list.isEmpty ? _noMatchState() : _sourceList(list)),
              ),
            ],
          );
        },
      ),
      // 多选模式：底部圆角浮动操作栏（统一替代原来的 FAB）。
      bottomNavigationBar: _selectMode ? _multiSelectBar() : null,
    );
  }

  // ============================================================
  // 顶栏下方固定区：搜索 + 分组操作（管理分组 / 创建分组 固定不动）
  // ============================================================

  Widget _pinnedFilters(List<BookSource> all) {
    final base = all.where((s) => !_hiddenGroups.contains(s.group)).toList();
    final counts = <String, int>{};
    for (final s in base) {
      counts[s.group] = (counts[s.group] ?? 0) + 1;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Column(
        children: [
          JellySearchBar(
            controller: _filterCtrl,
            hintText: '筛选已导入的书源',
            onChanged: (v) => setState(() => _keyword = v.trim()),
            onCleared: () {
              _filterCtrl.clear();
              setState(() => _keyword = '');
            },
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 34,
            child: Row(
              children: [
                // 两个分组操作固定在最左侧，不随分组 chip 滚动
                _squareIconBtn(Icons.menu_rounded, '管理分组', _showManageGroups),
                const SizedBox(width: 8),
                _groupActionBtn(
                  Icons.create_new_folder_outlined,
                  '创建分组',
                  _showNewGroup,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      _groupChip(
                        '全部',
                        base.length,
                        _pickedGroup == null,
                        () => setState(() => _pickedGroup = null),
                      ),
                      for (final e in counts.entries) ...[
                        const SizedBox(width: 8),
                        _groupChip(
                          e.key,
                          e.value,
                          _pickedGroup == e.key,
                          () => setState(() => _pickedGroup = e.key),
                        ),
                      ],
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // AppBar：居中标题「书源仓库」+ 右侧分享 + 盾牌体检（并排常显）
  //   多选模式：标题变「多选书源」，右侧只留盾牌。
  // ============================================================

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      // 居中标题（左为自动返回箭头）
      centerTitle: true,
      title: Text(
        _selectMode ? '多选书源' : '书源仓库',
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppTheme.fontTitle2,
          fontWeight: FontWeight.w600,
          color: _titleColor,
        ),
      ),
      actions: [
        // 普通模式：分享 + 盾牌（体检）两个图标**同时并排显示**，不用滑动切换。
        if (!_selectMode)
          // 书源仓（用户 2026-10-18）：从「我的」页移到这里，右上角图标进入
          _appBarIcon(Icons.storefront_rounded, '书源仓', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SourceWarehousePage()),
            );
          }),
        if (!_selectMode)
          _appBarIcon(Icons.ios_share_rounded, '分享书源', () {
            if (store.isEmpty) return;
            _shareAll();
          }),
        // 盾牌（书源体检）：两种模式都在。
        _appBarIcon(Icons.health_and_safety_rounded, '书源体检', () {
          if (store.isEmpty || _healthChecking) return;
          _runHealthCheck();
        }),
        // 导入书源：右上角按钮 → 居中弹窗（用户 2026-10-18）
        if (!_selectMode)
          _appBarIcon(
            Icons.input_rounded,
            '导入书源',
            _showImportSheet,
          ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// 顶栏动作图标：紧凑 IconButton（右上角图标并排用）。
  Widget _appBarIcon(IconData icon, String tooltip, VoidCallback onTap) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, color: _titleColor),
      onPressed: onTap,
    );
  }

  /// 分享全部书源：复制 JSON 到剪贴板（并提示可粘贴给他人）
  Future<void> _shareAll() async {
    // 只分享书源仓名下的源（含书源仓导入的漫画源）
    final books = store.sorted().where((s) => s.belongsToBook).toList();
    final json = BookSourceService.instance.exportSources(books);
    await Clipboard.setData(ClipboardData(text: json));
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '已复制书源',
          style: TextStyle(fontSize: AppTheme.fontHeadline),
        ),
        content: Text(
          '${books.length} 个书源的 JSON 已复制到剪贴板，'
          '可直接粘贴分享给别人。\n\n'
          '对方用「口令导入」粘贴即可导入。',
          style: const TextStyle(fontSize: AppTheme.fontSubhead, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 分享选中的书源：只导出多选勾选的源（JSON 到剪贴板）
  Future<void> _shareSelected() async {
    final selected = store.all
        .where((s) => _selected.contains(s.id) && s.belongsToBook)
        .toList();
    if (selected.isEmpty) return;
    final json = BookSourceService.instance.exportSources(selected);
    await Clipboard.setData(ClipboardData(text: json));
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '已复制书源',
          style: TextStyle(fontSize: AppTheme.fontHeadline),
        ),
        content: Text(
          '已把选中的 ${selected.length} 个书源复制到剪贴板，'
          '可直接分享给别人。\n\n'
          '对方用「口令导入」粘贴，或把内容生成二维码后用「二维码导入」扫码即可。',
          style: const TextStyle(fontSize: AppTheme.fontSubhead, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 二维码导入：打开扫码页，扫到的文本走「口令导入」同款解析链路
  Future<void> _importByQrCode() async {
    final text = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const BookSourceQrScanPage()),
    );
    if (text == null || text.trim().isEmpty) return;
    final parsed = _parseSources(text);
    if (parsed.isEmpty) {
      _toast('二维码内容里没有解析出书源');
      return;
    }
    final r = await store.addAll(parsed);
    await _reloadComicSourcesIfNeeded(parsed);
    _toast(r.added > 0 ? '已导入 ${r.added} 个书源' : '已更新 ${r.updated} 个书源');
    await _showCompatReport(parsed);
  }

  // ============================================================
  // 多选模式底部圆角浮动操作栏（替代原 FAB）
  //   已选 N 项 + 全选 + 删除 + 分享 + ×（退出多选）
  // ============================================================

  Widget _multiSelectBar() {
    final list = _visible;
    final allSelected = list.isNotEmpty && _selected.length == list.length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: _isDark ? 0.35 : 0.12),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              const SizedBox(width: 12),
              Text(
                '已选 ${_selected.length} 项',
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: _titleColor,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  if (allSelected) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(list.map((e) => e.id));
                  }
                }),
                child: Text(
                  allSelected ? '取消全选' : '全选',
                  style: const TextStyle(fontSize: AppTheme.fontSubhead),
                ),
              ),
              _barIcon(
                Icons.delete_outline_rounded,
                '删除选中',
                _selected.isEmpty ? null : _deleteSelected,
              ),
              _barIcon(
                Icons.ios_share_rounded,
                '分享选中',
                _selected.isEmpty ? null : _shareSelected,
              ),
              _barIcon(
                Icons.close_rounded,
                '退出多选',
                () => setState(() {
                  _selectMode = false;
                  _selected.clear();
                }),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  /// 底部操作栏里的一个图标按钮
  Widget _barIcon(IconData icon, String tooltip, VoidCallback? onTap) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 22, color: _titleColor),
      onPressed: onTap,
    );
  }

  // ============================================================
  // 空态（照截图：还没有书源 / 用地址、口令或本地文件导入书源 / 去导入书源）
  // ============================================================

  Widget _emptyState() => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: 48,
            color: JellyTheme.textSecondary.withValues(alpha: 0.55),
          ),
          const SizedBox(height: 20),
          Text(
            '还没有书源',
            style: TextStyle(
              fontSize: AppTheme.fontTitle3,
              fontWeight: FontWeight.w600,
              color: _titleColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '用上面的地址、口令、二维码或本地文件导入',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTheme.fontSubhead,
              color: JellyTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: _busy ? null : _showImportSheet,
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text('去导入书源'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _noMatchState() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.search_off_rounded,
          size: 42,
          color: JellyTheme.textSecondary.withValues(alpha: 0.5),
        ),
        const SizedBox(height: 12),
        Text(
          '没有匹配「$_keyword」的书源',
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            color: JellyTheme.textSecondary,
          ),
        ),
      ],
    ),
  );

  // ============================================================
  // 列表
  // ============================================================

  /// 主列表：
  ///   共 N 个 + 清空 → 统计 chips → 书源卡片
  /// （搜索与分组操作在 `_pinnedFilters` 里，固定在顶栏下方；关键词搜索在
  ///  `_visible` 里完成，这里只做「隐藏组 / 选中分组」过滤）
  Widget _sourceList(List<BookSource> all) {
    // 1) 按"隐藏组"和"选中分组"过滤
    var list = all.where((s) => !_hiddenGroups.contains(s.group)).toList();
    if (_pickedGroup != null) {
      list = list.where((s) => s.group == _pickedGroup).toList();
    }
    // 2) 未被隐藏的组（统计 + 共 N 个）
    final base = all.where((s) => !_hiddenGroups.contains(s.group)).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      children: [
        // ── 共 N 个 + 清空 ────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 0, 6),
          child: Row(
            children: [
              Text(
                '共 ${base.length} 个',
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: JellyTheme.textSecondary,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('清空书源'),
                      content: Text('将删除全部 ${base.length} 个书源，不可恢复。'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('取消'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text(
                            '清空',
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) {
                    // removeAll() 无参（清空全部）；这里要删的是
                    // "未被隐藏的组"里的源，所以逐个 remove
                    for (final s in base) {
                      await store.remove(s.id);
                    }
                  }
                },
                child: const Text(
                  '清空',
                  style: TextStyle(fontSize: AppTheme.fontSubhead),
                ),
              ),
            ],
          ),
        ),
        // ── 统计 chip 行：总数 / 待更新 / 正常 / 重复 / 异常 / 失效 ──
        //   数字全部基于真实数据计算（拿不到的项显示 0，不编造）。
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: _statChips(base),
            ),
          ),
        ),
        const SizedBox(height: 4),
        // ── 书源卡片 ──────────────────────────────────────────
        for (final s in list) _sourceTile(s),
      ],
    );
  }

  /// 分组 chip 行左侧的小圆钮（分组设置 / 新建分组）
  Widget _groupActionBtn(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: Material(
        color: _isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.04),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(icon, size: 18, color: JellyTheme.textSecondary),
          ),
        ),
      ),
    );
  }

  /// 筛选行左侧的**方形**小按钮（☰ 管理分组）
  Widget _squareIconBtn(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: Material(
        color: _isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(icon, size: 18, color: JellyTheme.textSecondary),
          ),
        ),
      ),
    );
  }

  /// 统计 chip 行：总数 / 待更新 / 正常 / 重复 / 异常 / 失效。
  /// 数字全部基于真实数据计算；模型拿不到的项（待更新）显示 0。
  List<Widget> _statChips(List<BookSource> base) {
    final total = base.length;
    // 正常 = 启用；异常 = 停用
    final enabled = base.where((s) => s.enabled).length;
    final disabled = total - enabled;
    // 重复 = 按 id/url 去重后多出来的条数
    final unique = base
        .map((s) => s.url.trim().isNotEmpty ? s.url.trim() : s.id)
        .toSet()
        .length;
    final duplicate = total - unique;
    // 失效 = 体检判死的源（未跑体检则为 0，不编造）
    final dead = _health.values
        .where((h) => h.level == BookSourceHealthLevel.dead)
        .length;
    // 待更新：模型没有"可更新"字段 → 恒为 0
    const pending = 0;
    final stats = <(IconData, int)>[
      (Icons.menu_book_rounded, total),
      (Icons.update_rounded, pending),
      (Icons.check_circle_outline_rounded, enabled),
      (Icons.copy_all_rounded, duplicate),
      (Icons.error_outline_rounded, disabled),
      (Icons.heart_broken_outlined, dead),
    ];
    return [
      for (var i = 0; i < stats.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        _statChip(stats[i].$1, stats[i].$2),
      ],
      const SizedBox(width: 8),
    ];
  }

  /// 一个统计 chip：浅底圆角块 + 小图标 + 数量（截图同款）
  Widget _statChip(IconData icon, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: _isDark
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: JellyTheme.textSecondary),
          const SizedBox(width: 5),
          Text(
            '$count',
            style: TextStyle(
              fontSize: AppTheme.fontSubhead,
              fontWeight: FontWeight.w600,
              color: _titleColor,
            ),
          ),
        ],
      ),
    );
  }

  /// 一个分组 chip（选中=深色实底白字，未选=浅底灰字）
  Widget _groupChip(String label, int count, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on
              ? (_isDark ? Colors.white : JellyTheme.primary)
              : (_isDark
                    ? Colors.white.withValues(alpha: 0.07)
                    : Colors.black.withValues(alpha: 0.04)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 「全部」前面有个 ∞ 标记（截图如此）
            if (label == '全部') ...[
              Icon(
                Icons.all_inclusive_rounded,
                size: 14,
                color: on
                    ? (_isDark ? JellyTheme.backgroundDark : Colors.white)
                    : JellyTheme.textSecondary,
              ),
              const SizedBox(width: 4),
            ],
            Text(
              '$label $count',
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                fontWeight: on ? FontWeight.w600 : FontWeight.normal,
                color: on
                    ? (_isDark ? JellyTheme.backgroundDark : Colors.white)
                    : JellyTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「新建分组」对话框（截图：标题 + 输入框 + 取消/确定）
  Future<void> _showNewGroup() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          '新建分组',
          style: TextStyle(fontSize: AppTheme.fontTitle3, color: _titleColor),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '输入分组名称',
            filled: true,
            fillColor: _isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.04),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    // 新建分组本身不产生书源 —— 它只是个"待用"的分组名。
    // 这里把它落成一个空分组的可见占位：取消隐藏它并选中，
    // 用户随后可以给书源改分组（截图里的「设置分组」）。
    setState(() {
      _hiddenGroups.remove(name);
      _pickedGroup = name;
    });
    _toast('已创建分组「$name」，可在书源上点「设置分组」归入');
  }

  /// 「管理分组」弹层（截图：管理分组 + 设置/新建/批量删除 + 拖动/眼睛）
  Future<void> _showManageGroups() async {
    final all = store.sorted();
    final names = <String>{for (final s in all) s.group}.toList();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 6),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: JellyTheme.textSecondary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 8, 6),
                  child: Row(
                    children: [
                      Text(
                        '管理分组',
                        style: TextStyle(
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w700,
                          color: _titleColor,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '新建分组',
                        onPressed: () {
                          Navigator.pop(ctx);
                          _showNewGroup();
                        },
                        icon: Icon(
                          Icons.create_new_folder_outlined,
                          size: 21,
                          color: _titleColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: names.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(40),
                          child: Text(
                            '还没有分组',
                            style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: JellyTheme.textSecondary,
                            ),
                          ),
                        )
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            for (final g in names)
                              ListTile(
                                leading: Icon(
                                  Icons.drag_handle_rounded,
                                  size: 20,
                                  color: JellyTheme.textSecondary,
                                ),
                                title: Text(
                                  g,
                                  style: TextStyle(
                                    fontSize: AppTheme.fontHeadline,
                                    color: _titleColor,
                                  ),
                                ),
                                subtitle: Text(
                                  '${all.where((s) => s.group == g).length} 个源',
                                  style: TextStyle(
                                    fontSize: AppTheme.fontFootnote,
                                    color: JellyTheme.textSecondary,
                                  ),
                                ),
                                // 眼睛 = 该组是否显示在列表里
                                trailing: IconButton(
                                  tooltip: _hiddenGroups.contains(g)
                                      ? '当前隐藏，点击显示'
                                      : '当前显示，点击隐藏',
                                  onPressed: () => setSheet(() {
                                    setState(() {
                                      if (!_hiddenGroups.remove(g)) {
                                        _hiddenGroups.add(g);
                                      }
                                    });
                                  }),
                                  icon: Icon(
                                    _hiddenGroups.contains(g)
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                    size: 20,
                                    color: JellyTheme.textSecondary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 分组名 → emoji 图标（Cmbok 截图：⚡快速书源 / 📣正版书源 / 📂通常书源）
  static String _groupEmoji(String group) {
    if (group.contains('快速')) return '⚡';
    if (group.contains('正版')) return '📣';
    if (group.contains('下载')) return '📥';
    if (group.contains('特殊')) return '🔞';
    if (group.contains('出版')) return '📕';
    if (group.contains('同人')) return '📓';
    if (group.contains('轻文') || group.contains('轻小说')) return '📄';
    return '📂';
  }

  /// 一个书源卡片：
  ///   [方形复选框] [缩略图] ✅名称 ⓘ / 分组小标签 ......  [启用开关]
  ///
  ///   · 左侧缩略图：模型没有封面字段 → 以"分组 emoji"块降级代替
  ///   · 名称前带状态点：启用=绿勾，停用=灰⊘
  ///   · 点正文 / 复选框 → 进入多选并勾选；长按 / ⓘ → 源菜单
  Widget _sourceTile(BookSource s) {
    final sel = _selected.contains(s.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SwipeActionTile(
        // 多选模式下关闭左滑，避免与勾选/点击冲突
        enabled: !_selectMode,
        backgroundColor: _card,
        actions: [
          SwipeAction(
            icon: Icons.edit_outlined,
            label: '编辑',
            color: JellyTheme.primary,
            onTap: () => _editSource(s),
          ),
          SwipeAction(
            icon: Icons.ios_share_rounded,
            label: '分享',
            color: const Color(0xFF3AA0FF),
            onTap: () => _shareOne(s),
          ),
          SwipeAction(
            icon: Icons.delete_outline_rounded,
            label: '删除',
            color: const Color(0xFFFF5A5A),
            onTap: () => _deleteOne(s),
          ),
        ],
        child: Container(
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(14),
            border: sel
                ? Border.all(color: JellyTheme.primary, width: 1.2)
                : null,
          ),
          child: Row(
            children: [
              // 复选框（常驻）
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: GestureDetector(
                  onTap: () => setState(() {
                    if (sel) {
                      _selected.remove(s.id);
                    } else {
                      _selected.add(s.id);
                      // 勾选即进入选择模式（顶栏出现"选中 N"）
                      _selectMode = true;
                    }
                    if (_selected.isEmpty) _selectMode = false;
                  }),
                  child: Icon(
                    sel ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 22,
                    color: sel ? JellyTheme.primary : JellyTheme.textSecondary,
                  ),
                ),
              ),
              Expanded(
                child: ListTile(
                  contentPadding: const EdgeInsets.fromLTRB(8, 2, 6, 2),
                  leading: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.black.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _groupEmoji(s.group),
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
                  title: Row(
                    children: [
                      // 状态点：启用=绿勾，停用=灰⊘
                      Icon(
                        s.enabled
                            ? Icons.check_circle_rounded
                            : Icons.block_rounded,
                        size: 14,
                        color: s.enabled
                            ? Colors.green
                            : JellyTheme.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w600,
                            color: s.enabled
                                ? _titleColor
                                : JellyTheme.textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      // ⓘ 小标：点它打开书源菜单（编辑/置顶/登录/删除/设置分组）
                      GestureDetector(
                        onTap: () => _showSourceMenu(s),
                        child: Icon(
                          Icons.info_outline_rounded,
                          size: 15,
                          color: JellyTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 分组小标签（如「通常书源」）
                      Container(
                        margin: const EdgeInsets.only(top: 3),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: _isDark
                              ? Colors.white.withValues(alpha: 0.07)
                              : Colors.black.withValues(alpha: 0.045),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          s.group.isEmpty ? '未分组' : s.group,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTheme.fontCaption,
                            color: JellyTheme.textSecondary,
                          ),
                        ),
                      ),
                      if (s.isPythonSource) _pythonBadge(),
                      if (_health[s.id] != null) _healthBadge(_health[s.id]!),
                    ],
                  ),
                  // 点正文 = 进入多选并勾选；长按 = 进入多选并勾上（不再弹菜单）
                  onTap: () => setState(() {
                    if (sel) {
                      _selected.remove(s.id);
                    } else {
                      _selected.add(s.id);
                      _selectMode = true;
                    }
                    if (_selected.isEmpty) _selectMode = false;
                  }),
                  onLongPress: () => setState(() {
                    _selectMode = true;
                    _selected.add(s.id);
                  }),
                  trailing: Switch(
                    value: s.enabled,
                    activeThumbColor: JellyTheme.primary,
                    onChanged: (v) => store.setEnabled(s.id, v),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Python 源徽标（仓库列表区分用）
  Widget _pythonBadge() {
    return Container(
      margin: const EdgeInsets.only(top: 3),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
      decoration: BoxDecoration(
        color: _isDark
            ? JellyTheme.primary.withValues(alpha: 0.22)
            : JellyTheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'Python',
        maxLines: 1,
        style: TextStyle(
          fontSize: AppTheme.fontCaption,
          color: JellyTheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 打开书源编辑页（config 型源不能走 Legado 的 7-tab 表单）
  Future<void> _editSource(BookSource s) async {
    if (s.isConfig) {
      // config 源的数据在 `config` 体内，7-tab 表单读顶层键 → 打开就是空表单，
      // 保存还会把 62 个字段塞进 raw 造成 id 漂移（详见 _showSourceMenu 注释）。
      _toast('这是 config 型源：请用它的配置编辑方式修改，此编辑页会写坏它的 JSON');
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookSourceEditorPage(source: s)),
    );
    if (mounted) setState(() {});
  }

  /// 分享单个书源（JSON 复制到剪贴板）
  Future<void> _shareOne(BookSource s) async {
    final json = BookSourceService.instance.exportSources([s]);
    await Clipboard.setData(ClipboardData(text: json));
    _toast('已复制「${s.name}」到剪贴板');
  }

  /// 删除单个书源（二次确认）
  Future<void> _deleteOne(BookSource s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text(
          '删除书源',
          style: TextStyle(fontSize: AppTheme.fontHeadline),
        ),
        content: Text('删除「${s.name}」？不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await store.remove(s.id);
    if (mounted) setState(() {});
    _toast('已删除「${s.name}」');
  }

  /// 点书源卡片弹出的底部菜单（按截图）：
  ///   顶部：源名 + 分组名 + ✏编辑 / ⬆置顶 / 🗑删除
  ///   列表：设置分组
  Future<void> _showSourceMenu(BookSource s) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 10),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: JellyTheme.textSecondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              // 标题行：源名/分组 + 三个圆钮
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppTheme.fontTitle3,
                              fontWeight: FontWeight.w700,
                              color: _titleColor,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            s.group.isEmpty ? '未分组' : s.group,
                            style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: JellyTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _groupActionBtn(Icons.edit_outlined, '编辑', () async {
                      Navigator.pop(ctx);
                      await _editSource(s);
                    }),
                    const SizedBox(width: 8),
                    _groupActionBtn(Icons.vertical_align_top_rounded, '置顶', () {
                      Navigator.pop(ctx);
                      // 置顶 = 把它排到最前（store 有 order 字段）
                      store.reorder([s.id]);
                    }),
                    const SizedBox(width: 8),
                    // ⚠️ 这个「登录」圆钮必须有：BookSourceLoginPage 原来的
                    // 唯一入口是被我删掉的 _showDetail。删了它登录页就成了
                    // 孤儿页面（代码在但用户进不去）——等于弄丢功能。
                    // 截图里圆钮位置只画了 3 个，但登录是必需功能，
                    // 多一个不影响主流程。
                    _groupActionBtn(
                      Icons.login_rounded,
                      '登录',
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => BookSourceLoginPage(source: s),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _groupActionBtn(
                      Icons.delete_outline_rounded,
                      '删除',
                      () async {
                        Navigator.pop(ctx);
                        await _deleteOne(s);
                      },
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // 设置分组
              ListTile(
                leading: Icon(
                  Icons.folder_outlined,
                  size: 22,
                  color: _titleColor,
                ),
                title: Text(
                  '设置分组',
                  style: TextStyle(
                    fontSize: AppTheme.fontHeadline,
                    color: _titleColor,
                  ),
                ),
                subtitle: Text(
                  s.group.isEmpty ? '未分组' : s.group,
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: JellyTheme.textSecondary,
                  ),
                ),
                trailing: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: JellyTheme.textSecondary,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showSetGroup({s.id});
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// 「设置分组」预设分组（外加仓库里已有的自定义分组）
  static const _presetGroups = <String>[
    '未分组',
    '通常书源',
    '正版书源',
    '快速书源',
    '下载书源',
    '特殊书源',
    '出版书源',
    '同人书源',
    '轻文书源',
  ];

  /// 「设置分组」底部弹层：给一批书源（多选/单个）归入某个分组。
  ///   顶部把手 + 标题「设置分组 (N 个源)」+ ×；下方一列分组选项，
  ///   每项左侧方形 checkbox 图标，当前分组右侧带 ✓。
  Future<void> _showSetGroup(Set<String> ids) async {
    if (ids.isEmpty) return;
    final all = store.sorted();
    // 选项 = 预设分组 + 仓库里已存在的自定义分组（去重）
    final existing = <String>{for (final s in all) s.group};
    final options = <String>[
      ..._presetGroups,
      ...existing.where((g) => !_presetGroups.contains(g)),
    ];
    // 当前分组：全部选中源同属一个组时才标记（否则不显示 ✓）
    final selectedGroups = <String>{
      for (final s in all.where((s) => ids.contains(s.id))) s.group,
    };
    final current = selectedGroups.length == 1 ? selectedGroups.first : null;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.7,
        ),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 6),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: JellyTheme.textSecondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 8, 6),
                child: Row(
                  children: [
                    Text(
                      '设置分组 (${ids.length} 个源)',
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w700,
                        color: _titleColor,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(ctx),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: _titleColor,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final g in options)
                      ListTile(
                        leading: Icon(
                          g == current
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 22,
                          color: g == current
                              ? JellyTheme.primary
                              : JellyTheme.textSecondary,
                        ),
                        title: Text(
                          g,
                          style: TextStyle(
                            fontSize: AppTheme.fontHeadline,
                            color: _titleColor,
                          ),
                        ),
                        trailing: g == current
                            ? Icon(
                                Icons.check_rounded,
                                size: 20,
                                color: JellyTheme.primary,
                              )
                            : null,
                        onTap: () async {
                          Navigator.pop(ctx);
                          for (final id in ids) {
                            await store.setGroup(id, g);
                          }
                          _toast('已归入「$g」');
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================

  /// 导入书源：居中弹窗（用户 2026-10-18），四种方式按
  /// 「网址 / 文件 / 文本 / 二维码」排列。
  Future<void> _showImportSheet() async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        title: Text(
          '导入书源',
          style: TextStyle(
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w700,
            color: _titleColor,
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选择一种导入方式，导入按地址合并去重，不会覆盖已有源',
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  color: JellyTheme.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _importTile(
                      '网址',
                      Icons.link_rounded,
                      () => Navigator.pop(ctx, 'url'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _importTile(
                      '文件',
                      Icons.folder_open_rounded,
                      () => Navigator.pop(ctx, 'file'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _importTile(
                      '文本',
                      Icons.text_snippet_outlined,
                      () => Navigator.pop(ctx, 'text'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _importTile(
                      '二维码',
                      Icons.qr_code_scanner_rounded,
                      () => Navigator.pop(ctx, 'qr'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.pop(ctx, 'python'),
                  icon: Icon(
                    Icons.code_rounded,
                    size: 16,
                    color: JellyTheme.textSecondary,
                  ),
                  label: Text(
                    '导入 Python 源',
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: JellyTheme.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'url') {
      await _importByUrl();
    } else if (action == 'file') {
      await _importByFile();
    } else if (action == 'text') {
      await _importByCode();
    } else if (action == 'qr') {
      await _importByQrCode();
    } else if (action == 'python') {
      await _importByPython();
    }
  }

  /// 弹窗里的一个方式按钮（2×2 宫格）
  Widget _importTile(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        height: 82,
        decoration: BoxDecoration(
          color: JellyTheme.primary.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: JellyTheme.primary.withValues(alpha: 0.18),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 24, color: JellyTheme.primary),
            const SizedBox(height: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: AppTheme.fontFootnote,
                fontWeight: FontWeight.w600,
                color: _titleColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 地址导入
  Future<void> _importByUrl() async {
    final ctrl = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '地址导入',
                  style: TextStyle(
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600,
                    color: _titleColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '支持 http(s) 链接；返回内容为书源 JSON',
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    color: JellyTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: ctrl,
                  style: const TextStyle(fontSize: AppTheme.fontSubhead),
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    hintText: 'https://example.com/booksource.json',
                    hintStyle: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: JellyTheme.textSecondary,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  child: FilledButton(
                    onPressed: () async {
                      final url = ctrl.text.trim();
                      if (url.isEmpty) {
                        _toast('请先填写网址');
                        return;
                      }
                      Navigator.pop(ctx);
                      await _fetchAndImport(url);
                    },
                    child: const Text('拉取并导入'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    ctrl.dispose();
  }

  /// 口令导入（粘贴）
  Future<void> _importByCode() async {
    final ctrl = TextEditingController();
    var error = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(ctx).bottom,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '口令导入',
                    style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600,
                      color: _titleColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '粘贴分享口令或书源 JSON（单个 / 数组 / {"sources":[…]} 都行）',
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: JellyTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: ctrl,
                    maxLines: 7,
                    minLines: 4,
                    style: const TextStyle(fontSize: AppTheme.fontSubhead),
                    decoration: InputDecoration(
                      hintText: '在此粘贴…',
                      hintStyle: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        color: JellyTheme.textSecondary,
                      ),
                      filled: true,
                      fillColor: _isDark
                          ? Colors.white.withValues(alpha: 0.05)
                          : Colors.black.withValues(alpha: 0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  if (error.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      error,
                      style: const TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: Colors.redAccent,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          final d = await Clipboard.getData('text/plain');
                          final t = d?.text;
                          if (t != null && t.isNotEmpty) {
                            ctrl.text = t;
                            setSheet(() => error = '');
                          }
                        },
                        icon: const Icon(Icons.content_paste_rounded, size: 17),
                        label: const Text('读剪贴板'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () async {
                          final text = ctrl.text.trim();
                          if (text.isEmpty) {
                            setSheet(() => error = '请先粘贴内容');
                            return;
                          }
                          final parsed = _parseSources(text);
                          if (parsed.isEmpty) {
                            setSheet(
                              () => error =
                                  '没解析出书源。Legado 书源需含 bookSourceName / bookSourceUrl',
                            );
                            return;
                          }
                          final r = await store.addAll(parsed);
                          await _reloadComicSourcesIfNeeded(parsed);
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          _toast(
                            r.added > 0
                                ? '已导入 ${r.added} 个书源'
                                : '已更新 ${r.updated} 个书源',
                          );
                        },
                        child: const Text('导入'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    ctrl.dispose();
  }

  /// 从字节导入：自动识别 zip 还是文本。
  ///
  /// 为什么要判 zip：**书源分发最常见的形态就是一个 zip**
  /// （截图里地址栏也写着 `json / zip`）。不认 zip 的话，
  /// 用户下载到的书源包导进来只会得到"JSON 解析失败"，
  /// 而且完全看不出原因是"这是个压缩包"。
  Future<void> _importBytes(Uint8List bytes) async {
    // zip 魔数 PK\x03\x04（空 zip 是 PK\x05\x06，跨卷是 PK\x07\x08）
    final isZip =
        bytes.length > 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07);

    if (!isZip) {
      final text = utf8.decode(bytes, allowMalformed: true);
      await _doImportText(text);
      return;
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      _toast('压缩包解析失败：$e');
      return;
    }

    // 把包里所有 .json/.txt 都当书源试一遍。
    // 不假设"只有一个文件" —— 书源包常按站点分组放多个 json。
    var totalAdded = 0;
    var totalUpdated = 0;
    var tried = 0;
    var failed = 0;
    final allParsed = <BookSource>[];

    for (final f in archive) {
      if (!f.isFile) continue;
      final lower = f.name.toLowerCase();
      if (!lower.endsWith('.json') && !lower.endsWith('.txt')) continue;
      tried++;
      try {
        final data = f.content;
        final fb = data is Uint8List
            ? data
            : Uint8List.fromList(List<int>.from(data as List));
        final text = utf8.decode(fb, allowMalformed: true);
        final parsed = _parseSources(text);
        if (parsed.isEmpty) continue;
        final r = await store.addAll(parsed);
        totalAdded += r.added;
        totalUpdated += r.updated;
        allParsed.addAll(parsed);
      } catch (_) {
        failed++;
      }
    }

    if (tried == 0) {
      _toast('压缩包里没有 json / txt 书源文件');
      return;
    }
    if (totalAdded == 0 && totalUpdated == 0) {
      _toast('压缩包里的 $tried 个文件都没解析出书源');
      return;
    }
    // 包里有漫画脚本 → 让漫画源管理器立刻注册（书源列表已隐藏它们）
    await _reloadComicSourcesIfNeeded(allParsed);
    _toast(
      '已从压缩包导入：新增 $totalAdded 个'
      '${totalUpdated > 0 ? '、更新 $totalUpdated 个' : ''}'
      '${failed > 0 ? '（$failed 个文件解析失败）' : ''}',
    );
    await _showCompatReport(allParsed);
  }

  /// 本地文件导入。
  ///
  /// ⚠️ file_picker 13.x 的 API 与旧版差别很大，这里踩过坑，写清楚：
  ///   · `FilePicker.pickFiles(...)` 是**静态**方法（旧版是 `FilePicker.platform.pickFiles`）
  ///   · 返回值是 **`List<PlatformFile>`**（旧版是 `FilePickerResult?`）
  ///   · 没有 `withData` 参数；`PlatformFile` 也没有 `bytes` 属性
  ///   · 读内容用 **`f.readAsBytes()`**（返回 `Future<Uint8List>`），
  ///     或经 `f.path` 自己读文件
  Future<void> _importByFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt', 'zip'],
      );
      if (result.isEmpty) return;
      final f = result.first;

      Uint8List bytes;
      try {
        // 首选 readAsBytes：不依赖 path（某些平台 path 可能为 null）
        bytes = await f.readAsBytes();
      } catch (_) {
        // 退回按路径读
        final path = f.path;
        if (path == null) {
          _toast('读不出这个文件（没有本地路径）');
          return;
        }
        bytes = await File(path).readAsBytes();
      }

      if (bytes.isEmpty) {
        _toast('文件是空的');
        return;
      }
      await _importBytes(bytes);
    } catch (e) {
      _toast('导入失败：${e.toString().split('\n').first}');
    }
  }

  /// 导入 Python 源（.py 文件 → PythonSourcesService 注册 + 生成书源条目）。
  ///
  /// 生成的书源 raw 带 `pythonKey`（= 文件名去 .py），搜索/详情/目录/正文
  /// 由 CPython 引擎的 `src.spider.book.<pythonKey>` 执行（book_source_python_engine.dart）。
  /// 引擎未就绪（非 iOS / 未启动）时仍会写条目，但给出提示。
  Future<void> _importByPython() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['py'],
      );
      if (result.isEmpty) return;
      final f = result.first;
      String code;
      final path = f.path;
      if (path == null) {
        _toast('读不出这个文件（没有本地路径）');
        return;
      }
      try {
        code = await File(path).readAsString();
      } catch (_) {
        _toast('文件读取失败');
        return;
      }
      if (code.trim().isEmpty) {
        _toast('文件是空的');
        return;
      }
      // key = 文件名去 .py（兼容带路径的情况）
      final fileName = f.name.endsWith('.py')
          ? f.name.substring(0, f.name.length - 3)
          : f.name;
      final key = fileName.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
      if (key.isEmpty) {
        _toast('文件名不合法');
        return;
      }
      setState(() => _busy = true);
      // 1. 写文件 + 注册进引擎
      final installed = await PythonSourcesService.instance.installSource(
        'book',
        key,
        code,
      );
      if (!installed.ok) {
        _toast('Python 源注册失败：${installed.message ?? '未知错误'}');
        return;
      }
      // 2. 生成书源条目（Legado 形态 + pythonKey）
      final src = BookSource(
        raw: <String, dynamic>{
          'bookSourceName': key,
          'bookSourceUrl': 'python://$key',
          'bookSourceGroup': 'Python',
          'bookSourceComment': 'Python 书源（CPython 引擎执行）',
          'bookSourceType': 0,
          'enabled': true,
          'enabledExplore': false,
          'pythonKey': key,
        },
        id: 'python:$key',
      );
      final r = await store.addAll([src]);
      _toast(
        '已导入 Python 源「$key」'
        '${(r.added > 0 || r.updated > 0) ? '' : '（已存在，已更新）'}'
        '${!PythonManager.instance.isIOS ? '；注意：Python 引擎需 iOS 真机' : ''}',
      );
      // 刷新列表（store 有监听时无需手动重载，保守起见触发一次）
      if (mounted) setState(() {});
    } catch (e) {
      _toast('导入失败：${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fetchAndImport(String url) async {
    setState(() => _busy = true);
    try {
      // 用 bytes 而不是 String：书源地址可能是 zip，
      // 当字符串解出来会是乱码，根本判不出问题在哪
      // ✅ **书源包下载也走「网络代理」**（本轮接上 ✓）—— 原来这里是**内联新建** ✗
      //   （`await Dio().get(...)` ✓ 一行里建完就用 ✓），没法"先构造再挂" ✓
      //   ⇒ 所以**拆成两行** ✓：先建 `proxyDio` ✓ → 挂代理 ✓ → 再用它请求 ✓✓。
      //   ℹ️ 安全依据 ✓：本处**无自定义适配器 / 无自定义 UA** ✗✓（就在下面几行 ✓）
      //     ⇒ 挂代理不会影响任何东西 ✓；而且本页**已有**浏览器 UA 的补丁 ✓（`:1707-1720` ✓）
      //       那是在 `Options(headers:)` 里 ✓（**Dio 选项层** ✓）→ 与 socket 层适配器**互不干扰** ✓✓（不会丢 ✓）。
      //   · 代理**关闭** ✓ → 返回 false ✓ **一行不改** ✓（与从前完全一致 ✓✓）
      final proxyDio = Dio();
      applyGlobalProxy(proxyDio);
      final res = await proxyDio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          // ✅ **补浏览器 UA**（本轮新增 ✓）—— 兼容 `yckceo.com/yuedu/shuyuan/json/id/N.json` 这类地址 ✓。
          //   为什么需要 ✗：此前没有任何 headers ✓ → 用的是 **Dio 默认 UA（`Dart/xxx`）** ✗，
          //   而不少书源分发站 / CDN 会因此**直接返回 403 / 空体** ✗✓
          //   —— 本仓对同一问题早有记录 ✓：`download_service:178`「默认 Dart/xxx 会被 c-nd3 等 CDN 拦 403
          //   （同 `app_image_cache.dart` 的 **UA 拦截器修复**）」✓✓，这里属于**同一类修复** ✓。
          //   ℹ️ 用**移动 Safari** 的 UA ✓（与 App 场景一致 ✓）；这只是**请求头** ✓，
          //     不改变任何解析逻辑 ✓（`_parseSources` 的 4 种形态兼容保持不变 ✓）。
          headers: const {
            'User-Agent':
                'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
                'Mobile/15E148 Safari/604.1',
            'Accept': 'application/json,text/plain,*/*',
          },
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final list = res.data;
      if (list == null || list.isEmpty) {
        _toast('网址返回内容为空');
        return;
      }
      await _importBytes(Uint8List.fromList(list));
    } catch (e) {
      _toast('拉取失败：${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doImportText(String text) async {
    final parsed = _parseSources(text);
    if (parsed.isEmpty) {
      _toast('没解析出书源。Legado 书源需含 bookSourceName / bookSourceUrl');
      return;
    }
    final r = await store.addAll(parsed);
    await _reloadComicSourcesIfNeeded(parsed);
    final comics = parsed.where((s) => s.isComicSource).length;
    final base = r.added > 0 && r.updated > 0
        ? '新增 ${r.added} 个、更新 ${r.updated} 个书源'
        : (r.added > 0 ? '已导入 ${r.added} 个书源' : '已更新 ${r.updated} 个书源');
    // 书源仓现在也会展示漫画源（阅读器自动走图片模式）
    _toast(
      comics > 0 ? '$base（含 $comics 个漫画源，图片模式阅读）' : base,
    );
    await _showCompatReport(parsed);
  }

  /// 导入后的兼容性报告：只在有 blocker / warning 时弹窗。
  ///
  /// 源已经入库（不阻断导入），这里只是把"哪些源可能跑不通、为什么"说清楚，
  /// 用户可以在书源管理里直接停用它们。
  Future<void> _showCompatReport(List<BookSource> parsed) async {
    if (parsed.isEmpty || !mounted) return;
    final results = parsed.map(BookSourceCompatibility.analyze).toList();
    final sum = BookSourceCompatibility.summarize(results);
    if (sum.blocked == 0 && sum.warning == 0) return;

    final problems = results.where((r) => r.hasAny).toList();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入完成 · 兼容性检查'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '可直接使用 ${sum.ok} 个，可能有问题 ${sum.warning} 个，'
                '不可用 ${sum.blocked} 个。',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: problems.length > 30 ? 30 : problems.length,
                  itemBuilder: (_, i) {
                    final r = problems[i];
                    final color = r.usable
                        ? Colors.orangeAccent
                        : Colors.redAccent;
                    final detail = r.issues
                        .take(3)
                        .map((e) => e.message)
                        .join('；');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            r.usable
                                ? Icons.warning_amber_rounded
                                : Icons.error_outline,
                            size: 16,
                            color: color,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${r.source.name}：$detail',
                              style: TextStyle(fontSize: 12, color: color),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              if (problems.length > 30) ...[
                const SizedBox(height: 6),
                Text(
                  '仅显示前 30 个，其余可在书源管理里逐条查看。',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(ctx).disabledColor,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 解析书源 JSON（兼容 4 种形态 + 脏 JSON）。
  /// 实现收敛到 [BookSourceImportParser]，订阅更新与本页导入共用一份。
  /// 解析导入内容并**打上书源仓归属**：书源仓也能导入漫画源
  ///（漫画源在阅读器里自动走图片模式）。漫源仓库的导入不走这里。
  List<BookSource> _parseSources(String text) => [
    for (final s in BookSourceImportParser.parseSources(text))
      s.withWarehouse('book'),
  ];

  // ============================================================
  // 详情 / 删除
  // ============================================================

  Future<void> _runHealthCheck() async {
    final targets = _visible;
    if (targets.isEmpty) return;
    // 完整「书源体检」页：并发选择 → 逐源体检（取书→详情→目录→正文）→
    // 统计分组列表 → 一键优化 / 清理（对齐参考图 IMG_8554~8561）
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookSourceHealthPage(),
      ),
    );
  }

  /// 体检标记：小圆点 + 文字（可用/部分可用/可疑/失效）
  Widget _healthBadge(BookSourceHealth h) {
    final (color, icon) = switch (h.level) {
      BookSourceHealthLevel.healthy => (
        Colors.green,
        Icons.check_circle_rounded,
      ),
      BookSourceHealthLevel.partial => (Colors.orange, Icons.error_rounded),
      BookSourceHealthLevel.suspect => (Colors.amber, Icons.help_rounded),
      BookSourceHealthLevel.dead => (Colors.redAccent, Icons.cancel_rounded),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '${h.levelText} · ${h.detail}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: AppTheme.fontCaption, color: color),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 书源编辑（V2.0.7 的「书源编辑」）
  // ============================================================

  // ❌ 这里原来挂着一段与"编辑弹层"有关的文档注释 ✗ —— 内容是：
  //   「编辑弹层。为什么做成"常用字段表单 + 完整 JSON"两段……
  //     常用字段（名称/网址/分组）走表单，其余走 JSON，且互相同步」
  // 但它**挂错了方法** ✗：紧跟在它后面的其实是 `_deleteSelected`（批量删除 ✓），
  // 跟"编辑弹层"毫无关系 ✓ → 属**孤儿注释** ✓，已移除 ✓。
  // ⚠️ 如果本文件里确实还有那个"编辑弹层"（表单 + JSON 两段 ✓），
  //   请把上面那段说明**移到它自己头上** ✓；否则那段描述本身也是过时的 ✓。
  /// 批量删除选中的书源（含二次确认 ✓）
  Future<void> _deleteSelected() async {
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '删除书源',
          style: TextStyle(fontSize: AppTheme.fontHeadline),
        ),
        content: Text('确定删除选中的 $n 个书源？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ids = _selected.toList();
    for (final id in ids) {
      await store.remove(id);
    }
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
    _toast('已删除 $n 个书源');
  }
}
