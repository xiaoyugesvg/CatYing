import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/services/api_config.dart';
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
    this.headers = const {},
  });

  final String id;
  final String name;
  final String url;
  final ParseLineSource source;

  /// 请求头（来自订阅 `parses[].ext.header`）。
  ///
  /// 不少解析接口会**按 UA 决定给不给地址**（例如「盘古」那条带的是
  /// Android Chrome 的 UA，用默认 UA 请求会直接回一个空白页）。
  /// 原来 `_fromParses` 把 `ext` 整个丢掉了，所以这类线路"存在但永远失败"。
  final Map<String, String> headers;

  bool get isCustom => source == ParseLineSource.custom;

  String apply(String rawUrl) {
    if (url.contains('{url}')) {
      return url.replaceAll('{url}', Uri.encodeComponent(rawUrl));
    }
    return '$url$rawUrl';
  }

  /// 同上，但把原始地址**整体 URL 编码**后再拼。
  ///
  /// 为什么两种都要试：TVBox 各分支对 `type=0` 的约定并不统一 ——
  /// 有的把原始地址原样拼（`?url=https://a/b?c=1&d=2`，里面的 `&`
  /// 会被当成新参数，接口只拿到半截地址）；有的要求编码。
  /// 解析时先试原样、失败再试编码，两种接口都能覆盖。
  String applyEncoded(String rawUrl) {
    final enc = Uri.encodeComponent(rawUrl);
    if (url.contains('{url}')) {
      return url.replaceAll('{url}', enc);
    }
    return '$url$enc';
  }

  ParseLine copyWith({String? name, String? url}) => ParseLine(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        source: source,
        headers: headers,
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

  /// 本次进程是否**真的**从订阅拿到过线路（[ensureSyncedFromConfig] 的去重标记）。
  ///
  /// ⚠️ 只在"拿到了非空结果"时才置位。配置还没加载完时 `readParses()` 会
  /// 返回空列表，如果那也算同步过，之后就永远不会再试 —— 表现就是用户看到的
  /// 「当前：自动（暂无线路）」一直不变（2026-10-30 截图）。
  bool _syncedFromConfig = false;

  /// 上次尝试同步的时间（节流用，避免页面反复重建时连续打网络）
  DateTime _lastSyncAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 上一次同步失败的原因（空 = 没失败）。设置页用它如实告诉用户
  /// "为什么一条线路都没有"，而不是干巴巴显示 0 条。
  String _syncError = '';
  String get syncError => _syncError;

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

  /// **确保订阅线路已经同步过一次**（进程内只做一次）。
  ///
  /// ── 为什么需要它（2026-10-30 修）────────────────────────────────
  /// 用户截图：「订阅线路 0 条」，而订阅配置里实际有 **56 条** `parses`。
  ///
  /// 根因：`syncFromParses` 原来只有两个调用点 ——
  ///   ① 打开「解析线路」设置页；
  ///   ② 真的去解析一次播放地址（`detail/controller._sniffPageForMedia`）。
  /// 而 `load()` 是在 `Get.put<ApiConfig>` **之前**跑的（见 `main.dart`），
  /// 那时读不到配置，只能恢复"选中项 + 自定义线路"。
  /// ⇒ 用户一进播放设置看到的就是 0 条，直到他恰好点开过解析线路页。
  ///
  /// 现在改成**懒同步**：任何要展示线路的地方先调一次这里。
  Future<void> ensureSyncedFromConfig() async {
    if (_syncedFromConfig) return;
    // 10 秒节流：没拿到线路时允许重试（配置可能还在下载），但不能每次
    // 重建都打一次网络。
    if (DateTime.now().difference(_lastSyncAttempt) <
        const Duration(seconds: 10)) {
      return;
    }
    await refreshFromConfig();
  }

  /// 强制重新读一次订阅 `parses`（设置页的"刷新"、切源后都要用）。
  Future<void> refreshFromConfig() async {
    _lastSyncAttempt = DateTime.now();
    try {
      final parses = await ApiConfig.instance.readParses();
      _syncError = '';
      // 空结果也照实覆盖（订阅里确实没有 parses 时要显示 0 条），
      // 但**不置 `_syncedFromConfig`**，这样下次进页面还会再试一次。
      syncFromParses(parses);
    } catch (e) {
      _syncError = '$e';
      AppLog.instance.w('[ParseLines] 读取订阅解析线路失败: $e');
      notifyListeners();
    }
  }

  /// 用订阅配置里的 `parses` 覆盖订阅线路（配置一换就整体替换）
  void syncFromParses(List<Map<String, dynamic>> parses) {
    _syncedFromConfig = parses.isNotEmpty;
    _subscription = _fromParses(parses);
    if (_selectedId.isNotEmpty && selected == null) {
      _selectedId = '';
    }
    AppLog.instance.log('[ParseLines] 订阅解析线路 ${_subscription.length} 条');
    notifyListeners();
  }

  /// TVBox `parses` → 线路
  ///
  /// 只跳过 `type=web`（"用内置浏览器打开网页"，不是解析接口，走 GET 模板
  /// 拿不到媒体地址）。
  ///
  /// ⚠️ 2026-10-30 修：原来连 `type=0` / `type=1` 一起跳过，导致大量订阅
  /// 的解析线路**全被吃掉**、页面显示「订阅线路」整组不出现（用户：
  /// 「解析线路没有导入订阅里面的解析线路吗？」）。
  /// 各 TVBox 分支对 0/1/2/3/4 的定义并不统一（同一份配置在不同分支里
  /// 0 和 1 经常是"普通解析 / json 解析"互换），而本 App 的
  /// `MediaResolver._fromParseLine` 只做「拼模板 → GET → 从响应里取 url」，
  /// **根本不看 type**，所以没有理由按 type 过滤。只保留 `web` 这一条硬排除。
  static List<ParseLine> _fromParses(List<Map<String, dynamic>> parses) {
    final out = <ParseLine>[];
    for (var i = 0; i < parses.length; i++) {
      final p = parses[i];
      final url = (p['url'] ?? '').toString().trim();
      if (url.isEmpty || !url.startsWith('http')) continue;
      final type = (p['type'] ?? '').toString().trim().toLowerCase();
      if (type == 'web') continue;
      final name = (p['name'] ?? '').toString().trim();
      out.add(
        ParseLine(
          id: 'sub:$i',
          name: name.isEmpty ? '解析 ${i + 1}' : name,
          url: url,
          headers: _headersOf(p['ext']),
        ),
      );
    }
    return out;
  }

  /// 从 `parses[].ext` 里取请求头。
  ///
  /// TVBox 的写法是 `{"ext": {"header": {"user-agent": "..."}}}`，
  /// 也有直接把 `ext` 写成 header map 的变体，两种都兜一下。
  static Map<String, String> _headersOf(Object? ext) {
    if (ext is! Map) return const {};
    final raw = ext['header'] is Map ? ext['header'] as Map : ext;
    final out = <String, String>{};
    raw.forEach((k, v) {
      final key = k.toString().trim();
      final val = v?.toString().trim() ?? '';
      if (key.isNotEmpty && val.isNotEmpty) out[key] = val;
    });
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
