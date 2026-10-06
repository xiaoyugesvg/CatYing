import 'package:flutter/material.dart';

/// 顶栏「聚合菜单」按钮：一个图标按钮，点击在按钮**正下方**展开菜单面板。
///
/// 菜单面板交互（用户 2026-10-06 确认，漫画页 / 图书页 / 书源页共用）：
/// · 收起态：只显示一个「⋯」图标按钮（显示第一）
/// · 点开 → **横滑轮播**：4 个菜单项一次只显示一个，左右滑动切换
/// · **下拉手势** → 展开竖排：4 个菜单项一列对齐（对齐「⋯」按钮）
/// · 上拉手势 → 收起面板；点面板外区域也关闭
class JellyIconMenuButton extends StatefulWidget {
  const JellyIconMenuButton({
    super.key,
    required this.isDark,
    required this.actions,
    this.icon = Icons.more_horiz_rounded,
    this.tooltip = '更多',
    this.size = 32,
    this.menuWidth = 96,
  });

  final bool isDark;

  /// 菜单项：图标 + 点击动作（横滑轮播 / 竖排共用）
  final List<({IconData icon, String tooltip, VoidCallback onTap})> actions;

  final IconData icon;
  final String tooltip;
  final double size;
  final double menuWidth;

  @override
  State<JellyIconMenuButton> createState() => _JellyIconMenuButtonState();
}

class _JellyIconMenuButtonState extends State<JellyIconMenuButton> {
  /// 挂在实际圆形按钮上，面板锚点以此为准。
  ///
  /// ⚠️ 不能用 `context.findRenderObject()`：StatelessWidget/State 的
  /// context 没有自己的 RenderObject，findRenderObject 会**下钻到子树里
  /// 第一个 RenderObject**（可能是 Tooltip 内部结构），拿到的全局坐标
  /// 会偏到旁边按钮的位置 —— 表现就是菜单从「筛选」图标下方弹出
  /// 而不是从本按钮正下方弹出。GlobalKey 直接钉住实际圆按钮。
  final GlobalKey _btnKey = GlobalKey();
  OverlayEntry? _entry;

  void _openMenu() {
    final actions = widget.actions;
    if (actions.isEmpty) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final box = _btnKey.currentContext?.findRenderObject() as RenderBox?;
    if (overlay == null || box == null) return;
    // 按钮右下角全局坐标：面板右缘对齐按钮右缘、从按钮正下方往下展开
    final pos = box.localToGlobal(Offset.zero);
    _close();
    final entry = OverlayEntry(
      builder: (_) => Material(
        // OverlayEntry 无 Material 上下文 → 里面 Text 会触发 Flutter
        // 「DefaultTextStyle 缺失」黄色调试线（用户遇到的"双黄线"）。
        // 包一层透明 Material 补齐 DefaultTextStyle / InkWell 涟漪。
        type: MaterialType.transparency,
        child: Stack(
          children: [
            // 透明 barrier：点击面板外区域关闭
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _close,
              ),
            ),
            Positioned(
              left: pos.dx + box.size.width - widget.menuWidth,
              top: pos.dy + box.size.height + 6,
              child: _JellyIconMenuPanel(
                isDark: widget.isDark,
                actions: actions,
                width: widget.menuWidth,
                onClose: _close,
              ),
            ),
          ],
        ),
      ),
    );
    _entry = entry;
    Overlay.of(context).insert(entry);
  }

  void _close() {
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 参考样式：黑色实心圆 + 白色图标（浅色）；深色模式白圆 + 深色图标
    final filled = widget.isDark ? Colors.white : const Color(0xFF17181C);
    final fg = widget.isDark ? const Color(0xFF17181C) : Colors.white;
    return Tooltip(
      message: widget.tooltip,
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _openMenu,
          child: Container(
            key: _btnKey,
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.14),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Center(
              child: Icon(widget.icon, size: 18, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

/// 菜单面板：横滑轮播（一次一个，左右滑动）⇄ 竖排一列（下拉展开）。
class _JellyIconMenuPanel extends StatefulWidget {
  const _JellyIconMenuPanel({
    required this.isDark,
    required this.actions,
    required this.width,
    required this.onClose,
  });

  final bool isDark;
  final List<({IconData icon, String tooltip, VoidCallback onTap})> actions;
  final double width;
  final VoidCallback onClose;

  @override
  State<_JellyIconMenuPanel> createState() => _JellyIconMenuPanelState();
}

class _JellyIconMenuPanelState extends State<_JellyIconMenuPanel> {
  bool _vertical = false;
  final PageController _pageController = PageController();

  @override
  void initState() {
    super.initState();
    // 监听页码变化刷新指示器圆点
    _pageController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Color get _fg => widget.isDark ? Colors.white : const Color(0xFF17181C);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // 下拉 → 竖排展开全部；上拉 → 收起面板
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity;
        if (v == null) return;
        if (v > 300) {
          setState(() => _vertical = true);
        } else if (v < -300) {
          widget.onClose();
        }
      },
      child: Container(
        width: widget.width,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: widget.isDark ? const Color(0xFF1C1C1E) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: _vertical ? _buildColumn() : _buildCarousel(),
      ),
    );
  }

  /// 横滑轮播：一次只显示一个菜单项，左右滑动切换
  Widget _buildCarousel() {
    final actions = widget.actions;
    final fg = _fg;
    final page = _pageController.hasClients
        ? (_pageController.page ?? 0).round()
        : 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 92,
          child: PageView.builder(
            controller: _pageController,
            itemCount: actions.length,
            itemBuilder: (context, i) {
              final a = actions[i];
              return GestureDetector(
                onTap: () {
                  a.onTap();
                  widget.onClose();
                },
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.isDark
                            ? Colors.white.withValues(alpha: 0.10)
                            : const Color(0xFF17181C).withValues(alpha: 0.06),
                        border: Border.all(
                          color: fg.withValues(alpha: 0.25),
                          width: 1.2,
                        ),
                      ),
                      child: Icon(a.icon, size: 24, color: fg),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      a.tooltip,
                      style: TextStyle(
                        fontSize: 11,
                        color: fg.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        // 页码指示器（当前页高亮）
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: page == i ? 7 : 5,
                  height: page == i ? 7 : 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: page == i
                        ? fg
                        : fg.withValues(alpha: 0.25),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 竖排一列：菜单项从上到下对齐（对齐「⋯」按钮所在列）
  Widget _buildColumn() {
    final actions = widget.actions;
    final fg = _fg;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(height: 4),
          _columnItem(actions[i]),
        ],
      ],
    );
  }

  Widget _columnItem(({IconData icon, String tooltip, VoidCallback onTap}) a) {
    final fg = _fg;
    return InkWell(
      onTap: () {
        a.onTap();
        widget.onClose();
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: widget.width,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.isDark
                    ? Colors.white.withValues(alpha: 0.10)
                    : const Color(0xFF17181C).withValues(alpha: 0.06),
                border: Border.all(
                  color: fg.withValues(alpha: 0.25),
                  width: 1.2,
                ),
              ),
              child: Icon(a.icon, size: 17, color: fg),
            ),
            const SizedBox(height: 3),
            Text(
              a.tooltip,
              style: TextStyle(
                fontSize: 10,
                color: fg.withValues(alpha: 0.75),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
