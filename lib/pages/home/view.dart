import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../services/player_prefs.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import '../../services/api_config.dart';
import '../../models/movie.dart';
import '../../models/movie_sort.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/source_switch_sheet.dart';
import '../../widgets/vod_card.dart';
import '../webview/view.dart';
import 'controller.dart';
import '../../widgets/home_search_bar.dart';
import '../../services/main_tab_controller.dart';
import '../../services/nav_feature_service.dart';
import '../../reading/services/settings_service.dart';

/// 首页 - 对应 Swift HomeView
class HomePage extends StatefulWidget {
  final VoidCallback? onSearchTap;

  const HomePage({super.key, this.onSearchTap});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final HomeController _controller = Get.put(HomeController());
  bool _isReconnecting = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 透明背景,让 app.dart ContentView 里的 BackgroundService 全局背景层透出
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // 底部不避让 Home Indicator：内容延伸到小白条下方，
          // 一屏显示更多卡片（用户要求）
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                // 顶部：源切换 + 搜索
                _buildHeaderBar(),
                // 主内容：大图幻灯片 → 分类 →（点分类弹出）筛选 → 片单/网格
                Expanded(child: _buildContentArea()),
              ],
            ),
          ),
          // 重连覆盖层
          if (_isReconnecting) _buildReconnectingOverlay(),
        ],
      ),
    );
  }

  /// 重连覆盖层 - 对应 Swift isReconnecting overlay
  Widget _buildReconnectingOverlay() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingXXL,
          vertical: AppTheme.spacingLG,
        ),
        decoration: BoxDecoration(
          color: AppTheme.backgroundElevated,
          borderRadius: BorderRadius.circular(AppTheme.radiusMD),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppTheme.accentColor,
              ),
            ),
            const SizedBox(height: AppTheme.spacingMD),
            Text(
              '正在重连服务...',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingSM, AppTheme.spacingLG, AppTheme.spacingXS),
      child: Row(
        children: [
          // 左：猫爪 Logo + 源名（点击换源）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              final changed = await SourceSwitchSheet.show(context);
              if (changed && mounted) {
                _controller.refresh();
              }
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _CatPawLogo(),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 130),
                  child: Obx(() => Text(
                        ApiConfig.instance.homeSourceBean.value?.name ?? '选择源',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )),
                ),
              ],
            ),
          ),
          // 右：搜索 —— 收起=圆形搜索图标，点击展开成小胶囊（长度约屏宽 36%，
          // 不撑满整行）。Spacer 把它顶到右上角，展开时向左伸展（iOS 风格）。
          const Spacer(),
          HomeSearchBar(
            hintText: '搜索影片',
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) {
                Get.toNamed('/search', arguments: v.trim());
              } else if (widget.onSearchTap != null) {
                widget.onSearchTap!();
              } else {
                Get.toNamed('/search');
              }
            },
            onTapEmpty: () {
              if (widget.onSearchTap != null) {
                widget.onSearchTap!();
              } else {
                Get.toNamed('/search');
              }
            },
          ),
          const SizedBox(width: 8),
          // 史藏按钮：右上角搜索按钮右侧（功能不变，点击进入史藏 tab）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                MainTabController.instance.select(NavFeature.shelf.tabIndex),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppTheme.palette.cardDark
                    : AppTheme.palette.cardLight,
                borderRadius: BorderRadius.circular(15),
                border:
                    Border.all(color: AppTheme.borderLight, width: 0.5),
              ),
              child: Icon(
                Icons.schedule_outlined,
                size: 16,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryTabBar() {
    // 分类行：**去掉外层卡片背景**（原来是一张 backgroundCard 卡片包着，
    // 切外观时那张卡片的描边写死白色 → 浅色模式下看起来"没跟着变"）。
    // 现在分类直接贴在页面上，只用「|」与右侧筛选按钮分隔。
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          // 分类（横向滚动）
          Expanded(
            child: Obx(() {
              // 分类屏蔽：被屏蔽的分类不进列表（在「筛选 → 分类屏蔽」里勾选）
              final blocked = PlayerPrefs.instance.blockedCategories;
              final sorts = _controller.sorts
                  .where((s) => !blocked.contains(s.name))
                  .toList();
              return ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.zero,
                itemCount: sorts.length,
                itemBuilder: (context, index) {
                  final sort = sorts[index];
                  final isSelected =
                      _controller.selectedSort.value?.id == sort.id;
                  return Padding(
                    // 改成椭圆卡片后需要一点横向间隔（原来是纯文字，2 就够）
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => _controller.selectSort(sort),
                      child: _CategoryChip(
                        label: sort.name,
                        selected: isSelected,
                      ),
                    ),
                  );
                },
              );
            }),
          ),
          // 分隔线「|」：把分类与筛选按钮分开
          Container(
            width: 1,
            height: 18,
            margin: const EdgeInsets.symmetric(horizontal: 10),
            color: AppTheme.borderMedium,
          ),
          // 右侧筛选按钮：点击弹出「分类屏蔽 / 隐藏筛选 / 切换布局」菜单
          _buildFilterButton(),
        ],
      ),
    );
  }

  /// 筛选入口按钮（放在分类栏右端）
  ///
  /// 没有筛选条件时置灰不可点；已有选中项时高亮成实心圆点，
  /// 让用户一眼看出"当前列表是被筛选过的"。
  /// 筛选按钮（分类栏右端）。
  ///
  /// 点击弹出**三项菜单**（参考图样式）：
  ///   分类屏蔽 / 隐藏筛选 / 切换布局
  /// 其中「隐藏筛选」展开下方的分组筛选行；按钮在有筛选条件时高亮。
  Widget _buildFilterButton() {
    return Obx(() {
      final filters = _controller.currentFilters;
      final hasAny = filters.isNotEmpty;
      final picked = _controller.selectedFilters.entries
          .where((e) => e.value.isNotEmpty)
          .length;
      return Padding(
        padding: const EdgeInsets.only(left: 6, right: 2),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: hasAny ? _openOptionsMenu : null,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: picked > 0
                  ? AppTheme.accentColor.withValues(alpha: 0.18)
                  : AppTheme.backgroundTertiary,
              shape: BoxShape.circle,
              border: Border.all(
                color: picked > 0
                    ? AppTheme.accentColor.withValues(alpha: 0.45)
                    : AppTheme.borderLight,
                width: 0.6,
              ),
            ),
            child: Icon(
              Icons.tune,
              size: 18,
              color: hasAny
                  ? (picked > 0
                      ? AppTheme.accentColor
                      : AppTheme.textSecondary)
                  : AppTheme.textTertiary.withValues(alpha: 0.4),
            ),
          ),
        ),
      );
    });
  }

  /// 弹出的选项菜单：筛选条件 / 分类屏蔽 / 隐藏筛选 / 切换布局
  ///
  /// ⚠️ 「筛选条件」这一项是**必须保留的功能入口**：底部筛选菜单
  /// （[_openFilterSheet]）原来只挂在 RFW 主题的 `toggleFilters` 事件上，
  /// RFW 主题整套删掉后它就没人调用了。为了"删 RFW 但其余功能不变"，
  /// 这里给它补了一个原生入口 —— RFW 可以删，筛选能力不能丢。
  Future<void> _openOptionsMenu() async {
    final prefs = PlayerPrefs.instance;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => kbSheet(SafeArea(
        top: false,
        child: StatefulBuilder(
          builder: (ctx, setSheet) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textTertiary.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // 菜单项：**一行两个**（用户 2026-10-14：这类菜单别一行一个，太占位置）
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _optionTile(
                            icon: Icons.tune,
                            label: '筛选条件',
                            onTap: () {
                              Navigator.pop(ctx);
                              _openFilterSheet();
                            },
                          ),
                        ),
                        Expanded(
                          child: _optionTile(
                            icon: Icons.block,
                            label: '分类屏蔽',
                            onTap: () {
                              Navigator.pop(ctx);
                              _openCategoryBlockSheet();
                            },
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: _optionTile(
                            icon: Icons.filter_alt_outlined,
                            label:
                                prefs.hideFilters.value ? '显示筛选' : '隐藏筛选',
                            onTap: () async {
                              Navigator.pop(ctx);
                              await prefs
                                  .setHideFilters(!prefs.hideFilters.value);
                              setSheet(() {});
                            },
                          ),
                        ),
                        Expanded(
                          child: _optionTile(
                            icon: Icons.grid_view,
                            label: '切换布局',
                            onTap: () {
                              Navigator.pop(ctx);
                              _openLayoutSheet();
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      )),
    );
  }

  /// 菜单项（图标 + 文字）。
  /// ⚠️ 现在挂在**一行两个**的 `Row + Expanded` 里 ⇒ 内边距与图标-文字间距
  /// 都要收窄，否则半宽下文字会被挤断（原来是一行一个的宽排版）。
  Widget _optionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppTheme.textPrimary),
            const SizedBox(width: 10),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontHeadline)),
            ),
          ],
        ),
      ),
    );
  }

  /// 把一堆选项排成**固定列数**的网格。
  ///
  /// 用户 2026-10-14：「选项多的别一行一个，很占位置」⇒ 统一 3~4 列。
  ///   · 宽 ≥ 340 → 4 列，否则 3 列（"一行三个或 4 个"）；
  ///   · 用 `Wrap` + **定宽子项**而不是 `GridView`：行高按内容自适应 —— 外层
  ///     本来就在可滚动的弹窗里，`GridView` 的固定 `childAspectRatio` 反而会
  ///     把行高撑高（那就又"占位置"了）。
  Widget _chipGrid(List<Widget> chips) {
    return LayoutBuilder(
      builder: (context, box) {
        const gap = 8.0;
        final cols = box.maxWidth >= 340 ? 4 : 3;
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final c in chips) SizedBox(width: w, child: c),
          ],
        );
      },
    );
  }

  /// 分类屏蔽：多选分类，屏蔽后不出现在首页分类栏
  Future<void> _openCategoryBlockSheet() async {
    final prefs = PlayerPrefs.instance;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => kbSheet(SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Text('分类屏蔽',
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('勾选的分类将隐藏',
                        style: TextStyle(
                            color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
                  ],
                ),
              ),
              Flexible(
                child: Obx(() => SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                      // 一行 3~4 个（分类名可能几十个，一行一个太占位置）
                      child: _chipGrid([
                        for (final s in _controller.sorts)
                          SelectableChip(
                            title: s.name,
                            isSelected:
                                prefs.blockedCategories.contains(s.name),
                            onTap: () =>
                                prefs.toggleBlockCategory(s.name),
                          ),
                      ]),
                    )),
              ),
            ],
          ),
        ),
      )),
    );
  }

  /// 切换布局：2 / 3 / 4 列
  ///
  /// 样式与「史藏」页的布局弹窗**保持一致**：大格子 + 左侧方块示意 +
  /// 右侧「N 列」，一行两个。原来是 Wrap + 小胶囊挤成一列，观感差很多。
  Future<void> _openLayoutSheet() async {
    final prefs = PlayerPrefs.instance;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => kbSheet(SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text('切换布局',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Text('一行显示几列',
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Obx(() => _layoutCell(
                              prefs.gridColumns.value, 2, ctx)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Obx(() => _layoutCell(
                              prefs.gridColumns.value, 3, ctx)),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Obx(() => _layoutCell(
                            prefs.gridColumns.value, 4, ctx)),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(child: SizedBox.shrink()),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      )),
    );
  }

  /// 布局选项格子（与史藏页同一套视觉）
  Widget _layoutCell(int cur, int n, BuildContext ctx) {
    final selected = cur == n;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        await PlayerPrefs.instance.setGridColumns(n);
        if (ctx.mounted) Navigator.pop(ctx);
      },
      child: Container(
        height: 62,
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accentColor.withValues(alpha: 0.14)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
          border: Border.all(
            color: selected
                ? AppTheme.accentColor.withValues(alpha: 0.7)
                : AppTheme.glassBorderSoft,
            width: selected ? 1.2 : 0.6,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 用 n 个小方块直观示意列数
            for (var i = 0; i < n && i < 4; i++)
              Container(
                width: 9,
                height: 13,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                decoration: BoxDecoration(
                  color: selected
                      ? AppTheme.accentColor
                      : AppTheme.textTertiary.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            const SizedBox(width: 10),
            Text('$n 列',
                style: TextStyle(
                    color: selected
                        ? AppTheme.accentColor
                        : AppTheme.textSecondary,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal)),
          ],
        ),
      ),
    );
  }

  /// 内联筛选行（参考图样式）：分类 / 地区 / 排序 / 年份 各一行芯片。
  ///
  /// 显隐由「筛选 → 隐藏筛选」控制（PlayerPrefs.hideFilters）。
  /// 点选即时生效（_controller.selectFilter）。
  Widget _buildInlineFilters() {
    return Obx(() {
      final groups = _controller.currentFilters;
      if (groups.isEmpty) return const SizedBox.shrink();
      return Container(
        margin: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG,
          0,
          AppTheme.spacingLG,
          AppTheme.spacingSM,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingMD,
          vertical: AppTheme.spacingMD,
        ),
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(AppTheme.radiusMD),
          border: Border.all(color: AppTheme.borderLight, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final f in groups) ...[
              _filterRow(f),
              if (f != groups.last) const SizedBox(height: 10),
            ],
          ],
        ),
      );
    });
  }

  /// 一行筛选：左侧组名 + 右侧**可横向滚动**的选项。
  ///
  /// 关键点（都是实测问题）：
  ///   1. 组名必须给足宽度且**允许换行** —— 原来 44 固定宽 + 不换行，
  ///      "国家/地区" 被压得看不见，整行只剩下一列「全部」芯片；
  ///   2. 选中值若不在当前列表里（换分类后的残留），「全部」的选中态要失效，
  ///      否则两个同时高亮；
  ///   3. 选项末尾留余量，最后一项不被裁掉半个字。
  ///   4. 源 filters 配置自带「全部/默认」首项时，**不再重复渲染固定「全部」**
  ///      （用户反馈：每个维度多了一列按钮，第二列点不动）——
  ///      直接渲染源返回的选项列表即可，与分类页筛选弹层样式一致。
  Widget _filterRow(SortFilter f) {
    final selected = _controller.selectedFilters[f.key];
    final hasValidSelection =
        selected != null && f.values.any((v) => v.v == selected);
    return Row(
      // 顶部对齐：组名可能换行成两行，芯片列保持顶部对齐才整齐
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 60,
          child: Padding(
            padding: const EdgeInsets.only(top: 6, right: 4),
            child: Text(
              f.name,
              // 组名文字在固定宽度列内居中
              textAlign: TextAlign.center,
              // 允许换行，长组名（国家/地区）不再被截断
              softWrap: true,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textTertiary,
                // 组名字号加大（11 → 13）：用户反馈 4 个字太小、卡片显宽
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              children: [
                // 只渲染源返回的选项（首个通常是「全部」或「默认」），
                // 不再追加固定「全部」——避免每个维度出现两列重复按钮
                for (final v in f.values) ...[
                  SelectableChip(
                    title: v.n,
                    // 空值项（「全部」）在无有效选中时高亮；其余按选中值高亮
                    isSelected:
                        v.v == '' ? !hasValidSelection : selected == v.v,
                    onTap: () => _controller.selectFilter(f.key, v.v),
                  ),
                  const SizedBox(width: AppTheme.spacingSM),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 筛选菜单：底部弹出，分组选择，点选即时生效
  Future<void> _openFilterSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 拖拽条
                Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 4),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.textTertiary.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // 标题 + 重置
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 12, 4),
                  child: Row(
                    children: [
                      Text('筛选',
                          style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: AppTheme.fontHeadline,
                              fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Obx(() {
                        final picked = _controller.selectedFilters.entries
                            .where((e) => e.value.isNotEmpty)
                            .length;
                        if (picked == 0) return const SizedBox.shrink();
                        return TextButton(
                          onPressed: () {
                            for (final f in _controller.currentFilters) {
                              _controller.selectFilter(f.key, '');
                            }
                          },
                          child: const Text('重置'),
                        );
                      }),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                    child: Obx(() => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final f in _controller.currentFilters) ...[
                              Text(f.name,
                                  style: TextStyle(
                                      color: AppTheme.textTertiary,
                                      // 与行筛选一致：组名字号 11 → 13
                                      fontSize: AppTheme.fontSubhead,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 8),
                              // 一行 3~4 个（筛选值可能几十个，一行一个太占位置）
                              _chipGrid([
                                // 与行筛选一致：不再追加固定「全部」，
                                // 源 filters 自带「全部/默认」首项，避免重复一列
                                for (final v in f.values)
                                  SelectableChip(
                                    title: v.n,
                                    isSelected: v.v == ''
                                        ? _controller
                                                .selectedFilters[f.key] ==
                                            null
                                        : _controller.selectedFilters[f.key] ==
                                            v.v,
                                    onTap: () =>
                                        _controller.selectFilter(f.key, v.v),
                                  ),
                              ]),
                              const SizedBox(height: 18),
                            ],
                          ],
                        )),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildContentArea() {
    return Obx(() {
      // 全部 Rx 在 Obx 闭包顶部读取，LayoutBuilder 内不再访问 Rx
      final isLoading = _controller.isLoading.value;
      final errorMsg = _controller.errorMessage.value;
      final homeVideos = _controller.homeVideos.toList();
      final videos = _controller.videos.toList();
      final sorts = _controller.sorts.toList();
      final selectedSortId = _controller.selectedSort.value?.id;
      final hasMore = _controller.hasMore.value;
      final source = ApiConfig.instance.homeSourceBean.value;

      if (isLoading && videos.isEmpty) {
        return const AppLoading();
      }

      // 源配置失败（线路清单没拿到）时 homeSourceBean 为 null，控制器会直接 return
      // 什么都不加载 → 原来这里只显示转圈/空白。优先暴露这个错误，让用户知道
      // 该去改源地址或换源，而不是对着空白页猜。
      final sourceConfigError = ApiConfig.instance.apiConfigError.value;
      if (sourceConfigError != null && videos.isEmpty) {
        return Center(
          child: AppError(
            message: sourceConfigError,
            onRetry: () => _controller.refresh(),
          ),
        );
      }

      if (errorMsg != null && videos.isEmpty) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (source != null && source.isIndexSite)
                const AppError(message: '该线路为索引服务，请点击影视跳转搜索')
              else
                AppError(
                  message: errorMsg,
                  onRetry: () => _controller.refresh(),
                ),
              if (source != null && !source.isSupportedInSwift)
                Padding(
                  padding: const EdgeInsets.only(top: AppTheme.spacingSM),
                  child: Text(
                    '当前源类型: ${source.typeDescription}',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
                ),
            ],
          ),
        );
      }

      return RefreshIndicator(
        color: AppTheme.accentColor,
        backgroundColor: AppTheme.backgroundSecondary,
        onRefresh: () => _controller.refresh(),
        // ⚠️ Obx 必须包住 LayoutBuilder：
        // 原来 gridColumns 只在 LayoutBuilder 内部读，改列数后这个 builder
        // 不会重建 → 网格列数不更新，看起来像"布局切换没生效"。
        child: Obx(() {
          final userCols = PlayerPrefs.instance.gridColumns.value;
          final crossAxisCount = userCols.clamp(2, 4);
          return LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth =
                  (constraints.maxWidth -
                          AppTheme.cardSpacing * (crossAxisCount - 1)) /
                      crossAxisCount;

              // 卡片真实高度 = 海报高（宽 × posterHeightRatio）+ 文字区。
              //
              // 海报比例 1.44 = 0.72 × 2：按要求把首页卡片高度做成原来的**两倍**。
              // ⚠️ 必须与下面 VodCard 的 posterHeightRatio 保持一致，
              //    否则网格分给卡片的高度与卡片实际需要的高度对不上 → 底部留白。
              const posterRatio = 1.44;
              const textArea = 30.0; // 标题行 + 上下内边距
              final cardHeight = cardWidth * posterRatio + textArea;
              final ratio = cardWidth / cardHeight;

              return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(
                        top: AppTheme.spacingXS, bottom: 8),
                    child: homeVideos.isEmpty
                        // 幻灯片兜底策略见 HomeController._fillBannerFromCategory：
                        //   · 还在加载 → 占位块（避免顶部高度跳一下）
                        //   · 加载完仍为空（源连分类列表都没有）→ **整块隐藏**，
                        //     不再留一块空白占位
                        ? (isLoading
                            ? const _BannerPlaceholder()
                            : const SizedBox.shrink())
                        : ListenableBuilder(
                            // 样式变化（设置里切换）时立即重建；
                            // key 带上 style → 换样式时 State/PageController 一起重建
                            // （viewportFraction 只能在构造时给，复用旧 controller 会错位）
                            listenable: SettingsService(),
                            builder: (context, _) {
                              final st = SettingsService().homeBannerStyle;
                              return _RecommendBanner(
                                key: ValueKey('banner-${st.index}'),
                                style: st,
                                videos: homeVideos.length > 6
                                    ? homeVideos.sublist(0, 6)
                                    : List<Video>.from(homeVideos),
                              );
                            },
                          ),
                  ),
                ),
                if (sorts.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppTheme.spacingLG,
                        AppTheme.spacingXS,
                        AppTheme.spacingLG,
                        AppTheme.spacingXS,
                      ),
                      child: _buildCategoryTabBar(),
                    ),
                  ),
                // 内联筛选芯片行（截图样式）：「筛选 → 隐藏筛选」可关掉它
                SliverToBoxAdapter(
                  child: Obx(() {
                    if (PlayerPrefs.instance.hideFilters.value) {
                      return const SizedBox.shrink();
                    }
                    return _buildInlineFilters();
                  }),
                ),
                SliverPadding(
                  // 底部 padding 改为 0：内容区下探到底，一屏显示更多卡片
                  //（用户要求对齐参考图"内容贴底"；原本 80 是给悬浮导航让位，现按用户指示取消）
                  padding: const EdgeInsets.fromLTRB(
                    AppTheme.spacingXL,
                    AppTheme.spacingMD,
                    AppTheme.spacingXL,
                    0,
                  ),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      childAspectRatio: ratio,
                      crossAxisSpacing: AppTheme.cardSpacing,
                      mainAxisSpacing: AppTheme.cardSpacing,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        if (index >= videos.length) {
                          if (hasMore && selectedSortId != null) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _controller.loadMore();
                            });
                            return Center(
                              child: Padding(
                                padding: EdgeInsets.all(8.0),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppTheme.accentColor),
                                ),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        }
                        final vid = videos[index];
                        return VodCard(
                          video: vid,
                          // 与上面的 posterRatio 配套（首页卡片高度 ×2）
                          posterHeightRatio: 1.44,
                          onTap: () => Get.toNamed('/detail', arguments: vid),
                        );
                      },
                      childCount: videos.length +
                          ((hasMore && selectedSortId != null) ? 1 : 0),
                    ),
                  ),
                ),
              ],
            );
            },
          );
        }),
      );
    });
  }

  void _openConfigCenterUrl(Video video) {
    String? openUrl;
    if (video.pic.startsWith('http')) {
      openUrl = video.pic;
      // 尝试解码 proxy URL 中的 base64 编码
      final proxyMatch = RegExp(r'/proxy/([A-Za-z0-9+/=]+)').firstMatch(video.pic);
      if (proxyMatch != null) {
        final encoded = proxyMatch.group(1);
        if (encoded != null) {
          try {
            final decoded = utf8.decode(base64Decode(encoded));
            if (decoded.startsWith('http')) {
              openUrl = decoded;
            }
          } catch (e) { /* ignore */ }
        }
      }
    }

    if (openUrl != null) {
      // 在**应用内**打开 WebView（替代 url_launcher 跳外部浏览器），
      // 让用户保持 TVBox 上下文，符合"配置中心"的语义。
      Get.to(
        () => InAppWebViewPage(
          url: openUrl!,
          title: '配置中心',
        ),
        transition: Transition.cupertino,
      );
    }
  }
}

/// 首页顶部推荐横幅（自动轮播）。样式由「设置 → 主页页面 → 首页幻灯片」切换：
///   · `wide` 横版大图（原样式）：16:9 大图 + 左下标题 + 右下来源角标
///   · `cards` 卡片轮播：竖版海报居中放大，两侧缩小 / 倾斜 / 压暗（coverflow / V 形）
///   · `hero` 沉浸大图：满宽出血 + 底部重渐变 + 大字标题 + 元信息 + 播放钮，
///            指示器换成**分段进度条**（参考 Disney+ hero carousel）
///   · `feature` 主次三栏：左边一张大竖版海报 + 右侧竖排 3 条小卡（杂志排版）
///   · `grid` 双排海报：**2 行 × 3 列 = 6 张**竖版海报（发现墙）
///
/// ⚠️ 各样式 `viewportFraction` 不同，而它**只能在 PageController 构造时**给
/// → 切换样式时由调用方换 `key`，让整个 State + PageController 重建
///   （见 home/view 的调用点）。
const double _kBannerWideHeight = 196;

// ── 卡片轮播的尺寸（对齐参考图的比例，不是在真机上量的，但关系是对的）──
//   · 中心卡 ≈ 0.44 屏宽、竖版（170×250，比例 0.68）
//   · 侧卡缩到 0.62 → ≈105 宽，与参考图里"两侧小卡完整露出、只被屏幕边裁一点"
//     一致 ⇒ 页间距（viewportFraction）要**小于**卡宽，卡才会比自己的槽位宽、
//     互相轻微叠压（这正是 coverflow 的关键，参考图里中心卡压着两侧卡）。
// 用户 2026-10-13：「卡片幻灯片之间的间距小一点」⇒ 页间距调小（0.34→0.30），
// 中心卡与两侧卡叠压更多、整体更紧凑。
const double _kBannerCardsViewport = 0.30; // ≈0.30 屏宽的页间距
const double _kBannerCardsCardW = 170;
const double _kBannerCardsCardH = 250;
const double _kBannerCardsHeight = 282; // 画布：卡 250 + 两侧下沉/缩放的余量

// ── 沉浸大图（hero）──
//   满宽出血（viewportFraction 1.0）⇒ 画面顶到屏幕两边，文字全部压在渐变上。
//   高度比 wide 高一档，给"大字标题 + 元信息 + 播放钮"留出呼吸。
const double _kBannerHeroHeight = 236;

// ── 主次三栏（feature）──
//   一页 = 左边**一张大竖版海报**（约 42% 宽，2:3）+ 右侧**竖排 3 条小卡**
//   （缩略图 + 标题 + 角标）。杂志排版：一条主推 + 三条次要。
const double _kBannerFeatureHeight = 250;
const int _kBannerFeaturePerPage = 4; // 1 大 + 3 小

// ── 双排海报（grid）──
//   一页 = **2 行 × 3 列 = 6 张**竖版海报（名称压在图上）。
//
//   ── 为什么换掉原来的「三格海报轨」（用户 2026-10-14：「太丑」）──
//   原来一页只有 3 张、被压在一行里，看着像缩略图列表；而且整块矮（198）
//   显得空。现在两行铺满：海报 ≈114×146（≈3:4），一屏 6 条 ✓。
const double _kBannerGridHeight = 300;
const int _kBannerGridPerPage = 6;
const int _kBannerGridCols = 3;

// ── 左右双卡（duo，2026-10-15 新增）──
//   一页 = **2 张竖版大海报并排**，整屏高度。张数最少、单张最大。
const double _kBannerDuoHeight = 300;
const int _kBannerDuoPerPage = 2;

// ── 九宫格（nine，2026-10-15 新增）──
//   一页 = **3 行 × 3 列 = 9 张**小海报。与「双排海报」（2×3=6）拉开密度差。
const double _kBannerNineHeight = 380;
const int _kBannerNinePerPage = 9;
const int _kBannerNineCols = 3;

// ── 交错瀑布（masonry，2026-10-15 新增）──
//   2 列错位：左边 1 张**满高**大卡，右边上下 2 张短卡。
const double _kBannerMasonryHeight = 300;
const int _kBannerMasonryPerPage = 3;

class _RecommendBanner extends StatefulWidget {
  final List<Video> videos;
  final HomeBannerStyle style;

  const _RecommendBanner({
    super.key,
    required this.videos,
    this.style = HomeBannerStyle.wide,
  });

  @override
  State<_RecommendBanner> createState() => _RecommendBannerState();
}

class _RecommendBannerState extends State<_RecommendBanner>
    with SingleTickerProviderStateMixin {
  /// 循环轮播的起始**绝对**页（取足够大的整数，前后都能滑，实现无限循环）
  static const int _kLoopAnchor = 100000;

  /// 一页几条：分组样式（主次三栏 / 双排海报 / 左右双卡 / 九宫格 / 交错瀑布）
  /// 一页多条，其余一页一条。
  int get _perPage => switch (widget.style) {
        HomeBannerStyle.feature => _kBannerFeaturePerPage,
        HomeBannerStyle.grid => _kBannerGridPerPage,
        HomeBannerStyle.duo => _kBannerDuoPerPage,
        HomeBannerStyle.nine => _kBannerNinePerPage,
        HomeBannerStyle.masonry => _kBannerMasonryPerPage,
        _ => 1,
      };

  /// 页数：分组样式按"几条一页"分组，其余一条一页。
  int get _pageCount {
    final len = widget.videos.length;
    if (len <= 0) return 0;
    final per = _perPage;
    return per > 1 ? (len / per).ceil() : len;
  }

  /// 分组样式**不做无限循环**：分组后取模会错位（组数常常不是条数的约数）。
  bool get _loops => _perPage <= 1;

  /// 起始绝对页：取页数的整数倍，保证首屏显示的是第 0 页
  int get _loopStart {
    final n = _pageCount;
    if (!_loops || n <= 0) return 0;
    return (_kLoopAnchor ~/ n) * n;
  }

  late final PageController _pageCtrl = PageController(
    initialPage: _loopStart,
    // 各样式页宽不同；切换样式时调用方会换 key ⇒ 整个 State 重建，这里只读一次
    viewportFraction: switch (widget.style) {
      HomeBannerStyle.cards => _kBannerCardsViewport,
      HomeBannerStyle.hero => 1.0, // 满宽出血
      HomeBannerStyle.feature => 1.0, // 一页 = 整屏（1 大 + 3 小）
      HomeBannerStyle.grid => 1.0, // 一页 = 整屏（6 张）
      HomeBannerStyle.duo => 1.0, // 一页 = 整屏（2 张大）
      HomeBannerStyle.nine => 1.0, // 一页 = 整屏（9 张）
      HomeBannerStyle.masonry => 1.0, // 一页 = 整屏（1 大 + 2 短）
      HomeBannerStyle.wide => 0.92,
    },
  );

  /// 当前**绝对**页（无限递增/递减）。数据下标 = `_page % length`。
  int _page = 0;

  /// 当前数据下标（圆点用）；`rail` 下 = 当前分组下标
  int get _index {
    final n = _pageCount;
    if (n <= 0) return 0;
    return _loops ? _page % n : _page;
  }

  /// hero 的分段进度条：把"距离下次自动翻页的 5 秒"画成当前段的填充。
  /// ⚠️ 只在 hero 下 forward（见 [_restartAuto]）—— 其它样式常驻跑动画
  ///    等于白白让 App 永远不进入空闲帧。
  bool get _usesProgressBar => widget.style == HomeBannerStyle.hero;
  late final AnimationController _progress;

  Timer? _autoTimer;

  /// （重）启动自动翻页：与进度条同一节拍。
  /// 手动滑动 / 换源后也调它 —— 否则"刚滑完 1 秒就自动跳走"。
  void _restartAuto() {
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(const Duration(seconds: 5), (_) => _advance());
    if (_usesProgressBar) _progress.forward(from: 0);
  }

  void _advance() {
    if (!mounted || widget.videos.isEmpty || !_pageCtrl.hasClients) return;
    _pageCtrl.nextPage(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
    );
  }

  @override
  void initState() {
    super.initState();
    // 在这里建（而不是 late 懒建）：dispose 里要无条件 dispose 它，
    // 懒建会在"从未用过进度条"的样式下**在 dispose 里才创建**一个控制器。
    _progress = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
    _page = _loopStart;
    _restartAuto();
  }

  @override
  void didUpdateWidget(covariant _RecommendBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换源后 homeVideos 会整体替换（数量/顺序都可能变），而 State 被复用：
    // 不重置绝对页就会让 % length 映射到错误的数据下标（圆点错位）。
    //
    // ⚠️ 只能比「长度 + 首条 id」，不能比对象 identity：父组件每次 rebuild 都
    // 传新建的 List（sublist / List.from），用 identical 会每帧都重置回第一页。
    final oldFirst = oldWidget.videos.isEmpty ? '' : oldWidget.videos.first.id;
    final newFirst = widget.videos.isEmpty ? '' : widget.videos.first.id;
    if (oldWidget.videos.length != widget.videos.length ||
        oldFirst != newFirst) {
      _page = _loopStart;
      if (_pageCtrl.hasClients) {
        _pageCtrl.jumpToPage(_page);
      }
      _restartAuto(); // 节拍跟着重来（否则进度条与新内容不同步）
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _progress.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.videos.isEmpty) return const SizedBox.shrink();
    final style = widget.style;
    return Column(
      children: [
        SizedBox(
          height: switch (style) {
            HomeBannerStyle.wide => _kBannerWideHeight,
            HomeBannerStyle.cards => _kBannerCardsHeight,
            HomeBannerStyle.hero => _kBannerHeroHeight,
            HomeBannerStyle.feature => _kBannerFeatureHeight,
            HomeBannerStyle.grid => _kBannerGridHeight,
            HomeBannerStyle.duo => _kBannerDuoHeight,
            HomeBannerStyle.nine => _kBannerNineHeight,
            HomeBannerStyle.masonry => _kBannerMasonryHeight,
          },
          child: PageView.builder(
            controller: _pageCtrl,
            // 分组样式有固定页数；其余不传 itemCount = 无限循环（用户 2026-10-13）
            itemCount: _loops ? null : _pageCount,
            onPageChanged: (i) {
              setState(() => _page = i);
              _restartAuto(); // 手动滑完重新计时，避免"刚滑 1 秒就被自动跳走"
            },
            itemBuilder: (_, i) => switch (style) {
              HomeBannerStyle.cards => _coverflowItem(context, i),
              HomeBannerStyle.hero => _heroItem(context, i),
              HomeBannerStyle.feature => _featurePage(context, i),
              HomeBannerStyle.grid => _gridPage(context, i),
              HomeBannerStyle.duo => _duoPage(context, i),
              HomeBannerStyle.nine => _ninePage(context, i),
              HomeBannerStyle.masonry => _masonryPage(context, i),
              HomeBannerStyle.wide => _wideItem(context, i),
            },
          ),
        ),
        const SizedBox(height: 10),
        _indicator(),
      ],
    );
  }

  /// 指示器：hero 用**分段进度条**，其余用圆点（rail 按分组数）。
  Widget _indicator() {
    final n = _pageCount;
    if (n <= 1) return const SizedBox.shrink();
    if (_usesProgressBar) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: AnimatedBuilder(
          animation: _progress,
          builder: (_, __) => Row(
            children: [
              for (var i = 0; i < n; i++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: i == n - 1 ? 0 : 4),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: SizedBox(
                        height: 3,
                        child: Stack(
                          children: [
                            ColoredBox(
                              color: AppTheme.textTertiary
                                  .withValues(alpha: 0.28),
                              child: const SizedBox.expand(),
                            ),
                            if (i == _index)
                              FractionallySizedBox(
                                widthFactor: _progress.value.clamp(0.0, 1.0),
                                child: ColoredBox(
                                  color: AppTheme.accentColor,
                                  child: const SizedBox.expand(),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(n, (i) {
        final active = i == _index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: active ? 18 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: active
                ? AppTheme.accentColor
                : AppTheme.textTertiary.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }

  // ══════════════════════════════════════════════════════════
  // 各样式的一项
  // ══════════════════════════════════════════════════════════

  Video _videoAt(int i) => widget.videos[i % widget.videos.length];

  /// 横版大图（原样式）：16:9 铺满 + 左下标题 + 右下来源角标。
  Widget _wideItem(BuildContext context, int i) {
    final v = _videoAt(i);
    final badge = VodCard.badgeText(v);
    return GestureDetector(
      onTap: () => Get.toNamed('/detail', arguments: v),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: AppTheme.backgroundSecondary,
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 横版铺满（海报 cover，优先展示画面主体）
            _BannerImage(url: v.pic),
            // 底部渐变（只放标题，不重复叠名）
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 72,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.72),
                    ],
                  ),
                ),
              ),
            ),
            // 左下标题
            Positioned(
              left: 14,
              bottom: 12,
              right: 120,
              child: Text(
                v.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: AppTheme.fontTitle3,
                  fontWeight: FontWeight.w600,
                  shadows: [
                    Shadow(blurRadius: 8, color: Colors.black54),
                  ],
                ),
              ),
            ),
            // 右下半透明黑角标
            if (badge.isNotEmpty)
              Positioned(
                right: 12,
                bottom: 12,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppBrightness.isLight.value
                        ? Colors.black.withValues(alpha: 0.62)
                        : Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    badge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: AppTheme.fontCaption,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 沉浸大图（hero）：满宽出血 + 底部重渐变 + 大字标题 + 元信息 + 圆形播放钮。
  ///
  /// 与 `wide` 的区别不只是"更高"：这里**没有圆角/外框**（画面顶到两边）、
  /// 渐变更厚、标题大一档、并且多了一行"年份 · 类型 · 备注"和一枚播放按钮
  /// —— 就是 Disney+ 那套 hero 的观感。
  Widget _heroItem(BuildContext context, int i) {
    final v = _videoAt(i);
    // 元信息行：只拼非空项（源里经常缺年份/类型）
    final badge = VodCard.badgeText(v);
    final meta = <String>[
      if (v.year.trim().isNotEmpty) v.year.trim(),
      if (v.type.trim().isNotEmpty) v.type.trim(),
      if (badge.isNotEmpty) badge,
    ].join(' · ');

    return GestureDetector(
      onTap: () => Get.toNamed('/detail', arguments: v),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _BannerImage(url: v.pic),
          // 底部重渐变：给大字标题 + 元信息 + 按钮一个可读的底
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 140,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.55),
                    Colors.black.withValues(alpha: 0.88),
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 76,
            bottom: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  v.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(blurRadius: 10, color: Colors.black54)],
                  ),
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.78),
                      fontSize: AppTheme.fontCaption + 0.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // 右下圆形播放钮（整卡也可以点，这枚是"能播"的视觉暗示）
          Positioned(
            right: 16,
            bottom: 16,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.92),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                size: 26,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }


  /// 一张竖版海报瓦片（**名称压在图上**）—— 「双排海报」与「主次三栏」共用。
  ///
  /// 左上角是角标（更新到第 N 集 / 完结…），底部一行名称 + 一层压暗渐变
  /// （白字直接压在彩色海报上会糊）。
  Widget _posterTile(BuildContext context, Video v, {BorderRadius? radius}) {
    final badge = VodCard.badgeText(v);
    return GestureDetector(
      onTap: () => Get.toNamed('/detail', arguments: v),
      child: ClipRRect(
        borderRadius: radius ?? BorderRadius.circular(14),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: AppTheme.backgroundSecondary,
              child: _BannerImage(url: v.pic),
            ),
            // 底部压暗：保证白字可读
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 62,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.78),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 7,
              child: Text(
                v.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                ),
              ),
            ),
            if (badge.isNotEmpty)
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    badge,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: AppTheme.fontCaption - 1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 双排海报（grid）：一页 = **2 行 × 3 列 = 6 张**竖版海报。
  ///
  /// ── 为什么换掉原来的「三格海报轨」（用户 2026-10-14：「太他妈丑」）──
  /// 原来一页只有 3 张、被压在一行里、整块还矮（198）⇒ 看着像缩略图列表、
  /// 又空又小 ✗。现在**两行铺满**：海报 ≈114×146（≈3:4），一屏 6 条 ✓，
  /// 名称也压进图里（不再在图片外单占一行）✓。
  Widget _gridPage(BuildContext context, int i) {
    final start = i * _kBannerGridPerPage;
    const rows = 2;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (var r = 0; r < rows; r++) ...[
            if (r > 0) const SizedBox(height: 8),
            Expanded(
              child: Row(
                children: [
                  for (var c = 0; c < _kBannerGridCols; c++) ...[
                    if (c > 0) const SizedBox(width: 8),
                    Expanded(
                      child: _tileAt(start + r * _kBannerGridCols + c),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 左右双卡（duo，2026-10-15 新增）：一页 = **2 张竖版大海报并排**，整屏高。
  /// 张数最少、单张最大 —— 与「双排海报」的 6 张 / 「九宫格」的 9 张形成密度梯度。
  Widget _duoPage(BuildContext context, int i) {
    final start = i * _kBannerDuoPerPage;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (var c = 0; c < _kBannerDuoPerPage; c++) ...[
            if (c > 0) const SizedBox(width: 10),
            Expanded(
              child: _tileAt(start + c, radius: BorderRadius.circular(16)),
            ),
          ],
        ],
      ),
    );
  }

  /// 九宫格（nine，2026-10-15 新增）：一页 = **3 行 × 3 列 = 9 张**小海报。
  /// 一眼看得最多，和「双排海报」（2×3=6）拉开密度差。
  Widget _ninePage(BuildContext context, int i) {
    final start = i * _kBannerNinePerPage;
    const rows = 3;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (var r = 0; r < rows; r++) ...[
            if (r > 0) const SizedBox(height: 8),
            Expanded(
              child: Row(
                children: [
                  for (var c = 0; c < _kBannerNineCols; c++) ...[
                    if (c > 0) const SizedBox(width: 8),
                    Expanded(
                      child: _tileAt(start + r * _kBannerNineCols + c),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 交错瀑布（masonry，2026-10-15 新增）：左边 1 张**满高**大卡 +
  /// 右边上下 2 张短卡。比"规整网格"更有节奏感。
  Widget _masonryPage(BuildContext context, int i) {
    final start = i * _kBannerMasonryPerPage;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: _tileAt(start, radius: BorderRadius.circular(16)),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Column(
              children: [
                Expanded(
                  child: _tileAt(start + 1,
                      radius: BorderRadius.circular(14)),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _tileAt(start + 2,
                      radius: BorderRadius.circular(14)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 主次三栏（feature）：一页 = **左边一张大竖版海报 + 右侧竖排 3 条小卡**。
  ///
  /// 杂志排版：一条主推 + 三条次要。信息密度比"一排海报"高，观感也和
  /// 横版大图 / 卡片轮播 / 沉浸大图 都不重复 ✓。
  Widget _featurePage(BuildContext context, int i) {
    final start = i * _kBannerFeaturePerPage;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 左：大竖版海报（≈42% 屏宽，250 高 ⇒ 约 2:3 ✓ 标准海报比例）
          SizedBox(
            width: MediaQuery.of(context).size.width * 0.42,
            child: _tileAt(start, radius: BorderRadius.circular(16)),
          ),
          const SizedBox(width: 10),
          // 右：竖排 3 条小卡
          Expanded(
            child: Column(
              children: [
                for (var k = 1; k < _kBannerFeaturePerPage; k++) ...[
                  if (k > 1) const SizedBox(height: 8),
                  Expanded(child: _featureRowAt(start + k)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 取第 [idx] 条的海报瓦片；越界（最后不满一页）留白，不越界取值。
  Widget _tileAt(int idx, {BorderRadius? radius}) {
    if (idx < 0 || idx >= widget.videos.length) return const SizedBox.shrink();
    return _posterTile(context, widget.videos[idx], radius: radius);
  }

  /// 主次三栏右侧的一条小卡：缩略图 + 标题 + 角标。
  Widget _featureRowAt(int idx) {
    if (idx < 0 || idx >= widget.videos.length) return const SizedBox.shrink();
    final v = widget.videos[idx];
    final badge = VodCard.badgeText(v);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Get.toNamed('/detail', arguments: v),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 56,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ColoredBox(
                color: AppTheme.backgroundSecondary,
                child: _BannerImage(url: v.pic),
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  v.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontFootnote + 0.5,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                if (badge.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    badge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption - 0.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 卡片轮播的一项：竖版海报 + 底部标题 + 右上角标。
  ///
  /// 按与当前页的**连续**距离 `delta` 做 缩放 / 侧倾 / 后退 / 下沉 / 压暗 ——
  /// 拖动过程中 `page` 是小数，所以这些变化是平滑的（不会只在翻页那一刻跳变）。
  ///
  /// 用户 2026-10-13：「整体带 V 形的那种切换形式」⇒ 加大两侧的侧倾与下沉，
  /// 并让两侧向后退（Z 轴），中心卡前凸、两侧后收下坠，整体呈 **V 形**。
  Widget _coverflowItem(BuildContext context, int i) {
    final v = widget.videos[i % widget.videos.length];
    final badge = VodCard.badgeText(v);

    double page = _page.toDouble();
    if (_pageCtrl.hasClients && _pageCtrl.position.haveDimensions) {
      page = _pageCtrl.page ?? page;
    }
    final delta = (i - page).clamp(-1.5, 1.5);
    final absD = delta.abs().clamp(0.0, 1.0);
    // 中间卡略放大、两侧缩到 0.62 —— 落差本身就是 V 形的观感来源
    final scale = 1.04 - 0.42 * absD;
    final rotY = -0.26 * delta; // 两侧 ±≈15° 侧倾（V 形的两条斜边）
    final dy = 26.0 * absD; // 两侧下沉（V 形的下坠）
    final dz = -60.0 * absD; // 两侧后退（透视里更「远」，强化纵深）
    final dim = (1 - 0.45 * absD).clamp(0.0, 1.0); // 两侧压暗到 0.55

    return Transform(
      alignment: Alignment.center,
      // ⚠️ **顺序就是效果本身，不要调换**（2026-10-14 修的真 bug）：
      //   `Matrix4` 是**后乘**，几何按**从右往左**依次作用，所以这里实际是
      //     scale（缩放卡）→ rotateY（侧倾）→ translate（整体位移）→ 透视投影
      //
      //   旧写法把 `translate` 写在最后（= 几何上最先作用），位移会被紧接着的
      //   `scale` 再乘一遍：`dy = 18` 真正只沉了 `18 × 0.62 ≈ 11px`，
      //   在 282 高的画布上几乎看不出来 —— 这就是"代码写着 V 形、真机上却是
      //   三张齐平"的原因（用户 2026-10-14：「按上次的来」，即要 V 形效果）。
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0012) // 透视
        ..translate(0.0, dy, dz)
        ..rotateY(rotY)
        ..scale(scale),
      child: Opacity(
        opacity: dim,
        // 卡宽由槽位（viewportFraction 0.30 ≈ 117pt）决定：`Center` 会把下面那个
        // `SizedBox(width: 170)` 约束回槽位宽度，所以**三张卡是紧挨着、不重叠**的。
        // 中间那张靠「更大 + 不压暗 + 投影落在两侧卡上」拉出层次，
        // 不去做真正的叠压 —— PageView 的绘制顺序是按下标来的，
        // 真叠压时**右侧**那张会盖在中间卡上（左侧不会），反而不像"中间在最上层"。
        child: Center(
          child: SizedBox(
            width: _kBannerCardsCardW,
            height: _kBannerCardsCardH,
            child: GestureDetector(
              onTap: () => Get.toNamed('/detail', arguments: v),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: AppTheme.backgroundSecondary,
                  border:
                      Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 16,
                        offset: const Offset(0, 8)),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _BannerImage(url: v.pic),
                    // 底部渐变 + 标题（竖版海报也要能一眼看出片名）
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 76,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.78),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 10,
                      child: Text(
                        v.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: AppTheme.fontFootnote,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                          shadows: [
                            Shadow(blurRadius: 8, color: Colors.black54)
                          ],
                        ),
                      ),
                    ),
                    if (badge.isNotEmpty)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            badge,
                            maxLines: 1,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: AppTheme.fontCaption,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BannerImage extends StatelessWidget {
  final String url;
  const _BannerImage({required this.url});

  @override
  Widget build(BuildContext context) {
    final pic = url.trim();
    if (pic.isEmpty || !pic.startsWith('http')) {
      return ColoredBox(
        color: AppTheme.backgroundTertiary,
        child: Center(
          child: Icon(Icons.movie_filter_outlined,
              color: AppTheme.textTertiary, size: 40),
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: pic,
      // fill = 拉伸填满，**保证整张图都显示出来**（cover 会把海报两侧裁掉，
      // 用户反馈"图片显示不全"）。允许变形，不允许裁切。
      fit: BoxFit.fill,
      placeholder: (_, __) => ColoredBox(color: AppTheme.backgroundTertiary),
      errorWidget: (_, __, ___) => ColoredBox(
        color: AppTheme.backgroundTertiary,
        child: Icon(Icons.broken_image_outlined, color: AppTheme.textTertiary),
      ),
    );
  }
}


/// 分类胶囊
class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  const _CategoryChip({required this.label, required this.selected});

  @override
  Widget build(BuildContext context) {
    // 用户 2026-10-13：「影视那个分类也加个椭圆的卡片背景」⇒ 由「纯文字 + 下划线」
    // 改成**椭圆胶囊卡片**：选中 = 强调色实底 + 白字，未选中 = 次级底 + 次级字。
    // 样式与小程序详情页的分类 chip、阅读模块筛选 chip 统一。
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? AppTheme.accentColor : AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(999), // 椭圆胶囊
        border: Border.all(
          color: selected
              ? AppTheme.accentColor
              : AppTheme.glassBorderSoft,
          width: 0.6,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.white : AppTheme.textSecondary,
          fontSize: AppTheme.fontSubhead,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}
/// 首页时钟 - 对应 Swift HomeClockView
class _HomeClockView extends StatefulWidget {
  const _HomeClockView();

  @override
  State<_HomeClockView> createState() => _HomeClockViewState();
}

class _HomeClockViewState extends State<_HomeClockView> {
  late DateTime _now;
  late final Stream<DateTime> _stream;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _stream = Stream.periodic(
      const Duration(seconds: 1),
      (_) => DateTime.now(),
    );
  }

  String _formatDate(DateTime date) {
    final weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final weekday = weekdays[date.weekday - 1];
    final h = date.hour.toString().padLeft(2, '0');
    final m = date.minute.toString().padLeft(2, '0');
    return '${date.month}/${date.day} 周$weekday $h:$m';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DateTime>(
      stream: _stream,
      builder: (context, snapshot) {
        final date = snapshot.data ?? _now;
        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spacingMD,
            vertical: AppTheme.spacingSM,
          ),
          decoration: BoxDecoration(
            color: AppTheme.backgroundElevated,
            borderRadius: BorderRadius.circular(AppTheme.radiusMD),
            border: Border.all(
              color: AppTheme.borderLight,
              width: 0.5,
            ),
          ),
          child: Text(
            _formatDate(date),
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontFootnote,
              fontWeight: FontWeight.w500,
              fontFamily: 'monospace',
            ),
          ),
        );
      },
    );
  }
}


/// 猫爪 Logo（品牌图标）
class _CatPawLogo extends StatelessWidget {
  const _CatPawLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppTheme.accentColor.withValues(alpha: 0.65), AppTheme.accentColor],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: AppTheme.accentColor.withValues(alpha: 0.35),
            blurRadius: 10,
          ),
        ],
      ),
      child: const Icon(Icons.pets, color: Colors.white, size: 20),
    );
  }
}


/// 轮播占位：无缓存首启时避免顶部空一块
class _BannerPlaceholder extends StatelessWidget {
  const _BannerPlaceholder();
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 196,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: AppTheme.backgroundTertiary,
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_filter_outlined,
                color: AppTheme.textTertiary, size: 36),
            const SizedBox(height: 8),
            Text('正在加载推荐…',
                style: TextStyle(color: AppTheme.textTertiary, fontSize: AppTheme.fontSubhead)),
          ],
        ),
      ),
    );
  }
}
