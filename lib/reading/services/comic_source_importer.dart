import 'dart:convert';

import 'package:dio/dio.dart';

import '../source/global_proxy.dart';
import '../models/book_source.dart';
import '../services/book_source_import_parser.dart';
import '../source/source_config_store.dart';
import '../source/source_definition.dart';
import '../source/source_manager.dart';

/// 漫画源导入（网址 / 文本 / 文件 / 二维码共用）。
///
/// 支持四种形态：
///   · Web 配置源：`{"type":"config","config":{"name":...,"url":...}}`
///     或裸 `{name,url,...}`；
///   · Legado 漫画脚本：含 `bookSourceName / bookSourceUrl`，统一按
///     `bookSourceType: 2` 存进书源仓库，再由 SourceManager 注册成漫画源；
///   · Venera index.json：`[{name,fileName,key,version}]`，逐个下载 `fileName`
///     指向的 `.js`（[baseUrl] 用于解析相对路径），存成 `type: venera`；
///   · 单个 Venera `.js` 脚本：直接解析 `class X extends ComicSource` 入库。
///
/// Venera 脚本原样保存，由 `VeneraMangaSource` 用内置 JS 运行时执行。
Future<({bool ok, String message})> importComicSourcesText(
  String text, {
  String baseUrl = '',
}) async {
  try {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
    final defs = <SourceDefinition>[];
    // Venera index 条目：{name, fileName, key, version}
    final veneraEntries = <Map<String, dynamic>>[];

    void take(dynamic raw) {
      if (raw is! Map) return;
      final m = raw.cast<String, dynamic>();
      if (m['json'] is String && !m.containsKey('config')) {
        try {
          final inner = jsonDecode(m['json'] as String);
          if (inner is List) {
            for (final x in inner) {
              take(x);
            }
            return;
          }
          if (inner is Map) {
            take(inner);
            return;
          }
        } catch (_) {}
      }
      // Venera index 条目：不是配置源，收集起来下载 .js
      if (m.containsKey('fileName')) {
        veneraEntries.add(m);
        return;
      }
      if (m.containsKey('config') && m['config'] is Map) {
        defs.add(SourceDefinition.fromJson(m));
        return;
      }
      if (m.containsKey('name') && m.containsKey('url')) {
        defs.add(
          SourceDefinition(
            id: 'config:${m['name']}',
            type: 'config',
            config: m,
          ),
        );
      }
    }

    if (decoded is List) {
      for (final e in decoded) {
        take(e);
      }
    } else if (decoded is Map) {
      final m = decoded.cast<String, dynamic>();
      if (m['sources'] is List) {
        for (final e in (m['sources'] as List)) {
          take(e);
        }
      } else {
        take(m);
      }
    }

    // 单个 Venera 脚本（直接粘贴/选择 .js 文件）
    final veneraDefs = <SourceDefinition>[];
    if (veneraEntries.isEmpty && _veneraClassRe.hasMatch(text)) {
      final d = _veneraDefFromScript(
        text,
        fallbackName: _guessScriptName(text),
      );
      if (d != null) veneraDefs.add(d);
    }

    // 下载 index.json 里指向的脚本（4 路并发，避免一次打满加速代理）
    var veneraFailed = 0;
    if (veneraEntries.isNotEmpty) {
      final base = baseUrl.trim();
      final results = List<SourceDefinition?>.filled(
        veneraEntries.length,
        null,
      );
      var cursor = 0;
      Future<void> worker() async {
        while (true) {
          final i = cursor++;
          if (i >= veneraEntries.length) return;
          final e = veneraEntries[i];
          final fileName = '${e['fileName'] ?? ''}'.trim();
          if (fileName.isEmpty) continue;
          final url = _resolveUrl(base, fileName);
          final js = await _downloadScript(url);
          if (js == null) {
            veneraFailed++;
            continue;
          }
          results[i] = _veneraDefFromScript(
            js,
            fallbackName: '${e['name'] ?? ''}'.trim().isEmpty
                ? _guessScriptName(js)
                : '${e['name']}'.trim(),
            storageKey: '${e['key'] ?? ''}'.trim(),
            version: '${e['version'] ?? ''}'.trim(),
            scriptUrl: url,
          );
          if (results[i] == null) veneraFailed++;
        }
      }

      await Future.wait([for (var w = 0; w < 4; w++) worker()]);
      veneraDefs.addAll(results.whereType<SourceDefinition>());
    }

    // Legado 漫画脚本
    final legado = <BookSource>[];
    try {
      for (final s in BookSourceImportParser.parseSources(text)) {
        if (s.raw['bookSourceName'] == null && s.raw['bookSourceUrl'] == null) {
          continue;
        }
        if (!s.isComicSource) continue;
        legado.add(
          BookSource(raw: {...s.raw, 'bookSourceType': 2}, id: s.id),
        );
      }
    } catch (_) {}

    if (defs.isEmpty && legado.isEmpty && veneraDefs.isEmpty) {
      return (
        ok: false,
        message: veneraFailed > 0
            ? 'Venera 脚本全部下载失败（$veneraFailed 个），请检查网络或换加速地址'
            : '没解析出漫画源。支持：\n'
                  '① Web 配置源 {"type":"config","config":{"name":...,"url":...}}\n'
                  '② Legado 书源脚本（bookSourceName / bookSourceUrl）\n'
                  '③ Venera index.json 或单个 .js 脚本',
      );
    }

    // config 源必须有 name + url，否则导入后也用不了
    final bad = <String>[];
    for (final d in defs) {
      if (d.type != 'config') continue;
      final c = d.config;
      if ((c['name'] ?? '').toString().trim().isEmpty) {
        bad.add('缺少 name');
      } else if ((c['url'] ?? '').toString().trim().isEmpty) {
        bad.add('${c['name']} 缺少 url');
      }
    }
    if (bad.isNotEmpty) {
      return (ok: false, message: '漫画源不完整：${bad.take(3).join('；')}');
    }

    final store = SourceConfigStore();
    final local = await store.loadLocal();
    final byId = {for (final d in local) d.id: d};
    // 清掉历史遗留的「名称空壳」配置源：早期把 Venera index 的
    // {name,fileName,key} 误当成 config 存了下来 ⇒ 编辑页只有一个名称、
    // 点进去没有内容。只清「名字能对上本次 Venera 条目 && 无 url/规则」的。
    final veneraNames = veneraDefs
        .map((d) => '${d.config['name'] ?? ''}'.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    if (veneraNames.isNotEmpty) {
      byId.removeWhere((_, d) => _isNameOnlyShell(d, veneraNames));
    }
    var added = 0;
    var updated = 0;
    for (final d in [...defs, ...veneraDefs]) {
      if (d.id.trim().isEmpty) continue;
      if (byId.containsKey(d.id)) {
        updated++;
      } else {
        added++;
      }
      byId[d.id] = d;
    }
    await store.saveLocal(byId.values.toList());

    var bookAdded = 0;
    var bookUpdated = 0;
    if (legado.isNotEmpty) {
      final bsStore = BookSourceStore.instance;
      if (bsStore.isEmpty) await bsStore.init();
      final r = await bsStore.addAll(legado);
      bookAdded = r.added;
      bookUpdated = r.updated;
    }

    await SourceManager().reload();

    final parts = <String>[];
    if (defs.isNotEmpty) {
      parts.add(
        added > 0 && updated > 0
            ? '新增 $added 个、更新 $updated 个漫画源'
            : (added > 0 ? '已导入 $added 个漫画源' : '已更新 $updated 个漫画源'),
      );
    }
    if (veneraDefs.isNotEmpty) {
      final nameList = veneraDefs
          .map((d) => '${d.config['name'] ?? ''}'.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final label = nameList.isEmpty
          ? ''
          : '（${nameList.take(3).join('、')}'
                '${nameList.length > 3 ? ' 等' : ''}）';
      final bytes = veneraDefs.fold<int>(
        0,
        (sum, d) => sum + '${d.config['script'] ?? ''}'.length,
      );
      parts.add(
        'Venera 源 ${veneraDefs.length} 个$label'
        '，脚本共 $bytes 字节已入库'
        '${veneraFailed > 0 ? '（$veneraFailed 个下载失败）' : ''}',
      );
    }
    if (legado.isNotEmpty) {
      parts.add(
        bookAdded > 0 && bookUpdated > 0
            ? 'Legado 漫画源新增 $bookAdded 个、更新 $bookUpdated 个'
            : (bookAdded > 0
                  ? '已导入 $bookAdded 个 Legado 漫画源'
                  : '已更新 $bookUpdated 个 Legado 漫画源'),
      );
    }
    return (ok: true, message: parts.join('；'));
  } catch (e) {
    return (ok: false, message: '导入失败：$e');
  }
}

final RegExp _veneraClassRe = RegExp(
  r'class\s+[A-Za-z_$][A-Za-z0-9_$]*\s+extends\s+ComicSource\b',
);

/// 是否是被误存成 config 的 Venera index 条目（只有 name，没有 url/规则）。
bool _isNameOnlyShell(SourceDefinition d, Set<String> names) {
  if (d.type != 'config') return false;
  if (!names.contains('${d.config['name'] ?? ''}'.trim())) return false;
  if ('${d.config['url'] ?? ''}'.trim().isNotEmpty) return false;
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

/// `class Xxx extends ComicSource` → `Xxx`（用于兜底命名）。
String _guessScriptName(String script) {
  final m = RegExp(
    r'class\s+([A-Za-z_$][A-Za-z0-9_$]*)\s+extends\s+ComicSource\b',
  ).firstMatch(script);
  return m?.group(1) ?? 'Venera';
}

/// 从脚本里取 `name = "..."` / `key = "..."`（只看前 8KB，避免匹配到方法体）。
String _fieldOf(String script, String field) {
  final head = script.length > 8192 ? script.substring(0, 8192) : script;
  final m = RegExp(
    r'\b' + field + r'''\s*[=:]\s*["'`]([^"'`]+)["'`]''',
  ).firstMatch(head);
  return m?.group(1)?.trim() ?? '';
}

SourceDefinition? _veneraDefFromScript(
  String js, {
  required String fallbackName,
  String storageKey = '',
  String version = '',
  String scriptUrl = '',
}) {
  if (!_veneraClassRe.hasMatch(js)) return null;
  final className = _guessScriptName(js);
  final name = _fieldOf(js, 'name');
  final key = _fieldOf(js, 'key');
  final idBase = scriptUrl.isNotEmpty
      ? scriptUrl
            .split('/')
            .last
            .replaceAll(RegExp(r'\.js$', caseSensitive: false), '')
      : ((storageKey.isNotEmpty ? storageKey : key).isNotEmpty
            ? (storageKey.isNotEmpty ? storageKey : key)
            : className);
  final id = 'venera:$idBase';
  return SourceDefinition(
    id: id,
    type: 'venera',
    engine: 'venera',
    config: {
      'id': id,
      'name': name.isNotEmpty ? name : fallbackName,
      'key': storageKey.isNotEmpty
          ? storageKey
          : (key.isNotEmpty ? key : idBase),
      'version': version,
      'scriptUrl': scriptUrl,
      'script': js,
    },
  );
}

String _resolveUrl(String base, String file) {
  final u = Uri.tryParse(file);
  if (u != null && u.hasScheme) return file;
  final b = Uri.tryParse(base);
  if (b == null || !b.hasScheme) return file;
  return b.resolve(file).toString();
}

Future<String?> _downloadScript(String url) async {
  final candidates = <String>[url];
  // gh-proxy 被限流时回退到 raw.githubusercontent / jsDelivr
  final ghProxy = RegExp(
    r'^https?://[^/]*gh-proxy[^/]*/(https?://.+)$',
  ).firstMatch(url);
  if (ghProxy != null) {
    final raw = ghProxy.group(1)!;
    candidates.add(raw);
    if (raw.contains('raw.githubusercontent.com')) {
      candidates.add(
        raw
            .replaceFirst('raw.githubusercontent.com', 'cdn.jsdelivr.net/gh')
            .replaceFirst('/refs/heads/', '@'),
      );
      candidates.add(
        raw.replaceFirst('raw.githubusercontent.com', 'raw.gitmirror.com'),
      );
    }
  }
  for (final u in candidates) {
    try {
      final js = await fetchComicSourceText(u);
      if (js.trim().isNotEmpty && _veneraClassRe.hasMatch(js)) return js;
    } catch (_) {}
  }
  return null;
}

Dio? _dioCache;

/// 漫画源导入/更新用的 HTTP 客户端。
///
/// **必须应用全局代理**：GitHub / gh-proxy 这类地址在国内基本都要走代理，
/// 用裸 Dio 会表现为"导入永远下载失败"。
Dio _dio() {
  final cached = _dioCache;
  if (cached != null) return cached;
  final dio = Dio(
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
  _dioCache = dio;
  return dio;
}

/// 下载一段文本（漫画源 JSON / Venera .js）。
///
/// 走全局代理；失败自动重试一次（加速地址偶发 5xx）。
Future<String> fetchComicSourceText(String url) async {
  try {
    return (await _dio().get<String>(url)).data ?? '';
  } catch (_) {
    return (await _dio().get<String>(url)).data ?? '';
  }
}
