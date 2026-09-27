import 'dart:convert';
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

  /// 分类栏/过滤栏是否可见（滚动下移时收起, 上移/回顶恢复）
  /// 对应 tvbox-Swift / 主流影视壳: 列表下滚时顶部分类折叠, 扩大可视区
  bool _categoryBarVisible = true;
  double _lastScrollOffset = 0;

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
                _buildHeaderBar(),
                // 分类/筛选：滚动时保持显示（吸顶，不再折叠）
                Obx(() {
                  final hasCat = _controller.sorts.isNotEmpty;
                  final hasFilter = _controller.currentFilters.isNotEmpty;
                  if (!hasCat && !hasFilter) return const SizedBox.shrink();
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasCat) _buildCategoryTabBar(),
                      if (hasFilter) _buildFilterBar(),
                    ],
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

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingLG, vertical: AppTheme.spacingXS),
      child: GestureDetector(
        onTap: () {
          if (widget.onSearchTap != null) {
            widget.onSearchTap!();
          } else {
            Get.toNamed('/search');
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: AppTheme.backgroundTertiary,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Icon(Icons.search, color: AppTheme.textTertiary, size: 16),
              SizedBox(width: 8),
              Text(
                '搜索影片、演员、导演...',
                style: TextStyle(
                    color: AppTheme.textTertiary, fontSize: AppTheme.fontSubhead),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryTabBar() {
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingLG),
        itemCount: _controller.sorts.length,
        itemBuilder: (context, index) {
          final sort = _controller.sorts[index];
          return Obx(() {
            final isSelected = _controller.selectedSort.value?.id == sort.id;
            return Padding(
              padding: const EdgeInsets.only(right: AppTheme.spacingSM),
              child: GestureDetector(
                onTap: () => _controller.selectSort(sort),
                child: Container(
                  // alignment: center —— 修复分类胶囊"框和名字不居中"：
                  // 原实现 Container 未设置 alignment，横向 ListView 交叉轴
                  // 会拉伸 item 高度，文字默认顶对齐，视觉上胶囊框与名字偏上。
                  alignment: Alignment.center,
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppTheme.accentColor.withValues(alpha: 0.14)
                        : AppTheme.backgroundTertiary,
                    borderRadius: BorderRadius.circular(20),
                    // 选中态加一圈细描边，让"框"更明确，整体更精致
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
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            );
          });
        },
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingLG, vertical: AppTheme.spacingXS),
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
            // 自适应网格 - 对应 Swift adaptive(minimum: 120, maximum: 160)
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
                80, // 底部间距对应 Swift .padding(.bottom, 80)
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                childAspectRatio: (cardWidth) / (cardWidth / 0.65 + 50),
                crossAxisSpacing: AppTheme.cardSpacing,
                mainAxisSpacing: AppTheme.cardSpacing,
              ),
              itemCount: videos.length + (_controller.hasMore.value && _controller.selectedSort.value != null ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= videos.length) {
                  // 对应 Swift: 使用 addPostFrameCallback 避免在 build 阶段触发 setState
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
                            strokeWidth: 2, color: AppTheme.accentColor),
                      ),
                    ),
                  );
                }

                final video = videos[index];
                final source = ApiConfig.instance.homeSourceBean.value;

                // 索引站点 - 对应 Swift isIndexSite: 跳转搜索
                if (source != null && source.isIndexSite) {
                  return VodCard(
                    video: video,
                    onTap: () {
                      // 对应 Swift navigateToSearch(with: video.name)
                      // 使用 pendingSearchKeyword 触发搜索 overlay，匹配 Swift 行为
                      Get.find<AppState>().pendingSearchKeyword.value =
                          video.name;
                    },
                  );
                }

                // 配置中心 - 对应 Swift isConfigCenter: 打开 URL
                if (source != null && source.isConfigCenter) {
                  return VodCard(
                    video: video,
                    onTap: () => _openConfigCenterUrl(video),
                  );
                }

                // 普通源 - 对应 Swift NavigationLink
                return VodCard(
                  video: video,
                  onTap: () {
                    Get.toNamed('/detail', arguments: video);
                  },
                );
              },
            );
          },
        ),
      );
    });
  }

  /// 配置中心 URL 解析 - 对应 Swift openConfigCenterUrl
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
                    setState(() {
                      _expanded = false;
                      _ctrl.clear();
                    });
                    _focus.unfocus();
                    widget.onOpenFull();
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
