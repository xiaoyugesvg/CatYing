import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「程序市场」的一条订阅：一个订阅 = 一个市场清单地址（`{"apps":[…]}`）。
///
/// 用户 2026-10-18：程序管理要支持**多个订阅 / 多个市场**，
/// 而程序页本身只显示已安装，不再把市场塞进同一个 Tab。
class MarketSubscription {
  const MarketSubscription({
    required this.id,
    required this.name,
    required this.url,
  });

  final String id;
  final String name;
  final String url;

  MarketSubscription copyWith({String? name, String? url}) =>
      MarketSubscription(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url};

  static MarketSubscription? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final url = (raw['url'] ?? '').toString().trim();
    if (url.isEmpty) return null;
    var id = (raw['id'] ?? '').toString().trim();
    if (id.isEmpty) id = 'market_${url.hashCode & 0x7fffffff}';
    final name = (raw['name'] ?? '').toString().trim();
    return MarketSubscription(
      id: id,
      name: name.isEmpty ? _hostOf(url) : name,
      url: url,
    );
  }

  static String _hostOf(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? '程序市场' : host;
  }
}

/// 市场订阅存储（prefs 持久化 + 变更通知）。
///
/// 兼容旧版本的单市场地址键 `miniapp_market_url`：首次加载时如果还没有
/// 订阅，会把它迁移成一条订阅，用户原来的市场不会丢。
class MarketSubscriptionStore extends ChangeNotifier {
  MarketSubscriptionStore._();

  static final MarketSubscriptionStore instance =
      MarketSubscriptionStore._();

  static const _key = 'miniapp_market_subs_v1';
  static const _legacyKey = 'miniapp_market_url';

  final List<MarketSubscription> _items = [];
  List<MarketSubscription> get items => List.unmodifiable(_items);

  bool _loaded = false;
  bool get isLoaded => _loaded;

  SharedPreferences? _sp;

  Future<SharedPreferences> _prefs() async =>
      _sp ??= await SharedPreferences.getInstance();

  Future<void> load() async {
    if (_loaded) return;
    try {
      final sp = await _prefs();
      final raw = sp.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            final s = MarketSubscription.tryParse(e);
            if (s != null &&
                !_items.any((x) => x.url == s.url || x.id == s.id)) {
              _items.add(s);
            }
          }
        }
      }
      // 旧版单地址迁移（只做一次；迁移后旧键保留也无副作用，会被去重）
      if (_items.isEmpty) {
        final old = (sp.getString(_legacyKey) ?? '').trim();
        if (old.isNotEmpty) {
          _items.add(MarketSubscription(
            id: 'market_${DateTime.now().millisecondsSinceEpoch}',
            name: MarketSubscription._hostOf(old),
            url: old,
          ));
          await _persist();
        }
      }
    } catch (e) {
      debugPrint('[MarketSub] 读取订阅失败: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// 按 URL 去重添加；已存在则直接返回原订阅。
  Future<MarketSubscription> add({
    required String name,
    required String url,
  }) async {
    await load();
    final u = url.trim();
    final exist = _items.where((e) => e.url == u).firstOrNull;
    if (exist != null) return exist;
    final n = name.trim();
    final sub = MarketSubscription(
      id: 'market_${DateTime.now().millisecondsSinceEpoch}_${_items.length}',
      name: n.isEmpty ? MarketSubscription._hostOf(u) : n,
      url: u,
    );
    _items.add(sub);
    await _persist();
    notifyListeners();
    return sub;
  }

  Future<void> update(
    String id, {
    String? name,
    String? url,
  }) async {
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final u = (url ?? _items[i].url).trim();
    if (u.isEmpty) return;
    final n = (name ?? _items[i].name).trim();
    _items[i] = _items[i].copyWith(
      url: u,
      name: n.isEmpty ? MarketSubscription._hostOf(u) : n,
    );
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _items.removeWhere((e) => e.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final sp = await _prefs();
      await sp.setString(
        _key,
        jsonEncode(_items.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[MarketSub] 保存订阅失败: $e');
    }
  }
}
