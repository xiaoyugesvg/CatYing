import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

class EpgProgram {
  final String title;
  final DateTime? start;
  final DateTime? stop;
  EpgProgram({required this.title, this.start, this.stop});
}

/// 直播 EPG：从全局 epg_url 拉 XMLTV，按频道名取今日节目
class EpgService extends GetxService {
  static EpgService get instance => Get.find<EpgService>();

  final isWorking = false.obs;
  Dio? _dio;

  Dio get _dioC {
    return _dio ??= Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
    ));
  }

  /// 简易内存缓存：频道名 -> 节目
  final Map<String, List<EpgProgram>> _cache = {};
  DateTime _cacheAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<String> loadEpgUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString('epg_url') ?? '').trim();
  }

  /// 取某频道节目单（今日）
  Future<List<EpgProgram>> programsFor(String channelName) async {
    final url = await loadEpgUrl();
    if (url.isEmpty) return const [];
    if (_cache.isNotEmpty &&
        DateTime.now().difference(_cacheAt).inHours < 6) {
      return _lookup(channelName);
    }
    isWorking.value = true;
    try {
      final res = await _dioC.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = res.data ?? const <int>[];
      String xml;
      if (url.endsWith('.gz') || bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
        xml = utf8.decode(gzip.decode(bytes));
      } else {
        xml = utf8.decode(bytes);
      }
      _parseXmltv(xml);
      _cacheAt = DateTime.now();
      return _lookup(channelName);
    } catch (e) {
      AppLog.instance.log('[EpgService] load fail: $e');
      return const [];
    } finally {
      isWorking.value = false;
    }
  }

  void _parseXmltv(String xml) {
    _cache.clear();
    final now = DateTime.now();
    // programme start="20240101120000 +0800" stop="..." channel="xxx"
    final progRe = RegExp(
        r'<programme\s+([^>]*)>([\s\S]*?)</programme>',
        caseSensitive: false);
    final attrRe = RegExp(r'(\w+)\s*=\s*"([^"]*)"');
    final titleRe = RegExp(r'<title[^>]*>([\s\S]*?)</title>',
        caseSensitive: false);
    for (final m in progRe.allMatches(xml)) {
      final attrs = <String, String>{};
      for (final a in attrRe.allMatches(m.group(1)!)) {
        attrs[a.group(1)!] = a.group(2)!;
      }
      final title = titleRe.firstMatch(m.group(2) ?? '')?.group(1)?.trim() ?? '';
      if (title.isEmpty) continue;
      final start = _parseXmltvTime(attrs['start']);
      final stop = _parseXmltvTime(attrs['stop']);
      if (start == null) continue;
      // 只保留今天附近
      if (start.year != now.year || start.month != now.month || start.day != now.day) {
        if (start.isBefore(now.subtract(const Duration(days: 1)))) continue;
      }
      final ch = (attrs['channel'] ?? '').trim();
      final p = EpgProgram(title: title, start: start, stop: stop);
      for (final key in _nameKeys(ch)) {
        _cache.putIfAbsent(key, () => []).add(p);
      }
    }
    for (final list in _cache.values) {
      list.sort((a, b) => (a.start ?? DateTime(0)).compareTo(b.start ?? DateTime(0)));
    }
    AppLog.instance.log('[EpgService] parsed channels=${_cache.length}');
  }

  Iterable<String> _nameKeys(String ch) sync* {
    if (ch.isEmpty) return;
    yield ch;
    yield ch.toLowerCase();
    // 常见：CCTV-1 / cctv1 / CCTV1
    final compact = ch.replaceAll(RegExp(r'[\s\-_]+'), '').toLowerCase();
    yield compact;
  }

  List<EpgProgram> _lookup(String channelName) {
    final name = channelName.trim();
    if (name.isEmpty) return const [];
    for (final key in [
      name,
      name.toLowerCase(),
      name.replaceAll(RegExp(r'[\s\-_]+'), '').toLowerCase(),
    ]) {
      final hit = _cache[key];
      if (hit != null && hit.isNotEmpty) return hit;
    }
    // 模糊：包含关系
    for (final e in _cache.entries) {
      if (e.key.contains(name) || name.contains(e.key)) {
        return e.value;
      }
    }
    return const [];
  }

  DateTime? _parseXmltvTime(String? raw) {
    if (raw == null || raw.length < 12) return null;
    // 20240101120000 +0800
    final y = int.tryParse(raw.substring(0, 4));
    final mo = int.tryParse(raw.substring(4, 6));
    final d = int.tryParse(raw.substring(6, 8));
    final h = int.tryParse(raw.substring(8, 10));
    final mi = int.tryParse(raw.substring(10, 12));
    if (y == null || mo == null || d == null || h == null || mi == null) return null;
    return DateTime(y, mo, d, h, mi);
  }

  String formatTime(DateTime? t) {
    if (t == null) return '';
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
