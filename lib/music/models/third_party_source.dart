import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 第三方音源的数据层 —— 移植自 Beans-Music 的 `UnblockSourceStore.swift`。
///
/// ── 这是什么 ──────────────────────────────────────────────────
/// 用户自己导入的"音源"配置：一条 [ThirdPartySource] 描述如何从一个
/// 第三方服务把歌曲解析成可播放地址。支持两种形态：
///
///   · `kind: 'keyword'` —— **模板法**：把歌名/歌手填进 [template] 的占位符
///     拼成请求 URL，再从响应里按 [urlPath] 取播放地址。
///     例如 `https://api.x.com/url?name={name}&artist={artist}`
///
///   · `kind: 'script'`  —— **脚本法**：用 [script] 里的 LX 脚本
///     （JavaScript）自己完成请求与解析，能力更强（可加密、可多步）。
///
///   · `kind: 'musicfree'` —— **MusicFree 插件**：也用 [script] 存，
///     但导出形状是 `{ platform, getMediaSource }` 且常 `require('axios')`。
///     跑法走独立适配层（见 `assets/nodejs-project/src/musicfree_adapter.js`）。
///
/// 原版字段全部保留（含 [script]），因为用户明确要求"源添加功能不变"。
class ThirdPartySource {
  final String id;
  final String name;

  /// 'keyword' = 模板法；'script' = LX 脚本法
  final String kind;

  /// 模板 URL（模板法用）
  final String template;

  /// 从响应 JSON 里取播放地址的路径，如 'data.url'
  final String urlPath;

  /// 请求头
  final Map<String, String> headers;

  /// 默认音质：'128k' / '320k' / 'flac' / 'flac24bit' / 'hires' / 'atmos' / 'master'
  final String quality;

  /// LX 脚本源码（脚本法用）
  final String? script;

  final bool enabled;

  /// 是不是**内置音源**（随 App 打包的洛雪/MusicFree 源）。
  ///
  /// 内置源可以**编辑**（改配置），可以**删除**（删除 = 从列表移除，App 重建
  /// 时会自动重新注册并启用——见 `BuiltinSourcesService`）。用户自己导入的源
  /// 这一字段为 false（与旧数据兼容：老 JSON 没有该字段 → 默认为 false）。
  final bool isBuiltin;

  /// 内置源的更新源 URL（用于「检查更新」/自动更新；用户源为空）
  final String updateUrl;

  /// 插件的**用户变量**（登录态 / Cookie / 卡密 / 服务器地址…）。
  ///
  /// ── 2026-10-21 第三期 ────────────────────────────────────────
  /// MusicFree 插件可以在导出里声明 `userVariables: [{key,name,hint}]`，
  /// 运行时通过 `global.env.getUserVariables()` 读取。宿主要做的就是把
  /// 用户填的值注入进去（见 `musicfree_adapter.js` / `lx_engine.js`）。
  ///
  /// 空表 = 该插件没配任何变量（或用户没填）。
  final Map<String, String> variables;

  const ThirdPartySource({
    required this.id,
    required this.name,
    this.kind = 'keyword',
    required this.template,
    this.urlPath = 'url',
    this.headers = const {},
    this.quality = '320k',
    this.script,
    this.enabled = true,
    this.isBuiltin = false,
    this.updateUrl = '',
    this.variables = const {},
  });

  /// 是不是 **LX 脚本**（`lx.on(...)` / `module.exports.musicUrl`）
  bool get isScript => kind == 'script';

  /// 是不是 **MusicFree 插件**（`module.exports = { platform, getMediaSource }`）
  ///
  /// ⚠️ 这类源**也是**用 [script] 存脚本的，只是**跑法不同**：
  /// LX 走纯沙箱，MusicFree 走适配层（注入 axios/he 白名单）。
  bool get isMusicFree => kind == 'musicfree';

  /// **要不要用脚本字段**（LX 脚本 + MusicFree 插件都算）。
  ///
  /// 🔴 为什么要单独一个 getter，而不是到处写 `isScript`：
  /// 音源管理页与编辑器原来全部按 `s.isScript` 分支，于是
  /// MusicFree 插件会被当成**模板法**：
  ///   · 列表标签显示成 "KEYWORD"（错的）
  ///   · 编辑器不显示脚本框，改显示模板输入框
  ///   · **保存时 `script: s.isScript ? scriptCtrl.text : s.script`**
  ///     → 脚本字段被写回旧值 → 插件内容丢失 → 播放必然失败 ✗
  bool get usesScript => isScript || isMusicFree;

  /// UI 上显示的类型名
  String get kindLabel {
    if (isMusicFree) return 'MusicFree';
    if (isScript) return '脚本';
    return 'KEYWORD';
  }

  ThirdPartySource copyWith({
    String? name,
    String? kind,
    String? template,
    String? urlPath,
    Map<String, String>? headers,
    String? quality,
    String? script,
    bool? enabled,
    bool clearScript = false,
    Map<String, String>? variables,
  }) {
    return ThirdPartySource(
      id: id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      template: template ?? this.template,
      urlPath: urlPath ?? this.urlPath,
      headers: headers ?? this.headers,
      quality: quality ?? this.quality,
      script: clearScript ? null : (script ?? this.script),
      enabled: enabled ?? this.enabled,
      isBuiltin: isBuiltin,
      updateUrl: updateUrl,
      variables: variables ?? this.variables,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind,
        'template': template,
        'urlPath': urlPath,
        'headers': headers,
        'quality': quality,
        if (script != null) 'script': script,
        'enabled': enabled,
        if (isBuiltin) 'isBuiltin': true,
        if (updateUrl.isNotEmpty) 'updateUrl': updateUrl,
        if (variables.isNotEmpty) 'variables': variables,
      };

  /// 宽松解析：原版对每个字段都有默认值，缺字段不报错
  /// （用户导入的源格式五花八门，宽容比严格有用）
  factory ThirdPartySource.fromJson(Map<String, dynamic> j) {
    final headers = <String, String>{};
    final rawHeaders = j['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) => headers[k.toString()] = v.toString());
    }
    // 用户变量（插件登录态等）：只收字符串键值，坏数据忽略
    final variables = <String, String>{};
    final rawVars = j['variables'];
    if (rawVars is Map) {
      rawVars.forEach((k, v) {
        final key = k.toString().trim();
        if (key.isEmpty || v == null) return;
        variables[key] = v.toString();
      });
    }
    final quality = (j['quality'] ?? headers['quality'] ?? '320k').toString();
    return ThirdPartySource(
      id: (j['id'] ?? DateTime.now().microsecondsSinceEpoch.toString()).toString(),
      name: (j['name'] ?? '未命名音源').toString(),
      kind: (j['kind'] ?? 'keyword').toString(),
      template: (j['template'] ?? '').toString(),
      urlPath: (j['urlPath'] ?? 'url').toString(),
      headers: headers,
      quality: quality,
      script: j['script']?.toString(),
      enabled: _asBool(j['enabled']),
      isBuiltin: _asBool(j['isBuiltin'], fallback: false),
      updateUrl: (j['updateUrl'] ?? '').toString(),
      variables: variables,
    );
  }

  /// 宽容解析 bool：兼容 `true/false`、`"true"/"false"`、`1/0`、`"1"/"0"`、`yes/no/on/off`。
  ///
  /// ⚠️ 原来是 `j['enabled'] as bool? ?? true` —— 用户导入的源里 `enabled`
  /// 写成字符串或数字时会抛 `CastError`，而 [listFromJson] 是整份 map，
  /// **一条脏数据就把整个音源列表废掉**（列表变空且没有任何提示）。
  static bool _asBool(Object? v, {bool fallback = true}) {
    if (v == null) return fallback;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v.toString().trim().toLowerCase();
    if (s.isEmpty) return fallback;
    if (s == 'true' || s == '1' || s == 'yes' || s == 'y' || s == 'on') {
      return true;
    }
    if (s == 'false' || s == '0' || s == 'no' || s == 'n' || s == 'off') {
      return false;
    }
    return fallback;
  }

  static List<ThirdPartySource> listFromJson(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      debugPrint('[ThirdPartySource] 音源列表 JSON 解析失败: $e');
      return const [];
    }
    if (decoded is! List) return const [];

    // ⚠️ 逐条容错：原来 `.map(fromJson)` 一条坏数据就整份抛异常 →
    // 列表直接空掉，用户看到"音源全没了"却不知道是哪条坏了。
    // 现在跳过坏的、保留好的，并把跳过了几条写进日志。
    final out = <ThirdPartySource>[];
    var skipped = 0;
    for (final e in decoded) {
      if (e is! Map) {
        skipped++;
        continue;
      }
      try {
        out.add(ThirdPartySource.fromJson(e.cast<String, dynamic>()));
      } catch (err) {
        skipped++;
        debugPrint('[ThirdPartySource] 跳过无法解析的音源: $err');
      }
    }
    if (skipped > 0) {
      debugPrint('[ThirdPartySource] 共跳过 $skipped 条坏数据，保留 ${out.length} 条音源');
    }
    return out;
  }

  @override
  bool operator ==(Object other) => other is ThirdPartySource && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 音源管理（持久化 + 增删改查）。
///
/// 对应 Beans 的 `UnblockSourceStore`。
/// 用的是 `ValueNotifier` 而非 GetX —— 音乐模块自成一体，
/// 用最轻的通知机制即可，也避免和影视侧的 GetX 状态混淆。
class ThirdPartySourceStore {
  ThirdPartySourceStore._();
  static final ThirdPartySourceStore instance = ThirdPartySourceStore._();

  static const _key = 'music.thirdPartySources.v1';

  final List<ThirdPartySource> _items = [];

  /// 变更通知（UI 用 ValueListenableBuilder 监听）
  final revision = ValueNotifier<int>(0);

  /// **仅测试用**：把内存里的源列表清空（可给一份替身）。
  ///
  /// 为什么不直接改 `_items`：它是私有的，测试文件访问不到。
  /// 为什么需要它：`ThirdPartySourceStore` 是**单例**，测试之间会互相污染
  ///（前一个测试加的源会留在后一个测试里，导致"源被禁用 → 返回 null"
  /// 这类断言时对时错）。
  @visibleForTesting
  void resetForTest([List<ThirdPartySource>? items]) {
    _items
      ..clear()
      ..addAll(items ?? const []);
    revision.value++;
  }

  List<ThirdPartySource> get all => List.unmodifiable(_items);

  List<ThirdPartySource> get enabled =>
      _items.where((s) => s.enabled).toList();

  /// 管理页要显示的：原版把内置源排除掉，我们只显示用户导入的
  List<ThirdPartySource> get managementVisibleSources => List.unmodifiable(_items);

  bool get isEmpty => _items.isEmpty;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        _items
          ..clear()
          ..addAll(ThirdPartySource.listFromJson(raw));
      }
    } catch (e) {
      debugPrint('[MusicSource] 加载失败: $e');
    }
    revision.value++;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(_items.map((s) => s.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[MusicSource] 保存失败: $e');
    }
    revision.value++;
  }

  ThirdPartySource? byId(String id) {
    for (final s in _items) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 加入一批源；同 id 覆盖，同名跳过（避免重复导入同一份源）
  Future<int> addAll(List<ThirdPartySource> list) async {
    var added = 0;
    for (final s in list) {
      final idx = _items.indexWhere((e) => e.id == s.id);
      if (idx >= 0) {
        _items[idx] = s;
        added++;
        continue;
      }
      if (_items.any((e) => e.name == s.name)) continue;
      _items.add(s);
      added++;
    }
    await _persist();
    return added;
  }

  Future<void> upsert(ThirdPartySource s) async {
    final idx = _items.indexWhere((e) => e.id == s.id);
    if (idx >= 0) {
      _items[idx] = s;
    } else {
      _items.add(s);
    }
    await _persist();
  }

  /// 把某个源挪到**同类源（kind 相同）的第一位**。
  ///
  /// 用于「五源合一」这类要作为洛雪**首选**的源：新装时它本来就在 `_loadLxSources`
  /// 的第一位，但老设备上 `addAll` 只会**追加**到列表末尾 ⇒ 播放时排在所有洛雪源
  /// 后面。这里统一挪一次；已经在第一位就不写盘。
  Future<void> moveToSameKindFront(String id) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final item = _items[idx];
    final firstSame = _items.indexWhere((e) => e.kind == item.kind);
    if (firstSame == idx) return;
    _items.removeAt(idx);
    final target = _items.indexWhere((e) => e.kind == item.kind);
    if (target < 0) {
      _items.add(item);
    } else {
      _items.insert(target, item);
    }
    await _persist();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    _items[idx] = _items[idx].copyWith(enabled: enabled);
    await _persist();
  }

  Future<void> remove(String id) async {
    _items.removeWhere((e) => e.id == id);
    await _persist();
  }

  /// 排序：把 id 对应的音源向上（delta=-1）或向下（delta=+1）移动一格。
  /// 越界时静默忽略（已经是顶/底就没有可移动的余地）。
  Future<void> move(String id, int delta) async {
    final i = _items.indexWhere((e) => e.id == id);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= _items.length) return;
    final t = _items[i];
    _items[i] = _items[j];
    _items[j] = t;
    await _persist();
  }

  /// 按给定顺序重排**其中一部分源**（插件市场里拖动已安装插件用）。
  ///
  /// 只重排 `orderedIds` 涉及的那些源，它们占用的“槽位”不变；
  /// 其它源（用户音源、别的平台内置源）位置原样保留。
  Future<void> reorderSubset(List<String> orderedIds) async {
    final ids = orderedIds.toSet();
    final slots = <int>[];
    for (var i = 0; i < _items.length; i++) {
      if (ids.contains(_items[i].id)) slots.add(i);
    }
    if (slots.isEmpty) return;
    final byId = {for (final s in _items) s.id: s};
    final ordered = <ThirdPartySource>[];
    for (final id in orderedIds) {
      final s = byId[id];
      if (s != null) ordered.add(s);
    }
    if (ordered.length != slots.length) return; // 传进来的 id 不完整，忽略
    for (var k = 0; k < slots.length; k++) {
      _items[slots[k]] = ordered[k];
    }
    await _persist();
  }

  Future<void> removeAll() async {
    _items.clear();
    await _persist();
  }

  /// 整体替换为 [list]（内置源\"恢复默认\"用：删除旧内置源后重新注入）。
  Future<void> replaceAll(List<ThirdPartySource> list) async {
    _items
      ..clear()
      ..addAll(list);
    await _persist();
  }

  /// 导出为 JSON（方便用户备份/分享自己的源）
  String exportJson() =>
      const JsonEncoder.withIndent('  ')
          .convert(_items.map((s) => s.toJson()).toList());
}
