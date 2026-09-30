import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../services/player_prefs.dart';
import '../shelf/controller.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:rfw/rfw.dart' show DynamicMap;
import '../../services/api_config.dart';
import '../../services/app_log.dart';
import '../../services/rfw_theme_service.dart';
import '../../models/movie.dart';
import '../../router/app_pages.dart';
import '../../services/main_tab_controller.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/rfw/rfw_home_view.dart';
import '../../widgets/source_switch_sheet.dart';
import '../../widgets/vod_card.dart';
import '../webview/view.dart';
import 'controller.dart';

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

  /// 筛选面板显隐。
  ///
  /// 现在筛选走「分类栏右端筛选按钮 → 底部弹出菜单」（见 _openFilterSheet）。
  /// 这个字段只作为 RFW 主题数据契约里的开关位保留，供自定义主题使用。
  bool _showFilters = false;

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
          SafeArea(
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
            const SizedBox(
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
          const Spacer(),
          // 右：可伸长搜索（小框 → 展开输入）
          _ExpandableSearch(
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) {
                Get.toNamed('/search', arguments: v.trim());
              } else if (widget.onSearchTap != null) {
                widget.onSearchTap!();
              } else {
                Get.toNamed('/search');
              }
            },
            onOpenFull: () {
              if (widget.onSearchTap != null) {
                widget.onSearchTap!();
              } else {
                Get.toNamed('/search');
              }
            },
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
          .where((e) => (e.value ?? '').isNotEmpty)
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

  /// 三项菜单：分类屏蔽 / 隐藏筛选 / 切换布局
  Future<void> _openOptionsMenu() async {
    final prefs = PlayerPrefs.instance;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
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
      ),
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
                    color: AppTheme.textPrimary, fontSize: 15)),
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
      builder: (ctx) => SafeArea(
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
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('勾选的分类将隐藏',
                        style: TextStyle(
                            color: AppTheme.textTertiary, fontSize: 11)),
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
      ),
    );
  }

  /// 切换布局：2 / 3 / 4 列
  Future<void> _openLayoutSheet() async {
    final prefs = PlayerPrefs.instance;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Text('切换布局',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            Obx(() => Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                  child: Wrap(
                    spacing: 10,
                    children: [
                      for (final n in const [2, 3, 4])
                        SelectableChip(
                          title: '$n 列',
                          isSelected: prefs.gridColumns.value == n,
                          onTap: () async {
                            await prefs.setGridColumns(n);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        ),
                    ],
                  ),
                )),
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
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 40,
                    child: Text(
                      f.name,
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          SelectableChip(
                            title: '全部',
                            isSelected:
                                _controller.selectedFilters[f.key] == null,
                            onTap: () => _controller.selectFilter(f.key, ''),
                          ),
                          const SizedBox(width: AppTheme.spacingSM),
                          for (final v in f.values) ...[
                            SelectableChip(
                              title: v.n,
                              isSelected:
                                  _controller.selectedFilters[f.key] == v.v,
                              onTap: () =>
                                  _controller.selectFilter(f.key, v.v),
                            ),
                            const SizedBox(width: AppTheme.spacingSM),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (f != groups.last) const SizedBox(height: AppTheme.spacingSM),
            ],
          ],
        ),
      );
    });
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
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Obx(() {
                        final picked = _controller.selectedFilters.entries
                            .where((e) => (e.value ?? '').isNotEmpty)
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
                                      fontSize: AppTheme.fontCaption,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  SelectableChip(
                                    title: '全部',
                                    isSelected: _controller
                                            .selectedFilters[f.key] ==
                                        null,
                                    onTap: () =>
                                        _controller.selectFilter(f.key, ''),
                                  ),
                                  for (final v in f.values)
                                    SelectableChip(
                                      title: v.n,
                                      isSelected: _controller
                                              .selectedFilters[f.key] ==
                                          v.v,
                                      onTap: () =>
                                          _controller.selectFilter(f.key, v.v),
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
      // ---- RFW 自定义首页主题 ----
      // 启用且有可用主题时，内容区交给主题渲染；主题坏了/没选主题则原样回退。
      // 放在这里（而不是 build 顶层）的原因：主题只应替换内容区，
      // 顶部搜索栏、分类 tab、筛选栏仍由 App 提供，保证这些原生入口始终可用。
      final rfwSource = RfwThemeService.instance.currentThemeSource;
      if (rfwSource.isNotEmpty) {
        return _buildRfwContentArea(rfwSource);
      }

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
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 列数优先用「筛选 → 切换布局」里的用户选择（2/3/4），
            // 没设过时才退回按宽度自适应的旧逻辑。
            final userCols = PlayerPrefs.instance.gridColumns.value;
            final crossAxisCount = userCols.clamp(2, 4);
            final cardWidth =
                (constraints.maxWidth -
                        AppTheme.cardSpacing * (crossAxisCount - 1)) /
                    crossAxisCount;

            return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(
                        top: AppTheme.spacingXS, bottom: 8),
                    child: homeVideos.isEmpty
                        ? const _BannerPlaceholder()
                        : _RecommendBanner(videos: homeVideos.length > 6
                            ? homeVideos.sublist(0, 6)
                            : List<Video>.from(homeVideos)),
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
                  padding: const EdgeInsets.fromLTRB(
                    AppTheme.spacingXL,
                    AppTheme.spacingMD,
                    AppTheme.spacingXL,
                    80,
                  ),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      childAspectRatio:
                          (cardWidth) / (cardWidth / 0.65 + 50),
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
                            return const Center(
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
        ),
      );
    });
  }

  // ============================================================
  // RFW 自定义首页主题
  // ============================================================

  /// 用当前主题渲染内容区。
  ///
  /// 主题可用的数据见 [RfwDataContract.build]；事件名来自 PeekPro 主题模板
  /// （openItem / refresh / selectType / selectFilter / openSearch /
  /// showSourcePicker / openHistory / openFavorite / openPush /
  /// showCategoryPicker / showDisplayStylePicker / showFilterPicker /
  /// longPressItem / openRecommend / toggleFilters / showApiConfigPicker /
  /// navigateBack）。
  Widget _buildRfwContentArea(String themeSource) {
    final c = _controller;
    final videos = c.videos.toList();
    final sorts = c.sorts.toList();
    final itemMaps = <Map<String, Object?>>[
      for (final v in videos)
        <String, Object?>{
          'id': v.id,
          'name': v.name,
          'pic': v.pic,
          'remarks': v.note,
          'year': v.year,
          'typeName': v.type,
          'typeId': v.tid,
          'sourceKey': v.sourceKey,
        },
    ];
    final classMaps = <Map<String, Object?>>[
      for (final s in sorts)
        <String, Object?>{
          'typeId': s.id,
          'typeName': s.name,
          'selected': s.id == c.selectedSort.value?.id,
        },
    ];
    final data = RfwDataContract.build(
      items: itemMaps,
      classes: classMaps,
      source: ApiConfig.instance.homeSourceBean.value?.name ?? '',
      loading: c.isLoading.value,
      errorMessage: c.errorMessage.value ?? '',
      isLandscape:
          MediaQuery.maybeOf(context)?.orientation == Orientation.landscape,
      selectedTypeId: c.selectedSort.value?.id ?? '',
      showFilters: _showFilters,
    );

    return RfwHomeView(
      themeSource: themeSource,
      data: data,
      onEvent: _onRfwEvent,
      // 主题渲染失败时回退原生网格。
      // 注意不能递归回 _buildContentArea（会无限递归），所以这里用
      // 「切回原生」的更简单做法：显示提示 + 让用户关掉主题。
      fallback: _buildRfwFallback(),
    );
  }

  /// 主题不可用时的兜底视图
  Widget _buildRfwFallback() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dashboard_customize_outlined,
                size: 40, color: AppTheme.textTertiary),
            const SizedBox(height: 12),
            Text(
              '当前主题无法渲染',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              RfwThemeService.instance.lastError.value.isEmpty
                  ? '主题缺少必要组件或 root 定义'
                  : RfwThemeService.instance.lastError.value,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(color: AppTheme.textTertiary, fontSize: 11.5),
            ),
          ],
        ),
      ),
    );
  }

  /// 把主题事件映射到 App 的实际动作。
  ///
  /// 事件参数用 `args.xxx` 从主题传入；缺失时尽量用当前状态兜底，
  /// 避免因主题少传参数就整个点不动。
  void _onRfwEvent(String name, DynamicMap args) {
    final c = _controller;
    switch (name) {
      case 'openItem':
      case 'openRecommend':
      case 'longPressItem':
        final id = '${args['id'] ?? args['vodId'] ?? ''}';
        final video = c.videos.firstWhereOrNull((v) => v.id == id) ??
            c.homeVideos.firstWhereOrNull((v) => v.id == id);
        if (video != null) {
          Get.toNamed(AppPages.detail, arguments: video);
        }
        break;

      case 'refresh':
        c.refresh();
        break;

      case 'selectType':
        final typeId = '${args['typeId'] ?? ''}';
        final sort = c.sorts.firstWhereOrNull((s) => s.id == typeId);
        if (sort != null) c.selectSort(sort);
        break;

      case 'selectFilter':
        final key = '${args['key'] ?? ''}';
        final value = '${args['value'] ?? ''}';
        if (key.isNotEmpty) c.selectFilter(key, value);
        break;

      case 'toggleFilters':
        // RFW 主题点了"筛选" → 直接打开底部筛选菜单（与右上筛选按钮一致）
        setState(() => _showFilters = !_showFilters);
        _openFilterSheet();
        break;

      case 'showSourcePicker':
        // 真实入口：底部源切换弹窗（与顶栏"换源"同一实现）
        SourceSwitchSheet.show(context);
        break;

      case 'showCategoryPicker':
      case 'showFilterPicker':
        // 主题里的「筛选」→ 打开三项菜单（分类屏蔽/隐藏筛选/切换布局）
        _openOptionsMenu();
        break;

      case 'showDisplayStylePicker':
        // 主题里的「布局」→ 打开列数选择
        _openLayoutSheet();
        break;

      case 'showApiConfigPicker':
        // 暂时没有原生的接口配置选择器，复用「换源」入口，
        // 避免主题按钮点了完全没反应。
        SourceSwitchSheet.show(context);
        break;

      case 'openSearch':
        Get.toNamed(AppPages.search);
        break;

      case 'openHistory':
        // 「史藏」合并页：切到该 tab 并选中内部「播放历史」
        ShelfController.instance.tab.value = 0;
        MainTabController.instance.select(1);
        break;

      case 'openFavorite':
        // 「史藏」合并页：切到该 tab 并选中内部「我的收藏」
        ShelfController.instance.tab.value = 1;
        MainTabController.instance.select(1);
        break;

      case 'openPush':
        MainTabController.instance.select(4);
        break;

      case 'navigateBack':
        Navigator.of(context).maybePop();
        break;

      default:
        AppLog.instance.log('[RFW] 未处理的事件: $name args=$args');
    }
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

/// 首页顶部推荐横幅（自动轮播）：横版大图 + 左下标题 + 右下源角标
class _RecommendBanner extends StatefulWidget {
  final List<Video> videos;
  const _RecommendBanner({required this.videos});

  @override
  State<_RecommendBanner> createState() => _RecommendBannerState();
}

class _RecommendBannerState extends State<_RecommendBanner> {
  final _pageCtrl = PageController(viewportFraction: 0.92);
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
    return Column(
      children: [
        SizedBox(
          // 横版 16:9 观感（高度按宽度估算，PageView 内再 AspectRatio）
          height: 196,
          child: PageView.builder(
            controller: _pageCtrl,
            itemCount: widget.videos.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) {
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
                            fontSize: 18,
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
                                fontSize: 11,
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

/// 横滑片单（标题 + 横向海报列表）
class _ShelfRow extends StatelessWidget {
  final String title;
  final List<Video> videos;
  const _ShelfRow({required this.title, required this.videos});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.spacingXL, AppTheme.spacingMD, AppTheme.spacingXL, 8),
            child: Text(
              title,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            height: 190,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: AppTheme.spacingXL),
              itemCount: videos.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final v = videos[i];
                return SizedBox(
                  width: 110,
                  child: VodCard(
                    video: v,
                    onTap: () => Get.toNamed('/detail', arguments: v),
                  ),
                );
              },
            ),
          ),
        ],
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
        gradient: const LinearGradient(
          colors: [Color(0xFF6BDC9A), AppTheme.accentColor],
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

/// 可伸长搜索：小圆角框 → 点击展开成输入条
class _ExpandableSearch extends StatefulWidget {
  final ValueChanged<String> onSubmitted;
  final VoidCallback onOpenFull;

  const _ExpandableSearch({
    required this.onSubmitted,
    required this.onOpenFull,
  });

  @override
  State<_ExpandableSearch> createState() => _ExpandableSearchState();
}

class _ExpandableSearchState extends State<_ExpandableSearch> {
  bool _expanded = false;
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // iOS 风格搜索控件：
    // - 收起 = 圆形玻璃按钮；点击展开成胶囊输入框（宽度动画）
    // - 底色/描边/文字色全部走 AppTheme，切外观自动跟随
    //   （原描边写死 Colors.white.withValues(0.10)，浅色模式下几乎看不见边框）
    final maxW = MediaQuery.of(context).size.width;
    final expandedW = (maxW * 0.52).clamp(140.0, 220.0);
    return AnimatedContainer(
      duration: AppTheme.motionBase,
      curve: AppTheme.motionCurve,
      width: _expanded ? expandedW : 40,
      height: 36,
      decoration: BoxDecoration(
        // 收起时用略深的玻璃底，展开时提亮一点，形成"进入输入态"的层次
        color: _expanded
            ? AppTheme.backgroundElevated
            : AppTheme.backgroundTertiary,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _expanded
              ? AppTheme.accentColor.withValues(alpha: 0.45)
              : AppTheme.glassBorder,
          width: _expanded ? 1 : 0.8,
        ),
        boxShadow: _expanded
            ? [
                BoxShadow(
                  color: AppTheme.accentColor.withValues(alpha: 0.18),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: _expanded
          ? Row(
              children: [
                const SizedBox(width: 12),
                Icon(Icons.search,
                    color: AppTheme.textTertiary, size: 15),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    autofocus: true,
                    cursorColor: AppTheme.accentColor,
                    cursorWidth: 2,
                    cursorRadius: const Radius.circular(1),
                    style: TextStyle(
                        color: AppTheme.textPrimary, fontSize: 13),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (v) {
                      setState(() {
                        _expanded = false;
                        _ctrl.clear();
                      });
                      _focus.unfocus();
                      widget.onSubmitted(v);
                    },
                    onTapOutside: (_) {
                      // 点输入框外部 → 收起搜索框并清空文字
                      if (_expanded) {
                        setState(() {
                          _expanded = false;
                          _ctrl.clear();
                        });
                        _focus.unfocus();
                      }
                    },
                    decoration: InputDecoration(
                      hintText: '搜索影片...',
                      hintStyle: TextStyle(
                          color: AppTheme.textTertiary, fontSize: 13),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    final text = _ctrl.text.trim();
                    if (text.isNotEmpty) {
                      // 有输入内容：直接提交搜索（和按回车行为一致）
                      setState(() {
                        _expanded = false;
                        _ctrl.clear();
                      });
                      _focus.unfocus();
                      widget.onSubmitted(text);
                    } else {
                      // 无输入内容：打开完整搜索页
                      setState(() {
                        _expanded = false;
                      });
                      _focus.unfocus();
                      widget.onOpenFull();
                    }
                  },
                  child: Icon(Icons.search,
                      color: AppTheme.accentColor, size: 18),
                ),
                const SizedBox(width: 8),
              ],
            )
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() => _expanded = true);
                _focus.requestFocus();
              },
              child: Icon(Icons.search,
                  color: AppTheme.textSecondary, size: 18),
            ),
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
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
