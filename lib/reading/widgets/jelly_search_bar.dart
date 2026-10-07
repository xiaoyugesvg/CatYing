import 'package:flutter/material.dart';
import '../theme/jelly_theme.dart';
import '../../common/theme.dart';

/// 果冻风格胶囊搜索框（固定在顶部，胶囊形状）
class JellySearchBar extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final Function(String)? onSubmitted;
  final Function(String)? onChanged;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onFocusChange;
  final VoidCallback? onCleared;
  final bool autofocus;

  const JellySearchBar({
    super.key,
    required this.controller,
    this.hintText = '搜索漫画',
    this.onSubmitted,
    this.onChanged,
    this.onTap,
    this.onFocusChange,
    this.onCleared,
    this.autofocus = false,
  });

  @override
  State<JellySearchBar> createState() => _JellySearchBarState();
}

class _JellySearchBarState extends State<JellySearchBar> {
  bool _isFocused = false;
  final FocusNode _focusNode = FocusNode();
  bool _userTapped = false; // 区分"用户点击搜索框"与"路由返回时 Flutter 自动抓取焦点"
  bool _autoFocusConsumed = false; // widget.autofocus 的首次自动获焦放行标记

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus && !_userTapped) {
        if (widget.autofocus && !_autoFocusConsumed) {
          // 弹窗搜索首次打开的合法 autofocus，放行一次
          _autoFocusConsumed = true;
        } else {
          // 路由（详情/弹窗）返回时 Flutter 会把焦点自动交给搜索框，非用户意愿 → 失焦
          _focusNode.unfocus();
          return;
        }
      }
      if (!_focusNode.hasFocus) _userTapped = false; // 失焦后重置，下次仍按"非用户"判定
      if (mounted) setState(() => _isFocused = _focusNode.hasFocus);
      widget.onFocusChange?.call(_focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hintColor = JellyTheme.textSecondary;

    // 外层间距由调用方控制，便于与其他控件（如视图切换）并排
    return Container(
      height: 50,
      decoration: BoxDecoration(
        // ── 搜索框背景统一（用户 2026-10-07：「阅读里所有搜索框背景色没统一」）──
        // 原来这里是**卡片色 + 阴影**（一块浅灰底），而顶部行里的
        // `JellyExpandableSearch` 早已按用户要求改成**透明底 + 细边框**
        // ⇒ 同一个阅读模块里两种搜索框底色不一样 ✗。
        // 现在两边**完全同款**：透明底 + 一档细边框（走 JellyTheme 主题语义色，
        // 随明暗外观），底色永远是"页面背景"，不再出现灰色块 ✓。
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(25), // 胶囊形状（半径=高度的一半）
        border: Border.all(
          color: isDark
              ? JellyTheme.textPrimaryDark.withValues(alpha: 0.22)
              : JellyTheme.textPrimaryLight.withValues(alpha: 0.22),
          width: 1,
        ),
      ),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _userTapped = true, // 用户点击早于获焦，据此放行
        child: TextField(
          controller: widget.controller,
          focusNode: _focusNode,
          autofocus: widget.autofocus,
          onTap: () => widget.onTap?.call(),
          onSubmitted: (value) => widget.onSubmitted?.call(value),
          onChanged: widget.onChanged,
          textAlignVertical: TextAlignVertical.center,
          style: TextStyle(
            fontSize: AppTheme.fontHeadline,
            height: 1.0,
            color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
          ),
          decoration: InputDecoration(
            // 关闭主题默认的灰色填充，让输入框透明白底胶囊
            filled: false,
            hintText: widget.hintText,
            hintStyle: TextStyle(fontSize: AppTheme.fontHeadline, color: hintColor),
            prefixIcon: Icon(
              Icons.search_rounded,
              color: _isFocused ? JellyTheme.navSelectedFg : hintColor,
              size: 22,
            ),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 44,
              minHeight: 44,
            ),
            suffixIcon: widget.controller.text.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.clear_rounded, color: hintColor, size: 18),
                    onPressed: () {
                      widget.controller.clear();
                      widget.onChanged?.call('');
                      widget.onCleared?.call();
                      _focusNode.unfocus();
                    },
                  )
                : null,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(horizontal: 6),
          ),
        ),
      ),
    );
  }
}
