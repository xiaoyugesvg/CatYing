import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
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

  /// 本地模块的伪协议。
  ///
  /// REX 模块本质就是一段 JS，没必要非放到网上。用户从本地选一个 `.js`
  /// 文件时：源码复制到 App 私有目录、`url` 记成 `local://<文件名>`，
  /// 调用 `/rex/api` 时由 [_call] 把源码作为 `code` 一起送过去 ——
  /// Node 侧不用碰文件系统（它的沙箱里没有 `fs`）。
  static const localScheme = 'local://';

  static bool isLocal(String url) => url.startsWith(localScheme);

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
        // 以及**用户改过的名字**（重命名后不被脚本里的 title 覆盖）
        final old = modules[i];
        modules[i] = m.copyWith(
          enabled: old.enabled,
          title: old.title == m.title ? m.title : old.title,
        );
      } else {
        modules.add(m);
      }
    }
    await _persist();
  }

  /// 重命名模块（只改显示名，地址和脚本都不动）
  Future<void> rename(String url, String title) async {
    final i = modules.indexWhere((e) => e.url == url);
    final t = title.trim();
    if (i < 0 || t.isEmpty) return;
    if (modules[i].title == t) return;
    modules[i] = modules[i].copyWith(title: t);
    await _persist();
  }

  Future<void> remove(String url) async {
    modules.removeWhere((e) => e.url == url);
    await _persist();
  }

  /// REX 首页只显示启用中的模块
  List<RexModule> get enabledModules =>
      modules.where((e) => e.enabled).toList();

  /// 首页真正能出内容的模块（启用的 + 有列表/搜索能力）。
  ///
  /// 纯播放源（只有 loadResource）进了这个列表也只会显示空页面，
  /// 所以首页不展示它们，但在订阅管理里保留并标「仅播放」。
  List<RexModule> get browsableModules =>
      modules.where((e) => e.enabled && e.browsable).toList();

  bool hasUrl(String url) => modules.any((e) => e.url == url);

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

  /// 两个模块互换位置。
  ///
  /// 管理页按「已启用 / 已停用」分组展示，[move] 是在**整表**里交换，
  /// 会越过组外的模块 —— 用户点一下上移，卡片却原地不动（中间夹着一个
  /// 看不见的已停用模块）。分组内调整顺序要用这个按 url 精确交换。
  Future<void> swap(String urlA, String urlB) async {
    final i = modules.indexWhere((e) => e.url == urlA);
    final j = modules.indexWhere((e) => e.url == urlB);
    if (i < 0 || j < 0 || i == j) return;
    final t = modules[i];
    modules[i] = modules[j];
    modules[j] = t;
    await _persist();
  }

  /// 改模块地址：重新拉元数据后替换（保留启用状态与顺序）
  Future<void> updateUrl(String oldUrl, String newUrl) async {
    if (modules.indexWhere((e) => e.url == oldUrl) < 0) return;
    // 中文路径必须编码，否则 Dio 抛 Invalid character in path（同 fetchCollection）
    final fresh = await loadModule(normalizeUrl(newUrl.trim()));
    // ⚠️ await 期间列表可能被「移除模块」改动过：必须按 url 重新定位，
    //    否则会覆盖到别的模块，索引越界时直接 RangeError。
    final i = modules.indexWhere((e) => e.url == oldUrl);
    if (i < 0) return;
    modules[i] = fresh.copyWith(enabled: modules[i].enabled);
    await _persist();
  }

  /// 刷新全部模块的元数据；返回失败明细
  Future<List<String>> refreshAll() async {
    final errors = <String>[];
    // 快照当前列表再逐个刷新：循环体内 await 期间 modules 可能被移除，
    // 用下标写回会把 A 的元数据写进 B（旧实现的问题）。
    for (final m in List<RexModule>.from(modules)) {
      try {
        final fresh = await loadModule(m.url);
        final i = modules.indexWhere((e) => e.url == m.url);
        if (i < 0) continue; // 刷新期间被移除
        modules[i] = fresh.copyWith(enabled: modules[i].enabled);
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

  /// 把用户粘贴的地址规范化。
  ///
  /// 🔴 中文路径（如 `…/collections/花花.rex`）必须百分号编码：
  /// dart:io 的 HttpClient 只接受 ASCII 请求行，Dio 直接抛
  /// `Invalid character in path` —— 用户看到的就是「导入没反应」。
  static String normalizeUrl(String input) {
    final u = input.trim();
    if (u.isEmpty) return u;
    if (u.codeUnits.any((c) => c > 127)) {
      try {
        return Uri.encodeFull(u);
      } catch (_) {
        return u;
      }
    }
    return u;
  }

  Future<String> _get(String url) async {
    try {
      final res = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          headers: const {
            // 部分模块/集合放在会拦默认 UA 的站点上
            'User-Agent':
                'Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) '
                    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 '
                    'Mobile/15E148 Safari/604.1',
          },
        ),
      );
      return res.data ?? '';
    } catch (e) {
      throw RexException('拉取失败：${_shortNet(e)}');
    }
  }

  /// 拉取一个集合地址，**只解析 JSON、不加载模块**（秒回）。
  ///
  /// 这是「市场」页的核心：先拿到候选清单让用户勾选，
  /// 避免像以前那样一次串行加载几十个模块、界面上毫无反馈。
  Future<RexCollection> fetchCollection(String input) async {
    var url = input.trim();
    if (url.isEmpty) throw const RexException('先粘贴集合地址');
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      throw const RexException('地址要以 http:// 或 https:// 开头');
    }
    url = normalizeUrl(url);

    final text = await _get(url);
    if (text.trim().isEmpty) throw const RexException('地址内容为空');

    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{')) {
      Map<String, dynamic>? map;
      try {
        final d = jsonDecode(text);
        if (d is Map) map = d.cast<String, dynamic>();
      } catch (_) {
        map = null;
      }
      if (map != null && map['widgets'] is List) {
        return _parseCollection(url, map);
      }
    }

    // 不是集合 ⇒ 当成单个模块。标题尽量从 WidgetMetadata 里抠出来
    final m = RegExp(r'''title\s*:\s*['"]([^'"]{1,40})['"]''').firstMatch(text);
    final host = Uri.tryParse(url)?.host ?? url;
    return RexCollection(
      url: url,
      title: m != null ? m.group(1)! : host,
      items: [
        RexCollectionItem(
          url: url,
          title: m != null ? m.group(1)! : host,
        ),
      ],
    );
  }

  RexCollection _parseCollection(String url, Map<String, dynamic> map) {
    final widgets = map['widgets'];
    if (widgets is! List || widgets.isEmpty) {
      throw const RexException('这个 .rex 集合里没有模块');
    }
    final base = Uri.tryParse(url);
    final items = <RexCollectionItem>[];
    for (final w in widgets) {
      if (w is! Map) continue;
      var u = '${w['url'] ?? ''}'.trim();
      if (u.isEmpty) continue;
      if (!u.startsWith('http') && base != null) {
        u = base.resolve(u).toString();
      }
      final it = RexCollectionItem.fromJson(w.cast<String, dynamic>());
      items.add(RexCollectionItem(
        url: normalizeUrl(u),
        title: it.title,
        id: it.id,
        author: it.author,
        version: it.version,
        description: it.description,
      ));
    }
    if (items.isEmpty) throw const RexException('这个 .rex 集合里没有可用的模块地址');
    return RexCollection(
      url: url,
      title: '${map['title'] ?? ''}'.trim(),
      description: '${map['description'] ?? ''}',
      icon: '${map['icon'] ?? ''}',
      items: items,
    );
  }

  /// 批量加载并保存勾选的模块。
  ///
  /// · 并发 [concurrency] 路（默认 4）：88 个模块串行要几分钟，界面像卡死；
  /// · 每一项单独 25 秒超时，坏的模块不会拖住整批；
  /// · [onProgress] 每完成一项回调一次，页面用它画进度条。
  Future<RexImportResult> importSelected(
    List<RexCollectionItem> items, {
    void Function(int done, int total, String current)? onProgress,
    int concurrency = 4,
  }) async {
    if (items.isEmpty) return const RexImportResult();
    final total = items.length;
    final width = concurrency.clamp(1, 6);
    // 按下标回填而不是 add：4 路并发完成顺序是随机的，
    // 直接 add 会让订阅列表顺序与集合文件不一致（每次导入还不一样）。
    final slots = List<RexModule?>.filled(total, null);
    final errors = <String>[];
    var next = 0;
    var done = 0;

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= total) return;
        final it = items[i];
        try {
          final m = await loadModule(it.url, fallbackTitle: it.title)
              .timeout(const Duration(seconds: 25));
          slots[i] = m;
        } catch (e) {
          errors.add('${it.title.isEmpty ? it.url : it.title}：${_short(e)}');
        }
        done++;
        onProgress?.call(done, total, it.title);
      }
    }

    await Future.wait(
      List.generate(width > total ? total : width, (_) => worker()),
    );
    final loaded = slots.whereType<RexModule>().toList();
    if (loaded.isNotEmpty) await addAll(loaded);
    return RexImportResult(imported: loaded, errors: errors);
  }

  /// 一步到位导入（单个模块地址 / 集合都会展开）。
  ///
  /// 保持旧入口：内部改成「先取清单 → 全量导入」，
  /// 但页面已改用 [fetchCollection] + [importSelected] 让用户挑选。
  Future<List<RexModule>> importFrom(String input) async {
    final col = await fetchCollection(input);
    final res = await importSelected(col.items);
    if (res.imported.isEmpty) {
      throw RexException(
        res.errors.isEmpty ? '没有导入任何模块' : '全部加载失败：${res.errors.take(2).join('；')}',
      );
    }
    return res.imported;
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

  // ── 本地模块（从文件导入）─────────────────────────────────────

  /// 本地模块源码目录（App 私有目录，不进相册/文档）
  Future<Directory> _localDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/rex_local');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 读取本地模块源码；文件不存在返回 null
  Future<String?> readLocalCode(String url) async {
    try {
      final name = url.substring(localScheme.length).split('/').last;
      final dir = await _localDir();
      final f = File('${dir.path}/$name');
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 从本地文件导入一个 REX 模块（`.js` 源码）。
  ///
  /// 源码复制进 App 目录后以 `local://<文件名>` 作为模块地址，
  /// 之后 list/detail/resource/search 都走同一条 [_call] 通道。
  /// 同名文件重复导入 = 就地更新，不会出现两个同名模块。
  Future<RexModule> importLocalFile(String path) async {
    final file = File(path);
    final code = await file.readAsString();
    if (code.trim().isEmpty) throw const RexException('这个文件是空的');
    final rawName = path.split(RegExp(r'[\\/]')).last;
    // 只保留安全字符，避免 ../ 之类跑出目录
    final safe = rawName.replaceAll(RegExp(r'[^A-Za-z0-9._\u4e00-\u9fa5-]'), '_');
    final dir = await _localDir();
    await File('${dir.path}/$safe').writeAsString(code);

    final url = '$localScheme$safe';
    // 同名文件重新导入时要丢掉旧编译缓存，否则 Node 还在跑上一版代码
    try {
      await _call({'action': 'clearCache', 'url': url}, checkOk: false);
    } catch (_) {}
    final fallback = safe.replaceAll(RegExp(r'\.(js|mjs|txt)$'), '');
    final fresh = await loadModule(url, fallbackTitle: fallback);
    final i = modules.indexWhere((e) => e.url == url);
    if (i >= 0) {
      modules[i] = fresh.copyWith(enabled: modules[i].enabled);
    } else {
      modules.add(fresh);
    }
    await _persist();
    revision.value++;
    return fresh;
  }

  /// 一次性导入多个本地文件；返回成功与失败明细
  Future<RexImportResult> importLocalFiles(List<String> paths) async {
    final imported = <RexModule>[];
    final errors = <String>[];
    for (final p in paths) {
      try {
        imported.add(await importLocalFile(p));
      } catch (e) {
        errors.add('${p.split(RegExp(r'[\\/]')).last}：$_short(e)');
      }
    }
    return RexImportResult(imported: imported, errors: errors);
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
    // 本地模块：源码由这里读出来塞进请求体（Node 侧没有 fs）
    final payload = Map<String, dynamic>.from(body);
    final target = '${payload['url'] ?? ''}';
    if (isLocal(target)) {
      final code = await readLocalCode(target);
      if (code == null) {
        throw const RexException('本地模块文件已丢失，请重新导入');
      }
      payload['code'] = code;
    }
    try {
      final res = await _dio.post(
        'http://127.0.0.1:$port/rex/api',
        data: payload,
        options: Options(
          contentType: Headers.jsonContentType,
          // 不要因为 4xx/5xx 就抛异常：Node 侧出错时会带 `{ok:false,error}`，
          // 那段文案才是用户该看到的。默认 validateStatus 会把它整段吞掉，
          // 界面上只剩一屏 "This exception was thrown because …"。
          validateStatus: (_) => true,
        ),
      );
      final data = res.data;
      if (data is Map) {
        final map = data.cast<String, dynamic>();
        if (checkOk && map['ok'] == false) {
          throw RexException('${map['error'] ?? '模块执行失败'}');
        }
        return map;
      }
      final code = res.statusCode ?? 0;
      if (code < 200 || code >= 300) {
        throw RexException('后台返回 HTTP $code');
      }
      throw const RexException('模块返回格式异常');
    } on RexException {
      rethrow;
    } catch (e) {
      throw RexException(_short(e));
    }
  }

  /// **外网**请求的错误翻译（集合/模块地址直连）。
  ///
  /// 🔴 不能复用 [_short]：那是给 localhost Node 桥写的，外网失败被翻成
  /// 「连不上后台服务（Node 可能正在启动）」会完全误导 —— 用户截图里的
  /// 真实失败就是设备直连 workers.dev 被 DNS 阻断，跟 Node 毫无关系。
  static String _shortNet(Object e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return '请求超时，检查网络后重试';
        case DioExceptionType.connectionError:
          // e.error 里通常带着 SocketException 的具体原因
          final raw = '${e.error ?? e.message ?? ''}';
          if (raw.contains('Failed host lookup') ||
              raw.contains('No address associated')) {
            return '域名解析失败（站点可能被阻断，换个网络或稍后再试）';
          }
          if (raw.contains('refused')) return '连接被拒绝（站点可能已下线）';
          if (raw.contains('reset')) return '连接被重置（站点可能被阻断，换个网络试试）';
          return '网络连接失败（检查网络，或确认地址没过期）';
        case DioExceptionType.badResponse:
          return '站点返回 HTTP ${e.response?.statusCode ?? '?'}';
        case DioExceptionType.badCertificate:
          return '证书校验失败（站点证书异常）';
        case DioExceptionType.cancel:
          return '请求已取消';
        default:
          return '请求失败：${e.type.name}';
      }
    }
    final s = '$e';
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  static String _short(Object e) {
    if (e is DioException) {
      // badResponse 的 message 是一整段英文解释，对用户毫无意义 ——
      // 只保留「连不上 / 超时」这类真正需要人看的信息。
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return '请求超时，稍后重试';
        case DioExceptionType.connectionError:
          return '连不上后台服务（Node 可能正在启动）';
        case DioExceptionType.badResponse:
          return '后台返回 HTTP ${e.response?.statusCode ?? '?'}';
        case DioExceptionType.cancel:
          return '请求已取消';
        default:
          return '请求失败：${e.type.name}';
      }
    }
    final s = '$e';
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }
}
