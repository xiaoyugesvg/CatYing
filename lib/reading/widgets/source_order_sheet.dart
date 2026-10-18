import 'package:flutter/material.dart';

import '../../common/theme.dart';

/// 「调整源顺序」底部面板 —— 漫画页 / 书源页长按源标签共用。
///
/// 用户 2026-10-18：「源 tab 长按进入左右移动顺序功能」。
/// 面板里纵向拖动手柄即可改顺序；保存后由调用方写回各自的 Store。
Future<List<String>?> showSourceOrderSheet(
  BuildContext context, {
  required String title,
  required List<(String id, String name)> items,
}) {
  final order = List<(String, String)>.of(items);
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: isDark ? AppTheme.backgroundSecondary : Colors.white,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 10, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(
                        ctx,
                        order.map((e) => e.$1).toList(),
                      ),
                      child: Text(
                        '保存',
                        style: TextStyle(color: AppTheme.accentOnSurface),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '按住右侧把手上下拖动，调整源在标签栏里的顺序',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
                ),
              ),
              Flexible(
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                  itemCount: order.length,
                  onReorder: (oldIndex, newIndex) {
                    var target = newIndex;
                    if (target > oldIndex) target -= 1;
                    setSheet(() {
                      final moved = order.removeAt(oldIndex);
                      order.insert(target, moved);
                    });
                  },
                  itemBuilder: (_, i) => ReorderableDelayedDragStartListener(
                    key: ValueKey('src_order_${order[i].$1}'),
                    index: i,
                    child: ListTile(
                      dense: true,
                      title: Text(
                        order[i].$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontSubhead,
                        ),
                      ),
                      trailing: Icon(
                        Icons.drag_handle_rounded,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
