/// 小说书源数据模型，承载书源元信息与各路由规则。
library;

import 'dart:convert';

import 'rule_search.dart';
import 'rule_toc.dart';
import 'rule_content.dart';
import 'rule_book_info.dart';
import 'rule_explore.dart';

class XiaoshuoBookSource {
  String bookSourceUrl;
  String bookSourceName;
  String? bookSourceGroup;
  int bookSourceType;
  String? bookUrlPattern;
  int customOrder;
  bool enabled;
  bool enabledExplore;
  String? jsLib;
  bool enabledCookieJar;
  String? concurrentRate;
  String? header;
  String? loginUrl;
  String? loginUi;
  String? loginCheckJs;
  String? coverDecodeJs;
  String? bookSourceComment;
  String? variableComment;
  int lastUpdateTime;
  int respondTime;
  int weight;
  String? exploreUrl;
  String? exploreScreen;
  ExploreRule? ruleExplore;
  String? searchUrl;
  SearchRule? ruleSearch;
  BookInfoRule? ruleBookInfo;
  TocRule? ruleToc;
  ContentRule? ruleContent;

  /// 解析器配置（保留字段）。
  Map<String, dynamic>? parserConfig;

  /// 子分类检测开关。
  bool subCategoryDetection;

  /// 过滤关键词。
  List<String> filterKeywords;

  /// 子分类 URL 模式。
  List<String> subCategoryPatterns;

  XiaoshuoBookSource({
    this.bookSourceUrl = '',
    this.bookSourceName = '',
    this.bookSourceGroup,
    this.bookSourceType = 0,
    this.bookUrlPattern,
    this.customOrder = 0,
    this.enabled = true,
    this.enabledExplore = true,
    this.jsLib,
    this.enabledCookieJar = true,
    this.concurrentRate,
    this.header,
    this.loginUrl,
    this.loginUi,
    this.loginCheckJs,
    this.coverDecodeJs,
    this.bookSourceComment,
    this.variableComment,
    this.lastUpdateTime = 0,
    this.respondTime = 180000,
    this.weight = 0,
    this.exploreUrl,
    this.exploreScreen,
    this.ruleExplore,
    this.searchUrl,
    this.ruleSearch,
    this.ruleBookInfo,
    this.ruleToc,
    this.ruleContent,
    this.parserConfig,
    this.subCategoryDetection = true,
    this.filterKeywords = const [],
    this.subCategoryPatterns = const [],
  });

  String get key => bookSourceUrl;
  String get tag => bookSourceName;

  bool get isValid =>
      bookSourceName.isNotEmpty &&
      bookSourceUrl.isNotEmpty &&
      (ruleSearch != null || ruleToc != null || ruleContent != null || ruleExplore != null);

  SearchRule getSearchRule() {
    ruleSearch ??= SearchRule();
    return ruleSearch!;
  }

  ExploreRule getExploreRule() {
    ruleExplore ??= ExploreRule();
    return ruleExplore!;
  }

  BookInfoRule getBookInfoRule() {
    ruleBookInfo ??= BookInfoRule();
    return ruleBookInfo!;
  }

  TocRule getTocRule() {
    ruleToc ??= TocRule();
    return ruleToc!;
  }

  ContentRule getContentRule() {
    ruleContent ??= ContentRule();
    return ruleContent!;
  }

  /// `header` 形态兼容：String 原样；Map/List 编码成 JSON 字符串；其它 → toString。
  ///
  /// 见 [fromJson] 里 [FIX-HEADER-MAP] 的说明：服务层可能写 Map，引擎只吃字符串。
  static String? _headerString(dynamic v) {
    if (v == null) return null;
    if (v is String) return v;
    if (v is Map || v is List) {
      try {
        return jsonEncode(v);
      } catch (_) {
        return null;
      }
    }
    return v.toString();
  }

  /// 宽容取整：数字 / 数字字符串 / 中文类型名（"漫画"=2 等）。
  static int _asInt(Object? v, [int fallback = 0]) {
    if (v is num) return v.toInt();
    if (v is String) {
      final s = v.trim();
      final n = int.tryParse(s);
      if (n != null) return n;
      switch (s) {
        case '有声':
        case 'audio':
          return 1;
        case '漫画':
        case 'comic':
          return 2;
        case '文件':
        case 'file':
          return 3;
      }
    }
    return fallback;
  }

  /// 宽容取布尔：bool / "true" / 1 / 0。
  static bool _asBool(Object? v, bool fallback) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      if (s == 'true' || s == '1') return true;
      if (s == 'false' || s == '0') return false;
    }
    return fallback;
  }

  factory XiaoshuoBookSource.fromJson(Map<String, dynamic> json) {
    return XiaoshuoBookSource(
      bookSourceUrl: json['bookSourceUrl'] as String? ?? '',
      bookSourceName: json['bookSourceName'] as String? ?? '',
      bookSourceGroup: json['bookSourceGroup'] as String?,
      // ⚠️ Legado 源里 bookSourceType 既可能是数字（0/1/2/3），也可能是
      // 中文文本（"漫画"）。原来写死 `as int?` ⇒ 遇到文本型直接抛类型错，
      // 整条源在漫画模块被跳过（内置「看漫画」「漫小肆」就是这么消失的）。
      bookSourceType: _asInt(json['bookSourceType']),
      bookUrlPattern: json['bookUrlPattern'] as String?,
      customOrder: _asInt(json['customOrder']),
      enabled: _asBool(json['enabled'], true),
      enabledExplore: _asBool(json['enabledExplore'], true),
      jsLib: json['jsLib'] as String?,
      enabledCookieJar: _asBool(json['enabledCookieJar'], true),
      concurrentRate: json['concurrentRate']?.toString(),
      // [FIX-HEADER-MAP] `header` 在 legado 里是 **JSON 字符串**（如 '{"User-Agent":"…"}'），
      // 但本项目服务层保存 Cookie 时会把它写成 **Map**（book_source_service.dart 里
      // `header['Cookie'] = c` 后 `raw['header'] = header`）⇒ 原来的 `as String?`
      // 会抛类型错，被上层吞掉后**整个源在 Dart-only 引擎下不可用**（保存过 Cookie 的源必现）。
      // 这里两种形态都接受：Map/List 一律 `jsonEncode` 成字符串，与引擎的
      // `analyze_url.dart` `_parseHeader(String)` 消费口径一致。
      header: _headerString(json['header']),
      loginUrl: json['loginUrl'] as String?,
      loginUi: json['loginUi'] as String?,
      loginCheckJs: json['loginCheckJs'] as String?,
      coverDecodeJs: json['coverDecodeJs'] as String?,
      bookSourceComment: json['bookSourceComment'] as String?,
      variableComment: json['variableComment'] as String?,
      lastUpdateTime: _asInt(json['lastUpdateTime']),
      respondTime: _asInt(json['respondTime'], 180000),
      weight: _asInt(json['weight']),
      exploreUrl: json['exploreUrl'] as String?,
      exploreScreen: json['exploreScreen'] as String?,
      ruleExplore: _parseExploreRule(json['ruleExplore']),
      searchUrl: json['searchUrl'] as String?,
      ruleSearch: _parseSearchRule(json['ruleSearch']),
      ruleBookInfo: _parseBookInfoRule(json['ruleBookInfo']),
      ruleToc: _parseTocRule(json['ruleToc']),
      ruleContent: _parseContentRule(json['ruleContent']),
      parserConfig: json['parser'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(json['parser'] as Map)
          : null,
      subCategoryDetection: _asBool(json['subCategoryDetection'], true),
      filterKeywords: _parseStringList(json['filterKeywords']),
      subCategoryPatterns: _parseStringList(json['subCategoryPatterns']),
    );
  }

  Map<String, dynamic> toJson() => {
        'bookSourceUrl': bookSourceUrl,
        'bookSourceName': bookSourceName,
        if (bookSourceGroup != null) 'bookSourceGroup': bookSourceGroup,
        'bookSourceType': bookSourceType,
        if (bookUrlPattern != null) 'bookUrlPattern': bookUrlPattern,
        'customOrder': customOrder,
        'enabled': enabled,
        'enabledExplore': enabledExplore,
        if (jsLib != null) 'jsLib': jsLib,
        'enabledCookieJar': enabledCookieJar,
        if (concurrentRate != null) 'concurrentRate': concurrentRate,
        if (header != null) 'header': header,
        if (loginUrl != null) 'loginUrl': loginUrl,
        if (loginUi != null) 'loginUi': loginUi,
        if (loginCheckJs != null) 'loginCheckJs': loginCheckJs,
        if (coverDecodeJs != null) 'coverDecodeJs': coverDecodeJs,
        if (bookSourceComment != null) 'bookSourceComment': bookSourceComment,
        if (variableComment != null) 'variableComment': variableComment,
        'lastUpdateTime': lastUpdateTime,
        'respondTime': respondTime,
        'weight': weight,
        if (exploreUrl != null) 'exploreUrl': exploreUrl,
        if (exploreScreen != null) 'exploreScreen': exploreScreen,
        if (ruleExplore != null) 'ruleExplore': ruleExplore!.toJson(),
        if (searchUrl != null) 'searchUrl': searchUrl,
        if (ruleSearch != null) 'ruleSearch': ruleSearch!.toJson(),
        if (ruleBookInfo != null) 'ruleBookInfo': ruleBookInfo!.toJson(),
        if (ruleToc != null) 'ruleToc': ruleToc!.toJson(),
        if (ruleContent != null) 'ruleContent': ruleContent!.toJson(),
        if (parserConfig != null) 'parser': parserConfig,
        'subCategoryDetection': subCategoryDetection,
        if (filterKeywords.isNotEmpty) 'filterKeywords': filterKeywords,
        if (subCategoryPatterns.isNotEmpty)
          'subCategoryPatterns': subCategoryPatterns,
      };

  static ExploreRule? _parseExploreRule(dynamic val) {
    final map = _parseRuleDynamic(val);
    if (map is Map<String, dynamic>) return ExploreRule.fromJson(map);
    return null;
  }

  static SearchRule? _parseSearchRule(dynamic val) {
    final map = _parseRuleDynamic(val);
    if (map is Map<String, dynamic>) return SearchRule.fromJson(map);
    return null;
  }

  static BookInfoRule? _parseBookInfoRule(dynamic val) {
    final map = _parseRuleDynamic(val);
    if (map is Map<String, dynamic>) return BookInfoRule.fromJson(map);
    return null;
  }

  static TocRule? _parseTocRule(dynamic val) {
    final map = _parseRuleDynamic(val);
    if (map is Map<String, dynamic>) return TocRule.fromJson(map);
    return null;
  }

  static ContentRule? _parseContentRule(dynamic val) {
    final map = _parseRuleDynamic(val);
    if (map is Map<String, dynamic>) return ContentRule.fromJson(map);
    return null;
  }
}

List<String> _parseStringList(dynamic val) {
  if (val == null) return const [];
  if (val is List) {
    return val.whereType<String>().toList();
  }
  if (val is String) {
    return val.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }
  return const [];
}

dynamic _parseRuleDynamic(dynamic val) {
  if (val == null) return null;
  if (val is Map<String, dynamic>) return val;
  if (val is Map) return Map<String, dynamic>.from(val.cast());
  if (val is String && val.isNotEmpty) {
    try {
      // JSON 字符串解析：部分 Legado 书源将规则存储为 JSON 字符串而非 Map
      final decoded = jsonDecode(val);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded.cast());
    } catch (_) {}
  }
  if (val is List) {
    for (final item in val) {
      if (item is Map<String, dynamic>) return item;
      if (item is Map) return Map<String, dynamic>.from(item.cast());
    }
  }
  return null;
}
