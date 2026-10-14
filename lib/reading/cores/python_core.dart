// lib/reading/cores/python_core.dart
//
// PythonCore —— 阅读核心的 CPython 实现。
//
// 职责**只有四件事**（刻意不掺阅读器逻辑，见 reader_core.dart 的边界纪律）：
//   ① 源脚本按需落盘（下载 → 写 <Documents>/python-project/src/spider/<kind>/<key>.py）
//   ② 注册进 CPython 引擎（PythonSourcesService.installSource）
//   ③ 调引擎方法（PythonManager.call，模块 `book.<key>` / `img.<key>`）
//   ④ 把返回值映射成 ReaderCore 的数据类
//
// 源 URL 的 key 与视频侧同一套：`psrc_<md5(url)前12位>`（确定性，同一 URL 恒同 key）。

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../services/app_log.dart';
import '../../services/network_manager.dart';
import '../../services/python_manager.dart';
import '../../services/python_sources_service.dart';
import 'reader_core.dart';

class PythonCore implements ReaderCore {
  PythonCore._();
  static final PythonCore instance = PythonCore._();

  @override
  String get id => 'python';

  @override
  String get label => 'Python 源';

  @override
  bool get supportsText => true;

  @override
  bool get supportsImages => true;

  /// 本会话已确认注册过的 `kind/key`
  final Set<String> _installed = {};

  /// 当前使用的源脚本地址（.py）。由上层在"用户选定 py 书源/图源"时设置 ——
  /// 核心接口只传关键字，不传源；PythonCore 必须自己知道用哪个脚本。
  String sourceUrl = '';

  // ============================================================
  // ① 源安装（下载 + 注册）
  // ============================================================

  static String _keyFor(String url) {
    final h = md5.convert(utf8.encode(url.trim())).toString();
    return 'psrc_${h.substring(0, 12)}';
  }

  /// 确保 [url] 的 .py 已在引擎里（落盘 + 注册），返回模块 key；失败返回 null。
  Future<String?> ensureInstalled(String url, String kind) async {
    final u = url.trim();
    if (u.isEmpty) return null;
    final key = _keyFor(u);
    if (_installed.contains('$kind/$key')) return key;
    if (PythonSourcesService.instance.isRegisteredInSession(kind, key)) {
      _installed.add('$kind/$key');
      return key;
    }
    if (!PythonManager.instance.isIOS) return null;
    if (!await PythonManager.instance.ensureStarted()) {
      AppLog.instance.w('[PythonCore] 引擎未就绪，无法注册 $u');
      return null;
    }
    // 已有本地缓存就直接用；没有才下载（与视频侧 PythonScriptSources 同一策略）
    var code = await PythonSourcesService.instance.readSource(kind, key);
    if (code == null || code.trim().isEmpty) {
      try {
        code = await NetworkManager.instance.getString(u);
      } catch (e) {
        AppLog.instance.w('[PythonCore] 脚本下载失败 $u: $e');
        return null;
      }
      if (code.trim().isEmpty) return null;
    }
    final r =
        await PythonSourcesService.instance.installSource(kind, key, code);
    if (!r.ok) {
      AppLog.instance.w('[PythonCore] 注册失败 $u: ${r.message}');
      return null;
    }
    _installed.add('$kind/$key');
    AppLog.instance.log('[PythonCore] 已就绪 $kind/$key ← $u');
    return key;
  }

  // ============================================================
  // ③④ 调引擎 + 映射
  // ============================================================

  /// 调 `book.<key>` / `img.<key>` 的 [method]，返回原始结果（失败/报错返回 null）。
  Future<Map<String, dynamic>?> _call(
      String kind, String key, String method, Map<String, dynamic> args) async {
    final r = await PythonManager.instance.call('$kind.$key', method, args);
    if (!r.ok) {
      AppLog.instance.w('[PythonCore] $kind.$method 通道失败: ${r.error}');
      return null;
    }
    final data = r.json;
    if (data is Map<String, dynamic>) {
      // spider_runner 把源脚本异常包成 {ok:false,error}，通道层仍是 ok=true
      if (data['ok'] == false) {
        AppLog.instance.w('[PythonCore] $kind.$method 源报错: ${data['error']}');
        return null;
      }
      return data;
    }
    if (data is List) return {'list': data};
    return null;
  }

  /// 把可能是 List/单条的字段统一成 List<Map>
  static List<Map<String, dynamic>> _listOf(dynamic v) {
    if (v is List) {
      return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return const [];
  }

  /// [srcUrl] 会一并编进 hit.id —— 核心接口只给一个字符串 id，而 PythonCore
  /// 必须知道"用哪个源脚本"，所以把源 URL 和条目 id 一起编码（见 PythonCoreSource）。
  static List<CoreBookHit> _hits(dynamic v, String srcUrl) => _listOf(v)
      .map((m) => CoreBookHit(
            id: PythonCoreSource.encode(
                srcUrl, (m['id'] ?? m['url'] ?? '').toString()),
            name: (m['name'] ?? m['title'] ?? '').toString(),
            author: (m['author'] ?? '').toString(),
            cover: (m['cover'] ?? m['coverUrl'] ?? m['pic'] ?? '').toString(),
          ))
      .where((h) => h.name.isNotEmpty)
      .toList();

  /// 从"搜索/图片"这类结果的多种可能字段里挑第一个非空列表
  static dynamic _pickList(Map<String, dynamic> m) =>
      m['list'] ?? m['data'] ?? m['items'] ?? m['books'] ?? m['results'];

  // ── 文本 ────────────────────────────────────────────────────

  @override
  Future<List<CoreBookHit>> searchText(String keyword) async {
    final url = sourceUrl.trim();
    if (url.isEmpty) return const [];
    final key = await ensureInstalled(url, 'book');
    if (key == null) return const [];
    final q = keyword.trim();
    final m = await _call(
        'book', key, 'search', {'keyword': q, 'key': q, 'page': 1});
    if (m == null) return const [];
    return _hits(_pickList(m) ?? m, url);
  }

  @override
  Future<CoreBookDetail?> bookInfo(String id) async {
    final src = PythonCoreSource.of(id);
    final key = await ensureInstalled(src.url, 'book');
    if (key == null) return null;
    final m = await _call('book', key, 'bookInfo', {'id': src.query});
    if (m == null) return null;
    final d = (m['data'] is Map)
        ? Map<String, dynamic>.from(m['data'] as Map)
        : m;
    return CoreBookDetail(
      id: src.query,
      name: (d['name'] ?? d['title'] ?? '').toString(),
      author: (d['author'] ?? '').toString(),
      cover: (d['cover'] ?? d['coverUrl'] ?? '').toString(),
      intro: (d['intro'] ?? d['desc'] ?? '').toString(),
    );
  }

  @override
  Future<List<CoreChapter>> toc(String id) async {
    final src = PythonCoreSource.of(id);
    final key = await ensureInstalled(src.url, 'book');
    if (key == null) return const [];
    final m = await _call('book', key, 'toc', {'id': src.query});
    if (m == null) return const [];
    return _listOf(_pickList(m) ?? m)
        .map((c) => CoreChapter(
              name: (c['name'] ?? c['title'] ?? '').toString(),
              url: (c['url'] ?? c['id'] ?? '').toString(),
            ))
        .where((c) => c.name.isNotEmpty)
        .toList();
  }

  @override
  Future<String> content(String id, int chapterIndex) async {
    final src = PythonCoreSource.of(id);
    final key = await ensureInstalled(src.url, 'book');
    if (key == null) return '';
    final m = await _call('book', key, 'content',
        {'id': src.query, 'index': chapterIndex});
    if (m == null) return '';
    return (m['content'] ?? m['data'] ?? m['text'] ?? '').toString();
  }

  // ── 图片 ────────────────────────────────────────────────────

  @override
  Future<List<CoreBookHit>> searchImages(String keyword) async {
    final url = sourceUrl.trim();
    if (url.isEmpty) return const [];
    final key = await ensureInstalled(url, 'img');
    if (key == null) return const [];
    final q = keyword.trim();
    final m =
        await _call('img', key, 'search', {'keyword': q, 'key': q, 'page': 1});
    if (m == null) return const [];
    return _hits(_pickList(m) ?? m, url);
  }

  @override
  Future<List<String>> images(String id, int chapterIndex) async {
    final src = PythonCoreSource.of(id);
    final key = await ensureInstalled(src.url, 'img');
    if (key == null) return const [];
    final m = await _call('img', key, 'images',
        {'id': src.query, 'index': chapterIndex});
    if (m == null) return const [];
    // 允许两种返回：字符串列表，或 [{url:…}] 列表
    final raw = _pickList(m) ?? m['urls'] ?? m['images'];
    if (raw is List) {
      return raw
          .map((e) => e is Map ? (e['url'] ?? e['src'] ?? '').toString() : e.toString())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return const [];
  }
}

/// PythonCore 的 id 编码：`<源URL>|<条目id或搜索词>`。
///
/// 为什么这么编码：核心接口只传一个字符串 id，而 PythonCore 必须同时知道
/// "用哪个源脚本"和"查什么"。这是核心内部的约定，外面不用关心。
class PythonCoreSource {
  final String url;
  final String query;

  const PythonCoreSource(this.url, this.query);

  static const String _sep = '|';

  static PythonCoreSource of(String encoded) {
    final i = encoded.indexOf(_sep);
    if (i <= 0) return PythonCoreSource('', encoded);
    return PythonCoreSource(
        encoded.substring(0, i), encoded.substring(i + 1));
  }

  /// 把"源URL + 查询/条目"编成核心 id（[searchText]/[searchImages] 的返回里用它）
  static String encode(String url, String query) => '$url$_sep$query';
}
