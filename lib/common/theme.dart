import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../reading/theme/jelly_palette.dart';

/// 全局明暗：外观模式切换后 AppTheme 颜色跟着变（深色/浅色/跟随系统）
class AppBrightness {
  /// true = 浅色界面
  static final ValueNotifier<bool> isLight = ValueNotifier(false);
}

/// 主题配置 —— 取色统一来自**水墨书香**调色板（`JellyPalette.ink()`）。
///
/// ── 为什么改成"读调色板"而不是继续写字面量 ────────────────────
/// 用户要求影视/直播/音乐的 UI 风格与阅读一致，**功能不变**。
/// `AppTheme` 是影视侧所有颜色的唯一源头（各页面都写 `AppTheme.xxx`），
/// 所以只要这里取色变了，**整个影视模块立刻换风格，且一行业务代码都不用动** ——
/// 这是在"只换视觉、不动功能"的约束下最安全的改法。
///
/// ── 与阅读模块的关系（重要）──────────────────────────────────
/// 两边**各自独立**，不能互相干扰：
///   · 影视：`AppBrightness.isLight` 决定明暗（由 theme_mode_store 设置）
///   · 阅读：`SettingsService.isDarkMode` 决定明暗（可跟随系统）
/// 这里**直接持有** `JellyPalette.ink()`，不去调 `JellyTheme.apply()`
/// —— 后者是阅读模块的全局单例，动它会把阅读的主题也改掉。
///
/// ── 关于"取同一个调色板，深浅却不同"────────────────────────────
/// 调色板里本身就有 light/dark 两套值（`backgroundLight` / `backgroundDark`
/// 等）。这里按 `AppBrightness` 选其中一套，
/// 于是"白天/黑夜模式"仍然是各自独立开关的，只是**两套色都来自水墨书香**。
class AppTheme {
  /// 全局字号缩放（设置可调，默认 1.0）。
  ///
  /// #10：这个名字是对的 —— "界面字号"本来就属于**外观**，不属于播放器。
  /// 原来的读取入口在 `PlayerPrefs.instance.fontScale`（播放器设置里），
  /// 读起来是"字号缩放存在播放器设置里"，命名和功能不匹配。
  /// 现在 AppTheme 是唯一入口：
  ///   · 读取：`AppTheme.fontScale`（ValueNotifier，用 Obx/ValueListenableBuilder 监听）
  ///   · 写入：`AppTheme.setFontScale()`
  ///   · 加载：`AppTheme.loadFontScale()`（启动时读盘）
  /// PlayerPrefs 里的旧字段保留作**兼容壳**（delegate 到这里），
  /// 避免其它老代码突然找不到 `PlayerPrefs.instance.fontScale`。
  static final ValueNotifier<double> fontScale = ValueNotifier(1.0);

  static double fs(double base) => (base * fontScale.value).clamp(9.0, 40.0);

  /// 启动时从持久化读字号缩放（原 PlayerPrefs.load 里那行搬过来）
  static Future<void> loadFontScale() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getDouble('ui_font_scale') ?? 0;
    fontScale.value = (v >= 0.85 && v <= 1.30) ? v : 1.0;
  }

  /// 设置并持久化字号缩放
  static Future<void> setFontScale(double s) async {
    final v = s.clamp(0.85, 1.30);
    fontScale.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('ui_font_scale', v);
  }

  // ── 调色板来源（影视 + 直播共用一套）─────────────────────────────
  //
  // ⚠️ 为什么影视和直播能共用一套，而音乐/阅读要各自独立：
  //   `_tabPages` 里影视(0~3)与直播(4)在**同一个 PageView**中，
  //   永远不会同屏显示 —— 共用调色板没有任何视觉冲突。
  //   而音乐(5)/阅读(6)是独立 tab 且各自有完整主题体系，互不干扰。
  //
  // `AppTheme.` 在全项目被引用 1017 处，**不能**改成"每处传 module 参数"。
  // 所以这里的做法是：调色板换成"可由设置切换"，取色入口保持零改动
  // （1017 处调用一行都不用动）。

  /// 当前生效的调色板。默认水墨书香；由 `ModuleThemeStore` 驱动切换。
  static JellyPalette _palette = const JellyPalette.ink();

  /// 当前是哪个模块在用它（用于区分影视/直播各自的设置）
  static String _activeModule = 'video';

  static JellyPalette get palette => _palette;
  static String get activeModule => _activeModule;

  /// 由 store / 设置页调用：换调色板并通知重建
  ///
  /// 注意这里**不碰** `JellyTheme`（阅读模块的全局单例），
  /// 否则会把阅读的主题也一起改掉。
  static void applyPalette(JellyPalette p, {String? module}) {
    _palette = p;
    if (module != null) _activeModule = module;
    paletteRevision.value++;
  }

  /// 调色板变更通知（页面监听后重建即可换色）
  static final ValueNotifier<int> paletteRevision = ValueNotifier<int>(0);

  /// 当前明暗下的调色板取色入口
  static bool get _light => AppBrightness.isLight.value;

  /// 强调色（按钮/选中态/图标高亮）。
  ///
  /// ── 这里原来有个真问题 ────────────────────────────────────────
  /// 旧实现是 `static const Color accentColor = Color(0xFF3A3A3A)`
  /// —— **硬编码墨灰**。于是用户切到「粉色少女」「蓝色海洋」等配色时：
  ///   · 页面底色/卡片/文字**都会变**（那些走 backgroundPrimary 等 getter）
  ///   · **只有强调色永远是墨灰** → 按钮、选中态、勾选图标跟配色对不上
  ///
  /// 旧注释说"不能改成 getter，因为有 26 处 const 引用会一起失效"。
  /// 实测统计：266 处引用里**只有 5 处在 const 表达式内**（一个 CircularProgressIndicator
  /// 和四处 Icon），已经把那 5 处的 `const` 去掉。所以这个顾虑被高估了。
  ///
  /// 现在它是 **getter，跟随调色板** —— 与 [backgroundPrimary] 等同一套来源，
  /// 换配色时整页一起变。
  static Color get accentColor => _palette.primary;

  /// 强调色的浅一档（用于次要高亮、hover 态）
  static Color get accentLightColor => _palette.primaryLight;

  /// 页面底色：宣纸米白 / 墨夜
  static Color get backgroundPrimary =>
      _light ? _palette.backgroundLight : _palette.backgroundDark;

  /// 卡片/次级底色
  static Color get backgroundSecondary =>
      _light ? _palette.cardLight : _palette.cardDark;

  static Color get backgroundTertiary =>
      _palette.primary.withValues(alpha: _light ? 0.06 : 0.10);
  static Color get backgroundElevated =>
      _palette.primary.withValues(alpha: _light ? 0.08 : 0.12);

  // ===== 半透明卡片色 =====
  // 用调色板的卡片色 + 不同 alpha，保持"同一套色、多层透明"的观感
  static Color get backgroundCard =>
      (_light ? _palette.cardLight : _palette.cardDark).withValues(alpha: 0.80);
  static Color get backgroundCardElevated =>
      (_light ? _palette.cardLight : _palette.cardDark).withValues(alpha: 0.90);
  static Color get backgroundNavBar =>
      (_light ? _palette.cardLight : _palette.cardDark).withValues(alpha: 0.80);

  // ===== iOS 27 Liquid Glass 玻璃体系 =====
  // 玻璃底色仍用"墨色低透明度"来表达（而不是灰），
  // 这样玻璃面板在水墨底色上不会显脏。
  static Color get glassTint =>
      _palette.primary.withValues(alpha: _light ? 0.06 : 0.10);
  static Color get glassTintDeep =>
      _palette.primary.withValues(alpha: _light ? 0.05 : 0.12);
  /// 浅玻璃底（悬浮栏用）
  static Color get glassTintLight =>
      _palette.primary.withValues(alpha: _light ? 0.03 : 0.05);
  /// 超浅玻璃底（沉浸式底栏用）
  static Color get glassTintClear =>
      _palette.primary.withValues(alpha: _light ? 0.02 : 0.03);

  // 高光层: 顶部镜面高光（浅色下是白光、深色下也是白光，只是强弱不同）
  static Color get glassHighlightTop => _light
      ? Colors.white.withValues(alpha: 0.55)
      : Colors.white.withValues(alpha: 0.20);
  static Color get glassHighlightMid => _light
      ? Colors.white.withValues(alpha: 0.28)
      : Colors.white.withValues(alpha: 0.08);

  // 描边：用墨色低透明度，边缘分离感更"干净"
  static Color get glassBorder =>
      _palette.primary.withValues(alpha: _light ? 0.10 : 0.20);
  static Color get glassBorderSoft =>
      _palette.primary.withValues(alpha: _light ? 0.06 : 0.12);

  // ---- Liquid Glass：内侧双色边缘 ----
  //
  // 玻璃的"厚度感"来自**内侧**两条描边：顶部亮（光从上方来）、
  // 底部暗（玻璃背面吸光）。只有外圈单一描边时，面板看起来像"贴纸"。
  static Color get glassInnerTop =>
      Colors.white.withValues(alpha: _light ? 0.65 : 0.24);
  static Color get glassInnerBottom =>
      _palette.primary.withValues(alpha: _light ? 0.06 : 0.10);
  /// 顶部镜面弧线（很窄，模拟折射光带）
  static Color get glassSpecular =>
      Colors.white.withValues(alpha: _light ? 0.60 : 0.32);

  // 玻璃圆角 —— Liquid Glass 比旧版更圆更柔
  static const double glassRadius = 28; // 面板/弹窗大圆角
  static const double glassRadiusCard = 20; // 卡片圆角
  static const double glassRadiusSmall = 14; // 小控件（行内按钮/徽章）
  // 玻璃模糊强度 (对背景内容扩散更强)
  static const double glassBlurSigma = 28;

  // ---- Liquid Glass 动效曲线 ----
  static const Duration motionFast = Duration(milliseconds: 180);
  static const Duration motionBase = Duration(milliseconds: 260);
  static const Curve motionCurve = Curves.easeOutCubic;

  static Color get textPrimary => _light ? _palette.textPrimaryLight : _palette.textPrimaryDark;

  /// 次要文字：原先是半透明黑/白；这里用调色板的中灰 + 同等的"弱化"强度。
  /// 2026-10-01 提高深浅两档透明度（列表/卡片文字对比度不足：深色下太暗、浅色宣纸底上太浅）
  static Color get textSecondary =>
      _palette.textSecondary.withValues(alpha: _light ? 0.92 : 0.84);
  static Color get textTertiary =>
      _palette.textSecondary.withValues(alpha: _light ? 0.68 : 0.64);

  static Color get borderLight =>
      _palette.primary.withValues(alpha: _light ? 0.10 : 0.12);
  static Color get borderMedium =>
      _palette.primary.withValues(alpha: _light ? 0.16 : 0.18);

  // 间距
  static const double spacingXS = 4;
  static const double spacingSM = 8;
  static const double spacingMD = 12;
  static const double spacingLG = 16;
  static const double spacingXL = 20;
  static const double spacingXXL = 24;

  // 圆角
  static const double radiusSM = 8;
  static const double radiusMD = 10;
  static const double radiusLG = 14;
  static const double radiusXL = 20;

  // 卡片
  static const double cardRadius = 10;
  static const double cardSpacing = 6;
  static const double cardPadding = 8;

  // 字号
  static const double fontCaption = 11;
  static const double fontFootnote = 12;
  static const double fontSubhead = 13;
  static const double fontBody = 14;
  static const double fontHeadline = 16;
  static const double fontTitle3 = 18;
  static const double fontTitle2 = 20;

  /// 页面大标题（"音乐库" / "我的" / "书架" 这类整页标题，通常配 w700）。
  ///
  /// ── 为什么单独加这一档 ────────────────────────────────────────
  /// 三个模块原来各写各的：音乐 `24`、影视 `20`、阅读 `22`（主流）。
  /// 统一时若把 24 压到 `fontTitle2`(20) 会**明显变小**、页面层级感丢失；
  /// 取 **22** 是因为阅读侧已有 7 处用它作页面标题，改成 22 的改动面最小。
  static const double fontPageTitle = 22;

  /// 品牌大标题（splash / 关于页的 "TVBox" 这种大字）。
  /// 与 `textTheme.headlineLarge` 的 48 保持一致。
  static const double fontDisplay = 48;

  /// 底部导航栏的文字（比 [fontCaption] 还小一档，因为栏内空间紧）。
  static const double fontNavLabel = 10;

  /// 暗色主题

  /// 浅色主题（设置 → 深色/浅色/跟随系统）
  ///
  /// ── ⚠️ 这里曾有一个真 bug ──────────────────────────────────────
  /// 原来写的是 `scaffoldBackgroundColor: const Color(0xFFF6F6F7)`
  /// —— 一个**硬编码的 Material 默认灰**。
  /// 而 `darkTheme` 用的是 `backgroundPrimary`（跟随调色板）。
  ///
  /// 后果：**浅色模式完全不听「水墨书香」调色板**。
  /// 选中水墨书香后，桌面/设置页的页面底色是那块冷灰 `#F6F6F7`，
  /// 而不是调色板里的宣纸米白 `#F7F5F1` —— 用户看到的就是
  /// "浅色模式怎么是灰的"。首页因为自己铺了图/渐变层才显得正常，
  /// 设置页透明底就把它透出来了。
  ///
  /// 现在整块改为**跟随调色板**：所有 tab 页的 Scaffold 都是透明的，
  /// 它们都透出同一层背景；主题色必须两边一致，否则深/浅切换会
  /// 出现"深色对、浅色错"这种只错一半的现象。
  static ThemeData get lightTheme {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: backgroundPrimary,
      colorScheme: base.colorScheme.copyWith(
        primary: accentColor,
        secondary: accentColor,
        // 卡片/弹层用调色板的卡片色（深色模式下这两者也是分开的）
        surface: backgroundSecondary,
        onSurface: textPrimary,
        // 「次级容器」用它做输入框填充/分隔，跟调色板走
        surfaceContainerHighest: backgroundTertiary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: textPrimary,
      ),
      cardTheme: base.cardTheme.copyWith(
        color: backgroundSecondary,
        elevation: 0,
      ),
      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: backgroundSecondary,
      ),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        backgroundColor: backgroundSecondary,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: backgroundTertiary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(glassRadiusSmall),
          borderSide: BorderSide.none,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(accentColor),
      ),
      // #3：以下三项原来**只有 darkTheme 有**，lightTheme 缺 ——
      // 导致浅色模式下底部导航、Chip、文字全是 Material 默认样式，
      // 与整体水墨风不搭。现在两边齐全且都走调色板。
      // ⚠️ 一开始我写成 `_buildTextTheme(base.textTheme)` —— 那个函数
      // **并不存在**（我凭印象写的）。darkTheme 用的是**内联 TextTheme**
      // （9 种字号），所以这里照抄它的结构，只是颜色走浅色调色板。
      chipTheme: ChipThemeData(
        backgroundColor: backgroundTertiary,
        selectedColor: accentColor.withValues(alpha: 0.15),
        labelStyle: TextStyle(color: textSecondary, fontSize: fontSubhead),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        selectedItemColor: accentColor,
        unselectedItemColor: textTertiary,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle:
            const TextStyle(fontSize: fontNavLabel, fontWeight: FontWeight.w500),
        unselectedLabelStyle: const TextStyle(fontSize: fontNavLabel),
      ),
      // ── 按钮统一（三个模块的按钮圆角/内边距/按压反馈一致）──────────
      //
      // 三个模块此前都**没有**配 *ButtonTheme，全靠 Material 默认 +
      // 各处零散的 `styleFrom(...)` 覆盖 —— 于是同一个 App 里
      // 按钮圆角有 8/10/11/12/14 五种，内边距也各异。
      //
      // 这里从主题层统一：**圆角 20 = `glassRadiusCard`**（与卡片同一档）——
      // 用户明确要求按钮"对齐卡片那波的做法"。原来三模块的按钮圆角
      // 散在 8/10/11/12/14 五种，现在都归到卡片这一档。
      // 文字按钮保持紧凑的内边距（它们是对话框/设置行里最常用的，
      // 加大 padding 会把布局撑开）。
      //
      // ⚠️ 各处已有的 `styleFrom(borderRadius: ...)` **优先级高于主题**，
      // 所以这个主题不会破坏那些"故意不一样"的按钮（如胶囊形搜索/筛选）。
      // 它统一的是**没有显式指定样式**的那大部分。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(glassRadiusCard),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: const TextStyle(
            fontSize: fontBody,
            fontWeight: FontWeight.w600,
          ),
          // ── 阴影：对齐卡片那波（blur 12 / offset(0,4)）──────────
          // 原来按钮**完全没有阴影**，与有阴影的卡片不在同一个视觉层次上。
          // 用很淡的黑（6%：浅色 12%、深色 22%）—— 太重会显得脏。
          elevation: 1,
          shadowColor: Colors.black.withValues(alpha: _light ? 0.12 : 0.22),
          // ── 按压反馈 ─────────────────────────────────────────
          // 未指定 overlayColor 时用的是主题色叠加，三个模块因调色板不同
          // 而按压效果各异；这里统一成**中性**的：
          // 深色下压亮、浅色下压暗，与卡片/输入框同一套手感。
          overlayColor:
              (_light ? Colors.black : Colors.white).withValues(alpha: 0.08),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(glassRadiusCard),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: const TextStyle(
            fontSize: fontBody,
            fontWeight: FontWeight.w600,
          ),
          // 描边按钮**不加阴影**（它本来就是"平"的语义）；
          // 但按压反馈要和 Filled 一致，否则两种按钮手感不同。
          overlayColor:
              accentColor.withValues(alpha: _light ? 0.08 : 0.12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(glassRadiusCard),
          ),
          // 保持紧凑：TextButton 大量用在对话框/设置行里
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          textStyle: const TextStyle(fontSize: fontBody),
          // 按压反馈同样中性化（见 FilledButton 处的说明）
          overlayColor:
              accentColor.withValues(alpha: _light ? 0.08 : 0.12),
        ),
      ),
      // SnackBar 统一外观（与顶部气泡 AppToast 同一种视觉）
      snackBarTheme: SnackBarThemeData(
        backgroundColor: backgroundCard,
        contentTextStyle: TextStyle(
          color: textPrimary,
          fontSize: fontBody,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        elevation: 0,
      ),
      textTheme: TextTheme(
        headlineLarge: TextStyle(
            color: textPrimary, fontSize: fontDisplay, fontWeight: FontWeight.w800),
        headlineMedium: TextStyle(
            color: textPrimary,
            fontSize: fontTitle2,
            fontWeight: FontWeight.w700),
        headlineSmall: TextStyle(
            color: textPrimary,
            fontSize: fontTitle3,
            fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: textPrimary, fontSize: fontBody),
        bodyMedium: TextStyle(color: textSecondary, fontSize: fontSubhead),
        bodySmall: TextStyle(color: textTertiary, fontSize: fontFootnote),
        labelLarge: TextStyle(
            color: textPrimary, fontSize: fontBody, fontWeight: FontWeight.w600),
        labelMedium: TextStyle(color: textSecondary, fontSize: fontSubhead),
        labelSmall: TextStyle(color: textTertiary, fontSize: fontCaption),
      ),
      // #4：分隔线原来硬编码 Color(0x14000000)（黑色 8%），
      // 换配色时不变。改为从调色板派生。
      dividerTheme: DividerThemeData(
        color: borderLight,
        thickness: 1,
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: backgroundPrimary,
      colorScheme: ColorScheme.dark(
        primary: accentColor,
        secondary: accentLightColor,
        surface: backgroundSecondary,
        error: Colors.red,
      ),
      appBarTheme: AppBarTheme(
        // 透明 + 无 elevation: 让全局背景层透出, 配合页面顶部形成玻璃观感;
        // 需要真实毛玻璃的页面 (detail 等) 自行用 GlassPanel/flexibleSpace
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: fontHeadline,
          fontWeight: FontWeight.bold,
        ),
        iconTheme: IconThemeData(color: textSecondary),
      ),
      cardTheme: CardThemeData(
        color: backgroundSecondary,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: backgroundTertiary,
        selectedColor: accentColor.withValues(alpha: 0.15),
        labelStyle: TextStyle(color: textSecondary, fontSize: fontSubhead),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        selectedItemColor: accentColor,
        unselectedItemColor: textTertiary,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle:
            const TextStyle(fontSize: fontNavLabel, fontWeight: FontWeight.w500),
        unselectedLabelStyle: const TextStyle(fontSize: fontNavLabel),
      ),
      // ---- Liquid Glass：全局弹层大圆角 ----
      // 弹窗/底部弹层走 28（glassRadius），比旧版 16 更圆更柔。
      dialogTheme: DialogThemeData(
        backgroundColor: backgroundSecondary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(glassRadius),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(glassRadius),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: backgroundSecondary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(glassRadiusSmall),
          borderSide: BorderSide.none,
        ),
        hintStyle: TextStyle(color: textTertiary, fontSize: fontSubhead),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: spacingLG,
          vertical: spacingMD,
        ),
      ),
      // ── 按钮统一（三个模块的按钮圆角/内边距/按压反馈一致）──────────
      //
      // 三个模块此前都**没有**配 *ButtonTheme，全靠 Material 默认 +
      // 各处零散的 `styleFrom(...)` 覆盖 —— 于是同一个 App 里
      // 按钮圆角有 8/10/11/12/14 五种，内边距也各异。
      //
      // 这里从主题层统一：**圆角 20 = `glassRadiusCard`**（与卡片同一档）——
      // 用户明确要求按钮"对齐卡片那波的做法"。原来三模块的按钮圆角
      // 散在 8/10/11/12/14 五种，现在都归到卡片这一档。
      // 文字按钮保持紧凑的内边距（它们是对话框/设置行里最常用的，
      // 加大 padding 会把布局撑开）。
      //
      // ⚠️ 各处已有的 `styleFrom(borderRadius: ...)` **优先级高于主题**，
      // 所以这个主题不会破坏那些"故意不一样"的按钮（如胶囊形搜索/筛选）。
      // 它统一的是**没有显式指定样式**的那大部分。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(glassRadiusCard),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: const TextStyle(
            fontSize: fontBody,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(glassRadiusCard),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: const TextStyle(
            fontSize: fontBody,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(glassRadiusCard),
          ),
          // 保持紧凑：TextButton 大量用在对话框/设置行里
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          textStyle: const TextStyle(fontSize: fontBody),
        ),
      ),
      // SnackBar 统一外观（与顶部气泡 AppToast 同一种视觉）——
      // 全 App 56 处 showSnackBar 不改调用点，靠主题层统一长相。
      snackBarTheme: SnackBarThemeData(
        backgroundColor: backgroundCard,
        contentTextStyle: TextStyle(
          color: textPrimary,
          fontSize: fontBody,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        elevation: 0,
      ),
      textTheme: TextTheme(
        headlineLarge: TextStyle(
            color: textPrimary, fontSize: fontDisplay, fontWeight: FontWeight.w800),
        headlineMedium: TextStyle(
            color: textPrimary,
            fontSize: fontTitle2,
            fontWeight: FontWeight.w700),
        headlineSmall: TextStyle(
            color: textPrimary,
            fontSize: fontTitle3,
            fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: textPrimary, fontSize: fontBody),
        bodyMedium: TextStyle(color: textSecondary, fontSize: fontSubhead),
        bodySmall: TextStyle(color: textTertiary, fontSize: fontFootnote),
        labelLarge: TextStyle(
            color: textPrimary, fontSize: fontBody, fontWeight: FontWeight.w600),
        labelMedium: TextStyle(color: textSecondary, fontSize: fontSubhead),
        labelSmall: TextStyle(color: textTertiary, fontSize: fontCaption),
      ),
      useMaterial3: true,
    );
  }
}
