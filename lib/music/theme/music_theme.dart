import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
enum MusicAccent {
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
        orElse: () => MusicAccent.amber,
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

  /// 当前明暗。由 MusicThemeStore 在启动/切换时写入。
  static bool _isDark = false;
  static bool get isDark => _isDark;
  static void setDark(bool v) => _isDark = v;

  /// 当前强调色方案
  static MusicAccent _accent = MusicAccent.amber;
  static MusicAccent get accent => _accent;

  /// 用户自定义强调色（覆盖 accent；null = 用预设）
  static Color? _customAccent;
  static Color? get customAccent => _customAccent;

  static void setAccent(MusicAccent a) {
    _accent = a;
    _customAccent = null;
  }

  static void setCustomAccent(Color? c) => _customAccent = c;

  /// 整体替换（启动时从存储恢复）
  static void apply({required bool dark, required MusicAccent accent, Color? custom}) {
    _isDark = dark;
    _accent = accent;
    _customAccent = custom;
  }

  // ── 基础色（对应 Beans 的 beansBackground / beansCard / ...）──────────

  /// 页面背景
  static Color get background =>
      _isDark ? const Color(0xFF0A0A0C) : const Color(0xFFF2F2F7);

  /// 卡片背景
  static Color get card =>
      _isDark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF);

  /// 主文字
  static Color get label => _isDark ? Colors.white : Colors.black;

  /// 次要文字
  static Color get secondary =>
      _isDark ? const Color(0xFF98989F) : const Color(0xFF6C6C70);

  /// 鼠尾草绿（Beans 的次要强调，用于"已下载/已完成"等状态）
  static Color get sage =>
      _isDark ? const Color(0xFF8FA67A) : const Color(0xFF627B4F);

  /// 玻璃卡片填充（半透明，配合 BackdropFilter 做毛玻璃）
  static Color get glassFill =>
      _isDark ? const Color(0x0FFFFFFF).withValues(alpha: 0.07) : Colors.white.withValues(alpha: 0.55);

  /// 强调色（用户自定义优先）
  static Color get tint {
    final c = _customAccent;
    if (c != null) return _isDark ? c : _shade(c, 0.25);
    return _isDark ? _accent.tintDark : _accent.tintLight;
  }

  /// 高亮色（亮的那端，深色模式下更醒目）
  static Color get highlight => _customAccent ?? _accent.highlight;

  /// 当前强调色的渐变
  static List<Color> get accentGradient => _customAccent != null
      ? [_shade(_customAccent!, -0.1), _shade(_customAccent!, 0.15)]
      : _accent.gradientColors;

  /// 分隔线
  static Color get divider =>
      _isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.06);

  /// 轻微填充（列表选中态/输入框底）
  static Color get fill =>
      _isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.04);

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

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = MusicThemeMode.fromKey(prefs.getString(_kMode));
    final accent = MusicAccent.fromKey(prefs.getString(_kAccent));
    final customRaw = prefs.getInt(_kCustom);
    MusicTheme.apply(
      dark: _resolveDark(mode),
      accent: accent,
      custom: customRaw == null ? null : Color(customRaw),
    );
    revision.value++;
  }

  bool _resolveDark(MusicThemeMode mode) => switch (mode) {
        MusicThemeMode.system =>
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark,
        MusicThemeMode.light => false,
        MusicThemeMode.dark => true,
      };

  Future<void> setMode(MusicThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, mode.name);
    MusicTheme.setDark(_resolveDark(mode));
    revision.value++;
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
