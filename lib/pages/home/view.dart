import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import '../../services/api_config.dart';
import '../../models/movie.dart';
import '../../widgets/vod_card.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/source_switch_sheet.dart';
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

  /// 筛选面板：默认隐藏，点分类时弹出
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
    // 分类胶囊横向滚动
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 0.5,
        ),
      ),
      padding: const EdgeInsets.symmetric(
        vertical: AppTheme.spacingSM,
        horizontal: AppTheme.spacingXS,
      ),
      child: SizedBox(
        height: 40,
        child: Obx(() => ListView.builder(
          scrollDirection: Axis.horizontal,
          padding:
              const EdgeInsets.symmetric(horizontal: AppTheme.spacingXS),
          itemCount: _controller.sorts.length,
          itemBuilder: (context, index) {
            final sort = _controller.sorts[index];
            final isSelected =
                _controller.selectedSort.value?.id == sort.id;
            return Padding(
              padding:
                  const EdgeInsets.only(right: AppTheme.spacingSM),
              child: GestureDetector(
                onTap: () {
                  final wasSelected =
                      _controller.selectedSort.value?.id == sort.id;
                  if (wasSelected) {
                    // 再点同一分类：切换筛选显隐
                    setState(() {
                      _showFilters = !_showFilters;
                    });
                    return;
                  }
                  _controller.selectSort(sort);
                  setState(() {
                    // 默认收起，避免遮住列表；用户可手动展开
                  });
                },
                child: _CategoryChip(
                  label: sort.name,
                  selected: isSelected,
                ),
              ),
            );
          },
        )),
      ),
    );
  }

  Widget _buildFilterBar() {
    // 独立卡片：分类 / 地区 / 排序 / 年份 筛选行
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 0.5,
        ),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacingMD,
        vertical: AppTheme.spacingSM,
      ),
      child: Column(
        children: _controller.currentFilters.map((filter) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppTheme.spacingSM),
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  child: Text(
                    filter.name,
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: AppTheme.fontCaption,
                      fontWeight: FontWeight.w500,
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
                              _controller.selectedFilters[filter.key] == null,
                          onTap: () =>
                              _controller.selectFilter(filter.key, ''),
                        ),
                        const SizedBox(width: AppTheme.spacingSM),
                        ...filter.values.map((value) {
                          return Padding(
                            padding: const EdgeInsets.only(
                                right: AppTheme.spacingSM),
                            child: SelectableChip(
                              title: value.n,
                              isSelected:
                                  _controller.selectedFilters[filter.key] ==
                                      value.v,
                              onTap: () => _controller.selectFilter(
                                  filter.key, value.v),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
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
      final selectedFilters =
          Map<String, String>.from(_controller.selectedFilters);
      final currentFilters = _controller.currentFilters.toList();
      final showFilters = _showFilters;
      final source = ApiConfig.instance.homeSourceBean.value;

      if (isLoading && videos.isEmpty) {
        return const AppLoading();
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
            final cardMinWidth = 120.0;
            final crossAxisCount =
                (constraints.maxWidth / (cardMinWidth + AppTheme.cardSpacing))
                    .floor()
                    .clamp(2, 6);
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
                if (showFilters &&
                    selectedSortId != null &&
                    currentFilters.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppTheme.spacingLG,
                        0,
                        AppTheme.spacingLG,
                        AppTheme.spacingSM,
                      ),
                      child: _buildFilterBar(),
                    ),
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
      final next = (_index + 1) % widget.videos.length;
      _pageCtrl.animateToPage(
        next,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
      );
    });
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
      fit: BoxFit.cover,
      // 横版裁切：海报中间偏上更好看
      alignment: Alignment(0, -0.15),
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
    return Container(
      alignment: Alignment.center,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: selected
            ? AppTheme.accentColor.withValues(alpha: 0.14)
            : AppTheme.backgroundTertiary,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: selected
              ? AppTheme.accentColor.withValues(alpha: 0.45)
              : Colors.white.withValues(alpha: 0.06),
          width: selected ? 1 : 0.5,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? AppTheme.accentColor : AppTheme.textSecondary,
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
    // 展开宽度跟随屏幕，避免源名长/小屏溢出
    final maxW = MediaQuery.of(context).size.width;
    final expandedW = (maxW * 0.52).clamp(140.0, 220.0);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: _expanded ? expandedW : 40,
      height: 36,
      decoration: BoxDecoration(
        color: AppTheme.backgroundTertiary,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: _expanded
          ? Row(
              children: [
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    autofocus: true,
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
