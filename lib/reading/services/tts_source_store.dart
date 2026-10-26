import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/reading/models/tts_source.dart';

/// 朗读源仓库。
///
/// ── 两条存储路径（截图里写明的要求）──────────────────────────
/// 截图原话：
///   "API Key 存在系统密钥库里，不写进配置、也不进备份。"
///   "换机后需要重填一次。"
///
/// 所以：
///   · **源配置**（名称/地址/模型/音色/调优）→ SharedPreferences
///   · **API Key** → 单独的存储键，**不随源配置一起序列化**
///
/// ⚠️ 这里要说清一个现实：真正的「系统密钥库」（iOS Keychain）需要
/// `flutter_secure_storage` 插件。当前项目**没有装**。所以这一版把
/// Key 存在**独立的 SharedPreferences 键**里 —— 它做到了"不进配置、
/// 不进备份"（因为导出/备份只读源配置那两个键），但**没有做到系统级
/// 加密**。装上 flutter_secure_storage 后把 [_kKeyPrefix] 那两个方法
/// 换成 Keychain 读写即可，其它代码不用动。
class TtsSourceStore extends ChangeNotifier {
  TtsSourceStore._();
  static final TtsSourceStore instance = TtsSourceStore._();

  static const _kListKey = 'tts_sources_v1';
  /// 当前正在使用的朗读源 id（空 = 用系统朗读）
  static const _kActiveKey = 'tts_active_source_v1';
  /// API Key 单独存，前缀 + 源 id
  static const _kKeyPrefix = 'tts_api_key_';

  final List<TtsSource> _items = [];
  bool _loaded = false;
  String _activeId = '';

  List<TtsSource> get all => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;

  /// 当前使用中的朗读源（空 = 系统朗读兜底）
  String get activeId => _activeId;
  TtsSource? get active {
    if (_activeId.isEmpty) return null;
    for (final s in _items) {
      if (s.id == _activeId) return s;
    }
    return null;
  }

  Future<void> init() async {
    if (_loaded) return;
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kListKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final arr = jsonDecode(raw) as List;
        _items
          ..clear()
          ..addAll(arr.map((e) =>
              TtsSource.fromJson(Map<String, dynamic>.from(e as Map))));
      } catch (_) {
        // 配置损坏时不要崩 —— 当作没有源，用户重新加
      }
    }
    _activeId = sp.getString(_kActiveKey) ?? '';
    _loaded = true;
    notifyListeners();
  }

  /// 把某个朗读源设为「当前使用」（空字符串 = 回到系统朗读）
  Future<void> setActive(String id) async {
    _activeId = id;
    final sp = await SharedPreferences.getInstance();
    if (id.isEmpty) {
      await sp.remove(_kActiveKey);
    } else {
      await sp.setString(_kActiveKey, id);
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _kListKey,
      jsonEncode(_items.map((e) => e.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<void> upsert(TtsSource s, {String? apiKey}) async {
    final i = _items.indexWhere((e) => e.id == s.id);
    if (i < 0) {
      _items.add(s);
    } else {
      _items[i] = s;
    }
    await _persist();
    // Key 单独写（null 表示"这次不改 Key"）
    if (apiKey != null) await setApiKey(s.id, apiKey);
  }

  Future<void> remove(String id) async {
    _items.removeWhere((e) => e.id == id);
    if (_activeId == id) _activeId = '';
    await _persist();
    final sp = await SharedPreferences.getInstance();
    await sp.remove('$_kKeyPrefix$id');
    if (_activeId.isEmpty) await sp.remove(_kActiveKey);
  }

  /// 读 API Key（不在源配置里 —— 见类文档）
  Future<String> apiKey(String id) async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString('$_kKeyPrefix$id') ?? '';
  }

  Future<void> setApiKey(String id, String key) async {
    final sp = await SharedPreferences.getInstance();
    if (key.trim().isEmpty) {
      await sp.remove('$_kKeyPrefix$id');
    } else {
      await sp.setString('$_kKeyPrefix$id', key.trim());
    }
  }

  /// 导出**源配置**（不含 API Key，可安全备份/分享）
  String exportJson() =>
      const JsonEncoder.withIndent('  ').convert(_items.map((e) => e.toJson()).toList());

  /// 从 JSON 导入（单条或数组）。解析后的引擎会带「更新」徽标覆盖同名条目。
  Future<({int added, int updated, String? error})> importJson(String text) async {
    try {
      final decoded = jsonDecode(text);
      final list = decoded is List ? decoded : [decoded];
      var added = 0, updated = 0;
      for (final e in list) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        if (!m.containsKey('type')) m['type'] = 'network';
        if (!m.containsKey('name')) m['name'] = '导入的引擎';
        if (!m.containsKey('id')) {
          m['id'] = DateTime.now().millisecondsSinceEpoch.toString() +
              added.toString();
        }
        final s = TtsSource.fromJson(m);
        final i = _items.indexWhere((x) => x.id == s.id);
        if (i < 0) {
          _items.add(s);
          added++;
        } else {
          _items[i] = s;
          updated++;
        }
      }
      await _persist();
      return (added: added, updated: updated, error: null);
    } catch (e) {
      return (added: 0, updated: 0, error: '$e');
    }
  }
}
