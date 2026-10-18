import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import '../models/source_subscription.dart';
import '../source/global_proxy.dart';
import '../source/source_config_store.dart';
import '../source/source_definition.dart';
import '../source/source_manager.dart';
import 'book_source_import_parser.dart';

/// 阅读模块「源订阅」存储与更新。
///
/// 记录的是**链接**；更新时下载 JSON → 按类型过滤（小说=0 / 漫画=2）→
/// 交给 [BookSourceStore] 入库。源本体与本地导入的源共用同一个 Store。
class SourceSubscriptionStore extends ChangeNotifier {
  SourceSubscriptionStore._();
  static final SourceSubscriptionStore instance = SourceSubscriptionStore._();

  static const _key = 'reading_source_subscriptions_v1';
  static const _seedKey = 'reading_source_subscriptions_seeded_v1';

  final List<SourceSubscription> _items = [];
  List<SourceSubscription> get items => List.unmodifiable(_items);

  bool _loaded = false;
  bool get isLoaded => _loaded;

  SharedPreferences? _sp;

  Future<SharedPreferences> _prefs() async =>
      _sp ??= await SharedPreferences.getInstance();

  Future<void> load() async {
    if (_loaded) return;
    final sp = await _prefs();
    try {
      final raw = sp.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final arr = jsonDecode(raw);
        if (arr is List) {
          for (final e in arr) {
            final s = SourceSubscription.tryParse(e);
            if (s != null) _items.add(s);
          }
        }
      }
      // 迁移：上一版把小说/漫画拆成两条内置订阅，现在合并成 legado-all.json。
      // 只迁移"内置"记录，用户自己加的不动。
      final oldSeedUrls = {
        'https://raw.githubusercontent.com/leimao2333/leimao-sources/main/novel.json',
        'https://raw.githubusercontent.com/leimao2333/leimao-sources/main/comic-legado.json',
      };
      final hadOldSeeds =
          _items.any((e) => e.builtin && oldSeedUrls.contains(e.url));
      if (hadOldSeeds) {
        _items.removeWhere(
            (e) => e.builtin && oldSeedUrls.contains(e.url));
        if (!_items.any((e) => e.url == _legadoAllUrl)) {
          _items.add(_legadoAllSeed);
        }
        await _persist();
      }

      // 首次播种：把常用的两条链接记进来（只做一次；用户删掉不复活）
      if (sp.getBool(_seedKey) != true) {
        for (final s in _seeds) {
          if (_items.any((e) => e.url == s.url)) continue;
          _items.add(s);
        }
        await sp.setBool(_seedKey, true);
        await _persist();
      }
    } catch (e) {
      _log('读取源订阅失败: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  static const String _legadoAllUrl =
      'https://raw.githubusercontent.com/leimao2333/leimao-sources/main/legado-all.json';

  static const SourceSubscription _legadoAllSeed = SourceSubscription(
    id: 'seed_leimao_legado_all',
    name: '雷毛 Legado 综合源（80）',
    url: _legadoAllUrl,
    kind: SourceSubscriptionKind.legado,
    builtin: true,
  );

  static List<SourceSubscription> get _seeds => [
        _legadoAllSeed,
        SourceSubscription(
          id: 'seed_leimao_venera',
          name: '雷毛 Venera 漫画源（33）',
          url:
              'https://raw.githubusercontent.com/leimao2333/leimao-sources/main/venera/index.json',
          kind: SourceSubscriptionKind.venera,
          builtin: true,
        ),
      ];

  Future<SourceSubscription?> add({
    required String name,
    required String url,
    required SourceSubscriptionKind kind,
  }) async {
    await load();
    final u = url.trim();
    if (u.isEmpty) return null;
    final exist = _items.where((e) => e.url == u).firstOrNull;
    if (exist != null) return exist;
    final now = DateTime.now().millisecondsSinceEpoch;
    final s = SourceSubscription(
      id: 'sub_$now',
      name: name.trim().isEmpty ? u : name.trim(),
      url: u,
      kind: kind,
    );
    _items.add(s);
    await _persist();
    notifyListeners();
    return s;
  }

  Future<void> remove(String id) async {
    _items.removeWhere((e) => e.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    _items[i] = _items[i].copyWith(enabled: enabled);
    await _persist();
    notifyListeners();
  }

  Future<void> rename(String id, String name) async {
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    _items[i] = _items[i].copyWith(name: name.trim());
    await _persist();
    notifyListeners();
  }

  /// 更新一条订阅：下载 → 解析 → 按类型过滤 → 入库。
  Future<({bool ok, String message, int count})> update(String id) async {
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return (ok: false, message: '订阅不存在', count: 0);
    final sub = _items[i];
    if (sub.kind == SourceSubscriptionKind.venera) {
      return _updateVenera(sub, i);
    }
    if (!sub.kind.supported) {
      const msg = '该源类型暂未支持';
      _items[i] = sub.copyWith(lastError: msg);
      await _persist();
      notifyListeners();
      return (ok: false, message: msg, count: 0);
    }
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 40),
        responseType: ResponseType.plain,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                  'AppleWebKit/605.1.15 (KHTML, like Gecko) '
                  'Version/17.0 Mobile/15E148 Safari/604.1',
          'Accept': 'application/json,text/plain,*/*',
        },
      ));
      applyGlobalProxy(dio);
      final res = await dio.get<String>(sub.url);
      final text = res.data ?? '';
      if (text.trim().isEmpty) throw Exception('订阅返回为空');
      final all = BookSourceImportParser.parseSources(text);
      final wanted = all.where((s) {
        if (sub.kind == SourceSubscriptionKind.comic) return s.type == '2';
        if (sub.kind == SourceSubscriptionKind.novel) return s.type == '0';
        // legado 综合源：小说 + 漫画都收，更新后两个仓同时有内容
        return s.type == '0' || s.type == '2';
      }).toList();
      if (wanted.isEmpty) {
        throw Exception('没有解析到${sub.kind.label}（共 ${all.length} 条）');
      }
      final r = await BookSourceStore.instance.addAll(wanted);
      // 含漫画源时刷新漫画模块的源列表（Legado 漫画源从 BookSourceStore 注册）
      if (wanted.any((s) => s.type == '2')) {
        await SourceManager().reload();
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      _items[i] = sub.copyWith(
        count: wanted.length,
        lastUpdated: now,
        lastError: '',
      );
      await _persist();
      notifyListeners();
      return (
        ok: true,
        message: '新增 ${r.added} 个、更新 ${r.updated} 个',
        count: wanted.length,
      );
    } catch (e) {
      final msg = _friendly(e);
      _items[i] = sub.copyWith(lastError: msg);
      await _persist();
      notifyListeners();
      return (ok: false, message: msg, count: 0);
    }
  }

  /// Venera 源列表：`index.json` 是 `[{name,key,version,fileName}]` 数组，
  /// 每条指向一个 `.js`（相对路径按 index.json 的地址解析）。
  ///
  /// 源脚本原样保存到漫画源配置（`sources.json` 的 `type: venera`），
  /// 由 `VeneraMangaSource` 用内置 JS 运行时执行 —— 不做规则转写，
  /// 上游脚本更新后重新「更新订阅」即可。
  Future<({bool ok, String message, int count})> _updateVenera(
    SourceSubscription sub,
    int i,
  ) async {
    Dio? client;
    try {
      final dio = client = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 40),
        responseType: ResponseType.plain,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                  'AppleWebKit/605.1.15 (KHTML, like Gecko) '
                  'Version/17.0 Mobile/15E148 Safari/604.1',
          'Accept': 'application/json,text/plain,*/*',
        },
      ));
      applyGlobalProxy(dio);
      final res = await dio.get<String>(sub.url);
      final text = res.data ?? '';
      if (text.trim().isEmpty) throw Exception('订阅返回为空');
      final decoded = jsonDecode(text);
      if (decoded is! List) throw Exception('Venera 源列表不是 JSON 数组');

      final base = Uri.parse(sub.url);
      final entries = decoded.whereType<Map>().toList();
      if (entries.isEmpty) throw Exception('Venera 源列表为空');

      final defs = <SourceDefinition>[];
      var cursor = 0;
      var failed = 0;
      Future<void> worker() async {
        while (true) {
          final idx = cursor++;
          if (idx >= entries.length) return;
          final e = entries[idx];
          final fileName = '${e['fileName'] ?? ''}'.trim();
          if (fileName.isEmpty) continue;
          final scriptUrl = base.resolve(fileName).toString();
          try {
            final js = (await dio.get<String>(scriptUrl)).data ?? '';
            if (js.trim().isEmpty) {
              failed++;
              continue;
            }
            final idBase = fileName
                .split('/')
                .last
                .replaceAll(RegExp(r'\.js$', caseSensitive: false), '');
            final storageKey = '${e['key'] ?? ''}'.trim();
            defs.add(SourceDefinition(
              id: 'venera:$idBase',
              type: 'venera',
              engine: 'venera',
              config: {
                'id': 'venera:$idBase',
                'name': '${e['name'] ?? idBase}',
                'key': storageKey.isEmpty ? idBase : storageKey,
                'version': '${e['version'] ?? ''}',
                'scriptUrl': scriptUrl,
                'script': js,
              },
            ));
          } catch (err) {
            failed++;
            _log('Venera 脚本下载失败 $scriptUrl: $err');
          }
        }
      }

      // 6 路并发：33 个脚本串行下载太慢，全并发又容易被 GitHub 限流
      await Future.wait([for (var w = 0; w < 6; w++) worker()]);
      if (defs.isEmpty) {
        throw Exception('没有成功下载到任何脚本（失败 $failed 个）');
      }

      final existing = await SourceConfigStore().loadLocal();
      final newUrls =
          defs.map((d) => '${d.config['scriptUrl'] ?? ''}').toSet();
      // 部分脚本下载失败时保留上一版，避免一次网络抖动把源删掉
      final kept = failed == 0
          ? const <SourceDefinition>[]
          : existing
              .where((d) =>
                  d.type == 'venera' &&
                  !newUrls.contains('${d.config['scriptUrl'] ?? ''}'))
              .toList();
      final merged = existing.where((d) => d.type != 'venera').toList()
        ..addAll(kept)
        ..addAll(defs);
      await SourceConfigStore().saveLocal(merged);
      await SourceManager().reload();

      final now = DateTime.now().millisecondsSinceEpoch;
      _items[i] = sub.copyWith(
        count: defs.length,
        lastUpdated: now,
        lastError: '',
      );
      await _persist();
      notifyListeners();
      return (
        ok: true,
        message: failed == 0
            ? '已加载 ${defs.length} 个 Venera 源'
            : '已加载 ${defs.length} 个 Venera 源（${failed} 个下载失败）',
        count: defs.length,
      );
    } catch (e) {
      final msg = _friendly(e);
      _items[i] = sub.copyWith(lastError: msg);
      await _persist();
      notifyListeners();
      return (ok: false, message: msg, count: 0);
    } finally {
      client?.close(force: true);
    }
  }

  /// 全部更新（跳过停用与不支持的）
  Future<({int ok, int failed})> updateAll() async {
    var ok = 0, failed = 0;
    for (final s in List<SourceSubscription>.from(_items)) {
      if (!s.enabled || !s.kind.supported) continue;
      final r = await update(s.id);
      r.ok ? ok++ : failed++;
    }
    return (ok: ok, failed: failed);
  }

  /// 自动更新周期：24 小时。首次（[SourceSubscription.lastUpdated] == 0）
  /// 会立即拉取，所以新装/新加的订阅不用再手动点「更新」。
  static const Duration autoTtl = Duration(hours: 24);

  bool _autoRunning = false;

  /// 启动时调用：把「从未更新过」或「超过 [autoTtl] 未更新」的订阅逐个拉一遍，
  /// 源体会落库（[BookSourceStore] / [SourceConfigStore]），下次启动直接用本地源，
  /// 不再依赖用户手动点更新。
  Future<void> autoUpdateStale() async {
    if (_autoRunning) return;
    _autoRunning = true;
    try {
      await load();
      final now = DateTime.now().millisecondsSinceEpoch;
      final stale = _items
          .where((s) =>
              s.enabled &&
              s.kind.supported &&
              (s.lastUpdated == 0 ||
                  now - s.lastUpdated > autoTtl.inMilliseconds))
          .toList();
      for (final s in stale) {
        // 期间用户可能停用 / 删除，逐条再确认一次
        final cur = _items.where((e) => e.id == s.id).firstOrNull;
        if (cur == null || !cur.enabled) continue;
        await update(s.id);
      }
    } catch (e) {
      _log('自动更新订阅失败: $e');
    } finally {
      _autoRunning = false;
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('timed out')) {
      return '网络错误：连接超时或无法访问';
    }
    if (s.contains('status code of') || s.contains('HTTP')) {
      return '下载失败：$s';
    }
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  Future<void> _persist() async {
    try {
      final sp = await _prefs();
      await sp.setString(
        _key,
        jsonEncode(_items.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      _log('保存源订阅失败: $e');
    }
  }

  void _log(String msg) {
    if (kDebugMode) debugPrint('[SourceSubscription] $msg');
  }
}
