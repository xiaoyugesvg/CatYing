import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'common_widgets.dart';
import 'package:get/get.dart';
import '../common/theme.dart';
import '../models/source_bean.dart';
import '../services/api_config.dart';
import '../services/source_kind.dart';
import 'app_toast.dart';
import 'card_action_sheet.dart';
import 'source_kind_badge.dart';

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

class _SourceSwitchSheetState extends State<SourceSwitchSheet> {
  final TextEditingController _searchController = TextEditingController();

  /// 源列表滚动控制器（「定位」按钮要滚到当前选中的源）
  final ScrollController _scrollController = ScrollController();
  String _keyword = '';

  /// false=单列列表 / true=双排网格（默认双排，与参考截图一致）
  bool _gridMode = true;

  /// 是否正在看「失效线路」分类（顶部「失效 N」切换）
  bool _showInvalid = false;

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

  /// 按住把手拖到另一条线路上 → 重排并落盘
  Future<void> _moveSource(String fromKey, String toKey) async {
    if (fromKey == toKey) return;
    final all = List<SourceBean>.of(
      // ignore: invalid_use_of_protected_member
      ApiConfig.instance.sourceBeanList.value,
    );
    final from = all.indexWhere((s) => s.key == fromKey);
    final to = all.indexWhere((s) => s.key == toKey);
    if (from < 0 || to < 0) return;
    final item = all.removeAt(from);
    all.insert(to, item);
    await ApiConfig.instance.reorderVideoSources(
      all.map((s) => s.key).toList(),
    );
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
  /// 网格/单列两种形态都按**算术**算行偏移（不用 GlobalKey + ensureVisible：
  /// 选中的源常常在很下面、还没被 build，拿不到 context 就定位不了）。
  void _locateSelected(List<SourceBean> list, String? selectedKey) {
    if (selectedKey == null || !_scrollController.hasClients) return;
    // 本地 Python 源单独排在最上面，直接回到顶部
    if (selectedKey.startsWith('localpy_')) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
      return;
    }
    final idx = list.indexWhere((s) => s.key == selectedKey);
    if (idx < 0) return;
    final panelW = context.size?.width ?? MediaQuery.of(context).size.width;
    double offset;
    if (_gridMode) {
      // 与 _buildBody 的网格参数保持一致：2 列 / 间距 10 / 纵横比 3.4 / 行距 8
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

  /// 分组小标题（只有「本地 Python / 订阅线路」两处用）
  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppTheme.fontCaption,
          color: AppTheme.textTertiary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  void _selectSource(SourceBean source) {
    ApiConfig.instance.setHomeSource(source);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
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
                      onTap: () {
                        // ignore: invalid_use_of_protected_member
                        final all = ApiConfig.instance.sourceBeanList.value;
                        _locateSelected(
                          _filteredSourcesFrom(all),
                          _selectedKey,
                        );
                      },
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
              // 源列表：占满剩余空间，随时可滚动（搜索中/键盘弹起时也一样）
              Expanded(
                child: Obx(() {
                  // 「失效」分类：列出已移出的线路（可逐条 / 全部移回）
                  if (_showInvalid) return _buildInvalidList();
                  // ignore: invalid_use_of_protected_member
                  final all = ApiConfig.instance.sourceBeanList.value;
                  final selectedKey = _selectedKey;
                  final list = _filteredSourcesFrom(all);
                  // 本地 Python 源：单独一组（用户 2026-10-17），不跟订阅线路混排。
                  // 仅在「本地爬虫」开关打开时显示（用户 2026-10-18：默认优先订阅）。
                  final local = ApiConfig.instance.localSourcesEnabled.value
                      ? _filteredSourcesFrom(
                          // ignore: invalid_use_of_protected_member
                          ApiConfig.instance.localVideoSources.value,
                        )
                      : const <SourceBean>[];
                  if (list.isEmpty && local.isEmpty) {
                    return Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          '未找到匹配的源',
                          style: TextStyle(color: AppTheme.textTertiary),
                        ),
                      ),
                    );
                  }
                  // 用户 2026-10-13：「搜索源里面不要需要区分分类，例如 CMS 还有 js 这些」
                  // ⇒ 订阅线路仍然平铺；只有「本地 Python」单独放在最上面一组。
                  return ListView(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      if (local.isNotEmpty) ...[
                        _sectionHeader('本地 Python（${local.length}）'),
                        if (_gridMode)
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  mainAxisSpacing: 8,
                                  crossAxisSpacing: 10,
                                  childAspectRatio: 3.4,
                                ),
                            itemCount: local.length,
                            itemBuilder: (context, index) {
                              final source = local[index];
                              return _SourceTile(
                                name: source.name,
                                api: source.api,
                                selected: source.key == selectedKey,
                                onTap: () => _selectSource(source),
                                // 本地源不走「移入失效」，删除在设置页里
                                onLongPress: null,
                              );
                            },
                          )
                        else
                          for (final source in local)
                            _SourceRow(
                              name: source.name,
                              api: source.api,
                              selected: source.key == selectedKey,
                              onTap: () => _selectSource(source),
                              onLongPress: null,
                            ),
                        const SizedBox(height: 10),
                      ],
                      if (list.isNotEmpty && local.isNotEmpty)
                        _sectionHeader('订阅线路'),
                      if (_gridMode)
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 10,
                                childAspectRatio: 3.4,
                              ),
                          itemCount: list.length,
                          itemBuilder: (context, index) {
                            final source = list[index];
                            return DragTarget<String>(
                              onWillAcceptWithDetails: (d) =>
                                  d.data != source.key,
                              onAcceptWithDetails: (d) =>
                                  _moveSource(d.data, source.key),
                              builder: (_, candidate, _) {
                                final tile = _SourceTile(
                                  name: source.name,
                                  api: source.api,
                                  selected: source.key == selectedKey,
                                  onTap: () => _selectSource(source),
                                  onLongPress: () => _sourceMenu(source),
                                  dragHandle: CardDragHandle(
                                    data: source.key,
                                    label: source.name,
                                  ),
                                );
                                if (candidate.isEmpty) return tile;
                                return DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: AppTheme.accentColor.withValues(
                                        alpha: 0.6,
                                      ),
                                      width: 1.4,
                                    ),
                                  ),
                                  child: tile,
                                );
                              },
                            );
                          },
                        )
                      else
                        for (final source in list)
                          DragTarget<String>(
                            onWillAcceptWithDetails: (d) =>
                                d.data != source.key,
                            onAcceptWithDetails: (d) =>
                                _moveSource(d.data, source.key),
                            builder: (_, candidate, _) {
                              final row = _SourceRow(
                                name: source.name,
                                api: source.api,
                                selected: source.key == selectedKey,
                                onTap: () => _selectSource(source),
                                onLongPress: () => _sourceMenu(source),
                                dragHandle: CardDragHandle(
                                  data: source.key,
                                  label: source.name,
                                ),
                              );
                              if (candidate.isEmpty) return row;
                              return DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: AppTheme.accentColor.withValues(
                                      alpha: 0.6,
                                    ),
                                    width: 1.4,
                                  ),
                                ),
                                child: row,
                              );
                            },
                          ),
                    ],
                  );
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

  /// 长按 = 卡片式菜单（分享 / 失效）
  final VoidCallback? onLongPress;

  /// 拖动把手（长按它排序）；null = 不显示（本地 Python 源）
  final Widget? dragHandle;

  const _SourceRow({
    required this.name,
    required this.api,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.dragHandle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
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
              if (dragHandle != null) dragHandle!,
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

  /// 长按 = 卡片式菜单（分享 / 失效）
  final VoidCallback? onLongPress;

  /// 拖动把手（长按它排序）；null = 不显示（本地 Python 源）
  final Widget? dragHandle;

  const _SourceTile({
    required this.name,
    required this.api,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.dragHandle,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
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
            if (dragHandle != null) ...[
              const SizedBox(width: 2),
              dragHandle!,
            ],
          ],
        ),
      ),
    );
  }
}
