// lib/music/models/plugin_subscription.dart
//
// MusicFree 插件**订阅源**（registry.json）—— 2026-10-21 第三期。
//
// 之前只有一个写死的远端索引（hebijunge）。现在支持多条订阅：
//   · 默认订阅（内置，不可删，可停用）
//   · 用户添加的任意 registry.json / plugins.json 地址
//
// 订阅本身只负责"提供插件清单"；安装/更新/卸载在 `PluginMarketService`，
// 装好的插件仍然是普通的 `ThirdPartySource`（kind: musicfree），
// 所以搜索、发现页、播放兜底全部照旧生效。

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PluginSubscription {
  final String id;
  final String name;
  final String url;
  final bool enabled;

  const PluginSubscription({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
  });

  bool get isDefault => id == PluginSubscriptionStore.defaultId;

  PluginSubscription copyWith({String? name, String? url, bool? enabled}) =>
      PluginSubscription(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'enabled': enabled,
      };

  factory PluginSubscription.fromJson(Map<String, dynamic> j) =>
      PluginSubscription(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '未命名订阅').toString(),
        url: (j['url'] ?? '').toString(),
        enabled: j['enabled'] != false,
      );
}

/// 订阅源存储（SharedPreferences + ValueNotifier 通知 UI）。
class PluginSubscriptionStore {
  PluginSubscriptionStore._();
  static final PluginSubscriptionStore instance = PluginSubscriptionStore._();

  static const String defaultId = 'default';
  static const String defaultUrl =
      'https://hebijunge.github.io/musicfree-plugins/plugins.json';

  static const _key = 'music.pluginSubscriptions.v1';

  final List<PluginSubscription> _items = [];
  final revision = ValueNotifier<int>(0);

  List<PluginSubscription> get all => List.unmodifiable(_items);
  List<PluginSubscription> get enabled =>
      _items.where((s) => s.enabled).toList();

  bool get isEmpty => _items.isEmpty;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) {
              final s = PluginSubscription.fromJson(
                Map<String, dynamic>.from(e),
              );
              if (s.url.trim().isNotEmpty) _items.add(s);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[MusicSub] 读取订阅失败: $e');
    }
    // 默认订阅始终存在（用户删不掉，只可能被停用）
    if (!_items.any((s) => s.isDefault)) {
      _items.insert(
        0,
        const PluginSubscription(
          id: defaultId,
          name: 'MusicFree 插件源',
          url: defaultUrl,
        ),
      );
    }
    revision.value++;
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(_items.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[MusicSub] 保存订阅失败: $e');
    }
    revision.value++;
  }

  PluginSubscription? byId(String id) {
    for (final s in _items) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 新增订阅。返回 null = 成功；否则返回错误文案。
  Future<String?> add({required String name, required String url}) async {
    final u = url.trim();
    if (u.isEmpty) return '订阅地址不能为空';
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      return '订阅地址必须是 http(s) 链接';
    }
    if (_items.any((s) => s.url.trim() == u)) return '这个订阅已经添加过了';
    _items.add(PluginSubscription(
      id: 'sub_${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? '自定义订阅' : name.trim(),
      url: u,
    ));
    await _persist();
    return null;
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final i = _items.indexWhere((s) => s.id == id);
    if (i < 0) return;
    _items[i] = _items[i].copyWith(enabled: enabled);
    await _persist();
  }

  /// 删除订阅（默认订阅只允许停用，不允许删除）。
  Future<bool> remove(String id) async {
    if (id == defaultId) return false;
    _items.removeWhere((s) => s.id == id);
    await _persist();
    return true;
  }
}
