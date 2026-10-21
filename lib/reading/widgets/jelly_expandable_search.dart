import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../theme/jelly_theme.dart';

/// **果冻风可展开搜索框** —— 对齐影视首页 `AppExpandableSearch` 的交互：
/// 收起时是个小圆钮（只占一个图标位），点一下**带宽度动画**伸长成胶囊输入框。
///
/// ── 用户 2026-10-10：「阅读改成像影视首页：收起圆钮 + 点击展开动画」──
/// 原来是名不副实的"常驻小胶囊"（名字叫 Expandable 但从不收起），
/// 现在改成真·展开式：
///   · 收起 = h×h 圆钮（透明底 + 细描边，与阅读"无灰色长条"视觉一致）
///   · 点击 = 宽度动画伸长成胶囊 + 自动聚焦（搜索历史等联动照常触发）
///   · 提交 = 收起但**不清空**（阅读页是页内搜索，关键词要保留可改；
///     影视版提交清空是因为它只是"进完整搜索页"的入口）
///   · 点输入框外部 = 收起（保留文字）
///
/// ── 与 `JellySearchBar` 的关系（别用错）──────────────────────
///   · [JellyExpandableSearch] —— **顶栏/标题行**用，收起只占 h×h。
///   · `JellySearchBar`        —— **弹窗/半屏面板/浮层**里用，保持常驻输入框。
///
/// ── 动画说明 ────────────────────────────────────────────────
/// 传了 [maxWidth] 的调用点（图书 133 / 书源 133 / 书源仓库 140 / 漫画 107）
/// 宽度 32 → maxWidth 真插值动画；未传的（收藏页，外层 FractionallySizedBox
/// 0.6 有界）展开宽度为 null 撑满父级，无插值但形态/底色仍有过渡。
class JellyExpandableSearch extends StatefulWidget {
  const JellyExpandableSearch({
    super.key,
    required this.onSubmitted,

    /// 展开后输入框里的提示文字（搜索书架 / 搜索收藏 / 搜索漫画 / 搜索图书 …）
    this.hintText = '搜索',

    /// 胶囊高度（默认 32）；收起态圆钮直径同值
    this.height = 32,

    /// 展开后的胶囊宽度（收起态恒为 [height]）；传了才有宽度插值动画。
    /// null 则展开后撑满父级给的有界宽度。
    this.maxWidth,

    /// 外部 controller（搜索历史/联动用）；不传则内部自建
    this.controller,

    /// 聚焦状态变化（如"聚焦且内容为空 → 显示搜索历史"）；
    /// 展开=获焦=true、收起/提交/点外部=false，联动逻辑无需改动
    this.onFocusChange,

    /// 输入变化（实时过滤）
    this.onChanged,

    /// 点清除按钮后
    this.onCleared,

    /// 右侧附加控件（如搜索中的 spinner），显示在清除按钮之后（展开态）
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
  bool _expanded = false;
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

  void _expand() {
    setState(() => _expanded = true);
    _focus.requestFocus();
  }

  /// 收起。**保留文字**（阅读页是页内搜索，用户要能再展开改字重搜）。
  void _collapse() {
    setState(() => _expanded = false);
    _focus.unfocus();
  }

  void _submit(String v) {
    final text = v.trim();
    _collapse();
    if (text.isNotEmpty) widget.onSubmitted(text);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final hintColor = JellyTheme.textSecondary;
    final h = widget.height;
    // 边框走 JellyTheme 主题语义色（随明暗外观），与阅读模块外观系统一致
    final borderColor = isDark
        ? JellyTheme.textPrimaryDark.withValues(alpha: 0.22)
        : JellyTheme.textPrimaryLight.withValues(alpha: 0.22);

    final field = TextField(
      controller: _ctrl,
      focusNode: _focus,
      // 展开时由 _expand() 主动 requestFocus，不需要 autofocus
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
      onTapOutside: (_) {
        if (_expanded) _collapse();
      },
      decoration: InputDecoration(
        hintText: widget.hintText,
        hintStyle: TextStyle(
          fontSize: AppTheme.fontSubhead,
          color: hintColor,
        ),
        // 🔴 必须显式关掉填充：`JellyTheme` 的 inputDecorationTheme 是
        //   `filled: true + fillColor: primary@8%`（给普通表单输入框用的）⇒
        //   这里不写就会在提示文字后面画出一块**灰色圆角底**（用户截图里
        //   "搜索书架"后面那层灰，2026-10-21）。胶囊自己有实底，内层必须透明。
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        isDense: true,
        contentPadding: EdgeInsets.zero,
      ),
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      // 收起 = h×h 圆钮；展开 = maxWidth（未传则 null 撑满父级）
      width: _expanded ? widget.maxWidth : h,
      height: h,
      decoration: BoxDecoration(
        // 用户 2026-10-18：「搜索框这个位置不要透明」——
        // 收起/展开都用**卡片实底**（深色 #2A2A2C / 浅色白），
        // 不再让搜索框融进背景留一块"空玻璃"。
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(h / 2),
        border: Border.all(
          color: borderColor.withValues(alpha: _expanded ? 0.16 : 0.30),
          width: 0.5,
        ),
      ),
      child: _expanded
          ? Row(
              children: [
                const SizedBox(width: 12),
                Icon(Icons.search_rounded, color: hintColor, size: h * 0.6),
                const SizedBox(width: 6),
                Expanded(child: field),
                // 有输入时显示清除按钮；trailing（如 spinner）紧随其后
                if (_ctrl.text.isNotEmpty)
                  GestureDetector(
                    onTap: () {
                      _ctrl.clear();
                      widget.onChanged?.call('');
                      widget.onCleared?.call();
                    },
                    child:
                        Icon(Icons.clear_rounded, color: hintColor, size: 18),
                  ),
                if (widget.trailing != null) ...[
                  const SizedBox(width: 4),
                  widget.trailing!,
                ],
                // ⚠️ 2026-10-14：删掉了原来那个「→ 确认按钮」—— 影视/小程序的搜索框
                //   **没有**它，多一个图标正是两边不一致、阅读这边显得"重"的原因之一。
                //   提交仍由键盘搜索键完成（`textInputAction: search` 已绑 onSubmitted ✓）。
                const SizedBox(width: 10),
              ],
            )
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _expand,
              child: Center(
                child:
                    Icon(Icons.search_rounded, color: hintColor, size: h * 0.6),
              ),
            ),
    );
  }
}
