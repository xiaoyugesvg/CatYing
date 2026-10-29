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

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

import 'package:tvbox/models/import_conflict.dart';
import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/xbpq/xbpq_http.dart';
import 'package:tvbox/services/xbpq/xbpq_play.dart';
import 'package:tvbox/services/xbpq/xbpq_rule.dart';
import 'package:tvbox/services/xbpq/xbpq_source.dart';
import 'package:tvbox/services/xbpq/xbpq_util.dart';

/// 一条已导入的 XBPQ 源。
class XbpqEntry {
  XbpqEntry({
    required this.key,
    required this.name,
    required this.ruleText,
    this.addedAt = 0,
    this.usage = 0,
  }) : rule = XbpqRule.parse(ruleText);

  final String key;
  final String name;
  final String ruleText;

  /// 导入时间（毫秒）。2026-10-29 补：XBPQ 管理页要与「本地爬虫」同构，
  /// 排序菜单里的「时间 / 频率」需要这两个字段。
  final int addedAt;

  /// 使用次数（「频率」排序用）。
  final int usage;

  /// 解析结果；规则不合法时为 null（导入时会拦掉，这里只是兜底）。
  final XbpqRule? rule;

  /// 转成 App 内部的 SourceBean（与 [XbpqService.sourceBeans] 同口径）。
  ///
  /// 刻意不用 type=3：那是 Spider 分支，会在 `SourceService` 里被抢先路由到
  /// 脚本引擎。type=1 只是占位，真正的分发靠 key 前缀。
  SourceBean toSourceBean() => SourceBean(
    key: key,
    name: name,
    api: '${XbpqService._apiScheme}$key',
    type: 1,
    searchable: 1,
    filterable: 1,
  );

  XbpqEntry copyWith({String? name, int? usage}) => XbpqEntry(
    key: key,
    name: name ?? this.name,
    ruleText: ruleText,
    addedAt: addedAt,
    usage: usage ?? this.usage,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'rule': ruleText,
    if (addedAt > 0) 'addedAt': addedAt,
    if (usage > 0) 'usage': usage,
  };

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
      addedAt: (value['addedAt'] as num?)?.toInt() ?? 0,
      usage: (value['usage'] as num?)?.toInt() ?? 0,
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
    _entries[key] = XbpqEntry(
      key: key,
      name: displayName,
      ruleText: ruleText,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _save();
    AppLog.instance.log('[Xbpq] 已导入规则 $key（$displayName）');
    return (true, '已导入 $displayName');
  }

  /// 批量导入（统一只写一次盘）。与 `LocalJsSources.importMany` 同构。
  ///
  /// 同名规则按 [replaceName] 决定是覆盖还是改名：
  ///   · true（默认）= 覆盖同名条目，**沿用旧 key**（用户视角是"规则更新了"）；
  ///   · false = 自动改名 `名字 (2)`。
  Future<({int imported, int failed, List<String> errors})> importMany(
    List<({String name, String code})> items, {
    ImportConflict conflict = ImportConflict.rename,
  }) async {
    if (items.isEmpty) {
      return (imported: 0, failed: 0, errors: const <String>[]);
    }
    await ensureLoaded();
    var imported = 0;
    var failed = 0;
    final errors = <String>[];
    for (final it in items) {
      final ruleText = it.code.trim();
      if (ruleText.isEmpty) {
        failed++;
        if (errors.length < 8) errors.add('${it.name}: 规则内容为空');
        continue;
      }
      final parsed = XbpqRule.parse(ruleText);
      if (parsed == null) {
        failed++;
        if (errors.length < 8) errors.add('${it.name}: 不是 XBPQ 规则');
        continue;
      }
      var display = it.name.trim();
      if (display.toLowerCase().endsWith('.json')) {
        display = display.substring(0, display.length - 5);
      }
      if (display.toLowerCase().endsWith('.txt')) {
        display = display.substring(0, display.length - 4);
      }
      if (display.isEmpty) display = keyPrefix;

      // 同名覆盖：沿用旧 key，只换规则文本
      XbpqEntry? same;
      if (conflict == ImportConflict.replace) {
        for (final e in _entries.values) {
          if (e.name == display) {
            same = e;
            break;
          }
        }
      }
      if (same != null) {
        _entries[same.key] = XbpqEntry(
          key: same.key,
          name: same.name,
          ruleText: ruleText,
          addedAt: same.addedAt,
          usage: same.usage,
        );
        imported++;
        continue;
      }
      // 避免重名：`名字 (2)`、`名字 (3)`…
      var unique = display;
      var n = 2;
      while (_entries.values.any((e) => e.name == unique)) {
        unique = '$display ($n)';
        n++;
      }
      final key = '$keyPrefix${_hashOf(ruleText)}';
      _entries[key] = XbpqEntry(
        key: key,
        name: unique,
        ruleText: ruleText,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      );
      imported++;
    }
    if (imported > 0) await _save();
    return (imported: imported, failed: failed, errors: errors);
  }

  /// 这批名字里与**现有规则同名**的那些（已去掉扩展名）。
  Future<List<String>> conflictingNames(Iterable<String> names) async {
    final bases = <String>{};
    for (final raw in names) {
      var b = raw.trim();
      final lower = b.toLowerCase();
      if (lower.endsWith('.json')) b = b.substring(0, b.length - 5);
      if (lower.endsWith('.txt')) b = b.substring(0, b.length - 4);
      if (b.isNotEmpty) bases.add(b);
    }
    if (bases.isEmpty) return const <String>[];
    await ensureLoaded();
    return _entries.values
        .where((e) => bases.contains(e.name))
        .map((e) => e.name)
        .toList();
  }

  /// 修改某条规则的文本（页面里的「编辑规则」）。
  Future<(bool, String)> saveRule(String key, String text) async {
    await ensureLoaded();
    final entry = _entries[key];
    if (entry == null) return (false, '规则不存在');
    final ruleText = text.trim();
    if (ruleText.isEmpty) return (false, '规则内容为空');
    if (XbpqRule.parse(ruleText) == null) {
      return (false, '这不是 XBPQ 规则：缺少 主页url / 分类url 等必需字段');
    }
    _entries[key] = XbpqEntry(
      key: key,
      name: entry.name,
      ruleText: ruleText,
      addedAt: entry.addedAt,
      usage: entry.usage,
    );
    await _save();
    return (true, '');
  }

  /// 按给定 key 顺序重排（源面板拖动排序用）。
  ///
  /// `_entries` 是 LinkedHashMap，插入顺序即展示顺序 —— 重建一遍即可。
  Future<void> reorderWithin(List<String> orderedKeys) async {
    await ensureLoaded();
    if (orderedKeys.isEmpty) return;
    final wanted = orderedKeys.toSet();
    final next = <String, XbpqEntry>{};
    var qi = 0;
    for (final e in _entries.values) {
      if (wanted.contains(e.key)) {
        final k = orderedKeys[qi++];
        final moved = _entries[k];
        if (moved != null) next[k] = moved;
      } else {
        next[e.key] = e;
      }
    }
    if (next.length != _entries.length) return;
    _entries
      ..clear()
      ..addAll(next);
    await _save();
  }

  /// 记录一次使用（「频率」排序用）。
  Future<void> bumpUsage(String key) async {
    await ensureLoaded();
    final e = _entries[key];
    if (e == null) return;
    _entries[key] = e.copyWith(usage: e.usage + 1);
    await _save();
  }


  Future<({bool ok, String? message})> remove(String key) async {
    await ensureLoaded();
    if (_entries.remove(key) == null) {
      return (ok: false, message: '规则不存在');
    }
    await _save();
    AppLog.instance.log('[Xbpq] 已删除规则 $key');
    return (ok: true, message: null);
  }

  /// 改名。
  ///
  /// key 是**规则文本**的哈希，与显示名无关 ⇒ 改名不动 key，
  /// 当前选中的源、已存的播放记录都不会因此失效。
  Future<({bool ok, String? message})> rename(String key, String name) async {
    await ensureLoaded();
    final entry = _entries[key];
    if (entry == null) return (ok: false, message: '规则不存在');
    final displayName = name.trim();
    if (displayName.isEmpty) return (ok: false, message: '名称不能为空');
    if (displayName == entry.name) return (ok: true, message: null);
    _entries[key] = XbpqEntry(
      key: key,
      name: displayName,
      ruleText: entry.ruleText,
      addedAt: entry.addedAt,
      usage: entry.usage,
    );
    await _save();
    return (ok: true, message: null);
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


  // ══════════════════════════════════════════════════════════════
  // 与 LocalJsSources / LocalPythonSources 对齐的调用面
  // ══════════════════════════════════════════════════════════════
  // 用户 2026-10-29：「XBPQ 的管理以及导入还有等等功能，开关都要和本地爬虫
  // 一样」。三个管理页共用同一套布局与交互，只有背后的存储不同 ——
  // 这里补齐同名方法，页面才能用同一份实现（少一份重复的 1400 行 UI）。

  /// 已导入规则（按展示顺序）。
  List<XbpqEntry> get sources => entries;

  /// 按文本导入一条规则（页面统一调用）。
  Future<({bool ok, String? message, XbpqEntry? source})> importCode(
    String code, {
    String? displayName,
    bool save = true,
    ImportConflict conflict = ImportConflict.rename,
  }) async {
    await ensureLoaded();
    var base = (displayName ?? 'XBPQ 规则').trim();
    final lower = base.toLowerCase();
    if (lower.endsWith('.json')) base = base.substring(0, base.length - 5);
    if (lower.endsWith('.txt')) base = base.substring(0, base.length - 4);
    if (base.isEmpty) base = 'XBPQ 规则';

    final ruleText = code.trim();
    if (ruleText.isEmpty) {
      return (ok: false, message: '规则内容为空', source: null);
    }
    if (XbpqRule.parse(ruleText) == null) {
      return (
        ok: false,
        message: '这不是 XBPQ 规则：缺少 主页url / 分类url 等必需字段',
        source: null,
      );
    }

    // 同名覆盖：沿用旧 key（与 PY / JS 的 ImportConflict.replace 同语义）
    if (conflict == ImportConflict.replace) {
      for (final e in _entries.values.toList()) {
        if (e.name == base) {
          _entries[e.key] = XbpqEntry(
            key: e.key,
            name: e.name,
            ruleText: ruleText,
            addedAt: e.addedAt,
            usage: e.usage,
          );
          if (save) await _save();
          return (ok: true, message: null, source: _entries[e.key]);
        }
      }
    }

    var name = base;
    var n = 2;
    while (_entries.values.any((e) => e.name == name)) {
      name = '$base ($n)';
      n++;
    }
    final key = '$keyPrefix${_hashOf(ruleText)}';
    final entry = XbpqEntry(
      key: key,
      name: name,
      ruleText: ruleText,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _entries[key] = entry;
    if (save) await _save();
    return (ok: true, message: null, source: entry);
  }

  /// 读一条规则的文本（页面「编辑规则」用）。
  Future<String?> readCode(String key) async {
    await ensureLoaded();
    return _entries[key]?.ruleText;
  }

  /// 写一条规则的文本（与 `LocalJsSources.saveCode` 同签名）。
  Future<({bool ok, String? message})> saveCode(
    String key,
    String code,
  ) async {
    final (ok, message) = await saveRule(key, code);
    return (ok: ok, message: message.isEmpty ? null : message);
  }

  /// 扫描目录里的 `.json` / `.txt`（供「导入文件夹」用）。
  Future<List<({String name, String code})>> scanDirectory(
    String path, {
    bool recursive = true,
  }) async {
    final items = <({String name, String code})>[];
    final dir = Directory(path);
    if (!await dir.exists()) return items;
    await for (final f in dir.list(
      recursive: recursive,
      followLinks: false,
    )) {
      if (f is! File) continue;
      final lower = f.path.toLowerCase();
      if (!lower.endsWith('.json') && !lower.endsWith('.txt')) continue;
      try {
        final code = await f.readAsString();
        if (code.trim().isEmpty) continue;
        items.add((name: f.uri.pathSegments.last, code: code));
      } catch (_) {
        // 单个文件读失败不影响其它文件
      }
    }
    return items;
  }


  /// 解析 zip 里的 `.json` / `.txt`（不落盘）。解析失败会抛异常。
  List<({String name, String code})> scanZipBytes(List<int> bytes) {
    final items = <({String name, String code})>[];
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final f in archive) {
      if (!f.isFile) continue;
      final name = f.name.replaceAll('\\', '/');
      final lower = name.toLowerCase();
      if (!lower.endsWith('.json') && !lower.endsWith('.txt')) continue;
      if (lower.contains('__macosx/')) continue;
      final data = f.content;
      if (data is! List<int> || data.isEmpty) continue;
      items.add((
        name: name.split('/').last,
        code: utf8.decode(data, allowMalformed: true),
      ));
    }
    return items;
  }

  /// XBPQ 规则是纯文本，没有"注册进引擎"这一步（内置 Dart 引擎按需解析）。
  Future<int> registerAll() async {
    await ensureLoaded();
    return _entries.length;
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
