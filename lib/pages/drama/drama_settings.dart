// lib/pages/drama/drama_settings.dart
//
// 「短剧」分类的本地设置（2026-10-22）：
//   · 匹配关键词（源分类名包含任意一个就算短剧类目）
//   · 参与聚合的源（空 = 只聚合当前源）
//
// 存在 SharedPreferences，和订阅/线路解耦，换订阅不会丢。

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/services/api_config.dart';

class DramaSettings {
  DramaSettings._();

  static const _kKeywords = 'drama_keywords_v1';

  /// 旧的**全局**白名单（v1）。2026-10-30 起只用于**迁移**，不再写入。
  static const _kSources = 'drama_source_keys_v1';

  /// 按订阅分组的白名单：`{订阅URL: [源key...]}`（v2）
  static const _kSourcesMap = 'drama_source_keys_v2';

  static const _kGroups = 'drama_groups_v1';
  static const _kListCache = 'drama_list_cache_v1';

  /// 当前源选中的分类下标（按源分别记，2026-10-28）
  static const _kGroupIdx = 'drama_group_idx_v1';

  /// 列表缓存最多保留几个「源 · 分类」（LRU，防止无限膨胀）
  static const int _listCacheMax = 12;

  /// 短剧页当前看的源（单源模式）。
  ///
  /// 用户 2026-10-24：「短剧不要一下子刷新所有的…就是影视那种，
  /// 左上角一个切换源，我一个个切换，不要每一次刷新那么多源」——
  /// 列表页一次只扫这一个源；空串 = 跟随首页当前源。
  static const _kPicked = 'drama_picked_source_v1';

  /// 「挑这个源的时候，首页源是哪个」。
  ///
  /// ⚠️ 2026-10-30 起**不再参与"当前源"解析**（只留档 + 便于排查）。
  ///   它原本用来判定"这次挑的源是不是已经过期"，但那条规则会让用户在影视里
  ///   随便换个线路、短剧就偷偷跟着换源（用户原话：「我不是选了源吗？」）。
  ///   现在挑的源只要还可用就永远优先，见 [resolveCurrentSource]。
  ///   写入点仍在（`savePickedSourceKey(homeKey:)`），保持老数据可读。
  static const _kPickedHome = 'drama_picked_home_v1';

  static Future<String> pickedSourceKey() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getString(_kPicked) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 挑 [pickedSourceKey] 时首页是哪个源（空串 = 老数据/没记录过）。
  static Future<String> pickedHomeKey() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getString(_kPickedHome) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 记住短剧页选的源。
  ///
  /// [homeKey] 传「选的时候首页源 key」，用于判断这次选择是否已过期
  /// （见 [_kPickedHome]）。不传 = 不更新那条记录（保持向后兼容）。
  static Future<void> savePickedSourceKey(
    String key, {
    String? homeKey,
  }) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kPicked, key);
      if (homeKey != null) {
        if (homeKey.isEmpty) {
          await sp.remove(_kPickedHome);
        } else {
          await sp.setString(_kPickedHome, homeKey);
        }
      }
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
  ///
  /// ── 2026-10-30：改成**按订阅分开存** ─────────────────────────
  /// 用户原话：「短剧如果我在这个订阅选了几个，切换订阅后再选的话就是
  /// 增加了，能不能都有有呢。」
  ///
  /// 原来白名单是**一份全局 StringList**（`drama_source_keys_v1`），
  /// 于是切订阅后勾选会**累加**：
  ///   · 订阅 A 勾 {源1, 源2} → 存 {源1, 源2}
  ///   · 切订阅 B（B 里没有这两个 key），弹层里一个都没勾
  ///   · 用户勾 {源3} → 存成 {源1, 源2, 源3} ✗ 白名单里躺着 A 的残留
  ///
  /// 显示上因为 [filterBySelection] 会按当前源的列表过滤，看着"碰巧是对的"，
  /// 但存的那份越来越脏；而且用户切回 A 再打开弹层时，初始状态是
  /// "全没勾"（因为 initial 传的是全局表，A 的 key 在里面但 B 的也在），
  /// 一保存就把 B 的选择带进 A 了。
  ///
  /// 现在按**订阅 URL**（`ApiConfig.configUrl`）分组：每个订阅记自己那份，
  /// 切来切去互不影响、切回原订阅勾选还在（用户要的"都有"）。
  ///
  /// 兼容：老数据（`drama_source_keys_v1` 那份全局表）在首次读到时
  /// **迁移给当前订阅**，之后不再读写它（保留不删，方便回退版本）。
  static Future<Set<String>> sourceKeys() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final scope = _scopeKey();
      final map = _readScopeMap(sp);
      final hit = map[scope];
      if (hit != null) return hit.toSet();

      // 迁移旧全局表（只做一次：迁移完就把该 scope 写进 map）
      final legacy = sp.getStringList(_kSources);
      if (legacy != null && legacy.isNotEmpty) {
        map[scope] = legacy;
        await _writeScopeMap(sp, map);
        return legacy.toSet();
      }
      return <String>{};
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> saveSourceKeys(Set<String> keys) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final map = _readScopeMap(sp);
      // 空集合也要**显式写一条空列表**：否则下次读到 null 会去迁移旧数据，
      // 把用户刚清空的选择又"复活"回来。
      map[_scopeKey()] = keys.toList();
      await _writeScopeMap(sp, map);
    } catch (_) {}
  }

  /// 当前订阅标识：订阅 URL；没配订阅（纯本地源）时用 `local`
  ///
  /// ⚠️ `ApiConfig.instance` 是 `Get.find<ApiConfig>()` —— 单元测试里没有
  /// `Get.put`，直接读会抛 `"ApiConfig" not found`。这里必须兜住：
  /// 拿不到就退化成 `local`（也就等于"不分订阅"），
  /// 否则 `saveSourceKeys` 的 try/catch 会把**整次写入**吞掉，
  /// 测试与"启动早期就写设置"的场景都会静默丢数据。
  static String _scopeKey() {
    try {
      final u = ApiConfig.instance.configUrl.value.trim();
      return u.isEmpty ? 'local' : u;
    } catch (_) {
      return 'local';
    }
  }

  static Map<String, List<String>> _readScopeMap(SharedPreferences sp) {
    final raw = sp.getString(_kSourcesMap);
    if (raw == null || raw.isEmpty) return <String, List<String>>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, List<String>>{};
      final out = <String, List<String>>{};
      decoded.forEach((k, v) {
        if (v is List) {
          out[k.toString()] = [
            for (final e in v)
              if (e != null && e.toString().isNotEmpty) e.toString(),
          ];
        }
      });
      return out;
    } catch (_) {
      return <String, List<String>>{};
    }
  }

  static Future<void> _writeScopeMap(
    SharedPreferences sp,
    Map<String, List<String>> map,
  ) async {
    try {
      await sp.setString(_kSourcesMap, jsonEncode(map));
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
  ///   1. 记录里挑过的 key **还在可选列表里**（存在 / 未被关掉 / 在白名单内）→ 用它；
  ///   2. 挑的源已经没了 → 首页源在白名单内就跟首页源；
  ///   3. 白名单非空 → 取第一个（勾选的源被删/取消勾选时自动落位）；
  ///   4. 白名单为空（没勾过）→ 跟随首页当前源。
  ///
  /// 🔴 2026-10-30 修（用户：「短剧不要影视模块源是什么就是什么呀，
  ///   我不是选了源吗？」）：
  ///   昨天（10-29）为了让"影视里切本地 JS ↔ 订阅"能传导到短剧页，
  ///   这里加过一条「挑源时记下当时的首页 key，首页 key 一变就认定这次挑的
  ///   已过期、改跟首页走」。那条规则**过头了**：
  ///   用户在短剧页明确挑了一个源，之后只要在影视里换过任意一个线路，
  ///   短剧就**默默换成了影视的源** —— 表现正是"我明明选了源，它却跟着影视跑"。
  ///
  ///   而 10-29 那个真问题（切源后短剧还挂在没内容的旧本地 JS 源上）
  ///   真正的根因是**可选列表里还留着已经关掉的本地源**，
  ///   那条已经在 `_allSources()` / `isLocalSourceEnabled` 修掉了：
  ///   关掉的源根本进不了 [all]，规则 1 的 `find` 会落空 → 自动往下落位。
  ///   所以这里不需要"过期"这一层，挑的源**只要还可用就永远优先**。
  static SourceBean? resolveCurrentSource({
    required List<SourceBean> all,
    required Set<String> keys,
    required String pickedKey,
    required SourceBean? homeSource,
  }) {
    final allowed = filterBySelection(all, keys);
    final homeKey = homeSource?.key ?? '';
    bool inWhite(String k) => keys.isEmpty || allowed.any((s) => s.key == k);
    SourceBean? find(String k) {
      for (final s in all) {
        if (s.key == k) return s;
      }
      return null;
    }

    // ① 挑过的源：还在列表里就用它（**不再因为首页源变了而作废**）
    if (pickedKey.isNotEmpty && inWhite(pickedKey)) {
      final hit = find(pickedKey);
      if (hit != null) return hit;
    }

    // ② 挑的源已经不可用（被删 / 被关 / 被移出白名单）→ 首页源在白名单内就跟首页
    if (homeSource != null && homeKey.isNotEmpty && inWhite(homeKey)) {
      return find(homeKey) ?? homeSource;
    }

    // ③ 白名单第一个
    if (keys.isNotEmpty && allowed.isNotEmpty) return allowed.first;

    // ④ 跟随首页当前源
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

  // ============================================================
  // 第一页列表缓存（2026-10-28）
  // ============================================================
  //
  // 用户 2026-10-28：「刷新，连原先明明有都没法出现了…选中的不能缓存一哈吗？」
  // 分类缓存只解决了「扫哪几个分类」，**列表本身**每次都还要打一次接口；
  // 站点抖动时列表拉空 → 页面直接变「这个短剧分类还没有内容」。
  // 这里把每个「源 · 分类」的第一页落盘，刷新失败时先显示上次内容。

  static String _listKey(String sourceKey, String sortId) =>
      '$sourceKey|$sortId';

  static Future<Map<String, dynamic>> _listCacheMap() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kListCache);
      if (raw == null || raw.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return <String, dynamic>{};
  }

  /// 取某个「源 · 分类」上次缓存的第一页；没有返回 null。
  static Future<List<Map<String, dynamic>>?> cachedList(
    String sourceKey,
    String sortId,
  ) async {
    final all = await _listCacheMap();
    final rows = all[_listKey(sourceKey, sortId)];
    if (rows is! List || rows.isEmpty) return null;
    return [
      for (final e in rows)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  /// 存某个「源 · 分类」的第一页（超过上限时按插入顺序淘汰最旧的）。
  static Future<void> saveList(
    String sourceKey,
    String sortId,
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return;
    try {
      final all = await _listCacheMap();
      final key = _listKey(sourceKey, sortId);
      // 重新插入到末尾 = 最近使用
      all.remove(key);
      all[key] = rows;
      while (all.length > _listCacheMax) {
        all.remove(all.keys.first);
      }
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kListCache, jsonEncode(all));
    } catch (_) {}
  }

  // ============================================================
  // 当前源选中的分类下标（2026-10-28）
  // ============================================================
  //
  // 之前 _groupIdx 每次加载都重置成 0，于是重进短剧页一定打回第一个分类
  // （往往就是失效的那个）。这里按源持久化「上次选中的分类」，重进时恢复。

  static String _groupIdxKey(String sourceKey) => '$_kGroupIdx:$sourceKey';

  static Future<int> readGroupIndex(String sourceKey) async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getInt(_groupIdxKey(sourceKey)) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> saveGroupIndex(String sourceKey, int idx) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_groupIdxKey(sourceKey), idx);
    } catch (_) {}
  }

  /// 取某个源下**任意一个**分类的缓存第一页（按最近使用倒序，取最后写入的）。
  ///
  /// 当"缓存 id 失效导致列表空、且本分类没有列表缓存"时，用同源其它分类的
  /// 缓存兜底，至少不让页面彻底空白（2026-10-28 修复）。
  static Future<List<Map<String, dynamic>>?> anyCachedList(
    String sourceKey,
  ) async {
    final all = await _listCacheMap();
    List<Map<String, dynamic>>? pick;
    final prefix = '$sourceKey|';
    for (final entry in all.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final rows = entry.value;
      if (rows is List && rows.isNotEmpty) {
        pick = [
          for (final e in rows)
            if (e is Map) Map<String, dynamic>.from(e),
        ];
      }
    }
    return pick;
  }
}
