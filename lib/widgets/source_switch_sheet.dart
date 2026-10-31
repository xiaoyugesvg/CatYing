import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:get/get.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/models/subscription.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/local_js_sources.dart';
import 'package:tvbox/services/local_python_sources.dart';
import 'package:tvbox/services/xbpq/xbpq_service.dart';
import 'package:tvbox/services/source_kind.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/card_action_sheet.dart';
import 'package:tvbox/widgets/source_kind_badge.dart';

/// 源切换面板（2026-10-02 二次重构：**三分之一屏**）
///
/// 用户明确要求"源切换改成三分之一屏页"：
/// - 不再全屏路由页，改为底部弹窗，高度 ≈ 屏高 1/3
/// - 顶部 SafeArea 避让状态栏；标题「搜索源」+ 搜索框（小胶囊）+ 单列/双排切换
/// - 键盘弹起时：1/3 高面板 + kbSheet 抬高仍不会顶出屏幕（0.33 + 键盘 < 1），
///   顶部不动、列表压缩但仍可滚动（Expanded + AlwaysScrollable）
/// - 点击源 → setHomeSource + 关闭弹窗，由调用方刷新首页
class SourceSwitchSheet extends StatefulWidget {
  /// 选中源并关闭弹窗后回调（用于刷新首页内容）
  final VoidCallback? onSelected;

  const SourceSwitchSheet({super.key, this.onSelected});

  /// 便捷弹出：返回 true 表示用户确实切换了源
  static Future<bool> show(BuildContext context) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => kbSheet(const SourceSwitchSheet()),
    );
    return changed == true;
  }

  @override
  State<SourceSwitchSheet> createState() => _SourceSwitchSheetState();
}

/// 源面板的分类。
///
/// 2026-10-29 由「本地 PY / 订阅」两档扩成四档：订阅线路 + 三族本地源
/// （本地爬虫 / 本地JS / XBPQ）。三族本地源**只在导入过**时才出现。
///
/// 2026-10-31：本地JS 曾经并进 [subscription] 分组试过一版，**已回退** ——
/// 用户：「本地JS 就不合并订阅行不」。合并本来只是展示层的排序，
/// 与"切源不串"没有关系（那是 `SpiderService._syncSlotFromEngine` 解决的），
/// 所以独立成档更清楚。
enum _SrcGroup {
  subscription('订阅'),
  localPy('本地PY'),
  localJs('本地JS'),
  xbpq('XBPQ');

  const _SrcGroup(this.label);

  /// 胶囊上的名字（订阅那个会换成订阅名，见 build 里的 subName）
  final String label;
}

class _SourceSwitchSheetState extends State<SourceSwitchSheet> {
  final TextEditingController _searchController = TextEditingController();

  /// 源列表滚动控制器（「定位」按钮要滚到当前选中的源）
  final ScrollController _scrollController = ScrollController();
  String _keyword = '';

  /// false=单列列表 / true=双排网格（默认双排，与参考截图一致）
  bool _gridMode = true;

  /// 是否正在看「失效线路」分类（顶部「失效 N」切换）
  bool _showInvalid = false;

  /// 当前分类。
  ///
  /// 2026-10-29 之前只有「本地 PY / 订阅」两档（`int _tab`）。用户要求
  /// 「本地JS」「XBPQ」各自成一个分类，且**只在导入过**的时候才出现 ——
  /// 于是改成枚举 + 动态分类列表（见 [_groups]）。
  _SrcGroup _group = _SrcGroup.subscription;

  /// 首次构建时按当前主页源决定默认分类
  bool _tabInited = false;

  /// 长按一条线路 → 移入「失效」（用户 2026-10-15：
  /// 「删除后不再加载」「或者是移入失效分类，不加载不显示呢」）。
  ///
  /// 为什么不做"直接删除"：线路表是**以接口下发的 sites 为准整表替换**的，
  /// 删掉下次加载又被灌回来；而且删了就找不回。所以改成"移出列表 + 落盘 + 可移回"。
  Future<void> _markInvalid(SourceBean source) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          '移入失效线路？',
          style: TextStyle(
            fontSize: AppTheme.fontHeadline,
            color: AppTheme.textPrimary,
          ),
        ),
        content: Text(
          '「${source.name}」将不再加载、也不显示在列表里；\n'
          '随时可以在顶部「失效」里移回。',
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            color: AppTheme.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移入失效'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ApiConfig.instance.markVideoSourceInvalid(source);
    if (!mounted) return;
    AppToast.message('「${source.name}」已移入失效线路');
  }

  /// 长按线路 → **卡片式**菜单（一行两个）：分享 / 失效
  ///
  /// 影视线路本身没有"编辑 / 分组 / 批量删除"的接口（线路表以订阅下发为准），
  /// 所以只给实际存在的两个动作。
  Future<void> _sourceMenu(SourceBean source) async {
    await showCardActions(
      context,
      title: source.name,
      subtitle: source.api,
      actions: [
        CardAction(
          icon: Icons.ios_share_rounded,
          label: '分享',
          onTap: () {
            Clipboard.setData(
              ClipboardData(text: '${source.name}\n${source.api}'),
            );
            AppToast.message('已复制线路地址');
          },
        ),
        CardAction(
          icon: Icons.block_rounded,
          label: '失效',
          danger: true,
          onTap: () => _markInvalid(source),
        ),
      ],
    );
  }

  /// 本地源 bean → 对应的本地条目（PY / JS / XBPQ 三族）。
  ///
  /// 2026-10-29：这里原来只认 PY，JS 与 XBPQ 的源在源面板里长按会**毫无反应**
  /// （`_localOf` 返回 null 就 return 了）。现在三族都认。
  Future<void> _localSourceMenu(SourceBean bean) async {
    if (bean.isLocalPySource) {
      final s = LocalPythonSources.instance.sources
          .firstWhereOrNull((e) => e.sourceKey == bean.key);
      if (s == null) return;
      return _showLocalActions(
        bean: bean,
        subtitle: '本地PY · ${s.key}.py',
        onRename: (name) async {
          final r = await LocalPythonSources.instance.rename(s.key, name);
          return (r.ok, r.message);
        },
        onShare: () => LocalPythonSources.instance.readCode(s.key),
        onDelete: () async {
          await LocalPythonSources.instance.remove(s.key);
          return true;
        },
      );
    }
    if (bean.isLocalJsSource) {
      final s = LocalJsSources.instance.sources
          .firstWhereOrNull((e) => e.sourceKey == bean.key);
      if (s == null) return;
      return _showLocalActions(
        bean: bean,
        subtitle: '本地JS · ${s.key}.js',
        onRename: (name) async {
          final r = await LocalJsSources.instance.rename(s.key, name);
          return (r.ok, r.message);
        },
        onShare: () => LocalJsSources.instance.readCode(s.key),
        onDelete: () async {
          await LocalJsSources.instance.remove(s.key);
          return true;
        },
      );
    }
    if (bean.isXbpqSource) {
      return _showLocalActions(
        bean: bean,
        subtitle: 'XBPQ · ${bean.key}',
        onRename: (name) async {
          final r = await XbpqService.instance.rename(bean.key, name);
          return (r.ok, r.message);
        },
        // XBPQ 的"脚本"就是规则文本，分享出去即一份可直接导入的规则
        onShare: () async => XbpqService.instance.entryOf(bean.key)?.ruleText,
        onDelete: () async {
          await XbpqService.instance.remove(bean.key);
          return true;
        },
      );
    }
  }

  /// 三族本地源共用的长按菜单（编辑 / 分享 / 删除）。
  ///
  /// 抽出来是因为 PY / JS / XBPQ 的菜单文案与交互必须**完全一致**
  /// （用户 2026-10-29：「长按、布局等等全部和本地爬虫一样」），
  /// 只有背后的存储实现不同。
  Future<void> _showLocalActions({
    required SourceBean bean,
    required String subtitle,
    required Future<(bool, String?)> Function(String name) onRename,
    required Future<String?> Function() onShare,
    required Future<bool> Function() onDelete,
  }) async {
    await showCardActions(
      context,
      title: bean.name,
      subtitle: subtitle,
      actions: [
        CardAction(
          icon: Icons.drive_file_rename_outline,
          label: '编辑',
          onTap: () => _renameLocal(bean, onRename),
        ),
        CardAction(
          icon: Icons.ios_share_rounded,
          label: '分享',
          onTap: () async {
            final code = await onShare();
            if (code == null || code.isEmpty) {
              AppToast.error('找不到脚本内容');
              return;
            }
            await Clipboard.setData(ClipboardData(text: code));
            AppToast.message('内容已复制到剪贴板');
          },
        ),
        CardAction(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          danger: true,
          onTap: () => _deleteLocal(bean, onDelete),
        ),
      ],
    );
  }

  Future<void> _renameLocal(
    SourceBean bean,
    Future<(bool, String?)> Function(String name) doRename,
  ) async {
    final ctrl = TextEditingController(text: bean.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          '重命名',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: AppTheme.textPrimary),
          decoration: const InputDecoration(hintText: '显示名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final (ok, message) = await doRename(name);
    if (!ok) {
      AppToast.error(message ?? '改名失败');
      return;
    }
    await ApiConfig.instance.reloadLocalVideoSources();
    if (mounted) setState(() {});
  }

  Future<void> _deleteLocal(
    SourceBean bean,
    Future<bool> Function() doDelete,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          '删除本地源？',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: Text(
          '「${bean.name}」会被删除，不可恢复。',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await doDelete();
    // 删的是当前主页源时，reload 会自动切回订阅线路或下一条本地源
    await ApiConfig.instance.reloadLocalVideoSources();
    if (!mounted) return;
    setState(() {});
    AppToast.message('已删除');
  }

  /// 按住把手拖到另一条线路上 → 重排并落盘
  Future<void> _moveSource(String fromKey, String toKey) async {
    if (fromKey == toKey) return;

    // ── 本地源族内重排（PY / JS 各自一份顺序；XBPQ 没有顺序概念）──
    final gFrom = _groupOfKey(fromKey);
    final gTo = _groupOfKey(toKey);
    if (gFrom == gTo && gFrom != _SrcGroup.subscription) {
      // 只在本分类内排，且只排当前可见的这批
      final visible = _listOf(gFrom).map((s) => s.key).toList();
      final from = visible.indexOf(fromKey);
      final to = visible.indexOf(toKey);
      if (from < 0 || to < 0) return;
      final moved = visible.removeAt(from);
      visible.insert(to.clamp(0, visible.length), moved);
      switch (gFrom) {
        case _SrcGroup.localPy:
          await LocalPythonSources.instance.reorderWithin(visible);
          await ApiConfig.instance.reloadLocalVideoSources();
          break;
        case _SrcGroup.localJs:
          await LocalJsSources.instance.reorderWithin(visible);
          await ApiConfig.instance.reloadLocalVideoSources();
          break;
        case _SrcGroup.xbpq:
        case _SrcGroup.subscription:
          // XBPQ 规则按导入顺序，不提供拖动排序；订阅走下面的分支
          break;
      }
      return;
    }
    if (gFrom != _SrcGroup.subscription) return; // 跨分类拖动无意义

    // 订阅线路：只重排当前可见的这批（搜索过滤时不影响隐藏的源）
    // 直接对 RxList 本身取快照（它是 List 的子类），不碰受保护的 `.value`。
    final visible = _filteredSourcesFrom(
      List<SourceBean>.of(ApiConfig.instance.sourceBeanList),
    ).map((s) => s.key).toList();
    final from = visible.indexOf(fromKey);
    final to = visible.indexOf(toKey);
    if (from < 0 || to < 0) return;
    final item = visible.removeAt(from);
    visible.insert(to.clamp(0, visible.length), item);
    await ApiConfig.instance.reorderVideoSources(visible);
  }

  /// 「失效」分类的列表：已移出的线路，可逐条 / 全部移回
  Widget _buildInvalidList() {
    final api = ApiConfig.instance;
    // 读一下这个 Rx：让外面的 Obx 跟着条数变化刷新
    api.invalidVideoSourceCount.value;
    final items = api.invalidVideoSourcesForCurrentSub;
    if (items.isEmpty) {
      return Center(
        child: Text('没有失效线路', style: TextStyle(color: AppTheme.textTertiary)),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '已移出 ${items.length} 条（不加载、不显示）',
                style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: AppTheme.textTertiary,
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                final n = await api.restoreAllInvalidVideoSources();
                if (!mounted) return;
                setState(() => _showInvalid = false);
                AppToast.message('已移回 $n 条线路');
              },
              child: const Text('全部移回'),
            ),
          ],
        ),
        for (final m in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.borderLight, width: 0.5),
              ),
              child: Row(
                children: [
                  const Icon(Icons.block, size: 15, color: Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      (m['name'] ?? m['key'] ?? '').toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final ok = await api.restoreInvalidVideoSource(
                        (m['id'] ?? '').toString(),
                      );
                      if (!mounted || !ok) return;
                      AppToast.message('已移回');
                    },
                    child: const Text('移回'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 定位到当前选中的源（用户 2026-10-13：「搜索源页面要加个定位功能」）。
  ///
  /// 2026-10-20 修「定位不准」：原来把「本地源 + 分组标题」也算进订阅线路的
  /// 下标偏移里，且本地源固定滚到顶部 —— 现在按 **tab 分组**定位：
  ///   ① 先切到选中源所在的 tab；
  ///   ② 再按该 tab 内的下标算行偏移（tab 内没有分组标题，算术才准）。
  void _locateSelected() {
    final key = _selectedKey;
    if (key == null) return;
    final target = _groupOfKey(key);
    final list = _listOf(target);
    if (_group != target) {
      setState(() => _group = target);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToKey(list, key);
      });
    } else {
      _scrollToKey(list, key);
    }
  }

  void _scrollToKey(List<SourceBean> list, String key) {
    if (!_scrollController.hasClients) return;
    final idx = list.indexWhere((s) => s.key == key);
    if (idx < 0) return;
    final panelW = context.size?.width ?? MediaQuery.of(context).size.width;
    double offset;
    if (_gridMode) {
      // 与列表体的网格参数保持一致：2 列 / 间距 10 / 纵横比 3.4 / 行距 8
      final itemW = (panelW - 32 - 10) / 2;
      final rowH = itemW / 3.4 + 8;
      offset = 4 + (idx ~/ 2) * rowH;
    } else {
      // 单列行高：_SourceRow = 底距 6 + 容器上下内边距 22 + 图标 28
      offset = 4 + idx * 56.0;
    }
    final pos = _scrollController.position;
    final target = (offset - pos.viewportDimension / 3).clamp(
      0.0,
      pos.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  /// 当前主页源 key（列表里高亮 + 定位用）
  String? get _selectedKey => ApiConfig.instance.homeSourceBean.value?.key;

  /// 按搜索词过滤（列表体与「定位」按钮共用同一份口径）
  List<SourceBean> _filteredSourcesFrom(List<SourceBean> all) {
    if (_keyword.isEmpty) return all;
    final kw = _keyword.toLowerCase();
    return all.where((s) => s.name.toLowerCase().contains(kw)).toList();
  }

  /// 本地 **Python** 源（key 前缀 `localpy_`）
  List<SourceBean> get _localPySources {
    // ignore: invalid_use_of_protected_member
    final all = ApiConfig.instance.localVideoSources.value;
    return all.where((s) => s.isLocalPySource).toList();
  }

  /// 本地 **JS** 源（key 前缀 `localjs_`）
  List<SourceBean> get _localJsSources {
    // ignore: invalid_use_of_protected_member
    final all = ApiConfig.instance.localVideoSources.value;
    return all.where((s) => s.isLocalJsSource).toList();
  }

  /// **XBPQ** 规则源（key 前缀 `localxbpq_`）
  List<SourceBean> get _xbpqSources {
    // ignore: invalid_use_of_protected_member
    final all = ApiConfig.instance.localVideoSources.value;
    return all.where((s) => s.isXbpqSource).toList();
  }

  /// 某个分类下的源（已按搜索词过滤）
  List<SourceBean> _listOf(_SrcGroup g) {
    switch (g) {
      case _SrcGroup.subscription:
        // ignore: invalid_use_of_protected_member
        return _filteredSourcesFrom(ApiConfig.instance.sourceBeanList.value);
      case _SrcGroup.localPy:
        return _filteredSourcesFrom(_localPySources);
      case _SrcGroup.localJs:
        return _filteredSourcesFrom(_localJsSources);
      case _SrcGroup.xbpq:
        return _filteredSourcesFrom(_xbpqSources);
    }
  }

  /// 该分类的**总条数**（不受搜索影响 —— 决定分类胶囊是否出现）
  int _countOf(_SrcGroup g) {
    switch (g) {
      case _SrcGroup.subscription:
        // ignore: invalid_use_of_protected_member
        return ApiConfig.instance.sourceBeanList.value.length;
      case _SrcGroup.localPy:
        return _localPySources.length;
      case _SrcGroup.localJs:
        return _localJsSources.length;
      case _SrcGroup.xbpq:
        return _xbpqSources.length;
    }
  }

  /// 要显示的分类胶囊。
  ///
  /// 订阅永远在；三族本地源**只有导入过才出现**（用户 2026-10-29：
  /// 「只有导入这两种脚本才会在源切换里面有这两个的分类」）。
  List<_SrcGroup> get _groups {
    return [
      _SrcGroup.subscription,
      if (_countOf(_SrcGroup.localPy) > 0) _SrcGroup.localPy,
      if (_countOf(_SrcGroup.localJs) > 0) _SrcGroup.localJs,
      if (_countOf(_SrcGroup.xbpq) > 0) _SrcGroup.xbpq,
    ];
  }

  /// 这条源是不是「本地导入」的（PY / JS / XBPQ 三族）。
  ///
  /// 用来决定挂哪种菜单（本地源有重命名/删除，订阅线路没有）。
  /// 逐条判断而不是按"当前 tab"判断 —— 以后哪个 tab 里混进异族源都不会漏。
  static bool _isLocalBean(SourceBean s) =>
      s.isLocalPySource || s.isLocalJsSource || s.isXbpqSource;

  /// 选中源属于哪个分类
  _SrcGroup _groupOfKey(String key) {
    if (key.startsWith('localpy_')) return _SrcGroup.localPy;
    if (key.startsWith(SourceBean.localJsKeyPrefix)) return _SrcGroup.localJs;
    if (key.startsWith(SourceBean.xbpqKeyPrefix)) return _SrcGroup.xbpq;
    return _SrcGroup.subscription;
  }

  /// 分类胶囊（放在等分容器里的一个格子）
  ///
  /// ── 2026-10-30 重做 ──────────────────────────────────────────
  /// 用户：「源切换这个按钮太丑了」「这个框要一样的尺寸，2 个就是两等分，
  /// 3 个就是三等分，4 个就是四等分」。
  ///
  /// 原来宽度由文字撑开（`padding: horizontal 12` + 内容自适应），于是
  /// 「本地PY 155」比「花蚁」宽一倍，一排胶囊参差不齐、看着很乱。
  /// 现在：
  ///   · 宽度交给外层 `Expanded` 平分 —— 2/3/4 个就是 2/3/4 等分；
  ///   · 高度统一 34、圆角 17（原来 30/15 偏矮，和弹窗其它元素不搭）；
  ///   · 数量用小一号字放在名字后面（11 vs 12.5），等分后 84px 也塞得下
  ///     「本地PY 155」，不会只剩「本地P…」；
  ///   · 选中态用 `accentOnSurface` 而非 `accentColor` —— 后者是调色板 primary，
  ///     水墨主题下是墨灰 #3A3A3A，深色模式里"选中了却看不出来"；
  ///   · 未选中透明底 + 0.5 细边，与弹窗背景融为一体（原来涂一层灰底显脏）；
  ///   · 前景色按底色亮度取黑/白（柠檬黄、蕉红这类浅强调色，白字只有 1.5:1）。
  ///
  /// [count] 传负数表示不显示数量（订阅线路那一格显示的是订阅名，不是条数）。
  Widget _tabPill(String label, int count, bool on, VoidCallback onTap) {
    final accent = AppTheme.accentOnSurface;
    final onColor =
        accent.computeLuminance() > 0.179 ? Colors.black : Colors.white;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        height: 34,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: on ? accent : Colors.transparent,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(
            color: on ? Colors.transparent : AppTheme.borderLight,
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: on ? onColor : AppTheme.textSecondary,
                  fontSize: 12.5,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (count >= 0) ...[
              const SizedBox(width: 3),
              Text(
                '$count',
                style: TextStyle(
                  color: on
                      ? onColor.withValues(alpha: 0.72)
                      : AppTheme.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 当前 tab 的源列表（本地源 / 订阅线路共用同一套网格与单列形态）。
  ///
  /// 用户 2026-10-20：**长按条目任意位置拖动排序**（列表/网格都一样）；
  /// 菜单统一收到条目右侧的 ⋮ 按钮，避免和长按拖动抢手势。
  Widget _buildSourceList(
    List<SourceBean> list,
    String? selectedKey,
  ) {
    Widget itemOf(SourceBean source, Widget child) {
      return DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != source.key,
        onAcceptWithDetails: (d) => _moveSource(d.data, source.key),
        builder: (_, candidate, _) =>
            _draggableItem(source, child, candidate),
      );
    }

    Widget tileOf(SourceBean source) => itemOf(
          source,
          _SourceTile(
            name: source.name,
            api: source.api,
            selected: source.key == selectedKey,
            onTap: () => _selectSource(source),
            onMenu: () => _isLocalBean(source)
                ? _localSourceMenu(source)
                : _sourceMenu(source),
          ),
        );

    Widget rowOf(SourceBean source) => itemOf(
          source,
          _SourceRow(
            name: source.name,
            api: source.api,
            selected: source.key == selectedKey,
            onTap: () => _selectSource(source),
            onMenu: () => _isLocalBean(source)
                ? _localSourceMenu(source)
                : _sourceMenu(source),
          ),
        );

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (_gridMode)
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 10,
              childAspectRatio: 3.4,
            ),
            itemCount: list.length,
            itemBuilder: (context, index) => tileOf(list[index]),
          )
        else
          for (final source in list) rowOf(source),
      ],
    );
  }

  /// 长按拖动外壳：反馈卡 + 落点高亮。
  Widget _draggableItem(
    SourceBean source,
    Widget child,
    List<String?> candidate,
  ) {
    final draggable = LongPressDraggable<String>(
      data: source.key,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(
            color: AppTheme.backgroundSecondary,
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
            source.name,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontSubhead,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: child),
      child: child,
    );
    return _dropHighlight(draggable, candidate);
  }

  /// 拖动悬停时的高亮外框
  Widget _dropHighlight(Widget child, List<String?> candidate) {
    if (candidate.isEmpty) return child;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.accentColor.withValues(alpha: 0.6),
          width: 1.4,
        ),
      ),
      child: child,
    );
  }

  Future<void> _selectSource(SourceBean source) async {
    // 选本地源 ⇒ 顺手打开**对应那一族**的开关（与本地源管理页同一语义），
    // 否则主页源会被订阅线路覆盖。
    // 2026-10-29：三族各有独立开关，不能一律去开「本地爬虫」。
    if (source.isLocalPySource && !ApiConfig.instance.localSourcesEnabled.value) {
      await ApiConfig.instance.setLocalSourcesEnabled(true);
    } else if (source.isXbpqSource &&
        !ApiConfig.instance.localXbpqEnabled.value) {
      await ApiConfig.instance.setLocalXbpqEnabled(true);
    }
    // 本地 JS 没有开关（2026-10-31，导入即启用），这里不需要再"顺手打开"。
    await ApiConfig.instance.setHomeSource(source);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    // 首次打开：当前主页源是本地源 → 直接落在对应分类
    if (!_tabInited) {
      _tabInited = true;
      final key = _selectedKey;
      if (key != null) _group = _groupOfKey(key);
    }
    // 面板高度 = 1/3 屏 × 1.2（用户要求"变成现在的 1.2 倍"）：
    // 1/3 屏时标题+搜索框占掉大半，源网格只剩一点点高（看起来"底部遮住一部分"），
    // 加高后常规屏 3 行源可以完整显示；矮屏仍可滚动兜底。
    final panelHeight = (h * 0.4).clamp(h * 0.34, h * 0.48);
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      // 顶部避让状态栏：标题永远不被刘海/状态栏遮住
      child: SafeArea(
        top: true,
        bottom: false,
        child: SizedBox(
          height: panelHeight,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部拖拽指示条
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 4),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textSecondary.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // 头部：标题「搜索源」（左）+ 单列/双排切换（右）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Text(
                      '搜索源',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    // 「失效」入口（用户 2026-10-15）：只在存在失效线路时出现，
                    // 点一下在"正常线路 / 失效线路"之间切换。
                    Obx(() {
                      final n =
                          ApiConfig.instance.invalidVideoSourceCount.value;
                      if (n <= 0) return const SizedBox.shrink();
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: () =>
                                setState(() => _showInvalid = !_showInvalid),
                            child: Container(
                              height: 30,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: _showInvalid
                                    ? AppTheme.accentColor.withValues(
                                        alpha: 0.15,
                                      )
                                    : AppTheme.backgroundTertiary,
                                borderRadius: BorderRadius.circular(15),
                              ),
                              child: Text(
                                '失效 $n',
                                style: TextStyle(
                                  fontSize: AppTheme.fontFootnote,
                                  color: _showInvalid
                                      ? AppTheme.accentColor
                                      : AppTheme.textSecondary,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                      );
                    }),
                    // 定位：滚到当前选中的源（用户 2026-10-13 要求）
                    GestureDetector(
                      onTap: _locateSelected,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: AppTheme.backgroundTertiary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.my_location_rounded,
                          size: 15,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => setState(() => _gridMode = !_gridMode),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: AppTheme.backgroundTertiary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _gridMode
                              ? Icons.view_list_outlined
                              : Icons.grid_view_outlined,
                          size: 15,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 搜索（小胶囊，占满宽度）
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _ExpandableSearchField(
                  controller: _searchController,
                  keyword: _keyword,
                  onChanged: (v) => setState(() => _keyword = v.trim()),
                ),
              ),
              // 分类胶囊：订阅线路 + 三族本地源 —— **等分排列**。
              // 本地源即使对应开关关着也显示（点它即会打开开关）；
              // 但**没导入过的那一族整条不出现**（用户 2026-10-29）。
              Obx(() {
                final groups = _groups;
                final subName =
                    SubscriptionService.instance.active?.name ?? '订阅线路';
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                  child: Row(
                    children: [
                      for (var i = 0; i < groups.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        // Expanded 平分：2 个 = 两等分，3 个 = 三等分，
                        // 4 个 = 四等分（用户 2026-10-30 明确要求）
                        Expanded(
                          child: _tabPill(
                            groups[i] == _SrcGroup.subscription
                                ? subName
                                : groups[i].label,
                            groups[i] == _SrcGroup.subscription
                                ? -1
                                : _countOf(groups[i]),
                            _group == groups[i],
                            () => setState(() => _group = groups[i]),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }),
              // 源列表：占满剩余空间，随时可滚动（搜索中/键盘弹起时也一样）
              Expanded(
                child: Obx(() {
                  // 「失效」分类：列出已移出的线路（可逐条 / 全部移回）
                  if (_showInvalid) return _buildInvalidList();
                  final selectedKey = _selectedKey;
                  final groups = _groups;
                  // 当前分类被删空（或开关变化导致该族消失）→ 回落到订阅线路
                  final group =
                      groups.contains(_group) ? _group : _SrcGroup.subscription;
                  final isLocal = group != _SrcGroup.subscription;
                  final list = _listOf(group);
                  if (list.isEmpty) {
                    return Center(
                      child: Text(
                        _keyword.isEmpty
                            ? (isLocal ? '这里还没有${group.label}源' : '这里还没有源')
                            : '未找到匹配的源',
                        style: TextStyle(color: AppTheme.textTertiary),
                      ),
                    );
                  }
                  return _buildSourceList(list, selectedKey);
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单列模式：一行一个源，圆圈 + 类型字符 + 名称
class _SourceRow extends StatelessWidget {
  final String name;
  final String api;
  final bool selected;
  final VoidCallback onTap;

  /// 菜单入口（⋮）。长按已经是拖动排序，菜单不能再用长按。
  final VoidCallback? onMenu;

  const _SourceRow({
    required this.name,
    required this.api,
    required this.selected,
    required this.onTap,
    this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.accentColor.withValues(alpha: 0.12)
                : AppTheme.backgroundTertiary,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? AppTheme.accentColor.withValues(alpha: 0.4)
                  : AppTheme.borderLight,
              width: selected ? 1 : 0.5,
            ),
          ),
          child: Row(
            children: [
              // 猫爪风格源图标
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: selected
                      ? AppTheme.accentColor
                      : AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.pets,
                  size: 15,
                  color: selected ? Colors.white : AppTheme.textTertiary,
                ),
              ),
              const SizedBox(width: 10),
              SourceKindBadge(kind: inferMediaKind(name, api: api)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    color: selected
                        ? AppTheme.textPrimary
                        : AppTheme.textSecondary,
                    fontSize: AppTheme.fontBody,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onMenu != null)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onMenu,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(Icons.more_horiz_rounded,
                        size: 17, color: AppTheme.textTertiary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 源面板搜索框：**超小胶囊**（与首页 HomeSearchBar 同规格）
/// 高 30 / 圆角 15 / 底色 cardLight·cardDark / 轻阴影无描边
class _ExpandableSearchField extends StatefulWidget {
  final TextEditingController controller;
  final String keyword;
  final ValueChanged<String> onChanged;

  const _ExpandableSearchField({
    required this.controller,
    required this.keyword,
    required this.onChanged,
  });

  @override
  State<_ExpandableSearchField> createState() => _ExpandableSearchFieldState();
}

class _ExpandableSearchFieldState extends State<_ExpandableSearchField> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 透明底小胶囊搜索框：不涂灰色块（用户要求"灰色背景改成透明的，整体统一"），
    // 只留细边胶囊，与弹窗背景融为一体；深浅模式自动跟随描边色。
    return Container(
      height: 30,
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: Row(
        children: [
          const SizedBox(width: 10),
          Icon(Icons.search, color: AppTheme.textTertiary, size: 14),
          const SizedBox(width: 5),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focus,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 12,
              ),
              onChanged: widget.onChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索源…',
                hintStyle: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: 12,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 6),
              ),
            ),
          ),
          if (widget.keyword.isNotEmpty)
            GestureDetector(
              onTap: () {
                widget.controller.clear();
                widget.onChanged('');
              },
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Icon(
                  Icons.cancel,
                  color: AppTheme.textTertiary,
                  size: 13,
                ),
              ),
            ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

/// 双排模式：网格卡片，圆圈 + 类型字符 + 名称
class _SourceTile extends StatelessWidget {
  final String name;
  final String api;
  final bool selected;
  final VoidCallback onTap;

  /// 菜单入口（⋮）。长按已经是拖动排序，菜单不能再用长按。
  final VoidCallback? onMenu;

  const _SourceTile({
    required this.name,
    required this.api,
    required this.selected,
    required this.onTap,
    this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? AppTheme.accentColor.withValues(alpha: 0.4)
                : AppTheme.borderLight,
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 16,
              color: selected ? AppTheme.accentColor : AppTheme.textTertiary,
            ),
            const SizedBox(width: 8),
            SourceKindBadge(kind: inferMediaKind(name, api: api)),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  color: selected
                      ? AppTheme.textPrimary
                      : AppTheme.textSecondary,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onMenu != null)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onMenu,
                child: Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Icon(Icons.more_horiz_rounded,
                      size: 16, color: AppTheme.textTertiary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
