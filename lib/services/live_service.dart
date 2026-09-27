import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/live_models.dart';

/// 直播源服务：解析 tvbox `lives` 配置 / m3u 播放列表 / 内嵌 channels
class LiveService extends GetxService {
  static LiveService get instance => Get.find<LiveService>();

  /// 屏蔽的分组名（持久化：直播页隐藏对应分类）
  final blockedGroups = <String>[].obs;

  @override
  void onInit() {
    super.onInit();
    _restoreBlocked();
    _restoreLives();
  }

  /// 从本地恢复多源配置
  Future<void> _restoreLives() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('live_lives');
      if (saved != null && saved.isNotEmpty) {
        final list = jsonDecode(saved);
        if (list is List && list.isNotEmpty) {
          final lives = list.whereType<Map>().toList();
          if (lives.isNotEmpty) {
            await loadFromLivesJson(lives);
            return;
          }
        }
      }
      // 没有多源配置，尝试恢复单源 URL（自动加载，避免直播页空白）
      final url = prefs.getString('live_url') ?? '';
      if (url.isNotEmpty) {
        _persistedUrl = url;
        await loadFromUrl(url);
      }
    } catch (_) {}
  }

  Future<void> _restoreBlocked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('blocked_groups') ?? const [];
      blockedGroups.value = saved;
    } catch (_) {}
  }

  Future<void> _persistBlocked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('blocked_groups', blockedGroups.toList());
    } catch (_) {}
  }

  void toggleBlockedGroup(String name) {
    if (blockedGroups.contains(name)) {
      blockedGroups.remove(name);
    } else {
      blockedGroups.add(name);
    }
    _persistBlocked();
  }

  final channels = <LiveChannel>[].obs;
  final groups = <LiveGroup>[].obs;
  /// 多直播源列表（参考图：综合直播[刚刚更新]/虎牙[未下载]/斗鱼[未下载]...）
  final sources = <LiveSource>[].obs;
  /// 当前选中的直播源索引
  final selectedSourceIndex = 0.obs;
  /// 公告列表（任意源可携带 announcements / notice 字段）
  final announcements = <String>[].obs;
  final isLoading = false.obs;
  final error = RxnString();
  final selectedGroup = 0.obs;

  /// 原始 lives 配置缓存（loadSource 切源时重解析）
  List<Map<String, dynamic>>? _rawLives;

  /// 最近一次成功加载的 m3u/txt URL（持久化到本地，重启自动恢复）
  String? _persistedUrl;
  String? get currentUrl => _persistedUrl;

  /// 从 tvbox JSON 的 lives 数组加载（多源：默认只加载第一个源，其余标记"未下载"）
  Future<void> loadFromLivesJson(List<dynamic> lives) async {
    isLoading.value = true;
    error.value = null;
    try {
      _rawLives = lives
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      sources.value = [];
      announcements.value = [];
      for (var i = 0; i < _rawLives!.length; i++) {
        final map = _rawLives![i];
        final name = (map['name'] ?? '直播源${i + 1}').toString();
        final notices = map['announcements'] ?? map['notice'];
        if (notices is List) {
          announcements.addAll(notices
              .map((e) => e.toString())
              .where((t) => t.trim().isNotEmpty));
        }
        sources.add(LiveSource(name: name, loaded: i == 0));
      }
      if (_rawLives!.isNotEmpty) {
        await _loadSourceLocked(0);
        selectedSourceIndex.value = 0;
      } else {
        channels.value = [];
        groups.value = [];
        selectedSourceIndex.value = 0;
      }
    } finally {
      isLoading.value = false;
    }
  }

  /// 切换直播源（索引对应 sources）
  Future<void> loadSource(int index) async {
    if (_rawLives == null || index < 0 || index >= _rawLives!.length) return;
    isLoading.value = true;
    error.value = null;
    try {
      await _loadSourceLocked(index);
      final next = <LiveSource>[];
      for (var i = 0; i < sources.length; i++) {
        next.add(LiveSource(name: sources[i].name, loaded: i == index));
      }
      sources.value = next;
      selectedSourceIndex.value = index;
    } finally {
      isLoading.value = false;
    }
  }

  /// 按源索引解析并替换当前频道/分组
  Future<void> _loadSourceLocked(int index) async {
    final map = _rawLives![index];
    final all = <LiveChannel>[];
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
    channels.value = all;
    _rebuildGroups();
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
      _rawLives = null;
      sources.value = [LiveSource(name: '自定义直播源', loaded: true)];
      selectedSourceIndex.value = 0;
      if (list.isEmpty) {
        error.value = '未解析到频道';
      } else {
        await _persistUrl(url);
      }
    } catch (e) {
      error.value = '加载失败：$e';
    } finally {
      isLoading.value = false;
    }
  }

  /// 删除单个直播源（设置页）：多源从 lives 移除并重建，自定义单源清空全部
  Future<void> removeSource(int index) async {
    if (index < 0 || index >= sources.length) return;
    if (_rawLives != null) {
      if (index < _rawLives!.length) _rawLives!.removeAt(index);
      if (_rawLives!.isEmpty) {
        await clearAll();
      } else {
        await _persistLives();
        await loadFromLivesJson(_rawLives!);
      }
    } else {
      await clearAll();
    }
  }

  /// 刷新单个直播源（设置页）
  Future<void> reloadSource(int index) async {
    if (_rawLives != null && index < _rawLives!.length) {
      await loadSource(index);
    } else if (_persistedUrl != null && _persistedUrl!.isNotEmpty) {
      await loadFromUrl(_persistedUrl!);
    }
  }

  /// 添加一个新的直播源（追加到列表末尾）
  /// 单源模式下自动转成多源模式
  Future<void> addSource(String url, {String? name}) async {
    url = url.trim();
    if (url.isEmpty) return;
    isLoading.value = true;
    error.value = null;
    try {
      final newItem = <String, dynamic>{
        'name': name?.trim().isEmpty ?? true ? '直播源${sources.length + 1}' : name!,
        'url': url,
      };
      if (_rawLives == null) {
        // 单源模式 → 先把当前的转成多源第一项，再追加新源
        if (_persistedUrl != null && _persistedUrl!.isNotEmpty) {
          _rawLives = [
            {'name': '自定义直播源', 'url': _persistedUrl},
            newItem,
          ];
        } else {
          _rawLives = [newItem];
        }
        await _persistLives();
        await loadFromLivesJson(_rawLives!);
      } else {
        // 多源模式：直接追加
        _rawLives!.add(newItem);
        sources.add(LiveSource(name: newItem['name'] as String, loaded: false));
        await _persistLives();
        // 加载新增的源
        final newIndex = _rawLives!.length - 1;
        await loadSource(newIndex);
      }
    } catch (e) {
      error.value = '添加失败：$e';
    } finally {
      isLoading.value = false;
    }
  }

  /// 更新指定索引的直播源 URL（设置页编辑用）
  Future<void> updateSourceUrl(int index, String url) async {
    url = url.trim();
    if (url.isEmpty || index < 0 || index >= sources.length) return;
    isLoading.value = true;
    error.value = null;
    try {
      if (_rawLives != null && index < _rawLives!.length) {
        // 多源模式
        _rawLives![index]['url'] = url;
        await _persistLives();
        await loadSource(index);
      } else {
        // 单源模式
        await loadFromUrl(url);
      }
    } catch (e) {
      error.value = '更新失败：$e';
    } finally {
      isLoading.value = false;
    }
  }

  /// 获取指定源的 URL（设置页编辑用）
  String? getSourceUrl(int index) {
    if (_rawLives != null && index < _rawLives!.length) {
      return _rawLives![index]['url']?.toString();
    }
    return _persistedUrl;
  }

  /// 持久化多源配置到本地
  Future<void> _persistLives() async {
    if (_rawLives == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('live_lives', jsonEncode(_rawLives));
    } catch (_) {}
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

  Future<void> _persistUrl(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('live_url', url);
      _persistedUrl = url;
    } catch (_) {}
  }

  /// 清空全部直播数据（删除直播源）
  Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('live_url');
      await prefs.remove('live_lives');
    } catch (_) {}
    _persistedUrl = null;
    channels.value = [];
    groups.value = [];
    sources.value = [];
    selectedSourceIndex.value = 0;
    selectedGroup.value = 0;
    announcements.value = [];
    _rawLives = null;
    error.value = null;
  }

  /// 刷新当前源：优先重拉保存的 m3u URL，否则重载 lives 中已选中的源
  Future<void> reloadCurrent() async {
    final saved = _persistedUrl;
    if (saved != null && saved.isNotEmpty) {
      await loadFromUrl(saved);
      return;
    }
    if (_rawLives != null) {
      for (var i = 0; i < sources.length; i++) {
        if (sources[i].loaded) {
          await loadSource(i);
          return;
        }
      }
    }
  }
}

/// 直播源条目（参考图：名称 + 刚刚更新/未下载 状态）
class LiveSource {
  final String name;
  final bool loaded;
  const LiveSource({required this.name, required this.loaded});
}
