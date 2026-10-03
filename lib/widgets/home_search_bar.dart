import 'package:flutter/material.dart';

import '../common/theme.dart';

/// **首页右上角搜索**（2026-10-02 定稿：iOS 风格收起/展开）
///
/// 用户明确要求：
/// - **正常（收起）** = 一个圆形搜索图标按钮（白底/卡片底 + 放大镜）
/// - **点击** = 展开成小胶囊输入框，**长度只到参考图那条**（约屏宽 36%，
///   不撑满整行）；聚焦自动弹键盘
///
/// ── 样式 ──────────────────────────────────────────────
/// 收起：直径 32 圆钮；展开：宽 屏宽×0.36 / 高 30 / 圆角 15（胶囊）
/// 底色 cardLight·cardDark + 细边（无阴影，干净，对齐参考图）
/// 展开内容：放大镜(14) + hint「搜索影片」(12) + 有内容时 × 清除
///
/// ── 行为 ──────────────────────────────────────────────
/// · 点圆钮 → 展开 + 聚焦
/// · 键盘搜索键 / 提交：有内容 → [onSubmitted]（带关键词进搜索页）
/// · 无内容提交 / 点外部失焦 → 收起；空提交同时触发 [onTapEmpty]（打开完整搜索页）
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
  /// false=收起（圆形搜索图标按钮）；true=展开（小胶囊输入框）
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
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    // 只销毁自己建的（外部传进来的由外部负责）
    if (_ownsCtrl) _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _expand() {
    setState(() => _expanded = true);
    _focus.requestFocus();
  }

  void _collapse() {
    setState(() => _expanded = false);
    _focus.unfocus();
  }

  void _submit(String v) {
    final text = v.trim();
    if (text.isEmpty) {
      _collapse();
      widget.onTapEmpty?.call();
      return;
    }
    _ctrl.clear();
    _collapse();
    widget.onSubmitted(text);
  }

  @override
  Widget build(BuildContext context) {
    // 展开后胶囊长度：参考图"搜索漫画"那条的长度（约屏宽 36%，
    // 不撑满整行 —— 用户明确要求"长度只需要这个这么长"）
    final expandedWidth = MediaQuery.of(context).size.width * 0.36;
    return AnimatedContainer(
      duration: AppTheme.motionBase,
      curve: AppTheme.motionCurve,
      // 收起 = 圆形按钮（直径 32）；展开 = 小胶囊（宽 = 屏宽 36%）
      width: _expanded ? expandedWidth : 32,
      height: 30,
      decoration: BoxDecoration(
        // 透明底：跟随页面背景（深浅模式自动切换），不再有一块明显灰底
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(15),
        // 展开态无边框（整条融入背景，用户要求搜索框灰色长条透明）；
        // 收起态（圆形按钮）保留细边以便看出是按钮
        border: _expanded
            ? Border.all(color: Colors.transparent, width: 0)
            : Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: _expanded
          ? Row(
              children: [
                const SizedBox(width: 10),
                Icon(Icons.search_rounded,
                    color: AppTheme.textTertiary, size: 14),
                const SizedBox(width: 5),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    autofocus: true,
                    cursorColor: AppTheme.accentColor,
                    cursorWidth: 1.5,
                    cursorRadius: const Radius.circular(1),
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.0,
                      color: AppTheme.textPrimary,
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: _submit,
                    onChanged: (v) {
                      setState(() {});
                      widget.onChanged?.call(v);
                    },
                    onTapOutside: (_) {
                      if (_expanded && !_focus.hasFocus) _collapse();
                    },
                    decoration: InputDecoration(
                      hintText: widget.hintText,
                      hintStyle: TextStyle(
                        fontSize: 12,
                        color: AppTheme.textTertiary,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                // 有内容才显示 × 清除（无内容时右侧不放任何图标，对齐参考图）
                if (_ctrl.text.isNotEmpty)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _ctrl.clear();
                      setState(() {});
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.cancel_rounded,
                        color: AppTheme.textTertiary,
                        size: 13,
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
              ],
            )
          // 收起：圆形搜索图标按钮（参考图：白底黑放大镜）
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _expand,
              child: Center(
                child: Icon(
                  Icons.search_rounded,
                  // 明暗自适应：浅色=宣纸上的墨字、深色=墨夜上的亮字
                  color: AppTheme.textPrimary,
                  size: 16,
                ),
              ),
            ),
    );
  }
}
