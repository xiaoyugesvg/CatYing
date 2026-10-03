import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../theme/jelly_theme.dart';

/// **果冻风常驻小胶囊搜索框** —— 与影视首页右上角同款样式：
/// 本身就是输入框（不点开），图标在**左侧**，提示文字如
/// 「搜索书架 / 搜索漫画 / 搜索图书 / 搜索收藏」。
///
/// ── 与 `JellySearchBar` 的关系（别用错）──────────────────────
///   · [JellyExpandableSearch] —— **顶栏/标题行**用，常驻小胶囊，
///      高度默认 36（不超过同排圆钮图标高度），不占整行视觉重量。
///   · `JellySearchBar`        —— **弹窗/半屏面板/浮层**里用（`showModalBottomSheet`、
///      搜索浮层）。那种场景本来就需要一个显眼的常驻输入框（还带 `autofocus`），
///      保持不动。
///
/// ── 规格（与首页 `AppExpandableSearch` 对齐）────────────────
/// 常驻胶囊 / 默认高 36 圆角 18（可经 [height] 调）/ 底色 JellyTheme 卡片色 /
/// 无描边靠阴影分离 / 图标在左 / 字号 fontHeadline。
/// 配色走 JellyTheme，切明暗/外观自动跟随。
class JellyExpandableSearch extends StatefulWidget {
  const JellyExpandableSearch({
    super.key,
    required this.onSubmitted,

    /// 输入框里的提示文字（搜索书架 / 搜索收藏 / 搜索漫画 / 搜索图书 …）
    this.hintText = '搜索',

    /// 胶囊高度（默认 36，不超过同排圆钮图标高度；可整体调大）
    this.height = 36,

    /// 外部 controller（搜索历史/联动用）；不传则内部自建
    this.controller,

    /// 聚焦状态变化（如"聚焦且内容为空 → 显示搜索历史"）
    this.onFocusChange,

    /// 输入变化（实时过滤）
    this.onChanged,

    /// 点清除按钮后
    this.onCleared,

    /// 右侧附加控件（如搜索中的 spinner），显示在清除按钮之前
    this.trailing,
  });

  final ValueChanged<String> onSubmitted;
  final String hintText;
  final double height;
  final TextEditingController? controller;
  final ValueChanged<bool>? onFocusChange;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onCleared;
  final Widget? trailing;

  @override
  State<JellyExpandableSearch> createState() => _JellyExpandableSearchState();
}

class _JellyExpandableSearchState extends State<JellyExpandableSearch> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;
  bool _ownsCtrl = false;

  @override
  void initState() {
    super.initState();
    final ext = widget.controller;
    if (ext != null) {
      _ctrl = ext;
    } else {
      _ctrl = TextEditingController();
      _ownsCtrl = true;
    }
    _focus = FocusNode();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    if (_ownsCtrl) _ctrl.dispose();
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    widget.onFocusChange?.call(_focus.hasFocus);
  }

  void _submit(String v) {
    final text = v.trim();
    if (text.isEmpty) return;
    // 常驻胶囊：提交后不清空、不收起，用户可继续改字再搜
    widget.onSubmitted(text);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final hintColor = JellyTheme.textSecondary;
    final h = widget.height;

    return SizedBox(
      height: h,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(h / 2),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.30)
                  : Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            const SizedBox(width: 14),
            // 图标在左（用户要求：不要居中，放左边）
            Icon(Icons.search_rounded, color: hintColor, size: h * 0.6),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                // 常驻输入框不自动弹键盘（进页面即弹会打断浏览）
                autofocus: false,
                cursorColor: JellyTheme.primary,
                cursorWidth: 2,
                cursorRadius: const Radius.circular(1),
                style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  height: 1.0,
                  color: fg,
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: _submit,
                onChanged: widget.onChanged,
                onTapOutside: (_) => _focus.unfocus(),
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: TextStyle(
                    fontSize: AppTheme.fontHeadline,
                    color: hintColor,
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            // 有输入时显示清除按钮；trailing（如 spinner）紧随其后
            if (_ctrl.text.isNotEmpty)
              GestureDetector(
                onTap: () {
                  _ctrl.clear();
                  widget.onChanged?.call('');
                  widget.onCleared?.call();
                },
                child: Icon(Icons.clear_rounded, color: hintColor, size: 18),
              ),
            if (widget.trailing != null) ...[
              const SizedBox(width: 4),
              widget.trailing!,
            ],
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}
