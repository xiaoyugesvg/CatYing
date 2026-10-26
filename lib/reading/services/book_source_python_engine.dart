// lib/reading/services/book_source_python_engine.dart
//
// 书源 **Python 引擎**接入层：让 `raw` 里带 `pythonKey` 字段的书源走
// CPython 引擎（`src.spider.book.<pythonKey>` 的 search/bookInfo/toc/content）。
//
// ── 接法（最小侵入）──────────────────────────────────────────
// 在 `BookSourceService._call(body)` 开头试本类：非 Python 源 / 动作未接管 /
// 失败一律返回 null ⇒ 回落既有链路（Dart 原生引擎 → Node），现行为不变。
//
// ── 动作映射（Python 侧函数签名对齐 demo.py）──────────────
// | 动作 | Python 调用 | 返回形状（对齐 bs* 契约） |
// |---|---|---|
// | bsSearch | search(keyword, page) | {ok:true, list:[{name,author,bookUrl,coverUrl,intro,kind,lastChapter}]} |
// | bsBookInfo | bookInfo(url=bookUrl) | {ok:true, info:{name,author,coverUrl,intro,lastChapter}} |
// | bsToc | toc(url=tocUrl) | {ok:true, list:[{name,url}]} |
// | bsContent | content(url=chapterUrl) | {ok:true, content:'…'} 或 {ok:true, type:'images', images:[…]} |
// | bsExplore | （无） | {ok:true, categories:[]}（Python 源无分类浏览） |
// | bsLogin | （无 source） | null ⇒ 回落 Node |
//
// 识别：书源 JSON 自定义字段 `pythonKey`（字符串，非空）。导入/编辑书源时
// 由仓库页写入该字段；模块文件名须与 pythonKey 一致（Documents 下
// python-project/src/spider/book/<pythonKey>.py，PythonSourcesService 负责同步）。

import 'dart:convert';

import 'package:tvbox/services/python_manager.dart';
import 'package:tvbox/services/python_sources_service.dart';

class BookSourcePythonEngine {
  BookSourcePythonEngine._();
  static final BookSourcePythonEngine instance = BookSourcePythonEngine._();

  static const Set<String> _supported = {
    'bsSearch',
    'bsBookInfo',
    'bsToc',
    'bsContent',
    'bsExplore',
  };

  /// 从书源 raw JSON 里取 pythonKey（无则非 Python 源）
  String? _pythonKeyOf(dynamic raw) {
    if (raw is String) {
      try {
        final j = jsonDecode(raw);
        if (j is Map) return j['pythonKey']?.toString().trim();
      } catch (_) {}
      return null;
    }
    if (raw is Map) {
      return raw['pythonKey']?.toString().trim();
    }
    return null;
  }

  /// 取源地址（与 [_pythonKeyOf] 同形：raw 可能是 JSON 串或 Map）
  String? _sourceUrlOf(dynamic source) {
    String? pick(Map m) {
      for (final k in const ['bookSourceUrl', 'url', 'api']) {
        final v = m[k]?.toString().trim();
        if (v != null && v.isNotEmpty) return v;
      }
      return null;
    }

    if (source is! Map) return null;
    final raw = source['raw'];
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final j = jsonDecode(raw);
        if (j is Map) return pick(j);
      } catch (_) {}
    }
    if (raw is Map) return pick(raw);
    return pick(source);
  }

  /// 把懒安装拿到的 key 写回 raw（下次不必再装；界面也能显示成"Python 源"）
  void _injectPythonKey(dynamic source, String key) {
    if (source is! Map) return;
    final raw = source['raw'];
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final j = jsonDecode(raw);
        if (j is Map) {
          j['pythonKey'] = key;
          source['raw'] = jsonEncode(j);
          return;
        }
      } catch (_) {}
    }
    if (raw is Map) {
      raw['pythonKey'] = key;
      return;
    }
    source['pythonKey'] = key;
  }

  /// 入口：接管则返回契约 JSON；未接管/失败返回 null（回落既有链路）
  Future<Map<String, dynamic>?> handle(Map<String, dynamic> body) async {
    final action = body['action'] as String?;
    if (action == null || !_supported.contains(action)) return null;
    var key = _pythonKeyOf(body['source']);
    if (key == null || key.isEmpty) {
      // 🔴 2026-10-14 修（"py 书源用不了"的直接原因）：
      //   JSON 书源仓库导入的 py 源，raw 里**没有 pythonKey**（全项目只有
      //   "手动选 .py 文件导入"那条路会写它）⇒ 这类源永远不走 CPython，
      //   表现为"py 书打不开 / 目录报错 / 正文空"。
      //   这里补一次**懒安装**：地址是 .py 就下载 + 注册进 CPython 拿到 key，
      //   并写回 raw（下次不用再装，界面也能正确显示成"Python 源"）。
      final u = _sourceUrlOf(body['source']);
      if (u != null && u.toLowerCase().split('?').first.endsWith('.py')) {
        final k =
            await PythonSourcesService.instance.ensureInstalled(u, 'book');
        if (k != null) {
          key = k;
          _injectPythonKey(body['source'], k);
        }
      }
    }
    if (key == null || key.isEmpty) return null;

    final args = <String, dynamic>{};
    switch (action) {
      case 'bsSearch':
        args['keyword'] = body['keyword'] ?? '';
        args['page'] = body['page'] ?? 1;
        break;
      case 'bsBookInfo':
        args['url'] = body['bookUrl'] ?? '';
        break;
      case 'bsToc':
        args['url'] = body['tocUrl'] ?? '';
        break;
      case 'bsContent':
        args['url'] = body['chapterUrl'] ?? '';
        break;
      case 'bsExplore':
        // Python 源没有分类浏览（首页导航探测是 Node 引擎能力）
        return {'ok': true, 'categories': const []};
    }

    final method = switch (action) {
      'bsSearch' => 'search',
      'bsBookInfo' => 'bookInfo',
      'bsToc' => 'toc',
      'bsContent' => 'content',
      _ => '',
    };
    if (method.isEmpty) return null;

    final r = await PythonManager.instance.call('book.$key', method, args);
    if (!r.ok) return null;
    final data = r.json;

    // 包装成 bs* 契约形状
    switch (action) {
      case 'bsSearch':
        if (data is! List) return null;
        return {
          'ok': true,
          'list': data.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList(),
        };
      case 'bsBookInfo':
        if (data is! Map) return null;
        return {'ok': true, 'info': data.cast<String, dynamic>()};
      case 'bsToc':
        if (data is! List) return null;
        return {
          'ok': true,
          'list': data.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList(),
        };
      case 'bsContent':
        if (data is String) {
          return {'ok': true, 'content': data};
        }
        if (data is Map) {
          final m = data.cast<String, dynamic>();
          final imgs = m['images'];
          if (imgs is List && imgs.isNotEmpty) {
            return {
              'ok': true,
              'type': 'images',
              'images': imgs.map((e) => e.toString()).toList(),
            };
          }
          final text = m['content'] ?? m['text'] ?? '';
          return {'ok': true, 'content': text};
        }
        return null;
    }
    return null;
  }
}
