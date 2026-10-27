import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/prefs_mirror.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/card_action_sheet.dart';
import 'package:tvbox/widgets/home_search_bar.dart';
import 'package:tvbox/miniapp/models/mini_app.dart';
import 'package:tvbox/miniapp/services/builtin_mini_apps.dart';
import 'package:tvbox/miniapp/services/market_subscription_store.dart';
import 'package:tvbox/miniapp/services/mini_app_service.dart';
import 'package:tvbox/miniapp/pages/mini_app_detail_page.dart';
import 'package:tvbox/miniapp/pages/mini_app_maiyou_page.dart';
import 'package:tvbox/miniapp/pages/mini_app_market_page.dart';
import 'package:tvbox/miniapp/pages/mini_app_web_page.dart';

/// 「程序」tab 主页：**直接显示已安装**的小程序（不再有「已安装 / 市场」双 Tab）。
///
/// 市场改为**订阅制**独立页面：一个订阅 = 一个市场，可添加多个，
/// 入口在顶栏的商店按钮 / 「添加程序」弹层（见 [MiniAppMarketPage]）。
class MiniAppListPage extends StatefulWidget {
  const MiniAppListPage({super.key});

  @override
  State<MiniAppListPage> createState() => _MiniAppListPageState();
}

/// 程序列表排序方式
enum _AppSort {
  custom('自定义'),
  name('名称'),
  newest('最近添加');

  const _AppSort(this.label);
  final String label;
}

/// 「已安装」的视图：一行几个（或列表）
enum _AppViewMode {
  two('一行两个', 2),
  three('一行三个', 3),
  four('一行四个', 4),
  list('列表', 0);

  const _AppViewMode(this.label, this.columns);

  final String label;

  /// 0 = 列表模式（不支持多列）
  final int columns;

  bool get isList => columns == 0;
}

/// 「已安装」网格的**行高**。
///
/// 用户 2026-10-14：「卡片高度太高了，只要现在的三分之二」——
/// 原来 4 列时卡宽 ≈82.5pt、`childAspectRatio: 0.62` ⇒ 高 ≈133pt，
/// 取 2/3 ≈ **88pt**（对一行两个/三个也统一用这个高度，见 `_buildBody` 的说明）。
const double _kCardHeight = 88;

class _MiniAppListPageState extends State<MiniAppListPage> {
  MiniAppService get service => MiniAppService.instance;
  bool _busy = false;

  /// 「已安装」的视图（一行两个 / 三个 / 四个 / 列表）—— 用户 2026-10-14。
  /// 存 prefs，重启保持。
  static const String _kViewMode = 'miniapp_view_mode';
  _AppViewMode _viewMode = _AppViewMode.four;

  /// 排序（自定义 = 按存储顺序，可拖动调整）
  _AppSort _sort = _AppSort.custom;

  /// 当前分组 tab：null = 全部
  String? _groupFilter;

  /// 顶栏搜索（输入框由 `HomeSearchBar` 自己持有展开态，这里只跟着它过滤）
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    service.ensureLoaded();
    _restoreViewMode();
    // 监听 controller 而不是用 TextField.onChanged：
    // 点「×」清空、收起时清空都是**程序化** clear()，不会触发 onChanged，
    // 只挂 onChanged 会让 `_query` 停在旧值（列表显示的还是过滤后的结果）。
    _searchCtrl.addListener(() {
      if (!mounted) return;
      setState(() => _query = _searchCtrl.text);
    });
  }

  /// 读回上次选的视图（缺省/越界都用「一行四个」）。
  Future<void> _restoreViewMode() async {
    try {
      final p = await SharedPreferences.getInstance();
      final i = p.getInt(_kViewMode) ?? _AppViewMode.four.index;
      if (i >= 0 && i < _AppViewMode.values.length && mounted) {
        setState(() => _viewMode = _AppViewMode.values[i]);
      }
    } catch (_) {
      // 读失败就用默认视图，不影响使用
    }
  }

  Future<void> _setViewMode(_AppViewMode m) async {
    setState(() => _viewMode = m);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kViewMode, m.index);
    } catch (_) {
      // 写失败不抛：本次会话仍生效
    }
    PrefsMirror.snapshotSoon();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 过滤 + 排序后的程序（内置那几张卡不参与）
  List<MiniApp> _visibleApps() {
    var list = service.apps.toList();
    if (_groupFilter != null) {
      list = list.where((a) => a.group == _groupFilter).toList();
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where(
            (a) =>
                a.name.toLowerCase().contains(q) ||
                a.source.toLowerCase().contains(q),
          )
          .toList();
    }
    switch (_sort) {
      case _AppSort.custom:
        break;
      case _AppSort.name:
        list.sort((a, b) => a.name.compareTo(b.name));
      case _AppSort.newest:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── 顶栏：标题 / 搜索 / 市场 / 设置 / 添加 ─────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spacingMD,
                AppTheme.spacingMD,
                AppTheme.spacingMD,
                0,
              ),
              child: Row(
                children: [
                  Text(
                    '程序',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontTitle3,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  HomeSearchBar(
                    hintText: '搜索程序',
                    controller: _searchCtrl,
                    // 已安装列表是本地过滤，不需要"进搜索页"，空提交即收起
                    onSubmitted: (_) {},
                    onTapEmpty: () {},
                  ),
                  const SizedBox(width: 4),
                  _topIcon(Icons.storefront_rounded, '程序市场', _openMarket),
                  _topIcon(Icons.tune_rounded, '设置', _showSettingsSheet),
                  _topIcon(Icons.add_circle_outline, '添加程序', _showAddSheet),
                ],
              ),
            ),
            const SizedBox(height: AppTheme.spacingSM),

            // ── 分组 tab：全部 / 自定义分组 / ＋新建分组 ───────────
            Obx(() {
              final tabs = <String>['全部', ...service.groups];
              return SizedBox(
                height: 42,
                child: Row(
                  children: [
                    Expanded(
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(left: 16, right: 8),
                        itemCount: tabs.length + 1,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, i) {
                          if (i == tabs.length) {
                            return _groupTab(
                              label: '＋ 新建分组',
                              selected: false,
                              onTap: _createGroupDialog,
                            );
                          }
                          final name = tabs[i];
                          final selected = name == '全部'
                              ? _groupFilter == null
                              : _groupFilter == name;
                          return _groupTab(
                            label: name,
                            selected: selected,
                            onTap: () => setState(
                              () => _groupFilter = name == '全部' ? null : name,
                            ),
                          );
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _viewModeButton(),
                    ),
                  ],
                ),
              );
            }),

            // ── 已安装内容（没有「市场 Tab」了）──────────────────
            Expanded(child: Obx(() => _buildBody())),
          ],
        ),
      ),
    );
  }

  void _openMarket() {
    Get.to(() => const MiniAppMarketPage());
  }

  /// 顶栏的视图切换（一行两个 / 三个 / 四个 / 列表）
  Widget _viewModeButton() {
    return PopupMenuButton<_AppViewMode>(
      tooltip: '切换视图',
      initialValue: _viewMode,
      color: AppTheme.backgroundSecondary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      onSelected: _setViewMode,
      itemBuilder: (_) => [
        for (final m in _AppViewMode.values)
          PopupMenuItem(
            value: m,
            child: Row(
              children: [
                Icon(_viewModeIcon(m), size: 17),
                const SizedBox(width: 8),
                Text(m.label, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _viewModeIcon(_viewMode),
              size: 17,
              color: AppTheme.textSecondary,
            ),
            const SizedBox(width: 3),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 16,
              color: AppTheme.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  IconData _viewModeIcon(_AppViewMode m) => switch (m) {
    _AppViewMode.two => Icons.grid_view_rounded,
    _AppViewMode.three => Icons.apps_rounded,
    _AppViewMode.four => Icons.grid_on_rounded,
    _AppViewMode.list => Icons.view_list_rounded,
  };

  // ── 顶栏小图标 ────────────────────────────────────────────────
  Widget _topIcon(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 21, color: AppTheme.textPrimary),
        ),
      ),
    );
  }

  // ── 主体：已装程序（网格/列表、可搜索/排序）────────
  Widget _buildBody() {
    final apps = _visibleApps();
    // 只有「自定义顺序 + 无搜索/无分组过滤」时才能直接拖动排序
    final canDrag =
        _sort == _AppSort.custom &&
        _query.trim().isEmpty &&
        _groupFilter == null;
    if (apps.isEmpty) {
      final noQuery = _query.trim().isEmpty;
      final inGroup = _groupFilter != null;
      final empty = noQuery && !inGroup;
      final title = noQuery ? (inGroup ? '该分组还没有程序' : '还没有程序') : '没有匹配的程序';
      final subtitle = noQuery
          ? (inGroup ? '长按程序 → 移动到分组' : '导入 TVBox 配置，或从小程序市场安装')
          : '换个关键词再试试';
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppTheme.accentColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  noQuery
                      ? (inGroup
                            ? Icons.folder_open_rounded
                            : Icons.widgets_outlined)
                      : Icons.search_off_rounded,
                  size: 30,
                  color: AppTheme.accentOnSurface,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontFootnote,
                  height: 1.5,
                ),
              ),
              if (empty) ...[
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: _showAddSheet,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('导入程序'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.accentColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 11,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: _openMarket,
                      icon: const Icon(Icons.storefront_rounded, size: 18),
                      label: const Text('浏览市场'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 11,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (_viewMode.isList) {
      // 列表模式：一行一个（长按条目直接拖动排序，菜单在 ⋮）
      return ListView(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingMD,
          // 与「全部」分组 tab 拉开距离（用户 2026-10-18）
          12,
          AppTheme.spacingMD,
          110,
        ),
        children: [
          for (final a in apps)
            _draggableApp(
              a,
              canDrag,
              _listRow(
                title: a.name,
                subtitle: _appTag(a),
                onTap: () => _openApp(a),
                onMenu: () => _showAppMenu(a),
              ),
            ),
        ],
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spacingMD,
        // 与「全部」分组 tab 拉开距离（用户 2026-10-18）
        12,
        AppTheme.spacingMD,
        110,
      ),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        // 用户 2026-10-14：视图可选**一行两个 / 三个 / 四个**（存 prefs）
        crossAxisCount: _viewMode.columns,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        // ── 🔴 用**固定行高**（mainAxisExtent）而不是 childAspectRatio ──
        //
        // 用户 2026-10-14：「卡片高度太高了，只要现在（133pt）的三分之二」
        //   ⇒ 2/3 ≈ 88pt。写死 aspectRatio 的话，切到"一行两个"时卡宽翻倍、
        //     高度也跟着翻到 ~190pt（又变回"太高"）✗ —— 高度该由**这一条**
        //     决定，而不是由列数决定 ✓。
        // 卡片本身是 Stack（渐变底 + 压住的首字 + 底部名称），高度变了不会
        // 溢出（内容贴着底/居中布局）✓。
        mainAxisExtent: _kCardHeight,
      ),
      itemCount: apps.length,
      itemBuilder: (context, index) {
        final app = apps[index];
        return _draggableApp(
          app,
          canDrag,
          _MiniAppCard(
            app: app,
            // 稳定随机色：按 id（不是 name —— 同名不同来源要能区分）取色
            tint: _tintFor(app.id.isNotEmpty ? app.id : app.name),
            onTap: () => _openApp(app),
            onMenu: () => _showAppMenu(app),
          ),
        );
      },
    );
  }

  /// 长按条目直接拖动排序（列表 / 一行多列通用）；菜单统一在 ⋮ 按钮。
  Widget _draggableApp(MiniApp app, bool canDrag, Widget child) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != app.id,
      onAcceptWithDetails: (d) => _moveApp(d.data, app.id),
      builder: (_, candidate, __) {
        final tile = candidate.isEmpty
            ? child
            : DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: AppTheme.accentColor.withValues(alpha: 0.8),
                    width: 2,
                  ),
                ),
                child: child,
              );
        if (!canDrag) return tile;
        return LongPressDraggable<String>(
          data: app.id,
          feedback: _appDragFeedback(app),
          childWhenDragging: Opacity(opacity: 0.35, child: tile),
          child: tile,
        );
      },
    );
  }

  Widget _appDragFeedback(MiniApp app) => Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _tintFor(app.id.isNotEmpty ? app.id : app.name),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Text(
            app.name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );

  /// 程序副标题：影视 N / 频道 N / 在线站点…
  String _appTag(MiniApp app) {
    if (app.isWebApp) {
      final base = app.source.startsWith('http') ? '在线站点' : '本地网页程序';
      // 随 App 打包的内置程序：标出来，用户才知道删了还能装回来
      return isBuiltinAppId(app.id) ? '内置 · $base' : base;
    }
    if (app.isMaiyou) return '直播订阅 · 麦优';
    final parsed = app.parsed;
    final videoCount = parsed.cmsSites.length + parsed.spiderSites.length;
    final liveCount = parsed.liveGroups.fold<int>(
      0,
      (sum, g) => sum + g.channels.length,
    );
    return [
      if (videoCount > 0) '影视 $videoCount',
      if (liveCount > 0) '频道 $liveCount',
      if (parsed.hasInlineSpider) '内嵌脚本',
    ].join(' · ');
  }

  /// 打开程序（按类型分派：网页型 / 麦优订阅 / TVBox 配置）
  void _openApp(MiniApp app) {
    if (app.isWebApp) {
      final src = app.source;
      final isRemote = src.startsWith('http');
      Get.to(
        () => MiniAppWebPage(
          remoteUrl: isRemote ? src : null,
          localRoot: isRemote ? null : src,
          manifestJson: app.rawJson,
        ),
      );
      return;
    }
    if (app.isMaiyou) {
      Get.to(() => MiniAppMaiyouPage(appId: app.id));
      return;
    }
    Get.to(() => MiniAppDetailPage(appId: app.id));
  }

  Widget _listRow({
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    VoidCallback? onMenu,
  }) {
    // 行式卡片对齐参考图与「市场」Tab：**彩色首字图标 + 标题 + 副标题 + 右侧箭头**
    final tint = _tintFor(title);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(11),
                      color: tint,
                    ),
                    child: Text(
                      title.isNotEmpty ? title.characters.first : '程',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
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
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppTheme.textTertiary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (onMenu != null)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onMenu,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4, right: 2),
                        child: Icon(
                          Icons.more_horiz_rounded,
                          size: 18,
                          color: AppTheme.textTertiary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const _tints = <Color>[
    Color(0xFF4FC3F7),
    Color(0xFF9575CD),
    Color(0xFF66BB6A),
    Color(0xFFFFA726),
    Color(0xFFEF5350),
    Color(0xFF26A69A),
  ];

  /// 按名称稳定取色（不用 String.hashCode：不保证跨进程稳定）
  Color _tintFor(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _tints[h % _tints.length];
  }

  // ── 设置弹层：排序 / 视图 / 调整顺序（行式排版，对齐参考图 2）──────
  //
  // 参考图 2 是「标题粗体 + 灰色说明小字 + 右侧控件」一行的排法，这里照抄这个
  // 信息结构；⚠️ 但**不照抄它那些设置项**（本地服务起始端口 / 最多同时后台运行 /
  // 在线网站广告过滤 / 混合合成模式 / 局域网共享）—— 那些能力本项目没有，
  // 放上去就是假开关。这里只列**真实存在**的三项，且改完即时生效，
  // 所以也不需要参考图底部那个「保存」按钮。
  void _showSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部拖动把手（与「添加程序」弹层保持同一套视觉语言）
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(top: 10, bottom: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.textSecondary.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 20, 4),
                  child: Text(
                    '程序设置',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _settingRow(
                  title: '排序',
                  desc: '已安装列表按什么顺序排列',
                  control: Wrap(
                    spacing: 8,
                    children: [
                      for (final s in _AppSort.values)
                        _sheetChip(s.label, _sort == s, () {
                          setState(() => _sort = s);
                          setSheet(() {});
                        }),
                    ],
                  ),
                ),
                _settingDivider(),
                _settingRow(
                  title: '视图',
                  desc: '一行几个，或列表（列表信息更全）',
                  // 四个视图选项在手机宽度下放不进右侧 ⇒ 改为**标题下另起一行**，
                  // 否则左侧说明会被挤成竖排小字（截图里的排版问题）。
                  stacked: true,
                  control: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      // 用户 2026-10-14：从「网格 / 列表」两档扩成
                      // **一行两个 / 一行三个 / 一行四个 / 列表** ✓（存 prefs）
                      for (final m in _AppViewMode.values)
                        _sheetChip(m.label, _viewMode == m, () {
                          _setViewMode(m);
                          setSheet(() {});
                        }),
                    ],
                  ),
                ),
                if (service.apps.length > 1) ...[
                  _settingDivider(),
                  _settingRow(
                    title: '调整顺序',
                    desc: '长按拖动把手，重排已安装程序',
                    control: Icon(
                      Icons.chevron_right_rounded,
                      color: AppTheme.textTertiary,
                    ),
                    onTap: () {
                      Get.back();
                      _showReorderSheet();
                    },
                  ),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 设置行（参考图 2 的排法）：左「标题 + 灰色说明」，右侧控件。
  ///
  /// [stacked] = true 时控件换到标题下方独占一行（选项多、右侧放不下时用），
  /// 避免左侧说明被挤成一条竖排小字。
  Widget _settingRow({
    required String title,
    required String desc,
    required Widget control,
    bool stacked = false,
    VoidCallback? onTap,
  }) {
    final labels = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontSubhead + 1,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          desc,
          style: TextStyle(
            color: AppTheme.textTertiary,
            fontSize: AppTheme.fontCaption,
            height: 1.3,
          ),
        ),
      ],
    );
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: LayoutBuilder(
        builder: (context, box) {
          // 手机窄屏（内容宽 <300）连「排序」也改成上下排，防止右侧控件
          // 把左侧说明挤成竖排；平板/大屏仍保持左文右控件。
          final useStacked = stacked || box.maxWidth < 300;
          if (useStacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                labels,
                const SizedBox(height: 10),
                control,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: labels),
              const SizedBox(width: 10),
              control,
            ],
          );
        },
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }

  Widget _settingDivider() => Divider(
    height: 1,
    thickness: 0.5,
    indent: 20,
    endIndent: 20,
    color: AppTheme.borderLight,
  );

  Widget _sheetChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppTheme.accentColor : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderLight, width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : AppTheme.textSecondary,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// 一个分组 tab（「全部」/自定义分组/新建分组）
  Widget _groupTab({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppTheme.accentColor : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? Colors.transparent : AppTheme.borderLight,
            width: 0.6,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : AppTheme.textSecondary,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// 新建分组
  Future<void> _createGroupDialog() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: Text('新建分组', style: TextStyle(color: AppTheme.textPrimary)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: AppTheme.textPrimary),
          decoration: const InputDecoration(hintText: '分组名称'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    final n = (name ?? '').trim();
    if (n.isEmpty) return;
    final ok = await service.createGroup(n);
    if (!mounted) return;
    if (!ok) {
      AppToast.message('分组「$n」已存在');
      return;
    }
    setState(() => _groupFilter = n);
  }

  /// 选择某个程序的分组
  void _showGroupPicker(MiniApp app) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '移动到分组',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                app.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _sheetChip('未分组', app.group.isEmpty, () async {
                        Navigator.pop(ctx);
                        await service.setGroup(app, '');
                        if (mounted) setState(() {});
                      }),
                      for (final g in service.groups)
                        _sheetChip(g, app.group == g, () async {
                          Navigator.pop(ctx);
                          await service.setGroup(app, g);
                          if (mounted) setState(() {});
                        }),
                      _sheetChip('＋ 新建分组', false, () async {
                        Navigator.pop(ctx);
                        await _createGroupForApp(app);
                      }),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  /// 给某个程序新建分组并直接移进去
  Future<void> _createGroupForApp(MiniApp app) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: Text('新建分组', style: TextStyle(color: AppTheme.textPrimary)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: AppTheme.textPrimary),
          decoration: const InputDecoration(hintText: '分组名称'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    final n = (name ?? '').trim();
    if (n.isEmpty) return;
    await service.createGroup(n);
    await service.setGroup(app, n);
    if (mounted) setState(() {});
  }

  // ── 长按菜单：分享 / 分组 / 排序 / 删除（卡片式，一行 2 个）──────
  void _showAppMenu(MiniApp app) {
    showCardActions(
      context,
      title: app.name,
      subtitle: _appTag(app),
      actions: [
        CardAction(
          icon: Icons.ios_share_rounded,
          label: '分享',
          onTap: () => _shareApp(app),
        ),
        CardAction(
          icon: Icons.folder_outlined,
          label: '分组',
          onTap: () => _showGroupPicker(app),
        ),
        CardAction(
          icon: Icons.reorder_rounded,
          label: '排序',
          onTap: _showReorderSheet,
        ),
        CardAction(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          danger: true,
          onTap: () => _confirmRemove(app),
        ),
      ],
    );
  }

  /// 长按拖到另一张卡片上 → 重排（自定义顺序落盘）
  Future<void> _moveApp(String fromId, String toId) async {
    if (fromId == toId) return;
    final apps = service.apps;
    final from = apps.indexWhere((a) => a.id == fromId);
    final to = apps.indexWhere((a) => a.id == toId);
    if (from < 0 || to < 0) return;
    await service.reorder(from, from < to ? to + 1 : to);
    if (mounted) setState(() {});
  }

  /// 分享：复制程序链接/配置到剪贴板（应用内没有分享 SDK，统一走复制）
  Future<void> _shareApp(MiniApp app) async {
    final text = app.source.trim().isNotEmpty ? app.source.trim() : app.rawJson;
    await Clipboard.setData(ClipboardData(text: text));
    AppToast.message('已复制程序链接');
  }

  /// 拖动排序（列表顺序即自定义顺序，落盘）
  void _showReorderSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.6,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Text(
                      '调整顺序',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '拖动右侧把手',
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Obx(
                  () => ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    itemCount: service.apps.length,
                    onReorderItem: (o, n) =>
                        service.reorder(o, n, alreadyAdjusted: true),
                    itemBuilder: (c, i) {
                      final a = service.apps[i];
                      return ListTile(
                        key: ValueKey(a.id),
                        title: Text(
                          a.name,
                          style: TextStyle(color: AppTheme.textPrimary),
                        ),
                        subtitle: Text(
                          _appTag(a),
                          style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: 11,
                          ),
                        ),
                        trailing: Icon(
                          Icons.drag_handle_rounded,
                          color: AppTheme.textTertiary,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmRemove(MiniApp app) {
    Get.dialog(
      AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          '删除程序',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 16),
        ),
        content: Text(
          '删除「${app.name}」？其影视源会从视频源列表移除。',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Get.back();
              await service.remove(app);
              AppToast.message('已删除');
            },
            child: Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  // ── 添加 ──────────────────────────────────────────────────────
  void _showAddSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.textSecondary.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                '添加程序',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontTitle3,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppTheme.spacingLG),
              _AddTile(
                icon: Icons.link,
                title: '网络导入',
                subtitle: 'TVBox 配置地址，或小程序市场链接',
                onTap: () {
                  Get.back();
                  _importFromUrlDialog();
                },
              ),
              const SizedBox(height: AppTheme.spacingMD),
              // 小程序市场：订阅制（一个订阅 = 一个市场），在独立市场页里安装
              _AddTile(
                icon: Icons.storefront_outlined,
                title: '小程序市场',
                subtitle: '订阅市场（可多个），浏览并安装里面的程序',
                onTap: () {
                  Get.back();
                  _openMarket();
                },
              ),
              const SizedBox(height: AppTheme.spacingMD),
              _AddTile(
                icon: Icons.content_paste,
                title: '粘贴 JSON',
                subtitle: '手动粘贴配置内容',
                onTap: () {
                  Get.back();
                  _importFromTextDialog();
                },
              ),
              const SizedBox(height: AppTheme.spacingMD),
              _AddTile(
                icon: Icons.folder_open,
                title: '本地文件',
                subtitle: '选择 .json 配置文件导入',
                onTap: () {
                  Get.back();
                  _importFromFile();
                },
              ),
              const SizedBox(height: AppTheme.spacingMD),
              _AddTile(
                icon: Icons.live_tv,
                title: '麦优直播订阅',
                subtitle: '输入麦优分类接口地址（json.txt）',
                onTap: () {
                  Get.back();
                  _importMaiyouDialog();
                },
              ),
              // 内置程序：随 App 打包、正常情况首次启动就已经装好了；
              // 这个入口用于「手滑删了想装回来」或「内置包更新后手动重装」。
              const SizedBox(height: AppTheme.spacingMD),
              _AddTile(
                icon: Icons.inventory_2_outlined,
                title: '内置程序',
                subtitle: '随 App 打包的程序（删了可在这里装回）',
                onTap: () {
                  Get.back();
                  _showBuiltinSheet();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 内置程序（assets/miniapps/*.zip）─────────────────────────
  void _showBuiltinSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.textSecondary.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                '内置程序',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontTitle3,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '这些程序随 App 一起打包，不需要联网下载',
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
              ),
              const SizedBox(height: AppTheme.spacingLG),
              // 安装状态跟着 apps 变，所以用 Obx 包一层
              Obx(() {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final b in kBuiltinMiniApps) ...[
                      _builtinRow(b),
                      if (b != kBuiltinMiniApps.last)
                        const SizedBox(height: AppTheme.spacingMD),
                    ],
                  ],
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _builtinRow(BuiltinMiniApp b) {
    final installed = service.isInstalled(b.appId);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              color: _tintFor(b.appId),
            ),
            child: Text(
              b.name.isNotEmpty ? b.name.characters.first : '内',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  b.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  installed ? '已安装 · v${b.version}' : b.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => _installBuiltin(b, force: installed),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.accentColor,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 34),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              installed ? '重新安装' : '安装',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _installBuiltin(BuiltinMiniApp b, {bool force = false}) async {
    AppToast.message(force ? '正在重装 ${b.name}…' : '正在安装 ${b.name}…');
    final r = await service.installBuiltin(b.appId, force: force);
    if (!mounted) return;
    if (r.ok) {
      AppToast.message('${b.name} 已就绪');
    } else {
      AppToast.message(r.error ?? '安装失败');
    }
  }

  Future<void> _importMaiyouDialog() async {
    final controller = TextEditingController();
    final ok = await Get.dialog<bool>(
      AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          '添加麦优直播订阅',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              style: TextStyle(color: AppTheme.textPrimary),
              decoration: InputDecoration(
                hintText: '如 http://api.maiyoux.com:81/mf/json.txt',
                hintStyle: TextStyle(color: AppTheme.textSecondary),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppTheme.borderMedium),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '订阅后以独立应用打开：分类浏览 → 频道播放',
              style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final url = controller.text.trim();
    if (url.isEmpty) {
      AppToast.message('订阅地址不能为空');
      return;
    }
    await _run(() => MiniAppService.instance.importMaiyou(url));
  }

  Future<void> _importFromUrlDialog() async {
    final controller = TextEditingController();
    final ok = await Get.dialog<bool>(
      AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          '网络导入',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 16),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          style: TextStyle(color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: 'https://…/tvbox.json',
            hintStyle: TextStyle(color: AppTheme.textSecondary),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppTheme.borderMedium),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final url = controller.text.trim();
    if (url.isEmpty) {
      AppToast.message('地址不能为空');
      return;
    }
    await _importByUrlSmart(url);
  }

  Future<void> _importFromTextDialog() async {
    final controller = TextEditingController();
    final ok = await Get.dialog<bool>(
      AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          '粘贴 JSON',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 16),
        ),
        content: SizedBox(
          height: 220,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: null,
            expands: true,
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              hintText: '{ "name": "…", "sites": […], "lives": […] }',
              hintStyle: TextStyle(color: AppTheme.textSecondary),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppTheme.borderMedium),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => service.importFromText(controller.text));
  }

  /// 网络导入 / 小程序市场：一次下载判断——
  /// 内容是市场清单 `{"apps":[…]}` → 打开市场页（列出 + 安装按钮）；
  /// 否则按普通 TVBox 配置导入。
  Future<void> _importByUrlSmart(String url) async {
    if (_busy) return;
    _busy = true;
    try {
      final r = await service.importUrlSmart(url);
      final market = r.market;
      if (!mounted) return;
      if (market != null) {
        // 市场清单 → 记为一条订阅，然后打开市场页（可切换 / 管理订阅）
        await MarketSubscriptionStore.instance.add(name: '', url: url);
        if (!mounted) return;
        _openMarket();
      } else {
        AppToast.message(r.ok ? '导入成功' : (r.error ?? '导入失败'));
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        // zip = 小程序包（解包安装为网页型程序）；json/txt = TVBox 配置
        allowedExtensions: const ['json', 'txt', 'zip'],
      );
      if (result.isEmpty) return;
      final f = result.first;
      final path = f.path;
      if (path == null) {
        AppToast.message('读不出这个文件（没有本地路径）');
        return;
      }
      if (path.toLowerCase().endsWith('.zip')) {
        await _run(() => service.installFromZipFile(path));
        return;
      }
      await _run(() => service.importFromFile(path));
    } catch (e) {
      AppToast.message('选择文件失败: $e');
    }
  }

  Future<void> _run(Future<({bool ok, String? error})> Function() task) async {
    if (_busy) return;
    _busy = true;
    try {
      final result = await task();
      if (result.ok) {
        AppToast.message('导入成功');
      } else {
        AppToast.message(result.error ?? '导入失败');
      }
    } finally {
      _busy = false;
    }
  }
}

// ── 卡片 ────────────────────────────────────────────────────────
//
// 2026-10-14 改版（用户要求）：
//   · 去掉卡面上的「本地网页程序 / 在线站点 / 影视 N」副标题 —— 卡面只留封面；
//   · 名称位置：先按"移到卡片外面居中"做过一版，用户随后改主意 ——
//     最终要**压在封面底部、居中**（配一层底部压暗渐变保证白字可读）；
//   · 封面卡改成**每个程序一个稳定随机色**（按 id 哈希取色）——
//     同一个程序每次进来同色，不会每帧乱跳；不同程序之间颜色错开。
class _MiniAppCard extends StatelessWidget {
  final MiniApp app;

  /// 封面底色（由外层按 app.id 稳定取色后传入）
  final Color tint;
  final VoidCallback onTap;

  /// 菜单入口（⋮）。长按已经是拖动排序，菜单不能再用长按。
  final VoidCallback? onMenu;

  const _MiniAppCard({
    required this.app,
    required this.tint,
    required this.onTap,
    this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final initial = app.name.isNotEmpty ? app.name.characters.first : '程';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        // antiAlias：底部那层压暗渐变要跟着圆角裁，否则四角会露出方角
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              tint.withValues(alpha: 0.92),
              tint.withValues(alpha: 0.60),
            ],
          ),
          // 用同色系投影代替玻璃描边：彩色卡配灰色描边会显脏
          boxShadow: [
            BoxShadow(
              color: tint.withValues(alpha: 0.28),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 右上角柔光：让纯渐变卡片有一点层次
            Positioned(
              top: -26,
              right: -26,
              child: Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.10),
                ),
              ),
            ),
            // 类型角标：网页 / 直播订阅 / TVBox
            Positioned(
              left: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  app.isWebApp
                      ? (app.source.startsWith('http')
                            ? Icons.public_rounded
                            : Icons.code_rounded)
                      : app.isMaiyou
                      ? Icons.live_tv_rounded
                      : Icons.widgets_rounded,
                  size: 12,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
            ),
            // 菜单按钮（右上角）：轻量图标 + 投影，压深色底也能看清
            if (onMenu != null)
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onMenu,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.more_horiz_rounded,
                      size: 18,
                      color: Colors.white.withValues(alpha: 0.9),
                      shadows: [
                        Shadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // 首字：略往上挪，给底部名称留出位置，别挤在一起
            Align(
              alignment: const Alignment(0, -0.18),
              child: Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  shadows: [Shadow(blurRadius: 10, color: Colors.black26)],
                ),
              ),
            ),
            // 底部压暗：白字直接压在彩色底上会糊，这层保证可读
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 46,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.45),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 名称：**压在封面底部、居中**（用户 2026-10-14）
            Positioned(
              left: 6,
              right: 6,
              bottom: 6,
              child: Text(
                app.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _AddTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        child: Row(
          children: [
            Icon(icon, size: 22, color: AppTheme.textPrimary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: AppTheme.textSecondary),
          ],
        ),
      ),
    );
  }
}
