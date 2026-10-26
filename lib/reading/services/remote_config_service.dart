import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/reading/utils/constants.dart';
import 'package:tvbox/reading/source/global_proxy.dart';

void _log(String message) {
  if (kDebugMode) debugPrint('[RemoteConfig] $message');
}

/// 远程配置服务（单例 ChangeNotifier）
/// 同步 Windows 端 StartupCheckThread：统一管理启动检测（公告/地址配置），
/// 先读缓存（即时可用），再后台检测远程更新（不阻塞启动）。
///
/// - [copyApiUrl]：拷贝漫画 API 地址，由 ComicApi 每次请求动态读取，远程更新即时生效。
/// - [zlibraryDomain]：z-library 初始默认域名，仅 ZlibraryService 在无持久化重定向域名时使用
///   （已重定向到可用域名的用户不受影响）。
/// - [notification]：公告文本，首页弹窗展示。
///
/// zlibrary 覆盖逻辑：本地当前域名仍可用则不覆盖云端值（避免把能用的换成不确定的）。
class RemoteConfigService extends ChangeNotifier {
  RemoteConfigService._();
  static final RemoteConfigService _instance = RemoteConfigService._();
  factory RemoteConfigService() => _instance;

  static const _kCopyUrl = 'remote_copy_url';
  static const _kZlibraryDomain = 'remote_zlibrary_domain';
  static const _kNotification = 'remote_notification';

  String _copyApiUrl = CmbokConstants.defaultCopyApiUrl;
  String _zlibraryDomain =
      _hostOf(CmbokConstants.zLibraryApiUrl) ?? 'zh.zlibrary.by';
  Object?
  _cloudZlibraryUrl; // 云端 zlibrary_url 原始值（单字符串或数组），交 ZlibraryService 探测
  String _notification = '';

  String get copyApiUrl => _copyApiUrl;
  String get zlibraryDomain => _zlibraryDomain;

  /// 云端 zlibrary_url 原始值（单字符串或数组）；非 null 表示已拉到云端配置。
  /// ZlibraryService 监听本服务变化后据此归一化 + 并发探测选优。
  Object? get cloudZlibraryUrl => _cloudZlibraryUrl;
  String get notification => _notification;

  /// 初始化：先读缓存（即时可用），再后台检测远程更新（不阻塞启动）。
  /// ComicApi 动态读取 copyApiUrl、弹窗监听 notification，刷新返回后自动生效。
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedCopy = prefs.getString(_kCopyUrl);
      if (cachedCopy != null && cachedCopy.isNotEmpty) {
        _copyApiUrl = _normalizeCopyUrl(cachedCopy);
      }
      final cachedZl = prefs.getString(_kZlibraryDomain);
      if (cachedZl != null && cachedZl.isNotEmpty) {
        _zlibraryDomain = cachedZl;
      }
      _notification = prefs.getString(_kNotification) ?? '';
      _log(
        '缓存: copyApiUrl=$_copyApiUrl, zlibraryDomain=$_zlibraryDomain, '
        'notification=${_notification.isEmpty ? "(空)" : _notification}',
      );
    } catch (e) {
      _log('加载缓存失败: $e');
    }
    notifyListeners();
    _refresh(); // 后台检测更新（不阻塞启动）；动态生效（失败保留缓存）
  }

  /// 后台刷新：公告 -> 地址配置
  /// 同步 Windows 端 StartupCheckThread 执行顺序（版本检测已移除）。
  Future<void> _refresh() async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ),
    );
    // ✅ **云端配置刷新也走「网络代理」**（本轮接上 ✓）—— 与 `source_config_store.fetchRemote` 同款 ✓。
    //   ℹ️ 安全依据 ✓（**已读源码确认** ✓）：本处**无自定义适配器** ✗✓（只有两个 5s 超时 ✓）
    //     → 直接挂**安全** ✓✓
    //   · 代理**关闭** ✓ → 返回 false ✓ **一行不改** ✓（与从前完全一致 ✓✓）
    applyGlobalProxy(dio);
    // 局部新建的 Dio 必须显式释放，否则遗留 HttpClient 连接池
    try {
      final SharedPreferences prefs;
      try {
        prefs = await SharedPreferences.getInstance();
      } catch (e) {
        _log('获取 prefs 失败（保留缓存）: $e');
        return;
      }

      // 1. 公告
      final notificationChanged = await _fetchNotification(dio, prefs);

      // 2. 地址配置（与公告独立，始终执行）
      final urlChanged = await _fetchUrlConfig(dio, prefs);

      if (notificationChanged || urlChanged) {
        notifyListeners();
      }
    } finally {
      dio.close(force: true);
    }
  }

  /// 拉取 url_config.json：更新拷贝漫画地址 / z-library 默认域名。返回是否有变化。
  Future<bool> _fetchUrlConfig(Dio dio, SharedPreferences prefs) async {
    try {
      final res = await dio.get<dynamic>(CmbokConstants.urlConfigUrl);
      final cfg = _asMap(res.data);
      if (cfg == null) return false;
      var changed = false;

      final copy = (cfg['copy_url'] ?? '').toString().trim();
      if (copy.isNotEmpty) {
        final normalized = _normalizeCopyUrl(copy);
        if (normalized != _copyApiUrl) {
          _copyApiUrl = normalized;
          await prefs.setString(_kCopyUrl, normalized);
          changed = true;
          _log('copy_url 更新: $normalized');
        }
      }

      // zlibrary_url：兼容单字符串/数组，记录原始值交 ZlibraryService 归一化 + 探测选优
      final zl = cfg['zlibrary_url'];
      if (zl != null && zl != _cloudZlibraryUrl) {
        _cloudZlibraryUrl = zl;
        changed = true;
        _log('zlibrary_url 云端候选已更新: $zl');
        // 🔴 原来这里**只写内存 `_cloudZlibraryUrl`、从不落盘** ✗ ——
        // 而 `init()` 读的是 prefs 键 `_kZlibraryDomain` ✓，那个键
        // **全仓库没有任何写入方** ✗ → "跨重启记住云端下发的默认域名"
        // 这件事**完全无效且不报错** ✓（每次启动都退回硬编码 `zh.zlibrary.by` ✓）。
        // 现在把归一化后的**单个域名**落盘 ✓：数组/单串都取第一个非空项 ✓，
        // 归一化交给 `Uri.host`（裸域名时 host 为空 → 回退原串 ✓），
        // 多候选的探测选优仍由 ZlibraryService 负责 ✓，这里只负责"记住" ✓
        final first = zl is List
            ? zl
                .map((e) => e.toString().trim())
                .firstWhere((e) => e.isNotEmpty, orElse: () => '')
            : zl.toString().trim();
        if (first.isNotEmpty) {
          final host = Uri.tryParse(first)?.host ?? '';
          final domain = host.isNotEmpty ? host : first;
          await prefs.setString(_kZlibraryDomain, domain);
          _log('zlibrary 默认域名已持久化: $domain');
        }
      }
      return changed;
    } catch (e) {
      _log('url_config 拉取失败（保留缓存）: $e');
      return false;
    }
  }

  /// 拉取 notification.json：更新公告文本。返回是否有变化。
  Future<bool> _fetchNotification(Dio dio, SharedPreferences prefs) async {
    try {
      final res = await dio.get<dynamic>(CmbokConstants.notificationUrl);
      final n = _asMap(res.data)?['notification']?.toString().trim() ?? '';
      if (n != _notification) {
        _notification = n;
        await prefs.setString(_kNotification, n);
        _log('notification 更新: ${n.isEmpty ? "(空)" : n}');
        return true;
      }
      return false;
    } catch (e) {
      _log('notification 拉取失败（保留缓存）: $e');
      return false;
    }
  }

  /// 规范化拷贝漫画地址：保证末尾 /（ComicApi 拼接 ${baseUrl}api/v3/... 依赖）
  static String _normalizeCopyUrl(String url) {
    final s = url.trim();
    return s.endsWith('/') ? s : '$s/';
  }

  /// 从 url 中取 host（兼容 "zh.zlibrary.by" 与 "https://zh.zlibrary.by/"）
  static String? _hostOf(String url) {
    final s = url.trim();
    if (s.isEmpty) return null;
    var uri = Uri.tryParse(s);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    // 无 scheme 时 Uri.tryParse 取不到 host，补 https:// 再解析
    uri = Uri.tryParse('https://$s');
    return (uri != null && uri.host.isNotEmpty) ? uri.host : null;
  }

  /// 容错解析为 Map：Dio 默认按 application/json 自动解析为 Map，
  /// 个别情况下返回 String，则再 jsonDecode。
  static Map? _asMap(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.isNotEmpty) {
      try {
        final d = jsonDecode(data);
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return null;
  }
}
