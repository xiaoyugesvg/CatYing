import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/card_action_sheet.dart';
import 'package:tvbox/rex/rex_layout_sheet.dart';
import 'package:tvbox/rex/rex_market_page.dart';
import 'package:tvbox/rex/rex_models.dart';
import 'package:tvbox/rex/rex_service.dart';

/// REX 订阅管理：市场入口 + 启用/停用 + 刷新 + 排序 + 改地址 + 删除。
///
/// 布局按「已启用 / 已停用」两段分组 —— 原来的单列表里开关一关，
/// 卡片只是变灰、位置不变，用户很难看清「现在到底有几个源在首页」。
///
/// 2026-10-24 重做（用户要求）：
///   · 视图切换：列表 / 一行 2 列 / 一行 4 列（偏好落盘 rex_manage_view）；
///   · 多选模式：全选 / 批量启用 / 批量停用 / 清空（批量移除）；
///   · 长按弹**卡片式**菜单（一排两张，与影视源切换同一套 showCardActions）；
///   · 卡片名称下面不再显示链接（界面更干净）。
class RexManagePage extends StatefulWidget {
  const RexManagePage({super.key});

  @override
  State<RexManagePage> createState() => _RexManagePageState();
}

class _RexManagePageState extends State<RexManagePage> {
  final _service = RexService.instance;
  bool _busy = false;

  /// 多选模式：点卡片 = 勾选，底栏出批量操作
  bool _selecting = false;
  final Set<String> _selected = {};

  /// 视图：0 = 列表，2/3/4 = 一行几列（镜像 PlayerPrefs.rexManageView）
  int _view = 2;

  // ── 工具栏：搜索 / 排序 / 定位（对齐影视源面板的能力）──────────
  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  String _kw = '';

  /// 0 = 订阅顺序，1 = 名称，2 = 分类数（多→少）
  int _sort = 0;

  /// 每个模块一个 GlobalKey，「定位」靠它精确滚到首页正在用的那个
  final Map<String, GlobalKey> _cardKeys = {};

  GlobalKey _keyOf(String url) =>
      _cardKeys.putIfAbsent(url, () => GlobalKey());

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;
  Color get _line => _isDark
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.06);
  Color get _tile => _isDark
      ? Colors.white.withValues(alpha: 0.05)
      : Colors.black.withValues(alpha: 0.025);

  /// 文字 / 图标用的强调色（暗色下 accentColor 是墨灰，看不见）
  Color get _accent => AppTheme.accentOnSurface;

  @override
  void initState() {
    super.initState();
    _view = PlayerPrefs.instance.rexManageView.value;
    _service.load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── 搜索 / 排序 / 定位 ───────────────────────────────────────

  /// 过滤 + 排序后的模块（两段分组前先过一遍）
  List<RexModule> _arrange(List<RexModule> src) {
    Iterable<RexModule> it = src;
    if (_kw.isNotEmpty) {
      final k = _kw.toLowerCase();
      it = it.where((m) =>
          m.title.toLowerCase().contains(k) ||
          m.url.toLowerCase().contains(k));
    }
    final list = it.toList();
    switch (_sort) {
      case 1:
        list.sort((a, b) => a.title.compareTo(b.title));
        break;
      case 2:
        list.sort(
            (a, b) => b.listFunctions.length.compareTo(a.listFunctions.length));
        break;
      default:
        break; // 订阅顺序
    }
    return list;
  }

  /// 定位到「首页正在用的模块」
  void _locate() {
    final url = _service.lastModuleUrl;
    if (url == null) {
      AppToast.show('先去首页选一个模块', '');
      return;
    }
    final ctx = _cardKeys[url]?.currentContext;
    if (ctx == null) {
      AppToast.show('这个模块不在当前筛选结果里', '');
      return;
    }
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
      alignment: 0.3,
    );
  }

  // ── 视图切换 ─────────────────────────────────────────────────

  Future<void> _openLayout() async {
    final picked = await showRexLayoutSheet(
      context,
      listMode: _view == 0,
      // 列数统一在返回后落盘（onPick 只在选网格项时触发，列表项不触发）
      current: _view == 0 ? 2 : _view,
      maxColumns: 4,
      onPick: (_) async {},
    );
    if (picked == null || !mounted) return;
    await PlayerPrefs.instance.setRexManageView(picked);
    if (mounted) setState(() => _view = picked);
  }

  // ── 多选 / 批量 ───────────────────────────────────────────────

  void _toggleSelect(String url) => setState(() {
        if (_selected.contains(url)) {
          _selected.remove(url);
        } else {
          _selected.add(url);
        }
      });

  void _exitSelecting() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  Future<void> _batchEnable(bool v) async {
    if (_selected.isEmpty) return;
    for (final u in List<String>.from(_selected)) {
      await _service.setEnabled(u, v);
    }
    if (!mounted) return;
    setState(() {});
    AppToast.show(v ? '已启用 ${_selected.length} 个' : '已停用 ${_selected.length} 个', '');
  }

  /// 清空 = 移除所有勾选的模块（本地模块连源码文件一起删）
  Future<void> _batchRemove() async {
    final n = _selected.length;
    if (n == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空选中模块？'),
        content: Text('选中的 $n 个模块会从订阅列表移除；\n本地导入的模块源码文件也会一起删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    for (final u in List<String>.from(_selected)) {
      await _service.remove(u);
    }
    if (!mounted) return;
    _exitSelecting();
    setState(() => _busy = false);
    AppToast.show('已移除 $n 个模块', '');
  }

  // ── UI ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final all = _service.modules;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: _selecting
            ? IconButton(
                tooltip: '退出多选',
                icon: Icon(Icons.close_rounded, color: _fg),
                onPressed: _exitSelecting,
              )
            : null,
        title: Text(
          _selecting ? '已选 ${_selected.length} 个' : 'REX 订阅',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: AppTheme.fontTitle3,
              fontWeight: FontWeight.bold,
              color: _fg),
        ),
        actions: _selecting
            ? [
                TextButton(
                  onPressed: () => setState(() {
                    if (_selected.length == all.length) {
                      _selected.clear();
                    } else {
                      _selected
                        ..clear()
                        ..addAll(all.map((e) => e.url));
                    }
                  }),
                  child: Text(
                      _selected.length == all.length ? '取消全选' : '全选'),
                ),
                const SizedBox(width: 4),
              ]
            : [
                  if (all.isNotEmpty)
                    _topIcon(Icons.checklist_rounded, '多选',
                        _busy ? null : () => setState(() => _selecting = true)),
                  _topIcon(
                      _view == 0
                          ? Icons.view_list_rounded
                          : Icons.grid_view_rounded,
                      '视图',
                      _busy ? null : _openLayout),
                  _topIcon(Icons.storefront_rounded, '市场',
                      _busy ? null : _openMarket),
                  _topIcon(
                    Icons.sync_rounded,
                    '刷新',
                    _busy ? null : _refreshAll,
                    busy: _busy,
                  ),
                  const SizedBox(width: 4),
                ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: _service.revision,
        builder: (context, _, __) {
          final all = _service.modules;
          // 搜索 / 排序只影响显示，不影响顶部统计（统计始终是全量）
          final arranged = _arrange(all);
          final on = arranged.where((e) => e.enabled).toList();
          final off = arranged.where((e) => !e.enabled).toList();
          final enabledAll = all.where((e) => e.enabled).length;
          return ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            children: [
              _summaryCard(all.length, enabledAll),
              if (all.isNotEmpty) _toolbar(),
              if (all.isEmpty) ...[
                const SizedBox(height: 30),
                _empty(),
              ],
              if (all.isNotEmpty && arranged.isEmpty) ...[
                const SizedBox(height: 34),
                Center(
                  child: Text('没有匹配的模块',
                      style: TextStyle(
                          color: _sub, fontSize: AppTheme.fontSubhead)),
                ),
              ],
              if (on.isNotEmpty) ..._section('已启用', on),
              if (off.isNotEmpty) ..._section('已停用', off),
              if (all.isNotEmpty && !_selecting) ...[
                const SizedBox(height: 16),
                Text(
                  '首页只显示「已启用 + 有列表/搜索能力」的模块；'
                  '标着「仅播放」的模块没有可浏览内容，只作为取流源保留。',
                  style: TextStyle(
                      color: _sub,
                      fontSize: AppTheme.fontCaption,
                      height: 1.6),
                ),
              ],
            ],
          );
        },
      ),
      bottomNavigationBar: _selecting ? _selectionBar() : null,
    );
  }

  /// 一个分组（已启用 / 已停用）：标题 + 列表或网格
  List<Widget> _section(String title, List<RexModule> list) {
    return [
      const SizedBox(height: 18),
      _sectionTitle(title, list.length),
      if (_view == 0)
        for (var i = 0; i < list.length; i++)
          KeyedSubtree(
            key: _keyOf(list[i].url),
            child: _card(
              list[i],
              prevUrl: i > 0 ? list[i - 1].url : null,
              nextUrl: i < list.length - 1 ? list[i + 1].url : null,
            ),
          )
      else
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _view,
            mainAxisSpacing: _view >= 4 ? 8 : 10,
            crossAxisSpacing: _view >= 4 ? 8 : 10,
            // 固定高度 = 卡片尺寸刚好包住内容（用户：「满足内容就行，不要太大」）
            mainAxisExtent: _view >= 4 ? 108 : 128,
          ),
          itemCount: list.length,
          itemBuilder: (_, i) => KeyedSubtree(
            key: _keyOf(list[i].url),
            child: _gridCell(list[i], compact: _view >= 4),
          ),
        ),
    ];
  }

  /// 工具栏：搜索 + 排序 + 定位（影视源面板同款能力）
  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(17),
                border: Border.all(color: _line, width: 0.6),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  Icon(Icons.search_rounded, size: 15, color: _sub),
                  const SizedBox(width: 5),
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      style: TextStyle(
                          color: _fg, fontSize: AppTheme.fontSubhead),
                      onChanged: (v) => setState(() => _kw = v.trim()),
                      decoration: InputDecoration(
                        hintText: '搜索模块…',
                        hintStyle: TextStyle(color: _sub, fontSize: 12.5),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  if (_kw.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _searchCtrl.clear();
                        setState(() => _kw = '');
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(Icons.cancel, size: 14, color: _sub),
                      ),
                    ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<int>(
            tooltip: '排序',
            padding: EdgeInsets.zero,
            initialValue: _sort,
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 0, child: Text('订阅顺序')),
              PopupMenuItem(value: 1, child: Text('按名称')),
              PopupMenuItem(value: 2, child: Text('按分类数')),
            ],
            child: _roundTool(Icons.swap_vert_rounded),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _locate,
            child: Tooltip(
              message: '定位首页当前模块',
              child: _roundTool(Icons.my_location_rounded),
            ),
          ),
        ],
      ),
    );
  }

  Widget _roundTool(IconData icon) => Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(color: _tile, shape: BoxShape.circle),
        child: Icon(icon, size: 17, color: _sub),
      );

  /// 顶部概览：按小程序的写法做「实底卡片 + 环形进度」，
  /// 不再用整块渐变底（浅色主题下渐变会发灰、显脏）。
  Widget _summaryCard(int total, int enabled) {
    final ratio = total == 0 ? 0.0 : enabled / total;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
      decoration: BoxDecoration(
        color: _tile,
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
        border: Border.all(color: _line, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(Icons.extension_rounded, size: 17, color: _accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('我的模块',
                        style: TextStyle(
                            color: _fg,
                            fontSize: AppTheme.fontSubhead,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 1),
                    Text('启用 $enabled · 停用 ${total - enabled}',
                        style: TextStyle(
                            color: _sub, fontSize: AppTheme.fontCaption)),
                  ],
                ),
              ),
              // 右侧小环形进度：一眼看出启用比例
              SizedBox(
                width: 34,
                height: 34,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(
                        value: ratio,
                        strokeWidth: 2.6,
                        backgroundColor: _line,
                        valueColor: AlwaysStoppedAnimation<Color>(_accent),
                      ),
                    ),
                    Text('$enabled',
                        style: TextStyle(
                            color: _fg,
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accentColor,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 42),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMD)),
              ),
              onPressed: _busy ? null : _openMarket,
              icon: const Icon(Icons.add_rounded, size: 19),
              label: const Text('从市场添加模块'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text, int count) => Padding(
        padding: const EdgeInsets.only(bottom: 2, left: 2),
        child: Row(
          children: [
            Text(text,
                style: TextStyle(
                    color: _fg,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: _tile,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text('$count',
                  style:
                      TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
            ),
          ],
        ),
      );

  Widget _empty() => Column(
        children: [
          Icon(Icons.extension_outlined,
              size: 36, color: _sub.withValues(alpha: 0.6)),
          const SizedBox(height: 10),
          Text('还没有模块',
              style: TextStyle(
                  color: _fg,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('去市场挑一个合集，勾选后一键导入。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: _sub, fontSize: AppTheme.fontFootnote, height: 1.6)),
        ],
      );

  void _onCardTap(RexModule m) {
    if (_selecting) _toggleSelect(m.url);
  }

  /// 列表模式卡片。
  ///
  /// [prevUrl] / [nextUrl] 是**同一分组内**相邻模块的地址。
  ///
  /// 分组展示下不能再用「全局上移/下移」：整表里相邻的那个可能是被折叠在
  /// 另一组的模块，点一下卡片会原地不动。用相邻 url 精确交换。
  Widget _card(RexModule m, {String? prevUrl, String? nextUrl}) {
    final picked = _selected.contains(m.url);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _onCardTap(m),
      // 长按 → 卡片式快捷操作（卸载 / 分享 / 刷新…），比一个个点小箭头快
      onLongPress: _busy || _selecting ? null : () => _quickActions(m),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(12, 11, 6, 6),
        decoration: BoxDecoration(
          color: picked ? _accent.withValues(alpha: 0.10) : _tile,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          border: Border.all(
              color: picked ? _accent.withValues(alpha: 0.5) : _line,
              width: picked ? 1.2 : 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_selecting) ...[
                  _selectDot(picked),
                  const SizedBox(width: 10),
                ],
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _accent
                        .withValues(alpha: m.enabled ? 0.15 : 0.06),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(Icons.extension_rounded,
                      size: 19,
                      color: m.enabled
                          ? _accent
                          : _sub.withValues(alpha: 0.7)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.title.isEmpty ? 'REX 模块' : m.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: m.enabled ? _fg : _sub,
                              fontSize: AppTheme.fontHeadline,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 5,
                        runSpacing: 4,
                        children: [
                          if (m.version.isNotEmpty) _chip('v${m.version}'),
                          if (RexService.isLocal(m.url))
                            _chip('本地', accent: true),
                          _chip('${m.listFunctions.length} 个分类'),
                          if (m.canSearch) _chip('可搜索'),
                          if (m.canPlay) _chip('可播放'),
                          if (m.streamOnly) _chip('仅播放', accent: true),
                        ],
                      ),
                    ],
                  ),
                ),
                IgnorePointer(
                  ignoring: _selecting,
                  child: Opacity(
                    opacity: _selecting ? 0.35 : 1,
                    child: Switch(
                      value: m.enabled,
                      activeThumbColor: _accent,
                      onChanged: _busy
                          ? null
                          : (v) => _service.setEnabled(m.url, v),
                    ),
                  ),
                ),
              ],
            ),
            if (!_selecting)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_service.modules.length > 1) ...[
                    _mini(
                        Icons.keyboard_arrow_up_rounded,
                        prevUrl == null
                            ? null
                            : () => _service.swap(m.url, prevUrl)),
                    _mini(
                        Icons.keyboard_arrow_down_rounded,
                        nextUrl == null
                            ? null
                            : () => _service.swap(m.url, nextUrl)),
                  ],
                  _mini(Icons.more_horiz_rounded,
                      _busy ? null : () => _quickActions(m)),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// 网格模式卡片（2 列 / 4 列）：图标 + 名称 + 能力一行 + 开关。
  Widget _gridCell(RexModule m, {required bool compact}) {
    final picked = _selected.contains(m.url);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _onCardTap(m),
      onLongPress: _busy || _selecting ? null : () => _quickActions(m),
      child: Container(
        padding: EdgeInsets.all(compact ? 8 : 10),
        decoration: BoxDecoration(
          color: picked ? _accent.withValues(alpha: 0.10) : _tile,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          border: Border.all(
              color: picked ? _accent.withValues(alpha: 0.5) : _line,
              width: picked ? 1.2 : 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: compact ? 24 : 28,
                  height: compact ? 24 : 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _accent
                        .withValues(alpha: m.enabled ? 0.15 : 0.06),
                    borderRadius: BorderRadius.circular(compact ? 7 : 8),
                  ),
                  child: Icon(Icons.extension_rounded,
                      size: compact ? 13 : 15,
                      color: m.enabled
                          ? _accent
                          : _sub.withValues(alpha: 0.7)),
                ),
                const Spacer(),
                if (_selecting)
                  _selectDot(picked)
                else if (RexService.isLocal(m.url))
                  _chip('本地', accent: true),
              ],
            ),
            SizedBox(height: compact ? 6 : 8),
            Text(
              m.title.isEmpty ? 'REX 模块' : m.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: m.enabled ? _fg : _sub,
                fontSize: compact ? AppTheme.fontCaption : AppTheme.fontSubhead,
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    m.streamOnly
                        ? '仅播放'
                        : '${m.listFunctions.length} 个分类',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: _sub.withValues(alpha: 0.85),
                        fontSize: AppTheme.fontCaption),
                  ),
                ),
                IgnorePointer(
                  ignoring: _selecting,
                  child: Opacity(
                    opacity: _selecting ? 0.35 : 1,
                    child: Transform.scale(
                      scale: compact ? 0.62 : 0.7,
                      alignment: Alignment.centerRight,
                      child: Switch(
                        value: m.enabled,
                        activeThumbColor: _accent,
                        onChanged: _busy
                            ? null
                            : (v) => _service.setEnabled(m.url, v),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 多选模式的小圆勾
  Widget _selectDot(bool on) => Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: on ? _accent : Colors.transparent,
          shape: BoxShape.circle,
          border: Border.all(
              color: on ? _accent : _sub.withValues(alpha: 0.5),
              width: 1.4),
        ),
        child: on
            ? const Icon(Icons.check_rounded, size: 13, color: Colors.white)
            : null,
      );

  /// 多选底栏：启用 / 停用 / 清空
  Widget _selectionBar() => Container(
        decoration: BoxDecoration(
          color: _isDark
              ? const Color(0xFF141416).withValues(alpha: 0.96)
              : Colors.white.withValues(alpha: 0.96),
          border: Border(top: BorderSide(color: _line, width: 0.8)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Row(
              children: [
                Text('已选 ${_selected.length}',
                    style: TextStyle(
                        color: _sub, fontSize: AppTheme.fontCaption)),
                const Spacer(),
                TextButton(
                  onPressed: _selected.isEmpty ? null : () => _batchEnable(true),
                  child: const Text('启用'),
                ),
                TextButton(
                  onPressed:
                      _selected.isEmpty ? null : () => _batchEnable(false),
                  child: const Text('停用'),
                ),
                TextButton(
                  onPressed: _selected.isEmpty || _busy ? null : _batchRemove,
                  child: const Text('清空',
                      style: TextStyle(color: Colors.redAccent)),
                ),
              ],
            ),
          ),
        ),
      );

  /// 长按卡片 → **卡片式**快捷操作面板（一排两张，与影视源切换同一套）。
  ///
  /// 用户 2026-10-24：「长按后也不是我要的卡片式一行两列」——
  /// 原来是一列 ListTile，换成 showCardActions 网格卡片。
  void _quickActions(RexModule m) {
    HapticFeedback.mediumImpact();
    showCardActions(
      context,
      title: m.title.isEmpty ? 'REX 模块' : m.title,
      subtitle: RexService.isLocal(m.url)
          ? '本地文件'
          : (Uri.tryParse(m.url)?.host ?? m.url),
      actions: [
        CardAction(
          icon: Icons.drive_file_rename_outline,
          label: '改名',
          onTap: () => _rename(m),
        ),
        CardAction(
          icon: Icons.ios_share_rounded,
          label: '分享',
          onTap: () {
            Clipboard.setData(ClipboardData(text: m.url));
            AppToast.show('地址已复制', m.url);
          },
        ),
        CardAction(
          icon: Icons.sync_rounded,
          label: '刷新',
          onTap: () => _refreshOne(m),
        ),
        CardAction(
          icon: Icons.link_rounded,
          label: '改址',
          onTap: () => _editUrl(m),
        ),
        CardAction(
          icon: Icons.cleaning_services_outlined,
          label: '清缓存',
          onTap: () => _clearCache(m),
        ),
        CardAction(
          icon: Icons.delete_outline_rounded,
          label: '卸载',
          danger: true,
          onTap: () => _confirmRemove(m),
        ),
      ],
    );
  }

  /// 顶栏紧凑图标（小程序那种：无背景、40×40 点击区）。
  ///
  /// 默认的 IconButton 是 48×48，管理页顶栏放 4 个会把标题挤掉
  /// （85 个模块的用户要 多选/视图/市场/刷新 四个入口）。
  Widget _topIcon(IconData icon, String tip, VoidCallback? onTap,
      {bool busy = false}) {
    return IconButton(
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      icon: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(icon, size: 21, color: _fg),
      onPressed: onTap,
    );
  }

  Widget _chip(String text, {bool accent = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(
          color: accent
              ? _accent.withValues(alpha: 0.15)
              : (_isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.04)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text,
            style: TextStyle(
              color: accent ? _accent : _sub,
              fontSize: 10,
              fontWeight: accent ? FontWeight.w600 : FontWeight.w400,
            )),
      );

  Widget _mini(IconData icon, VoidCallback? onTap) => IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        // 34 起：30 的点击区在拇指下容易点空（iOS 建议 ≥44，但这里并排
        // 两个箭头 + 更多，34 是能兼顾密度与准确度的折中）
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        icon: Icon(icon,
            size: 20,
            color: onTap == null ? _sub.withValues(alpha: 0.3) : _sub),
        onPressed: onTap,
      );

  Future<void> _openMarket() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'rex:market'),
      builder: (_) => const RexMarketPage(),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _refreshOne(RexModule m) async {
    setState(() => _busy = true);
    try {
      await _service.refreshModule(m);
      if (mounted) AppToast.show('已刷新「${m.title}」', '');
    } catch (e) {
      if (mounted) AppToast.show('刷新失败：$e', '');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshAll() async {
    if (_service.modules.isEmpty) return;
    setState(() => _busy = true);
    try {
      final errors = await _service.refreshAll();
      if (!mounted) return;
      AppToast.show(
        errors.isEmpty
            ? '全部刷新完成（${_service.modules.length} 个模块）'
            : '${_service.modules.length - errors.length} 个成功，'
                '${errors.length} 个失败：${errors.first}',
        '',
      );
    } catch (e) {
      // 没有 catch 时异常会逃出按钮回调，变成未捕获异步异常
      if (mounted) AppToast.show('刷新失败：$e', '');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearCache(RexModule m) async {
    await _service.clearCache(m);
    if (mounted) AppToast.show('已清空「${m.title}」的编译缓存', '');
  }

  /// 重命名模块：只改显示名（首页源切换、管理页都用这个名字），
  /// 地址和脚本不动，重新导入也不会被脚本里的 title 覆盖
  Future<void> _rename(RexModule m) async {
    final ctrl = TextEditingController(text: m.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名模块'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(labelText: '显示名称'),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || name.isEmpty || !mounted) return;
    try {
      await _service.rename(m.url, name);
      if (!mounted) return;
      setState(() {});
      AppToast.show('已重命名', name);
    } catch (e) {
      if (mounted) AppToast.show('重命名失败：$e', '');
    }
  }

  Future<void> _editUrl(RexModule m) async {
    final ctrl = TextEditingController(text: m.url);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改模块地址'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(labelText: '模块 raw 地址'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    final newUrl = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || newUrl.isEmpty || newUrl == m.url || !mounted) return;
    setState(() => _busy = true);
    try {
      await _service.updateUrl(m.url, newUrl);
      if (mounted) AppToast.show('地址已更新', '');
    } catch (e) {
      if (mounted) AppToast.show('更新失败：$e', '');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmRemove(RexModule m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除模块？'),
        content: Text('「${m.title}」会从订阅列表移除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('移除')),
        ],
      ),
    );
    if (ok == true) await _service.remove(m.url);
  }
}
