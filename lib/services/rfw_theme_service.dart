import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rfw/formats.dart' show parseLibraryFile;
import 'package:rfw/rfw.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

/// 一个可用的 RFW 主题
class RfwTheme {
  /// 唯一标识（内置主题用固定名，导入主题用文件名）
  final String id;

  /// 展示名
  final String name;

  /// `.rfwtxt` 全文
  final String source;

  /// 是否为内置主题（内置的不可删除）
  final bool builtin;

  const RfwTheme({
    required this.id,
    required this.name,
    required this.source,
    this.builtin = false,
  });
}

/// RFW 主题引擎
///
/// 负责：
/// 1. 管理 `.rfwtxt` 主题文件（内置 + 用户导入），持久化到 Documents 目录；
/// 2. 用 `package:rfw` 解析主题文本；
/// 3. 把 App 的首页数据转换成 RFW 的 DynamicMap 数据契约；
/// 4. 语法检查（导入时给出可读错误）。
///
/// ⚠️ 关于数据契约的硬约束（踩过的坑）：
/// rfw 的 `DynamicContent.updateKey` 内部 `_hasValidType` **只接受**
/// DynamicMap / DynamicList / int / double / bool / String —— **不接受 null**。
/// 而 spider 源的数据里 null 极多（vod_year / vod_area / vod_actor 常为空），
/// 直接塞进去会在 debug 模式触发 assert、release 下行为未定义。
/// 所以所有写入 rfw 的数据必须先过 [sanitizeForRfw]。
class RfwThemeService {
  RfwThemeService._();
  static final RfwThemeService instance = RfwThemeService._();

  static const String _currentKey = 'rfw_current_theme';
  static const String _enabledKey = 'rfw_theme_enabled';
  static const String _dirName = 'themes';

  /// 当前选中的主题 id；空串 = 不使用 RFW 主题（走原生首页）
  final currentThemeId = ''.obs;

  /// 是否启用 RFW 自定义首页
  final enabled = false.obs;

  /// 已导入的用户主题
  final userThemes = <RfwTheme>[].obs;

  /// 解析失败的最近一次错误（供 UI 展示）
  final lastError = ''.obs;

  Directory? _dir;

  Future<Directory> _ensureDir() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/$_dirName');
    if (!d.existsSync()) d.createSync(recursive: true);
    _dir = d;
    return d;
  }

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(_enabledKey) ?? false;
      currentThemeId.value = prefs.getString(_currentKey) ?? '';
      await _loadUserThemes();
      AppLog.instance.log('[RfwTheme] init: enabled=${enabled.value}, '
          'current=${currentThemeId.value}, userThemes=${userThemes.length}');
    } catch (e) {
      AppLog.instance.log('[RfwTheme] init 失败: $e');
    }
  }

  Future<void> _loadUserThemes() async {
    final dir = await _ensureDir();
    final list = <RfwTheme>[];
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.rfwtxt')) continue;
      try {
        list.add(RfwTheme(
          id: name,
          name: _displayNameFromFileName(name),
          source: f.readAsStringSync(),
        ));
      } catch (e) {
        AppLog.instance.log('[RfwTheme] 读取 $name 失败: $e');
      }
    }
    userThemes.assignAll(list);
  }

  String _displayNameFromFileName(String fileName) {
    var n = fileName;
    if (n.endsWith('.rfwtxt')) n = n.substring(0, n.length - 7);
    return n.isEmpty ? fileName : n;
  }

  Future<void> setEnabled(bool v) async {
    enabled.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, v);
  }

  Future<void> setCurrent(String id) async {
    currentThemeId.value = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_currentKey, id);
  }

  /// 当前主题的文本。为空则表示没有可用主题（回退原生首页）。
  String get currentThemeSource {
    if (!enabled.value) return '';
    final id = currentThemeId.value;
    if (id.isEmpty) return '';
    for (final t in userThemes) {
      if (t.id == id) return t.source;
    }
    return '';
  }

  // ============================================================
  // 解析
  // ============================================================

  /// 语法检查：返回 null 表示通过，否则返回可读错误信息。
  String? validate(String source) {
    if (source.trim().isEmpty) return '主题内容为空';
    try {
      parseLibraryFile(source, sourceIdentifier: 'theme');
      return null;
    } catch (e) {
      return '$e';
    }
  }

  /// 解析成 rfw 的 RemoteWidgetLibrary。失败返回 null 并记录 [lastError]。
  RemoteWidgetLibrary? parse(String source) {
    try {
      final lib = parseLibraryFile(source, sourceIdentifier: 'theme');
      lastError.value = '';
      return lib;
    } catch (e) {
      lastError.value = '$e';
      AppLog.instance.log('[RfwTheme] 解析失败: $e');
      return null;
    }
  }

  // ============================================================
  // 导入 / 删除
  // ============================================================

  /// 从文本导入主题（可指定文件名，默认按主题名生成）。
  /// 成功返回主题 id，语法错误返回 null 并把原因写入 [lastError]。
  Future<String?> importFromText(String source, {String? fileName}) async {
    final err = validate(source);
    if (err != null) {
      lastError.value = err;
      return null;
    }
    var name = fileName?.trim() ?? '';
    if (name.isEmpty) {
      name = 'theme_${DateTime.now().millisecondsSinceEpoch}.rfwtxt';
    }
    if (!name.endsWith('.rfwtxt')) name = '$name.rfwtxt';
    final dir = await _ensureDir();
    final f = File('${dir.path}/$name');
    await f.writeAsString(source);
    await _loadUserThemes();
    lastError.value = '';
    AppLog.instance.log('[RfwTheme] 已导入: $name');
    return name;
  }

  Future<void> deleteUserTheme(String id) async {
    final dir = await _ensureDir();
    try {
      final f = File('${dir.path}/$id');
      if (f.existsSync()) f.deleteSync();
    } catch (e) {
      AppLog.instance.log('[RfwTheme] 删除 $id 失败: $e');
    }
    if (currentThemeId.value == id) await setCurrent('');
    await _loadUserThemes();
  }

  // ============================================================
  // 数据契约
  // ============================================================

  /// 递归净化：只保留 rfw 支持的类型，丢弃 null。
  ///
  /// rfw 的 `_hasValidType` 不接受 null，spider 数据里 null 很常见，
  /// 不过这一层就会在 debug 触发 assert。
  static Object? sanitizeForRfw(Object? value) {
    if (value == null) return null; // 由调用方剔除
    if (value is String || value is bool || value is int || value is double) {
      return value;
    }
    if (value is num) return value.toDouble();
    if (value is Map) {
      final out = <String, Object?>{};
      value.forEach((k, v) {
        final cleaned = sanitizeForRfw(v);
        if (cleaned != null) out['$k'] = cleaned;
      });
      return out;
    }
    if (value is Iterable) {
      final out = <Object?>[];
      for (final v in value) {
        final cleaned = sanitizeForRfw(v);
        if (cleaned != null) out.add(cleaned);
      }
      return out;
    }
    // 其它类型（枚举/实体类等）转字符串，保证不破坏类型约束
    return '$value';
  }

  /// 构建 data 根节点。主题里通过 `data.home.*` 访问。
  static Map<String, Object?> buildData({
    required List<Map<String, Object?>> items,
    int gridColumns = 3,
    List<Map<String, Object?>> categories = const [],
    List<Map<String, Object?>> recommend = const [],
    String selectedCategoryId = '',
    bool loading = false,
    bool hasMore = false,
  }) {
    Map<String, Object?> clean(Map<String, Object?> m) =>
        (sanitizeForRfw(m) as Map?)?.cast<String, Object?>() ?? {};

    final data = <String, Object?>{
      'home': <String, Object?>{
        'items': items.map(clean).toList(),
        'gridColumns': gridColumns,
        'categories': categories.map(clean).toList(),
        'recommend': recommend.map(clean).toList(),
        'selectedCategoryId': selectedCategoryId,
        'loading': loading,
        'hasMore': hasMore,
      },
    };
    return (sanitizeForRfw(data) as Map).cast<String, Object?>();
  }
}
