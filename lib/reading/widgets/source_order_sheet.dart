import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../common/theme.dart';

/// 「调整源顺序」底部面板 —— 漫画页 / 书源页长按源标签共用。
///
/// 用户 2026-10-18：
///   · 源 tab 长按进入左右移动顺序功能；
///   · 面板支持视图切换：列表 / 两列 / 三列 / 四列；
///   · 网格模式按住卡片即可拖动调整顺序。
///
/// 用户 2026-10-18（补）：视图（列数）必须**记住** ——
/// 之前每次长按都从列表重建，用户切到两列后一长按又变回列表。
Future<List<String>?> showSourceOrderSheet(
  BuildContext context, {
  required String title,
  required List<(String id, String name)> items,
}) async {
  final order = List<(String, String)>.of(items);
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final savedCols = await _loadCols();
  // 面板状态（列数）必须放在 builder 外面，否则每次 setState 都会重置回列表
  final state = _OrderSheetState(cols: savedCols);
  if (!context.mounted) return null;
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: isDark ? AppTheme.backgroundSecondary : Colors.white,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => _OrderSheetBody(
        title: title,
        order: order,
        isDark: isDark,
        onChanged: () => setSheet(() {}),
        onSave: () => Navigator.pop(
          ctx,
          order.map((e) => e.$1).toList(),
        ),
        state: state,
        onColsChanged: (v) {
          state.cols = v;
          _saveCols(v);
          setSheet(() {});
        },
      ),
    ),
  );
}

/// 面板视图（列数）持久化键 —— 漫画/书源两个入口共用同一偏好
const String _kOrderSheetCols = 'reading_source_order_cols';

/// 进程内缓存：避免每次长按都读一次 SharedPreferences
int? _cachedCols;

Future<int> _loadCols() async {
  if (_cachedCols != null) return _cachedCols!;
  try {
    final p = await SharedPreferences.getInstance();
    final v = p.getInt(_kOrderSheetCols);
    _cachedCols = (v != null && v >= 1 && v <= 4) ? v : 1;
  } catch (_) {
    _cachedCols = 1;
  }
  return _cachedCols!;
}

void _saveCols(int v) {
  _cachedCols = v;
  SharedPreferences.getInstance()
      .then((p) => p.setInt(_kOrderSheetCols, v))
      .catchError((_) => false);
}

/// 面板内部状态（列数）。
class _OrderSheetState {
  _OrderSheetState({required this.cols});
  int cols;
}

class _OrderSheetBody extends StatelessWidget {
  const _OrderSheetBody({
    required this.title,
    required this.order,
    required this.isDark,
    required this.onChanged,
    required this.onSave,
    required this.state,
    required this.onColsChanged,
  });

  final String title;
  final List<(String, String)> order;
  final bool isDark;
  final VoidCallback onChanged;
  final VoidCallback onSave;
  final _OrderSheetState state;
  final ValueChanged<int> onColsChanged;

  void _move(int from, int to) {
    if (from == to || from < 0 || from >= order.length) return;
    final moved = order.removeAt(from);
    final target = to.clamp(0, order.length);
    order.insert(target, moved);
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final cols = state.cols;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
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
                  // 视图切换：列表 / 两列 / 三列 / 四列
                  PopupMenuButton<int>(
                    tooltip: '切换视图',
                    initialValue: cols,
                    color: isDark ? AppTheme.backgroundSecondary : Colors.white,
                    onSelected: onColsChanged,
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 1,
                        child: Row(
                          children: [
                            Icon(Icons.view_list_rounded, size: 17),
                            SizedBox(width: 8),
                            Text('列表'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 2,
                        child: Row(
                          children: [
                            Icon(Icons.grid_view_rounded, size: 17),
                            SizedBox(width: 8),
                            Text('两列'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 3,
                        child: Row(
                          children: [
                            Icon(Icons.grid_view_rounded, size: 17),
                            SizedBox(width: 8),
                            Text('三列'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 4,
                        child: Row(
                          children: [
                            Icon(Icons.grid_view_rounded, size: 17),
                            SizedBox(width: 8),
                            Text('四列'),
                          ],
                        ),
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        cols == 1
                            ? Icons.view_list_rounded
                            : Icons.grid_view_rounded,
                        size: 20,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onSave,
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
                  cols == 1 ? '按住右侧把手上下拖动，调整源在标签栏里的顺序' : '按住卡片拖动，调整源在标签栏里的顺序',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
              ),
            ),
            Flexible(
              child: cols == 1 ? _buildList() : _buildGrid(context, cols),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    return ReorderableListView.builder(
      shrinkWrap: true,
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      itemCount: order.length,
      onReorder: (oldIndex, newIndex) {
        var target = newIndex;
        if (target > oldIndex) target -= 1;
        _move(oldIndex, target);
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
    );
  }

  Widget _buildGrid(BuildContext context, int cols) {
    const spacing = 8.0;
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final cellW = (constraints.maxWidth - spacing * (cols - 1)) / cols;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            mainAxisExtent: 46,
          ),
          itemCount: order.length,
          itemBuilder: (_, i) {
            final card = _gridCard(
              order[i].$2,
              highlighted: false,
            );
            return DragTarget<int>(
              onWillAcceptWithDetails: (d) => d.data != i,
              onAcceptWithDetails: (d) {
                _move(d.data, i);
              },
              builder: (ctx, candidate, _) {
                final hover = candidate.isNotEmpty;
                return LongPressDraggable<int>(
                  data: i,
                  feedback: Material(
                    color: Colors.transparent,
                    child: SizedBox(
                      width: cellW,
                      height: 46,
                      child: _gridCard(order[i].$2, highlighted: true),
                    ),
                  ),
                  childWhenDragging: Opacity(
                    opacity: 0.30,
                    child: card,
                  ),
                  child: hover
                      ? _gridCard(order[i].$2, highlighted: true)
                      : card,
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _gridCard(String name, {required bool highlighted}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: highlighted
            ? AppTheme.accentColor.withValues(alpha: 0.16)
            : (isDark ? AppTheme.palette.cardDark : Colors.white),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: highlighted
              ? AppTheme.accentColor.withValues(alpha: 0.55)
              : AppTheme.borderLight,
        ),
      ),
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
