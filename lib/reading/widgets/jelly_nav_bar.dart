import 'dart:io';

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:tvbox/common/floating_nav_spec.dart';
import 'package:tvbox/reading/services/settings_service.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';
import 'package:tvbox/reading/theme/jelly_theme.dart';

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

  /// 首尾两项**固定**，只有中间的项参与横向滑动（影视底栏，2026-10-26）
  final bool pinEnds;

  /// 一屏基准显示几个（0 = 按可用宽度均分）。
  ///
  /// 影视底栏传 8：8 个以内按实际数量均分铺满，超过 8 个就
  /// 每项固定为「可用宽度 / 8」，中间那段静默横向滑动。
  final int maxSlots;

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
    this.pinEnds = false,
    this.maxSlots = 0,
    this.palette,
  }) : assert(
         items.length >= 2,
         // ── 为什么取消了 6 项上限（2026-10-26）──────────────────────
         // 影视首页的底栏项数是用户在「设置 → 主页页面」里自己勾的，
         // 全开能有十几个（首页/直播/音乐/阅读/程序/RSS/海阔/Emby/短剧/
         // 房间/REX/TG/史藏/设置）。原来硬性 assert ≤ 6：release 下断言
         // 被剔除、栏里就全挤成 44px 一条（用户："分类太多，太密"），
         // debug 下更会直接崩。
         // 现在项多时不再压窄，改成**每条目保持正常宽度 + 整条横向可滑**
         // （见 `_buildFloatingNavBar` 的 scrollable 分支），所以只保留下限。
         '导航项至少要 2 个',
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

  /// 当前悬浮栏风格（设置页可切换：
  /// 水墨 / macOS 玻璃 / 鸿蒙卡片 / iOS 液态 / 澎湃 / 云母 Mica）
  FloatingNavStyle get _style =>
      FloatingNavStyle.fromId(SettingsService().navStyle);

  late AnimationController _controller;
  int _previousIndex = 0;

  /// 项太多时整条栏可横向滑动（用户 2026-10-26：「分类很多，太密」）
  final ScrollController _scrollCtrl = ScrollController();

  /// 最近一次布局时每项的宽度（自动滚到选中项要用）
  double _scrollItemW = 0;

  /// 上一次已经自动滚到过哪个下标（避免每次 build 都强行滚动，
  /// 用户手动滑走后不该被拉回去）
  int _revealedIndex = -1;

  /// 果冻弹性曲线（直接 transform，避免在 build 中创建 CurvedAnimation 造成监听器泄漏）
  static const _curve = ElasticOutCurve(0.7);

  // 导航栏尺寸：整体加高，底部间距稍高于顶部，左右上角圆角
  static const _barHeight = 80.0; // 整体高度（原 64）
  static const _topPad = 10.0; // 顶部间距
  static const _bottomPad = 18.0; // 底部间距（> 顶部，内容整体偏上）
  static const _topRadius = 20.0; // 左、右上角圆角
  // 选中指示器为圆形（宽=高），宽度由 itemWidth 与 bandHeight 反算，无固定内边距常量

  // 悬浮模式尺寸（高度/边距在 Widget 类中公开定义，供外部避让使用）
  /// 悬浮胶囊圆角（按风格变：macOS 26 / 鸿蒙 20 / iOS 满胶囊 / 澎湃 24 / 云母 16）
  double get _floatingRadius => FloatingNavSpec.styleRadius(_style);
  static const _floatingTopPad = FloatingNavSpec.innerPadV; // 悬浮时上下内边距
  static const _floatingIconSize = FloatingNavSpec.iconSize; // 与影视/音乐统一
  // 悬浮每项宽度随屏宽自适应（宽屏适当加宽），见 _buildFloatingNavBar
  static const _floatingItemMin = 80.0; // 每项最小宽度（手机保底）
  static const _floatingItemMax = 120.0; // 每项最大宽度（宽屏上限）
  static const _floatingItemFactor = 0.2; // 随屏宽增长系数

  /// 每项低于这个宽度就算"挤"：不再继续压窄，改成整条可横向滑动
  static const _floatingItemComfort = 64.0;

  /// 栏可滑动时：把当前选中的项滚进可视区（居中）
  ///
  /// [contentIndex] = 该项在**滚动内容**里的下标（固定首尾时中间那段是 `index-1`）
  void _revealSelected(double itemWidth, bool scrollable, {int? contentIndex}) {
    final idx = contentIndex ?? widget.currentIndex;
    _scrollItemW = itemWidth;
    if (!scrollable) return;
    if (_revealedIndex == idx) return;
    _revealedIndex = idx;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      final pos = _scrollCtrl.position;
      final center = idx * _scrollItemW + _scrollItemW / 2;
      final target =
          (center - pos.viewportDimension / 2).clamp(0.0, pos.maxScrollExtent);
      if ((pos.pixels - target).abs() < 1) return;
      _scrollCtrl.animateTo(
        target.toDouble(),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 850), // 切换速度放慢（原 600）
      vsync: this,
    )..value = 1.0; // 初始处于静止态，指示器归位到当前项
    // 设置变化时重建：背景动画开关决定是否套 BackdropFilter 模糊，
    // 风格 / 不透明度也是每次 build 现读的 ⇒ 改完立即生效。
    SettingsService().addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SettingsService().removeListener(_onSettingsChanged);
    _controller.dispose();
    _scrollCtrl.dispose();
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
          // ── 项多到放不下时**不再硬挤**（用户 2026-10-26）──────────
          //   影视底栏（pinEnds + maxSlots=8）：
          //     · ≤8 项 ⇒ 按实际数量均分铺满（和原来的观感一致）
          //     · >8 项 ⇒ 每项固定「可用宽度 / 8」，首页/设置固定不动，
          //       中间那段静默横向滑动（无回弹、无渐变、无滚动条）
          //   阅读/音乐底栏（未传 pinEnds）：沿用"挤不下才滑"的老规则。
          final n = widget.items.length;
          final pinned = widget.pinEnds && n >= 3;
          final slots = widget.maxSlots > 0 ? widget.maxSlots : n;
          final fit = available / n;
          final scrollable = pinned ? n > slots : fit < _floatingItemComfort;
          final perItem = pinned
              ? available / (n <= slots ? n : slots)
              : (scrollable ? ideal : fit.clamp(44.0, ideal));
          final contentWidth = (pinned || scrollable)
              ? available
              : n * perItem;
          // 胶囊居中：在屏幕边距基础上补足左右内边距，垂直结构保持不变（仍贴底部）
          // 可滑动（含固定首尾）时胶囊直接占满可用宽度，不再补居中留白
          final sidePad = (pinned || scrollable)
              ? 0.0
              : ((constraints.maxWidth - contentWidth) / 2 - horizontalMargin)
                  .clamp(0.0, double.infinity);
          // 背景动画开启时跳过 BackdropFilter：底层每帧重绘下，高斯模糊逐帧采样
          // 是 GPU 主力开销；改用更高不透明度纯色（动效透出可接受，图标仍清晰）。
          // 动画关闭时底层静止，模糊成本低，保留玻璃质感。
          final bgAnim = SettingsService().backgroundAnimation;
          final barDeco = _barDecoration(isDark);
          final navBody = Container(
            height: JellyNavBar.floatingBarHeight,
            decoration: barDeco,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: _floatingTopPad),
              child: pinned
                  // 首尾固定 + 中间可滑（影视底栏）
                  ? _buildPinnedNavContent(
                      height: JellyNavBar.floatingBarHeight -
                          _floatingTopPad * 2,
                      itemWidth: perItem,
                      iconOnly: SettingsService().navIconOnly,
                      iconSize: SettingsService().navIconOnly
                          ? 26
                          : _floatingIconSize,
                    )
                  : _buildNavContent(
                      height: JellyNavBar.floatingBarHeight -
                          _floatingTopPad * 2,
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
                      // 项数放不下时按这个宽度排布并允许横向滑动
                      itemWidth: perItem,
                    ),
            ),
          );
          // 要不要背景模糊由 FloatingNavSpec.needsBlur 决定：
          // 玻璃类（macOS/iOS）必须模糊才有质感；但**栏体本身不够透时
          // 模糊被完全盖住**（水墨/鸿蒙/云母默认不透明度 0.90~0.95，
          // 实测开/关模糊只差 0~96 个像素）⇒ 那就别白烧一次全屏高斯。
          // 用户把不透明度滑杆拉低后会自动开始模糊，功能没砍。
          final useBlur =
              !bgAnim && FloatingNavSpec.needsBlur(_style, barDeco);
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
                boxShadow: _barShadow(isDark),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_floatingRadius),
                // ── 模糊层 / 内容层拆开（2026-10-27，修「横向滑动不顺」）──────
                //
                // 原来是 `BackdropFilter(child: navBody)`：navBody 里**含可横向
                // 滑动的内容**（影视底栏中间那段）。滚动会让整棵子树每帧重绘，
                // 而 BackdropFilter 是逐帧执行的 —— sigma=15 的高斯模糊
                // 每帧重算一次、面积还是整条栏 ⇒ 真机上拖底栏直接掉帧，
                // 手感"发涩/不顺"。
                //
                // 拆开以后：模糊层只负责模糊背景、内容层单独一个 RepaintBoundary。
                // 滚动只重绘内容层，模糊层的栅格可以被合成器直接复用 ⇒
                // 滑动不再触发模糊。
                child: Stack(
                  children: [
                    if (useBlur)
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: BackdropFilter(
                            filter: JellyTheme.glassFilter,
                            // ── ⚠️ 这个透明 child 不能删（2026-10-31 实测）──
                            //
                            // 上一版这里写的是「不要 child：只把背景模糊掉，
                            // 底色由内容层画」，**注释是错的**：
                            // `BackdropFilter` 一旦没有 child，整层模糊会被
                            // 直接丢弃 —— 不是"模糊了但看不见"，是**根本不执行**。
                            //
                            // 实测（sigma=20，红/蓝两块拼色，取交界上方 8px
                            // 的红通道）：无 child ⇒ 255（原封不动）；
                            // 加一个全透明 child ⇒ 164（交界被摊成渐变）。
                            // 四种层结构（裸的 / +ClipRRect / +内层
                            // RepaintBoundary / 两者都有）结果全是 164，
                            // 说明**只有 child 有无才致命**，ClipRRect 和
                            // RepaintBoundary 都不影响。
                            //
                            // 后果：六种风格从来没模糊过，玻璃全成了"平的
                            // 半透明色块"—— 用户那句"你看看你写的什么玩意"，
                            // 一半是配色，另一半就是这个。
                            child: const ColoredBox(color: Colors.transparent),
                          ),
                        ),
                      ),
                    // ── 顶部高光（2026-10-31）──────────────────────────
                    //
                    // 参考 `abhay572002/glass_liquid_navbar`（MIT）：真实
                    // iOS 26 液态玻璃在玻璃之上还要再画一层
                    // **从顶部往下 40% 渐隐的白色**（它的 `_GlassPainter`
                    // 里那段 specular 渐变，opacity 深色 0.20 / 浅色 0.08）。
                    // 少了这层，玻璃就是一块"平的半透明色"，怎么调透明度
                    // 都不像液态 —— 这是原来六种风格"看着假"的主因之一。
                    if (FloatingNavSpec.usesSpecularHighlight(_style))
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius:
                                  BorderRadius.circular(_floatingRadius),
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.white.withValues(
                                    alpha: isDark ? 0.20 : 0.08,
                                  ),
                                  Colors.white.withValues(alpha: 0),
                                ],
                                stops: const [0.0, 0.40],
                              ),
                            ),
                          ),
                        ),
                      ),
                    // ── 顶部 1px 亮线（云母 Mica 的标志）──────────────
                    //
                    // Windows 11 Mica 没有大面积高光，只有一条顶部亮边
                    // （色值约 rgba(255,255,255,0.09)）。
                    if (FloatingNavSpec.usesTopHairline(_style))
                      Positioned(
                        top: 0,
                        left: _floatingRadius * 0.6,
                        right: _floatingRadius * 0.6,
                        child: IgnorePointer(
                          child: Container(
                            height: 1,
                            color: Colors.white
                                .withValues(alpha: isDark ? 0.10 : 0.65),
                          ),
                        ),
                      ),
                    // ⚠️ navBody 必须是**非定位**子节点：只有 Positioned 子节点时
                    // Stack 会取 constraints.biggest（这里 = 整屏高），栏会被拉满屏。
                    // 它自带 height=floatingBarHeight，正好用来定 Stack 的高度。
                    RepaintBoundary(child: navBody),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 悬浮胶囊底色（六种风格的配色**只在 FloatingNavSpec 里写一份**）。
  ///
  /// 2026-10-30 重构：这里原来有一整段 switch，和设置页的预览卡各写一份，
  /// 改一边忘另一边就"预览跟实际不一样"。现在统一委托过去。
  BoxDecoration _barDecoration(bool isDark) {
    return FloatingNavSpec.barDecoration(
      style: _style,
      isDark: isDark,
      palette: _pal,
      opacity: SettingsService().navBarOpacity,
    );
  }

  /// 悬浮胶囊外阴影（同色光晕 / 中性投影，规格在 FloatingNavSpec）
  List<BoxShadow> _barShadow(bool isDark) {
    return FloatingNavSpec.barShadows(
      style: _style,
      isDark: isDark,
      palette: _pal,
    );
  }

  /// 单个导航项（图标 + 文字），两种布局共用
  Widget _navItemAt(
    int index,
    double width, {
    required bool iconOnly,
    required double iconSize,
    double? position,
  }) {
    return SizedBox(
      width: width,
      child: _JellyNavItem(
        item: widget.items[index],
        index: index,
        // 指示器的**连续**位置（如 2.37 = 正从第 2 项滑向第 3 项）。
        // 传 null 表示"不参与滑动"（固定端），此时按 isSelected 二值取色。
        position: position,
        isSelected: index == widget.currentIndex,
        onTap: () => _onItemTap(index),
        onLongPress:
            widget.onLongPress != null ? () => widget.onLongPress!(index) : null,
        onSlideUp:
            widget.onSlideUp != null ? () => widget.onSlideUp!(index) : null,
        palette: _pal,
        style: _style,
        iconOnly: iconOnly,
        iconSize: iconSize,
      ),
    );
  }

  /// 选中指示块（返回 Positioned ⇒ 必须直接放进 Stack）
  ///
  /// 形态跟着风格走：圆形块 / 圆角矩形 / 底部圆点 / 底部短线
  /// （用户 2026-10-24：「你就是换个颜色吗？」—— 形状也必须有区别）
  Widget _indicator({
    required double bandHeight,
    required double itemWidth,
    required bool visible,
    double left = 0,
    double scale = 1,
  }) {
    final ind = FloatingNavSpec.styleIndicator(_style);
    final indWidth = switch (ind) {
      NavIndicator.blob => bandHeight,
      NavIndicator.pill => itemWidth * 0.74,
      NavIndicator.dot => 5.0,
      NavIndicator.underline => 18.0,
    };
    final indHeight = switch (ind) {
      NavIndicator.blob => bandHeight,
      NavIndicator.pill => bandHeight * 0.78,
      NavIndicator.dot => 5.0,
      NavIndicator.underline => 3.0,
    };
    final indPad = (itemWidth - indWidth) / 2;
    final bool indAtBottom =
        ind == NavIndicator.dot || ind == NavIndicator.underline;
    final indBottom = ind == NavIndicator.dot ? 6.0 : 4.0;
    final indRadius = switch (ind) {
      NavIndicator.blob => bandHeight / 2,
      NavIndicator.pill => 10.0,
      NavIndicator.dot => 3.0,
      NavIndicator.underline => 2.0,
    };
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 指示器颜色只取一次：下面的发光阴影必须跟它同色，
    // 原来这里写死 `neonColor`（青色），换成云母/鸿蒙后光晕颜色就错了。
    final indColor = FloatingNavSpec.styleIndicatorColor(
      _style,
      isDark: isDark,
      palette: _pal,
    );
    return Positioned(
      top: indAtBottom ? null : (bandHeight - indHeight) / 2,
      bottom: indAtBottom ? indBottom : null,
      left: left + indPad,
      width: indWidth,
      height: indHeight,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: visible ? 1 : 0,
        child: Transform.scale(
          scale: scale,
          child: Container(
            decoration: BoxDecoration(
              color: indColor,
              borderRadius: BorderRadius.circular(indRadius),
              // ── 光晕层（2026-10-31）────────────────────────────────
              //
              // 参考 `abhay572002/glass_liquid_navbar`（MIT）的真实 iOS 26
              // 液态玻璃实现：它的指示器是**两层** ——
              //   · 下层 `MaskFilter.blur(15)` 的模糊光晕（alpha 0.1）
              //   · 上层实心色块（alpha 0.2）
              //
              // 原来这里只画了一个纯色块，所以怎么调都"没有液态感"。
              // Flutter 里用 BoxShadow 做等价效果，比 CustomPaint +
              // MaskFilter 便宜（不需要每帧新建 Paint/图层）。
              boxShadow: [
                BoxShadow(
                  // 底部指示条（若有风格启用）原本就带较强发光，保留
                  color: indColor.withValues(
                    alpha: ind == NavIndicator.underline ? 0.65 : 0.34,
                  ),
                  blurRadius: ind == NavIndicator.underline ? 8 : 14,
                  spreadRadius: ind == NavIndicator.underline ? 0 : 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 导航栏内部内容（弹性指示器 + 导航项），两种模式共用
  ///
  /// [itemWidth] 不为空时按该宽度排布每一项：总宽超过可视区就**整条横向滑动**
  /// （项太多的场景），否则和以前一样平分宽度。
  Widget _buildNavContent({
    required double height,
    bool iconOnly = false,
    double iconSize = 22.0,
    double? itemWidth,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = widget.items.length;
        final fitWidth = constraints.maxWidth / count;
        // 没显式给宽度时（贴底固定栏）也走同一套：挤不下就滑动，
        // 不把每项压成一条缝
        final minComfort = iconOnly ? 52.0 : _floatingItemComfort;
        final w =
            itemWidth ?? (fitWidth < minComfort ? minComfort : fitWidth);
        final contentWidth = w * count;
        final scrollable = contentWidth > constraints.maxWidth + 0.5;
        _revealSelected(w, scrollable);
        final band = SizedBox(
          width: contentWidth,
          height: height,
          // 指示器 + 导航项**一起**放进 AnimatedBuilder：
          // 图标颜色要跟着滑块连续渐变，所以每帧都得重算（项数 5~8，开销可忽略，
          // 且只在切换的那 300ms 内重建）。
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final progress = _curve.transform(_controller.value);
              // 指示器的**连续**位置（如 2.37 = 正从第 2 项滑向第 3 项）
              final pos = _previousIndex +
                  (widget.currentIndex - _previousIndex) * progress;
              return Stack(
                children: [
                  // 选中指示器（弹性滑动 + 弹性缩放）
                  _indicator(
                    bandHeight: height,
                    itemWidth: w,
                    visible: true,
                    left: pos * w,
                    scale: 0.88 + 0.12 * progress,
                  ),
                  // 导航项（固定宽度，纵向拉伸保证点击区域）
                  Positioned.fill(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < count; i++)
                          _navItemAt(
                            i,
                            w,
                            iconOnly: iconOnly,
                            iconSize: iconSize,
                            position: pos,
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        );
        if (!scrollable) return band;
        // 项太多：横向滑动（高度不变，胶囊外形与间距完全不受影响）
        // ClampingScrollPhysics：不要 iOS 那种回弹拖影，滑动"无痕"
        //
        // DragStartBehavior.down（2026-10-27）：默认的 `.start` 要等手指走过
        // 触摸斜率（~18pt）才认下这一拖，内容在那之前**纹丝不动**，然后突然
        // 追上手指 —— 手感就是"粘一下再动"。改成 `.down` 后从按下点开始
        // 跟手，起步不再有那一下迟滞。
        return SingleChildScrollView(
          controller: _scrollCtrl,
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          dragStartBehavior: DragStartBehavior.down,
          child: band,
        );
      },
    );
  }

  /// 首尾**固定**、中间可滑的布局（影视底栏，用户 2026-10-26）
  ///
  ///   [首页] [ ⇠ 中间分类，横向滑动 ⇢ ] [设置]
  ///
  /// 首页/设置不随滑动移动；中间项宽度固定（= 可用宽度 / maxSlots），
  /// 超出可视区时静默滚动（无回弹 / 无滚动条 / 无边缘渐变）。
  Widget _buildPinnedNavContent({
    required double height,
    required double itemWidth,
    required bool iconOnly,
    required double iconSize,
  }) {
    final n = widget.items.length;
    final midCount = n - 2;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _pinnedEnd(0, itemWidth, height, iconOnly, iconSize),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final midWidth = midCount * itemWidth;
              final scrollable = midWidth > c.maxWidth + 0.5;
              final inMid = widget.currentIndex > 0 &&
                  widget.currentIndex < n - 1;
              if (inMid) {
                _revealSelected(
                  itemWidth,
                  scrollable,
                  contentIndex: widget.currentIndex - 1,
                );
              }
              final mid = SizedBox(
                width: midWidth,
                height: height,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final progress = _curve.transform(_controller.value);
                    final prevMid = (_previousIndex - 1).clamp(0, midCount - 1);
                    final curMid =
                        (widget.currentIndex - 1).clamp(0, midCount - 1);
                    final midPos =
                        prevMid + (curMid - prevMid) * progress.toDouble();
                    // midPos 是"中间段内的 0-based 位置"，映射回整条栏的
                    // 原始索引要 +1（中间段从第 1 项开始）。
                    // 当前停在固定端时（inMid == false）不参与滑动，传 null 走二值。
                    final itemPos = inMid ? midPos + 1 : null;
                    return Stack(
                      children: [
                        // 指示器跟着中间内容一起滚（跨段时淡入淡出，不做整条横飞）
                        _indicator(
                          bandHeight: height,
                          itemWidth: itemWidth,
                          visible: inMid,
                          left: midPos * itemWidth,
                        ),
                        Positioned.fill(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var i = 1; i < n - 1; i++)
                                _navItemAt(
                                  i,
                                  itemWidth,
                                  iconOnly: iconOnly,
                                  iconSize: iconSize,
                                  position: itemPos,
                                ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              );
              return ClipRect(
                child: scrollable
                    ? SingleChildScrollView(
                        controller: _scrollCtrl,
                        scrollDirection: Axis.horizontal,
                        // 关掉回弹：滑动不留任何视觉痕迹
                        physics: const ClampingScrollPhysics(),
                        // 见 _buildNavContent 里的说明：`.down` 才跟手
                        dragStartBehavior: DragStartBehavior.down,
                        child: mid,
                      )
                    : mid,
              );
            },
          ),
        ),
        _pinnedEnd(n - 1, itemWidth, height, iconOnly, iconSize),
      ],
    );
  }

  /// 固定端（首页 / 设置）
  Widget _pinnedEnd(
    int index,
    double width,
    double height,
    bool iconOnly,
    double iconSize,
  ) {
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: [
          _indicator(
            bandHeight: height,
            itemWidth: width,
            visible: widget.currentIndex == index,
          ),
          Positioned.fill(
            child: _navItemAt(
              index,
              width,
              iconOnly: iconOnly,
              iconSize: iconSize,
            ),
          ),
        ],
      ),
    );
  }
}

/// 果冻导航项组件
class _JellyNavItem extends StatelessWidget {
  final JellyNavItem item;

  /// 本项在栏里的下标（算连续邻近度要用）
  final int index;

  /// 指示器的连续位置；null = 固定端，按 [isSelected] 二值取色
  final double? position;

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
    required this.index,
    required this.isSelected,
    required this.onTap,
    required this.palette,
    required this.style,
    this.position,
    this.onLongPress,
    this.onSlideUp,
    this.iconOnly = false,
    this.iconSize = 22.0,
  });

  /// 本项与指示器的"邻近度"：1 = 指示器正压在上面，0 = 完全不沾。
  ///
  /// 参考 `abhay572002/glass_liquid_navbar`（MIT）的 `_TabItem._proximity`：
  /// iOS 26 液态玻璃的图标颜色是**跟着滑块连续渐变**的，不是到位才跳变。
  /// 曲线用 `easeIn`（同样是它那里的写法），滑动前半程颜色变化慢、
  /// 后半程快，观感更像真实液体。
  double get _proximity {
    final pos = position;
    if (pos == null) return isSelected ? 1.0 : 0.0;
    final d = (pos - index).abs().clamp(0.0, 1.0);
    return Curves.easeIn.transform(1.0 - d);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 取色走 FloatingNavSpec —— 与影视/音乐同一套规则，
    // 这样三条栏的"选中/未选中颜色"永远一致（用户要求颜色统一）。
    final onColor = FloatingNavSpec.styleContentColor(
      style,
      selected: true,
      isDark: isDark,
      palette: palette,
    );
    final offColor = FloatingNavSpec.styleContentColor(
      style,
      selected: false,
      isDark: isDark,
      palette: palette,
    );
    final p = _proximity;
    // 两端直接返回原色，避免 lerp 在 0/1 处产生微小色差
    final color = p >= 0.999
        ? onColor
        : (p <= 0.001 ? offColor : Color.lerp(offColor, onColor, p)!);
    // 图标缩放也跟着连续化（原来只有 1.0 / 1.06 两档，滑动时会"啪"一下）
    final iconScale = 1.0 + 0.06 * p;

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
                  scale: iconScale,
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
                      // 选中时图标轻微放大（最多 1.06），跟着滑块连续变化
                      AnimatedScale(
                        scale: iconScale,
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
