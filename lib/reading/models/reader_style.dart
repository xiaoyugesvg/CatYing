/// 一套「阅读样式」= 一份**可命名、可一键切换**的阅读外观快照。
///
/// 为什么单独抽模型：阅读器里的排版/配色选项是**散装**的（字号、行距、边距、
/// 页眉页脚、翻页动画…），换一种观感要改十几处。样式把它们打包成一个整体，
/// 像 Legado 的「阅读样式」/ 简悦的「自定义样式」那样：点一下整套换掉。
///
/// 覆盖四类内容：
///   ① 配色 / 背景：纯色（日间 + 夜间两套索引）、自定义底色、内置壁纸、自定义图片
///   ② 排版：字号 / 行高 / 字距 / 字重 / 段距 / 缩进 / 标题对齐与样式
///   ③ 边距 + 信息栏：正文四边、页眉页脚的内衬、显示哪些项、是否隐藏手机状态栏
///   ④ 翻页动画：左右 / 上下 / 仿真 / 覆盖 / 无动画
///
/// 另外带一整套「底线」（信纸行线），它与排版预设共用同一份快照。
class ReaderStyle {
  const ReaderStyle({
    required this.id,
    required this.name,
    this.builtin = false,
    // ── ① 配色 / 背景 ──
    this.bgIndex = 0,
    this.dayBgIndex = 0,
    this.bgColor,
    this.bgColorNight,
    this.fgColor,
    this.bgImageAsset,
    this.bgImagePath,
    this.bgImageDark = false,
    // ── ② 排版 ──
    this.fontSize = 18,
    this.lineHeight = 1.72,
    this.letterSpacing = 0.3,
    this.fontWeight = 400,
    this.fontId = '',
    this.paraSpacing = 0.5,
    this.indent = 2,
    this.titleAlign = 0,
    this.titleStyle = 0,
    this.hideRepeatTitle = true,
    this.focusBold = false,
    // ── ③ 边距 + 信息栏 ──
    this.padLeft = 20,
    this.padRight = 20,
    this.padTop = 16,
    this.padBottom = 40,
    this.headerPadH = 15,
    this.headerPadTop = 0,
    this.footerPadH = 15,
    this.footerPadBottom = 6,
    this.statusItems = const ['章节', '页码', '进度'],
    this.hideStatusBar = false,
    this.statusTextScale = 1.0,
    // ── 页眉页脚格式串（左/中/右；空串 = 用 statusItems 开关）──
    this.headerL = '',
    this.headerC = '',
    this.headerR = '',
    this.footerL = '',
    this.footerC = '',
    this.footerR = '',
    // ── ④ 翻页 ──
    this.pageMode = 'slide',
    this.dualPage = false,
    // ── 章标题版式（默认 / 仙鹤日间 / 仙鹤夜间 / 微信读书 / 自定义）──
    this.chapterTitleStyle = '',
    this.chapterTitleHtml = '',
    // ── 底线（信纸行线）──
    this.underlineColor,
    this.underlineStyle = 0,
    this.underlineAlpha = 0.35,
    this.underlineWidth = 1.2,
    this.underlineGap = 3.0,
    this.underlineFull = false,
  });

  /// 唯一 id：内置 `builtin:xxx`，用户 `user:<毫秒>`，导入 `import:<毫秒>`
  final String id;

  /// 显示名（样式卡片上的名字）
  final String name;

  /// 是否为内置样式（内置不可改名/删除）
  final bool builtin;

  /// 夜间/当前纯色背景索引（对应阅读器的 6 套纯色）
  final int bgIndex;

  /// 日间纯色背景索引
  final int dayBgIndex;

  /// 自定义底色（ARGB）。非 null 时优先于 [bgIndex]
  final int? bgColor;

  /// 自定义夜间底色（ARGB）。null = 跟随 [bgColor]
  final int? bgColorNight;

  /// 正文/前景色（ARGB）。null = 按背景自动取色
  final int? fgColor;

  /// 内置壁纸 asset（`assets/images/reader_bg/...`）
  final String? bgImageAsset;

  /// 自定义壁纸的本地文件路径（另一台设备上不存在时自动忽略）
  final String? bgImagePath;

  /// 壁纸是否做暗色处理（夜间）
  final bool bgImageDark;

  final double fontSize;
  final double lineHeight;

  /// 字距（逻辑像素）。Legado 里是 em，导入时按 `em × 字号` 换算
  final double letterSpacing;

  final double fontWeight;

  /// 自定义字体 id（'' = 系统默认；见 ReaderFontService）
  final String fontId;
  final double paraSpacing;
  final double indent;
  final int titleAlign;
  final int titleStyle;
  final bool hideRepeatTitle;
  final bool focusBold;

  final double padLeft;
  final double padRight;
  final double padTop;
  final double padBottom;
  final double headerPadH;
  final double headerPadTop;
  final double footerPadH;
  final double footerPadBottom;

  /// 页眉页脚显示项：时间 / 章节 / 电量 / 书名 / 页码 / 进度
  final List<String> statusItems;

  final bool hideStatusBar;
  final double statusTextScale;

  /// 页眉 / 页脚格式串（左 / 中 / 右）。都为空时用 [statusItems] 的开关式渲染。
  final String headerL;
  final String headerC;
  final String headerR;
  final String footerL;
  final String footerC;
  final String footerR;

  /// 翻页动画：slide / scroll / curl / cover / none（= PageMode.name）
  final String pageMode;

  final bool dualPage;

  /// 章标题版式 id（'' = 默认；见 ReaderTitleStyle 的 id）
  final String chapterTitleStyle;

  /// 自定义标题样式的 HTML（`chapterTitleStyle == 'custom'` 时生效）
  final String chapterTitleHtml;

  final int? underlineColor;
  final int underlineStyle;
  final double underlineAlpha;
  final double underlineWidth;
  final double underlineGap;
  final bool underlineFull;

  ReaderStyle renamed(String newName) => ReaderStyle(
    id: id,
    name: newName,
    builtin: builtin,
    bgIndex: bgIndex,
    dayBgIndex: dayBgIndex,
    bgColor: bgColor,
    bgColorNight: bgColorNight,
    fgColor: fgColor,
    bgImageAsset: bgImageAsset,
    bgImagePath: bgImagePath,
    bgImageDark: bgImageDark,
    fontSize: fontSize,
    lineHeight: lineHeight,
    letterSpacing: letterSpacing,
    fontWeight: fontWeight,
    fontId: fontId,
    paraSpacing: paraSpacing,
    indent: indent,
    titleAlign: titleAlign,
    titleStyle: titleStyle,
    hideRepeatTitle: hideRepeatTitle,
    focusBold: focusBold,
    padLeft: padLeft,
    padRight: padRight,
    padTop: padTop,
    padBottom: padBottom,
    headerPadH: headerPadH,
    headerPadTop: headerPadTop,
    footerPadH: footerPadH,
    footerPadBottom: footerPadBottom,
    statusItems: statusItems,
    hideStatusBar: hideStatusBar,
    statusTextScale: statusTextScale,
    headerL: headerL,
    headerC: headerC,
    headerR: headerR,
    footerL: footerL,
    footerC: footerC,
    footerR: footerR,
    pageMode: pageMode,
    dualPage: dualPage,
    chapterTitleStyle: chapterTitleStyle,
    chapterTitleHtml: chapterTitleHtml,
    underlineColor: underlineColor,
    underlineStyle: underlineStyle,
    underlineAlpha: underlineAlpha,
    underlineWidth: underlineWidth,
    underlineGap: underlineGap,
    underlineFull: underlineFull,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'builtin': builtin,
    'bgIndex': bgIndex,
    'dayBgIndex': dayBgIndex,
    'bgColor': bgColor,
    'bgColorNight': bgColorNight,
    'fgColor': fgColor,
    'bgImageAsset': bgImageAsset,
    'bgImagePath': bgImagePath,
    'bgImageDark': bgImageDark,
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'letterSpacing': letterSpacing,
    'fontWeight': fontWeight,
    'fontId': fontId,
    'paraSpacing': paraSpacing,
    'indent': indent,
    'titleAlign': titleAlign,
    'titleStyle': titleStyle,
    'hideRepeatTitle': hideRepeatTitle,
    'focusBold': focusBold,
    'padLeft': padLeft,
    'padRight': padRight,
    'padTop': padTop,
    'padBottom': padBottom,
    'headerPadH': headerPadH,
    'headerPadTop': headerPadTop,
    'footerPadH': footerPadH,
    'footerPadBottom': footerPadBottom,
    'statusItems': statusItems,
    'hideStatusBar': hideStatusBar,
    'statusTextScale': statusTextScale,
    'headerL': headerL,
    'headerC': headerC,
    'headerR': headerR,
    'footerL': footerL,
    'footerC': footerC,
    'footerR': footerR,
    'pageMode': pageMode,
    'dualPage': dualPage,
    'chapterTitleStyle': chapterTitleStyle,
    'chapterTitleHtml': chapterTitleHtml,
    'underlineColor': underlineColor,
    'underlineStyle': underlineStyle,
    'underlineAlpha': underlineAlpha,
    'underlineWidth': underlineWidth,
    'underlineGap': underlineGap,
    'underlineFull': underlineFull,
  };

  static double _d(Object? v, double fallback) =>
      (v as num?)?.toDouble() ?? fallback;

  static int? _i(Object? v) => (v as num?)?.toInt();

  static ReaderStyle fromJson(Map<String, dynamic> j) => ReaderStyle(
    id: (j['id'] as String?) ?? 'user:0',
    name: (j['name'] as String?) ?? '未命名',
    builtin: j['builtin'] as bool? ?? false,
    bgIndex: _i(j['bgIndex']) ?? 0,
    dayBgIndex: _i(j['dayBgIndex']) ?? 0,
    bgColor: _i(j['bgColor']),
    bgColorNight: _i(j['bgColorNight']),
    fgColor: _i(j['fgColor']),
    bgImageAsset: j['bgImageAsset'] as String?,
    bgImagePath: j['bgImagePath'] as String?,
    bgImageDark: j['bgImageDark'] as bool? ?? false,
    fontSize: _d(j['fontSize'], 18),
    lineHeight: _d(j['lineHeight'], 1.72),
    letterSpacing: _d(j['letterSpacing'], 0.3),
    fontWeight: _d(j['fontWeight'], 400),
    fontId: (j['fontId'] as String?) ?? '',
    paraSpacing: _d(j['paraSpacing'], 0.5),
    indent: _d(j['indent'], 2),
    titleAlign: _i(j['titleAlign']) ?? 0,
    titleStyle: _i(j['titleStyle']) ?? 0,
    hideRepeatTitle: j['hideRepeatTitle'] as bool? ?? true,
    focusBold: j['focusBold'] as bool? ?? false,
    padLeft: _d(j['padLeft'], 20),
    padRight: _d(j['padRight'], 20),
    padTop: _d(j['padTop'], 16),
    padBottom: _d(j['padBottom'], 40),
    headerPadH: _d(j['headerPadH'], 15),
    headerPadTop: _d(j['headerPadTop'], 0),
    footerPadH: _d(j['footerPadH'], 15),
    footerPadBottom: _d(j['footerPadBottom'], 6),
    statusItems:
        (j['statusItems'] as List?)?.map((e) => '$e').toList() ??
        const ['章节', '页码', '进度'],
    hideStatusBar: j['hideStatusBar'] as bool? ?? false,
    statusTextScale: _d(j['statusTextScale'], 1.0),
    headerL: (j['headerL'] as String?) ?? '',
    headerC: (j['headerC'] as String?) ?? '',
    headerR: (j['headerR'] as String?) ?? '',
    footerL: (j['footerL'] as String?) ?? '',
    footerC: (j['footerC'] as String?) ?? '',
    footerR: (j['footerR'] as String?) ?? '',
    pageMode: (j['pageMode'] as String?) ?? 'slide',
    dualPage: j['dualPage'] as bool? ?? false,
    chapterTitleStyle: (j['chapterTitleStyle'] as String?) ?? '',
    chapterTitleHtml: (j['chapterTitleHtml'] as String?) ?? '',
    underlineColor: _i(j['underlineColor']),
    underlineStyle: _i(j['underlineStyle']) ?? 0,
    underlineAlpha: _d(j['underlineAlpha'], 0.35),
    underlineWidth: _d(j['underlineWidth'], 1.2),
    underlineGap: _d(j['underlineGap'], 3.0),
    underlineFull: j['underlineFull'] as bool? ?? false,
  );

  // ── Legado / 阅读（readConfig.json）导入 ────────────────────

  /// 解析 Legado 的 `readConfig.json`（站点「导入排版」给的就是它）。
  ///
  /// 已知取舍（如实写在这里，避免以后当成 bug）：
  ///   · **背景图片无法带过来**：`bgType=2` 时 `bgStr` 是对方手机上的
  ///     `/storage/emulated/0/...jpg` 路径，换机后不存在 ⇒ 退化成纯色
  ///     （深色文字给「米黄」，浅色文字给「夜间」），可在「主题」里另选壁纸；
  ///   · **字体无法带过来**：Legado 的 `textFont` 是本机字体文件路径；
  ///   · 页眉页脚按 Legado 的 `headerMode/footerMode` 近似映射：
  ///     0=无、1=时间/页码、2=书名/进度、3=两者都要；
  ///   · `lineSpacingExtra` 是"在字号之外额外加多少 px"，这里折算成行高倍数
  ///     `1 + extra / 字号`；`letterSpacing` 是 em，按 `em × 字号` 折成 px。
  static ReaderStyle fromLegado(
    Map<String, dynamic> cfg, {
    required String id,
    String? nameOverride,
  }) {
    final fs = _d(cfg['textSize'], 19).clamp(12.0, 30.0);
    final extra = _d(cfg['lineSpacingExtra'], 14);
    final lh = (1 + extra / fs).clamp(1.05, 3.0);
    final lsEm = _d(cfg['letterSpacing'], 0);
    final ls = (lsEm * fs).clamp(-2.0, 4.0);
    final indentStr = (cfg['paragraphIndent'] as String?) ?? '';
    final indent = indentStr.length.clamp(0, 4).toDouble();

    final bgType = _i(cfg['bgType']) ?? 0;
    final bgStr = (cfg['bgStr'] as String?) ?? '';
    final textColor = _parseColor(cfg['textColor']);
    // bgType != 2 时 bgStr 才是颜色；== 2 时它是本机图片路径（拿不到）
    final bgColor = bgType == 2 ? null : _parseColor(bgStr);
    final bgNight = bgType == 2 ? null : _parseColor(cfg['bgStrNight']);
    final darkText = _isDark(textColor);
    // 没有可用底色时退化成内置纯色：深色文字 → 米黄(3)，浅色文字 → 夜间(5)
    final fallbackBg = darkText ? 3 : 5;

    final items = <String>[];
    final hm = _i(cfg['headerMode']) ?? 0;
    final fm = _i(cfg['footerMode']) ?? 0;
    if (hm == 1 || hm == 3) items.add('时间');
    if (hm == 2 || hm == 3) items.add('书名');
    if (fm == 1 || fm == 3) items.add('页码');
    if (fm == 2 || fm == 3) items.add('进度');
    if (fm > 0) items.add('章节');

    final anim = _i(cfg['pageAnim']) ?? 2;
    final pageMode = switch (anim) {
      0 => 'cover',
      1 => 'curl',
      2 => 'slide',
      3 => 'none',
      _ => 'scroll',
    };

    double px(Object? v, double fallback, {double max = 120}) =>
        _d(v, fallback).clamp(0.0, max);

    return ReaderStyle(
      id: id,
      name: nameOverride ?? (cfg['name'] as String?) ?? '导入样式',
      bgIndex: bgColor != null ? 0 : fallbackBg,
      dayBgIndex: fallbackBg,
      bgColor: bgColor,
      bgColorNight: bgNight,
      fgColor: textColor,
      fontSize: fs,
      lineHeight: lh,
      letterSpacing: ls,
      fontWeight: 400,
      paraSpacing: 0.5,
      indent: indent,
      hideRepeatTitle: true,
      padLeft: px(cfg['paddingLeft'], 20),
      padRight: px(cfg['paddingRight'], 20),
      padTop: px(cfg['paddingTop'], 0),
      padBottom: px(cfg['paddingBottom'], 0),
      headerPadH: px(
        (cfg['headerPaddingLeft'] as num? ?? 0) +
            (cfg['headerPaddingRight'] as num? ?? 0),
        15,
      ),
      headerPadTop: px(cfg['headerPaddingTop'], 0),
      footerPadH: px(
        (cfg['footerPaddingLeft'] as num? ?? 0) +
            (cfg['footerPaddingRight'] as num? ?? 0),
        15,
      ),
      footerPadBottom: px(cfg['footerPaddingBottom'], 6),
      statusItems: items,
      pageMode: pageMode,
    );
  }

  /// `#AARRGGBB` / `#RRGGBB` / `#RGB` → ARGB 整数（解析失败返回 null）
  static int? _parseColor(Object? v) {
    if (v is! String) return null;
    var s = v.trim();
    if (!s.startsWith('#')) return null;
    s = s.substring(1);
    if (s.length == 3) {
      s = s.split('').map((c) => '$c$c').join();
    }
    if (s.length == 6) s = 'ff$s';
    if (s.length != 8) return null;
    final n = int.tryParse(s, radix: 16);
    return n;
  }

  /// 颜色是否偏暗（用于判断"该配深底还是浅底"）
  static bool _isDark(int? argb) {
    if (argb == null) return true;
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    return (0.299 * r + 0.587 * g + 0.114 * b) < 140;
  }

  // ── 内置样式 ────────────────────────────────────────────────

  /// 内置预设：参数取自站点上真实可解析的 Legado 排版（换算后），
  /// 没有背景图的那几套用阅读器内置纯色代替。
  static const List<ReaderStyle> builtins = [
    ReaderStyle(
      id: 'builtin:modern',
      name: '现代排版',
      builtin: true,
      bgIndex: 3,
      dayBgIndex: 3,
      fgColor: 0xFF000000,
      fontSize: 19,
      lineHeight: 1.74,
      letterSpacing: 0.95,
      indent: 1,
      padLeft: 27,
      padRight: 27,
      padTop: 0,
      padBottom: 0,
      statusItems: ['时间', '书名', '章节', '页码', '进度'],
    ),
    ReaderStyle(
      id: 'builtin:weread',
      name: '微信读书',
      builtin: true,
      bgIndex: 0,
      dayBgIndex: 0,
      fgColor: 0xFF0B0B0B,
      fontSize: 19,
      lineHeight: 1.79,
      letterSpacing: 0.38,
      indent: 0,
      padLeft: 20,
      padRight: 18,
      padTop: 16,
      padBottom: 6,
      statusItems: ['时间', '书名', '章节', '页码', '进度'],
    ),
    ReaderStyle(
      id: 'builtin:jjblue',
      name: '晋江蓝',
      builtin: true,
      bgIndex: 4,
      dayBgIndex: 4,
      fgColor: 0xFF5E8F97,
      fontSize: 20,
      lineHeight: 1.7,
      letterSpacing: -0.4,
      padLeft: 12,
      padRight: 17,
      padTop: 20,
      padBottom: 0,
      statusItems: ['章节', '页码', '进度'],
    ),
    ReaderStyle(
      id: 'builtin:fanqie',
      name: '番茄小说',
      builtin: true,
      bgIndex: 3,
      dayBgIndex: 3,
      fgColor: 0xFF5B4928,
      fontSize: 24,
      lineHeight: 1.58,
      letterSpacing: 0,
      padLeft: 21,
      padRight: 20,
      padTop: 12,
      padBottom: 11,
      statusItems: ['时间', '书名', '章节', '页码', '进度'],
    ),
    ReaderStyle(
      id: 'builtin:qidian',
      name: '起点',
      builtin: true,
      bgIndex: 3,
      dayBgIndex: 3,
      fgColor: 0xFF302303,
      fontSize: 18,
      lineHeight: 1.72,
      letterSpacing: 0.18,
      padLeft: 25,
      padRight: 25,
      padTop: 1,
      padBottom: 0,
      statusItems: ['章节', '页码', '进度'],
    ),
    ReaderStyle(
      id: 'builtin:night',
      name: '黑夜主题',
      builtin: true,
      bgIndex: 5,
      dayBgIndex: 5,
      fgColor: 0xFFBCB4B4,
      fontSize: 20,
      lineHeight: 1.6,
      letterSpacing: 1.6,
      padLeft: 20,
      padRight: 20,
      padTop: 40,
      padBottom: 6,
      statusItems: ['时间', '书名', '章节', '页码'],
    ),
    ReaderStyle(
      id: 'builtin:houmo',
      name: '仿厚墨排版',
      builtin: true,
      bgIndex: 0,
      dayBgIndex: 0,
      fgColor: 0xFF2D2D33,
      fontSize: 17,
      lineHeight: 1.71,
      letterSpacing: 0.34,
      padLeft: 22,
      padRight: 22,
      padTop: 9,
      padBottom: 10,
      statusItems: ['时间', '书名', '章节', '页码', '进度'],
    ),
    ReaderStyle(
      id: 'builtin:day1',
      name: '白天布局',
      builtin: true,
      bgIndex: 3,
      dayBgIndex: 3,
      fgColor: 0xFF3E3422,
      fontSize: 24,
      lineHeight: 1.62,
      letterSpacing: 0.72,
      padLeft: 20,
      padRight: 20,
      padTop: 10,
      padBottom: 6,
      statusItems: ['时间', '书名', '章节', '页码', '进度'],
    ),
    ReaderStyle(
      id: 'builtin:plain',
      name: '极简纯色',
      builtin: true,
      bgIndex: 0,
      dayBgIndex: 0,
      fgColor: 0xFF4A4545,
      fontSize: 22,
      lineHeight: 1.41,
      letterSpacing: 0.22,
      padLeft: 5,
      padRight: 5,
      padTop: 0,
      padBottom: 0,
      statusItems: [],
    ),
    ReaderStyle(
      id: 'builtin:kraft',
      name: '牛皮纸夜读',
      builtin: true,
      bgIndex: 2,
      dayBgIndex: 2,
      bgColor: 0xFFECE3DC,
      bgColorNight: 0xFF3B2F1E,
      fgColor: 0xFF4C433C,
      fontSize: 23,
      lineHeight: 1.74,
      letterSpacing: 0,
      padLeft: 30,
      padRight: 30,
      padTop: 35,
      padBottom: 6,
      statusItems: ['时间', '书名', '章节', '页码', '进度'],
    ),
    ReaderStyle(
      id: 'builtin:green',
      name: '护眼绿',
      builtin: true,
      bgIndex: 1,
      dayBgIndex: 1,
      fgColor: 0xFF23301F,
      fontSize: 18,
      lineHeight: 1.72,
      letterSpacing: 0.3,
      padLeft: 20,
      padRight: 20,
      padTop: 16,
      padBottom: 40,
      statusItems: ['章节', '页码', '进度'],
    ),
    ReaderStyle(
      id: 'builtin:ink',
      name: '墨黑',
      builtin: true,
      bgIndex: 5,
      dayBgIndex: 5,
      fgColor: 0xFFC8C8C8,
      fontSize: 18,
      lineHeight: 1.72,
      letterSpacing: 0.3,
      padLeft: 20,
      padRight: 20,
      padTop: 16,
      padBottom: 40,
      statusItems: ['章节', '页码', '进度'],
    ),
  ];
}
