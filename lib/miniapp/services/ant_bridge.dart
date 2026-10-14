import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../common/theme.dart';
import '../../models/cache_store.dart';
import '../../models/movie_sort.dart';
import '../../models/source_bean.dart';
import '../../models/vod_info.dart';
import '../../services/api_config.dart';
import '../../services/app_log.dart';
import '../../services/play_route.dart';
import '../../services/parse_service.dart';
import '../../services/source_service.dart';
import '../../services/spider_service.dart';
import '../../widgets/app_toast.dart';
import '../../pages/play/sniff_player_page.dart';
import '../pages/mini_app_player_page.dart';

/// 官方 ant JSAPI SDK v4 桥（Dart 侧实现）。
///
/// 对齐 ant-video 官方契约：
/// `mini-app/.claude/skills/miniapp-dev/references/jsapi.md`
///
/// - manifest 声明了 `permissions` 才放行对应 API（缺省一律 PERMISSION_DENIED）
/// - `ant.request` 返回**原始字符串**（不是解码后的 JSON），支持
///   method/headers/body/timeout/responseType/followRedirects，拒绝内网地址
/// - `ant.source.home(siteKey)` 单参，返回 `{classes, list}`
/// - `ant.source.detail` 返回单个 vod 对象
/// - `vod_play_from / vod_play_url` 返回**数组**（官方 v4 形状）
/// - `ant.player.open` 支持 headers 与 parse/jx 线路判断
class AntBridge {
  AntBridge._();

  static const channelName = 'AntBridge';
  static const int sdkVersion = 4;

  /// 当前小程序 appId（storage 分区前缀用）
  static String appId = 'app';

  /// manifest permissions 权限门禁
  static Set<String> permissions = <String>{};

  /// 由小程序页面在加载时调用（读 manifest.json 后配置）。
  static void configure({
    required String appId,
    List<String> permissions = const [],
  }) {
    AntBridge.appId = appId.isEmpty ? 'app' : appId;
    AntBridge.permissions = permissions.toSet();
  }

  /// 注入到 WebView 的 window.ant（SDK v4）。页面每次加载完成都注入。
  static const String injectScript = r'''
(function () {
  if (window.__antInjected) return;
  window.__antInjected = true;
  window.__antSeq = 0;
  window.__antCbs = {};

  window.__antResolve = function (id, data) {
    var cb = window.__antCbs[id];
    if (cb) { cb(null, data); delete window.__antCbs[id]; }
  };
  window.__antReject = function (id, err) {
    var cb = window.__antCbs[id];
    if (cb) { cb(err, null); delete window.__antCbs[id]; }
  };

  function antCall(method, args) {
    return new Promise(function (resolve, reject) {
      var id = ++window.__antSeq;
      window.__antCbs[id] = function (err, data) {
        if (err) {
          var e = new Error((err && err.message) || String(err));
          e.code = (err && err.code) || 'UNKNOWN_API';
          reject(e);
        } else {
          resolve(data);
        }
      };
      try {
        window.AntBridge.postMessage(
          JSON.stringify({ id: id, method: method, args: args || {} })
        );
      } catch (e) {
        delete window.__antCbs[id];
        reject(e);
      }
    });
  }

  // 事件总线（player.close / player.stateChange 宿主当前不主动推送，
  // 注册调用可用，等宿主扩展）
  var listeners = {};
  function emit(name, data) {
    (listeners[name] || []).slice().forEach(function (fn) {
      try { fn(data); } catch (e) {}
    });
  }
  function on(name, fn) {
    (listeners[name] = listeners[name] || []).push(fn);
    return function () { off(name, fn); };
  }
  function once(name, fn) {
    function wrap(d) { off(name, wrap); fn(d); }
    return on(name, wrap);
  }
  function off(name, fn) {
    if (fn) {
      listeners[name] = (listeners[name] || []).filter(function (f) { return f !== fn; });
    } else {
      delete listeners[name];
    }
  }

  window.ant = {
    version: 4,
    env: {
      getSystemInfo: function () { return antCall('env.getSystemInfo', {}); }
    },
    log: function (m) {
      try { console.log('[ant]', m); } catch (e) {}
      return Promise.resolve();
    },

    // ── 网络（走宿主 Dio，不受 CORS 限制）──
    request: function (o) { return antCall('request', o || {}); },
    requestJson: function (o) { return antCall('requestJson', o || {}); },
    requestBytes: function (o) {
      return antCall('request', Object.assign({}, o || {}, { responseType: 'base64' }))
        .then(function (res) {
          var raw = (res && res.data) || '';
          if (!window.atob) throw new Error('atob 不可用');
          var bin = window.atob(raw);
          var bytes = new Uint8Array(bin.length);
          for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          return bytes;
        });
    },
    base64ToBytes: function (b64) {
      var bin = window.atob(String(b64 || ''));
      var bytes = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      return bytes;
    },

    // ── 存储（按 appId 隔离）──
    storage: {
      get: function (k, d) { return antCall('storage.get', { key: k, def: d }); },
      set: function (k, v) { return antCall('storage.set', { key: k, value: v }); },
      getJSON: function (k, d) { return antCall('storage.getJSON', { key: k, def: d }); },
      setJSON: function (k, v) { return antCall('storage.setJSON', { key: k, value: v }); },
      remove: function (k) { return antCall('storage.remove', { key: k }); },
      clear: function () { return antCall('storage.clear', {}); },
      keys: function () { return antCall('storage.keys', {}); }
    },

    // ── UI ──
    ui: {
      toast: function (m) { return antCall('ui.toast', { message: m }); },
      loading: function (m) { return antCall('ui.loading', { message: m }); },
      hideLoading: function () { return antCall('ui.hideLoading', {}); },
      confirm: function (o) { return antCall('ui.confirm', o || {}); },
      actionSheet: function (names) { return antCall('ui.actionSheet', { items: names || [] }); }
    },
    clipboard: {
      set: function (t) { return antCall('clipboard.set', { text: t }); },
      get: function () { return antCall('clipboard.get', {}); }
    },

    // ── 导航（JS 侧同源跳转）──
    navigateTo: function (url) {
      if (url) { try { window.location.href = url; } catch (e) {} }
      return Promise.resolve();
    },
    redirectTo: function (url) {
      if (url) { try { window.location.replace(url); } catch (e) {} }
      return Promise.resolve();
    },
    navigateBack: function () {
      try { if (window.history.length > 1) window.history.back(); } catch (e) {}
      return Promise.resolve({ moved: true });
    },
    // 退出当前网页：走宿主桥（原来只 Promise.resolve()，点了毫无反应）
    exitMiniApp: function () { return antCall('exitMiniApp', {}); },

    // ── 反向服务（宿主暂不提供 loopback，注册 handler 备用）──
    serve: function (handler) { window.__antServe = handler; return Promise.resolve(); },

    // ── 事件与生命周期 ──
    on: function (name, fn) { return on(name, fn); },
    once: function (name, fn) { return once(name, fn); },
    off: function (name, fn) { off(name, fn); },
    onShow: function (fn) { on('app.show', fn); return Promise.resolve(); },
    onHide: function (fn) { on('app.hide', fn); return Promise.resolve(); },

    // ── TV 遥控（占位）──
    tv: { onKey: function (h) { window.__antTvKey = h; return Promise.resolve(); } },

    // ── 播放器 ──
    player: {
      open: function (o) { return antCall('player.open', o || {}); },
      getState: function () { return antCall('player.getState', {}); },
      onStateChange: function (fn) { return on('player.stateChange', fn); },
      onClose: function (fn) { return on('player.close', fn); }
    },

    // ── 采集源（宿主已配置的视频源）──
    source: {
      list: function () { return antCall('source.list', {}); },
      home: function (siteKey) { return antCall('source.home', { siteKey: siteKey }); },
      category: function (o) { return antCall('source.category', o || {}); },
      search: function (o) { return antCall('source.search', o || {}); },
      detail: function (o) { return antCall('source.detail', o || {}); },
      play: function (o) { return antCall('source.play', o || {}); },
      // 最近观看（含进度）：{list:[{vod_*,sourceKey,flag,episodeIndex,progressSeconds}]}
      recent: function (o) { return antCall('source.recent', o || {}); }
    }
  };

  // 页面加载完成 → 触发 app.show（模拟 onShow）
  setTimeout(function () { emit('app.show', {}); }, 0);
})();
''';

  /// WebView channel 消息入口。返回统一 `{id, ok, result|error}` JSON 字符串。
  static Future<String> handleMessage(String raw) async {
    Map<String, dynamic> req;
    try {
      req = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      req = <String, dynamic>{};
    }
    final id = req['id'];
    final method = (req['method'] ?? '').toString();
    final argsRaw = req['args'];
    final args = argsRaw is Map
        ? Map<String, dynamic>.from(argsRaw)
        : <String, dynamic>{};
    try {
      _checkPermission(method);
      final result = await _dispatch(method, args);
      return jsonEncode(<String, dynamic>{'id': id, 'ok': true, 'result': result});
    } on AntError catch (e) {
      return jsonEncode(<String, dynamic>{
        'id': id,
        'ok': false,
        'error': {'code': e.code, 'message': e.message},
      });
    } catch (e) {
      return jsonEncode(<String, dynamic>{
        'id': id,
        'ok': false,
        'error': {'code': 'INTERNAL_ERROR', 'message': '$e'},
      });
    }
  }

  // ────────────────────────── 权限门禁 ──────────────────────────

  /// 方法 → 所需权限。返回 null 表示无需权限。
  static String? _requiredPermission(String method) {
    if (method.startsWith('ui.') || method.startsWith('clipboard.')) return 'ui';
    if (method.startsWith('storage.')) return 'storage';
    if (method.startsWith('request')) return 'network';
    if (method.startsWith('player.')) return 'player';
    if (method.startsWith('source.')) return 'source';
    return null;
  }

  static void _checkPermission(String method) {
    final perm = _requiredPermission(method);
    if (perm == null) return;
    if (!permissions.contains(perm)) {
      throw AntError('PERMISSION_DENIED',
          '未声明 $perm 权限（manifest.json 的 permissions 里补上即可）');
    }
  }

  // ────────────────────────── 分发 ──────────────────────────

  static Future<Object?> _dispatch(String method, Map<String, dynamic> args) async {
    switch (method) {
      case 'env.getSystemInfo':
        return _envInfo();
      case 'request':
        return _request(args, json: false);
      case 'requestJson':
        return _request(args, json: true);
      case 'storage.get':
      case 'storage.set':
      case 'storage.getJSON':
      case 'storage.setJSON':
      case 'storage.remove':
      case 'storage.clear':
      case 'storage.keys':
        return _storage(method, args);
      case 'ui.toast':
        AppToast.message((args['message'] ?? '').toString());
        return null;
      case 'ui.loading':
        return _uiLoading((args['message'] ?? '加载中…').toString());
      case 'ui.hideLoading':
        return _uiHideLoading();
      case 'ui.confirm':
        return _uiConfirm(args);
      case 'ui.actionSheet':
        return _uiActionSheet(args);
      case 'clipboard.set':
        await Clipboard.setData(ClipboardData(text: (args['text'] ?? '').toString()));
        return null;
      case 'clipboard.get':
        final data = await Clipboard.getData('text/plain');
        return data?.text ?? '';
      case 'player.open':
        return _playerOpen(args);
      case 'player.getState':
        return {'active': false};
      case 'source.list':
        return _sourceList();
      case 'source.home':
        return _sourceHome(args);
      case 'source.category':
        return _sourceCategory(args);
      case 'source.search':
        return _sourceSearch(args);
      case 'source.detail':
        return _sourceDetail(args);
      case 'source.play':
        return _sourcePlay(args);
      case 'source.recent':
        return _sourceRecent(args);
      case 'exitMiniApp':
        return _exitMiniApp();
      default:
        throw AntError('UNKNOWN_API', '未知方法 $method');
    }
  }

  // ────────────────────────── env ──────────────────────────

  /// App 版本号 / 构建号 —— **必须与 `pubspec.yaml` 的 `version:` 保持一致**。
  ///
  /// 为什么写成常量：Dart 运行时读不到 pubspec，本项目也没引入 `package_info_plus`。
  /// 改版本号时两处一起改（`version: 1.0.0+1` ⇒ `'1.0.0'` / `1`）。
  static const String kAppVersion = '1.0.0';
  static const int kAppBuildNumber = 1;

  /// 真实设备与应用信息。
  ///
  /// ⚠️ 2026-10-14 补：原来是**硬编码空值**（`osVersion: ''`、`appVersion: ''`、
  ///   `devMode: false`）⇒ 网页想"按 App 版本 / 系统版本做适配"完全没法做
  ///   （例如只在某个版本以上才用的能力无法判断）。现在给真实值。
  static Map<String, dynamic> _envInfo() => {
        'platform': Platform.isIOS
            ? 'ios'
            : (Platform.isAndroid ? 'android' : Platform.operatingSystem),
        'osVersion': Platform.operatingSystemVersion,
        'isTV': false, // 本项目是手机/平板形态（TV 遥控尚未接入）
        'appId': appId,
        'appName': '猫影',
        'appVersion': kAppVersion,
        'appVersionCode': kAppBuildNumber,
        'devMode': kDebugMode,
        'permissions': permissions.toList(),
        'sdkVersion': sdkVersion,
      };

  // ────────────────────────── request ──────────────────────────

  static bool _isForbiddenHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h == '::1' || h == '0.0.0.0' || h == '[::1]') return true;
    if (RegExp(r'^127\.').hasMatch(h)) return true;
    if (RegExp(r'^10\.').hasMatch(h)) return true;
    if (RegExp(r'^192\.168\.').hasMatch(h)) return true;
    if (RegExp(r'^169\.254\.').hasMatch(h)) return true;
    if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(h)) return true;
    if (h.startsWith('fe80')) return true;
    if (h.startsWith('fc') && h.contains(':')) return true;
    return false;
  }

  static Future<Object?> _request(Map<String, dynamic> args,
      {required bool json}) async {
    final url = (args['url'] ?? '').toString();
    if (url.isEmpty) throw AntError('INVALID_PARAMS', 'request: url 必填');
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw AntError('INVALID_URL', '只允许 http/https');
    }
    if (_isForbiddenHost(uri.host)) {
      throw AntError('FORBIDDEN_HOST', '回环/内网地址被禁止');
    }
    final method = (args['method'] ?? 'GET').toString().toUpperCase();
    final responseType = (args['responseType'] ?? 'text').toString();
    final timeoutMs = ((args['timeout'] as num?)?.toInt() ?? 15000).clamp(1000, 30000);
    final followRedirects = args['followRedirects'] ?? true;
    final headers = args['headers'] is Map
        ? (args['headers'] as Map)
            .map((k, v) => MapEntry(k.toString(), v.toString()))
        : const <String, String>{};
    final body = args['data'];

    Dio? client; // 见 finally：局部 Dio 必须显式释放
    try {
      final dio = client = Dio(BaseOptions(
        connectTimeout: Duration(milliseconds: timeoutMs),
        receiveTimeout: Duration(milliseconds: timeoutMs),
        followRedirects: followRedirects == true,
        responseType: responseType == 'base64'
            ? ResponseType.bytes
            : ResponseType.plain,
        headers: {'User-Agent': 'okhttp/4.12.0', ...headers},
      ));
      final resp = await dio.request<dynamic>(
        url,
        data: body is Map ? jsonEncode(body) : body,
        options: Options(method: method),
      );

      final statusCode = resp.statusCode ?? 200;
      if (json && (statusCode < 200 || statusCode >= 300)) {
        throw AntError('REQUEST_FAILED', 'HTTP $statusCode');
      }

      final payload = resp.data;
      Object? data;
      if (responseType == 'base64') {
        final bytes = payload is List<int>
            ? payload
            : (payload is String ? utf8.encode(payload) : const <int>[]);
        data = base64Encode(bytes);
      } else if (payload is String) {
        data = payload;
      } else if (payload != null) {
        data = jsonEncode(payload);
      } else {
        data = '';
      }

      if (json) {
        try {
          return jsonDecode(data as String);
        } catch (_) {
          throw AntError('REQUEST_FAILED', '响应不是合法 JSON');
        }
      }

      return {
        'statusCode': statusCode,
        'headers': _headersToMap(resp.headers),
        'data': data,
        'responseType': responseType,
        'url': resp.realUri.toString(),
      };
    } on DioException catch (e) {
      // 有 HTTP 响应 → 原样返回（不 reject）；纯网络失败 → REQUEST_FAILED
      final resp = e.response;
      if (resp != null) {
        final payload = resp.data;
        if (json) {
          if (resp.statusCode != null &&
              (resp.statusCode! < 200 || resp.statusCode! >= 300)) {
            throw AntError('REQUEST_FAILED', 'HTTP ${resp.statusCode}');
          }
          if (payload is String) {
            try {
              return jsonDecode(payload);
            } catch (_) {
              throw AntError('REQUEST_FAILED', '响应不是合法 JSON');
            }
          }
          return payload;
        }
        Object? data;
        if (responseType == 'base64') {
          final bytes = payload is List<int>
              ? payload
              : (payload is String ? utf8.encode(payload) : const <int>[]);
          data = base64Encode(bytes);
        } else if (payload is String) {
          data = payload;
        } else if (payload != null) {
          data = jsonEncode(payload);
        } else {
          data = '';
        }
        return {
          'statusCode': resp.statusCode ?? 0,
          'headers': resp.headers.isEmpty
              ? const <String, dynamic>{}
              : _headersToMap(resp.headers),
          'data': data,
          'responseType': responseType,
          'url': url,
        };
      }
      throw AntError('REQUEST_FAILED', '网络请求失败: ${e.message}');
    } finally {
      // 局部新建的 Dio 内部持有 HttpClient，不显式关闭会泄漏连接池
      client?.close(force: true);
    }
  }

  static Map<String, dynamic> _headersToMap(Headers headers) {
    final map = <String, dynamic>{};
    headers.forEach((k, v) => map[k] = v.join(', '));
    return map;
  }

  // ────────────────────────── storage ──────────────────────────

  static String _storageKey(String key) => 'ant.$appId.$key';

  static Future<Object?> _storage(String method, Map<String, dynamic> args) async {
    final prefs = await SharedPreferences.getInstance();
    final key = (args['key'] ?? '').toString();
    if (key.isEmpty || key.length > 256) {
      throw AntError('INVALID_KEY', 'storage key 为空或超过 256 字符');
    }
    final full = _storageKey(key);
    switch (method) {
      case 'storage.get':
        return prefs.getString(full) ?? args['def'];
      case 'storage.set':
        await prefs.setString(full, (args['value'] ?? '').toString());
        return null;
      case 'storage.getJSON':
        final raw = prefs.getString(full);
        if (raw == null) return args['def'];
        try {
          return jsonDecode(raw);
        } catch (_) {
          return args['def'];
        }
      case 'storage.setJSON':
        await prefs.setString(full, jsonEncode(args['value']));
        return null;
      case 'storage.remove':
        await prefs.remove(full);
        return null;
      case 'storage.clear':
        final prefix = 'ant.$appId.';
        for (final k in prefs.getKeys().toList()) {
          if (k.startsWith(prefix)) await prefs.remove(k);
        }
        return null;
      case 'storage.keys':
        final prefix = 'ant.$appId.';
        return prefs
            .getKeys()
            .where((k) => k.startsWith(prefix))
            .map((k) => k.substring(prefix.length))
            .toList();
      default:
        return null;
    }
  }

  // ────────────────────────── ui ──────────────────────────

  static bool _loadingOpen = false;

  static Future<Object?> _uiLoading(String message) async {
    if (_loadingOpen) return null;
    _loadingOpen = true;
    Get.dialog(
      PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: AppTheme.backgroundCard,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
                const SizedBox(width: 14),
                Flexible(
                  child: Text(
                    message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontBody,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      barrierDismissible: false,
    );
    return null;
  }

  static Future<Object?> _uiHideLoading() async {
    if (_loadingOpen) {
      _loadingOpen = false;
      try {
        if (Get.isDialogOpen ?? false) Get.back();
      } catch (_) {}
    }
    return null;
  }

  static Future<Object?> _uiConfirm(Map<String, dynamic> args) async {
    final ok = await Get.dialog<bool>(
      AlertDialog(
        backgroundColor: AppTheme.backgroundCard,
        title: Text(
          (args['title'] ?? '确认').toString(),
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 16),
        ),
        content: Text(
          (args['content'] ?? '').toString(),
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: Text(
              (args['cancelText'] ?? '取消').toString(),
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: Text(
              (args['confirmText'] ?? '确定').toString(),
              style: TextStyle(color: AppTheme.accentColor),
            ),
          ),
        ],
      ),
    );
    return ok == true;
  }

  static Future<Object?> _uiActionSheet(Map<String, dynamic> args) async {
    final items = (args['items'] as List?)?.map((e) => e.toString()).toList() ?? [];
    if (items.isEmpty) return -1;
    final index = await Get.bottomSheet<int>(
      SafeArea(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: AppTheme.backgroundCard,
            borderRadius: BorderRadius.circular(16),
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: items.length,
            itemBuilder: (context, i) => ListTile(
              title: Text(
                items[i],
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontBody,
                ),
              ),
              onTap: () => Get.back(result: i),
            ),
          ),
        ),
      ),
      isScrollControlled: true,
    );
    return index ?? -1;
  }

  // ────────────────────────── source ──────────────────────────

  static List<Map<String, dynamic>> _sourceList() {
    return ApiConfig.instance.sourceBeanList
        .where((b) => b.key.isNotEmpty)
        .map((b) => {
              'key': b.key,
              'name': b.name.isEmpty ? b.key : b.name,
              'type': b.type,
              'searchable': b.searchable,
            })
        .toList();
  }

  static SourceBean? _beanByKey(String siteKey) {
    if (siteKey.isEmpty) return null;
    for (final b in ApiConfig.instance.sourceBeanList) {
      if (b.key == siteKey) return b;
    }
    return null;
  }

  static Future<Object?> _sourceHome(Map<String, dynamic> args) async {
    final bean = _beanByKey((args['siteKey'] ?? '').toString());
    if (bean == null) {
      throw AntError('SITE_NOT_FOUND', '找不到源 ${args['siteKey']}');
    }
    final (sorts, videos) = await SourceService.instance.getSort(bean);
    return {
      'classes': sorts
          .map((s) => {'type_id': s.id, 'type_name': s.name})
          .toList(),
      'list': videos.map((v) => v.toJson()).toList(),
    };
  }

  static Future<Object?> _sourceCategory(Map<String, dynamic> args) async {
    final bean = _beanByKey((args['siteKey'] ?? '').toString());
    if (bean == null) {
      throw AntError('SITE_NOT_FOUND', '找不到源 ${args['siteKey']}');
    }
    final tid = (args['tid'] ?? '').toString();
    final page = (args['page'] as num?)?.toInt() ?? 1;
    final videos = await SourceService.instance.getList(
      bean,
      SortData(id: tid, name: ''),
      page: page,
    );
    return {'page': page, 'list': videos.map((v) => v.toJson()).toList()};
  }

  static Future<Object?> _sourceSearch(Map<String, dynamic> args) async {
    final bean = _beanByKey((args['siteKey'] ?? '').toString());
    if (bean == null) {
      throw AntError('SITE_NOT_FOUND', '找不到源 ${args['siteKey']}');
    }
    final wd = (args['wd'] ?? '').toString();
    if (wd.isEmpty) return {'list': <Object?>[]};
    final videos = await SourceService.instance.search(bean, wd);
    return {'list': videos.map((v) => v.toJson()).toList()};
  }

  static Future<Object?> _sourceDetail(Map<String, dynamic> args) async {
    final bean = _beanByKey((args['siteKey'] ?? '').toString());
    if (bean == null) {
      throw AntError('SITE_NOT_FOUND', '找不到源 ${args['siteKey']}');
    }
    final id = (args['id'] ?? '').toString();
    final info = await SourceService.instance.getDetail(bean, id);
    if (info == null) throw AntError('SOURCE_FAILED', '详情为空');
    return _vodToJson(info);
  }

  static Future<Object?> _sourcePlay(Map<String, dynamic> args) async {
    final bean = _beanByKey((args['siteKey'] ?? '').toString());
    final flag = (args['flag'] ?? '').toString();
    final id = (args['id'] ?? '').toString();
    if (bean == null) {
      throw AntError('SITE_NOT_FOUND', '找不到源 ${args['siteKey']}');
    }

    // Spider 源：走引擎解析真实地址（parse/jx/playUrl/header 原样透传）
    if (bean.isSpiderSource) {
      final key = bean.key.startsWith('nodejs_')
          ? bean.key.substring(7)
          : bean.key;
      final r = await SpiderService.instance.getPlayUrl(
          key, bean.type, bean.api, flag, id,
          ext: bean.ext ?? '');
      return {
        'parse': r?['parse'] ?? 0,
        'jx': r?['jx'] ?? 0,
        'url': r?['url'] ?? r?['playUrl'] ?? id,
        'playUrl': r?['playUrl'] ?? id,
        'flag': flag,
        'jxFrom': r?['jxFrom'] ?? '',
        'key': bean.key,
        'header': r?['header'] ?? <String, dynamic>{},
      };
    }

    // CMS / 远程源：剧集地址即直链
    if (id.startsWith('http://') || id.startsWith('https://')) {
      return {
        'parse': 0,
        'jx': 0,
        'url': id,
        'playUrl': id,
        'flag': flag,
        'jxFrom': '',
        'key': bean.key,
        'header': <String, dynamic>{},
      };
    }
    return {
      'parse': 1,
      'jx': 0,
      'url': id,
      'playUrl': id,
      'flag': flag,
      'jxFrom': '',
      'key': bean.key,
      'header': <String, dynamic>{},
    };
  }

  /// 「继续观看」：最近播放记录（带进度）。
  ///
  /// ⚠️ 2026-10-14 补：`ant.source.*` 原来只有 list/home/category/search/detail/play，
  ///   **没有"最近观看"** ⇒ WebHome 类首页做不了"继续观看"这一块。
  ///
  /// `args`: `{limit?: int}`（默认 20，上限 100）
  /// 返回：`{list:[{vod_id, vod_name, vod_pic, vod_remarks, sourceKey, updatedAt,
  ///        flag?, episodeIndex?, progressSeconds?}]}`
  ///   —— 后三个字段仅在该记录**存过播放进度**时出现（可直接拿去续播）。
  static Future<Object?> _sourceRecent(Map<String, dynamic> args) async {
    final limit = ((args['limit'] as num?)?.toInt() ?? 20).clamp(1, 100);
    final cs = CacheStore.instance;
    final out = <Map<String, dynamic>>[];
    for (final r in cs.records.take(limit)) {
      final st = cs.getPlaybackState(r.vodId, r.sourceKey);
      out.add({
        'vod_id': r.vodId,
        'vod_name': r.vodName,
        'vod_pic': r.vodPic,
        'vod_remarks': r.playNote,
        'sourceKey': r.sourceKey,
        'updatedAt': r.updateTime.millisecondsSinceEpoch,
        if (st != null) ...{
          'flag': st.flag,
          'episodeIndex': st.episodeIndex,
          'progressSeconds': st.progressSeconds,
        },
      });
    }
    return {'list': out};
  }

  /// 「退出当前网页」要执行的宿主动作（由宿主页在打开时注入）。
  ///
  /// · 小程序页（`MiniAppWebPage`）→ `Navigator.maybePop()`（返回上一页）
  /// · 「网页首页」模块（`WebHomePage`）→ 切回影视首页 tab（它是底栏 tab，没有"返回"）
  static void Function()? onExitRequested;

  /// `ant.exitMiniApp()` 的宿主实现。
  ///
  /// ⚠️ 2026-10-14 补：原来 JS 侧是**空实现**（只 `Promise.resolve()`）⇒
  ///   网页里放个"返回 / 退出"按钮，点了毫无反应 ✗。
  static Object? _exitMiniApp() {
    final cb = onExitRequested;
    if (cb != null) {
      // 延后到微任务：先让本次桥调用把结果回给 JS，再真正退出页面
      Future<void>.microtask(() {
        try {
          cb();
        } catch (_) {
          // 退出动作失败不影响桥调用本身
        }
      });
    }
    return {'ok': true};
  }

  /// VodInfo → TVBox JSON（官方 v4：vod_play_from / vod_play_url 是数组）
  static Map<String, dynamic> _vodToJson(VodInfo info) {
    final flags = info.playFlags;
    return {
      'vod_id': info.id,
      'vod_name': info.name,
      'vod_pic': info.pic,
      'vod_remarks': info.note,
      'vod_year': info.year,
      'vod_area': info.area,
      'type_name': info.typeName,
      'vod_director': info.director,
      'vod_actor': info.actor,
      'vod_content': info.des,
      'vod_play_from': flags,
      'vod_play_url': flags
          .map((f) => (info.playUrlMap[f] ?? [])
              .map((e) => '${e.name}\$${e.url}')
              .join('#'))
          .toList(),
    };
  }

  // ────────────────────────── player ──────────────────────────

  static Future<Object?> _playerOpen(Map<String, dynamic> args) async {
    final url = (args['url'] ?? '').toString();
    final title = (args['title'] ?? '').toString();
    final parse = (args['parse'] ?? 0).toString();
    final jx = (args['jx'] ?? 0).toString();
    if (url.isEmpty) throw AntError('INVALID_PARAMS', 'player.open: url 必填');

    final headers = args['headers'] is Map
        ? (args['headers'] as Map)
            .map((k, v) => MapEntry(k.toString(), v.toString()))
        : const <String, String>{};

    // 与影视端**同一套分流**（规则集中在 services/play_route.dart）：
    //   ① 主流正版站（优爱腾芒B…），或线路显式标了 parse/jx → 先过解析接口；
    //   ② 其余站点 → 直接嗅探。
    // 解析出直链直接播；解析出网页 / 未命中 / 没配接口 → 交给嗅探页兜底。
    var candidate = url;
    if (!looksLikeDirectMedia(candidate)) {
      final mustParse = parse == '1' || jx == '1' || needParseFirst(candidate);
      if (mustParse && ParseService.instance.enabled) {
        final outcome = await ParseService.instance.parseOutcome(candidate);
        if (outcome != null && outcome.url.isNotEmpty) {
          AppLog.instance.log(
              '[AntBridge] player.open 解析「${outcome.sourceName}」→ ${outcome.url}'
              '（${outcome.direct ? "直链" : "仍为网页，转嗅探"}）');
          candidate = outcome.url;
        } else {
          AppLog.instance.log('[AntBridge] player.open 解析未命中，转直接嗅探');
        }
      }
      if (!looksLikeDirectMedia(candidate)) {
        AppLog.instance.log('[AntBridge] player.open 转嗅探: $candidate');
        Get.to(() => SniffPlayerPage(url: candidate, title: title));
        return {'route': 'sniff', 'url': candidate, 'sniff': true};
      }
    }

    AppLog.instance.log('[AntBridge] player.open: $title $candidate');
    Get.to(() => MiniAppPlayerPage(url: candidate, title: title, headers: headers));
    return {
      'route': 'player',
      'url': candidate,
      'sniff': false,
      'headerKeys': headers.keys.toList(),
    };
  }
}

/// ant 桥错误（带官方错误码）
class AntError implements Exception {
  final String code;
  final String message;

  AntError(this.code, this.message);

  @override
  String toString() => '$code: $message';
}
