import 'package:flutter/material.dart';
import '../../common/theme.dart';

/// 剧集列表组件 - 对应 Swift EpisodeListView
/// **2026-09-26 重写**：由"50 集一组全部平铺"改为"每页 10 集 +
/// 页码切换（1-10 / 11-20 / 21-30 ...）",避免超长剧集列表一次
/// 渲染上百个 chip 导致卡顿，也让用户能快速跳转到任意区间。
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
  /// 每页集数（用户要求 1-10 / 11-20 这种按 10 集一页切换）
  static const int _pageSize = 10;

  /// 当前页码（0 基）
  late int _page;

  @override
  void initState() {
    super.initState();
    // 初始定位到已选集所在的页，进入即看到当前播放的集
    _page = widget.selectedIndex ~/ _pageSize;
  }

  @override
  void didUpdateWidget(EpisodeListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 选集切换（如播放器内切集）后若超出当前页，跟随跳页
    final targetPage = widget.selectedIndex ~/ _pageSize;
    if (targetPage != _page && _pageValid(targetPage)) {
      _page = targetPage;
    }
  }

  int get _pageCount {
    final total = widget.episodeNames.length;
    if (total == 0) return 1;
    return (total + _pageSize - 1) ~/ _pageSize;
  }

  bool _pageValid(int page) => page >= 0 && page < _pageCount;

  /// 当前页的全局起始/结束下标（含）
  (int, int) get _currentRange {
    final start = _page * _pageSize;
    final end =
        (start + _pageSize - 1).clamp(0, widget.episodeNames.length - 1);
    return (start, end);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.episodeNames.isEmpty) return const SizedBox.shrink();
    final (start, end) = _currentRange;
    final pageCount = _pageCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 页切换条（仅超过 1 页即 >10 集时才显示）：
        // 左箭头 + 页码胶囊（可横向滑动）+ 右箭头
        if (pageCount > 1) ...[  
          Row(
            children: [
              _buildPageArrow(
                icon: Icons.chevron_left,
                enabled: _page > 0,
                onTap: () => setState(() {
                  if (_page > 0) _page--;
                }),
              ),
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: pageCount,
                    itemBuilder: (context, i) {
                      final pageStart = i * _pageSize + 1;
                      final pageEnd =
                          ((i + 1) * _pageSize)
                              .clamp(1, widget.episodeNames.length);
                      return _buildPagePill(
                        title: '$pageStart-$pageEnd',
                        isSelected: i == _page,
                        onTap: () => setState(() => _page = i),
                      );
                    },
                  ),
                ),
              ),
              _buildPageArrow(
                icon: Icons.chevron_right,
                enabled: _page < pageCount - 1,
                onTap: () => setState(() {
                  if (_page < pageCount - 1) _page++;
                }),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spacingMD),
        ],

        // 当前页剧集 chip
        Wrap(
          spacing: AppTheme.spacingSM,
          runSpacing: AppTheme.spacingSM,
          children: [
            for (var i = start; i <= end; i++)
              _buildEpisodeChip(
                globalIndex: i,
                name: widget.episodeNames[i],
                isSelected: i == widget.selectedIndex,
              ),
          ],
        ),
      ],
    );
  }

  /// 页码胶囊（1-10 / 11-20 ...）
  Widget _buildPagePill({
    required String title,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: AppTheme.spacingSM),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected
                ? AppTheme.accentColor.withValues(alpha: 0.14)
                : AppTheme.backgroundTertiary,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected
                  ? AppTheme.accentColor.withValues(alpha: 0.45)
                  : Colors.white.withValues(alpha: 0.06),
              width: isSelected ? 1 : 0.5,
            ),
          ),
          child: Text(
            title,
            style: TextStyle(
              color: isSelected ? AppTheme.accentColor : AppTheme.textSecondary,
              fontSize: AppTheme.fontFootnote,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPageArrow({
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled
              ? AppTheme.backgroundTertiary
              : AppTheme.backgroundTertiary.withValues(alpha: 0.4),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 18,
          color: enabled ? AppTheme.textSecondary : AppTheme.textTertiary,
        ),
      ),
    );
  }

  Widget _buildEpisodeChip({
    required int globalIndex,
    required String name,
    required bool isSelected,
  }) {
    return GestureDetector(
      onTap: () => widget.onEpisodeTap(globalIndex),
      child: Container(
        constraints: const BoxConstraints(minWidth: 60, maxWidth: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accentColor.withValues(alpha: 0.15)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(AppTheme.radiusSM),
          border: isSelected
              ? Border.all(color: AppTheme.accentColor.withValues(alpha: 0.4))
              : null,
        ),
        child: Text(
          name,
          style: TextStyle(
            color: isSelected ? AppTheme.accentColor : AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}