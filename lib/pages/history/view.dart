import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../models/movie.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/vod_card.dart';
import '../../models/cache_store.dart';
import 'controller.dart';

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
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

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
              _buildHeader(controller),
              Expanded(child: _buildContent(controller)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(HistoryController controller) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingXL, AppTheme.spacingLG, AppTheme.spacingXL, AppTheme.spacingSM),
      child: Row(
        children: [
          Text(
            '历史记录',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontTitle3,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          Obx(() {
            if (CacheStore.instance.records.isEmpty) return const SizedBox.shrink();
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
      final all = CacheStore.instance.records;
      final shown = controller.shown.value;
      final records =
          all.length > shown ? all.sublist(0, shown) : all;
      if (records.isEmpty) {
        return const EmptyState(
          title: '暂无历史记录',
          message: '观看影片后会自动记录',
          icon: Icons.history,
        );
      }

      // 一排 4 个的网格（与收藏页一致）。
      // 原来是 ListView 竖排详情行，卡片又高又占地方；改成网格一屏能看更多。
      return LayoutBuilder(
        builder: (context, constraints) {
          const crossAxisCount = 4;
          final cardWidth =
              (constraints.maxWidth - AppTheme.cardSpacing * (crossAxisCount - 1)) /
                  crossAxisCount;
          // 卡片高度 = 收藏卡片的 3/4（换算说明见 favorites/view.dart）
          final aspect = cardWidth / (cardWidth * 0.4875 + 50);
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
                onTap: () => controller.openHistory(item),
                onLongPress: () =>
                    _showDeleteConfirmDialog(context, controller, item),
              );
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

