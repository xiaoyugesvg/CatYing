import 'package:flutter/material.dart';
import '../../common/theme.dart';

/// 剧集列表组件 - 对应 Swift EpisodeListView
/// **2026-09-26 UI 重构（对照参考图）**：
/// - 头部：「合集 正在播放：第X集」+ 右侧「查看全部」按钮
/// - 下方横向滚动剧集卡片（当前集绿色圆点标记）
/// - 点「查看全部」弹出网格选集弹窗（每行 5 个，当前集绿色边框高亮）
class EpisodeListView extends StatefulWidget {
  final List<String> episodeNames;
  final int selectedIndex;
  final ValueChanged<int> onEpisodeTap;

  const EpisodeListView({
    super.key,
    required this.episodeNames,
    required this.selectedIndex,
    required this.onEpisodeTap,
  });

  @override
  State<EpisodeListView> createState() => _EpisodeListViewState();
}

class _EpisodeListViewState extends State<EpisodeListView> {
  /// 网格弹窗当前页（每页 10 集：1-10 / 11-20 ...）
  int _gridPage = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.episodeNames.isEmpty) return const SizedBox.shrink();

    final currentName = widget.episodeNames[widget.selectedIndex];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 头部行：合集 正在播放：第X集 …… 查看全部
        Row(
          children: [
            Text(
              '合集',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: AppTheme.spacingMD),
            Expanded(
              child: Text(
                '正在播放：$currentName',
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // 查看全部
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showAllEpisodesSheet,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(AppTheme.radiusSM),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '查看全部',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: AppTheme.fontCaption,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    SizedBox(width: 2),
                    Icon(
                      Icons.chevron_right,
                      size: 14,
                      color: AppTheme.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.spacingMD),

        // 横向滚动剧集卡片（当前集绿色圆点标记）
        SizedBox(
          height: 66,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: widget.episodeNames.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, i) =>
                _buildEpisodeCard(globalIndex: i, name: widget.episodeNames[i]),
          ),
        ),
      ],
    );
  }

  /// 横向剧集卡片 - 对应参考图：深色卡片 + 当前集绿色圆点
  Widget _buildEpisodeCard({
    required int globalIndex,
    required String name,
  }) {
    final isSelected = globalIndex == widget.selectedIndex;
    return GestureDetector(
      onTap: () => widget.onEpisodeTap(globalIndex),
      child: Container(
        width: 64,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accentColor.withValues(alpha: 0.10)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(AppTheme.radiusMD),
          border: Border.all(
            color: isSelected
                ? AppTheme.accentColor.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.06),
            width: 1.2,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 当前集绿点
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(bottom: 5),
              decoration: BoxDecoration(
                color:
                    isSelected ? AppTheme.accentColor : Colors.transparent,
                shape: BoxShape.circle,
              ),
            ),
            Flexible(
              child: Text(
                name,
                style: TextStyle(
                  color:
                      isSelected ? AppTheme.accentColor : AppTheme.textSecondary,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 当前页的剧集切片（每页 10 集）
  List<String> get _pagedNames {
    final start = _gridPage * 10;
    final end = (start + 10).clamp(0, widget.episodeNames.length);
    return widget.episodeNames.sublist(start, end);
  }

  /// 分页 tab 行：1-10 / 11-20 ...（超过 10 集才显示）
  Widget _buildGridPager({void Function(int page)? onPageChanged}) {
    final total = widget.episodeNames.length;
    if (total <= 10) return const SizedBox.shrink();
    final pageCount = (total / 10).ceil();
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: pageCount,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, p) {
          final isSelected = p == _gridPage;
          final start = p * 10 + 1;
          final end = ((p + 1) * 10).clamp(0, total);
          final label = '$start-$end';
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (onPageChanged != null) {
                onPageChanged(p);
              } else {
                setState(() => _gridPage = p);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.accentColor.withValues(alpha: 0.14)
                    : AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.accentColor.withValues(alpha: 0.6)
                      : Colors.white.withValues(alpha: 0.06),
                  width: isSelected ? 1.2 : 0.6,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? AppTheme.accentColor : AppTheme.textSecondary,
                  fontSize: AppTheme.fontCaption,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 网格选集弹窗 - 对应参考图：合集标题 + 每行 5 个 + 当前集绿框
  void _showAllEpisodesSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
        initialChildSize: 0.62,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: AppTheme.backgroundPrimary,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部拖拽指示条
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // 标题行：合集 …… 关闭
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 12, 12),
                child: Row(
                  children: [
                    Text(
                      '合集',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: AppTheme.backgroundTertiary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.close,
                          size: 18,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 分页 tab（1-10 / 11-20 ...）
              _buildGridPager(onPageChanged: (p) {
                setSheetState(() => _gridPage = p);
                setState(() => _gridPage = p);
              }),
              const SizedBox(height: 8),
              // 网格剧集（当前页切片）
              Expanded(
                child: GridView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.35,
                  ),
                  itemCount: _pagedNames.length,
                  itemBuilder: (context, i) {
                    final globalIndex = _gridPage * 10 + i;
                    final isSelected = globalIndex == widget.selectedIndex;
                    return GestureDetector(
                      onTap: () {
                        Navigator.pop(ctx);
                        widget.onEpisodeTap(globalIndex);
                      },
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppTheme.accentColor.withValues(alpha: 0.12)
                              : AppTheme.backgroundTertiary,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSelected
                                ? AppTheme.accentColor
                                : Colors.white.withValues(alpha: 0.06),
                            width: isSelected ? 1.6 : 0.6,
                          ),
                        ),
                        child: Text(
                          _pagedNames[i],
                          style: TextStyle(
                            color: isSelected
                                ? AppTheme.accentColor
                                : AppTheme.textSecondary,
                            fontSize: AppTheme.fontCaption,
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.normal,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
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
      ),
    );
  }
}
