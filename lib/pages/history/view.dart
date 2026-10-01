import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../models/movie.dart';
import '../../services/player_prefs.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/vod_card.dart';
import '../../models/cache_store.dart';
import '../shelf/controller.dart';
import 'controller.dart';

/// 「史藏」父页用它做「全选」：当前搜索过滤后可见项的 key 列表。
///
/// 必须是**过滤后**的列表 —— 否则全选会选中被搜索隐藏的项，
/// 用户点删除时删掉看不见的东西。
List<String> historyVisibleKeys() {
  final kw = PlayerPrefs.instance.historyKeyword.value.trim().toLowerCase();
  final all = CacheStore.instance.records;
  final list = kw.isEmpty
      ? all
      : all.where((e) => e.vodName.toLowerCase().contains(kw)).toList();
  return list.map((e) => ShelfController.keyOf('history', e.vodId)).toList();
}

/// 删除历史（供「史藏」编辑模式批量删除调用）。
///
/// 按 vodId 回查原始记录拿 sourceKey —— removeRecord 需要两者，
/// 而我们的 key 是 `history|<vodId>`；vodId 本身可能含 `|`，
/// 所以不能简单 split，回查更稳。
Future<void> deleteHistoryItems(List<String> keys) async {
  final ids = keys
      .map((k) => k.startsWith('history|') ? k.substring(8) : k)
      .toSet();
  final targets = CacheStore.instance.records
      .where((r) => ids.contains(r.vodId))
      .toList();
  for (final r in targets) {
    await CacheStore.instance.removeRecord(r.vodId, r.sourceKey);
  }
}

/// 历史页 - 对应 Swift HistoryView
///
/// **2026-07-09 重构**: 从 GridView 卡片列表改为 ListView 详情列表
///
/// 原版用 VodCard 网格 (crossAxisCount: 4, aspectRatio: 0.65), 每个卡片
/// 只显示海报+名称, 用户反馈看不到"最后播放时间/集数/进度/标题". 改成
/// ListView 每项包含:
///   - 左侧封面 (16:9 缩略图, 失败时降级到带 URL 的占位图)
///   - 右侧标题 (vodName) + 集数 (playNote) + 进度 (mm:ss / mm:ss)
///   - 底部时间 (今天 HH:mm / 昨天 HH:mm / YYYY-MM-DD)
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final _searchCtrl = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String v) {
    PlayerPrefs.instance.historyKeyword.value = v.trim();
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
    final controller = Get.put(HistoryController());

    return Scaffold(
      // 透明背景,让 ContentView 全局背景层透出
      backgroundColor: Colors.transparent,
      body: Container(
        color: Colors.transparent,
        child: SafeArea(
          child: Column(
            children: [
              _buildToolbar(controller),
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
                style: TextStyle(color: AppTheme.textPrimary, fontSize: AppTheme.fontSubhead),
                decoration: InputDecoration(
                  hintText: '搜索历史…',
                  hintStyle:
                      TextStyle(color: AppTheme.textTertiary, fontSize: AppTheme.fontSubhead),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            Obx(() {
              if (PlayerPrefs.instance.historyKeyword.value.isEmpty) {
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
      builder: (ctx) => kbSheet(SafeArea(
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
                          fontSize: AppTheme.fontHeadline,
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
                          isSelected: prefs.historyGridColumns.value == n,
                          onTap: () async {
                            await prefs.setHistoryGridColumns(n);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        ),
                    ],
                  ),
                )),
          ],
        ),
      )),
    );
  }

  /// 工具栏：搜索 + 布局切换 + 清空
  ///（标题「播放历史」与「编辑/全选」由父页「史藏」统一提供）
  Widget _buildToolbar(HistoryController controller) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingXL, AppTheme.spacingSM, AppTheme.spacingXL, AppTheme.spacingSM),
      child: Row(
        children: [
          // 搜索（展开输入框）
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
          // 布局切换
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
          const Spacer(),
          Obx(() {
            if (CacheStore.instance.records.isEmpty) {
              return const SizedBox.shrink();
            }
            return TextButton(
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
            );
          }),
        ],
      ),
    );
  }
  Widget _buildContent(HistoryController controller) {
    return Obx(() {
      final allRecords = CacheStore.instance.records;
      // 搜索过滤：按片名不区分大小写包含匹配
      final kw = PlayerPrefs.instance.historyKeyword.value.toLowerCase();
      final all = kw.isEmpty
          ? allRecords
          : allRecords
              .where((e) => e.vodName.toLowerCase().contains(kw))
              .toList();
      final shown = controller.shown.value;
      final records =
          all.length > shown ? all.sublist(0, shown) : all;
      if (records.isEmpty) {
        if (kw.isNotEmpty) {
          return const EmptyState(
            title: '没有匹配的历史',
            message: '试试换个关键词',
            icon: Icons.search_off,
          );
        }
        return const EmptyState(
          title: '暂无历史记录',
          message: '观看影片后会自动记录',
          icon: Icons.history,
        );
      }

      // 网格布局（列数来自「布局切换」，2~6，默认 4）。
      // 原来是 ListView 竖排详情行，卡片又高又占地方；改成网格一屏能看更多。
      return LayoutBuilder(
        builder: (context, constraints) {
          final crossAxisCount =
              PlayerPrefs.instance.historyGridColumns.value.clamp(2, 6);
          final cardWidth =
              (constraints.maxWidth - AppTheme.cardSpacing * (crossAxisCount - 1)) /
                  crossAxisCount;
          // 卡片总高 = 图片区 + 标题区(约30)
          // 图片约 1.5 倍高（换算与明细见 favorites/view.dart）
          final aspect = cardWidth / (cardWidth * 1.015 + 30);
          final hasMore = all.length > shown;

          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spacingLG,
              AppTheme.spacingLG,
              AppTheme.spacingLG,
              100, // 底部预留悬浮导航栏空间
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              childAspectRatio: aspect,
              crossAxisSpacing: AppTheme.cardSpacing,
              mainAxisSpacing: AppTheme.cardSpacing,
            ),
            itemCount: records.length + (hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              // 最后一个是"加载更多"，占一格做成按钮
              if (index >= records.length) {
                return GestureDetector(
                  onTap: controller.showMore,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundTertiary,
                      borderRadius:
                          BorderRadius.circular(AppTheme.glassRadiusCard),
                      border: Border.all(
                          color: AppTheme.glassBorderSoft, width: 0.6),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.expand_more,
                            size: 22, color: AppTheme.textSecondary),
                        const SizedBox(height: 4),
                        Text('加载更多',
                            style: TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: AppTheme.fontCaption)),
                        Text('${all.length - shown}',
                            style: TextStyle(
                                color: AppTheme.textTertiary,
                                fontSize: AppTheme.fontCaption)),
                      ],
                    ),
                  ),
                );
              }
              final item = records[index];
              final shelf = ShelfController.instance;
              final key = ShelfController.keyOf('history', item.vodId);
              return Obx(() {
                final editing = shelf.editing.value;
                return VodCard(
                  video: Video(
                    id: item.vodId,
                    name: item.vodName,
                    pic: item.vodPic,
                    sourceKey: item.sourceKey,
                    // 备注里放集数/进度，让角标显示"第01集 00:20"
                    //（与首页/收藏角标同款外观）
                    note: item.playNote,
                  ),
                  // 图片区约 1.5 倍高（与上面的 aspect 配套）
                  posterHeightRatio: 1.015,
                  editMode: editing,
                  selected: shelf.isSelected(key),
                  onToggleSelect: () => shelf.toggleSelect(key),
                  onDelete: () => controller.deleteItem(item),
                  // 编辑模式下点卡片 = 切换选中，而不是继续播放
                  onTap: editing
                      ? () => shelf.toggleSelect(key)
                      : () => controller.openHistory(item),
                  onLongPress: editing
                      ? null
                      : () => _showDeleteConfirmDialog(context, controller, item),
                );
              });
            },
          );
        },
      );
    });
  }

  void _showDeleteConfirmDialog(
    BuildContext context,
    HistoryController controller,
    VodRecord item,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLG)),
        title: Text('删除记录',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('确定删除「${item.vodName}」的观看记录？',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () {
              controller.deleteItem(item);
              Navigator.pop(context);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showClearConfirmDialog(
    BuildContext context,
    HistoryController controller,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLG)),
        title: Text('清空历史',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('确定清空所有观看记录？此操作不可恢复。',
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

