// lib/music/services/plugin_market_service.dart
//
// 插件市场 —— 2026-10-21 第三期。
//
// 职责：
//   · 拉取**所有启用订阅**的插件清单（registry/plugins.json）
//   · 给「插件市场」页提供：名称 / 版本 / 是否已安装 / 是否可更新
//   · 安装 / 更新 / 卸载（下载脚本 → `ThirdPartySourceStore`）
//
// 与 `BuiltinSourcesService` 的关系：
//   · 那边负责"随包内置 + 启动时自动补齐"，id 同样是 `builtin_mf_<文件名>`；
//   · 这里复用**同一个 id 规则**，所以市场里看到的"已安装"就是那边装好的，
//     不会出现两份同名插件。
//   · 版本号单独记在 `music.pluginVersions.v1`（{文件名: 版本}），用来判断
//     "可更新"——Store 里只存脚本，没有版本字段。

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/music/models/plugin_subscription.dart';
import 'package:tvbox/music/models/third_party_source.dart';
import 'package:tvbox/music/services/plugin_script_cache.dart';

/// 市场上的一个插件条目
class PluginMarketEntry {
  const PluginMarketEntry({
    required this.name,
    required this.url,
    required this.version,
    required this.subscriptionId,
  });

  final String name;
  final String url;
  final String version;
  final String subscriptionId;

  /// 插件文件名（url 末段，自带版本号）
  String get fileName {
    final seg = Uri.tryParse(url)?.pathSegments ?? const [];
    return seg.isEmpty ? 'unknown' : seg.last;
  }

  /// 与内置源一致的稳定 id（同一个插件在两边是同一个条目）
  String get sourceId => 'builtin_mf_$fileName';

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'version': version,
        'subscriptionId': subscriptionId,
      };

  factory PluginMarketEntry.fromJson(Map<String, dynamic> j) =>
      PluginMarketEntry(
        name: (j['name'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
        version: (j['version'] ?? '').toString(),
        subscriptionId: (j['subscriptionId'] ?? '').toString(),
      );
}

class PluginMarketService {
  PluginMarketService._();
  static final PluginMarketService instance = PluginMarketService._();

  static const _indexKey = 'music.pluginIndex.v1';
  static const _versionsKey = 'music.pluginVersions.v1';

  /// 单个脚本大小上限（与 BuiltinSourcesService 保持一致：agg 已到 2.9MB）
  static const int _maxScriptBytes = 4 * 1024 * 1024;

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 25),
  ));

  final List<PluginMarketEntry> _entries = [];
  Map<String, String> _versions = {};
  bool _initialized = false;

  /// 清单/安装状态变化通知
  final revision = ValueNotifier<int>(0);

  List<PluginMarketEntry> get entries => List.unmodifiable(_entries);

  bool get initialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_indexKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) {
              final entry = PluginMarketEntry.fromJson(
                Map<String, dynamic>.from(e),
              );
              if (entry.url.isNotEmpty) _entries.add(entry);
            }
          }
        }
      }
      final vraw = prefs.getString(_versionsKey);
      if (vraw != null && vraw.isNotEmpty) {
        final v = jsonDecode(vraw);
        if (v is Map) {
          _versions = v.map((k, val) => MapEntry(k.toString(), val.toString()));
        }
      }
    } catch (e) {
      debugPrint('[PluginMarket] 读取缓存失败: $e');
    }
    _initialized = true;
    revision.value++;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _indexKey,
        jsonEncode(_entries.map((e) => e.toJson()).toList()),
      );
      await prefs.setString(_versionsKey, jsonEncode(_versions));
    } catch (e) {
      debugPrint('[PluginMarket] 保存缓存失败: $e');
    }
    revision.value++;
  }

  /// 拉取所有启用订阅的清单。
  ///
  /// [only] 传某个订阅 id 时只刷新它（订阅管理页的"立即更新"）。
  /// 返回成功刷新的订阅数。
  Future<int> refresh({String? only}) async {
    final subs = PluginSubscriptionStore.instance.enabled
        .where((s) => only == null || s.id == only)
        .toList();
    if (subs.isEmpty) return 0;

    var ok = 0;
    final fetched = <PluginMarketEntry>[];

    for (final sub in subs) {
      try {
        final raw = await _fetchIndexText(sub.url);
        final list = _parseIndex(raw, sub.id);
        if (list.isEmpty) continue;
        fetched.addAll(list);
        ok++;
      } catch (e) {
        debugPrint('[PluginMarket] 拉取订阅「${sub.name}」失败: $e');
      }
    }
    if (fetched.isEmpty) return ok;

    // 同一文件名只留一条（多个订阅收录同一个插件时以后刷新的为准）
    final byFile = <String, PluginMarketEntry>{};
    for (final e in fetched) {
      if (_isBlockedName(e.name)) continue;
      byFile[e.fileName] = e;
    }

    // 保留**没刷新成功**的订阅的旧条目，避免一次网络失败把市场清空
    final refreshedIds = <String>{};
    for (final sub in subs) {
      // 只有真的返回了清单的订阅才算刷新成功
      if (fetched.any((e) => e.subscriptionId == sub.id)) {
        refreshedIds.add(sub.id);
      }
    }
    _entries
      ..removeWhere((e) => refreshedIds.contains(e.subscriptionId))
      ..addAll(byFile.values);

    // 已经装好、但没有版本记录的（内置源自动装的 / 旧版本数据）→ 把清单版本
    // 当作"已安装版本"，避免第一次打开市场时所有插件都显示"可更新"。
    for (final e in byFile.values) {
      if (isInstalled(e) && !_versions.containsKey(e.fileName)) {
        _versions[e.fileName] = e.version;
      }
    }

    await _persist();
    return ok;
  }

  /// 拉清单文本。github.io 上的清单在部分网络下拉不到（用户 2026-10-21 反馈），
  /// 同一个文件用 jsDelivr(gcore) 镜像兜底再试一次。
  Future<String> _fetchIndexText(String url) async {
    try {
      final resp = await _dio.get(url);
      return resp.data?.toString() ?? '';
    } catch (e) {
      final alt = _cdnFallback(url);
      if (alt == null) rethrow;
      final resp = await _dio.get(alt);
      return resp.data?.toString() ?? '';
    }
  }

  static const _ghPagesBase = 'https://hebijunge.github.io/musicfree-plugins/';
  static const _jsdelivrBase =
      'https://gcore.jsdelivr.net/gh/hebijunge/musicfree-plugins@master/';

  static String? _cdnFallback(String url) {
    final u = url.trim();
    if (!u.startsWith(_ghPagesBase)) return null;
    return _jsdelivrBase + u.substring(_ghPagesBase.length);
  }

  List<PluginMarketEntry> _parseIndex(String raw, String subId) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
    final List<dynamic> arr;
    if (decoded is List) {
      arr = decoded;
    } else if (decoded is Map && decoded['plugins'] is List) {
      arr = decoded['plugins'] as List;
    } else if (decoded is Map && decoded['data'] is List) {
      arr = decoded['data'] as List;
    } else {
      return const [];
    }
    final out = <PluginMarketEntry>[];
    for (final e in arr) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final url = (m['url'] ?? '').toString().trim();
      if (url.isEmpty) continue;
      out.add(PluginMarketEntry(
        name: (m['name'] ?? m['title'] ?? '未命名插件').toString(),
        url: url,
        version: (m['version'] ?? '').toString(),
        subscriptionId: subId,
      ));
    }
    return out;
  }

  /// 与内置源一致的下架规则：名称含 dj/DJ 的 DJ 类插件不展示、不安装
  static bool _isBlockedName(String name) =>
      name.toLowerCase().contains('dj');

  // ── 安装状态 ──────────────────────────────────────────────

  bool isInstalled(PluginMarketEntry e) =>
      ThirdPartySourceStore.instance.byId(e.sourceId) != null;

  bool canUpdate(PluginMarketEntry e) {
    if (!isInstalled(e)) return false;
    final have = _versions[e.fileName] ?? '';
    return e.version.isNotEmpty && have != e.version;
  }

  String installedVersion(PluginMarketEntry e) => _versions[e.fileName] ?? '';

  // ── 安装 / 更新 / 卸载 ────────────────────────────────────

  /// 下载脚本并写入 Store。返回 null = 成功；否则错误文案。
  Future<String?> install(PluginMarketEntry e) async {
    final store = ThirdPartySourceStore.instance;
    final cur = store.byId(e.sourceId);
    try {
      var script = await PluginScriptCache.instance.read(e.fileName);
      if (script == null) {
        final resp = await _dio.get(e.url);
        script = resp.data is String
            ? resp.data as String
            : (resp.data?.toString() ?? '');
        if (script.trim().isEmpty) return '下载内容为空';
        if (script.length > _maxScriptBytes) return '插件脚本过大（>4MB）';
        await PluginScriptCache.instance.write(e.fileName, script);
      }
      if (cur != null) {
        // 更新时**保留用户填的变量/开关/音质**，只换脚本
        await store.upsert(cur.copyWith(script: script));
      } else {
        await store.upsert(ThirdPartySource(
          id: e.sourceId,
          name: e.name,
          kind: 'musicfree',
          template: '',
          script: script,
          enabled: true,
          isBuiltin: true,
          updateUrl: e.url,
        ));
      }
      _versions[e.fileName] = e.version;
      await _persist();
      return null;
    } catch (err) {
      return '$err';
    }
  }

  /// 卸载（从 Store 移除 + 删文件缓存 + 清版本记录）。
  Future<void> uninstall(PluginMarketEntry e) async {
    await ThirdPartySourceStore.instance.remove(e.sourceId);
    await PluginScriptCache.instance.delete(e.fileName);
    _versions.remove(e.fileName);
    await _persist();
  }
}
