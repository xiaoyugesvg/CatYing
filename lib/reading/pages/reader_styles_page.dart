import 'package:flutter/material.dart';

import '../models/reader_style.dart';

/// 独立的「阅读样式」库页面。
///
/// 为什么单独一页：内置样式 + 我的样式原来都塞在阅读设置面板的「样式」tab 里，
/// 面板本身只有屏幕 80% 高、还要滚动，样式一多就找不到。这里给它们一个完整页面：
///   · 内置样式网格（点一下直接套用并返回阅读器）
///   · 我的样式列表（可编辑 / 删除）
///   · 底部「保存当前外观为样式」
///
/// 页面只负责**浏览和选择**，真正的套用/保存/编辑仍由阅读器页实现，
/// 通过回调把结果回传（保存/编辑返回最新的「我的样式」列表）。
class ReaderStylesPage extends StatefulWidget {
  const ReaderStylesPage({
    super.key,
    required this.builtins,
    required this.mine,
    required this.activeId,
    required this.background,
    required this.foreground,
    required this.onSaveCurrent,
    required this.onEdit,
    required this.onDelete,
  });

  final List<ReaderStyle> builtins;
  final List<ReaderStyle> mine;
  final String? activeId;

  /// 页面底色 / 前景色（跟随阅读器当前配色，避免深色阅读器里弹出一张白页）
  final Color background;
  final Color foreground;

  /// 保存当前外观为样式；返回最新的「我的样式」列表
  final Future<List<ReaderStyle>> Function() onSaveCurrent;

  /// 编辑某个我的样式；返回最新列表
  final Future<List<ReaderStyle>> Function(ReaderStyle) onEdit;

  /// 删除某个我的样式；返回最新列表
  final Future<List<ReaderStyle>> Function(ReaderStyle) onDelete;

  @override
  State<ReaderStylesPage> createState() => _ReaderStylesPageState();
}

class _ReaderStylesPageState extends State<ReaderStylesPage> {
  late List<ReaderStyle> _mine = List.of(widget.mine);
  bool _busy = false;

  Color get _fg => widget.foreground;
  Color get _bg => widget.background;

  Future<void> _run(Future<List<ReaderStyle>> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final list = await action();
      if (!mounted) return;
      setState(() => _mine = List.of(list));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: _fg,
        title: Text(
          '阅读样式',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: _fg,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          _label('内置样式（点一下立即套用）'),
          Wrap(
            spacing: 10,
            runSpacing: 12,
            children: [
              for (final s in widget.builtins)
                _card(s, onTap: () => Navigator.of(context).pop(s)),
            ],
          ),
          if (_mine.isNotEmpty) ...[
            const SizedBox(height: 18),
            _label('我的样式'),
            for (final s in _mine) _row(s),
          ],
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(widget.onSaveCurrent),
              icon: Icon(Icons.add_rounded, size: 18, color: _fg),
              label: Text(
                '把当前外观存为样式',
                style: TextStyle(color: _fg, fontSize: 14),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: _fg.withValues(alpha: 0.22)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 10),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: _fg.withValues(alpha: 0.55),
        letterSpacing: 0.3,
      ),
    ),
  );

  /// 一张样式卡：迷你书页 + 名字
  Widget _card(ReaderStyle s, {required VoidCallback onTap}) {
    final selected = widget.activeId == s.id;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 104,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                _preview(s, selected: selected),
                if (selected)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Icon(
                      Icons.check_circle_rounded,
                      size: 16,
                      color: _fg,
                      shadows: const [
                        Shadow(color: Colors.black45, blurRadius: 4),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: _fg.withValues(alpha: selected ? 1 : 0.72),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(ReaderStyle s) {
    final selected = widget.activeId == s.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: _fg.withValues(alpha: selected ? 0.10 : 0.05),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.of(context).pop(s),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                SizedBox(width: 48, child: _preview(s, selected: selected)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: _fg,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${s.fontSize.round()} 号 · 行高 ${s.lineHeight.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: _fg.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.edit_outlined, size: 18, color: _fg),
                  onPressed: _busy ? null : () => _run(() => widget.onEdit(s)),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: _fg.withValues(alpha: 0.72),
                  ),
                  onPressed: _busy
                      ? null
                      : () => _run(() => widget.onDelete(s)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 迷你书页：样式自己的底色 / 壁纸 / 字色 / 行距
  Widget _preview(ReaderStyle s, {required bool selected}) {
    final bg = s.bgColor != null ? Color(s.bgColor!) : const Color(0xFFFFFFFF);
    final dark = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
    final fg = s.fgColor != null
        ? Color(s.fgColor!)
        : (dark ? const Color(0xFFE2E2E2) : const Color(0xFF1A1A1A));
    final gap = (s.lineHeight - 1).clamp(0.15, 1.2) * 4;
    return Container(
      height: 66,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? _fg : _fg.withValues(alpha: 0.16),
          width: selected ? 2 : 1,
        ),
        image: s.bgImageAsset == null
            ? null
            : DecorationImage(
                image: AssetImage(s.bgImageAsset!),
                fit: BoxFit.cover,
              ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            height: 4,
            width: 26,
            margin: const EdgeInsets.only(bottom: 5),
            color: fg.withValues(alpha: 0.85),
          ),
          for (var i = 0; i < 3; i++) ...[
            Container(
              height: 2.5,
              width: i == 2 ? 26 : double.infinity,
              color: fg.withValues(alpha: 0.5),
            ),
            SizedBox(height: 2 + gap),
          ],
        ],
      ),
    );
  }
}
