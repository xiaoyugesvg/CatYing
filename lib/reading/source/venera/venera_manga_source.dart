/// Venera `ComicSource` 漫画源适配器。
///
/// 不重写源脚本：直接用 `quickjs_engine` 跑 Venera 的 `.js` 源，
/// 注入 [veneraJsPrelude] 提供的 `ComicSource / Network / Convert /
/// HtmlDocument / Comic / ComicDetails` 等全局对象，再由本类把
/// `search.load / comic.loadInfo / comic.loadEp` 桥到项目既有的
/// [MangaSource] 契约。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:quickjs_engine/quickjs_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/reading/source/manga_source.dart';
import 'package:tvbox/reading/source/models.dart';
import 'package:tvbox/reading/source/venera/venera_host_bridge.dart';
import 'package:tvbox/reading/source/venera/venera_js_prelude.dart';

class VeneraMangaSource extends MangaSource {
  VeneraMangaSource({
    required this.sourceKey,
    required this.definitionId,
    required String displayName,
    required this.script,
    this.scriptUrl = '',
    this.onToast,
    this.onLaunchUrl,
  }) : _displayName = displayName;

  /// 源定义里的唯一 id（`venera:<fileName>`，同一个 key 可以有多个脚本）。
  final String definitionId;

  /// Venera 脚本内的 `key`（与源存储/账号数据绑定，必须保持稳定）。
  final String sourceKey;

  /// 脚本原文（来自订阅 index.json 指向的 .js）。
  final String script;

  /// 脚本下载地址（仅用于排查/展示）。
  final String scriptUrl;

  final void Function(String message)? onToast;
  final void Function(String url)? onLaunchUrl;

  final String _displayName;

  JavascriptRuntime? _runtime;
  Future<void>? _initFuture;

  /// 是否有 JS 任务正在轮询（dispose 要等它结束再关运行时）。
  bool _running = false;
  bool _disposeRequested = false;

  /// 章节图请求头（由 `comic.onImageLoad` 返回）。
  Map<String, String> _chapterHeaders = const {};
  String? _chapterReferer;

  /// ehentai 等源的图床令牌（onImageLoad 返回的 nl），后续页必须带上。
  String? _chapterNl;
  String? _chapterNlEpId;

  /// 封面/列表缩略图请求头（由 `comic.onThumbnailLoad` 返回）。
  Map<String, String> _thumbHeaders = const {};
  String? _thumbReferer;

  Future<void> _tail = Future.value();

  @override
  String get id => definitionId;

  @override
  String get name => _displayName;

  @override
  String get lang => 'zh';

  @override
  bool get supportsLatest => true;

  @override
  bool get supportsCategories => true;

  @override
  Map<String, String> get imageHeaders => {
    'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
        'Mobile/15E148 Safari/604.1',
    ..._thumbHeaders,
    ..._chapterHeaders,
  };

  @override
  String? get referer => _thumbReferer;

  @override
  String? refererForChapter(CChapter chapter) =>
      _chapterReferer ?? _thumbReferer;

  void _log(String message) {
    if (kDebugMode) debugPrint('[VeneraSource:$sourceKey] $message');
  }

  @override
  void dispose() {
    // 正在跑 JS 任务时不能直接 close（会让轮询 evaluate 落到已释放的 context）。
    // 打标记，等任务结束后再关。
    if (_running) {
      _disposeRequested = true;
      return;
    }
    _closeRuntime();
  }

  void _closeRuntime() {
    final rt = _runtime;
    _runtime = null;
    _initFuture = null;
    if (rt is QuickJsRuntime2) {
      try {
        rt.close();
      } catch (e) {
        _log('关闭 JS 运行时失败: $e');
      }
    }
  }

  // ────────────────────────── 源设置（Venera settings）──────────────────────────

  /// 源声明的可配置项（select / input / switch / text）。
  Future<List<Map<String, dynamic>>> fetchSettings() async {
    await _ensureReady();
    final rt = _runtime;
    if (rt == null) return const [];
    final raw = rt
        .evaluate('JSON.stringify(__veneraSettingsInfo())')
        .stringResult;
    if (raw.isEmpty || raw == 'undefined' || raw == 'null') return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final e in list.whereType<Map>())
          e.map((k, v) => MapEntry('$k', v)),
      ];
    } catch (e) {
      _log('读取源设置失败: $e');
      return const [];
    }
  }

  /// 当前生效值（已保存 > 默认）。
  Future<Object?> readSetting(String key) async {
    await _ensureReady();
    final rt = _runtime;
    if (rt == null) return null;
    final raw = rt
        .evaluate('JSON.stringify(__veneraSettingValue(${jsonEncode(key)}))')
        .stringResult;
    if (raw.isEmpty || raw == 'undefined' || raw == 'null') return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  /// 保存设置：写入与 `load_setting` 相同的 prefs 键，随后重跑 init()
  /// （部分源在 init 里按设置选线路/域名）。
  Future<void> saveSetting(String key, Object? value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'venera_setting_${sourceKey}_$key',
      jsonEncode(value),
    );
    try {
      await _run('init', const {});
    } catch (e) {
      _log('设置已保存，但重跑 init 失败: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════
  // 初始化
  // ══════════════════════════════════════════════════════════════

  Future<void> _ensureReady() {
    final cached = _initFuture;
    if (cached != null) return cached;
    final future = _init();
    _initFuture = future;
    // 失败后允许下次重试（例如 init() 里的一次网络抖动）
    future.catchError((Object _) {
      if (identical(_initFuture, future)) _initFuture = null;
    });
    return future;
  }

  Future<void> _init() async {
    final className = _detectClassName(script);
    if (className == null) {
      throw Exception(
        '不是合法的 Venera ComicSource 脚本（未找到 extends ComicSource 的类）',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    final runtime = getJavascriptRuntime(
      extraArgs: const {'timeout': 30000, 'memoryLimit': 64 * 1024 * 1024},
    );
    final bridge = VeneraHostBridge(
      sourceKey: sourceKey,
      prefs: prefs,
      onToast: onToast,
      onLaunchUrl: onLaunchUrl,
    );
    runtime.onMessage('venera', bridge.handle);

    final prelude = runtime.evaluate(veneraJsPrelude);
    if (prelude.isError) {
      throw Exception('Venera 运行时初始化失败: ${prelude.stringResult}');
    }
    final loaded = runtime.evaluate(
      '$script\n;globalThis.__veneraSourceClass = $className;',
    );
    if (loaded.isError) {
      throw Exception('Venera 源脚本加载失败: ${loaded.stringResult}');
    }
    final created = runtime.evaluate(
      'globalThis.__veneraSrc = new globalThis.__veneraSourceClass();'
      'globalThis.__veneraCaptureDefaults();',
    );
    if (created.isError) {
      throw Exception('Venera 源实例化失败: ${created.stringResult}');
    }
    _runtime = runtime;
    // init() 里可能有网络请求（如拉取站点配置）。**init 失败不能拖垮整个源**：
    // 很多源把「探测可用域名 / 预登录」放在 init 里，站点抖动时它会抛错，
    // 但 explore/search 本身仍然能用。以前这里直接冒泡 ⇒ 源永远空白。
    try {
      final r = await _runRaw('init', const {});
      if (r != null && r is Map && r['error'] != null) {
        _log('init 返回错误（忽略）: ${r['error']}');
      }
    } catch (e) {
      _log('init 失败（忽略，继续可用）: $e');
    }
    _log('已就绪（$sourceKey，$className，脚本 ${script.length} 字节）');
  }

  static String? _detectClassName(String script) {
    final m = RegExp(
      r'class\s+([A-Za-z_$][A-Za-z0-9_$]*)\s+extends\s+ComicSource\b',
    ).firstMatch(script);
    return m?.group(1);
  }

  // ══════════════════════════════════════════════════════════════
  // JS 任务执行
  // ══════════════════════════════════════════════════════════════

  Future<T> _serial<T>(Future<T> Function() fn) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await fn());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<dynamic> _run(String kind, Map<String, dynamic> args) async {
    await _ensureReady();
    return _serial(() => _runRaw(kind, args));
  }

  /// 调用 JS 入口并等待 Promise 落定（不排队，仅 init 期间使用）。
  Future<dynamic> _runRaw(String kind, Map<String, dynamic> args) async {
    final rt = _runtime;
    if (rt == null) throw Exception('Venera 运行时未初始化');
    _running = true;
    try {
      final kindJson = jsonEncode(kind);
      final argsJson = jsonEncode(
        args,
      ).replaceAll('\u2028', '\\u2028').replaceAll('\u2029', '\\u2029');
      final started = rt.evaluate('__veneraRun($kindJson, $argsJson);');
      if (started.isError) {
        throw Exception('Venera 源调用失败: ${started.stringResult}');
      }
      final sw = Stopwatch()..start();
      while (true) {
        rt.executePendingJob();
        final state = rt.evaluate('__veneraJobState').stringResult;
        if (state == 'ok') {
          // __veneraStringify：把 JS Map/Set 转成普通对象/数组再序列化
          // （Venera 源用 Map 表示章节分组，JSON.stringify 直出会是空对象）
          final raw = rt
              .evaluate('__veneraStringify(__veneraJobValue)')
              .stringResult;
          if (raw.isEmpty || raw == 'undefined' || raw == 'null') return null;
          try {
            return jsonDecode(raw);
          } catch (_) {
            final brief = raw.length > 200 ? '${raw.substring(0, 200)}…' : raw;
            throw Exception('Venera 源返回了无法解析的数据（$kind）: $brief');
          }
        }
        if (state == 'err') {
          final err = rt.evaluate('__veneraJobError').stringResult;
          throw Exception(err.isEmpty ? 'Venera 源执行失败' : err);
        }
        if (sw.elapsed > const Duration(seconds: 60)) {
          throw Exception('Venera 源执行超时（$kind）');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    } finally {
      _running = false;
      if (_disposeRequested) {
        _disposeRequested = false;
        _closeRuntime();
      }
    }
  }

  // ══════════════════════════════════════════════════════════════
  // 列表 / 搜索
  // ══════════════════════════════════════════════════════════════

  @override
  Future<MangasPage> search(
    String query, {
    int page = 0,
    FilterList filters = const FilterList(),
  }) async {
    final r = await _run('search', {'query': query, 'page': page + 1});
    return _mapPage(r, page);
  }

  Future<MangasPage> _explore(int index, int page) async {
    final r = await _run('explore', {'index': index, 'page': page + 1});
    return _mapPage(r, page);
  }

  @override
  Future<MangasPage> getPopular({int page = 0}) => _explore(0, page);

  @override
  Future<MangasPage> getLatestUpdates({int page = 0}) => _explore(0, page);

  @override
  Future<List<FilterGroup>> fetchCategories() async {
    // 不吞异常：首页据此把真实错误（脚本报错 / HTTP 403 / 域名不可达）
    // 显示出来。以前 catch 后返回空列表 ⇒ 页面只剩空白，完全无法排查。
    await _ensureReady();
    final raw = _runtime!
        .evaluate('JSON.stringify(__veneraExploreInfo())')
        .stringResult;
    final list = jsonDecode(raw);
    if (list is! List || list.isEmpty) return const [];
    const all = FilterOption(value: '-1', name: '全部', isAll: true);
    return [
      FilterGroup(
        key: '__explore__',
        title: '分类',
        options: [
          all,
          for (final e in list.whereType<Map>())
            FilterOption(
              value: '${e['index'] ?? 0}',
              name: '${e['title'] ?? '列表'}',
            ),
        ],
        selected: all,
      ),
    ];
  }

  @override
  Future<MangasPage> getCategoryList(
    List<FilterGroup> groups, {
    int page = 0,
  }) {
    var index = 0;
    for (final g in groups) {
      if (g.key != '__explore__') continue;
      final v = g.selected?.value;
      if (v != null && !g.selected!.isAll) index = int.tryParse(v) ?? 0;
    }
    return _explore(index, page);
  }

  Future<MangasPage> _mapPage(dynamic r, int page) async {
    // 三种返回形态都要兼容（对应 Venera explore.type）：
    //   · multiPartPage           → [{title, comics: [...]}, ...]（列表）
    //   · singlePageWithMultiPart → {分区名: [Comic, ...], ...}（对象套数组）
    //   · *ComicList              → {comics: [...], maxPage: n}（对象）
    var maxPage = 1;
    var hasPageInfo = false;
    final flat = <Map>[];
    if (r is List) {
      for (final part in r.whereType<Map>()) {
        final comics = part['comics'];
        if (comics is List) flat.addAll(comics.whereType<Map>());
        final mp = (part['maxPage'] as num?)?.toInt();
        if (mp != null) {
          hasPageInfo = true;
          if (mp > maxPage) maxPage = mp;
        }
      }
    } else if (r is Map) {
      final comics = r['comics'];
      if (comics is List) {
        flat.addAll(comics.whereType<Map>());
        maxPage = (r['maxPage'] as num?)?.toInt() ?? 1;
        hasPageInfo = true;
      } else {
        for (final v in r.values) {
          if (v is List) {
            flat.addAll(v.whereType<Map>());
          } else if (v is Map) {
            // 少数源返回 {分区名: {title, comics: [...]}} 的嵌套结构
            final inner = v['comics'];
            if (inner is List) flat.addAll(inner.whereType<Map>());
            final mp = (v['maxPage'] as num?)?.toInt();
            if (mp != null) {
              hasPageInfo = true;
              if (mp > maxPage) maxPage = mp;
            }
          }
        }
      }
    }
    final list = _mapComics(flat);
    final shown = list.isEmpty ? list : await _applyThumbnailHeaders(list);
    return MangasPage(
      items: shown,
      hasNextPage: hasPageInfo && page + 1 < maxPage,
    );
  }

  List<CManga> _mapComics(List<Map> comics) {
    final list = <CManga>[];
    for (final c in comics) {
      final m = _toCManga(c);
      if (m.title.isNotEmpty || m.id.isNotEmpty) list.add(m);
    }
    return list;
  }

  CManga _toCManga(Map c) {
    final rawTags = c['tags'];
    final tags = rawTags is List
        ? rawTags.map((e) => '$e').where((e) => e.isNotEmpty).toList()
        : null;
    final cover = _normalizeUrl('${c['cover'] ?? ''}');
    return CManga(
      id: '${c['id'] ?? ''}',
      sourceId: id,
      title: '${c['title'] ?? ''}'.trim(),
      cover: cover,
      author: (c['subtitle'] ?? c['subTitle'])?.toString(),
      description: c['description']?.toString(),
      tags: tags,
      url: c['url']?.toString(),
    );
  }

  String _normalizeUrl(String url) {
    if (url.isEmpty) return url;
    if (url.startsWith('//')) return 'https:$url';
    return url;
  }

  // ══════════════════════════════════════════════════════════════
  // 详情 / 章节
  // ══════════════════════════════════════════════════════════════

  @override
  Future<({CManga manga, List<CChapter> chapters})> getMangaDetailsAndChapters(
    CManga manga,
  ) async {
    final r = await _run('info', {'id': manga.id});
    if (r is! Map) {
      throw Exception('Venera 源没有返回漫画详情');
    }
    final tagMap = r['tags'];
    final tags = <String>[];
    String? author;
    if (tagMap is Map) {
      for (final e in tagMap.entries) {
        final ns = '${e.key}'.toLowerCase();
        final values = e.value is List
            ? (e.value as List).map((v) => '$v').toList()
            : ['${e.value}'];
        if (const [
          'author',
          'authors',
          'artist',
          'artists',
          '作者',
          '画师',
        ].contains(ns)) {
          author ??= values.join(', ');
        }
        tags.addAll(values.where((v) => v.isNotEmpty));
      }
    }

    final chapters = <CChapter>[];
    final ch = r['chapters'];
    if (ch is Map) {
      var order = 0;
      for (final entry in ch.entries) {
        final value = entry.value;
        if (value is Map) {
          final groupName = '${entry.key}';
          for (final sub in value.entries) {
            chapters.add(
              CChapter(
                id: '${sub.key}',
                sourceId: id,
                mangaId: manga.id,
                name: '${sub.value}',
                order: order++,
                groupId: groupName,
                groupName: groupName,
              ),
            );
          }
        } else {
          chapters.add(
            CChapter(
              id: '${entry.key}',
              sourceId: id,
              mangaId: manga.id,
              name: '$value',
              order: order++,
            ),
          );
        }
      }
    }

    final cover = _normalizeUrl('${r['cover'] ?? manga.cover}');
    final result = manga.copyWith(
      id: manga.id,
      sourceId: id,
      title: '${r['title'] ?? manga.title}'.trim(),
      cover: cover,
      author: author ?? manga.author,
      description: r['description']?.toString() ?? manga.description,
      tags: tags.isEmpty ? manga.tags : tags,
      url: r['url']?.toString() ?? manga.url,
      updateTime: _parseTime(r['updateTime'] ?? r['uploadTime']),
      totalChapters: chapters.isEmpty ? manga.totalChapters : chapters.length,
      initialized: true,
    );
    final fixed = (await _applyThumbnailHeaders([result])).first;
    return (manga: fixed, chapters: chapters);
  }

  @override
  Future<CManga> getMangaDetails(CManga manga) async =>
      (await getMangaDetailsAndChapters(manga)).manga;

  @override
  Future<List<CChapter>> getChapterList(CManga manga) async =>
      (await getMangaDetailsAndChapters(manga)).chapters;

  DateTime? _parseTime(Object? value) {
    if (value == null) return null;
    if (value is num) return _fromEpoch(value);
    final text = '$value'.trim();
    if (text.isEmpty) return null;
    final n = int.tryParse(text);
    if (n != null && (text.length == 10 || text.length == 13)) {
      return _fromEpoch(n);
    }
    return DateTime.tryParse(text);
  }

  DateTime _fromEpoch(num v) => v > 100000000000
      ? DateTime.fromMillisecondsSinceEpoch(v.toInt())
      : DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());

  @override
  Future<List<String>> getChapterImages(CManga manga, CChapter chapter) async {
    final r = await _run('ep', {'comicId': manga.id, 'epId': chapter.id});
    // 标准返回 {images: [...]}；少数源直接返回图片数组，一并兼容
    final raw = r is Map ? r['images'] : (r is List ? r : null);
    if (raw is! List) {
      return const [];
    }
    final images = raw
        .map((e) => _normalizeUrl('$e'))
        .where((e) => e.isNotEmpty)
        .toList();
    if (images.isEmpty) return images;

    // nl 只在同一章内有效，换章必须重新取
    if (_chapterNlEpId != chapter.id) {
      _chapterNl = null;
      _chapterNlEpId = chapter.id;
    }

    // onImageLoad 可能给出图床地址/防盗链头（异步、允许返回 null）
    try {
      final cfg = await _run('imageConfigs', {
        'urls': images,
        'comicId': manga.id,
        'epId': chapter.id,
        'nl': _chapterNl,
      });
      if (cfg is Map) {
        final out = <String>[];
        final headers = <String, String>{};
        String? referer;
        for (final url in images) {
          final c = cfg[url];
          if (c is String && c.isNotEmpty) {
            out.add(c);
          } else if (c is Map) {
            final newUrl = '${c['url'] ?? ''}';
            out.add(newUrl.isEmpty ? url : newUrl);
            final nl = '${c['nl'] ?? ''}'.trim();
            if (nl.isNotEmpty) _chapterNl = nl;
            final h = c['headers'];
            if (h is Map) {
              for (final e in h.entries) {
                headers['${e.key}'] = '${e.value}';
                if ('${e.key}'.toLowerCase() == 'referer') {
                  referer = '${e.value}';
                }
              }
            }
          } else {
            out.add(url);
          }
        }
        if (headers.isNotEmpty) _chapterHeaders = headers;
        if (referer != null) _chapterReferer = referer;
        return out;
      }
    } catch (e) {
      _log('onImageLoad 调用失败（按默认头加载）: $e');
    }
    return images;
  }

  /// 调 `onThumbnailLoad`：拿封面防盗链头，并应用源给出的 URL 改写
  /// （如 ehentai 把 `s.exhentai.org` 换成 `ehgt.org`，不改写会整片封面 403）。
  Future<List<CManga>> _applyThumbnailHeaders(List<CManga> list) async {
    final covers = list
        .map((e) => e.cover)
        .where((e) => e.startsWith('http'))
        .toSet()
        .toList();
    if (covers.isEmpty) return list;
    try {
      final cfg = await _run('thumbConfigs', {'urls': covers});
      if (cfg is! Map || cfg.isEmpty) return list;
      final headers = <String, String>{};
      final rewrites = <String, String>{};
      String? referer;
      for (final entry in cfg.entries) {
        final c = entry.value;
        if (c is String && c.isNotEmpty) {
          if (c != entry.key) rewrites['${entry.key}'] = c;
          continue;
        }
        if (c is! Map) continue;
        final newUrl = '${c['url'] ?? ''}';
        if (newUrl.isNotEmpty && newUrl != '${entry.key}') {
          rewrites['${entry.key}'] = newUrl;
        }
        final h = c['headers'];
        if (h is! Map) continue;
        for (final e in h.entries) {
          headers['${e.key}'] = '${e.value}';
          if ('${e.key}'.toLowerCase() == 'referer') {
            referer = '${e.value}';
          }
        }
      }
      if (headers.isNotEmpty) _thumbHeaders = headers;
      if (referer != null) _thumbReferer = referer;
      if (rewrites.isEmpty) return list;
      return [
        for (final m in list)
          rewrites[m.cover] == null ? m : m.copyWith(cover: rewrites[m.cover]),
      ];
    } catch (e) {
      _log('onThumbnailLoad 调用失败（封面按默认头加载）: $e');
      return list;
    }
  }
}
