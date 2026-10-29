import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/services/app_log.dart';

/// 一条「解析线路」——把网页播放页 / 解析接口地址变成媒体直链的服务。
///
/// 两个来源（用户 2026-10-29：「解析线路就是内置或是订阅里面的」）：
///   · [ParseLineSource.subscription]：影视**订阅配置**里的 `parses` 数组
///     （TVBox 标准字段 `{name, type, url, ext}`）。配置一换就跟着换；
///   · [ParseLineSource.custom]：用户自己加/改的（持久化在本地）。
///
/// url 模板：含 `{url}` ⇒ 用编码后的原始地址替换；
/// 不含 ⇒ 按 TVBox 惯例把原始地址直接拼在模板后面。
class ParseLine {
  const ParseLine({
    required this.id,
    required this.name,
    required this.url,
    this.source = ParseLineSource.subscription,
  });

  final String id;
  final String name;
  final String url;
  final ParseLineSource source;

  bool get isCustom => source == ParseLineSource.custom;

  String apply(String rawUrl) {
    if (url.contains('{url}')) {
      return url.replaceAll('{url}', Uri.encodeComponent(rawUrl));
    }
    return '$url$rawUrl';
  }

  ParseLine copyWith({String? name, String? url}) => ParseLine(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        source: source,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
      };

  factory ParseLine.fromJson(Map<String, dynamic> j) => ParseLine(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
        source: ParseLineSource.custom,
      );
}

enum ParseLineSource {
  /// 订阅配置 `parses` 里的（只读）
  subscription,

  /// 用户自己加的（可改可删）
  custom,
}

/// 解析线路仓库。
///
/// 订阅线路不落盘（配置换了就该跟着换）；自定义线路 + 选中项落盘。
class ParseLineStore extends ChangeNotifier {
  ParseLineStore._();
  static final ParseLineStore instance = ParseLineStore._();

  static const String _kCustom = 'parse_lines_custom_v1';
  static const String _kSelected = 'parse_line_selected_v1';

  List<ParseLine> _subscription = const [];
  List<ParseLine> _custom = const [];

  /// 选中线路 id：'' = 自动（按顺序全试）
  String _selectedId = '';
  bool _loaded = false;

  bool get loaded => _loaded;
  String get selectedId => _selectedId;

  /// 订阅线路（只读）
  List<ParseLine> get subscriptionLines => List.unmodifiable(_subscription);

  /// 自定义线路（可改可删）
  List<ParseLine> get customLines => List.unmodifiable(_custom);

  /// 全部线路（订阅在前、自定义在后）
  List<ParseLine> get lines => [..._subscription, ..._custom];

  bool get isEmpty => lines.isEmpty;

  ParseLine? get selected {
    if (_selectedId.isEmpty) return null;
    for (final l in lines) {
      if (l.id == _selectedId) return l;
    }
    return null;
  }

  String get selectedName => selected?.name ?? '自动';

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _selectedId = prefs.getString(_kSelected) ?? '';
      final raw = prefs.getString(_kCustom);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          _custom = [
            for (final e in list)
              if (e is Map)
                ParseLine.fromJson(Map<String, dynamic>.from(e)),
          ].where((l) => l.url.isNotEmpty).toList();
        }
      }
    } catch (e) {
      AppLog.instance.w('[ParseLines] 读取失败: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// 用订阅配置里的 `parses` 覆盖订阅线路（配置一换就整体替换）
  void syncFromParses(List<Map<String, dynamic>> parses) {
    _subscription = _fromParses(parses);
    if (_selectedId.isNotEmpty && selected == null) {
      _selectedId = '';
    }
    AppLog.instance.log('[ParseLines] 订阅解析线路 ${_subscription.length} 条');
    notifyListeners();
  }

  /// TVBox `parses` → 线路
  ///
  /// 跳过 `type=web`（"用内置浏览器打开网页"，不是解析接口）
  /// 和 `type=0/1`（聚合类型，按"GET 模板找媒体地址"处理不了）。
  static List<ParseLine> _fromParses(List<Map<String, dynamic>> parses) {
    final out = <ParseLine>[];
    for (var i = 0; i < parses.length; i++) {
      final p = parses[i];
      final url = (p['url'] ?? '').toString().trim();
      if (url.isEmpty || !url.startsWith('http')) continue;
      final type = (p['type'] ?? '').toString().trim().toLowerCase();
      if (type == 'web' || type == '0' || type == '1') continue;
      final name = (p['name'] ?? '').toString().trim();
      out.add(
        ParseLine(
          id: 'sub:$i',
          name: name.isEmpty ? '解析 ${i + 1}' : name,
          url: url,
        ),
      );
    }
    return out;
  }

  Future<void> setSelected(String id) async {
    _selectedId = id;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (id.isEmpty) {
        await prefs.remove(_kSelected);
      } else {
        await prefs.setString(_kSelected, id);
      }
    } catch (e) {
      AppLog.instance.w('[ParseLines] 保存选中项失败: $e');
    }
  }

  /// 新增自定义线路
  Future<void> addCustom(String name, String url) async {
    final u = url.trim();
    if (u.isEmpty) return;
    _custom = [
      ..._custom,
      ParseLine(
        id: 'c:${DateTime.now().microsecondsSinceEpoch}',
        name: name.trim().isEmpty ? '自定义解析' : name.trim(),
        url: u,
        source: ParseLineSource.custom,
      ),
    ];
    await _saveCustom();
    notifyListeners();
  }

  /// 修改自定义线路（订阅线路不可改）
  Future<void> updateCustom(String id, String name, String url) async {
    final u = url.trim();
    if (u.isEmpty) return;
    _custom = [
      for (final l in _custom)
        if (l.id == id)
          l.copyWith(
            name: name.trim().isEmpty ? l.name : name.trim(),
            url: u,
          )
        else
          l,
    ];
    await _saveCustom();
    notifyListeners();
  }

  /// 删除自定义线路（订阅线路不可删）
  Future<void> removeCustom(String id) async {
    _custom = _custom.where((l) => l.id != id).toList();
    if (_selectedId == id) {
      _selectedId = '';
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_kSelected);
      } catch (_) {}
    }
    await _saveCustom();
    notifyListeners();
  }

  Future<void> _saveCustom() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kCustom,
        jsonEncode([for (final l in _custom) l.toJson()]),
      );
    } catch (e) {
      AppLog.instance.w('[ParseLines] 保存自定义线路失败: $e');
    }
  }

  /// 尝试顺序：选中那条排最前，其余按原顺序
  List<ParseLine> get attemptOrder {
    final list = lines;
    if (_selectedId.isEmpty) return list;
    final picked = list.where((l) => l.id == _selectedId).toList();
    if (picked.isEmpty) return list;
    return [
      ...picked,
      ...list.where((l) => l.id != _selectedId),
    ];
  }
}
