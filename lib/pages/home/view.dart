import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../services/api_config.dart';
import '../../services/app_state.dart';
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

  // 源切换行 + 分类/筛选行：滚动时保持显示（吸顶，不再折叠）

  @override
  void initState() {
    super.initState();
    // 监听重连状态
    ever(ApiConfig.instance.isLoaded, (loaded) {
      if (loaded && _isReconnecting) {
        setState(() => _isReconnecting = false);
        _controller.refresh();
      }
    });
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
                // 顶部源切换行 + 分类/筛选行：下滑保留（吸顶常驻）
                _buildHeaderBar(),
                // 分类 / 筛选：两张独立卡片（分类胶囊一张，筛选行一张）
                Obx(() {
                  final hasCat = _controller.sorts.isNotEmpty;
                  final hasFilter = _controller.currentFilters.isNotEmpty;
                  if (!hasCat && !hasFilter) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppTheme.spacingLG,
                      AppTheme.spacingXS,
                      AppTheme.spacingLG,
                      AppTheme.spacingSM,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (hasCat) ...[
                          _buildCategoryTabBar(),
                          if (hasFilter)
                            const SizedBox(height: AppTheme.spacingSM),
                        ],
                        if (hasFilter) _buildFilterBar(),
                      ],
                    ),
                  );
                }),
                Expanded(
                  child: _buildContentArea(),
                ),
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
    // 独立卡片：分类胶囊横向滚动
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
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding:
              const EdgeInsets.symmetric(horizontal: AppTheme.spacingXS),
          itemCount: _controller.sorts.length,
          itemBuilder: (context, index) {
            final sort = _controller.sorts[index];
            return Obx(() {
              final isSelected =
                  _controller.selectedSort.value?.id == sort.id;
              return Padding(
                padding:
                    const EdgeInsets.only(right: AppTheme.spacingSM),
                child: GestureDetector(
                  onTap: () => _controller.selectSort(sort),
                  child: Container(
                    alignment: Alignment.center,
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppTheme.accentColor.withValues(alpha: 0.14)
                          : AppTheme.backgroundTertiary,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isSelected
                            ? AppTheme.accentColor.withValues(alpha: 0.45)
                            : Colors.white.withValues(alpha: 0.06),
                        width: isSelected ? 1 : 0.5,
                      ),
                    ),
                    child: Text(
                      sort.name,
                      style: TextStyle(
                        color: isSelected
                            ? AppTheme.accentColor
                            : AppTheme.textSecondary,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              );
            });
          },
        ),
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
      if (_controller.isLoading.value &&
          _controller.categoryVideos.isEmpty &&
          _controller.homeVideos.isEmpty) {
        return const AppLoading();
      }

      if (_controller.errorMessage.value != null &&
          _controller.categoryVideos.isEmpty) {
        final source = ApiConfig.instance.homeSourceBean.value;
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 索引服务特殊提示 - 对应 Swift isIndexSite 错误处理
              if (source != null && source.isIndexSite)
                const AppError(message: '该线路为索引服务，请点击影视跳转搜索')
              else
                AppError(
                  message: _controller.errorMessage.value!,
                  onRetry: () => _controller.refresh(),
                ),
              // 不支持的源类型提示 - 对应 Swift !isSupportedInSwift
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

      // 对应 Swift: 选中分类时显示 categoryVideos，否则显示 homeVideos
      final videos = _controller.displayVideos;

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

            final homeList = _controller.homeVideos;
            final categoryList = _controller.displayVideos;
            final bannerItems =
                homeList.length > 6 ? homeList.sublist(0, 6) : homeList;
            final shelf1 = homeList.length > 6
                ? homeList.sublist(6, homeList.length > 18 ? 18 : homeList.length)
                : <Video>[];
            final shelf2 = homeList.length > 18
                ? homeList.sublist(18, homeList.length > 32 ? 32 : homeList.length)
                : <Video>[];

            return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // 顶部横幅轮播
                if (bannerItems.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _RecommendBanner(videos: bannerItems),
                  ),
                // 横滑片单 1
                if (shelf1.isNotEmpty)
                  _ShelfRow(title: '推荐热播', videos: shelf1),
                // 横滑片单 2
                if (shelf2.isNotEmpty)
                  _ShelfRow(title: '更多精彩', videos: shelf2),
                // 分类网格
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
                        if (index >= categoryList.length) {
                          if (_controller.hasMore.value &&
                              _controller.selectedSort.value != null) {
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
                        final vid = categoryList[index];
                        return VodCard(
                          video: vid,
                          onTap: () =>
                              Get.toNamed('/detail', arguments: vid),
                        );
                      },
                      childCount: categoryList.length +
                          ((_controller.hasMore.value &&
                                  _controller.selectedSort.value != null)
                              ? 1
                              : 0),
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
          } catch (_) {}
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

/// 首页顶部推荐横幅（自动轮播）
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
          height: 160,
          child: PageView.builder(
            controller: _pageCtrl,
            itemCount: widget.videos.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) {
              final v = widget.videos[i];
              return GestureDetector(
                onTap: () => Get.toNamed('/detail', arguments: v),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: AppTheme.backgroundSecondary,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      VodCard(video: v, onTap: null),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.75),
                              ],
                            ),
                          ),
                          child: Text(
                            v.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
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
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(widget.videos.length, (i) {
            final active = i == _index;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: active ? 16 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: active ? AppTheme.accentColor : Colors.white24,
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
        ),
      ],
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
