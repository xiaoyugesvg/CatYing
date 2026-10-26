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

import 'package:tvbox/reading/novel_source/novel_chinese_converter.dart';

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

  /// 默认点击分区：**按列**（和 Legado 一致）。
  ///
  /// 左列=上一页 / 中列=功能面板 / 右列=下一页。
  ///
  /// ⚠️ 2026-10-25 修：原来写的是「上中=上一页、中间一整行=菜单、下中=下一页」，
  /// 于是手指点在**中间偏上/偏下**都会翻页（很常见的落点），用户会以为
  /// "单击根本呼不出功能面板"。改成按列之后，竖直方向随便点中间那 1/3 都出面板。
  static Map<int, TapAction> defaultZones() => {
        0: TapAction.prev,
        1: TapAction.menu,
        2: TapAction.next,
        3: TapAction.prev,
        4: TapAction.menu,
        5: TapAction.next,
        6: TapAction.prev,
        7: TapAction.menu,
        8: TapAction.next,
      };

  /// 旧版默认分区（用于把老用户的存档自动升级成上面的按列分区）
  static const Map<int, TapAction> _legacyDefaultZones = {
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
    // 老存档里存的是**旧默认**（上中=上一页 / 中间一整行=菜单 / 下中=下一页）。
    // 那不是用户手改的，只是当时写死的默认值 ⇒ 自动升级成"按列"，
    // 否则改了默认也没用（老用户读到的还是旧存档）。
    if (zones.length == 9 &&
        _legacyDefaultZones.entries.every((e) => zones[e.key] == e.value)) {
      zones
        ..clear()
        ..addAll(defaultZones());
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

/// 宽松布尔解析：`true` / `1` / `"true"` 都算 true；
/// 不是布尔/数字/可识别字符串时用 [fallback]（当"没配置"）。
///
/// 为什么需要：净化规则是**第三方 JSON**（Legado 规则集、别人导出的文件），
/// 里面 `"scopeContent": "false"` 这种写法很常见，`as bool?` 会直接抛 TypeError。
bool _boolOr(dynamic v, bool fallback) {
  if (v == null) return fallback;
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = v.toString().trim().toLowerCase();
  if (s == 'true' || s == '1' || s == 'yes') return true;
  if (s == 'false' || s == '0' || s == 'no') return false;
  return fallback;
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

  /// 生效范围（书名关键词，空 = 所有书）。对应 Legado 的「范围」。
  final String bookScope;

  /// 排除范围（书名关键词，空 = 不排除）。对应 Legado 的「排除范围」。
  final String excludeScope;

  /// 用于标题 / 用于正文（Legado 的两个开关）。
  final bool applyToTitle;
  final bool applyToContent;

  const PurifyRule({
    this.name = '',
    this.group = '',
    required this.pattern,
    this.replacement = '',
    this.enabled = true,
    this.isRegex = true,
    this.bookScope = '',
    this.excludeScope = '',
    this.applyToTitle = false,
    this.applyToContent = true,
  });

  factory PurifyRule.fromJson(Map<String, dynamic> j) => PurifyRule(
        name: j['name'] as String? ?? '',
        group: j['group'] as String? ?? '',
        pattern: j['pattern'] as String? ?? j['rule'] as String? ?? '',
        replacement: j['replacement'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? j['isEnabled'] as bool? ?? true,
        isRegex: j['isRegex'] as bool? ?? true,
        bookScope: j['bookScope'] as String? ?? j['scope'] as String? ?? '',
        excludeScope:
            j['excludeScope'] as String? ?? j['exclude'] as String? ?? '',
        // ⚠️ 别写成 `as bool?`：第三方 JSON 里可能是 "true"/1，
        //   强转会抛 TypeError，整条导入就废了。这里用宽松判断。
        applyToTitle: _boolOr(j['applyToTitle'], _boolOr(j['scopeTitle'], false)),
        applyToContent:
            _boolOr(j['applyToContent'], _boolOr(j['scopeContent'], true)),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'group': group,
        'pattern': pattern,
        'replacement': replacement,
        'enabled': enabled,
        'isRegex': isRegex,
        'bookScope': bookScope,
        'excludeScope': excludeScope,
        'applyToTitle': applyToTitle,
        'applyToContent': applyToContent,
      };

  PurifyRule copyWith({
    String? name,
    String? group,
    String? pattern,
    String? replacement,
    bool? enabled,
    bool? isRegex,
    String? bookScope,
    String? excludeScope,
    bool? applyToTitle,
    bool? applyToContent,
  }) =>
      PurifyRule(
        name: name ?? this.name,
        group: group ?? this.group,
        pattern: pattern ?? this.pattern,
        replacement: replacement ?? this.replacement,
        enabled: enabled ?? this.enabled,
        isRegex: isRegex ?? this.isRegex,
        bookScope: bookScope ?? this.bookScope,
        excludeScope: excludeScope ?? this.excludeScope,
        applyToTitle: applyToTitle ?? this.applyToTitle,
        applyToContent: applyToContent ?? this.applyToContent,
      );

  /// 这本书是否适用（范围/排除范围都是「书名包含关键词」）
  bool matchesBook(String bookName) {
    final b = bookName.trim();
    if (bookScope.trim().isNotEmpty && !b.contains(bookScope.trim())) {
      return false;
    }
    if (excludeScope.trim().isNotEmpty && b.contains(excludeScope.trim())) {
      return false;
    }
    return true;
  }
}

/// 对一段文本应用**一条**规则（纯文本 / 正则都支持）。
/// 坏正则 → 原样返回（不打断阅读）。
String _applyOneRule(String text, PurifyRule rule) {
  if (!rule.isRegex) {
    return text.replaceAll(rule.pattern, rule.replacement);
  }
  var pattern = rule.pattern;
  var caseSensitive = true;
  var dotAll = false;
  // Legado（Java 正则）允许内联标志 `(?i)` / `(?m)` / `(?s)`，Dart 的 RegExp
  // 会直接报 `Invalid group` ⇒ 整条规则被静默跳过（实测 Downloadclouds 那套
  // 20 条里有 9 条是这么废掉的）。
  // 这里把**所有**内联标志剥掉、合并成全局参数：
  //   i = 不区分大小写（全局近似，比整条失效强）
  //   s = 点匹配换行
  //   m = 我们已经全局 multiLine: true，直接丢掉即可
  //   x/u 之类 Dart 没有对应项，丢掉标志本身（保留正则体）
  pattern = pattern.replaceAllMapped(RegExp(r'\(\?([a-zA-Z]+)\)'), (m) {
    final f = m.group(1)!.toLowerCase();
    if (f.contains('i')) caseSensitive = false;
    if (f.contains('s')) dotAll = true;
    return '';
  });
  try {
    return text.replaceAll(
      RegExp(
        pattern,
        multiLine: true,
        caseSensitive: caseSensitive,
        dotAll: dotAll,
      ),
      rule.replacement,
    );
  } catch (_) {
    // 用户自定义正则不合法 → 跳过该条
    return text;
  }
}

/// 应用一组净化规则（书源阅读器 / 本地阅读器共用）。
/// 坏正则跳过，不打断阅读。
///
/// [bookName] 传入时按规则的「范围 / 排除范围」筛选；不传则不做范围判断
/// （老调用点行为不变）。只作用于标题的规则在这里一律跳过（正文不该被它改）。
String applyPurifyRules(String raw, List<PurifyRule> rules, {String? bookName}) {
  var text = raw;
  for (final rule in rules) {
    if (!rule.enabled || rule.pattern.trim().isEmpty) continue;
    if (!rule.applyToContent) continue;
    if (bookName != null && !rule.matchesBook(bookName)) continue;
    text = _applyOneRule(text, rule);
  }
  return text;
}

/// 只对**标题**生效的规则（Legado 的「用于标题」）。
/// 正文不受影响；用在章节目录名 / 顶栏章节名上。
String applyPurifyTitleRules(String raw, List<PurifyRule> rules,
    {String? bookName}) {
  var text = raw;
  for (final rule in rules) {
    if (!rule.enabled || rule.pattern.trim().isEmpty) continue;
    if (!rule.applyToTitle) continue;
    if (bookName != null && !rule.matchesBook(bookName)) continue;
    text = _applyOneRule(text, rule);
  }
  return text;
}

/// 解析 legado 的「替换净化」JSON：单条对象或数组都接受。
/// 字段：name / group / pattern / replacement / isRegex / isEnabled
/// 也兼容 `legado://import/replaceRule?src=...` 里的 rule 字段写法。
///
/// ⚠️ 只会**跳过**一类规则（[skipped] 里记下名字，方便告诉用户导入了多少）：
///   `replacement` 以 `@js:` 开头 —— 那是 Legado 内置 JS 脚本，我们这边跑不了；
///   **绝不能原样导入**，否则匹配到的正文会被替换成一整段 JS 源码。
///
/// 「范围 / 排除范围 / 用于标题 / 用于正文」现在都支持了，所以**不再跳过**
/// 只作用于标题的规则（2026-10-25 加了 [applyPurifyTitleRules]）。
List<PurifyRule> parseLegadoReplaceRules(dynamic json, {List<String>? skipped}) {
  final list = json is List ? json : (json is Map ? [json] : const []);
  final out = <PurifyRule>[];
  for (final e in list) {
    if (e is! Map) continue;
    final pattern = (e['pattern'] ?? e['rule'] ?? '').toString();
    final name = (e['name'] ?? '').toString();
    if (pattern.trim().isEmpty) continue;
    final replacement = (e['replacement'] ?? '').toString();
    if (replacement.trimLeft().startsWith('@js:') ||
        replacement.trimLeft().startsWith('@JavaScript:')) {
      skipped?.add(name);
      continue;
    }
    out.add(
      PurifyRule(
        name: name,
        group: (e['group'] ?? '').toString(),
        pattern: pattern,
        replacement: replacement,
        enabled: _boolOr(e['isEnabled'], true),
        isRegex: _boolOr(e['isRegex'], true),
        bookScope: (e['scope'] ?? '').toString(),
        excludeScope: (e['excludeScope'] ?? '').toString(),
        applyToTitle: _boolOr(e['scopeTitle'], false),
        // Legado 的 scopeContent 默认是 true
        applyToContent: _boolOr(e['scopeContent'], true),
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
