import 'package:flutter/material.dart';
import '../../common/theme.dart';

/// 选集列表 - 对应 Swift EpisodeListView
/// **2026-09-26 分页化**：超过 10 集时按「1-10 / 11-20 / 21-30 …」分页切换，
/// 不再一屏塞下所有集数。
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
  static const int _pageSize = 10;
  /// 当前页码（0-based），切换集数时自动跳到所在页
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _page = widget.selectedIndex ~/ _pageSize;
  }

  @override
  void didUpdateWidget(covariant EpisodeListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex != oldWidget.selectedIndex) {
      setState(() {
        _page = widget.selectedIndex ~/ _pageSize;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.episodeNames;
    if (names.isEmpty) return const SizedBox.shrink();

    final pageCount = (names.length + _pageSize - 1) ~/ _pageSize;
    if (_page >= pageCount) _page = pageCount - 1;

    final start = _page * _pageSize;
    final end = (start + _pageSize).clamp(0, names.length);
    final visible = names.sublist(start, end);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 分页切换行：1-10 / 11-20 / 21-30 …
        if (pageCount > 1) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(pageCount, (page) {
                final isSelected = page == _page;
                final labelStart = page * _pageSize + 1;
                final labelEnd = ((page + 1) * _pageSize).clamp(0, names.length);
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _page = page),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppTheme.accentColor.withValues(alpha: 0.14)
                            : AppTheme.backgroundTertiary,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isSelected
                              ? AppTheme.accentColor.withValues(alpha: 0.4)
                              : AppTheme.borderLight,
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        '$labelStart-$labelEnd',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                          color: isSelected
                              ? AppTheme.accentColor
                              : AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 12),
        ],
        // 当前页集数网格
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(visible.length, (i) {
            final index = start + i;
            final isSelected = index == widget.selectedIndex;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onEpisodeTap(index),
              child: Container(
                width: 52,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppTheme.accentColor
                      : AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected
                        ? AppTheme.accentColor
                        : AppTheme.borderLight,
                    width: 0.8,
                  ),
                ),
                child: Text(
                  visible[i],
                  style: TextStyle(
                    fontSize: 12,
                    color: isSelected ? Colors.white : AppTheme.textPrimary,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            );
          }),
        ),
      ],
    );
  }
}
