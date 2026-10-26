import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/movie.dart';
import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/widgets/vod_card.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/pages/search/controller.dart';
import 'package:tvbox/widgets/app_toast.dart';

/// 热门搜索词（静态兜底列表，点击直达搜索）
const List<String> _hotKeywords = [
  '海贼王',
  '火影忍者',
  '斗罗大陆',
  '庆余年',
  '狂飙',
  '三体',
  '流浪地球',
  '甄嬛传',
  '西游记',
  '灌篮高手',
  '名侦探柯南',
  '奥特曼',
  '熊出没',
  '爱情公寓',
  '白夜追凶',
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
      backgroundColor: Colors.transparent,
      // AppBar 与背景同色，标题居中；右侧放「搜源」与「列表/网格」切换
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(
          '搜索',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontTitle3,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new,
            size: 18,
            color: AppTheme.textPrimary,
          ),
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
            icon: Icon(
              Icons.manage_search,
              size: 22,
              color: AppTheme.accentColor,
            ),
            tooltip: '选择搜索源',
            onPressed: _openSourcePicker,
          ),
          // 网格 / 列表切换
          Obx(
            () => IconButton(
              icon: Icon(
                _listMode.value
                    ? Icons.view_list_rounded
                    : Icons.grid_view_rounded,
                size: 22,
                color: AppTheme.accentColor,
              ),
              tooltip: _listMode.value ? '网格显示' : '列表显示',
              onPressed: () => _listMode.value = !_listMode.value,
            ),
          ),
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
      AppToast.message('当前源没有可搜索的站点');
      return;
    }
    final picked = await showModalBottomSheet<SourceBean>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => kbSheet(_SearchSourcePicker(sites: sites)),
    );
    if (picked == null || !mounted) return;
    final kw = _inputController.text.trim();
    if (kw.isEmpty) {
      AppToast.message('请先输入搜索内容');
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
        AppTheme.spacingLG,
        AppTheme.spacingXS,
        AppTheme.spacingLG,
        AppTheme.spacingMD,
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              height: 34,
              decoration: BoxDecoration(
                // 透明底 + 细边：跟随页面背景（深浅模式自动切换），
                // 不再是一块固定浅色/灰色（用户要求"背景跟随系统、灰色透明"）
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(17),
                border: Border.all(color: AppTheme.borderLight, width: 0.5),
              ),
              child: Row(
                children: [
                  Icon(Icons.search, color: AppTheme.textTertiary, size: 15),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      focusNode: _focusNode,
                      cursorColor: AppTheme.accentColor,
                      cursorWidth: 1.5,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 12,
                      ),
                      decoration: InputDecoration(
                        hintText: '搜索影视...',
                        hintStyle: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: 12,
                        ),
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
                  Obx(
                    () => _searchController.keyword.value.isNotEmpty
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
                            child: Icon(
                              Icons.cancel,
                              color: AppTheme.textTertiary,
                              size: 18,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppTheme.spacingSM),
          // 「搜索」按钮已移除：回车 / 输入防抖自动搜索即可触发，
          // 右侧不再有灰色实心按钮（用户要求去掉）
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
                        child: Icon(
                          Icons.movie_outlined,
                          size: 22,
                          color: AppTheme.textTertiary,
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: v.pic,
                        fit: BoxFit.fill,
                        placeholder: (_, __) =>
                            ColoredBox(color: AppTheme.backgroundTertiary),
                        errorBuilder: (_, __, ___) => ColoredBox(
                          color: AppTheme.backgroundTertiary,
                          child: Icon(
                            Icons.broken_image_outlined,
                            size: 20,
                            color: AppTheme.textTertiary,
                          ),
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
                        fontSize: AppTheme.fontCaption,
                      ),
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
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 17,
              color: AppTheme.textTertiary.withValues(alpha: 0.7),
            ),
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
      final anySearching = sites.any(
        (s) => _searchController.searchingStatus[s.key] == true,
      );
      return ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingMD,
          vertical: 6,
        ),
        children: [
          if (anySearching)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
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
                        strokeWidth: 1.5,
                        color: AppTheme.accentColor,
                      ),
                    ),
                    SizedBox(width: 6),
                    Text(
                      '搜索中',
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontFootnote,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ...sites.map((site) {
            final selected =
                _searchController.selectedSiteKey.value == site.key;
            final count = _searchController.resultCount[site.key] ?? 0;
            final siteSearching =
                _searchController.searchingStatus[site.key] == true;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _searchController.selectSite(site.key),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    // 与首页分类、RSS/海阔分类同一套：选中实底主题色 + 白字
                    color: selected
                        ? AppTheme.accentColor
                        : AppTheme.backgroundTertiary,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: selected
                          ? AppTheme.accentColor
                          : AppTheme.textTertiary.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 该源还在搜：名字前小转圈，用户知道它没卡死
                      if (siteSearching) ...[
                        SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color:
                                selected ? Colors.white : AppTheme.accentColor,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        site.name,
                        style: TextStyle(
                          color: selected
                              ? Colors.white
                              : AppTheme.textSecondary,
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      if (count > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: selected
                                ? Colors.white.withValues(alpha: 0.22)
                                : AppTheme.textTertiary.withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$count',
                            style: TextStyle(
                              color: selected
                                  ? Colors.white
                                  : AppTheme.textPrimary,
                              fontSize: AppTheme.fontCaption,
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
                Icon(
                  Icons.touch_app,
                  size: 48,
                  color: AppTheme.textTertiary.withValues(alpha: 0.5),
                ),
                SizedBox(height: 16),
                Text(
                  '选择左侧站点查看搜索结果',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontBody,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 8),
                Text(
                  '已完成全部站点搜索，点击站点名称查看对应结果',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontFootnote,
                  ),
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
                Icon(
                  Icons.search_off,
                  size: 48,
                  color: AppTheme.textTertiary.withValues(alpha: 0.5),
                ),
                SizedBox(height: 16),
                Text(
                  '该站点暂无搜索结果',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontBody,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  '试试左侧其他站点',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontFootnote,
                  ),
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

      // 网格：列数统一跟随首页（gridColumns，2~4，默认 3），
      // 海报比例 1.44、文字区 30 —— 与首页卡片/封面尺寸完全一致。
      return LayoutBuilder(
        builder: (context, constraints) {
          final crossAxisCount =
              PlayerPrefs.instance.gridColumns.value.clamp(2, 4);
          final cardWidth =
              (constraints.maxWidth -
                  AppTheme.cardSpacing * (crossAxisCount - 1)) /
              crossAxisCount;

          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spacingXL,
              AppTheme.spacingMD,
              AppTheme.spacingXL,
              0, // 底部 padding 归 0（与首页统一：内容显示更多）
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              childAspectRatio: cardWidth / (cardWidth * 1.44 + 30),
              crossAxisSpacing: AppTheme.cardSpacing,
              mainAxisSpacing: AppTheme.cardSpacing,
            ),
            itemCount: results.length,
            itemBuilder: (context, index) {
              final video = results[index];
              return VodCard(
                video: video,
                // 海报比例与首页一致（1.44）
                posterHeightRatio: 1.44,
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
        AppTheme.spacingLG,
        AppTheme.spacingSM,
        AppTheme.spacingLG,
        24,
      ),
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
                fontSize: AppTheme.fontTitle2,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          // 热门搜索：小胶囊流式排列（不再通栏长条，参考 App 常见样式）
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _hotKeywords.map((kw) => _hotPill(kw)).toList(),
          ),

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
                      fontSize: AppTheme.fontTitle2,
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
                      child: Icon(
                        Icons.delete_sweep_outlined,
                        color: AppTheme.textTertiary,
                        size: 20,
                      ),
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

  /// 热门搜索小胶囊：亮底 + 主色文字（primary），比历史胶囊更醒目。
  /// 与历史胶囊**底色统一**（backgroundCard + 细边），仅文字主次区分。
  Widget _hotPill(String keyword) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _runSearch(keyword),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
        ),
        child: Text(
          keyword,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontBody,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  /// 搜索历史胶囊：与热门胶囊**同底色**（backgroundCard + 细边），
  /// 文字用 secondary 弱化一级，形成主次但不割裂的两组。
  Widget _historyPill(String keyword) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _runSearch(keyword),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
        ),
        child: Text(
          keyword,
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
            fontWeight: FontWeight.w500,
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
          borderRadius: BorderRadius.circular(AppTheme.glassRadius),
        ),
        title: Text('清空搜索历史', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          '将删除全部搜索历史记录，确定？',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
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

/// 搜索页「搜索源」面板（2026-10-02 重构，对齐 Makka 聚合参考图）
///
/// - 三分之一屏底部面板（键盘弹起时 kbSheet 抬高仍不会顶出屏幕）
/// - 顶部 SafeArea 避让状态栏；标题「搜索源」+ 小胶囊搜索框
/// - 源列表**两列紧凑网格**，随时可滚动（搜索中/键盘弹起时也一样）
class _SearchSourcePicker extends StatefulWidget {
  final List<SourceBean> sites;

  const _SearchSourcePicker({required this.sites});

  @override
  State<_SearchSourcePicker> createState() => _SearchSourcePickerState();
}

class _SearchSourcePickerState extends State<_SearchSourcePicker> {
  final _ctrl = TextEditingController();
  String _kw = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    // 面板高度 = 1/3 屏 × 1.2（与首页源切换面板一致；矮屏仍可滚动）
    final panelHeight = (h * 0.4).clamp(h * 0.34, h * 0.48);
    final list = _kw.isEmpty
        ? widget.sites
        : widget.sites
            .where((s) => s.name.toLowerCase().contains(_kw.toLowerCase()))
            .toList();
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
              // 标题「搜索源」
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
                  ],
                ),
              ),
              // 搜索（小胶囊：透明底 + 细边，与首页源切换面板统一，
              // 不涂灰色块）
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  height: 30,
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(15),
                    border:
                        Border.all(color: AppTheme.borderLight, width: 0.5),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 10),
                      Icon(Icons.search,
                          color: AppTheme.textTertiary, size: 14),
                      const SizedBox(width: 5),
                      Expanded(
                        child: TextField(
                          controller: _ctrl,
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 12,
                          ),
                          onChanged: (v) =>
                              setState(() => _kw = v.trim()),
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: '搜索源…',
                            hintStyle: TextStyle(
                              color: AppTheme.textTertiary,
                              fontSize: 12,
                            ),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 6),
                          ),
                        ),
                      ),
                      if (_kw.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            _ctrl.clear();
                            setState(() => _kw = '');
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(5),
                            child: Icon(Icons.cancel,
                                color: AppTheme.textTertiary, size: 13),
                          ),
                        ),
                      const SizedBox(width: 6),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // 两列紧凑网格：随时可滚动
              Expanded(
                child: list.isEmpty
                    ? Center(
                        child: Text(
                          '未找到匹配的源',
                          style: TextStyle(color: AppTheme.textTertiary),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        physics: const AlwaysScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 10,
                          childAspectRatio: 3.2,
                        ),
                        itemCount: list.length,
                        itemBuilder: (c, i) {
                          final source = list[i];
                          return GestureDetector(
                            onTap: () => Navigator.pop(context, source),
                            child: Container(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: AppTheme.backgroundTertiary,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: AppTheme.borderLight, width: 0.5),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.pets,
                                    size: 14,
                                    color: AppTheme.textTertiary,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      source.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: AppTheme.textSecondary,
                                        fontSize: 12,
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
            ],
          ),
        ),
      ),
    );
  }
}
