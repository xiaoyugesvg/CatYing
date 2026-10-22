import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/nodejs_manager.dart';
import 'rex_models.dart';

/// REX / ForwardWidget 模块的 Dart 侧服务。
///
/// 真正的模块执行在 Node 里（`assets/nodejs-project/src/rex_engine.js`），
/// 这里只负责：
///   · 调 `/rex/api`（load / list / detail / resource / search）
///   · 解析 `.rex` 集合（`widgets[]` → 模块 raw 地址）
///   · 模块列表本地持久化（含元数据，启动不用联网）
class RexService {
  RexService._();
  static final RexService instance = RexService._();

  static const _key = 'rex.modules.v1';

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 90),
  ));

  final modules = <RexModule>[];
  final revision = ValueNotifier<int>(0);

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) {
              final m = RexModule.fromJson(e.cast<String, dynamic>());
              if (m.url.isNotEmpty) modules.add(m);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[REX] 读取模块列表失败: $e');
    }
    revision.value++;
  }

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _key,
        jsonEncode(modules.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[REX] 保存模块列表失败: $e');
    }
    revision.value++;
  }

  Future<void> addAll(List<RexModule> list) async {
    for (final m in list) {
      final i = modules.indexWhere((e) => e.url == m.url);
      if (i >= 0) {
        // 重新导入同一地址：保留用户的启用状态
        modules[i] = m.copyWith(enabled: modules[i].enabled);
      } else {
        modules.add(m);
      }
    }
    await _persist();
  }

  Future<void> remove(String url) async {
    modules.removeWhere((e) => e.url == url);
    await _persist();
  }

  /// REX 首页只显示启用中的模块
  List<RexModule> get enabledModules =>
      modules.where((e) => e.enabled).toList();

  Future<void> setEnabled(String url, bool enabled) async {
    final i = modules.indexWhere((e) => e.url == url);
    if (i < 0) return;
    modules[i] = modules[i].copyWith(enabled: enabled);
    await _persist();
  }

  /// 上移 / 下移（delta = -1 / +1），越界忽略
  Future<void> move(String url, int delta) async {
    final i = modules.indexWhere((e) => e.url == url);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= modules.length) return;
    final t = modules[i];
    modules[i] = modules[j];
    modules[j] = t;
    await _persist();
  }

  /// 改模块地址：重新拉元数据后替换（保留启用状态与顺序）
  Future<void> updateUrl(String oldUrl, String newUrl) async {
    final i = modules.indexWhere((e) => e.url == oldUrl);
    if (i < 0) return;
    final fresh = await loadModule(newUrl.trim());
    modules[i] = fresh.copyWith(enabled: modules[i].enabled);
    await _persist();
  }

  /// 刷新全部模块的元数据；返回失败明细
  Future<List<String>> refreshAll() async {
    final errors = <String>[];
    for (var i = 0; i < modules.length; i++) {
      final m = modules[i];
      try {
        final fresh = await loadModule(m.url);
        modules[i] = fresh.copyWith(enabled: m.enabled);
      } catch (e) {
        errors.add('${m.title}：$e');
      }
    }
    await _persist();
    return errors;
  }

  Future<void> clearCache(RexModule m) async {
    try {
      await _call({'action': 'clearCache', 'url': m.url}, checkOk: false);
    } catch (_) {}
  }

  // ── 导入 ─────────────────────────────────────────────────────

  /// 支持两种输入：
  ///   · 单个模块 raw 地址（返回 JS）
  ///   · `.rex` 集合（返回 `{ widgets: [{title,url}] }`）
  Future<List<RexModule>> importFrom(String input) async {
    final url = input.trim();
    if (url.isEmpty) throw const RexException('先粘贴模块地址');
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      throw const RexException('地址要以 http:// 或 https:// 开头');
    }

    String text = '';
    try {
      final res = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: const {
            // 部分模块/集合放在会拦默认 UA 的站点上
            'User-Agent':
                'Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) '
                    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 '
                    'Mobile/15E148 Safari/604.1',
          },
        ),
      );
      text = res.data ?? '';
    } catch (e) {
      throw RexException('拉取失败：${_short(e)}');
    }
    if (text.trim().isEmpty) throw const RexException('地址内容为空');

    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{')) {
      final collection = _parseCollection(url, text);
      if (collection != null) {
        if (collection.isEmpty) {
          throw const RexException('集合里没有可用的模块地址');
        }
        final loaded = <RexModule>[];
        final errors = <String>[];
        for (final item in collection) {
          try {
            loaded.add(await loadModule(item.url, fallbackTitle: item.title));
          } catch (e) {
            errors.add('${item.title.isEmpty ? item.url : item.title}：$e');
          }
        }
        if (loaded.isEmpty) {
          throw RexException('集合里的模块都加载失败：${errors.take(2).join('；')}');
        }
        return loaded;
      }
    }

    return [await loadModule(url)];
  }

  List<_CollectionItem>? _parseCollection(String baseUrl, String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final widgets = decoded['widgets'];
      if (widgets is! List || widgets.isEmpty) return null;
      final out = <_CollectionItem>[];
      final base = Uri.tryParse(baseUrl);
      for (final w in widgets) {
        if (w is! Map) continue;
        var u = '${w['url'] ?? ''}'.trim();
        if (u.isEmpty) continue;
        if (!u.startsWith('http') && base != null) {
          u = base.resolve(u).toString();
        }
        out.add(_CollectionItem(
          title: '${w['title'] ?? ''}',
          url: u,
        ));
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// 让 Node 加载模块并取 WidgetMetadata
  Future<RexModule> loadModule(String url, {String fallbackTitle = ''}) async {
    final data = await _call({'action': 'load', 'url': url});
    final meta = data['meta'];
    if (meta is! Map) {
      throw const RexException('模块没有返回 WidgetMetadata');
    }
    final m = meta.cast<String, dynamic>();
    final rawTitle = '${m['title'] ?? ''}'.trim();
    final title = rawTitle.isNotEmpty
        ? rawTitle
        : (fallbackTitle.trim().isNotEmpty ? fallbackTitle.trim() : 'REX 模块');
    return RexModule(
      url: url,
      id: '${m['id'] ?? url}',
      title: title,
      description: '${m['description'] ?? ''}',
      author: '${m['author'] ?? ''}',
      version: '${m['version'] ?? ''}',
      site: '${m['site'] ?? ''}',
      functions: [
        if (m['modules'] is List)
          for (final e in m['modules'] as List)
            if (e is Map) RexFunction.fromJson(e.cast<String, dynamic>()),
      ],
      functionNames: [
        if (m['functions'] is List)
          for (final e in m['functions'] as List) '$e',
      ],
    );
  }

  /// 重新拉一次元数据（模块更新后）
  Future<void> refreshModule(RexModule m) async {
    final fresh = await loadModule(m.url, fallbackTitle: m.title);
    final i = modules.indexWhere((e) => e.url == m.url);
    if (i >= 0) {
      modules[i] = fresh;
      await _persist();
    }
  }

  // ── 数据 ─────────────────────────────────────────────────────

  Future<List<RexItem>> list(
    RexModule module,
    RexFunction fn, {
    int page = 1,
  }) async {
    final params = _paramsFor(fn, page);
    final data = await _call({
      'action': 'list',
      'url': module.url,
      'functionName': fn.functionName,
      'params': params,
    });
    return _items(data['items']);
  }

  Future<List<RexItem>> search(
    RexModule module,
    String keyword, {
    int page = 1,
  }) async {
    final data = await _call({
      'action': 'search',
      'url': module.url,
      'keyword': keyword,
      'page': page,
    });
    return _items(data['items']);
  }

  Future<RexItem?> detail(RexModule module, RexItem item) async {
    final data = await _call({
      'action': 'detail',
      'url': module.url,
      'link': item.link,
    });
    final raw = data['item'];
    if (raw is! Map) return item;
    final d = RexItem.fromJson(raw.cast<String, dynamic>());
    // 模块偶尔把标题/封面丢了，用列表里的补上
    return RexItem(
      id: d.id.isEmpty ? item.id : d.id,
      title: d.title.isEmpty ? item.title : d.title,
      link: d.link.isEmpty ? item.link : d.link,
      cover: d.cover.isEmpty ? item.cover : d.cover,
      backdrop: d.backdrop.isEmpty ? item.backdrop : d.backdrop,
      description: d.description.isEmpty ? item.description : d.description,
      mediaType: d.mediaType.isEmpty ? item.mediaType : d.mediaType,
      playerType: d.playerType.isEmpty ? item.playerType : d.playerType,
    );
  }

  Future<List<RexStream>> resource(RexModule module, RexItem item) async {
    final data = await _call({
      'action': 'resource',
      'url': module.url,
      'link': item.link,
      'params': {
        'link': item.link,
        'id': item.link,
        'url': item.link,
        'title': item.title,
      },
    });
    final raw = data['streams'];
    final out = <RexStream>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final s = RexStream.fromJson(e.cast<String, dynamic>());
        if (s.url.isNotEmpty) out.add(s);
      }
    }
    return out;
  }

  Map<String, String> _paramsFor(RexFunction fn, int page) {
    final params = <String, String>{};
    for (final p in fn.params) {
      if (p.name.isEmpty) continue;
      if (p.type == 'page') {
        params[p.name] = '$page';
      } else if (p.value.isNotEmpty) {
        params[p.name] = p.value;
      }
    }
    // 模块可能没声明 page 参数，但 loadList 仍然读 params.page
    params.putIfAbsent('page', () => '$page');
    return params;
  }

  List<RexItem> _items(dynamic raw) {
    final out = <RexItem>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) out.add(RexItem.fromJson(e.cast<String, dynamic>()));
      }
    }
    return out;
  }

  Future<Map<String, dynamic>> _call(
    Map<String, dynamic> body, {
    bool checkOk = true,
  }) async {
    final port = NodeJSManager.instance.managementPort;
    if (port <= 0) {
      throw const RexException('后台服务未就绪，请稍后重试');
    }
    try {
      final res = await _dio.post(
        'http://127.0.0.1:$port/rex/api',
        data: body,
        options: Options(contentType: Headers.jsonContentType),
      );
      final data = res.data;
      if (data is! Map) throw const RexException('模块返回格式异常');
      final map = data.cast<String, dynamic>();
      if (checkOk && map['ok'] == false) {
        throw RexException('${map['error'] ?? '模块执行失败'}');
      }
      return map;
    } on RexException {
      rethrow;
    } catch (e) {
      throw RexException('请求失败：${_short(e)}');
    }
  }

  static String _short(Object e) {
    if (e is DioException) {
      final msg = e.message ?? '';
      final type = e.type.name;
      return msg.isEmpty ? type : '$type（$msg）';
    }
    final s = '$e';
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }
}

class _CollectionItem {
  const _CollectionItem({required this.title, required this.url});
  final String title;
  final String url;
}
