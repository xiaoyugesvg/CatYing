import 'package:flutter/material.dart';

import '../common/theme.dart';

/// **可伸长的搜索框** —— iOS 风格：收起时是个 44 圆钮，点一下展开成胶囊输入框。
///
/// ── 为什么要有这个（用户明确要求）──────────────────────────────
/// 原来顶栏里塞的是**常驻长条搜索框**（`JellySearchBar`），
/// 占掉一整行宽度。用户给的参考图是：
///   ① 收起 = 只有一个圆形搜索图标
///   ② 点击 = 带宽度动画伸长成输入框，可以输入
///
/// ── 与 `JellySearchBar` 的关系（重要，别用错）──────────────────
///   · [AppExpandableSearch] —— **顶栏**用。收起只占 44px，点击才展开。
///   · `JellySearchBar`     —— **弹窗/半屏面板**里用（`showModalBottomSheet`）。
///     那种场景本来就需要一个显眼的输入框（还带 `autofocus`），
///     改成"先点图标再展开"反而多一步。所以那边**保持不变**。
///
/// ── 规格与 `JellySearchBar` 对齐 ──────────────────────────────
/// 高 50 / 圆角 25（= 高的一半，胶囊）/ 底色 白 或 深色卡 /
/// **无描边**（靠阴影与底色分离）/ 图标 22 / 字号 15。
///
/// 颜色全部走 `AppTheme`，切外观/配色自动跟随
/// （原来影视首页那份描边写死 `Colors.white.withValues(0.10)`，
///   浅色模式下几乎看不见边框）。
class AppExpandableSearch extends StatefulWidget {
  const AppExpandableSearch({
    super.key,
    required this.onSubmitted,

    /// 无输入内容时点右侧图标要做什么（通常是"打开完整搜索页"）
    this.onOpenFull,

    /// 展开后输入框里的提示文字
    this.hintText = '搜索',

    /// 有输入时右侧的图标；点它 = 提交搜索。
    /// 传 null 则不显示（此时用键盘的搜索键提交）。
    this.submitIcon = Icons.search,

    /// 展开时是否自动聚焦
    this.autofocus = true,

    /// 外部 controller（有些页面要用它做搜索历史/联动）。
    /// 不传则内部自建一个。
    this.controller,

    /// 聚焦状态变化（如"聚焦且内容为空 → 显示搜索历史"）
    this.onFocusChange,

    /// 输入变化（用于实时过滤）
    this.onChanged,
  });

  final ValueChanged<String> onSubmitted;
  final VoidCallback? onOpenFull;
  final String hintText;
  final IconData? submitIcon;
  final bool autofocus;
  final TextEditingController? controller;
  final ValueChanged<bool>? onFocusChange;
  final ValueChanged<String>? onChanged;

  @override
  State<AppExpandableSearch> createState() => _AppExpandableSearchState();
}

class _AppExpandableSearchState extends State<AppExpandableSearch> {
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
    _focus.addListener(() {
      widget.onFocusChange?.call(_focus.hasFocus);
    });
  }

  @override
  void dispose() {
    // 只销毁自己建的（外部传进来的由外部负责）
    if (_ownsCtrl) _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _collapse({bool clear = true}) {
    setState(() {
      _expanded = false;
      if (clear) _ctrl.clear();
    });
    _focus.unfocus();
  }

  void _submit(String v) {
    final text = v.trim();
    if (text.isEmpty) {
      _collapse(clear: false);
      widget.onOpenFull?.call();
      return;
    }
    _collapse();
    widget.onSubmitted(text);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedContainer(
      duration: AppTheme.motionBase,
      curve: AppTheme.motionCurve,
      // 收起 = 44 圆钮（与 `JellySearchBar` 的 prefixIcon 尺寸一致）；
      // 展开 = 撑满父级给的 Constraints（通常是 Expanded 的宽度）
      width: _expanded ? null : 44,
      height: 50,
      decoration: BoxDecoration(
        // 浅色分支不能用写死的 Colors.white：用户把影视配色换成别的方案时
        //（`JellyPalette.cardLight` 不一定是纯白），搜索栏会与卡片撞色。
        color: isDark ? AppTheme.palette.cardDark : AppTheme.palette.cardLight,
        borderRadius: BorderRadius.circular(25),
        // 不加描边 —— 靠阴影与底色分离（与 JellySearchBar 一致）
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
      child: _expanded
          ? Row(
              children: [
                const SizedBox(width: 14),
                Icon(Icons.search_rounded,
                    color: AppTheme.textTertiary, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    autofocus: widget.autofocus,
                    cursorColor: AppTheme.accentColor,
                    cursorWidth: 2,
                    cursorRadius: const Radius.circular(1),
                    style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      height: 1.0,
                      color: AppTheme.textPrimary,
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
                        fontSize: AppTheme.fontHeadline,
                        color: AppTheme.textTertiary,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                if (widget.submitIcon != null)
                  GestureDetector(
                    onTap: () => _submit(_ctrl.text),
                    child: Icon(widget.submitIcon,
                        color: AppTheme.accentColor, size: 18),
                  ),
                const SizedBox(width: 8),
              ],
            )
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() => _expanded = true);
                _focus.requestFocus();
              },
              child: Center(
                child: Icon(Icons.search_rounded,
                    color: AppTheme.textTertiary, size: 22),
              ),
            ),
    );
  }
}
