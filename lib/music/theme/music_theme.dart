import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/common/theme_mode_store.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';

/// 音乐模块主题体系 —— 移植自 Beans-Music 的 `Theme.swift`。
///
/// 设计要点（照搬 Beans 的克制配色）：
///   · 背景/卡片用很浅的灰（#F2F2F7 / 白）与近黑（#0A0A0C / #1C1C1E）
///   · 文字三档：主 / 次（#6C6C70 ↔ #98989F）/ 强调
///   · 「鼠尾草绿」`sage` 是 Beans 的次要强调色（用于"已下载"等状态）
///   · 9 种强调色方案，每种给一对渐变（播放键/进度条/玻璃光晕用）
///   · 玻璃卡片填充 `glassFill` 是半透明，配合模糊做出"毛玻璃"质感
///
/// 注意：这里的色值**独立于猫影影视侧的 AppTheme**，因为 Beans 的视觉
/// 语言（浅灰底 + 琥珀暖金强调 + 毛玻璃）和影视侧差异很大，混用会两头不像。

/// 强调色方案（Beans 的 `BeansAccent`）
///
/// ⚠️ `ink`（水墨书香）必须排第一：它是**默认**方案，
/// 且用户明确要求音乐模块与阅读的水墨书香风格一致。
/// 其余 8 个是 Beans 原有的可选强调色，**保留不动**（那是功能，不是风格）。
enum MusicAccent {
  /// 水墨书香的强调色：墨灰 → 深墨。
  ///
  /// 注意它**没有配色相**（R≈G≈B）：水墨调里唯一的暖色是赭石，
  /// 而赭石是用在阅读侧的小面积点缀（印章/落款），
  /// 音乐这里大面积用在播放键/进度条上，用墨灰更协调。
  ink('水墨书香', Color(0xFF3A3A3A), Color(0xFF1F1F1F)),
  amber('琥珀暖金', Color(0xFFF2A33C), Color(0xFFC07A0A)),
  mint('青碧湖绿', Color(0xFF6BC79E), Color(0xFF298C6B)),
  pink('莓粉', Color(0xFFF58FB3), Color(0xFFD15E8F)),
  sky('星蓝', Color(0xFF63B5F5), Color(0xFF3B7AD6)),
  violet('罗兰紫', Color(0xFFB39EDB), Color(0xFF7D57C2)),
  cyber('赛博青', Color(0xFF40E6D9), Color(0xFF0D8CA6)),
  peach('蜜桃橘', Color(0xFFFF9E85), Color(0xFFF2618C)),
  gold('鎏金褐', Color(0xFFEBBF59), Color(0xFF73541A)),
  emerald('翡翠绿', Color(0xFF4DD98C), Color(0xFF0D8059));

  const MusicAccent(this.label, this.gradientStart, this.gradientEnd);

  final String label;

  /// 渐变首色（高亮色：光晕 / 进度点 / 歌词高亮）
  final Color gradientStart;

  /// 渐变尾色（播放键渐变终点）
  final Color gradientEnd;

  /// 播放键 / 进度条 / 玻璃光晕用的渐变
  List<Color> get gradientColors => [gradientStart, gradientEnd];

  /// 高亮色 = 渐变首色
  Color get highlight => gradientStart;

  /// 浅色模式下的强调色（压暗一点，白底上才够对比）
  Color get tintLight => gradientEnd;

  /// 深色模式下的强调色（用亮的那端）
  Color get tintDark => gradientStart;

  static MusicAccent fromKey(String? k) => MusicAccent.values.firstWhere(
        (a) => a.name == k,
        // 默认回落到水墨书香（而不是 Beans 的琥珀金）
        orElse: () => MusicAccent.ink,
      );
}

/// 主题模式（Beans 的 `BeansThemeMode`）
enum MusicThemeMode {
  system('跟随系统'),
  light('浅色'),
  dark('深色');

  const MusicThemeMode(this.label);
  final String label;

  static MusicThemeMode fromKey(String? k) => MusicThemeMode.values.firstWhere(
        (m) => m.name == k,
        orElse: () => MusicThemeMode.system,
      );
}

/// 音乐模块的取色入口。
///
/// 全部是静态 getter，跟随 [brightness]（由 `MusicThemeStore` 写入）。
/// 用法与 Beans 的 `Color.beansAmber` 等一一对应。
class MusicTheme {
  MusicTheme._();

  /// 当前生效的调色板（水墨书香 / 或用户在「主题与外观」里给音乐选的方案）。
  ///
  /// 为什么不直接 `JellyPalette.ink()` 写死：
  /// 统一主题设置页允许给音乐单独选一套预设之一，
  /// 那套选择经 `ModuleThemeStore` 落地 —— 这里读的就是那个结果，
  /// 保证悬浮栏、卡片等用的颜色与用户选的方案一致。
  ///
  /// 不 import `ModuleThemeStore` 是为了不让 `lib/music` 反向依赖
  /// `lib/common` 的存储层；用注入的方式（见 `MusicPaletteBridge`）。
  /// 当前生效的调色板。
  ///
  /// `?? const JellyPalette.ink()` 是**兜底**（水墨书香 = 默认主题）。
  /// ⚠️ 兜底本身没问题，危险的是**静默** —— 如果 bridge 没注册，
  /// 用户会一直看到水墨书香却不知道原因。
  /// 所以 `MusicPaletteBridge.current()` 里加了未注册时的显式日志/断言（#13）。
  static JellyPalette get palette =>
      MusicPaletteBridge.current() ?? const JellyPalette.ink();

  /// 当前明暗 —— **直接派生自全局唯一真源 `AppBrightness`**。
  ///
  /// 🔴 原来它是音乐自己记的一个 bool（`static bool _isDark`），由
  /// `MusicThemeStore` 在启动与 `applyFromGlobal` 时写入。那条链路只要
  /// 有一次没跑到（初始化顺序、模块回写的时机、`_syncing` 吞掉推送……），
  /// 音乐就会和全局不同步 —— 用户实测截图：
  /// **全局是浅色（其它 tab 都是浅色、底栏是白的），音乐页却整片深色。**
  ///
  /// 改成派生之后，两者**结构上不可能再不一致**：
  /// `setMode` → `_syncBackToGlobal` → 全局 `ThemeModeStore` →
  /// `AppBrightness` → 这里跟着变；`applyFromGlobal` 同理。
  ///
  /// 用私有 getter 顶替原来的私有字段，是为了让文件内所有 `_isDark`
  /// 读取点自动走新逻辑（一处改动，全文件生效）。
  static bool get _isDark => !AppBrightness.isLight.value;
  static bool get isDark => _isDark;

  /// 当前强调色方案
  // 默认水墨书香（与阅读一致）；其余 8 个仍是用户可选项
  static MusicAccent _accent = MusicAccent.ink;
  static MusicAccent get accent => _accent;

  /// 用户自定义强调色（覆盖 accent；null = 用预设）
  static Color? _customAccent;
  static Color? get customAccent => _customAccent;

  static void setAccent(MusicAccent a) {
    _accent = a;
    _customAccent = null;
  }

  static void setCustomAccent(Color? c) => _customAccent = c;

  /// 整体替换（启动时从存储恢复）。
  ///
  /// ⚠️ 这里**不再有 `dark` 参数**：明暗派生自全局 `AppBrightness`
  ///（见 `_isDark` 的说明），模块自己的存储不再决定明暗。
  static void apply({required MusicAccent accent, Color? custom}) {
    _accent = accent;
    _customAccent = custom;
  }

  // ── 基础色（全部从 JellyPalette 派生，与阅读/影视同一套主题）──────────
  //
  // 以前这里是硬编码的水墨书香色值（只适配了 ink 一套），
  // 现在全部从 palette（JellyPalette）取，换主题时音乐同步变色。
  // API 命名保持不变（background/card/label/secondary/tint...），
  // 避免全项目几百处引用一起改。

  /// 页面背景
  static Color get background =>
      _isDark ? palette.backgroundDark : palette.backgroundLight;

  /// 卡片背景
  static Color get card =>
      _isDark ? palette.cardDark : palette.cardLight;

  /// 主文字
  static Color get label =>
      _isDark ? palette.textPrimaryDark : palette.textPrimaryLight;

  /// 次要文字
  ///
  /// ⚠️ 浓度必须与全局 `AppTheme.textSecondary` 同向：全局是
  /// "浅色更实(0.92) / 深色改用白色 72%"（调色板中灰在墨夜底上只有
  /// ~3.3:1，夜间发灰伤眼 —— 用户 2026-10-20 反馈）。
  static Color get secondary => _isDark
      ? const Color(0xB8FFFFFF) // white 72%
      : palette.textSecondary.withValues(alpha: 0.92);

  /// 鼠尾草绿（Beans 的次要强调，用于"已下载/已完成"等状态）
  ///
  /// 统一主题后用 palette.success（成功色）替代，
  /// 保持"绿色 = 完成/下载"的语义关联。
  static Color get sage => palette.success;

  /// 玻璃卡片填充（半透明，配合 BackdropFilter 做毛玻璃）
  static Color get glassFill =>
      (_isDark ? palette.cardDark : palette.cardLight)
          .withValues(alpha: _isDark ? 0.60 : 0.70);

  /// 强调色。
  ///
  /// ⚠️ 两个坑：
  ///  1. `_customAccent` 由 `MusicThemeBridge` 注入的是 **palette.primary**
  ///     ——"浅色底上用的那一端"。深色模式直接拿它画播放键/进度条会与卡片
  ///     几乎同色（ink：tint=#3A3A3A、card=#2A2A2C，对比≈1.1:1），
  ///     按钮和进度条基本"消失"。所以深色模式要取亮端 `primaryLight`
  ///     （`MusicAccent.tintDark => gradientStart` 早就是这个约定）。
  ///  2. 浅色模式原写法是 `_shade(c, +0.15)`（**变亮**），与上方注释
  ///     "压暗一点，白底上才够对比"正好相反。
  ///  3. 深色下只换"亮端"还不够：墨灰主题的亮端 `primaryLight` 是
  ///     `#6E6E73`，压在卡片 `#2A2A2C` 上只有 **2.82:1**，皇家紫 `#9A3D8F`
  ///     更低到 **2.68:1** ⇒ 选中歌名/当前页签/进度点全是"灰糊糊一片"。
  ///     这两个恰好一个是**默认主题**、一个是新增鲜艳主题，必须兜底：
  ///     用 [_ensureContrast] 逐步推到看得清为止。
  ///
  /// ⚠️ 因为要兜底，[tint] 在深色下可能被提亮到浅色 —— 它**只能当文字/图标/
  /// 描边用**；要"实底 + 白字"的按钮请用 [accentFill]。
  static Color get tint {
    if (_isDark) {
      // 深色：强调色当"图标/选中态"用，3.0 是小面积点缀的下限
      return _ensureContrast(palette.primaryLight, palette.cardDark, 3.0,
          towardWhite: true);
    }
    final c = _customAccent;
    final base = c == null ? palette.primaryDark : _shade(c, -0.15);
    // 浅色：同一个颜色大量被当**正文色**用（选中歌名 / 重试 / 榜单名次），
    // 所以按 AA 的 4.5 兜底（沙丘褐 3.70、星蓝 4.19、莓粉 4.48 会被压深一档）
    return _ensureContrast(base, palette.cardLight, 4.5, towardWhite: false);
  }

  /// 「实底 + 白字」按钮的填充色。
  ///
  /// 与 [tint] 分开的原因：tint 为了可读性会被提亮（墨灰 → ≈#B6B6B9），
  /// 白字压上去只剩 1.9:1；这个 getter 保持"较深的一端"，保证白字可读。
  static Color get accentFill {
    if (_isDark) return palette.primaryLight;
    return _shade(_customAccent ?? palette.primary, -0.15);
  }

  /// [accentFill] 上应该用的前景色。
  ///
  /// 不能一律 `Colors.white`：鲜艳主题的亮端（果冻紫 `#9AA0DC`、柠檬黄
  /// `#FACA2E`）亮度很高，白字只有 2.4:1 —— 按钮上的"保存/安装"会糊掉。
  ///
  /// 取**纯黑**而不是"近黑"是算出来的：白/黑对比度的交叉点在亮度 0.179，
  /// 此处两端都能给到 4.58:1；若用 `#17171A`（亮度 0.0087），交叉点挪到
  /// 0.198，最差只剩 4.2:1，莓粉浅色下会掉到 **3.99** —— 就是"看着能看、
  /// 实际不达标"。所以这里用纯黑，换 0.5 的观感差异换稳过 AA。
  static Color get onAccentFill =>
      accentFill.computeLuminance() > 0.179 ? Colors.black : Colors.white;

  /// 把 [c] 朝白/黑推，直到在 [bg] 上达到 [target] 对比度为止。
  ///
  /// 为什么是"逐步推"而不是一次 `lerp(...,0.55)`：一次大幅提亮/压暗会把
  /// 主题色改得面目全非（皇家紫变成淡粉、沙丘褐变成咖啡）。这里每步 12%，
  /// 够用就停 —— 实测只有 3 套浅色 / 2 套深色需要挪动，且只挪 1~3 步。
  static Color _ensureContrast(
    Color c,
    Color bg,
    double target, {
    required bool towardWhite,
  }) {
    var out = c;
    for (var i = 0; i < 8; i++) {
      final la = out.computeLuminance();
      final lb = bg.computeLuminance();
      final hi = la > lb ? la : lb;
      final lo = la > lb ? lb : la;
      if ((hi + 0.05) / (lo + 0.05) >= target) return out;
      out = Color.lerp(out, towardWhite ? Colors.white : Colors.black, 0.12)!;
    }
    return out;
  }

  /// 高亮色（亮的那端，深色模式下更醒目）
  static Color get highlight => _isDark
      ? palette.primaryLight
      : _shade(_customAccent ?? palette.primary, -0.05);

  /// 当前强调色的渐变（从浅到深，用于播放键/进度条/光晕）
  static List<Color> get accentGradient {
    final c = _customAccent;
    if (c == null) return [palette.primaryLight, palette.primaryDark];
    return _isDark
        ? [palette.primaryLight, palette.primary]
        : [_shade(c, -0.24), _shade(c, -0.04)];
  }

  /// 分隔线
  static Color get divider =>
      palette.primary.withValues(alpha: _isDark ? 0.12 : 0.10);

  /// 轻微填充（列表选中态/输入框底）
  static Color get fill =>
      palette.primary.withValues(alpha: _isDark ? 0.08 : 0.06);

  /// 把颜色按 [amount] 变亮(正)/变暗(负)
  static Color _shade(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    final l = (hsl.lightness + amount).clamp(0.0, 1.0);
    return hsl.withLightness(l).toColor();
  }

  /// 给页面套上音乐模块的 ThemeData（局部生效，不影响影视侧）
  static ThemeData themeData() {
    final dark = _isDark;
    return ThemeData(
      brightness: dark ? Brightness.dark : Brightness.light,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      cardColor: card,
      dividerColor: divider,
      colorScheme: ColorScheme.fromSeed(
        seedColor: tint,
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
      splashFactory: InkSparkle.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      }),

      // ── 统一所有音乐子页的顶栏（2026-10-30）────────────────────
      //
      // 用户：「音乐按你设计的 UI 界面，优化美化每一个分类界面吧，
      // 还有其余页面。」
      //
      // 之前这里**只配了底色**，没配 `appBarTheme` —— 于是本地音乐 /
      // 我的歌单 / 歌单详情 / 源管理 / 插件市场 / 各平台专辑页全都用
      // Material 默认顶栏：20 号 Roboto、默认灰底、滚动时还会变一层色。
      // 摆在手绘的圆角卡片旁边，一眼就能看出"这是系统列表，不是这个 App"。
      //
      // 现在统一成：卡片底色 + 18 号粗标题 + 左对齐 + 无阴影 + 滚动不变色。
      // 改这一处，十几个子页一起对齐，比逐页改 AppBar 稳。
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: label,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        titleTextStyle: TextStyle(
          color: label,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
        ),
        iconTheme: IconThemeData(color: label, size: 22),
        actionsIconTheme: IconThemeData(color: label, size: 22),
      ),

      // 列表项：图标走强调色，标题走正文色，副标题走次级色。
      // 音乐模块里还有不少 ListTile（歌单选择、源列表），
      // 不配的话它们会用默认的蓝/灰。
      listTileTheme: ListTileThemeData(
        iconColor: tint,
        textColor: label,
        titleTextStyle: TextStyle(
          color: label,
          fontSize: AppTheme.fontHeadline,
          fontWeight: FontWeight.w500,
        ),
        subtitleTextStyle: TextStyle(
          color: secondary,
          fontSize: AppTheme.fontFootnote,
        ),
      ),

      // 分隔线统一 0.5px：音乐模块的卡片都是圆角的，
      // 1px 的实线在中间显得很硬。
      dividerTheme: DividerThemeData(
        color: divider,
        thickness: 0.5,
        space: 0.5,
      ),

      iconTheme: IconThemeData(color: label, size: 22),

      // 弹层（底部 sheet）统一卡片底 + 顶部圆角
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),

      // SnackBar 别用 Material 默认的深灰 —— 音乐模块的 toast 走 AppToast，
      // 这里只是兜底，保持配色一致。
      snackBarTheme: SnackBarThemeData(
        backgroundColor: card,
        contentTextStyle: TextStyle(color: label, fontSize: AppTheme.fontBody),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// 主题存储（Beans 的 `ThemeStore` 的核心部分）。
///
/// 只保留外观相关：模式 / 强调色 / 自定义色。
/// 原版 ThemeStore 有 400+ 行（含壁纸、播放器皮肤、按钮风格等），
/// 那些在下面的 `MusicPlayerSkin` 里单独存。
class MusicThemeStore {
  MusicThemeStore._();
  static final MusicThemeStore instance = MusicThemeStore._();

  static const _kMode = 'music.themeMode';
  static const _kAccent = 'music.accent';
  static const _kCustom = 'music.customAccent';

  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 由统一主题系统（ModuleThemeStore）调用：配色方案变化时，
  /// 通知音乐侧 UI 重建（因为 MusicTheme.palette 是静态 getter，
  /// 没人触发 rebuild 的话界面不会变）。
  void notifyPaletteChanged() {
    revision.value++;
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final accent = MusicAccent.fromKey(prefs.getString(_kAccent));
    final customRaw = prefs.getInt(_kCustom);
    // 明暗**不在这里恢复**：它派生自全局 `AppBrightness`（见 `MusicTheme._isDark`）。
    // `music.themeMode` 仍然继续写（记录用户上次的选择），但不再决定渲染 ——
    // 这正是"全局唯一真源"该有的样子。
    MusicTheme.apply(
      accent: accent,
      custom: customRaw == null ? null : Color(customRaw),
    );
    revision.value++;
  }

  Future<void> setMode(MusicThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, mode.name);
    // 不再 `MusicTheme.setDark(...)`：明暗派生自全局 `AppBrightness`。
    // 本方法只负责"记录选择 + 回写全局"；全局一变，明暗自动跟着变。
    revision.value++;
    // 同步回全局主题存储，保持三模块一致。
    //
    // ⚠️ 原来包在 `addPostFrameCallback` 里 —— 那个回调**只在有帧要绘制时
    // 才会执行**，用户改完设置马上退出页面时，回写可能始终不执行，
    // 于是"全局还是旧值"。而现在的模型是**全局唯一真源**，
    // 不回写 = 用户的选择丢失。直接调用即可（`notifyModuleChanged`
    // 内部有 `_syncing` 防递归，且不直接触碰 build）。
    _syncBackToGlobal(mode);
  }

  /// 从全局主题存储推过来（统一主题设置页改了明暗时调用）
  ///
  /// 不走 [setMode] 避免递归：setMode → _syncBackToGlobal → 全局 set → 再推回来
  Future<void> applyFromGlobal(ThemeMode mode) async {
    final m = switch (mode) {
      ThemeMode.light => MusicThemeMode.light,
      ThemeMode.dark => MusicThemeMode.dark,
      ThemeMode.system => MusicThemeMode.system,
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, m.name);
    // 明暗派生自 `AppBrightness`，无需在此写入；`revision` 负责触发 UI 重建。
    revision.value++;
  }

  /// 把音乐的模式转成全局 ThemeMode 并回写
  void _syncBackToGlobal(MusicThemeMode mode) {
    final global = switch (mode) {
      MusicThemeMode.light => ThemeMode.light,
      MusicThemeMode.dark => ThemeMode.dark,
      MusicThemeMode.system => ThemeMode.system,
    };
    // 带上来源：只跳过音乐自己，**仍要推给阅读**。
    // （原来 `notifyModuleChanged` 内部会置 `_syncing`，把发给所有模块的
    //   推送一起吞掉 —— 音乐改明暗时阅读不跟着变。）
    ThemeModeStore.notifyModuleChanged(global, origin: GlobalThemeSync.music);
  }

  Future<void> setAccent(MusicAccent accent) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAccent, accent.name);
    await prefs.remove(_kCustom);
    MusicTheme.setAccent(accent);
    revision.value++;
  }

  Future<void> setCustomAccent(Color? c) async {
    final prefs = await SharedPreferences.getInstance();
    if (c == null) {
      await prefs.remove(_kCustom);
    } else {
      await prefs.setInt(_kCustom, c.toARGB32());
    }
    MusicTheme.setCustomAccent(c);
    revision.value++;
  }

  MusicThemeMode get currentMode {
    // 没有显式记录时按明暗推断，够用且不必再读盘
    return MusicTheme.isDark ? MusicThemeMode.dark : MusicThemeMode.light;
  }
}

/// 播放器皮肤选项（Beans 的 `BeansCoverPlayerStyle` / `BeansPlayerDustMode`）
enum MusicCoverStyle {
  vinyl('黑胶唱片'),
  cd('CD 圆盘'),
  square('方形封面'),
  blur('模糊大图');

  const MusicCoverStyle(this.label);
  final String label;
}

enum MusicDustMode {
  none('无'),
  dust('浮尘'),
  stars('星点');

  const MusicDustMode(this.label);
  final String label;
}

/// 播放器外观存储
class MusicPlayerSkin {
  MusicPlayerSkin._();
  static final MusicPlayerSkin instance = MusicPlayerSkin._();

  static const _kCover = 'music.coverStyle';
  static const _kDust = 'music.dustMode';
  static const _kShowLyricFirst = 'music.showLyricFirst';

  final coverStyle = ValueNotifier<MusicCoverStyle>(MusicCoverStyle.vinyl);
  final dustMode = ValueNotifier<MusicDustMode>(MusicDustMode.dust);

  /// 进播放器是否默认显示歌词
  final showLyricFirst = ValueNotifier<bool>(false);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    coverStyle.value = MusicCoverStyle.values.firstWhere(
      (e) => e.name == prefs.getString(_kCover),
      orElse: () => MusicCoverStyle.vinyl,
    );
    dustMode.value = MusicDustMode.values.firstWhere(
      (e) => e.name == prefs.getString(_kDust),
      orElse: () => MusicDustMode.dust,
    );
    showLyricFirst.value = prefs.getBool(_kShowLyricFirst) ?? false;
  }

  Future<void> setCoverStyle(MusicCoverStyle v) async {
    coverStyle.value = v;
    (await SharedPreferences.getInstance()).setString(_kCover, v.name);
  }

  Future<void> setDustMode(MusicDustMode v) async {
    dustMode.value = v;
    (await SharedPreferences.getInstance()).setString(_kDust, v.name);
  }

  Future<void> setShowLyricFirst(bool v) async {
    showLyricFirst.value = v;
    (await SharedPreferences.getInstance()).setBool(_kShowLyricFirst, v);
  }
}

/// 音乐调色板的注入桥。
///
/// `lib/common` 是影视侧底层，不该被 `lib/music` 反向依赖；
/// 而音乐又需要知道"用户在统一主题页给音乐选了哪套预设"。
/// 用一个注入回调解决：`main.dart` 启动时把读取实现注册进来。
class MusicPaletteBridge {
  MusicPaletteBridge._();

  static JellyPalette? Function()? _get;

  /// 是否已被注册（#13：用来把"没注册"和"注册了但当前没值"区分开）
  static bool get isRegistered => _get != null;

  static void register(JellyPalette? Function() fn) {
    _get = fn;
    _warned = false; // 重新注册后允许再报一次
  }

  /// 只在首次发现"没注册"时打一条日志，避免每帧刷屏
  static bool _warned = false;

  static JellyPalette? current() {
    final fn = _get;
    if (fn == null) {
      // #13：**没注册**是最危险的情况 —— 说明 main.dart 的启动顺序被改坏了，
      // 此时 `MusicTheme.palette` 会**静默**退回水墨书香，
      // 界面上完全看不出异常，用户只会觉得"我选的主题坏了"。
      // 这里至少留一条明确日志（只在第一次打，避免每帧刷屏）。
      if (!_warned) {
        _warned = true;
        assert(false,
            'MusicPaletteBridge 未注册！音乐主题会静默退回水墨书香。'
            '请检查 main.dart 启动顺序里 MusicPaletteBridge.register 是否被删或被提前。');
        // ignore: avoid_print
        print('[Music] ⚠️ MusicPaletteBridge 未注册 —— '
            '音乐配色会退回水墨书香（检查 main.dart 启动顺序）');
      }
      return null;
    }
    return fn();
  }
}
