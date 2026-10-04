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
///     执行见 `lx_script_runner.dart`。
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
  });

  bool get isScript => kind == 'script';

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
      };

  /// 宽松解析：原版对每个字段都有默认值，缺字段不报错
  /// （用户导入的源格式五花八门，宽容比严格有用）
  factory ThirdPartySource.fromJson(Map<String, dynamic> j) {
    final headers = <String, String>{};
    final rawHeaders = j['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) => headers[k.toString()] = v.toString());
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

  Future<void> removeAll() async {
    _items.clear();
    await _persist();
  }

  /// 导出为 JSON（方便用户备份/分享自己的源）
  String exportJson() =>
      const JsonEncoder.withIndent('  ')
          .convert(_items.map((s) => s.toJson()).toList());
}
