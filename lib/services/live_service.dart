import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get.dart';

import '../models/live_models.dart';

/// 直播源服务：解析 tvbox `lives` 配置 / m3u 播放列表 / 内嵌 channels
class LiveService extends GetxService {
  static LiveService get instance => Get.find<LiveService>();

  final channels = <LiveChannel>[].obs;
  final groups = <LiveGroup>[].obs;
  final isLoading = false.obs;
  final error = RxnString();
  final selectedGroup = 0.obs;

  /// 从 tvbox JSON 的 lives 数组加载
  Future<void> loadFromLivesJson(List<dynamic> lives) async {
    isLoading.value = true;
    error.value = null;
    try {
      final all = <LiveChannel>[];
      for (final item in lives) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        // 内嵌 channels
        final embedded = (map['channels'] as List?) ?? const [];
        for (final ch in embedded) {
          if (ch is! Map) continue;
          final name = (ch['name'] ?? '').toString();
          final urls = (ch['urls'] as List?)?.map((e) => e.toString()).toList() ??
              const <String>[];
          if (name.isEmpty || urls.isEmpty) continue;
          all.add(LiveChannel(
            name: name,
            urls: urls,
            group: (ch['group'] ?? map['name'] ?? '未分组').toString(),
            logo: ch['logo']?.toString(),
          ));
        }
        // 远程 m3u / txt
        final url = map['url']?.toString() ?? '';
        if (url.isNotEmpty) {
          try {
            final body = await _fetch(url, ua: map['ua']?.toString());
            all.addAll(parseM3uOrTxt(body,
                defaultGroup: map['name']?.toString() ?? '直播'));
          } catch (e) {
            print('[LiveService] 拉取直播列表失败 $url: $e');
          }
        }
      }
      channels.value = all;
      _rebuildGroups();
    } finally {
      isLoading.value = false;
    }
  }

  /// 直接从 m3u/txt URL 加载
  Future<void> loadFromUrl(String url) async {
    isLoading.value = true;
    error.value = null;
    try {
      final body = await _fetch(url);
      final list = parseM3uOrTxt(body);
      channels.value = list;
      _rebuildGroups();
      if (list.isEmpty) {
        error.value = '未解析到频道';
      }
    } catch (e) {
      error.value = '加载失败：$e';
    } finally {
      isLoading.value = false;
    }
  }

  Future<String> _fetch(String url, {String? ua}) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        if (ua != null && ua.isNotEmpty) HttpHeaders.userAgentHeader: ua,
        if (ua == null || ua.isEmpty)
          HttpHeaders.userAgentHeader: 'Mozilla/5.0 (NewTv Live)',
      },
    ));
    final res = await dio.get<String>(url);
    return res.data ?? '';
  }

  /// 解析 m3u(#EXTINF) 或简单 txt（名称,url）
  List<LiveChannel> parseM3uOrTxt(String body, {String defaultGroup = '未分组'}) {
    final result = <LiveChannel>[];
    final lines = const LineSplitter().convert(body);
    String? pendingName;
    String? pendingLogo;
    String pendingGroup = defaultGroup;

    for (var raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF')) {
        pendingName = _extinfName(line);
        pendingLogo = _extinfAttr(line, 'tvg-logo');
        pendingGroup =
            _extinfAttr(line, 'group-title') ?? defaultGroup;
        continue;
      }
      if (line.startsWith('#')) continue;
      if (pendingName != null && _looksLikeStream(line)) {
        result.add(LiveChannel(
          name: pendingName,
          urls: [line],
          group: pendingGroup,
          logo: pendingLogo,
        ));
        pendingName = null;
        pendingLogo = null;
        pendingGroup = defaultGroup;
        continue;
      }
      // txt: 名称,url
      final idx = line.indexOf(',');
      if (idx > 0 && _looksLikeStream(line.substring(idx + 1).trim())) {
        result.add(LiveChannel(
          name: line.substring(0, idx).trim(),
          urls: [line.substring(idx + 1).trim()],
          group: defaultGroup,
        ));
      }
    }
    return result;
  }

  bool _looksLikeStream(String u) {
    final s = u.toLowerCase();
    return s.startsWith('http') ||
        s.startsWith('rtmp') ||
        s.startsWith('rtsp') ||
        s.startsWith('p3p') ||
        s.contains('.m3u8') ||
        s.contains('.flv') ||
        s.contains('.ts');
  }

  String? _extinfName(String line) {
    final comma = line.indexOf(',');
    if (comma >= 0 && comma < line.length - 1) {
      final n = line.substring(comma + 1).trim();
      if (n.isNotEmpty) return n;
    }
    return _extinfAttr(line, 'tvg-name');
  }

  String? _extinfAttr(String line, String key) {
    final re = RegExp('$key="([^"]*)"');
    return re.firstMatch(line)?.group(1);
  }

  void _rebuildGroups() {
    final map = <String, List<LiveChannel>>{};
    for (final c in channels) {
      map.putIfAbsent(c.group, () => []).add(c);
    }
    groups.value = map.entries
        .map((e) => LiveGroup(name: e.key, channels: e.value))
        .toList();
    selectedGroup.value = 0;
  }

  List<LiveChannel> get currentChannels {
    if (groups.isEmpty) return const [];
    final i = selectedGroup.value.clamp(0, groups.length - 1);
    return groups[i].channels;
  }
}
