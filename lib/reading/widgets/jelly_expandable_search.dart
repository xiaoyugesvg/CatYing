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

    /// 胶囊高度（默认 32，参考影视首页右上角小胶囊；可整体调大）
    this.height = 32,

    /// 胶囊最大宽度（默认 null 不限；顶栏 Expanded 撑开时用于控制长度，
    /// 传值后内部 Align+ConstrainedBox 生效，不会与 Expanded 的 tight 约束冲突）
    this.maxWidth,

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
  final double? maxWidth;
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
    // 底色与页面背景一致（用户要求去掉"灰色长条"）：透明底 + 细边框
    // 保持可辨识，不再用卡片色 + 阴影。
    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final hintColor = JellyTheme.textSecondary;
    final h = widget.height;

    final searchBar = SizedBox(
      height: h,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(h / 2),
          // 边框走 JellyTheme 主题语义色（随明暗外观），与阅读模块外观系统一致
          border: Border.all(
            color: isDark
                ? JellyTheme.textPrimaryDark.withValues(alpha: 0.22)
                : JellyTheme.textPrimaryLight.withValues(alpha: 0.22),
            width: 1,
          ),
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
                  fontSize: AppTheme.fontSubhead,
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
                    fontSize: AppTheme.fontSubhead,
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

    // 顶栏 Expanded 撑开时用 maxWidth 限制胶囊长度（Align 转 loose 约束，
    // 否则 ConstrainedBox 会被 Expanded 的 tight 宽度吞掉）
    if (widget.maxWidth != null) {
      return Align(
        // ⚠️ 这里的对齐**只在"组件被给了超出自身需要的宽度"时才看得出来**：
        //   · 外面用 `Spacer`（推荐）→ 组件只占内容宽（maxWidth）→
        //     本 `Align` 没有可推空间，等于不起作用（也就无所谓了 ✓）
        //   · 外面用 `Expanded`（tight 满宽）→ 本 `Align` 生效，
        //     `centerLeft` 会把胶囊推到**左缘**，与右侧图标空一大截 ✗
        //     （这正是用户报的 bug 的成因）
        //
        // 所以**页面侧的正确做法是"不要用 Expanded 包它，用 Spacer"** ✓
        //（见 `bookshelf_page` / `book_search_page` / `book_source_repo_page`
        //  的注释）。这里保持 `centerLeft` 不变，不动其它调用点的观感。
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.maxWidth!),
          child: searchBar,
        ),
      );
    }
    return searchBar;
  }
}
