import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../widgets/vod_card.dart';
import '../../widgets/common_widgets.dart';
import '../../models/cache_store.dart';
import '../../models/movie.dart';
import '../../services/player_prefs.dart';
import 'controller.dart';

/// 收藏页 - 对应 Swift FavoritesView
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  final _searchCtrl = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 当前搜索词（由搜索框写入 PlayerPrefs.favKeyword，供 controller 过滤）
  void _onSearchChanged(String v) {
    PlayerPrefs.instance.favKeyword.value = v.trim();
  }

  void _toggleSearch() {
    setState(() => _searching = !_searching);
    if (!_searching) {
      _searchCtrl.clear();
      _onSearchChanged('');
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.put(FavoritesController());

    return Scaffold(
      // 透明背景,让 ContentView 全局背景层透出
      backgroundColor: Colors.transparent,
      body: Container(
        color: Colors.transparent,
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(controller),
              // 搜索栏（点击放大镜展开）
              if (_searching) _buildSearchField(),
              Expanded(child: _buildContent(controller)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingXL, 0, AppTheme.spacingXL, AppTheme.spacingSM),
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.glassBorder, width: 0.8),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(Icons.search, size: 15, color: AppTheme.textTertiary),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                cursorColor: AppTheme.accentColor,
                cursorWidth: 2,
                onChanged: _onSearchChanged,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  hintText: '搜索收藏…',
                  hintStyle:
                      TextStyle(color: AppTheme.textTertiary, fontSize: 13),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            Obx(() {
              if (PlayerPrefs.instance.favKeyword.value.isEmpty) {
                return const SizedBox(width: 10);
              }
              return GestureDetector(
                onTap: () {
                  _searchCtrl.clear();
                  _onSearchChanged('');
                },
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.cancel,
                      size: 15, color: AppTheme.textTertiary),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// 布局切换：2~6 列
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
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
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
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final n in const [2, 3, 4, 5, 6])
                        SelectableChip(
                          title: '$n 列',
                          isSelected: prefs.favGridColumns.value == n,
                          onTap: () async {
                            await prefs.setFavGridColumns(n);
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

  Widget _buildHeader(FavoritesController controller) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingXL, AppTheme.spacingLG, AppTheme.spacingXL, AppTheme.spacingSM),
      child: Row(
        children: [
          Text(
            '我的收藏',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontTitle3,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          // 搜索（展开输入框）与 布局切换
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleSearch,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Icon(
                _searching ? Icons.close : Icons.search,
                size: 19,
                color: _searching
                    ? AppTheme.accentColor
                    : AppTheme.textSecondary,
              ),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openLayoutSheet,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Icon(
                Icons.grid_view_rounded,
                size: 19,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          Obx(() {
            if (CacheStore.instance.favorites.isEmpty) {
              return const SizedBox.shrink();
            }
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () {
                    final m = controller.favSortMode.value;
                    controller.favSortMode.value = switch (m) {
                      FavSort.timeDesc => FavSort.timeAsc,
                      FavSort.timeAsc => FavSort.nameAsc,
                      FavSort.nameAsc => FavSort.timeDesc,
                    };
                    controller.update();
                  },
                  child: Text(
                    switch (controller.favSortMode.value) {
                      FavSort.timeDesc => '时间↓',
                      FavSort.timeAsc => '时间↑',
                      FavSort.nameAsc => '名称A-Z',
                    },
                    style: TextStyle(
                        color: AppTheme.accentColor,
                        fontSize: AppTheme.fontCaption),
                  ),
                ),
                TextButton(
              // 不要用 Get.context! 强解包：该 context 为空时会直接崩。
              onPressed: () {
                final ctx = Get.context;
                if (ctx == null) return;
                _showClearConfirmDialog(ctx, controller);
              },
              child: Text(
                '清空',
                style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption),
              ),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _buildContent(FavoritesController controller) {
    return Obx(() {
      final all = controller.favoritesList;
      // 搜索过滤：按片名不区分大小写包含匹配
      final kw = PlayerPrefs.instance.favKeyword.value.toLowerCase();
      final favorites = kw.isEmpty
          ? all
          : all
              .where((e) => e.vodName.toLowerCase().contains(kw))
              .toList();

      if (favorites.isEmpty) {
        // 区分"真没有收藏"和"搜索无结果"
        if (kw.isNotEmpty) {
          return const EmptyState(
            title: '没有匹配的收藏',
            message: '试试换个关键词',
            icon: Icons.search_off,
          );
        }
        return const EmptyState(
          title: '暂无收藏',
          message: '收藏影片后会显示在这里',
          icon: Icons.favorite_border,
        );
      }

      return LayoutBuilder(
        builder: (context, constraints) {
          // 列数来自「布局切换」（2~6，默认 4）
          final crossAxisCount =
              PlayerPrefs.instance.favGridColumns.value.clamp(2, 6);
          final cardWidth =
              (constraints.maxWidth - AppTheme.cardSpacing * (crossAxisCount - 1)) /
                  crossAxisCount;

          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spacingLG,
              AppTheme.spacingLG,
              AppTheme.spacingLG,
              100, // 底部预留悬浮导航栏空间
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              // 卡片总高 = 图片区 + 标题区(约30)。
              //
              // 历史沿革：原式 cardWidth/0.65+50（卡片约196pt）→ 3/4 高
              // （0.4875+50，约91pt）→ 现按要求把**图片放大到约 1.5 倍**
              // （0.4875 → 1.015），卡片随之回到约 118pt。
              //
              // 图片区具体高度由 VodCard.posterHeightRatio 决定，这里的两者
              // 必须配套改，否则图片会把标题挤出去。
              childAspectRatio: cardWidth / (cardWidth * 1.015 + 30),
              crossAxisSpacing: AppTheme.cardSpacing,
              mainAxisSpacing: AppTheme.cardSpacing,
            ),
            itemCount: favorites.length,
            itemBuilder: (context, index) {
              final item = favorites[index];
              final video = Video(
                id: item.vodId,
                name: item.vodName,
                pic: item.vodPic,
                sourceKey: item.sourceKey,
              );
              return VodCard(
                video: video,
                // 图片区约 1.5 倍高（与上面的 childAspectRatio 配套）
                posterHeightRatio: 1.015,
                onTap: () => Get.toNamed('/detail', arguments: video),
                onLongPress: () =>
                    _showUnfavoriteDialog(context, controller, item),
              );
            },
          );
        },
      );
    });
  }

  void _showUnfavoriteDialog(
    BuildContext context,
    FavoritesController controller,
    VodCollect item,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLG)),
        title: Text('取消收藏',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('确定取消收藏「${item.vodName}」？',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () {
              controller.removeItem(item);
              Navigator.pop(context);
            },
            child: const Text('取消收藏', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showClearConfirmDialog(
    BuildContext context,
    FavoritesController controller,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLG)),
        title: Text('清空收藏',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('确定清空所有收藏？此操作不可恢复。',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () {
              controller.clearAll();
              Navigator.pop(context);
            },
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
