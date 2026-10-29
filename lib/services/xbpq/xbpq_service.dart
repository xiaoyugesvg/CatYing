// lib/services/xbpq/xbpq_service.dart
//
// XBPQ 源接入层 —— 把 `xbpq_source` / `xbpq_play` 包成一个按 key 寻址的门面，
// 并负责规则的持久化（导入 / 删除 / 列表）。
//
// 为什么要这一层：
//   · 取数层（P3）与播放层（P4）都是**纯 Dart**、靠注入的 fetcher 工作；
//     真正的网络实现（`XbpqHttp.fetch`，依赖 dio/Flutter）在这里接上；
//   · `SourceService` 只认 `SourceBean.key`，所以规则要能按 key 找到；
//   · 输出刻意保持 **TVBox JSON 协议形态**（`{class:[...]}` / `{list:[...]}`），
//     让 `SourceService` 现有的 `_parseVideoListFromJson` / `VodInfo.fromVideo`
//     直接复用，不必为 XBPQ 另写一套模型转换。
//
// key 约定：`localxbpq_<规则哈希前 12 位>` —— 与 `localpy_` 同族，
// 这样源面板、主页源回退、本地源开关等既有逻辑都能直接复用。

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/xbpq/xbpq_http.dart';
import 'package:tvbox/services/xbpq/xbpq_play.dart';
import 'package:tvbox/services/xbpq/xbpq_rule.dart';
import 'package:tvbox/services/xbpq/xbpq_source.dart';
import 'package:tvbox/services/xbpq/xbpq_util.dart';

/// 一条已导入的 XBPQ 源。
class XbpqEntry {
  XbpqEntry({required this.key, required this.name, required this.ruleText})
      : rule = XbpqRule.parse(ruleText);

  final String key;
  final String name;
  final String ruleText;

  /// 解析结果；规则不合法时为 null（导入时会拦掉，这里只是兜底）。
  final XbpqRule? rule;

  Map<String, dynamic> toJson() => {'name': name, 'rule': ruleText};

  static XbpqEntry? fromJson(String key, dynamic value) {
    if (value is! Map) return null;
    final name = '${value['name'] ?? ''}'.trim();
    final rule = '${value['rule'] ?? ''}';
    if (rule.trim().isEmpty) return null;
    final parsed = XbpqRule.parse(rule);
    if (parsed == null) return null;
    return XbpqEntry(
      key: key,
      name: name.isEmpty ? key : name,
      ruleText: rule,
    );
  }
}

class XbpqService {
  XbpqService._();

  static final XbpqService instance = XbpqService._();

  /// 源 key 前缀（与 `localpy_` 同族）。
  static const String keyPrefix = 'localxbpq_';

  static const String _prefsKey = 'xbpq_rules_v1';

  /// 规则「地址里的协议」——只用于展示，不是真能请求的地址。
  static const String _apiScheme = 'xbpq://';

  final Map<String, XbpqEntry> _entries = <String, XbpqEntry>{};
  bool _loaded = false;

  /// 取数层要 fetcher，播放层要取数层 —— 都懒建，避免 import 期副作用。
  late final XbpqSource _source = XbpqSource(fetcher: _fetch);
  late final XbpqPlay _play = XbpqPlay(source: _source);

  /// `XbpqFetcher` 是位置参数，`XbpqHttp.fetch` 是命名参数，这里做一次适配。
  static Future<String> _fetch(String raw, String referer, String agent) =>
      XbpqHttp.fetch(raw, referer: referer, agent: agent);

  // ============================================================
  // 规则仓
  // ============================================================

  bool get hasAny => _entries.isNotEmpty;

  int get count => _entries.length;

  /// 已导入的规则（供设置页列表用）。按导入顺序返回。
  List<XbpqEntry> get entries => List<XbpqEntry>.unmodifiable(_entries.values);

  /// 单条规则；不存在返回 null。
  XbpqEntry? entryOf(String key) => _entries[key];

  /// 已导入的源（供 `ApiConfig` 汇总进 `localVideoSources`）。
  List<SourceBean> get sourceBeans {
    final beans = <SourceBean>[];
    for (final entry in _entries.values) {
      beans.add(
        SourceBean(
          key: entry.key,
          name: entry.name,
          api: '$_apiScheme${entry.key}',
          // 刻意不用 type=3：那是 Spider 分支，会在 `SourceService` 里被
          // 抢先路由到脚本引擎。type=1 只是占位，真正的分发靠 key 前缀。
          type: 1,
          searchable: 1,
          filterable: 1,
        ),
      );
    }
    return beans;
  }

  Future<void> ensureLoaded({bool force = false}) async {
    if (_loaded && !force) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final next = <String, XbpqEntry>{};
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            final entry = XbpqEntry.fromJson(key.toString(), value);
            if (entry != null) next[entry.key] = entry;
          });
        }
      } catch (e) {
        AppLog.instance.w('[Xbpq] 规则清单解析失败: $e');
      }
    }
    // 原子换表：解析中途失败也不会把已有规则清空。
    _entries
      ..clear()
      ..addAll(next);
    _loaded = true;
  }

  /// 导入一份规则文本。返回 (是否成功, 提示语)。
  Future<(bool, String)> importRule({
    required String name,
    required String text,
  }) async {
    final ruleText = text.trim();
    if (ruleText.isEmpty) return (false, '规则内容为空');

    final rule = XbpqRule.parse(ruleText);
    if (rule == null) {
      return (false, '这不是 XBPQ 规则：缺少 主页url / 分类url 等必需字段');
    }

    await ensureLoaded();
    final key = '$keyPrefix${_hashOf(ruleText)}';
    final displayName = name.trim().isEmpty ? key : name.trim();
    _entries[key] = XbpqEntry(key: key, name: displayName, ruleText: ruleText);
    await _save();
    AppLog.instance.log('[Xbpq] 已导入规则 $key（$displayName）');
    return (true, '已导入 $displayName');
  }

  Future<void> remove(String key) async {
    await ensureLoaded();
    if (_entries.remove(key) == null) return;
    await _save();
    AppLog.instance.log('[Xbpq] 已删除规则 $key');
  }

  /// 改名。
  ///
  /// key 是**规则文本**的哈希，与显示名无关 ⇒ 改名不动 key，
  /// 当前选中的源、已存的播放记录都不会因此失效。
  Future<(bool, String)> rename(String key, String name) async {
    await ensureLoaded();
    final entry = _entries[key];
    if (entry == null) return (false, '规则不存在');
    final displayName = name.trim();
    if (displayName.isEmpty) return (false, '名称不能为空');
    if (displayName == entry.name) return (true, '');
    _entries[key] = XbpqEntry(
      key: key,
      name: displayName,
      ruleText: entry.ruleText,
    );
    await _save();
    return (true, '');
  }

  /// 清空全部规则，返回删除条数。
  Future<int> clearAll() async {
    await ensureLoaded();
    final n = _entries.length;
    if (n == 0) return 0;
    _entries.clear();
    await _save();
    AppLog.instance.log('[Xbpq] 已清空 $n 条规则');
    return n;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      for (final entry in _entries.values) entry.key: entry.toJson(),
    };
    await prefs.setString(_prefsKey, jsonEncode(payload));
  }

  static String _hashOf(String text) =>
      md5.convert(utf8.encode(text)).toString().substring(0, 12);

  // ============================================================
  // 数据
  // ============================================================

  /// 按 key 取规则；未导入或规则损坏时抛 [XbpqException]。
  Future<(XbpqRule, String)> _resolve(String key) async {
    await ensureLoaded();
    final entry = _entries[key];
    if (entry == null) throw const XbpqException('XBPQ 规则不存在（可能已被删除）');
    final rule = entry.rule;
    if (rule == null) throw const XbpqException('XBPQ 规则已损坏，请重新导入');
    final base = rule.homeUrl;
    if (base.isEmpty) throw const XbpqException('XBPQ 规则缺少主页地址');
    return (rule, base);
  }

  /// 首页：`(分类, 第一页视频)`。
  Future<(List<Map<String, String>>, List<Map<String, dynamic>>)> home(
    String key,
  ) async {
    final (rule, base) = await _resolve(key);
    final content = await _source.homeContent(rule: rule, base: base);
    final classes = (content['class'] as List)
        .whereType<Map<String, String>>()
        .toList();
    final videos = (content['list'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();
    return (classes, videos);
  }

  /// 分类列表。
  Future<List<Map<String, dynamic>>> category(
    String key, {
    required String categoryId,
    required int page,
  }) async {
    final (rule, base) = await _resolve(key);
    final content = await _source.categoryContent(
      rule: rule,
      base: base,
      category: categoryId,
      page: page,
    );
    return (content['list'] as List).whereType<Map<String, dynamic>>().toList();
  }

  /// 详情（含 `vod_play_from` / `vod_play_url`）。
  Future<Map<String, dynamic>?> detail(String key, String vodId) async {
    final (rule, base) = await _resolve(key);
    final content = await _play.detail(rule: rule, base: base, sourceId: vodId);
    final list = content['list'] as List?;
    if (list == null || list.isEmpty) return null;
    return list.first as Map<String, dynamic>;
  }

  /// 搜索。
  Future<List<Map<String, dynamic>>> search(
    String key,
    String keyword,
  ) async {
    final (rule, base) = await _resolve(key);
    final content = await _source.search(rule: rule, base: base, query: keyword);
    return (content['list'] as List).whereType<Map<String, dynamic>>().toList();
  }

  /// 取播放地址 → `{url, parse, header}`。
  ///
  /// 目前播放链路还没接这个钩子（详情页给的是**播放页地址**）。这里先备着：
  /// 接上之后能直接用规则里的「跳转播放链接」取直链，比开网页播放更准。
  Future<Map<String, dynamic>> playUrl(
    String key,
    String pageUrl, {
    String referer = '',
  }) async {
    final (rule, base) = await _resolve(key);
    return _play.playUrl(
      rule: rule,
      base: base,
      pageUrl: pageUrl,
      referer: referer,
    );
  }
}
