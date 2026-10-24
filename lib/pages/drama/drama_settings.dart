// lib/pages/drama/drama_settings.dart
//
// 「短剧」分类的本地设置（2026-10-22）：
//   · 匹配关键词（源分类名包含任意一个就算短剧类目）
//   · 参与聚合的源（空 = 只聚合当前源）
//
// 存在 SharedPreferences，和订阅/线路解耦，换订阅不会丢。

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/source_bean.dart';
import '../../services/api_config.dart';

class DramaSettings {
  DramaSettings._();

  static const _kKeywords = 'drama_keywords_v1';
  static const _kSources = 'drama_source_keys_v1';
  static const _kGroups = 'drama_groups_v1';

  /// 短剧页当前看的源（单源模式）。
  ///
  /// 用户 2026-10-24：「短剧不要一下子刷新所有的…就是影视那种，
  /// 左上角一个切换源，我一个个切换，不要每一次刷新那么多源」——
  /// 列表页一次只扫这一个源；空串 = 跟随首页当前源。
  static const _kPicked = 'drama_picked_source_v1';

  static Future<String> pickedSourceKey() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getString(_kPicked) ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> savePickedSourceKey(String key) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kPicked, key);
    } catch (_) {}
  }

  static const List<String> defaultKeywords = [
    '短剧',
    '微短剧',
    '竖屏',
    '爽剧',
    '短剧场',
  ];

  static Future<List<String>> keywords() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final list = sp.getStringList(_kKeywords);
      if (list == null || list.isEmpty) return defaultKeywords;
      return list;
    } catch (_) {
      return defaultKeywords;
    }
  }

  static Future<void> saveKeywords(List<String> list) async {
    final clean = list
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(
        _kKeywords,
        clean.isEmpty ? defaultKeywords : clean,
      );
    } catch (_) {}
  }

  /// 参与聚合的源 key；空集合 = 只聚合当前源
  static Future<Set<String>> sourceKeys() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return (sp.getStringList(_kSources) ?? const []).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> saveSourceKeys(Set<String> keys) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_kSources, keys.toList());
    } catch (_) {}
  }

  /// 按「短剧设置」白名单过滤源列表。
  ///
  /// [keys] 为空 = 用户没勾过（表示"不限"），原样返回 [all] 的副本。
  ///
  /// 抽成纯函数：左上角切换器、当前源解析、聚合目标三处共用**同一份规则**，
  /// 也便于单测（见 test/drama_source_selection_test.dart）。
  static List<SourceBean> filterBySelection(
    List<SourceBean> all,
    Set<String> keys,
  ) {
    if (keys.isEmpty) return List<SourceBean>.of(all);
    return all.where((s) => keys.contains(s.key)).toList();
  }

  /// 解析短剧页「当前应显示的源」。
  ///
  /// 规则（与左上角切换器的可选范围保持一致）：
  ///   1. 记录里挑过的 key **且在白名单内** → 用它；
  ///   2. 白名单非空 → 取第一个（勾选的源被删/取消勾选时自动落位）；
  ///   3. 白名单为空（没勾过）→ 跟随首页当前源。
  static SourceBean? resolveCurrentSource({
    required List<SourceBean> all,
    required Set<String> keys,
    required String pickedKey,
    required SourceBean? homeSource,
  }) {
    final allowed = filterBySelection(all, keys);
    final inWhite = keys.isEmpty || allowed.any((s) => s.key == pickedKey);
    if (pickedKey.isNotEmpty && inWhite) {
      for (final s in all) {
        if (s.key == pickedKey) return s;
      }
    }
    if (keys.isNotEmpty && allowed.isNotEmpty) return allowed.first;
    return homeSource;
  }

  /// 解析「参与聚合的源」（列表页扫描 / 搜索页共用）。
  ///
  /// [keys] 为空 → 只取首页当前源；非空 → 白名单过滤。
  static List<SourceBean> resolveTargets({
    required List<SourceBean> all,
    required Set<String> keys,
    required SourceBean? homeSource,
  }) {
    if (keys.isEmpty) {
      return homeSource == null ? const <SourceBean>[] : <SourceBean>[homeSource];
    }
    return all.where((s) => keys.contains(s.key)).toList();
  }

  /// 参与聚合的源：设置里选了就按选择，没选就只取当前源。
  ///
  /// 列表页扫描分类、搜索页搜内容都用同一份，避免两处各算一套
  /// 导致"搜得到的源和看得到的源不一致"。
  static Future<List<SourceBean>> targets() async {
    final api = ApiConfig.instance;
    final all = <SourceBean>[
      ...api.sourceBeanList,
      if (api.localSourcesEnabled.value) ...api.localVideoSources,
    ];
    return resolveTargets(
      all: all,
      keys: await sourceKeys(),
      homeSource: api.homeSourceBean.value,
    );
  }

  /// 上次扫描到的「源 · 分类」缓存。
  ///
  /// 用户 2026-10-23：「之前有的现在刷新不出来了，为啥每次都要刷新重搜？
  /// 既然获取了不能固定吗？」——扫描要打十几个源的分类接口，站点抖动时
  /// 就会漏掉几组；所以把结果落盘，进页面先用缓存，只有手动刷新才重扫。
  static Future<List<Map<String, String>>> cachedGroups() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kGroups);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final e in list)
          if (e is Map)
            {
              'source': '${e['source'] ?? ''}',
              'id': '${e['id'] ?? ''}',
              'name': '${e['name'] ?? ''}',
              'flag': '${e['flag'] ?? ''}',
            },
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveGroups(List<Map<String, String>> rows) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kGroups, jsonEncode(rows));
    } catch (_) {}
  }
}
