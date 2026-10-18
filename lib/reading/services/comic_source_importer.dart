import 'dart:convert';

import '../models/book_source.dart';
import '../services/book_source_import_parser.dart';
import '../source/source_config_store.dart';
import '../source/source_definition.dart';
import '../source/source_manager.dart';

/// 漫画源导入（网址 / 文本 / 文件 / 二维码共用）。
///
/// 支持两种形态：
///   · Web 配置源：`{"type":"config","config":{"name":...,"url":...}}`
///     或裸 `{name,url,...}`；
///   · Legado 漫画脚本：含 `bookSourceName / bookSourceUrl`，统一按
///     `bookSourceType: 2` 存进书源仓库，再由 SourceManager 注册成漫画源。
///
/// Venera index.json（`[{name,fileName,key,version}]`）**不在这里处理**：
/// 必须走「漫画仓 → 添加订阅」，由订阅下载脚本。
Future<({bool ok, String message})> importComicSourcesText(String text) async {
  try {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
    final defs = <SourceDefinition>[];

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
      // Venera index 条目：不是配置源，跳过
      if (m.containsKey('fileName')) return;
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

    if (defs.isEmpty && legado.isEmpty) {
      return (
        ok: false,
        message:
            '没解析出漫画源。支持：\n'
            '① Web 配置源 {"type":"config","config":{"name":...,"url":...}}\n'
            '② Legado 书源脚本（bookSourceName / bookSourceUrl）',
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
    var added = 0;
    var updated = 0;
    for (final d in defs) {
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
