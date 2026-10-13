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
                    // 名称间距收紧（原 spacingSM=8，现 2）
                    padding: const EdgeInsets.only(right: 2),
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
              // 底部筛选菜单的原生入口（原来只有 RFW 主题能调起来，见方法注释）
              _optionTile(
                icon: Icons.tune,
                label: '筛选条件',
                onTap: () {
                  Navigator.pop(ctx);
                  _openFilterSheet();
                },
              ),
              _optionTile(
                icon: Icons.block,
                label: '分类屏蔽',
                onTap: () {
                  Navigator.pop(ctx);
                  _openCategoryBlockSheet();
                },
              ),
              _optionTile(
                icon: Icons.filter_alt_outlined,
                label: prefs.hideFilters.value ? '显示筛选' : '隐藏筛选',
                onTap: () async {
                  Navigator.pop(ctx);
                  await prefs.setHideFilters(!prefs.hideFilters.value);
                  setSheet(() {});
                },
              ),
              _optionTile(
                icon: Icons.grid_view,
                label: '切换布局',
                onTap: () {
                  Navigator.pop(ctx);
                  _openLayoutSheet();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      )),
    );
  }

  Widget _optionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppTheme.textPrimary),
            const SizedBox(width: 16),
            Text(label,
                style: TextStyle(
                    color: AppTheme.textPrimary, fontSize: AppTheme.fontHeadline)),
          ],
        ),
      ),
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
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final s in _controller.sorts)
                            SelectableChip(
                              title: s.name,
                              isSelected:
                                  prefs.blockedCategories.contains(s.name),
                              onTap: () =>
                                  prefs.toggleBlockCategory(s.name),
                            ),
                        ],
                      ),
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
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
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
                                      onTap: () => _controller
                                          .selectFilter(f.key, v.v),
                                    ),
                                ],
                              ),
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

/// 首页顶部推荐横幅（自动轮播）。两种样式，由「设置 → 菜单设置 → 首页幻灯片」切换：
///   · `wide`  横版大图（原样式）：16:9 大图 + 左下标题 + 右下来源角标
///   · `cards` 卡片轮播（新增）：竖版海报居中放大，两侧海报缩小 / 倾斜 / 压暗露出
///            （coverflow 观感，对齐用户 2026-10-13 给的参考图）
///
/// ⚠️ 两种样式的 `viewportFraction` 不同，而它**只能在 PageController 构造时**给
/// → 切换样式时由调用方换 `key`，让整个 State + PageController 重建
///   （见 home/view 的调用点）。
const double _kBannerWideHeight = 196;

// ── 卡片轮播的尺寸（对齐参考图的比例，不是在真机上量的，但关系是对的）──
//   · 中心卡 ≈ 0.44 屏宽、竖版（170×250，比例 0.68）
//   · 侧卡缩到 0.62 → ≈105 宽，与参考图里"两侧小卡完整露出、只被屏幕边裁一点"
//     一致 ⇒ 页间距（viewportFraction）要**小于**卡宽，卡才会比自己的槽位宽、
//     互相轻微叠压（这正是 coverflow 的关键，参考图里中心卡压着两侧卡）。
const double _kBannerCardsViewport = 0.34; // ≈0.34 屏宽的页间距
const double _kBannerCardsCardW = 170;
const double _kBannerCardsCardH = 250;
const double _kBannerCardsHeight = 282; // 画布：卡 250 + 两侧下沉/缩放的余量

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

class _RecommendBannerState extends State<_RecommendBanner> {
  late final PageController _pageCtrl = PageController(
    viewportFraction:
        widget.style == HomeBannerStyle.cards ? _kBannerCardsViewport : 0.92,
  );
  int _index = 0;
  Timer? _autoTimer;

  @override
  void initState() {
    super.initState();
    _autoTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || widget.videos.isEmpty || !_pageCtrl.hasClients) return;
      final len = widget.videos.length;
      // 防御：_index 可能因列表变化越界，取模前先夹紧
      final cur = _index.clamp(0, len - 1);
      final next = (cur + 1) % len;
      _pageCtrl.animateToPage(
        next,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void didUpdateWidget(covariant _RecommendBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换源后 homeVideos 会整体替换（数量/顺序都可能变），而 State 被复用：
    // _index 不重置就会越界（圆点全灭 + 自动轮播跳页），PageController 也可能
    // 停在已不存在的位置。
    //
    // ⚠️ 只能比「长度 + 首条 id」，不能比对象 identity：父组件每次 rebuild 都
    // 传新建的 List（sublist / List.from），用 identical 会每帧都重置回第一页。
    final oldFirst = oldWidget.videos.isEmpty ? '' : oldWidget.videos.first.id;
    final newFirst = widget.videos.isEmpty ? '' : widget.videos.first.id;
    if (oldWidget.videos.length != widget.videos.length ||
        oldFirst != newFirst) {
      _index = 0;
      if (_pageCtrl.hasClients) {
        _pageCtrl.jumpToPage(0);
      }
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.videos.isEmpty) return const SizedBox.shrink();
    final cards = widget.style == HomeBannerStyle.cards;
    return Column(
      children: [
        SizedBox(
          // wide：横版 16:9 观感；cards：竖版海报轮播需要的更高画布
          height: cards ? _kBannerCardsHeight : _kBannerWideHeight,
          child: PageView.builder(
            controller: _pageCtrl,
            itemCount: widget.videos.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) {
              if (cards) return _coverflowItem(context, i);
              final v = widget.videos[i];
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
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
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
            },
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(widget.videos.length, (i) {
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
        ),
      ],
    );
  }

  /// 卡片轮播的一项：竖版海报 + 底部标题 + 右上角标。
  ///
  /// 按与当前页的**连续**距离 `delta` 做 缩放 / 侧倾 / 下沉 / 压暗 ——
  /// 拖动过程中 `page` 是小数，所以这些变化是平滑的（不会只在翻页那一刻跳变）。
  Widget _coverflowItem(BuildContext context, int i) {
    final v = widget.videos[i];
    final badge = VodCard.badgeText(v);

    double page = _index.toDouble();
    if (_pageCtrl.hasClients && _pageCtrl.position.haveDimensions) {
      page = _pageCtrl.page ?? page;
    }
    final delta = (i - page).clamp(-1.5, 1.5);
    final absD = delta.abs().clamp(0.0, 1.0);
    final scale = 1 - 0.38 * absD; // 两侧缩到 0.62（对齐参考图里的小卡）
    final rotY = -0.16 * delta; // 两侧 ±9° 侧倾
    final dy = 12.0 * absD; // 两侧轻微下沉
    final dim = (1 - 0.45 * absD).clamp(0.0, 1.0); // 两侧压暗

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0012) // 透视
        ..rotateY(rotY)
        ..scale(scale)
        ..translate(0.0, dy),
      child: Opacity(
        opacity: dim,
        // 卡比自己的槽位（viewportFraction 0.34 ≈ 133）宽 → 居中后轻微叠压两侧，
        // 形成参考图那种"中心卡压住两侧卡"的层次
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
    // 去掉胶囊背景卡片：分类名直接排版，只用「文字色 + 下划线」表达选中。
    // 原来的 backgroundTertiary 胶囊在浅色模式下是一块灰底，且描边写死白色
    // （Colors.white.withValues(...)）→ 切外观时看起来"没跟着变"。
    return Container(
      alignment: Alignment.bottomCenter,
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            label,
            style: TextStyle(
              color: selected ? AppTheme.accentColor : AppTheme.textSecondary,
              fontSize: AppTheme.fontSubhead,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          const SizedBox(height: 4),
          // 选中下划线（未选中占位，避免文字上下跳动）
          AnimatedContainer(
            duration: AppTheme.motionFast,
            curve: AppTheme.motionCurve,
            width: selected ? 18 : 0,
            height: 2.5,
            decoration: BoxDecoration(
              color: AppTheme.accentColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
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
