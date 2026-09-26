import 'package:flutter/material.dart';
import '../../common/theme.dart';
import '../../controllers/home_controller.dart';
import '../../services/api_config.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/glass.dart';
import 'package:get/get.dart';

/// 首页 - 对应 Swift HomeView
///
/// 结构：
/// - 顶部：渐变背景 + HeaderBar（LOGO + 刷新）+ 搜索栏
/// - 分类栏（横向滚动胶囊）+ 筛选栏（横向滚动标签）
/// - 内容区：GridView 卡片流（分类标签页 + 推荐）
///
/// **2026-09-26 更新**：
/// - 分类栏/筛选栏在列表下滚时自动折叠（AnimatedSize 平滑收起），
///   上滚/回顶时恢复，扩大内容可视区；
/// - 分类胶囊文字与容器居中（修复"框和名字不居中"）；
/// - 透明背景让 app.dart 全局渐变背景层透出。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final HomeController _controller = Get.put(HomeController());
  bool _isReconnecting = false;

  /// 分类栏/过滤栏是否可见（滚动下移时收起, 上移/回顶恢复）
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
                _buildSearchBar(),
                // **滚动收起分类栏**: AnimatedSize 让分类栏/过滤栏
                // 下滚时平滑折叠 (高度→0), 上滚恢复, 扩大内容可视区
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: _categoryBarVisible
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Obx(() {
                              if (_controller.sorts.isNotEmpty) {
                                return _buildCategoryTabBar();
                              }
                              return const SizedBox.shrink();
                            }),
                            Obx(() {
                              if (_controller.currentFilters.isNotEmpty) {
                                return _buildFilterBar();
                              }
                              return const SizedBox.shrink();
                            }),
                          ],
                        )
                      : const SizedBox(width: double.infinity, height: 0),
                ),
                Expanded(
                  // 监听滚动方向: 下滚超过 60pt 收起分类栏, 上滚恢复
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification.metrics.axis != Axis.vertical) {
                        return false;
                      }
                      final current = notification.metrics.pixels;
                      final delta = current - _lastScrollOffset;
                      if (delta > 6 && current > 60 && _categoryBarVisible) {
                        setState(() => _categoryBarVisible = false);
                      } else if (delta < -6 && !_categoryBarVisible) {
                        setState(() => _categoryBarVisible = true);
                      }
                      _lastScrollOffset = current;
                      return false;
                    },
                    child: _buildContentArea(),
                  ),
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

  // ============================================================
  // 顶部
  // ============================================================

  Widget _buildHeaderBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'NewTv',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: AppTheme.textPrimary),
            tooltip: '刷新',
            onPressed: () {
              _isReconnecting = true;
              setState(() {});
              ApiConfig.instance.refresh();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Get.toNamed('/search'),
        child: Container(
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(21),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.1),
              width: 0.5,
            ),
          ),
          child: const Row(
            children: [
              SizedBox(width: 14),
              Icon(Icons.search, color: Colors.white54, size: 20),
              SizedBox(width: 8),
              Text(
                '搜索影片 / 剧集 / 直播',
                style: TextStyle(color: Colors.white38, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 分类栏
  // ============================================================

  Widget _buildCategoryTabBar() {
    return SizedBox(
      height: 40,
      child: Obx(() {
        final sorts = _controller.sorts;
        if (sorts.isEmpty) return const SizedBox.shrink();
        return ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: sorts.length,
          itemBuilder: (context, index) {
            final sort = sorts[index];
            final selected = _controller.currentSortIndex.value == index;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => _controller.selectSort(index),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected
                        ? AppTheme.accentColor.withValues(alpha: 0.85)
                        : Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                    border: selected
                        ? null
                        : Border.all(
                            color: Colors.white.withValues(alpha: 0.12),
                            width: 0.5,
                          ),
                  ),
                  child: Center(
                    child: Text(
                      sort.name,
                      style: TextStyle(
                        color: selected ? Colors.white : Colors.white70,
                        fontSize: 13,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      }),
    );
  }

  // ============================================================
  // 筛选栏
  // ============================================================

  Widget _buildFilterBar() {
    return SizedBox(
      height: 38,
      child: Obx(() {
        final filters = _controller.currentFilters;
        if (filters.isEmpty) return const SizedBox.shrink();
        final selected = _controller.selectedFilterKeys;
        return ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: filters.length,
          itemBuilder: (context, index) {
            final f = filters[index];
            final isSelected = selected[f.key] == f.value;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => _controller.selectFilter(f),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppTheme.accentColor.withValues(alpha: 0.35)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isSelected
                          ? AppTheme.accentColor.withValues(alpha: 0.6)
                          : Colors.white.withValues(alpha: 0.12),
                      width: 0.5,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      f.value,
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white60,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      }),
    );
  }

  // ============================================================
  // 内容区
  // ============================================================

  Widget _buildContentArea() {
    return Obx(() {
      if (_controller.isLoading.value) {
        return const Center(
          child: CircularProgressIndicator(color: AppTheme.accentColor),
        );
      }
      final items = _controller.displayItems;
      if (items.isEmpty) {
        return const Center(
          child: Text(
            '暂无数据，请检查订阅或网络',
            style: TextStyle(color: AppTheme.textTertiary),
          ),
        );
      }
      return RefreshIndicator(
        color: AppTheme.accentColor,
        onRefresh: () async {
          await _controller.refresh();
        },
        child: GridView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 0.68,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) => _buildMovieCard(items[index]),
        ),
      );
    });
  }

  // ============================================================
  // 影片卡片
  // ============================================================

  Widget _buildMovieCard(dynamic item) {
    final title = item is VodItem ? item.name : (item.title ?? '');
    final pic = item is VodItem ? item.pic : (item.pic ?? '');
    return GestureDetector(
      onTap: () => Get.toNamed('/detail', arguments: item),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 封面
            if (pic.isNotEmpty)
              Image.network(
                pic,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildCardPlaceholder(title),
              )
            else
              _buildCardPlaceholder(title),
            // 渐变遮罩
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCardPlaceholder(String title) {
    return Container(
      color: Colors.white.withValues(alpha: 0.06),
      alignment: Alignment.center,
      child: Text(
        title.isEmpty ? '暂无封面' : title.characters.first,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.4),
          fontSize: 28,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  // ============================================================
  // 重连覆盖层
  // ============================================================

  Widget _buildReconnectingOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.5),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: AppTheme.accentColor),
              const SizedBox(height: 12),
              const Text(
                '正在重新连接订阅…',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
