import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
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

  /// 「在当前明暗下都看得清」的强调色 —— **当文字 / 图标 / 细描边用时请用它**，
  /// 不要直接用 [accentColor]。
  ///
  /// ⚠️ 用户 2026-10-15：「新加的功能白天看着可以，**晚上完全看不清字**」：
  ///   [accentColor] 取调色板 `primary`，而默认「水墨书香」的 primary 是
  ///   **#3A3A3A 墨灰** ⇒ 压在暗底（#1C1C1E / 卡片 #2A2A2C）上几乎不可见。
  ///   ⇒ 暗色模式改用 `textPrimaryDark`（浅色），浅色模式保持调色板 primary。
  static Color get accentOnSurface =>
      _light ? _palette.primary : _palette.textPrimaryDark;

  /// 「在当前明暗下都看得清」的强调色**淡底**（chip / 徽标 / 选中块底用）
  static Color get accentSurface => _light
      ? _palette.primary.withValues(alpha: 0.10)
      : Colors.white.withValues(alpha: 0.08);

  /// 强调色的浅一档（用于次要高亮、hover 态）
  static Color get accentLightColor => _palette.primaryLight;

  /// 页面底色：宣纸米白 / 墨夜
  static Color get backgroundPrimary =>
      _light ? _palette.backgroundLight : _palette.backgroundDark;

  /// 卡片/次级底色
  static Color get backgroundSecondary =>
      _light ? _palette.cardLight : _palette.cardDark;

  /// 淡底（圆形按钮底 / 未选中卡片底等）。
  ///
  /// ⚠️ 暗色下**不能再用调色板 primary**（默认「水墨书香」是 #3A3A3A 墨灰）——
  ///   墨灰淡底压在暗底（#1C1C1E）上等于没有（用户 2026-10-15：
  ///   「晚上完全看不清」）⇒ 暗色改成**白色淡底**；浅色保持原样，白天观感不变。
  static Color get backgroundTertiary => _light
      ? _palette.primary.withValues(alpha: 0.06)
      : Colors.white.withValues(alpha: 0.08);
  static Color get backgroundElevated => _light
      ? _palette.primary.withValues(alpha: 0.08)
      : Colors.white.withValues(alpha: 0.12);

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
  ///
  /// ── 2026-10-20 暗色再提亮 ─────────────────────────────────────
  /// 用户反馈「夜间模式字体是灰色的，伤眼」：调色板中灰（如 #8E8E93）压墨夜底
  /// 只有 ~3.3:1 对比度。暗色改为**白色降透明度**（稳定 ~8:1，不随配色漂移），
  /// 浅色仍用调色板原值（白天观感不变）。
  static Color get textSecondary => _light
      ? _palette.textSecondary.withValues(alpha: 0.92)
      : Colors.white.withValues(alpha: 0.72);
  static Color get textTertiary => _light
      ? _palette.textSecondary.withValues(alpha: 0.68)
      : Colors.white.withValues(alpha: 0.55);

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

  // ============================================================
  // 页面顶栏（Page Header）统一规格
  // ============================================================
  //
  // ── 为什么需要这个（A 档：统一规格）────────────────────────────
  // 阅读模块有 **8 个页面各自手写顶栏**（漫画/图书搜索、书架、收藏、
  // 下载、我的、图书详情、书源登录…），风格照 cmbok 截图排过，
  // 但**边距各写各的**，实测散成这样：
  //
  //   top   : 6（5 处） / 0（1 处）
  //   left  : 16（3 处） / 12（2 处） / 4（2 处）
  //   right : 12（3 处） / 16（1 处）
  //
  // 后果：**页与页之间标题的起始位置差 4px**，左右滑动切页时看得出来；
  // 而且两边不对称（left 16 / right 12）会让整行看起来"歪了一点"。
  //
  // 这里把规格收成一处，8 个页面都改用它 —— 改一次、8 页同时生效。
  //
  // ⚠️ 与 [FloatingNavSpec] 同一思路（那边管底部悬浮栏）。
  /// 顶栏距安全区顶部的距离
  static const double headerTop = 8;

  /// 顶栏左右外边距（**左右必须相等**，否则整行视觉偏移）
  static const double headerSide = 16;

  /// 标题与后续控件之间的间距
  static const double headerTitleGap = 10;

  /// 顶栏内相邻控件之间的间距
  static const double headerGap = 8;

  /// 顶栏一行的**标称高度** —— 与分段胶囊
  /// （`JellySegmentedToggle` 的 `height: 50`）对齐，
  /// 这样"有胶囊"和"没胶囊"的页面顶栏高度一致。
  static const double headerSlot = 50;

  /// 撑起顶栏的最小高度（`headerTop + headerSlot` + 下方留白）
  static const double headerHeight = headerTop + headerSlot + headerGap;

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
      // iOS 风格转场：页面右滑进入 / 左滑返回（Navigator.push 的
      // MaterialPageRoute 全部套用，含 iOS 边缘返回手势）
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: _CupertinoLikeTransitionsBuilder(),
          TargetPlatform.macOS: _CupertinoLikeTransitionsBuilder(),
          TargetPlatform.android: _CupertinoLikeTransitionsBuilder(),
        },
      ),
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
        // ⚠️ 必须显式指定：本主题的 AppBar 是**透明底**，而 Flutter 的默认
        // 推导会对透明底得出 `SystemUiOverlayStyle.light`（白色图标）——
        // 于是浅色页面上状态栏时钟/电量变成白字压浅底，看不见。
        // 深色主题同理要发浅色图标，见下方 darkTheme。
        systemOverlayStyle: SystemUiOverlayStyle.dark,
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
        // 统一透明底：所有输入框不再带灰填充（用户要求全局去灰底）
        filled: false,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(glassRadiusSmall),
          borderSide: BorderSide.none,
        ),
      ),
      switchTheme: SwitchThemeData(
        // 之前只设了 thumbColor ⇒ 轨道走 Material 默认主色（深色主题下近黑），
        // 用户看到的就是"开关全黑"。这里按平台习惯补全：
        // 开 = 主题色轨道 + 白色圆点；关 = 灰轨道 + 白色圆点。
        thumbColor: WidgetStateProperty.all(Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              // 不能直接用 accentColor：默认「水墨书香」的 primary 是 #3A3A3A，
              // 深色下就是用户说的"全黑开关" ⇒ 统一用调色板里的蓝。
              ? _palette.blue
              : textTertiary.withValues(alpha: 0.30),
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
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
      // iOS 风格转场（与 lightTheme 一致）
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: _CupertinoLikeTransitionsBuilder(),
          TargetPlatform.macOS: _CupertinoLikeTransitionsBuilder(),
          TargetPlatform.android: _CupertinoLikeTransitionsBuilder(),
        },
      ),
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
        // 透明底导致 Flutter 默认推导出白色图标 —— 深色主题下这是对的，
        // 但必须**显式**写出来，否则浅色主题的 AppBar 也会跟着发白色图标
        //（两个主题共用 AppBar 的默认推导逻辑）。
        systemOverlayStyle: SystemUiOverlayStyle.light,
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
        // 统一透明底：所有输入框不再带灰填充（用户要求全局去灰底）
        filled: false,
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
      // 开关：开 = 蓝色轨道 + 白点，关 = 灰轨道 + 白点
      //（深色主题原来漏配 ⇒ 轨道走 Material 默认主色，看起来就是全黑）
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? _palette.blue
              : textTertiary.withValues(alpha: 0.30),
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
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

/// iOS 风格页面转场（自实现，零依赖）：
/// 新页面从右侧滑入（**不淡化**），被压在下面的旧页面同步向左让开一点（视差），
/// 返回时反向。给 `Navigator.push(MaterialPageRoute)` 的路由用
/// （Get 路由的 iOS 转场由 `GetMaterialApp.defaultTransition` 提供）。
///
/// ⚠️ 为什么**不能淡化**新页 ✗：新页 opacity < 1 时会**透出下面那一页** ✗，
///   用户实测："界面切换感觉有点重叠" —— 去掉 FadeTransition 后，
///   进 / 出的两层是"推走"关系，不会再叠在一起 ✓
class _CupertinoLikeTransitionsBuilder extends PageTransitionsBuilder {
  const _CupertinoLikeTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 首页不转场（避免冷启动闪现）
    if (route.settings.name == Navigator.defaultRouteName) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    // 本页进场：从右滑入
    final enter = Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(curved);
    // 本页被"压在下面"时（有新页推上来）：向左让开 1/4 屏（iOS 视差）
    final parallax = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final exit = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(-0.25, 0),
    ).animate(parallax);
    return SlideTransition(
      position: exit,
      child: SlideTransition(position: enter, child: child),
    );
  }
}
