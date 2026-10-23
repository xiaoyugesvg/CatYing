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
      // 内置订阅已全部移除（用户 2026-10-18：链接自己填）。
      // 老版本播种过的 builtin 记录在这里一次性清掉，用户自己加的（builtin=false）不动。
      if (_items.any((e) => e.builtin)) {
        _items.removeWhere((e) => e.builtin);
        await _persist();
      }
      // 迁移：旧版把漫画订阅记成「综合源」，会同时出现在书源仓与漫画仓。
      // 按链接里的 comic / novel 关键字拆分，两个仓恢复独立。
      var kindMigrated = false;
      for (var i = 0; i < _items.length; i++) {
        final s = _items[i];
        if (s.kind != SourceSubscriptionKind.legado) continue;
        final u = s.url.toLowerCase();
        if (u.contains('venera')) {
          _items[i] = s.copyWith(kind: SourceSubscriptionKind.venera);
          kindMigrated = true;
        } else if (u.contains('comic')) {
          _items[i] = s.copyWith(kind: SourceSubscriptionKind.comic);
          kindMigrated = true;
        } else if (u.contains('novel') || u.contains('book')) {
          _items[i] = s.copyWith(kind: SourceSubscriptionKind.novel);
          kindMigrated = true;
        } else {
          // 仍认不出的旧「综合源」：统一归书源仓（书源仓本身也收漫画源），
          // 保证一条订阅只出现在一个仓（用户 2026-10-18）。
          _items[i] = s.copyWith(kind: SourceSubscriptionKind.novel);
          kindMigrated = true;
        }
      }
      if (kindMigrated) await _persist();
    } catch (e) {
      _log('读取源订阅失败: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<SourceSubscription?> add({
    required String name,
    required String url,
    required SourceSubscriptionKind kind,
    int updateHours = 24,
  }) async {
    await load();
    final u = url.trim();
    if (u.isEmpty) return null;
    // 同一个 URL 只在**同一边**去重：漫画仓与书源仓互不干扰
    //（用户可以给两边填相同链接/相同名称，用户 2026-10-18）。
    final sameSide = _items.where(
      (e) => kind.feedsComic ? e.kind.feedsComic : e.kind.feedsNovel,
    );
    final exist = sameSide.where((e) => e.url == u).firstOrNull;
    if (exist != null) return exist;
    final now = DateTime.now().millisecondsSinceEpoch;
    final s = SourceSubscription(
      id: 'sub_$now',
      name: name.trim().isEmpty ? u : name.trim(),
      url: u,
      kind: kind,
      updateHours: updateHours,
    );
    _items.add(s);
    await _persist();
    notifyListeners();
    return s;
  }

  /// 编辑一条订阅（名称 / 链接 / 类型 / 自动更新间隔）。
  Future<void> updateSubscription(
    String id, {
    String? name,
    String? url,
    SourceSubscriptionKind? kind,
    int? updateHours,
  }) async {
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    _items[i] = _items[i].copyWith(
      name: name?.trim(),
      url: url?.trim(),
      kind: kind,
      updateHours: updateHours,
    );
    await _persist();
    notifyListeners();
  }

  /// 手动拖动排序：按 [ids] 的顺序重排（不在列表里的保持原相对位置追加）。
  Future<void> reorder(List<String> ids) async {
    await load();
    final byId = {for (final e in _items) e.id: e};
    final ordered = <SourceSubscription>[];
    for (final id in ids) {
      final s = byId.remove(id);
      if (s != null) ordered.add(s);
    }
    ordered.addAll(byId.values);
    _items
      ..clear()
      ..addAll(ordered);
    await _persist();
    notifyListeners();
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
      return _updateVenera(sub);
    }
    // 旧记录 / 在书源仓误加的 Venera 地址：自动纠正为 Venera 订阅
    if (sub.url.toLowerCase().contains('venera')) {
      final fixed = sub.copyWith(kind: SourceSubscriptionKind.venera);
      _items[i] = fixed;
      await _persist();
      notifyListeners();
      return _updateVenera(fixed);
    }
    if (!sub.kind.supported) {
      const msg = '该源类型暂未支持';
      _items[i] = sub.copyWith(lastError: msg);
      await _persist();
      notifyListeners();
      return (ok: false, message: msg, count: 0);
    }
    // ⚠️ Dio 必须 close：每次 update 都 new 一个（自带 keep-alive 连接池），
    //    不关就会一直占着 socket/FD（批量更新时尤其明显）。
    Dio? dio;
    try {
      dio = Dio(
        BaseOptions(
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
        ),
      );
      applyGlobalProxy(dio);
      final res = await dio.get<String>(sub.url);
      final text = res.data ?? '';
      if (text.trim().isEmpty) throw Exception('订阅返回为空');

      // ── 漫画配置包（{"version":1,"sources":[{type,engine,config}]}）──
      // 只属于漫源仓库：书源仓的订阅即使混了这类内容也**不能**写进
      // SourceConfigStore（否则会跑到漫源仓库显示 —— 用户明确禁止两边串）。
      var configDefs = _parseConfigDefs(text);
      if (sub.kind != SourceSubscriptionKind.comic) {
        configDefs = const [];
      }

      // ⚠️ 不再按「是不是漫画源」过滤：用户从哪个仓导入，就原样收进哪个仓，
      //    由 _warehouse 决定显示位置（2026-10-18 用户明确要求）。
      var wanted = BookSourceImportParser.parseSources(
        text,
      ).where((s) => !s.isConfig).toList();
      final parsedCount = wanted.length;
      // 漫画仓的订阅：一律按漫画源入库（图片模式），避免书源仓的源跑过来。
      if (sub.kind == SourceSubscriptionKind.comic) {
        wanted = [
          for (final s in wanted)
            BookSource(raw: {...s.raw, 'bookSourceType': 2}, id: s.id),
        ];
      }
      // 打仓库归属（用户 2026-10-18：「从哪个仓订阅就用哪个」）：
      //   书源仓的订阅（含旧「综合源」）→ book；漫源仓库的订阅 → comic。
      final side = sub.kind.feedsComic ? 'comic' : 'book';
      wanted = [for (final s in wanted) s.withWarehouse(side)];
      if (wanted.isEmpty && configDefs.isEmpty) {
        throw Exception('没有解析到${sub.kind.label}（共 $parsedCount 条）');
      }

      // 配置源写入 SourceConfigStore（与漫画源仓库共用同一份）
      var configAdded = 0;
      var configUpdated = 0;
      if (configDefs.isNotEmpty) {
        final store = SourceConfigStore();
        final local = await store.loadLocal();
        final byId = {for (final d in local) d.id: d};
        for (final d in configDefs) {
          if (d.id.trim().isEmpty) continue;
          if (byId.containsKey(d.id)) {
            configUpdated++;
          } else {
            configAdded++;
          }
          byId[d.id] = d;
        }
        await store.saveLocal(byId.values.toList());
      }

      var added = 0;
      var updated = 0;
      var storedBookIds = <String>[];
      if (wanted.isNotEmpty) {
        final r = await BookSourceStore.instance.addAll(wanted);
        added = r.added;
        updated = r.updated;
        // ⚠️ 用**入库后的 id**：两个仓导入同一个源时，后导入的副本会
        // 拿到带仓库后缀的独立 id；记原 id 会让订阅 tab 找不到它。
        storedBookIds = r.ids;
      }
      await SourceManager().reload();

      final now = DateTime.now().millisecondsSinceEpoch;
      // ⚠️ 上面有多处 await：期间用户可能删了/拖动了订阅，
      //    原来直接用旧下标 i 写回会写错行（甚至复活已删订阅），这里按 id 重定位。
      final i2 = _items.indexWhere((e) => e.id == id);
      if (i2 < 0) {
        return (ok: false, message: '订阅已被删除', count: 0);
      }
      _items[i2] = sub.copyWith(
        count: configDefs.length + storedBookIds.length,
        lastUpdated: now,
        lastError: '',
        // 记下这条订阅带来的源 ⇒ 仓库页的订阅 tab 只显示它们
        sourceIds: [
          for (final d in configDefs) d.id,
          ...storedBookIds,
        ],
      );
      await _persist();
      notifyListeners();
      final parts = <String>[];
      if (configDefs.isNotEmpty) {
        parts.add(
          configAdded > 0 && configUpdated > 0
              ? '配置源新增 $configAdded 个、更新 $configUpdated 个'
              : (configAdded > 0
                    ? '已导入 $configAdded 个配置源'
                    : '已更新 $configUpdated 个配置源'),
        );
      }
      if (wanted.isNotEmpty) {
        parts.add('书源新增 $added 个、更新 $updated 个');
      }
      return (
        ok: true,
        message: parts.join('；'),
        count: configDefs.length + storedBookIds.length,
      );
    } catch (e) {
      final msg = _friendly(e);
      final i3 = _items.indexWhere((x) => x.id == id);
      if (i3 >= 0) {
        _items[i3] = sub.copyWith(lastError: msg);
        await _persist();
        notifyListeners();
      }
      return (ok: false, message: msg, count: 0);
    } finally {
      // 释放连接池（见方法开头说明）
      dio?.close(force: true);
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
  ) async {
    Dio? client;
    try {
      final dio = client = Dio(
        BaseOptions(
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
        ),
      );
      applyGlobalProxy(dio);
      final res = await dio.get<String>(sub.url);
      final text = res.data ?? '';
      if (text.trim().isEmpty) throw Exception('订阅返回为空');
      final trimmed = text.trimLeft();
      if (!trimmed.startsWith('[')) {
        // gh-proxy 等加速地址被限流/拦截时会返回 HTML 错误页
        throw Exception('订阅地址返回的不是 Venera index.json（可能被加速代理拦截）');
      }
      final decoded = jsonDecode(trimmed);
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
          final js = await _fetchVeneraScript(dio, scriptUrl);
          if (js == null || js.trim().isEmpty) {
            failed++;
            continue;
          }
          final idBase = fileName
              .split('/')
              .last
              .replaceAll(RegExp(r'\.js$', caseSensitive: false), '');
          final storageKey = '${e['key'] ?? ''}'.trim();
          defs.add(
            SourceDefinition(
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
            ),
          );
        }
      }

      // 4 路并发：33 个脚本串行下载太慢，全并发容易被加速代理限流
      await Future.wait([for (var w = 0; w < 4; w++) worker()]);
      if (defs.isEmpty) {
        throw Exception(
          '没有成功下载到任何脚本（失败 $failed 个，'
          '多半是加速代理限流或脚本地址不可达）',
        );
      }

      final existing = await SourceConfigStore().loadLocal();
      final newUrls = defs.map((d) => '${d.config['scriptUrl'] ?? ''}').toSet();
      // 部分脚本下载失败时保留上一版，避免一次网络抖动把源删掉；
      // 但上一版里如果是被代理拦截存下来的 HTML（不含 ComicSource），直接丢弃。
      final kept = failed == 0
          ? const <SourceDefinition>[]
          : existing
                .where(
                  (d) =>
                      d.type == 'venera' &&
                      !newUrls.contains('${d.config['scriptUrl'] ?? ''}') &&
                      _veneraClassRe.hasMatch(
                        '${d.config['script'] ?? ''}',
                      ),
                )
                .toList();

      // 清掉历史遗留的「空壳配置源」：之前 Venera index 被误解析成
      // `type=config`，只剩一个 name、没有 URL/规则 ⇒ 编辑页只有名称、
      // 点进去也没有内容。名字能和本次 Venera 条目对上的才清，避免误删用户源。
      final veneraNames = defs
          .map((d) => '${d.config['name'] ?? ''}'.trim())
          .where((e) => e.isNotEmpty)
          .toSet();
      bool isNameOnlyShell(SourceDefinition d) {
        if (d.type != 'config') return false;
        final name = '${d.config['name'] ?? ''}'.trim();
        if (!veneraNames.contains(name)) return false;
        final url = '${d.config['url'] ?? ''}'.trim();
        if (url.isNotEmpty) return false;
        for (final e in d.config.entries) {
          if (e.key == 'name' || e.key == 'url') continue;
          final v = e.value;
          if (v == null) continue;
          if (v is String && v.trim().isEmpty) continue;
          if (v is List && v.isEmpty) continue;
          if (v is Map && v.isEmpty) continue;
          return false;
        }
        return true;
      }

      final cleaned = existing
          .where((d) => d.type != 'venera' && !isNameOnlyShell(d))
          .toList();
      final merged = [...cleaned, ...kept, ...defs];
      await SourceConfigStore().saveLocal(merged);
      await SourceManager().reload();

      final now = DateTime.now().millisecondsSinceEpoch;
      // ⚠️ 上面下载 33 个脚本（`Future.wait`）耗时可达十几秒，期间用户可能
      //    删除 / 拖动订阅 ⇒ 原来直接用旧下标 `i` 写回会写错行、甚至把已删的
      //    订阅复活（与 `update()` 里 i2 那处同源）。这里按 id 重定位。
      final i2 = _items.indexWhere((e) => e.id == sub.id);
      if (i2 < 0) return (ok: false, message: '订阅已被删除', count: 0);
      _items[i2] = sub.copyWith(
        count: defs.length,
        lastUpdated: now,
        lastError: '',
        sourceIds: [for (final d in defs) d.id],
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
      final i3 = _items.indexWhere((x) => x.id == sub.id);
      if (i3 >= 0) {
        _items[i3] = sub.copyWith(lastError: msg);
        await _persist();
        notifyListeners();
      }
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

  /// 自动更新周期：每条订阅自己的 [SourceSubscription.updateHours]
  /// （0 = 只手动更新）。首次（[SourceSubscription.lastUpdated] == 0）
  /// 会立即拉取，所以新装/新加的订阅不用再手动点「更新」。
  bool _autoRunning = false;

  /// 启动时调用：把「从未更新过」或「超过各自间隔未更新」的订阅逐个拉一遍，
  /// 源体会落库（[BookSourceStore] / [SourceConfigStore]），下次启动直接用本地源，
  /// 不再依赖用户手动点更新。
  Future<void> autoUpdateStale() async {
    if (_autoRunning) return;
    _autoRunning = true;
    try {
      await load();
      final now = DateTime.now().millisecondsSinceEpoch;
      final stale = _items
          .where(
            (s) =>
                s.enabled &&
                s.kind.supported &&
                (s.lastUpdated == 0 ||
                    (s.updateHours > 0 &&
                        now - s.lastUpdated >
                            Duration(hours: s.updateHours).inMilliseconds)),
          )
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

  /// 解析漫画配置包（SiteConfig / ApiSourceConfig / 裸 config）。
  ///
  /// `{"version":1,"sources":[{type,engine?,config}]}` 是漫画源仓库的格式，
  /// 和 Legado 书源 JSON 完全不同 —— 必须写进 SourceConfigStore。
  List<SourceDefinition> _parseConfigDefs(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['sources'] is List) {
        // ⚠️ Legado 书源合集（如 x.muiu.site/…/book.json）同样是
        // `{"version":1,"sources":[…]}`, 但每条是 bookSourceName/bookSourceUrl。
        // 原来这里不区分 ⇒ 被误判成「漫画配置源」而拒绝导入（用户 2026-10-18）。
        final rawList = (decoded['sources'] as List).whereType<Map>();
        final looksBookBundle = rawList.any(
          (m) =>
              m.containsKey('bookSourceName') || m.containsKey('bookSourceUrl'),
        );
        if (looksBookBundle) return const [];
        return SourceConfigFile.fromJson(
          Map<String, dynamic>.from(decoded),
        ).sources.where((d) => d.id.trim().isNotEmpty).toList();
      }
      final list = <dynamic>[];
      if (decoded is List) {
        list.addAll(decoded);
      } else if (decoded is Map) {
        list.add(decoded);
      }
      final out = <SourceDefinition>[];
      for (final e in list) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        // Legado 书源（bookSourceName）不在这里处理
        if (m.containsKey('bookSourceName')) continue;
        // Venera index.json 的条目：{name,fileName,key,version}
        // 它不是配置源，必须走 _updateVenera 下载 .js；如果误当 config 存下来，
        // 就会变成「只有名称、没有 URL/规则」的空壳（用户 2026-10-18）。
        if (m.containsKey('fileName')) continue;
        if (m['config'] is Map) {
          final d = SourceDefinition.fromJson(m);
          if (d.id.trim().isNotEmpty) out.add(d);
        } else if (m.containsKey('name') && m.containsKey('url')) {
          out.add(
            SourceDefinition(
              id: 'config:${m['name']}',
              type: 'config',
              config: m,
            ),
          );
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static final RegExp _veneraClassRe = RegExp(
    r'extends\s+ComicSource',
    caseSensitive: false,
  );

  /// 下载一个 Venera 脚本：校验内容确实是 `class X extends ComicSource`。
  ///
  /// 走 gh-proxy 这类加速地址时，被限流会返回 **HTML 错误页**（非空字符串），
  /// 旧逻辑只判空 ⇒ 把 HTML 当脚本存进去，结果 33 个源全部加载失败。
  /// 这里先校验；失效时再退回原始 GitHub 地址重试一次。
  Future<String?> _fetchVeneraScript(Dio dio, String url) async {
    final candidates = <String>[url];
    final direct = _directGithubUrl(url);
    if (direct != null && direct != url) candidates.add(direct);
    // jsDelivr 镜像：国内通常比 raw.githubusercontent 稳定
    final cdn = _jsdelivrUrl(direct ?? url);
    if (cdn != null && !candidates.contains(cdn)) candidates.add(cdn);
    for (final u in candidates) {
      try {
        final js = (await dio.get<String>(u)).data ?? '';
        if (_veneraClassRe.hasMatch(js)) return js;
        _log('Venera 脚本内容不是 ComicSource（可能被代理拦截）: $u');
      } catch (e) {
        _log('Venera 脚本下载失败 $u: $e');
      }
    }
    return null;
  }

  /// `https://raw.githubusercontent.com/owner/repo/branch/path`
  /// → `https://cdn.jsdelivr.net/gh/owner/repo@branch/path`
  String? _jsdelivrUrl(String url) {
    final m = RegExp(
      r'raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$',
    ).firstMatch(url);
    if (m == null) return null;
    return 'https://cdn.jsdelivr.net/gh/'
        '${m.group(1)}/${m.group(2)}@${m.group(3)}/${m.group(4)}';
  }

  /// `https://gh-proxy.com/https://raw.githubusercontent.com/...`
  /// → `https://raw.githubusercontent.com/...`
  String? _directGithubUrl(String url) {
    final m = RegExp(r'^https?://[^/]+/(https?://.+)$').firstMatch(url);
    return m?.group(1);
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
