// lib/music/models/plugin_subscription.dart
//
// MusicFree 插件**订阅源**（registry.json）—— 2026-10-21 第三期。
//
// 支持多条订阅：
//   · 内置一条（plugins-gcore.json，首次启动种入一次，用户可删）
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

  static const String defaultId = 'default'; // 旧版内置订阅的 id，仅用于清理
  static const _key = 'music.pluginSubscriptions.v1';

  // ── 内置订阅（2026-10-21）──────────────────────────────────
  // 原来的内置地址是 github.io，设备上经常拉不到清单；换成 jsDelivr(gcore)
  // 镜像后同一份 plugins.json 能稳定访问 ⇒ 重新内置一条。
  // 只在**首次启动**写入一次：用户删掉后不会再被补回来。
  static const String builtinId = 'builtin_gcore';
  static const String builtinUrl =
      'https://gcore.jsdelivr.net/gh/hebijunge/musicfree-plugins@master/plugins-gcore.json';
  static const String _seededKey = 'music.pluginSubscriptions.seeded.v1';

  /// 旧镜像基址（GitHub Pages，国内经常不可达）
  static const String legacyGhPagesBase =
      'https://hebijunge.github.io/musicfree-plugins/';

  /// 新镜像基址（jsDelivr gcore）
  static const String jsDelivrGhBase =
      'https://gcore.jsdelivr.net/gh/hebijunge/musicfree-plugins@master/';

  /// 把**旧 github.io 镜像地址**改写成等价的 jsDelivr 地址；非旧地址返回 `null`。
  ///
  /// 路径部分原样保留，所以 `plugins-gcore.json`、`plugins/xxx.plugin.v1.js`
  /// 这类都适用。返回值 `null` 表示"这条不该动"，调用方据此决定是否写盘。
  static String? mirrorToJsDelivr(String url) {
    final u = url.trim();
    if (u.isEmpty || !u.startsWith(legacyGhPagesBase)) return null;
    final rest = u.substring(legacyGhPagesBase.length);
    if (rest.isEmpty) return null;
    final next = '$jsDelivrGhBase$rest';
    return next == u ? null : next;
  }

  final List<PluginSubscription> _items = [];
  final revision = ValueNotifier<int>(0);

  List<PluginSubscription> get all => List.unmodifiable(_items);
  List<PluginSubscription> get enabled =>
      _items.where((s) => s.enabled).toList();

  bool get isEmpty => _items.isEmpty;

  Future<void> init() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) {
              final s = PluginSubscription.fromJson(
                Map<String, dynamic>.from(e),
              );
              if (s.url.trim().isNotEmpty) {
                _items.add(s);
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[MusicSub] 读取订阅失败: $e');
    }
    // 旧版内置订阅（id=default，github.io 地址）顺手清掉
    final before = _items.length;
    _items.removeWhere((s) => s.id == defaultId);
    var dirty = _items.length != before;

    // 首次启动种入新的内置订阅（gcore 镜像）
    if (prefs != null && !(prefs.getBool(_seededKey) ?? false)) {
      if (!_items.any((s) => s.url.trim() == builtinUrl)) {
        _items.insert(
          0,
          const PluginSubscription(
            id: builtinId,
            name: 'MusicFree 插件源',
            url: builtinUrl,
          ),
        );
      }
      await prefs.setBool(_seededKey, true);
      dirty = true;
    }

    // ── 存量迁移：旧 github.io 镜像 → jsDelivr（2026-10-27）──────────
    //
    // 为什么必须有 ✗：内置地址换成 jsDelivr 之后，**只有首启用户**能种到新地址；
    // 已安装用户的 prefs 里存的是旧 github.io 地址，而 `_seededKey` 已是 true
    // ⇒ 上面的种子逻辑整段跳过 ⇒ 订阅条目还在、但拉清单长期失败（github.io
    // 在国内经常不可达），用户唯一的出路是「手动删掉订阅再加一遍」✗✗。
    // 这里把存量地址**就地改写成等价的 jsDelivr 地址** ✓：
    //   · 只改前缀匹配旧镜像的条目，用户自填的其它地址一律不动 ✓
    //   · 路径部分原样保留（plugins-gcore.json / plugins/xxx.js 都适用）✓
    //   · 幂等：已是新地址的不会再匹配，不会重复写盘 ✓
    var migrated = 0;
    for (var i = 0; i < _items.length; i++) {
      final rewritten = mirrorToJsDelivr(_items[i].url);
      if (rewritten != null) {
        _items[i] = _items[i].copyWith(url: rewritten);
        migrated++;
      }
    }
    if (migrated > 0) {
      debugPrint('[MusicSub] 已把 $migrated 条旧 github.io 订阅迁移到 jsDelivr');
      dirty = true;
    }
    revision.value++;
    if (dirty) await _persist();
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

  /// 删除订阅。
  Future<bool> remove(String id) async {
    _items.removeWhere((s) => s.id == id);
    await _persist();
    return true;
  }
}
