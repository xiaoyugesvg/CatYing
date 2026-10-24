import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reader_style.dart';

/// 用户保存的一套「标题样式」（HTML 源码 + 名字）。
class TitleStylePreset {
  const TitleStylePreset({
    required this.id,
    required this.name,
    required this.html,
  });

  final String id;
  final String name;
  final String html;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'html': html};

  static TitleStylePreset? fromJson(Map<String, dynamic> j) {
    final html = (j['html'] as String?) ?? '';
    if (html.trim().isEmpty) return null;
    return TitleStylePreset(
      id: (j['id'] as String?) ?? 'title:${DateTime.now().millisecondsSinceEpoch}',
      name: (j['name'] as String?) ?? '未命名',
      html: html,
    );
  }
}

/// 「阅读样式」的持久化：用户样式列表 + 当前选中的样式 id。
///
/// 内置样式不落盘（代码里就有），只在 `active` 里记 id，方便卡片上打「当前」标。
class ReaderStyleStore {
  static const _kCustom = 'reading.styles.custom';
  static const _kActive = 'reading.styles.active';
  static const _kTitles = 'reading.titleStyles';

  Future<List<ReaderStyle>> loadCustom() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kCustom);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      return [
        for (final e in list)
          if (e is Map) ReaderStyle.fromJson(Map<String, dynamic>.from(e)),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveCustom(List<ReaderStyle> styles) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _kCustom,
        jsonEncode([for (final s in styles) s.toJson()]),
      );
    } catch (_) {}
  }

  Future<String?> loadActiveId() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getString(_kActive);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveActiveId(String id) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kActive, id);
    } catch (_) {}
  }

  /// 我保存的「标题样式」列表
  Future<List<TitleStylePreset>> loadTitleStyles() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kTitles);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      return [
        for (final e in list)
          if (e is Map)
            ?TitleStylePreset.fromJson(Map<String, dynamic>.from(e)),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveTitleStyles(List<TitleStylePreset> list) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _kTitles,
        jsonEncode([for (final e in list) e.toJson()]),
      );
    } catch (_) {}
  }
}

/// Legado「导入排版」文件（`.zip` / `.json` / `legado://` 链接）→ [ReaderStyle]。
class ReaderStyleImporter {
  /// 从用户输入里抠出真正的 http(s) 地址。
  ///
  /// 站点给的是 `legado://import/readConfig?src=https://.../readcode/id/108.zip`，
  /// 用户直接贴整串也能用；也接受裸链接。
  static String? extractUrl(String input) {
    var s = input.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('legado://')) {
      final uri = Uri.tryParse(s);
      final src = uri?.queryParameters['src'];
      if (src == null || src.isEmpty) return null;
      s = src;
    }
    final uri = Uri.tryParse(s);
    if (uri == null || !uri.hasScheme) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return s;
  }

  /// 下载并解析（返回解析后的 readConfig Map；失败返回 null）
  static Future<Map<String, dynamic>?> fetchConfig(
    String url, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        responseType: ResponseType.bytes,
        followRedirects: true,
        validateStatus: (c) => c != null && c < 400,
      ),
    );
    try {
      final res = await dio.get<List<int>>(url);
      final bytes = res.data;
      if (bytes == null || bytes.isEmpty) return null;
      return decodeConfig(Uint8List.fromList(bytes));
    } catch (_) {
      return null;
    } finally {
      dio.close();
    }
  }

  /// `.zip`（内含 readConfig.json）或裸 `.json` 的字节 → Map
  static Map<String, dynamic>? decodeConfig(List<int> bytes) {
    if (bytes.isEmpty) return null;
    // zip 头 PK\x03\x04
    final isZip =
        bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04;
    if (isZip) {
      try {
        final archive = ZipDecoder().decodeBytes(bytes, verify: false);
        ArchiveFile? picked;
        for (final f in archive) {
          if (!f.isFile) continue;
          final n = f.name.toLowerCase();
          if (n.endsWith('readconfig.json')) {
            picked = f;
            break;
          }
          if (picked == null && n.endsWith('.json')) picked = f;
        }
        if (picked == null) return null;
        final data = picked.content as List<int>;
        final map = jsonDecode(utf8.decode(data, allowMalformed: true));
        return map is Map ? Map<String, dynamic>.from(map) : null;
      } catch (_) {
        return null;
      }
    }
    try {
      final map = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return map is Map ? Map<String, dynamic>.from(map) : null;
    } catch (_) {
      return null;
    }
  }
}
