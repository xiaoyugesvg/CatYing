import 'dart:io';

import 'package:flutter/material.dart';
import '../../common/floating_nav_spec.dart';
import '../services/settings_service.dart';
import '../theme/jelly_palette.dart';
import '../theme/jelly_theme.dart';

/// 果冻风格底部导航栏（支持悬浮胶囊样式，果冻弹性指示器）
class JellyNavBar extends StatefulWidget {
  final int currentIndex;
  final Function(int) onTap;
  final Function(int)? onLongPress;

  /// 点**当前** tab 时回调（默认没有）。
  ///
  /// ── 🔴 为什么需要它（用户 2026-10-16 实测）──────────────────────
  /// 「进了书源页后点悬浮栏的**图书**按钮，还是书源页」——
  /// 书源页是**内嵌子页**（`shellEmbeddedPage`，由外壳渲染，见
  /// `shell_embedded_page.dart`），外壳只能靠 `_onNavTap` 把它清掉；
  /// 而原来这里 `index != currentIndex` 才回调 ⇒ **点同一个 tab 什么都不做**
  /// ⇒ 内嵌页退不出去 ✗。（宽屏左侧竖栏 [JellyNavRail] 没有这个守卫，
  /// 所以只有手机底部栏有这个问题 —— 与用户"手机上传"的复现一致。）
  final Function(int)? onReselect;

  /// 导航项上滑手势（书架 tab 上滑唤起批量多选）
  final Function(int)? onSlideUp;
  final List<JellyNavItem> items;
  final bool floating;

  /// 取色调色板。为 null 时用阅读自己的 [JellyTheme.palette]。
  ///
  /// ── ⚠️ 为什么必须有这个参数 ──────────────────────────────────
  /// 三条栏现在**共用**这个组件（影视/音乐直接复用，不再各自画）。
  /// 但取色不能都固定用 JellyTheme（阅读的）：
  ///   · 影视栏要跟 AppTheme.palette（切影视配色时它变）
  ///   · 音乐栏要跟 MusicTheme.palette（切音乐配色时它变）
  /// 如果都写死 JellyTheme，切影视/音乐配色时栏的颜色**不会变**，
  /// 又是一个"看起来改了点开没变"的静默 bug。
  final JellyPalette? palette;

  const JellyNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.onLongPress,
    this.onReselect,
    this.onSlideUp,
    required this.items,
    this.floating = false,
    this.palette,
  }) : assert(
         items.length >= 2 && items.length <= 6,
         // ── 为什么上限从 5 放宽到 6 ────────────────────────────────
         // cmbok 原生是 5 项（漫画/图书/书架/收藏/我的）。
         // 猫影把阅读嵌进了影视 App，阅读自带悬浮栏而影视底栏被隐藏，
         // 所以**必须在阅读栏里给一条回影视的路**（第 6 项「影视」）。
         //
         // ⚠️ 只放宽上限是不够的：项数一变，宽度算法必须能跟着缩。
         // 原来的 `perItem = (屏宽×0.2).clamp(80,120)` 在 6 项时
         // 需要 480~600px 而手机只有 ~350px 可用 → 必然溢出。
         // 宽度算法已改成"按可用宽度反算"（见 _buildFloatingNavBar），
         // 那里才是让 6 项能安全容纳的关键。
         '导航项数需在 2~6 之间（5 项是 cmbok 原生，第 6 项是「返回影视」）',
       );

  /// 悬浮导航栏总占用高度（高度 + 底部外边距），用于页面 FAB 等避让
  static const double floatingTotalHeight =
      floatingBarHeight + floatingBottomMargin;
  static const double floatingBarHeight = FloatingNavSpec.barHeight;
  static const double floatingBottomMargin = FloatingNavSpec.bottomMargin;

  /// 内容底部避让高度：悬浮导航栏开启时返回总高+8+Home 指示器余量，否则 0。
  ///
  /// ⚠️ 悬浮模式（extendBody=true）下 body 会延伸到屏幕底部，
  /// 页面自己必须留出足够底部 padding，否则最后一项会被导航栏
  /// 或 Home 指示器遮挡（表现为"内容压导航栏、点不到"）。
  /// +40 用于覆盖 Home 指示器（iPhone 34 / Android 手势条 24~48）。
  static double get contentBottomAvoid =>
      SettingsService().navFloating ? floatingTotalHeight + 8 + 40 : 0.0;

  @override
  State<JellyNavBar> createState() => _JellyNavBarState();
}

class _JellyNavBarState extends State<JellyNavBar>
    with SingleTickerProviderStateMixin {
  /// 当前栏的取色调色板（可被 widget.palette 覆盖）
  JellyPalette get _pal => widget.palette ?? JellyTheme.palette;

  /// 当前悬浮栏风格（设置页可切换：水墨 / 液态玻璃 / 炫彩 / 霓虹）
  FloatingNavStyle get _style =>
      FloatingNavStyle.fromId(SettingsService().navStyle);

  late AnimationController _controller;
  int _previousIndex = 0;

  // 果冻弹性曲线（直接 transform，避免在 build 中创建 CurvedAnimation 造成监听器泄漏）
  static const _curve = ElasticOutCurve(0.7);

  // 导航栏尺寸：整体加高，底部间距稍高于顶部，左右上角圆角
  static const _barHeight = 80.0; // 整体高度（原 64）
  static const _topPad = 10.0; // 顶部间距
  static const _bottomPad = 18.0; // 底部间距（> 顶部，内容整体偏上）
  static const _topRadius = 20.0; // 左、右上角圆角
  // 选中指示器为圆形（宽=高），宽度由 itemWidth 与 bandHeight 反算，无固定内边距常量

  // 悬浮模式尺寸（高度/边距在 Widget 类中公开定义，供外部避让使用）
  static const _floatingRadius = FloatingNavSpec.radius; // 悬浮胶囊圆角
  static const _floatingTopPad = FloatingNavSpec.innerPadV; // 悬浮时上下内边距
  static const _floatingIconSize = FloatingNavSpec.iconSize; // 与影视/音乐统一
  // 悬浮每项宽度随屏宽自适应（宽屏适当加宽），见 _buildFloatingNavBar
  static const _floatingItemMin = 80.0; // 每项最小宽度（手机保底）
  static const _floatingItemMax = 120.0; // 每项最大宽度（宽屏上限）
  static const _floatingItemFactor = 0.2; // 随屏宽增长系数

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 850), // 切换速度放慢（原 600）
      vsync: this,
    )..value = 1.0; // 初始处于静止态，指示器归位到当前项
    // 背景动画开关变化时重建：决定悬浮栏是否套 BackdropFilter 模糊
    SettingsService().addListener(_onBgAnimChanged);
  }

  void _onBgAnimChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SettingsService().removeListener(_onBgAnimChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onItemTap(int index) {
    if (index != widget.currentIndex) {
      _previousIndex = widget.currentIndex;
      _controller.reset();
      _controller.forward();
      widget.onTap(index);
      return;
    }
    // 点当前的 tab：不播切页动画，但要**通知外壳** —— 这是"退出内嵌子页
    // （书源页）"的唯一路径（见 [onReselect] 的说明）
    widget.onReselect?.call(index);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (widget.floating) {
      return _buildFloatingNavBar(isDark);
    } else {
      return _buildFixedNavBar(isDark);
    }
  }

  /// 固定底部导航栏（原始样式：贴底、顶部圆角）
  Widget _buildFixedNavBar(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.backgroundDark : JellyTheme.cardLight,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(_topRadius), // 左、右上角圆角
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: _barHeight, // 整体高度加高
          child: Padding(
            // 底部间距稍高于顶部，内容整体偏上
            padding: const EdgeInsets.only(top: _topPad, bottom: _bottomPad),
            child: _buildNavContent(
              height: _barHeight - _topPad - _bottomPad,
              iconOnly: SettingsService().navIconOnly,
              iconSize: SettingsService().navIconOnly ? 26 : 22,
            ),
          ),
        ),
      ),
    );
  }

  /// 悬浮胶囊导航栏（不透明胶囊背景，与搜索框样式一致）
  Widget _buildFloatingNavBar(bool isDark) {
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screenWidth = MediaQuery.of(context).size.width;
          // #5：边距原来按屏宽比例算 `(屏宽×0.045).clamp(12,60)` ——
          // 手机上约 17.5px，iPad 上会到 60px，**和影视/音乐的固定
          // 边距对不上**（那两条是 FloatingNavSpec.sideMargin = 12）。
          // 现在统一用规格里的固定值，三条栏左右边距完全一致。
          final horizontalMargin = FloatingNavSpec.sideMargin;
          // ── 每项宽度：必须"按可用宽度反算"，不能只按屏宽比例算 ──────
          //
          // 之前的算法是 `(屏宽 × 0.2).clamp(80, 120)`：
          //   5 项 → 400~600px，6 项 → 480~600px
          // 而手机可用宽度只有 (屏宽 - 2×边距 - 2×内边距) ≈ 350~400px。
          // **一旦项数×每项宽度 > 可用宽度就必然溢出**（黄黑条纹）。
          // 项数从 5 变 6 时（加「影视」入口）就直接炸了。
          //
          // 正确做法：先算"可用宽度 / 项数"得到上限，再在其中取理想值。
          // 这样**无论几项都不会溢出** —— 项数增加只会让每项变窄。
          // 可用宽度 = 屏宽 - 两侧外边距（外层 Padding 只加了 horizontalMargin；
          // sidePad 是"内容比可用宽度窄时"的补足量，不算进上限）
          final available = (constraints.maxWidth - horizontalMargin * 2).clamp(
            1.0,
            constraints.maxWidth,
          );
          final ideal = (screenWidth * _floatingItemFactor).clamp(
            _floatingItemMin,
            _floatingItemMax,
          );
          final perItem = (available / widget.items.length).clamp(
            // 保底 44px：小于这个宽度手指点不准（Apple HIG 的最小可点区域）
            44.0,
            ideal,
          );
          final contentWidth = widget.items.length * perItem;
          // 胶囊居中：在屏幕边距基础上补足左右内边距，垂直结构保持不变（仍贴底部）
          final sidePad =
              ((constraints.maxWidth - contentWidth) / 2 - horizontalMargin)
                  .clamp(0.0, double.infinity);
          // 背景动画开启时跳过 BackdropFilter：底层每帧重绘下，高斯模糊逐帧采样
          // 是 GPU 主力开销；改用更高不透明度纯色（动效透出可接受，图标仍清晰）。
          // 动画关闭时底层静止，模糊成本低，保留玻璃质感。
          final bgAnim = SettingsService().backgroundAnimation;
          final navBody = Container(
            height: JellyNavBar.floatingBarHeight,
            decoration: _barDecoration(isDark, opaque: bgAnim),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: _floatingTopPad),
              child: _buildNavContent(
                height: JellyNavBar.floatingBarHeight - _floatingTopPad * 2,
                // #1：默认**显示文字标签**（与影视/音乐一致）。
                //
                // 原来是硬编码 `iconOnly: true`（纯图标）—— 那是
                // "5 项：漫画/图书/书架/收藏/我的"时期的写法。
                // 现在三条栏要以阅读为基准统一，而影视/音乐都是
                // 图标+文字，阅读只有图标就"光秃秃的"，而且
                // 漫画/图书/书架 三个图标辨识度本来就低。
                // 设置里可切换纯图标（隐藏文字），纯图标时图标放大。
                iconOnly: SettingsService().navIconOnly,
                iconSize: SettingsService().navIconOnly
                    ? 26
                    : _floatingIconSize,
              ),
            ),
          );
          // 炫彩/霓虹是不透明底，模糊背景没有意义（白耗一次全屏高斯）。
          // outline/jelly 是**半透明**底（浅色 alpha 只有 0.42 / 0.22）——
          // 不加模糊的话下方正文会原样透出，和栏内文字叠在一起看不清，
          // 所以它们也要跟 ink/liquid 一样走 BackdropFilter。
          final useBlur = !bgAnim &&
              _style != FloatingNavStyle.aurora &&
              _style != FloatingNavStyle.neon;
          return Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalMargin + sidePad,
              0,
              horizontalMargin + sidePad,
              JellyNavBar.floatingBottomMargin,
            ),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_floatingRadius),
                boxShadow: _barShadow(),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_floatingRadius),
                child: useBlur
                    ? BackdropFilter(
                        filter: JellyTheme.glassFilter,
                        child: navBody,
                      )
                    : navBody,
              ),
            ),
          );
        },
      ),
    );
  }

  /// 悬浮胶囊底色（按风格分支）
  BoxDecoration _barDecoration(bool isDark, {required bool opaque}) {
    final radius = BorderRadius.circular(_floatingRadius);
    switch (_style) {
      case FloatingNavStyle.liquid:
        // 液态玻璃：高透光渐变 + 白色高光描边
        return BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [
                    Colors.white.withValues(alpha: 0.18),
                    Colors.white.withValues(alpha: 0.05),
                  ]
                : [
                    Colors.white.withValues(alpha: 0.82),
                    Colors.white.withValues(alpha: 0.46),
                  ],
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: isDark ? 0.22 : 0.75),
          ),
        );
      case FloatingNavStyle.aurora:
        // 炫彩：固定霓虹渐变（不跟主题走，否则墨灰主题下不"炫"）
        return BoxDecoration(
          borderRadius: radius,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: FloatingNavSpec.auroraColors,
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.30)),
        );
      case FloatingNavStyle.neon:
        // 霓虹：深色底 + 发光描边
        return BoxDecoration(
          color: const Color(0xFF101116),
          borderRadius: radius,
          border: Border.all(
            color: FloatingNavSpec.neonColor.withValues(alpha: 0.90),
            width: 1.2,
          ),
        );
      case FloatingNavStyle.jelly:
        // 果冻：主题色半透明底 + 白色高光边框，像一块彩色软胶
        final accent = FloatingNavSpec.styleContentColor(
          FloatingNavStyle.outline,
          selected: true,
          isDark: isDark,
          palette: _pal,
        );
        return BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [
                    accent.withValues(alpha: 0.34),
                    accent.withValues(alpha: 0.16),
                  ]
                : [
                    accent.withValues(alpha: 0.22),
                    accent.withValues(alpha: 0.10),
                  ],
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: isDark ? 0.16 : 0.70),
          ),
        );
      case FloatingNavStyle.outline:
        // 描边：近乎透明的底 + 主题色细描边，尽量不遮内容
        final accent = FloatingNavSpec.styleContentColor(
          FloatingNavStyle.outline,
          selected: true,
          isDark: isDark,
          palette: _pal,
        );
        return BoxDecoration(
          color: (isDark ? const Color(0xFF101012) : Colors.white)
              .withValues(alpha: isDark ? 0.30 : 0.42),
          borderRadius: radius,
          border: Border.all(
            color: accent.withValues(alpha: isDark ? 0.70 : 0.55),
            width: 1.2,
          ),
        );
      case FloatingNavStyle.ink:
        return BoxDecoration(
          color: FloatingNavSpec.barColor(
            isDark,
            _pal,
          ).withValues(alpha: opaque ? FloatingNavSpec.barAlpha : 0.8),
          borderRadius: radius,
        );
    }
  }

  /// 悬浮胶囊外阴影（炫彩/霓虹带同色光晕）
  List<BoxShadow> _barShadow() {
    switch (_style) {
      case FloatingNavStyle.aurora:
        return [
          BoxShadow(
            color: FloatingNavSpec.auroraColors.first.withValues(alpha: 0.42),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ];
      case FloatingNavStyle.neon:
        return [
          BoxShadow(
            color: FloatingNavSpec.neonColor.withValues(alpha: 0.45),
            blurRadius: 18,
            spreadRadius: 1,
          ),
        ];
      case FloatingNavStyle.liquid:
        return [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ];
      case FloatingNavStyle.jelly:
        return [
          BoxShadow(
            color: _pal.primary.withValues(alpha: 0.26),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ];
      case FloatingNavStyle.outline:
        return [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ];
      case FloatingNavStyle.ink:
        return [
          BoxShadow(
            color: Colors.black.withValues(alpha: FloatingNavSpec.shadowAlpha),
            blurRadius: FloatingNavSpec.shadowBlur,
            offset: FloatingNavSpec.shadowOffset,
          ),
        ];
    }
  }

  /// 导航栏内部内容（弹性指示器 + 导航项），两种模式共用
  Widget _buildNavContent({
    required double height,
    bool iconOnly = false,
    double iconSize = 22.0,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = constraints.maxWidth / widget.items.length;
        final bandHeight = height;
        // 选中指示器 = 圆形（用户要求"图标和文字的背景太大，改成圆形"）：
        // 宽 = 高 = bandHeight，圆角 = 半径。不再用 1.25 倍宽的圆角矩形。
        final indicatorWidth = bandHeight;
        final pillPad = (itemWidth - indicatorWidth) / 2;
        return Stack(
          children: [
            // 果冻背景指示器（弹性滑动 + 弹性缩放）
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final progress = _curve.transform(_controller.value);
                final left =
                    _previousIndex * itemWidth +
                    (widget.currentIndex - _previousIndex) *
                        itemWidth *
                        progress;
                final scale = 0.88 + 0.12 * progress;
                final isDark = Theme.of(context).brightness == Brightness.dark;
                return Positioned(
                  top: 0,
                  left: left + pillPad,
                  width: indicatorWidth,
                  height: bandHeight,
                  child: Transform.scale(
                    scale: scale,
                    child: Container(
                      decoration: BoxDecoration(
                        color: FloatingNavSpec.styleIndicatorColor(
                          _style,
                          isDark: isDark,
                          palette: _pal,
                        ),
                        borderRadius: BorderRadius.circular(bandHeight / 2),
                      ),
                    ),
                  ),
                );
              },
            ),
            // 导航项（固定宽度，纵向拉伸保证点击区域）
            Positioned.fill(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: List.generate(widget.items.length, (index) {
                  return SizedBox(
                    width: itemWidth,
                    child: _JellyNavItem(
                      item: widget.items[index],
                      isSelected: index == widget.currentIndex,
                      onTap: () => _onItemTap(index),
                      onLongPress: widget.onLongPress != null
                          ? () => widget.onLongPress!(index)
                          : null,
                      onSlideUp: widget.onSlideUp != null
                          ? () => widget.onSlideUp!(index)
                          : null,
                      palette: _pal,
                      style: _style,
                      iconOnly: iconOnly,
                      iconSize: iconSize,
                    ),
                  );
                }),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 果冻导航项组件
class _JellyNavItem extends StatelessWidget {
  final JellyNavItem item;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSlideUp;
  final bool iconOnly;
  final double iconSize;
  final JellyPalette palette;
  final FloatingNavStyle style;

  const _JellyNavItem({
    required this.item,
    required this.isSelected,
    required this.onTap,
    required this.palette,
    required this.style,
    this.onLongPress,
    this.onSlideUp,
    this.iconOnly = false,
    this.iconSize = 22.0,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 取色走 FloatingNavSpec —— 与影视/音乐同一套规则，
    // 这样三条栏的"选中/未选中颜色"永远一致（用户要求颜色统一）。
    final color = FloatingNavSpec.styleContentColor(
      style,
      selected: isSelected,
      isDark: isDark,
      palette: palette,
    );

    return GestureDetector(
      // 上滑手势：唤起批量多选等（书架 tab 用；与长按并存）
      onVerticalDragEnd: onSlideUp == null
          ? null
          : (details) {
              if ((details.primaryVelocity ?? 0) < -250) onSlideUp!();
            },
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        // 用户 2026-10-18：「悬浮栏长按松手后有哒的一声」——
        // InkWell 默认 enableFeedback=true 会触发系统点击音（Android 的
        // SystemSound.click / iOS 的按键声）。底栏不需要任何声音反馈。
        enableFeedback: false,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Center(
          child: iconOnly
              ? AnimatedScale(
                  scale: isSelected ? 1.06 : 1.0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  child: _buildIcon(color),
                )
              // 用户调大 App 文字缩放（app.dart 全局 textScaler）时，
              // icon+label 的 Column 高度会超过 bandHeight → RenderFlex
              // 垂直溢出（黄黑条纹）。用 FittedBox(scaleDown) 包住：
              // 高度不够时等比缩小，任何字号下都不会溢出。
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 选中时图标轻微放大（1.06），比"只换颜色"更有反馈
                      AnimatedScale(
                        scale: isSelected ? 1.06 : 1.0,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                        child: _buildIcon(color),
                      ),
                      const SizedBox(height: FloatingNavSpec.iconLabelGap),
                      Text(
                        item.label,
                        // ⚠️ 必须限一行 + 省略号。
                        // 阅读栏可能到 6 项，每项宽度只有
                        // (屏宽 - 边距) / 项数 ≈ 65px。
                        // 标签一旦折成两行，总高度就会超过胶囊可用高度
                        // （72 - 上下内边距），表现为文字被切一半或溢出条纹。
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: color,
                          fontSize: FloatingNavSpec.labelSize,
                          // w600 = 音乐/影视的文字权重，统一后不会有一处偏粗
                          fontWeight: FloatingNavSpec.labelWeight,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildIcon(Color color) {
    // 用户上传的自定义图标优先（设置 → 主页页面 → 底栏风格与图标）
    final custom = SettingsService().navIconFor(item.label);
    if (custom != null && custom.isNotEmpty) {
      return Opacity(
        opacity: isSelected ? 1 : 0.62,
        child: Image.file(
          File(custom),
          width: iconSize,
          height: iconSize,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _defaultIcon(color),
        ),
      );
    }
    return _defaultIcon(color);
  }

  Widget _defaultIcon(Color color) {
    if (item.iconBuilder != null) {
      return item.iconBuilder!(color, iconSize);
    }
    return item.emoji != null
        ? Text(item.emoji!, style: TextStyle(fontSize: iconSize, height: 1.0))
        : Icon(item.icon, color: color, size: iconSize);
  }
}

/// 自定义图标构建器：传入颜色与尺寸，返回图标 Widget（跟随选中态变色）
typedef JellyIconBuilder = Widget Function(Color color, double size);

/// 导航项数据
class JellyNavItem {
  final IconData? icon;
  final String? emoji;
  final JellyIconBuilder? iconBuilder;
  final String label;

  const JellyNavItem({
    this.icon,
    this.emoji,
    this.iconBuilder,
    required this.label,
  }) : assert(icon != null || emoji != null || iconBuilder != null);
}
