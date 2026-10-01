import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import '../../common/theme.dart';
import '../../models/movie.dart';
import '../../models/source_bean.dart';
import '../../services/api_config.dart';
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

  /// 结果展示：false = 网格（海报墙），true = 列表（带标题/来源）
  final _listMode = false.obs;

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
      // AppBar 与背景同色，标题居中；右侧放「搜源」与「列表/网格」切换
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text('搜索',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new,
              size: 18, color: AppTheme.textPrimary),
          onPressed: () {
            if (widget.onClose != null) {
              widget.onClose!();
            } else {
              Navigator.of(context).maybePop();
            }
          },
        ),
        actions: [
          // 跳到源列表（搜索历史区没有源面板时可用来选源）
          IconButton(
            icon: Icon(Icons.manage_search,
                size: 22, color: AppTheme.accentColor),
            tooltip: '选择搜索源',
            onPressed: _openSourcePicker,
          ),
          // 网格 / 列表切换
          Obx(() => IconButton(
                icon: Icon(
                  _listMode.value
                      ? Icons.view_list_rounded
                      : Icons.grid_view_rounded,
                  size: 22,
                  color: AppTheme.accentColor,
                ),
                tooltip: _listMode.value ? '网格显示' : '列表显示',
                onPressed: () => _listMode.value = !_listMode.value,
              )),
        ],
      ),
      body: Container(
        color: AppTheme.backgroundPrimary,
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
    );
  }

  /// 「选择搜索源」：底部弹窗列出可用源，选中即对该源单独搜索
  Future<void> _openSourcePicker() async {
    final sites = _searchController.activeSites.isNotEmpty
        ? _searchController.activeSites
        : ApiConfig.instance.getSearchableSources();
    if (sites.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('当前源没有可搜索的站点')));
      return;
    }
    final picked = await showModalBottomSheet<SourceBean>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => kbSheet(SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Text('选择搜索源',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('点选即搜索',
                      style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption)),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: sites.length,
                itemBuilder: (c, i) => ListTile(
                  leading: Icon(Icons.dns_outlined,
                      size: 18, color: AppTheme.accentColor),
                  title: Text(sites[i].name,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontSubhead)),
                  onTap: () => Navigator.pop(ctx, sites[i]),
                ),
              ),
            ),
          ],
        ),
      )),
    );
    if (picked == null || !mounted) return;
    final kw = _inputController.text.trim();
    if (kw.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先输入搜索内容')));
      return;
    }
    _searchController.keyword.value = kw;
    await _searchController.searchInSource(picked);
  }

  // MARK: - 搜索栏

  /// 搜索栏（AppBar 下面一行）：圆角输入框 + 内嵌放大镜 + 右侧实心「搜索」按钮
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingXS, AppTheme.spacingLG, AppTheme.spacingMD),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              height: 44,
              decoration: BoxDecoration(
                color: AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: AppTheme.glassBorder, width: 0.8),
              ),
              child: Row(
                children: [
                  Icon(Icons.search,
                      color: AppTheme.textTertiary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      focusNode: _focusNode,
                      cursorColor: AppTheme.accentColor,
                      cursorWidth: 2,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead + 1,
                      ),
                      decoration: InputDecoration(
                        hintText: '搜索影视...',
                        hintStyle: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontSubhead + 1),
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
                      // 输入防抖（400ms）：停止输入即自动搜索
                      onChanged: (value) {
                        _searchController.onKeywordChanged(value, (kw) async {
                          await _searchController.searchFromDebounce(kw);
                        });
                      },
                    ),
                  ),
                  // 清除按钮
                  Obx(() => _searchController.keyword.value.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _inputController.clear();
                            _focusNode.unfocus();
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
          // 「搜索」实心按钮（参考图样式）
          GestureDetector(
            onTap: () {
              final text = _inputController.text.trim();
              if (text.isNotEmpty) {
                _searchController.keyword.value = text;
                _searchController.search();
              }
            },
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.accentColor,
                borderRadius: BorderRadius.circular(22),
              ),
              child: const Text('搜索',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
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

  /// 列表模式的一行（小海报 + 片名 + 备注/来源）
  Widget _resultListRow(Video v) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Get.toNamed('/detail', arguments: v),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
        ),
        child: Row(
          children: [
            // 小海报
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 62,
                height: 84,
                child: (v.pic.trim().isEmpty || !v.pic.startsWith('http'))
                    ? ColoredBox(
                        color: AppTheme.backgroundTertiary,
                        child: Icon(Icons.movie_outlined,
                            size: 22, color: AppTheme.textTertiary),
                      )
                    : CachedNetworkImage(
                        imageUrl: v.pic,
                        fit: BoxFit.fill,
                        placeholder: (_, __) =>
                            ColoredBox(color: AppTheme.backgroundTertiary),
                        errorWidget: (_, __, ___) => ColoredBox(
                          color: AppTheme.backgroundTertiary,
                          child: Icon(Icons.broken_image_outlined,
                              size: 20, color: AppTheme.textTertiary),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    v.name,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead + 1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (v.note.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      v.note.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption),
                    ),
                  ],
                  if (v.sourceKey.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      v.sourceKey,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppTheme.accentColor.withValues(alpha: 0.8),
                          fontSize: AppTheme.fontCaption),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 17, color: AppTheme.textTertiary.withValues(alpha: 0.7)),
          ],
        ),
      ),
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
                  color: AppTheme.backgroundTertiary,
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

      // 列表模式：横向卡片（小海报 + 标题 + 来源），信息量更大
      if (_listMode.value) {
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spacingLG,
            AppTheme.spacingMD,
            AppTheme.spacingLG,
            80,
          ),
          itemCount: results.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) => _resultListRow(results[i]),
        );
      }

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

  /// 搜索历史区（参考图样式）
  ///
  /// - 热门搜索：**通栏圆角行**，文字居中
  /// - 搜索历史：**胶囊标签**换行排列，右上角垃圾桶清空
  Widget _buildSearchHistorySection() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingSM, AppTheme.spacingLG, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---------- 热门搜索 ----------
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              '热门搜索',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          for (final kw in _hotKeywords) ...[
            _hotRow(kw),
            const SizedBox(height: 10),
          ],

          // ---------- 搜索历史 ----------
          if (_searchController.searchHistory.isNotEmpty) ...[
            const SizedBox(height: 22),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Row(
                children: [
                  Text(
                    '搜索历史',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  // 垃圾桶图标清空（参考图样式）
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _confirmClearHistory(),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.delete_sweep_outlined,
                          color: AppTheme.textTertiary, size: 20),
                    ),
                  ),
                ],
              ),
            ),
            // 胶囊标签换行排列
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _searchController.searchHistory.map((keyword) {
                return _historyPill(keyword);
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  /// 热门搜索行：通栏圆角 + 文字居中（对应参考图）
  Widget _hotRow(String keyword) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _runSearch(keyword),
      child: Container(
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(23),
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
        ),
        child: Text(
          keyword,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontSubhead + 1,
          ),
        ),
      ),
    );
  }

  /// 搜索历史胶囊
  Widget _historyPill(String keyword) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _runSearch(keyword),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
        ),
        child: Text(
          keyword,
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
          ),
        ),
      ),
    );
  }

  /// 统一的「点词即搜索」
  void _runSearch(String keyword) {
    _inputController.text = keyword;
    _searchController.keyword.value = keyword;
    _searchController.search();
  }

  /// 清空搜索历史前确认（避免误触把记录清掉）
  Future<void> _confirmClearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.glassRadius)),
        title:
            Text('清空搜索历史', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('将删除全部搜索历史记录，确定？',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) await _searchController.clearHistory();
  }
}
