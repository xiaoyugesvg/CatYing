/// 阅读设置（截图 IMG_71a10）。
///
/// ── 字段对应关系（截图逐项）──────────────────────────────────
///   阅读模式    ：左右 / 上下 / 仿真 / 覆盖 / 无动画
///   翻页反转    ：左点下一页、右点上一页
///   单手模式    ：屏幕左右点击都是下一页
///   点击区域    ：自定义各区域触发上一页/菜单/下一页
///   双页模式    ：横屏左右并排（上下模式除外）
///   信息栏      ：页眉页脚显示的信息，可逐项开关
///                 时间 / 章节 / 电量 / 书名 / 页码 / 进度
///   音量键翻页  ：按音量上/下键翻页（会接管音量键）
///   屏幕休眠    ：默认 / 10分钟 / 永不息屏
///   A1 对话气泡  ：关 / 对话气泡 / 对称气泡 + 配色
///   A2 繁简转换  ：原始 / 繁→简 / 简→繁
library;

import '../novel_source/novel_chinese_converter.dart';

class ReadingSettings {
  ReadingSettings({
    this.pageMode = PageMode.slide,
    this.flipReverse = false,
    this.oneHand = false,
    this.tapZones = const {},
    this.dualPage = false,
    this.statusItems = const {'章节', '页码', '进度'},
    this.statusTextScale = 1.0,
    this.hideStatusBar = false,
    this.showIllustrations = false,
    this.volumeKeys = false,
    this.sleepMode = SleepMode.defaultMode,
    this.bubbleMode = BubbleMode.none,
    this.bubblePalette = BubblePalette.light,
    this.bubbleBgColor,
    this.bubbleTextColor,
    this.convertMode = ChineseConvertMode.none,
    this.eyeBreakEnabled = false,
    this.eyeBreakMinutes = 30,
    this.purifyRules = defaultPurifyRules,
    this.autoReadIntervalSec = 8,
    this.preloadChapters = 1,
    this.preloadWifiOnly = false,
  });

  final PageMode pageMode;

  /// 左点下一页、右点上一页
  final bool flipReverse;

  /// 屏幕左右点击都是下一页
  final bool oneHand;

  /// 点击区域映射：zone 下标(0~8，3×3) → 动作
  ///
  /// 截图里的默认是「上一页 / 菜单 / 下一页」这类的三列布局。
  /// 空的键表示该区不动作。
  final Map<int, TapAction> tapZones;

  /// 横屏左右并排（上下模式除外）
  final bool dualPage;

  /// 页眉页脚显示的信息项（可多选）
  final Set<String> statusItems;

  /// 信息栏（页眉/页脚）的字体与电量图标缩放。
  ///
  /// 用户 2026-10-21：「信息栏的字体或者图标尺寸加个可调整功能」。
  /// 取值 0.85 / 1.0 / 1.15 / 1.3（小 / 标准 / 大 / 超大）。
  final double statusTextScale;

  /// 阅读时隐藏手机状态栏（沉浸全屏）。
  /// 用户 2026-10-21：「阅读的时候能不能全屏，不显示手机状态栏」。
  final bool hideStatusBar;

  /// 查看插图：在上下一篇末尾显示本章插图（点开可放大）。
  /// 用户 2026-10-21：对齐参考图的「查看插图」项。
  final bool showIllustrations;

  /// 按音量上/下键翻页（会接管音量键）
  final bool volumeKeys;

  final SleepMode sleepMode;

  /// 对话气泡样式（A1）：关 / 对话左气泡 / 对称气泡
  final BubbleMode bubbleMode;

  /// 气泡配色（A1）：浅色 / 深色 / 护眼 / 自定义
  final BubblePalette bubblePalette;

  /// 自定义气泡底色（A1，ARGB 整数）。null = 还没挑过色（用主题派生色）
  final int? bubbleBgColor;

  /// 自定义气泡文字色（A1，ARGB 整数）。null = 跟随正文前景
  final int? bubbleTextColor;

  /// 繁简转换（A2）：原始 / 繁→简 / 简→繁
  final ChineseConvertMode convertMode;

  /// 护眼休息提醒（C7）：连续阅读达到时长后提醒休息
  final bool eyeBreakEnabled;
  /// 护眼休息提醒时长（分钟）
  final int eyeBreakMinutes;

  /// 正文净化规则（C9）：默认规则集 + 用户自定义，启停状态随设置持久化
  final List<PurifyRule> purifyRules;

  /// 自动阅读的翻页间隔（秒）：3~60，默认 8 秒/页。
  ///
  /// 对齐 Legado 的「自动阅读」：到点自动翻下一页（滚动模式则是往下滚一屏），
  /// 任意触摸/切章/退出阅读器都会停。
  final int autoReadIntervalSec;

  /// 后台预取章节数：0~5（0 = 只取当前章），默认 1（当前 + 下一章）。
  final int preloadChapters;

  /// 预取仅走 WiFi（避免用流量偷偷下载后面几章）。
  final bool preloadWifiOnly;

  ReadingSettings copyWith({
    PageMode? pageMode,
    bool? flipReverse,
    bool? oneHand,
    Map<int, TapAction>? tapZones,
    bool? dualPage,
    Set<String>? statusItems,
    double? statusTextScale,
    bool? hideStatusBar,
    bool? showIllustrations,
    bool? volumeKeys,
    SleepMode? sleepMode,
    BubbleMode? bubbleMode,
    BubblePalette? bubblePalette,
    int? bubbleBgColor,
    int? bubbleTextColor,
    ChineseConvertMode? convertMode,
    bool? eyeBreakEnabled,
    int? eyeBreakMinutes,
    List<PurifyRule>? purifyRules,
    int? autoReadIntervalSec,
    int? preloadChapters,
    bool? preloadWifiOnly,
  }) {
    return ReadingSettings(
      pageMode: pageMode ?? this.pageMode,
      flipReverse: flipReverse ?? this.flipReverse,
      oneHand: oneHand ?? this.oneHand,
      tapZones: tapZones ?? this.tapZones,
      dualPage: dualPage ?? this.dualPage,
      statusItems: statusItems ?? this.statusItems,
      statusTextScale: statusTextScale ?? this.statusTextScale,
      hideStatusBar: hideStatusBar ?? this.hideStatusBar,
      showIllustrations: showIllustrations ?? this.showIllustrations,
      volumeKeys: volumeKeys ?? this.volumeKeys,
      sleepMode: sleepMode ?? this.sleepMode,
      bubbleMode: bubbleMode ?? this.bubbleMode,
      bubblePalette: bubblePalette ?? this.bubblePalette,
      bubbleBgColor: bubbleBgColor ?? this.bubbleBgColor,
      bubbleTextColor: bubbleTextColor ?? this.bubbleTextColor,
      convertMode: convertMode ?? this.convertMode,
      eyeBreakEnabled: eyeBreakEnabled ?? this.eyeBreakEnabled,
      eyeBreakMinutes: eyeBreakMinutes ?? this.eyeBreakMinutes,
      purifyRules: purifyRules ?? this.purifyRules,
      autoReadIntervalSec: autoReadIntervalSec ?? this.autoReadIntervalSec,
      preloadChapters: preloadChapters ?? this.preloadChapters,
      preloadWifiOnly: preloadWifiOnly ?? this.preloadWifiOnly,
    );
  }

  /// 默认点击区域：左=上一页，中=菜单，右=下一页（截图里的三列）
  static Map<int, TapAction> defaultZones() => {
        0: TapAction.prev,
        1: TapAction.prev,
        2: TapAction.menu,
        3: TapAction.menu,
        4: TapAction.menu,
        5: TapAction.menu,
        6: TapAction.next,
        7: TapAction.next,
        8: TapAction.next,
      };

  Map<String, dynamic> toJson() => {
        'pageMode': pageMode.name,
        'flipReverse': flipReverse,
        'oneHand': oneHand,
        'tapZones': tapZones.map((k, v) => MapEntry('$k', v.name)),
        'dualPage': dualPage,
        'statusItems': statusItems.toList(),
        'statusTextScale': statusTextScale,
        'hideStatusBar': hideStatusBar,
        'showIllustrations': showIllustrations,
        'volumeKeys': volumeKeys,
        'sleepMode': sleepMode.name,
        'bubbleMode': bubbleMode.name,
        'bubblePalette': bubblePalette.name,
        'bubbleBgColor': bubbleBgColor,
        'bubbleTextColor': bubbleTextColor,
        'convertMode': convertMode.name,
        'eyeBreakEnabled': eyeBreakEnabled,
        'eyeBreakMinutes': eyeBreakMinutes,
        'purifyRules': purifyRules.map((r) => r.toJson()).toList(),
        'autoReadIntervalSec': autoReadIntervalSec,
        'preloadChapters': preloadChapters,
        'preloadWifiOnly': preloadWifiOnly,
      };

  static ReadingSettings fromJson(Map<String, dynamic> j) {
    PageMode pm = PageMode.slide;
    for (final v in PageMode.values) {
      if (v.name == j['pageMode']) pm = v;
    }
    SleepMode sm = SleepMode.defaultMode;
    for (final v in SleepMode.values) {
      if (v.name == j['sleepMode']) sm = v;
    }
    BubbleMode bm = BubbleMode.none;
    for (final v in BubbleMode.values) {
      if (v.name == j['bubbleMode']) bm = v;
    }
    BubblePalette bp = BubblePalette.light;
    for (final v in BubblePalette.values) {
      if (v.name == j['bubblePalette']) bp = v;
    }
    final cm = ChineseConvertMode.fromString(j['convertMode'] as String?);
    final eyeOn = j['eyeBreakEnabled'] as bool? ?? false;
    final eyeMin = j['eyeBreakMinutes'] as int? ?? 30;
    List<PurifyRule> purify = defaultPurifyRules;
    final pj = j['purifyRules'];
    if (pj is List) {
      final parsed = pj
          .whereType<Map>()
          .map((m) => PurifyRule.fromJson(Map<String, dynamic>.from(m)))
          .where((r) => r.pattern.trim().isNotEmpty)
          .toList();
      if (parsed.isNotEmpty) purify = parsed;
    }
    final zones = <int, TapAction>{};
    final zj = j['tapZones'];
    if (zj is Map) {
      zj.forEach((k, v) {
        final i = int.tryParse('$k');
        if (i == null) return;
        for (final a in TapAction.values) {
          if (a.name == v) zones[i] = a;
        }
      });
    }
    return ReadingSettings(
      pageMode: pm,
      flipReverse: j['flipReverse'] == true,
      oneHand: j['oneHand'] == true,
      tapZones: zones.isEmpty ? defaultZones() : zones,
      dualPage: j['dualPage'] == true,
      statusItems: (j['statusItems'] is List)
          ? (j['statusItems'] as List).map((e) => '$e').toSet()
          : {'章节', '页码', '进度'},
      statusTextScale: ((j['statusTextScale'] as num?)?.toDouble() ?? 1.0)
          .clamp(0.8, 1.4)
          .toDouble(),
      hideStatusBar: j['hideStatusBar'] == true,
      showIllustrations: j['showIllustrations'] == true,
      volumeKeys: j['volumeKeys'] == true,
      sleepMode: sm,
      bubbleMode: bm,
      bubblePalette: bp,
      bubbleBgColor: j['bubbleBgColor'] as int?,
      bubbleTextColor: j['bubbleTextColor'] as int?,
      convertMode: cm,
      eyeBreakEnabled: eyeOn,
      eyeBreakMinutes: eyeMin,
      purifyRules: purify,
      autoReadIntervalSec:
          ((j['autoReadIntervalSec'] as num?)?.toInt() ?? 8).clamp(3, 60),
      preloadChapters:
          ((j['preloadChapters'] as num?)?.toInt() ?? 1).clamp(0, 5),
      preloadWifiOnly: j['preloadWifiOnly'] == true,
    );
  }
}

/// 对话气泡样式（A1）
enum BubbleMode {
  /// 关闭气泡（默认平铺）
  none('关'),

  /// 对话行渲染为左侧气泡
  chat('对话气泡'),

  /// 对话行左右交错对称气泡
  symmetric('对称气泡');

  const BubbleMode(this.label);
  final String label;
}

/// 气泡配色（A1）
enum BubblePalette {
  light('浅色'),
  dark('深色'),
  eye('护眼'),

  /// 自定义底色 / 文字色（见 [ReadingSettings.bubbleBgColor] /
  /// [ReadingSettings.bubbleTextColor]）
  custom('自定义');

  const BubblePalette(this.label);
  final String label;
}

/// 阅读模式（截图里的 5 个）
enum PageMode {
  /// 左右：水平滑动翻页（PageView 默认）
  slide('左右'),

  /// 上下：垂直滚动，不分页
  scroll('上下'),

  /// 仿真：翻书卷曲效果
  curl('仿真'),

  /// 覆盖：新页从侧面盖上来
  cover('覆盖'),

  /// 无动画：直接切换
  none('无动画');

  const PageMode(this.label);
  final String label;

  /// 这个模式是否分页（上下模式是滚动的，不分页）
  bool get paginates => this != PageMode.scroll;
}

/// 点击区域的三种动作（截图里是「上一页 / 菜单 / 下一页」）
enum TapAction {
  prev('上一页'),
  menu('菜单'),
  next('下一页'),
  none('无');

  const TapAction(this.label);
  final String label;
}

/// 屏幕休眠（截图里的三个按钮）
enum SleepMode {
  defaultMode('默认'),
  tenMinutes('10分钟'),
  never('永不息屏');

  const SleepMode(this.label);
  final String label;

  /// 对应 Duration；null = 不主动息屏（交给系统）
  Duration? get duration {
    switch (this) {
      case SleepMode.tenMinutes:
        return const Duration(minutes: 10);
      case SleepMode.never:
      case SleepMode.defaultMode:
        return null;
    }
  }
}

/// 正文净化规则（C9）：正则替换，enabled=false 时跳过。
/// pattern 用 RegExp 语义（默认 multiLine），坏正则会被阅读器 try/catch 跳过。
/// 2026-10-22：兼容 legado 的 replaceRule（name/group/isRegex/isEnabled），
/// 旧的三字段 JSON 仍可读；isRegex=false 时按纯文本替换。
class PurifyRule {
  final String name;
  final String group;
  final String pattern;
  final String replacement;
  final bool enabled;
  final bool isRegex;

  const PurifyRule({
    this.name = '',
    this.group = '',
    required this.pattern,
    this.replacement = '',
    this.enabled = true,
    this.isRegex = true,
  });

  factory PurifyRule.fromJson(Map<String, dynamic> j) => PurifyRule(
        name: j['name'] as String? ?? '',
        group: j['group'] as String? ?? '',
        pattern: j['pattern'] as String? ?? j['rule'] as String? ?? '',
        replacement: j['replacement'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? j['isEnabled'] as bool? ?? true,
        isRegex: j['isRegex'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'group': group,
        'pattern': pattern,
        'replacement': replacement,
        'enabled': enabled,
        'isRegex': isRegex,
      };

  PurifyRule copyWith({
    String? name,
    String? group,
    String? pattern,
    String? replacement,
    bool? enabled,
    bool? isRegex,
  }) =>
      PurifyRule(
        name: name ?? this.name,
        group: group ?? this.group,
        pattern: pattern ?? this.pattern,
        replacement: replacement ?? this.replacement,
        enabled: enabled ?? this.enabled,
        isRegex: isRegex ?? this.isRegex,
      );
}

/// 应用一组净化规则（书源阅读器 / 本地阅读器共用）。
/// 坏正则跳过，不打断阅读。
String applyPurifyRules(String raw, List<PurifyRule> rules) {
  var text = raw;
  for (final rule in rules) {
    if (!rule.enabled || rule.pattern.trim().isEmpty) continue;
    if (!rule.isRegex) {
      text = text.replaceAll(rule.pattern, rule.replacement);
      continue;
    }
    try {
      text = text.replaceAll(
        RegExp(rule.pattern, multiLine: true),
        rule.replacement,
      );
    } catch (_) {
      // 用户自定义正则不合法 → 跳过该条
    }
  }
  return text;
}

/// 解析 legado 的「替换净化」JSON：单条对象或数组都接受。
/// 字段：name / group / pattern / replacement / isRegex / isEnabled
/// 也兼容 `legado://import/replaceRule?src=...` 里的 rule 字段写法。
List<PurifyRule> parseLegadoReplaceRules(dynamic json) {
  final list = json is List ? json : (json is Map ? [json] : const []);
  final out = <PurifyRule>[];
  for (final e in list) {
    if (e is! Map) continue;
    final pattern = (e['pattern'] ?? e['rule'] ?? '').toString();
    if (pattern.trim().isEmpty) continue;
    out.add(
      PurifyRule(
        name: (e['name'] ?? '').toString(),
        group: (e['group'] ?? '').toString(),
        pattern: pattern,
        replacement: (e['replacement'] ?? '').toString(),
        enabled: e['isEnabled'] as bool? ?? true,
        isRegex: e['isRegex'] as bool? ?? true,
      ),
    );
  }
  return out;
}

/// C9 默认净化规则集（站点残留文案，可按需关闭/删除）
const List<PurifyRule> defaultPurifyRules = [
  PurifyRule(pattern: r'本章未完，请点击下一页继续阅读'),
  PurifyRule(pattern: r'请记住本书首发域名[^\n]*'),
  PurifyRule(pattern: r'最新网址[：:][^\n]*'),
  PurifyRule(pattern: r'新八一中文网[^\n]*'),
  PurifyRule(pattern: r'为您提供[^\n]*阅读[^\n]*'),
];
