import 'package:flutter/material.dart';

/// 主题调色板：持有一套主题的全部颜色（含 light + dark 两套色）。
///
/// 不可变（const 构造），新增主题只加一个命名构造；未来「用户自定义」可基于
/// 某预设 copyWith 覆盖个别字段，无需改架构。颜色经 [JellyTheme] 的同名 getter
/// 暴露给全项目（`JellyTheme.primary` -> `_palette.primary`），切换主题即换 _palette。
class JellyPalette {
  const JellyPalette({
    required this.primary,
    required this.primaryLight,
    required this.primaryDark,
    required this.accent,
    required this.success,
    required this.warning,
    required this.error,
    required this.blue,
    required this.backgroundLight,
    required this.backgroundDark,
    required this.cardLight,
    required this.cardDark,
    required this.navSelectedBg,
    required this.navSelectedFg,
    required this.navUnselected,
    required this.textPrimaryLight,
    required this.textPrimaryDark,
    required this.textSecondary,
  });

  /// 果冻紫蓝（默认，搬自原 JellyTheme 常量）
  const JellyPalette.jelly()
    : primary = const Color(0xFF7379C4),
      primaryLight = const Color(0xFF9AA0DC),
      primaryDark = const Color(0xFF555A93),
      accent = const Color(0xFFFFB4A2),
      success = const Color(0xFF7FDB9F),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFFF8B94),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFEDF3FB),
      backgroundDark = const Color(0xFF1A1A2E),
      cardLight = Colors.white,
      cardDark = const Color(0xFF252542),
      navSelectedBg = const Color(0xFFD0CCFF),
      navSelectedFg = const Color(0xFF443EB1),
      navUnselected = const Color(0xFF23232C),
      textPrimaryLight = const Color(0xFF2D3142),
      textPrimaryDark = Colors.white,
      textSecondary = const Color(0xFF9CA3AF);

  /// 粉色可爱少女风：灰玫瑰粉低饱和主色 + 柔粉米白背景，配柔淡紫强调；
  /// dark 取深褐底，文字用带粉调 off-white 降低对比眩光。
  const JellyPalette.pink()
    : primary = const Color(0xFFD48AA2),
      primaryLight = const Color(0xFFE8AFC0),
      primaryDark = const Color(0xFFA55F76),
      accent = const Color(0xFFB89EC9),
      success = const Color(0xFF7FDB9F),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFFF6B81),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFF8F2F4),
      backgroundDark = const Color(0xFF251E23),
      cardLight = Colors.white,
      cardDark = const Color(0xFF332A2F),
      navSelectedBg = const Color(0xFFE6CBD3),
      navSelectedFg = const Color(0xFFA66077),
      navUnselected = const Color(0xFF2D2329),
      textPrimaryLight = const Color(0xFF3D2B32),
      textPrimaryDark = const Color(0xFFF2E8EA),
      textSecondary = const Color(0xFFA0929A);

  /// 淡绿清新自然风：鼠尾草绿低饱和主色 + 浅绿米白背景，配柔米橙强调；
  /// dark 取深林底，文字用带绿调 off-white 降低对比眩光。
  const JellyPalette.green()
    : primary = const Color(0xFF7BA687),
      primaryLight = const Color(0xFFA3C5AF),
      primaryDark = const Color(0xFF547A66),
      accent = const Color(0xFFD4A574),
      success = const Color(0xFF66BB6A),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFEF5350),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFF3F6EF),
      backgroundDark = const Color(0xFF1E2620),
      cardLight = Colors.white,
      cardDark = const Color(0xFF283029),
      navSelectedBg = const Color(0xFFCFE0CE),
      navSelectedFg = const Color(0xFF3D6B45),
      navUnselected = const Color(0xFF232A25),
      textPrimaryLight = const Color(0xFF2A3B2F),
      textPrimaryDark = const Color(0xFFEAF0EA),
      textSecondary = const Color(0xFF8E9C90);

  /// 蓝色海洋风：灰青蓝低饱和主色 + 浅蓝灰背景，配暖沙强调；
  /// dark 取深海底，文字用带蓝调 off-white 降低对比眩光。
  const JellyPalette.ocean()
    : primary = const Color(0xFF4A8AA0),
      primaryLight = const Color(0xFF7AAFC2),
      primaryDark = const Color(0xFF355F73),
      accent = const Color(0xFFD4A574),
      success = const Color(0xFF66BB6A),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFEF5350),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFEFF4F8),
      backgroundDark = const Color(0xFF1A2228),
      cardLight = Colors.white,
      cardDark = const Color(0xFF243038),
      navSelectedBg = const Color(0xFFCADCE6),
      navSelectedFg = const Color(0xFF355F73),
      navUnselected = const Color(0xFF232A2E),
      textPrimaryLight = const Color(0xFF2A333A),
      textPrimaryDark = const Color(0xFFEAF0F2),
      textSecondary = const Color(0xFF8A9CA6);

  /// 落日余晖风：赤陶橙低饱和主色 + 暖米白背景，配晚霞紫粉强调；
  /// dark 取深暖褐底，文字用带暖调 off-white 降低对比眩光。
  const JellyPalette.sunset()
    : primary = const Color(0xFFC17A5A),
      primaryLight = const Color(0xFFDAA582),
      primaryDark = const Color(0xFF9A5A3E),
      accent = const Color(0xFFB088A6),
      success = const Color(0xFF66BB6A),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFEF5350),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFFBF4EE),
      backgroundDark = const Color(0xFF26201E),
      cardLight = Colors.white,
      cardDark = const Color(0xFF332B27),
      navSelectedBg = const Color(0xFFE8CFBC),
      navSelectedFg = const Color(0xFF9A5A3E),
      navUnselected = const Color(0xFF2A2422),
      textPrimaryLight = const Color(0xFF3A2E28),
      textPrimaryDark = const Color(0xFFF2EAE4),
      textSecondary = const Color(0xFF9C8A82);

  /// 蓝色天空风：明亮天蓝低饱和主色 + 清新浅蓝背景，配日光黄强调；
  /// dark 取深夜空底，文字用带蓝调 off-white 降低对比眩光。
  const JellyPalette.sky()
    : primary = const Color(0xFF5FA6D6),
      primaryLight = const Color(0xFF97CBE6),
      primaryDark = const Color(0xFF42789C),
      accent = const Color(0xFFE6C267),
      success = const Color(0xFF66BB6A),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFEF5350),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFEFF6FB),
      backgroundDark = const Color(0xFF1A2229),
      cardLight = Colors.white,
      cardDark = const Color(0xFF243039),
      navSelectedBg = const Color(0xFFCFE3F0),
      navSelectedFg = const Color(0xFF4A7C9E),
      navUnselected = const Color(0xFF232A30),
      textPrimaryLight = const Color(0xFF2A333D),
      textPrimaryDark = const Color(0xFFEAF1F5),
      textSecondary = const Color(0xFF8A9CA8);

  /// 水墨书香（默认主题）—— 黑白灰的水墨调，**无彩色倾向**。
  ///
  /// ── 为什么是这套值（"水墨 + 书香"两个意象）────────────────────
  /// 用户在主题风格里选中的就是这一项（色块为「墨 / 灰 / 白」三色），
  /// 所以配色要同时满足两个意象：
  ///   · **书香** → 浅色底用暖米白（#F7F5F1），是"宣纸/旧书页"的观感。
  ///     不能用纯白：纯白是屏幕色，不是纸色，而且 OLED 上刺眼
  ///   · **水墨** → 主色用墨灰（#3A3A3A）。不能用纯黑：
  ///     纯黑作主色/图标色太硬，而且与正文文字同色会失去层次
  ///   · 深色模式取墨夜深灰（#1C1C1E），不是纯黑 —— 纯黑配白字对比过强，
  ///     长时间阅读疲劳（iOS 系统深色也这么做）
  ///
  /// 强调色用**低饱和赭石**（#B08D57）：水墨画里唯一的暖色是印章与落款，
  /// 所以整体无彩色，只留这一处暖色做点缀。
  const JellyPalette.ink()
    : primary = const Color(0xFF3A3A3A),
      primaryLight = const Color(0xFF6E6E73),
      primaryDark = const Color(0xFF1F1F1F),
      accent = const Color(0xFFB08D57),
      success = const Color(0xFF6B9E78),
      warning = const Color(0xFFD4A853),
      error = const Color(0xFFC25B5B),
      blue = const Color(0xFF5A7D9A),
      backgroundLight = const Color(0xFFF7F5F1),
      backgroundDark = const Color(0xFF1C1C1E),
      cardLight = Colors.white,
      cardDark = const Color(0xFF2A2A2C),
      navSelectedBg = const Color(0xFFE6E3DD),
      navSelectedFg = const Color(0xFF3A3A3A),
      navUnselected = const Color(0xFF232325),
      textPrimaryLight = const Color(0xFF1F1F1F),
      textPrimaryDark = const Color(0xFFEDEDED),
      textSecondary = const Color(0xFF8E8E93);

  /// 森野青岚：深青绿 + 雾灰绿底，配暖木强调（护眼、偏自然）。
  const JellyPalette.forest()
    : primary = const Color(0xFF4E7C6A),
      primaryLight = const Color(0xFF7FA995),
      primaryDark = const Color(0xFF35594C),
      accent = const Color(0xFFD9A66A),
      success = const Color(0xFF66BB6A),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFEF5350),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFF1F5F1),
      backgroundDark = const Color(0xFF182420),
      cardLight = Colors.white,
      cardDark = const Color(0xFF22322C),
      navSelectedBg = const Color(0xFFCFE0D7),
      navSelectedFg = const Color(0xFF35594C),
      navUnselected = const Color(0xFF1E2A25),
      textPrimaryLight = const Color(0xFF24362F),
      textPrimaryDark = const Color(0xFFE8F0EB),
      textSecondary = const Color(0xFF8A9C93);

  /// 薰衣草梦：柔雾紫 + 粉调强调，安静柔和。
  const JellyPalette.lavender()
    : primary = const Color(0xFF8A7BB8),
      primaryLight = const Color(0xFFB0A3D6),
      primaryDark = const Color(0xFF665791),
      accent = const Color(0xFFE8B4C8),
      success = const Color(0xFF66BB6A),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFEF5350),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFF5F2FA),
      backgroundDark = const Color(0xFF1F1B2B),
      cardLight = Colors.white,
      cardDark = const Color(0xFF2B263B),
      navSelectedBg = const Color(0xFFDDD5F0),
      navSelectedFg = const Color(0xFF665791),
      navUnselected = const Color(0xFF262235),
      textPrimaryLight = const Color(0xFF2E2740),
      textPrimaryDark = const Color(0xFFEFEAF7),
      textSecondary = const Color(0xFF9A93AA);

  /// 暖棕咖啡：焦糖棕 + 奶油米白，配金色点缀。
  const JellyPalette.coffee()
    : primary = const Color(0xFF8C6A52),
      primaryLight = const Color(0xFFB8937A),
      primaryDark = const Color(0xFF6A4C39),
      accent = const Color(0xFFC9A227),
      success = const Color(0xFF66BB6A),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFEF5350),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFFAF5EF),
      backgroundDark = const Color(0xFF241D18),
      cardLight = Colors.white,
      cardDark = const Color(0xFF33291F),
      navSelectedBg = const Color(0xFFE6D6C6),
      navSelectedFg = const Color(0xFF6A4C39),
      navUnselected = const Color(0xFF2A221C),
      textPrimaryLight = const Color(0xFF3A2C22),
      textPrimaryDark = const Color(0xFFF3EAE1),
      textSecondary = const Color(0xFFA08F82);

  /// 沙丘暖阳：燕麦沙色 + 雾蓝强调，低饱和暖调。
  const JellyPalette.sand()
    : primary = const Color(0xFFC9A55F),
      primaryLight = const Color(0xFFE0C68F),
      primaryDark = const Color(0xFF9C7C42),
      accent = const Color(0xFF7FA8B8),
      success = const Color(0xFF66BB6A),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFEF5350),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFFBF7EC),
      backgroundDark = const Color(0xFF26221A),
      cardLight = Colors.white,
      cardDark = const Color(0xFF353026),
      navSelectedBg = const Color(0xFFEADFC5),
      navSelectedFg = const Color(0xFF99804F),
      navUnselected = const Color(0xFF2D2820),
      textPrimaryLight = const Color(0xFF3A3225),
      textPrimaryDark = const Color(0xFFF4EFE3),
      textSecondary = const Color(0xFFA69A85);

  /// 中秋月圆：金桂 + 月白蓝，浅色是暖米白（月饼／月光），深色取夜空墨蓝。
  const JellyPalette.midAutumn()
    : primary = const Color(0xFFC49A3F),
      primaryLight = const Color(0xFFE0BF74),
      primaryDark = const Color(0xFF9A7429),
      accent = const Color(0xFF7C9FCB),
      success = const Color(0xFF7FBF8F),
      warning = const Color(0xFFE8B44A),
      error = const Color(0xFFD9604F),
      blue = const Color(0xFF5B84B1),
      backgroundLight = const Color(0xFFFBF6E9),
      backgroundDark = const Color(0xFF1B1E2A),
      cardLight = Colors.white,
      cardDark = const Color(0xFF272B39),
      navSelectedBg = const Color(0xFFEFE3C4),
      navSelectedFg = const Color(0xFF8A6820),
      navUnselected = const Color(0xFF2A2A2E),
      textPrimaryLight = const Color(0xFF3A3223),
      textPrimaryDark = const Color(0xFFF4EEDF),
      textSecondary = const Color(0xFFA3936F);

  /// 新春纳福：正红 + 鎏金，浅色暖纸底，深色取枣红夜色。
  const JellyPalette.springFestival()
    : primary = const Color(0xFFBE2F2A),
      primaryLight = const Color(0xFFD95C54),
      primaryDark = const Color(0xFF8E211D),
      accent = const Color(0xFFD9AE3C),
      success = const Color(0xFF6FAF7C),
      warning = const Color(0xFFE8B44A),
      error = const Color(0xFFD94040),
      blue = const Color(0xFF4E7FB5),
      backgroundLight = const Color(0xFFFDF5F1),
      backgroundDark = const Color(0xFF231415),
      cardLight = Colors.white,
      cardDark = const Color(0xFF32201F),
      navSelectedBg = const Color(0xFFF3D9D2),
      navSelectedFg = const Color(0xFF8E211D),
      navUnselected = const Color(0xFF2A1E1E),
      textPrimaryLight = const Color(0xFF3C2320),
      textPrimaryDark = const Color(0xFFF7E9E4),
      textSecondary = const Color(0xFFB08A82);

  /// 元旦新岁：子夜蓝 + 烟花金，浅色清透，深色取跨年夜空。
  const JellyPalette.newYear()
    : primary = const Color(0xFF3F6FB5),
      primaryLight = const Color(0xFF6E9BD8),
      primaryDark = const Color(0xFF2B4F87),
      accent = const Color(0xFFE0B454),
      success = const Color(0xFF66BB6A),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFEF5350),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFF2F5FB),
      backgroundDark = const Color(0xFF141B28),
      cardLight = Colors.white,
      cardDark = const Color(0xFF1F2838),
      navSelectedBg = const Color(0xFFD3E0F4),
      navSelectedFg = const Color(0xFF2B4F87),
      navUnselected = const Color(0xFF222A36),
      textPrimaryLight = const Color(0xFF26313F),
      textPrimaryDark = const Color(0xFFE9EFF9),
      textSecondary = const Color(0xFF8A99AD);

  /// 圣诞雪夜：松针绿 + 圣诞红，浅色带雪雾感，深色取松林夜。
  const JellyPalette.christmas()
    : primary = const Color(0xFF2F7D5A),
      primaryLight = const Color(0xFF5AA37F),
      primaryDark = const Color(0xFF1F5C40),
      accent = const Color(0xFFC0392B),
      success = const Color(0xFF66BB6A),
      warning = const Color(0xFFE8C15A),
      error = const Color(0xFFD64545),
      blue = const Color(0xFF4E88B8),
      backgroundLight = const Color(0xFFF3F8F4),
      backgroundDark = const Color(0xFF101E18),
      cardLight = Colors.white,
      cardDark = const Color(0xFF1A2B23),
      navSelectedBg = const Color(0xFFD2E8DB),
      navSelectedFg = const Color(0xFF1F5C40),
      navUnselected = const Color(0xFF1E2A24),
      textPrimaryLight = const Color(0xFF23352C),
      textPrimaryDark = const Color(0xFFE8F2EC),
      textSecondary = const Color(0xFF86A294);

  /// 国庆华诞：朱红 + 鎏金，浅色暖金纸底，深色取深枣红。
  const JellyPalette.nationalDay()
    : primary = const Color(0xFFC0432F),
      primaryLight = const Color(0xFFDC6E57),
      primaryDark = const Color(0xFF92301F),
      accent = const Color(0xFFD9B44A),
      success = const Color(0xFF6FAF7C),
      warning = const Color(0xFFE8B44A),
      error = const Color(0xFFD94040),
      blue = const Color(0xFF4E7FB5),
      backgroundLight = const Color(0xFFFBF4EA),
      backgroundDark = const Color(0xFF231816),
      cardLight = Colors.white,
      cardDark = const Color(0xFF322420),
      navSelectedBg = const Color(0xFFF2DFC8),
      navSelectedFg = const Color(0xFF92301F),
      navUnselected = const Color(0xFF2A211D),
      textPrimaryLight = const Color(0xFF3A2921),
      textPrimaryDark = const Color(0xFFF7ECE3),
      textSecondary = const Color(0xFFAE9480);

  final Color primary;
  final Color primaryLight;
  final Color primaryDark;
  final Color accent;
  final Color success;
  final Color warning;
  final Color error;
  final Color blue;
  final Color backgroundLight;
  final Color backgroundDark;
  final Color cardLight;
  final Color cardDark;
  final Color navSelectedBg;
  final Color navSelectedFg;
  final Color navUnselected;
  final Color textPrimaryLight;
  final Color textPrimaryDark;
  final Color textSecondary;

  /// 逐色覆盖，返回新调色板（编辑器用）。未传的字段保留原值。
  JellyPalette copyWith({
    Color? primary,
    Color? primaryLight,
    Color? primaryDark,
    Color? accent,
    Color? success,
    Color? warning,
    Color? error,
    Color? blue,
    Color? backgroundLight,
    Color? backgroundDark,
    Color? cardLight,
    Color? cardDark,
    Color? navSelectedBg,
    Color? navSelectedFg,
    Color? navUnselected,
    Color? textPrimaryLight,
    Color? textPrimaryDark,
    Color? textSecondary,
  }) {
    return JellyPalette(
      primary: primary ?? this.primary,
      primaryLight: primaryLight ?? this.primaryLight,
      primaryDark: primaryDark ?? this.primaryDark,
      accent: accent ?? this.accent,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
      blue: blue ?? this.blue,
      backgroundLight: backgroundLight ?? this.backgroundLight,
      backgroundDark: backgroundDark ?? this.backgroundDark,
      cardLight: cardLight ?? this.cardLight,
      cardDark: cardDark ?? this.cardDark,
      navSelectedBg: navSelectedBg ?? this.navSelectedBg,
      navSelectedFg: navSelectedFg ?? this.navSelectedFg,
      navUnselected: navUnselected ?? this.navUnselected,
      textPrimaryLight: textPrimaryLight ?? this.textPrimaryLight,
      textPrimaryDark: textPrimaryDark ?? this.textPrimaryDark,
      textSecondary: textSecondary ?? this.textSecondary,
    );
  }

  /// 序列化为 `{字段名: #AARRGGBB}`，用于自定义主题持久化。
  Map<String, String> toMap() => {
    'primary': _toHex(primary),
    'primaryLight': _toHex(primaryLight),
    'primaryDark': _toHex(primaryDark),
    'accent': _toHex(accent),
    'success': _toHex(success),
    'warning': _toHex(warning),
    'error': _toHex(error),
    'blue': _toHex(blue),
    'backgroundLight': _toHex(backgroundLight),
    'backgroundDark': _toHex(backgroundDark),
    'cardLight': _toHex(cardLight),
    'cardDark': _toHex(cardDark),
    'navSelectedBg': _toHex(navSelectedBg),
    'navSelectedFg': _toHex(navSelectedFg),
    'navUnselected': _toHex(navUnselected),
    'textPrimaryLight': _toHex(textPrimaryLight),
    'textPrimaryDark': _toHex(textPrimaryDark),
    'textSecondary': _toHex(textSecondary),
  };

  /// 由 `{字段名: hex}` 重建调色板；单字段缺失/非法时回退 jelly 对应色（韧性解析）。
  factory JellyPalette.fromMap(Map<String, dynamic> map) {
    const j = JellyPalette.jelly();
    return JellyPalette(
      primary: _fromHex(map['primary'], j.primary),
      primaryLight: _fromHex(map['primaryLight'], j.primaryLight),
      primaryDark: _fromHex(map['primaryDark'], j.primaryDark),
      accent: _fromHex(map['accent'], j.accent),
      success: _fromHex(map['success'], j.success),
      warning: _fromHex(map['warning'], j.warning),
      error: _fromHex(map['error'], j.error),
      blue: _fromHex(map['blue'], j.blue),
      backgroundLight: _fromHex(map['backgroundLight'], j.backgroundLight),
      backgroundDark: _fromHex(map['backgroundDark'], j.backgroundDark),
      cardLight: _fromHex(map['cardLight'], j.cardLight),
      cardDark: _fromHex(map['cardDark'], j.cardDark),
      navSelectedBg: _fromHex(map['navSelectedBg'], j.navSelectedBg),
      navSelectedFg: _fromHex(map['navSelectedFg'], j.navSelectedFg),
      navUnselected: _fromHex(map['navUnselected'], j.navUnselected),
      textPrimaryLight: _fromHex(map['textPrimaryLight'], j.textPrimaryLight),
      textPrimaryDark: _fromHex(map['textPrimaryDark'], j.textPrimaryDark),
      textSecondary: _fromHex(map['textSecondary'], j.textSecondary),
    );
  }

  static String _toHex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

  static Color _fromHex(Object? v, Color fallback) {
    if (v is String && v.isNotEmpty) {
      var s = v.trim();
      if (s.startsWith('#')) s = s.substring(1);
      // 兼容 RRGGBB（补 FF alpha）与 AARRGGBB
      if (s.length == 6) s = 'FF$s';
      final parsed = int.tryParse(s, radix: 16);
      if (parsed != null) return Color(parsed);
    }
    return fallback;
  }

  /// 按 preset id 取调色板（仅内置预设；未知 id 兜底回 jelly）。
  /// 自定义主题的解析见 [SettingsService._resolvePalette]。
  factory JellyPalette.fromPreset(String id) {
    switch (id) {
      // ⚠️ 这个 case 绝不能漏：漏了会 fall through 到 default=jelly，
      // 于是选了「水墨书香」却拿到「魅力紫色」的配色 —— **不报错**，
      // 只是全 App 颜色不对（最难查的那种）。
      // jelly_palette 的测试里专门有一条锁住它。
      case 'ink':
        return const JellyPalette.ink();
      case 'pink':
        return const JellyPalette.pink();
      case 'green':
        return const JellyPalette.green();
      case 'ocean':
        return const JellyPalette.ocean();
      case 'sunset':
        return const JellyPalette.sunset();
      case 'sky':
        return const JellyPalette.sky();
      case 'forest':
        return const JellyPalette.forest();
      case 'lavender':
        return const JellyPalette.lavender();
      case 'coffee':
        return const JellyPalette.coffee();
      case 'sand':
        return const JellyPalette.sand();
      case 'midAutumn':
        return const JellyPalette.midAutumn();
      case 'springFestival':
        return const JellyPalette.springFestival();
      case 'newYear':
        return const JellyPalette.newYear();
      case 'christmas':
        return const JellyPalette.christmas();
      case 'nationalDay':
        return const JellyPalette.nationalDay();
      default:
        return const JellyPalette.jelly();
    }
  }
}

/// 自定义主题背景类型（三选一，互斥）。
enum ThemeBackgroundType { none, animation, image }

/// 自定义主题的背景配置（仅对自定义主题生效；内置 6 套主题恒用各自专属动画，
/// 不读此字段）。
///
/// - [ThemeBackgroundType.none]：纯色，透出 Scaffold 底色（=旧自定义主题行为）。
/// - [ThemeBackgroundType.animation]：借用某套内置背景动画（[animationId] 取
///   green/jelly/pink/ocean/sunset/sky），元素颜色随本主题调色板。
/// - [ThemeBackgroundType.image]：用户上传图片（[imagePath] 为复制到 app 目录后的
///   绝对路径）。
class ThemeBackground {
  const ThemeBackground({
    this.type = ThemeBackgroundType.none,
    this.animationId,
    this.imagePath,
    this.opacity = 1.0,
    this.blur = 0.0,
  });

  const ThemeBackground.none()
    : type = ThemeBackgroundType.none,
      animationId = null,
      imagePath = null,
      opacity = 1.0,
      blur = 0.0;

  const ThemeBackground.animation(
    String id, {
    this.opacity = 1.0,
    this.blur = 0.0,
  }) : type = ThemeBackgroundType.animation,
       animationId = id,
       imagePath = null;

  const ThemeBackground.image(
    String path, {
    this.opacity = 1.0,
    this.blur = 0.0,
  }) : type = ThemeBackgroundType.image,
       animationId = null,
       imagePath = path;

  final ThemeBackgroundType type;
  final String? animationId;
  final String? imagePath;

  /// 背景不透明度 0.2~1.0（默认 1.0）。调低可让底下 Scaffold 底色透出来，
  /// 图片/动画背景更"轻"，正文对比度更高。
  final double opacity;

  /// 背景模糊半径（0 = 不模糊，单位即 ImageFilter sigma，建议 0~24）。
  /// 仅图片背景生效——对逐帧变化的动画施加 ImageFilter 代价过高。
  final double blur;

  ThemeBackground copyWith({
    ThemeBackgroundType? type,
    String? animationId,
    String? imagePath,
    double? opacity,
    double? blur,
  }) {
    return ThemeBackground(
      type: type ?? this.type,
      animationId: animationId ?? this.animationId,
      imagePath: imagePath ?? this.imagePath,
      opacity: opacity ?? this.opacity,
      blur: blur ?? this.blur,
    );
  }

  /// 序列化；缺省字段省略。旧自定义主题无 `background` 节点时由
  /// [fromMap] 回退 [ThemeBackground.none]（向后兼容）。
  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{'type': type.name};
    if (animationId != null) m['animationId'] = animationId;
    if (imagePath != null) m['imagePath'] = imagePath;
    // 只在非默认值时写，保持旧格式体积/可读性
    if (opacity != 1.0) m['opacity'] = opacity;
    if (blur > 0) m['blur'] = blur;
    return m;
  }

  /// 由 map 重建；type 缺失/非法或对应字段缺失 → none（韧性解析）。
  factory ThemeBackground.fromMap(Object? raw) {
    if (raw is! Map) return const ThemeBackground.none();
    final t = raw['type'];
    ThemeBackgroundType? type;
    if (t is String) {
      for (final v in ThemeBackgroundType.values) {
        if (v.name == t) {
          type = v;
          break;
        }
      }
    }
    final opacity = _numOr(raw['opacity'], 1.0).clamp(0.2, 1.0).toDouble();
    final blur = _numOr(raw['blur'], 0.0).clamp(0.0, 40.0).toDouble();
    switch (type) {
      case ThemeBackgroundType.animation:
        final id = raw['animationId'];
        if (id is! String) return const ThemeBackground.none();
        return ThemeBackground(
          type: ThemeBackgroundType.animation,
          animationId: id,
          opacity: opacity,
          blur: blur,
        );
      case ThemeBackgroundType.image:
        final p = raw['imagePath'];
        if (p is! String) return const ThemeBackground.none();
        return ThemeBackground(
          type: ThemeBackgroundType.image,
          imagePath: p,
          opacity: opacity,
          blur: blur,
        );
      default:
        return const ThemeBackground.none().copyWith(
          opacity: opacity,
          blur: blur,
        );
    }
  }

  static double _numOr(Object? v, double fallback) =>
      v is num && v.isFinite ? v.toDouble() : fallback;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ThemeBackground &&
          other.type == type &&
          other.animationId == animationId &&
          other.imagePath == imagePath &&
          other.opacity == opacity &&
          other.blur == blur);

  @override
  int get hashCode => Object.hash(type, animationId, imagePath, opacity, blur);
}

/// 主题预设元信息（UI 展示用：id + 名称 + 调色板取色块）
class ThemePresetInfo {
  const ThemePresetInfo(
    this.id,
    this.name,
    this.palette, {
    this.background = const ThemeBackground(),
  });

  final String id;
  final String name;
  final JellyPalette palette;

  /// 背景配置（仅自定义主题用；内置预设恒用各自动画，此字段被忽略）。
  final ThemeBackground background;
}

/// 全部主题预设（顺序即展示顺序）
const List<ThemePresetInfo> themePresets = [
  // 水墨书香排第一：它是默认主题（截图里也是第一项且选中）
  ThemePresetInfo('ink', '水墨书香', JellyPalette.ink()),
  ThemePresetInfo('jelly', '魅力紫色', JellyPalette.jelly()),
  ThemePresetInfo('pink', '粉色少女', JellyPalette.pink()),
  ThemePresetInfo('green', '清新护眼', JellyPalette.green()),
  ThemePresetInfo('ocean', '蓝色海洋', JellyPalette.ocean()),
  ThemePresetInfo('sunset', '落日余晖', JellyPalette.sunset()),
  ThemePresetInfo('sky', '蓝色天空', JellyPalette.sky()),
  ThemePresetInfo('forest', '森野青岚', JellyPalette.forest()),
  ThemePresetInfo('lavender', '薰衣草梦', JellyPalette.lavender()),
  ThemePresetInfo('coffee', '暖棕咖啡', JellyPalette.coffee()),
  ThemePresetInfo('sand', '沙丘暖阳', JellyPalette.sand()),
  // ── 节日主题（用户 2026-10-20）────────────────────────────────
  ThemePresetInfo('midAutumn', '中秋月圆', JellyPalette.midAutumn()),
  ThemePresetInfo('springFestival', '新春纳福', JellyPalette.springFestival()),
  ThemePresetInfo('newYear', '元旦新岁', JellyPalette.newYear()),
  ThemePresetInfo('christmas', '圣诞雪夜', JellyPalette.christmas()),
  ThemePresetInfo('nationalDay', '国庆华诞', JellyPalette.nationalDay()),
];
