import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../theme/jelly_theme.dart';

/// **果冻风可展开搜索框** —— 与影视首页右上角同款交互：
/// 收起 = 44 圆钮（只有搜索图标，不占整行），点一下展开成小胶囊输入框。
///
/// ── 与 `JellySearchBar` 的关系（别用错）──────────────────────
///   · [JellyExpandableSearch] —— **顶栏/标题行**用。收起只占 44px，点击才展开。
///   · `JellySearchBar`        —— **弹窗/半屏面板/浮层**里用（`showModalBottomSheet`、
///      搜索浮层）。那种场景本来就需要一个显眼的常驻输入框（还带 `autofocus`），
///      保持不动。
///
/// ── 规格（与首页 `AppExpandableSearch` 对齐）────────────────
/// 收起 44 圆钮 / 展开高 50 圆角 25（胶囊）/ 底色 JellyTheme 卡片色 /
/// 无描边靠阴影分离 / 展开态图标在**左侧**（首页样式）/ 字号 fontHeadline。
/// 配色走 JellyTheme，切明暗/外观自动跟随。
class JellyExpandableSearch extends StatefulWidget {
  const JellyExpandableSearch({
    super.key,
    required this.onSubmitted,

    /// 展开后输入框里的提示文字（搜索漫画 / 搜索图书 / 搜索书架 …）
    this.hintText = '搜索',

    /// 展开时是否自动聚焦
    this.autofocus = true,

    /// 外部 controller（搜索历史/联动用）；不传则内部自建
    this.controller,

    /// 聚焦状态变化（如"聚焦且内容为空 → 显示搜索历史"）
    this.onFocusChange,

    /// 输入变化（实时过滤）
    this.onChanged,

    /// 点清除按钮后
    this.onCleared,

    /// 展开态右侧附加控件（如搜索中的 spinner），显示在清除按钮之前
    this.trailing,
  });

  final ValueChanged<String> onSubmitted;
  final String hintText;
  final bool autofocus;
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

  /// 区分"用户点击展开"与"路由返回时 Flutter 自动抓焦"：
  /// 展开胶囊的 TextField 只在用户点击后出现，正常情况下路由返回时组件
  /// 已收起、不会抓焦；但展开状态下返回（如从详情页 pop 回来）仍可能被
  /// 系统把焦点交回输入框 → 用 _userTapped 拦掉非用户意愿的获焦。
  bool _userTapped = false;

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
    if (_focus.hasFocus && !_userTapped) {
      // 非用户意愿的获焦（路由返回自动抓焦）→ 失焦并收起
      _focus.unfocus();
      if (mounted) setState(() => _expanded = false);
      widget.onFocusChange?.call(false);
      return;
    }
    if (!_focus.hasFocus) _userTapped = false;
    widget.onFocusChange?.call(_focus.hasFocus);
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
      return;
    }
    _collapse();
    widget.onSubmitted(text);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final hintColor = JellyTheme.textSecondary;

    return AnimatedContainer(
      duration: AppTheme.motionBase,
      curve: AppTheme.motionCurve,
      // 收起 = 44 圆钮；展开 = 撑满父级约束（通常放 Expanded 里）
      width: _expanded ? null : 44,
      height: 50,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(_expanded ? 25 : 22),
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
                // 图标在左（用户要求：不要居中，放左边）
                Icon(Icons.search_rounded, color: hintColor, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    autofocus: widget.autofocus,
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
                    onTap: () => _userTapped = true,
                    onTapOutside: (_) {
                      if (_expanded) _collapse();
                    },
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
                const SizedBox(width: 8),
              ],
            )
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _userTapped = true;
                setState(() => _expanded = true);
                _focus.requestFocus();
              },
              child: Center(
                child: Icon(Icons.search_rounded, color: hintColor, size: 22),
              ),
            ),
    );
  }
}
