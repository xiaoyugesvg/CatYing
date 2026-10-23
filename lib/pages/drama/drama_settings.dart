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
    final keys = await sourceKeys();
    if (keys.isEmpty) {
      final cur = api.homeSourceBean.value;
      return cur == null ? const [] : [cur];
    }
    return all.where((s) => keys.contains(s.key)).toList();
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
