import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../models/source_bean.dart';
import '../../widgets/vod_card.dart';
import '../../widgets/common_widgets.dart';
import 'controller.dart';

/// 热门搜索词（静态兜底列表，点击直达搜索）
const List<String> _hotKeywords = [
  '海贼王', '火影忍者', '斗罗大陆', '庆余年', '狂飙',
  '三体', '流浪地球', '甄嬛传', '西游记', '灌篮高手',
  '名侦探柯南', '奥特曼', '熊出没', '爱情公寓', '白夜追凶',
];

/// 搜索页 - 对应 Swift SearchView
class SearchPage extends StatefulWidget {
  /// 可选的初始搜索关键词，从其他页面传入时自动搜索
  final String? initialKeyword;
  /// 关闭回调 - 对应 Swift .sheet 的 dismiss
  final VoidCallback? onClose;

  const SearchPage({super.key, this.initialKeyword, this.onClose});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  // 使用 Get.find 获取 app.dart 中注册的同一实例，避免 Get.put 创建新实例替换
  final _searchController = Get.find<TvSearchController>();
  final _inputController = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // 对应 Swift: SearchView 直接使用 viewModel.keyword
    // 从 overlay 传入时，keyword 已由 app.dart 的 ever() 回调设置
    // 这里同步 inputController 与 keyword
    if (_searchController.keyword.value.isNotEmpty) {
      _inputController.text = _searchController.keyword.value;
    } else if (widget.initialKeyword != null &&
        widget.initialKeyword!.isNotEmpty) {
      _inputController.text = widget.initialKeyword!;
      _searchController.keyword.value = widget.initialKeyword!;
      // 路由跳转方式: 设置关键词后自动触发搜索
      // overlay 方式由 app.dart 的 ever() 回调负责触发搜索
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _searchController.search();
      });
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: AppTheme.backgroundPrimary,
        child: SafeArea(
          child: Column(
            children: [
              _buildSearchBar(),
              Expanded(
                child: Obx(() {
                  // 对应 Swift: if viewModel.activeSites.isEmpty && !viewModel.isSearching
                  if (_searchController.activeSites.isEmpty &&
                      !_searchController.isSearching.value) {
                    return _buildSearchHistorySection();
                  }
                  // 对应 Swift: GeometryReader + HStack(siteListPanel + resultsPanel)
                  return _buildSearchResultsLayout();
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // MARK: - 搜索栏

  /// 搜索栏 - 对应 Swift searchBar (含独立搜索按钮 + 渐变)
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingSM, AppTheme.spacingXL, AppTheme.spacingXL, AppTheme.spacingMD),
      child: Row(
        children: [
          // 返回按钮 - 对应 Swift .sheet dismiss
          IconButton(
            icon: Icon(Icons.arrow_back,
                color: AppTheme.textPrimary, size: 22),
            onPressed: () {
              if (widget.onClose != null) {
                widget.onClose!();
              } else {
                Navigator.of(context).maybePop();
              }
            },
            padding: const EdgeInsets.only(right: AppTheme.spacingSM),
            constraints: const BoxConstraints(),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.spacingLG, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.backgroundSecondary,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.05),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.search,
                      color: AppTheme.textSecondary, size: 18),
                  const SizedBox(width: AppTheme.spacingSM + AppTheme.spacingXS),
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      focusNode: _focusNode,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontHeadline,
                      ),
                      decoration: InputDecoration(
                        hintText: '搜索影片...',
                        hintStyle: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontHeadline),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onSubmitted: (value) {
                        if (value.trim().isNotEmpty) {
                          _searchController.keyword.value = value.trim();
                          _searchController.search();
                        }
                      },
                      // 输入防抖（400ms）：控制器里的 onKeywordChanged 之前
                      // 零调用点，属于「写了但没接上」的死代码。这里接上后
                      // 停止输入即自动搜索，不必再按回车/点按钮。
                      onChanged: (value) {
                        _searchController.onKeywordChanged(value, (kw) async {
                          await _searchController.searchFromDebounce(kw);
                        });
                      },
                    ),
                  ),
                  // 清除按钮 - 对应 Swift xmark.circle.fill
                  Obx(() => _searchController.keyword.value.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _inputController.clear();
                            _focusNode.unfocus();
                            // 对应 Swift: 清空所有搜索状态
                            _searchController.keyword.value = '';
                            _searchController.resultsBySite.clear();
                            _searchController.searchingStatus.clear();
                            _searchController.resultCount.clear();
                            _searchController.activeSites.clear();
                            _searchController.selectedSiteKey.value = null;
                            _searchController.isSearching.value = false;
                          },
                          child: Icon(Icons.cancel,
                              color: AppTheme.textTertiary, size: 18),
                        )
                      : const SizedBox.shrink()),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppTheme.spacingSM),
          // 搜索按钮 - iOS 风格圆形图标按钮 (不喧宾夺主)
          GestureDetector(
            onTap: () {
              final text = _inputController.text.trim();
              if (text.isNotEmpty) {
                _searchController.keyword.value = text;
                _searchController.search();
              }
            },
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.accentColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.accentColor.withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: const Icon(
                Icons.search,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // MARK: - 搜索结果布局

  /// 搜索结果布局 - 对照参考图：顶部横向源芯片 + 全宽海报网格
  Widget _buildSearchResultsLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 48,
          child: _buildSourceChipsBar(),
        ),
        Expanded(child: _buildResultsPanel()),
      ],
    );
  }

  /// 横向源筛选芯片（参考图：搜索中 / 卡卡影视 18 / 橘子影视 1 …）
  Widget _buildSourceChipsBar() {
    return Obx(() {
      final sites = _searchController.activeSites;
      if (sites.isEmpty) return const SizedBox.shrink();
      final anySearching =
          sites.any((s) => _searchController.searchingStatus[s.key] == true);
      return ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spacingMD, vertical: 6),
        children: [
          if (anySearching)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.5, color: AppTheme.accentColor),
                    ),
                    SizedBox(width: 6),
                    Text('搜索中',
                        style: TextStyle(
                            color: AppTheme.textTertiary, fontSize: 12)),
                  ],
                ),
              ),
            ),
          ...sites.map((site) {
            final selected =
                _searchController.selectedSiteKey.value == site.key;
            final count = _searchController.resultCount[site.key] ?? 0;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _searchController.selectSite(site.key),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppTheme.accentColor.withValues(alpha: 0.22)
                        : Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: selected
                          ? AppTheme.accentColor.withValues(alpha: 0.55)
                          : AppTheme.textTertiary.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        site.name,
                        style: TextStyle(
                          color:
                              selected ? AppTheme.accentColor : AppTheme.textSecondary,
                          fontSize: 13,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      if (count > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: selected
                                ? AppTheme.accentColor
                                : AppTheme.textTertiary.withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$count',
                            style: TextStyle(
                              color: selected ? Colors.white : AppTheme.textPrimary,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      );
    });
  }

  // MARK: - 站点列表面板

  /// 站点列表面板 - iOS 风格分组列表
  Widget _buildSiteListPanel() {
    return Container(
      color: Colors.transparent,
      child: Obx(() => ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingSM),
            itemCount: _searchController.activeSites.length,
            itemBuilder: (context, index) {
              final site = _searchController.activeSites[index];
              return _buildSiteRow(site);
            },
          )),
    );
  }

  /// 站点行 - 对应 Swift siteRow
  Widget _buildSiteRow(SourceBean site) {
    return Obx(() {
      final isSelected = _searchController.selectedSiteKey.value == site.key;
      final isSearching = _searchController.searchingStatus[site.key] ?? false;
      final count = _searchController.resultCount[site.key] ?? 0;

      return GestureDetector(
        onTap: () => _searchController.selectSite(site.key),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spacingSM,
            vertical: AppTheme.spacingSM + AppTheme.spacingXS,
          ),
          decoration: BoxDecoration(
            color: isSelected
                ? AppTheme.accentColor.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTheme.radiusSM),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                site.name,
                style: TextStyle(
                  color: isSelected
                      ? AppTheme.accentColor
                      : AppTheme.textSecondary,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppTheme.spacingXS),
              Row(
                children: [
                  if (isSearching) ...[
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                    const SizedBox(width: AppTheme.spacingXS),
                    Text(
                      '搜索中...',
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                  ] else
                    Text(
                      '$count 条结果',
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    });
  }

  // MARK: - 结果面板

  /// 结果面板 - 对应 Swift resultsPanel
  Widget _buildResultsPanel() {
    return Obx(() {
      // 还没有选中具体站点 → 引导用户从左侧站点列表选择
      if (_searchController.selectedSiteKey.value == null) {
        return Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.touch_app,size: 48,color: AppTheme.textTertiary.withValues(alpha: 0.5)),
                SizedBox(height: 16),
                Text(
                  '选择左侧站点查看搜索结果',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 8),
                Text(
                  '已完成全部站点搜索，点击站点名称查看对应结果',
                  style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      }

      // 对应 Swift: isCurrentSiteSearching && currentResults.isEmpty → AppLoadingView
      if (_searchController.isCurrentSiteSearching &&
          _searchController.currentResults.isEmpty) {
        return const Center(
          child: AppLoading(message: '搜索中...'),
        );
      }

      // 对应 Swift: currentResults.isEmpty → "暂无搜索结果"
      if (_searchController.currentResults.isEmpty) {
        return Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search_off,size: 48,color: AppTheme.textTertiary.withValues(alpha: 0.5)),
                SizedBox(height: 16),
                Text(
                  '该站点暂无搜索结果',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                ),
                SizedBox(height: 8),
                Text(
                  '试试左侧其他站点',
                  style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
                ),
              ],
            ),
          ),
        );
      }

      final results = _searchController.currentResults;

      // 对应 Swift: LazyVGrid(columns: adaptive)
      return LayoutBuilder(
        builder: (context, constraints) {
          final cardMinWidth = 120.0;
          final crossAxisCount =
              (constraints.maxWidth / (cardMinWidth + AppTheme.cardSpacing))
                  .floor()
                  .clamp(2, 6);
          final cardWidth =
              (constraints.maxWidth - AppTheme.cardSpacing * (crossAxisCount - 1)) /
                  crossAxisCount;

          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spacingXL,
              AppTheme.spacingMD,
              AppTheme.spacingXL,
              80,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              childAspectRatio: (cardWidth) / (cardWidth / 0.65 + 50),
              crossAxisSpacing: AppTheme.cardSpacing,
              mainAxisSpacing: AppTheme.cardSpacing,
            ),
            itemCount: results.length,
            itemBuilder: (context, index) {
              final video = results[index];
              return VodCard(
                video: video,
                onTap: () => Get.toNamed('/detail', arguments: video),
              );
            },
          );
        },
      );
    });
  }

  // MARK: - 搜索历史

  /// 搜索历史区 - 对应 Swift searchHistorySection
  Widget _buildSearchHistorySection() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppTheme.spacingXL),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 热门搜索：始终显示（无历史时也有内容可点）
          Text(
            '热门搜索',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: AppTheme.spacingLG),
          Wrap(
            spacing: AppTheme.spacingSM,
            runSpacing: AppTheme.spacingSM,
            children: _hotKeywords.map((keyword) {
              return SelectableChip(
                title: keyword,
                isSelected: false,
                onTap: () {
                  _inputController.text = keyword;
                  _searchController.keyword.value = keyword;
                  _searchController.search();
                },
              );
            }).toList(),
          ),
          if (_searchController.searchHistory.isNotEmpty) ...[
            const SizedBox(height: AppTheme.spacingXL),
            Row(
              children: [
                Text(
                  '搜索历史',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => _searchController.clearHistory(),
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline,
                          color: AppTheme.textTertiary, size: 14),
                      const SizedBox(width: AppTheme.spacingXS),
                      Text(
                        '清空',
                        style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.spacingLG),
            // 对应 Swift FlowLayout / LazyVGrid
            Wrap(
              spacing: AppTheme.spacingSM,
              runSpacing: AppTheme.spacingSM,
              children: _searchController.searchHistory.map((keyword) {
                return SelectableChip(
                  title: keyword,
                  isSelected: false,
                  onTap: () {
                    _inputController.text = keyword;
                    _searchController.keyword.value = keyword;
                    _searchController.search();
                  },
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }
}
