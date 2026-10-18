import 'package:flutter/material.dart';

import '../theme/jelly_theme.dart';

/// 分组名归一化：空 → 「未分组」（与「源仓库」页同一口径）。
String sourceGroupLabel(String raw) {
  final t = raw.trim();
  return t.isEmpty ? '未分组' : t;
}

/// 收集源分组（去重 + 按名称排序，不含「全部」）。
List<String> collectSourceGroups(Iterable<String> rawGroups) {
  final set = <String>{};
  for (final g in rawGroups) {
    set.add(sourceGroupLabel(g));
  }
  final list = set.toList()..sort((a, b) => a.compareTo(b));
  return list;
}

/// 快速源弹窗顶部的分组 tab：`[全部]` + 各分组，可横向滑动。
///
/// 分组口径与「源仓库」页一致（Legado 的 `bookSourceGroup`，空 = 未分组）。
class SourceGroupTabs extends StatelessWidget {
  const SourceGroupTabs({
    super.key,
    required this.groups,
    required this.selected,
    required this.onSelected,
  });

  /// 不含「全部」（内部补在最前面）。
  final List<String> groups;
  final String selected;
  final ValueChanged<String> onSelected;

  static const String all = '全部';

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: groups.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final label = i == 0 ? all : groups[i - 1];
          final sel = label == selected;
          return GestureDetector(
            onTap: () => onSelected(label),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              decoration: BoxDecoration(
                color: sel
                    ? JellyTheme.primary
                    : JellyTheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(17),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                  color: sel ? Colors.white : JellyTheme.primary,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 「搜索源」弹窗里没有匹配源时的占位。
class QuickSourcesEmpty extends StatelessWidget {
  const QuickSourcesEmpty({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Text(
          '没有匹配的源',
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
      ),
    );
  }
}
