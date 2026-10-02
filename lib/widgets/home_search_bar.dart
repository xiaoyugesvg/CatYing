import 'package:flutter/material.dart';

import '../common/theme.dart';

/// **首页右上角常驻搜索框**（2026-10-02 重构）
///
/// 对齐参考 App（奇优影院）的搜索框样式：**常驻胶囊输入框**，
/// 不是"收起圆钮、点击才展开"的旧交互——
/// 用户明确要求"重构首页右上角的搜索UI界面及其搜索位置UI"。
///
/// ── 样式 ──────────────────────────────────────────────
/// **小胶囊**（对齐参考 App）：高 38 / 圆角 19 / 底色 cardLight·cardDark
/// 轻阴影无描边；左：放大镜图标(16)；中：hint「搜索影片」；右：有内容 × 清除
///
/// ── 位置与键盘 ─────────────────────────────────────────
/// 组件放在首页顶栏（外层 SafeArea 内），**永远在状态栏下方**；
/// 键盘弹起时顶栏不动（页面 Scaffold 默认 resizeToAvoidBottomInset，
/// 顶栏属于 body 顶部，不受键盘影响），输入框不会被遮。
///
/// ── 行为 ──────────────────────────────────────────────
/// · 点击 → 聚焦弹键盘，直接输入
/// · 键盘搜索键 / 点右侧图标：有内容 → [onSubmitted](带关键词进搜索页)
/// · 无内容 → [onTapEmpty]（打开完整搜索页）
class HomeSearchBar extends StatefulWidget {
  const HomeSearchBar({
    super.key,
    required this.onSubmitted,

    /// 无输入内容时点击右侧图标 / 提交要做的事（通常是"打开完整搜索页"）
    this.onTapEmpty,

    /// 输入框提示文字
    this.hintText = '搜索',

    /// 外部 controller（部分页面要做搜索联动）；不传则内部自建
    this.controller,

    /// 聚焦状态变化
    this.onFocusChange,

    /// 输入变化
    this.onChanged,
  });

  final ValueChanged<String> onSubmitted;
  final VoidCallback? onTapEmpty;
  final String hintText;
  final TextEditingController? controller;
  final ValueChanged<bool>? onFocusChange;
  final ValueChanged<String>? onChanged;

  @override
  State<HomeSearchBar> createState() => _HomeSearchBarState();
}

class _HomeSearchBarState extends State<HomeSearchBar> {
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

  void _submit(String v) {
    final text = v.trim();
    if (text.isEmpty) {
      _focus.unfocus();
      widget.onTapEmpty?.call();
      return;
    }
    _ctrl.clear();
    _focus.unfocus();
    widget.onSubmitted(text);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 38,
      decoration: BoxDecoration(
        // 颜色走 AppTheme 调色板，切外观/配色自动跟随
        color: isDark ? AppTheme.palette.cardDark : AppTheme.palette.cardLight,
        borderRadius: BorderRadius.circular(19),
        // 靠阴影与底色分离，不加描边（浅色模式下写死描边会看不清）
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.30)
                : Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(Icons.search_rounded, color: AppTheme.textTertiary, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              cursorColor: AppTheme.accentColor,
              cursorWidth: 2,
              cursorRadius: const Radius.circular(1),
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                height: 1.0,
                color: AppTheme.textPrimary,
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: _submit,
              onChanged: (v) {
                setState(() {});
                widget.onChanged?.call(v);
              },
              decoration: InputDecoration(
                hintText: widget.hintText,
                hintStyle: TextStyle(
                  fontSize: AppTheme.fontBody,
                  color: AppTheme.textTertiary,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          // 有内容：× 清除；无内容：搜索箭头 → 打开完整搜索页
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _submit(_ctrl.text),
            child: Padding(
              padding: const EdgeInsets.all(9),
              child: Icon(
                _ctrl.text.isEmpty
                    ? Icons.arrow_forward_ios_rounded
                    : Icons.cancel_rounded,
                color: AppTheme.textTertiary,
                size: 15,
              ),
            ),
          ),
          const SizedBox(width: 5),
        ],
      ),
    );
  }
}
