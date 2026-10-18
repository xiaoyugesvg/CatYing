import 'package:flutter/material.dart';

/// 左滑操作项（编辑 / 分享 / 删除…）
class SwipeAction {
  const SwipeAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
}

/// 列表行「左滑露出操作」容器。
///
/// 不引入第三方 slidable：用水平拖拽 + 固定宽度操作区实现。
/// · 左滑露出右侧 [actions]；点空白处收起
/// · [enabled] = false 时完全不拦截手势（多选模式下用）
/// · 子组件自身的点击/长按不受影响（只有水平拖拽被接管）
class SwipeActionTile extends StatefulWidget {
  const SwipeActionTile({
    super.key,
    required this.child,
    required this.actions,
    this.enabled = true,
    this.backgroundColor = Colors.white,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
  });

  final Widget child;
  final List<SwipeAction> actions;
  final bool enabled;

  /// 前景（行本身）的底色 —— 必须不透明，否则会透出后面的操作按钮
  final Color backgroundColor;
  final BorderRadius borderRadius;

  @override
  State<SwipeActionTile> createState() => _SwipeActionTileState();
}

class _SwipeActionTileState extends State<SwipeActionTile> {
  static const double _actionWidth = 64;

  double _offset = 0;
  bool _dragging = false;

  double get _maxOffset => widget.actions.length * _actionWidth;

  void _close() {
    if (_offset == 0) return;
    setState(() => _offset = 0);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: Stack(
        children: [
          // 右侧操作区
          Positioned.fill(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (final a in widget.actions)
                  SizedBox(
                    width: _actionWidth,
                    child: Material(
                      color: a.color,
                      child: InkWell(
                        onTap: () {
                          _close();
                          a.onTap();
                        },
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(a.icon, size: 19, color: Colors.white),
                            const SizedBox(height: 3),
                            Text(
                              a.label,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 前景行
          GestureDetector(
            onHorizontalDragStart: (_) => setState(() => _dragging = true),
            onHorizontalDragUpdate: (d) {
              setState(() {
                _offset = (_offset + d.delta.dx).clamp(-_maxOffset, 0.0);
              });
            },
            onHorizontalDragEnd: (_) {
              setState(() {
                _dragging = false;
                _offset = _offset < -_maxOffset * 0.35 ? -_maxOffset : 0;
              });
            },
            child: AnimatedContainer(
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              transform: Matrix4.translationValues(_offset, 0, 0),
              child: ColoredBox(
                color: widget.backgroundColor,
                child: widget.child,
              ),
            ),
          ),
          // 打开状态：点前景任意处先收起，避免误触里面的按钮。
          // ⚠️ 只覆盖前景区域（右侧 _maxOffset 留给操作按钮），
          // 否则这层会把「编辑/分享/删除」的点击也吃掉。
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            right: _maxOffset,
            child: IgnorePointer(
              ignoring: _offset == 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
