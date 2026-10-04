import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'app_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/live_models.dart';

/// 直播源服务：解析 tvbox `lives` 配置 / m3u 播放列表 / 内嵌 channels
class LiveService extends GetxService {
  static LiveService get instance => Get.find<LiveService>();

  /// 由直播页注册；点播/其它页面打开时调用，避免「点播在播、直播还有声」
  static void Function()? pauseLivePlayer;

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
      _persistedName = prefs.getString('live_name');
      final url = prefs.getString('live_url') ?? '';
      if (url.isNotEmpty) {
        _persistedUrl = url;
        await loadFromUrl(url);
      }
    } catch (e) { /* ignore */ }
  }

  Future<void> _restoreBlocked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('blocked_groups') ?? const [];
      blockedGroups.value = saved;
    } catch (e) { /* ignore */ }
  }

  Future<void> _persistBlocked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('blocked_groups', blockedGroups.toList());
    } catch (e) { /* ignore */ }
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
  /// 供 Obx 依赖的版本号：改名/换源后 +1，保证列表 UI 必刷
  final sourcesTick = 0.obs;

  void _notifySources(List<LiveSource> next) {
    sources.assignAll(next);
    sources.refresh();
    sourcesTick.value = sourcesTick.value + 1;
  }
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

  /// 单源模式的自定义名称（持久化 live_name，默认「自定义直播源」）
  String? _persistedName;
  static const String _defaultSingleName = '自定义直播源';
  String get displayName => _persistedName ?? _defaultSingleName;

  /// 从 tvbox JSON 的 lives 数组加载（多源：默认只加载第一个源）
  Future<void> loadFromLivesJson(List<dynamic> lives) async {
    isLoading.value = true;
    error.value = null;
    try {
      _rawLives = lives
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      _notifySources(const []);
      announcements.value = [];
      final built = <LiveSource>[];
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < _rawLives!.length; i++) {
        final map = _rawLives![i];
        final name = (map['name'] ?? '直播源${i + 1}').toString();
        final notices = map['announcements'] ?? map['notice'];
        if (notices is List) {
          announcements.addAll(notices
              .map((e) => e.toString())
              .where((t) => t.trim().isNotEmpty));
        }
        // 第一个源即将自动加载 → 视为「刚刚更新」并持久化，
        // 避免后续 loadSource 重建列表时时间回退成安装时间
        final ts = map['updatedAt'];
        final oldTs = ts is int ? ts : nowMs;
        if (i == 0) {
          map['updatedAt'] = nowMs;
        }
        built.add(LiveSource(
          name: name,
          loaded: i == 0,
          updatedAt: i == 0 ? nowMs : oldTs,
        ));
      }
      _notifySources(built);
      await _persistLives();
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
      // 加载成功 → 该源视为「刚刚更新」并持久化
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      _rawLives![index]['updatedAt'] = nowMs;
      await _persistLives();
      // 名称以 _rawLives 为准，避免改名后仍显示旧 sources[i].name
      final next = <LiveSource>[];
      for (var i = 0; i < _rawLives!.length; i++) {
        final n = (_rawLives![i]['name']?.toString() ?? '').trim();
        final ts = _rawLives![i]['updatedAt'];
        next.add(LiveSource(
          name: n.isEmpty ? '直播源${i + 1}' : n,
          loaded: i == index,
          updatedAt: i == index ? nowMs : (ts is int ? ts : nowMs),
        ));
      }
      _notifySources(next);
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
    // 先出缓存，列表立刻可见，不阻塞在网络
    final cacheId = 'src_$index:${map['url'] ?? map['name'] ?? index}';
    final cached = await _readChannelCache(cacheId);
    if (cached != null && cached.isNotEmpty) {
      channels.value = [...all, ...cached];
      _rebuildGroups();
    }
    final url = map['url']?.toString() ?? '';
    if (url.isNotEmpty) {
      try {
        final body = await _fetch(url, ua: map['ua']?.toString());
        final parsed = parseM3uOrTxt(body,
            defaultGroup: map['name']?.toString() ?? '直播');
        all.addAll(parsed);
        if (parsed.isNotEmpty) {
          await _saveChannelCache(cacheId, parsed);
        }
      } catch (e) {
        AppLog.instance.log('[LiveService] 拉取直播列表失败 $url: $e');
        // 网络失败时，若上面已有缓存则保持现状（只是提示，不算错误）
        if (cached == null && all.isEmpty) {
          error.value = humanizeLiveError(e);
        }
      }
    }
    channels.value = all;
    _rebuildGroups();
  }

  /// 把网络异常翻译成用户能看懂、且能据此行动的一句话。
  ///
  /// 之前直接把 `$e` 贴到错误横幅上，是一整屏英文术语
  /// （DioException [receive timeout]: The request took longer than 0:00:12...），
  /// 用户既看不懂也不知道该怎么办。原始异常仍然只进 app.log。
  static String humanizeLiveError(Object e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return '直播源响应超时，可能是源服务器较慢。';
        case DioExceptionType.connectionTimeout:
          return '连接直播源超时，请检查网络后重试。';
        case DioExceptionType.connectionError:
          return '无法连接直播源，请检查网络或源地址是否有效。';
        case DioExceptionType.badResponse:
          final code = e.response?.statusCode;
          return '直播源返回错误${code == null ? '' : '（HTTP $code）'}，'
              '可能是源已失效。';
        case DioExceptionType.cancel:
          return '请求已取消。';
        default:
          return '加载直播源失败，请稍后重试。';
      }
    }
    final s = '$e';
    if (s.contains('SocketException') || s.contains('Failed host lookup')) {
      return '无法连接直播源，请检查网络或源地址。';
    }
    return '加载直播源失败，请稍后重试。';
  }

  /// 重试上次失败的加载（直播页错误横幅的「重试」按钮用）
  ///
  /// 优先重载当前选中的源；没有多源时退回持久化的单源 URL。
  Future<void> retryLast() async {
    final idx = selectedSourceIndex.value;
    final raw = _rawLives;
    if (raw != null && idx >= 0 && idx < raw.length) {
      await loadSource(idx);
      return;
    }
    final url = _persistedUrl;
    if (url != null && url.isNotEmpty) {
      await loadFromUrl(url);
    }
  }

  /// 直接从 m3u/txt URL 加载
  Future<void> loadFromUrl(String url) async {
    isLoading.value = true;
    error.value = null;
    try {
      // 缓存优先：立刻恢复上次频道，避免长时间空白
      final cached = await _readChannelCache('url:$url');
      if (cached != null && cached.isNotEmpty) {
        channels.value = cached;
        _rebuildGroups();
        _rawLives = null;
        _notifySources([
          LiveSource(
            name: displayName,
            loaded: true,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          )
        ]);
        selectedSourceIndex.value = 0;
      }
      final body = await _fetch(url);
      final list = parseM3uOrTxt(body);
      if (list.isNotEmpty) {
        await _saveChannelCache('url:$url', list);
      }
      channels.value = list;
      _rebuildGroups();
      _rawLives = null;
      _notifySources([
        LiveSource(
          name: displayName,
          loaded: true,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        )
      ]);
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
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      };
      if (_rawLives == null) {
        // 单源模式 → 先把当前的转成多源第一项，再追加新源
        if (_persistedUrl != null && _persistedUrl!.isNotEmpty) {
          _rawLives = [
            {
              'name': displayName,
              'url': _persistedUrl,
              'updatedAt': DateTime.now().millisecondsSinceEpoch,
            },
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
        _notifySources([
          ...sources,
          LiveSource(
            name: newItem['name'] as String,
            loaded: false,
            updatedAt: newItem['updatedAt'] as int,
          ),
        ]);
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

  /// 更新直播源名称（可选同时改 URL）。设置页「编辑直播源」用。
  Future<void> updateSourceMeta(
    int index, {
    String? name,
    String? url,
  }) async {
    if (index < 0 || index >= sources.length) return;
    final trimmedName = name?.trim();
    final trimmedUrl = url?.trim();
    if ((trimmedName == null || trimmedName.isEmpty) &&
        (trimmedUrl == null || trimmedUrl.isEmpty)) {
      return;
    }
    isLoading.value = true;
    error.value = null;
    try {
      if (_rawLives != null && index < _rawLives!.length) {
        if (trimmedName != null && trimmedName.isNotEmpty) {
          _rawLives![index]['name'] = trimmedName;
        }
        if (trimmedUrl != null && trimmedUrl.isNotEmpty) {
          _rawLives![index]['url'] = trimmedUrl;
        }
        // 编辑也算一次更新
        _rawLives![index]['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
        await _persistLives();
        // 先按 _rawLives 刷名称，再（可选）重载 URL —— 即使重载失败名称也要生效
        final list = <LiveSource>[];
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        for (var i = 0; i < _rawLives!.length; i++) {
          final n = (_rawLives![i]['name']?.toString() ?? '').trim();
          final ts = _rawLives![i]['updatedAt'];
          list.add(LiveSource(
            name: n.isEmpty ? '直播源${i + 1}' : n,
            loaded: sources.length > i ? sources[i].loaded : false,
            updatedAt: ts is int ? ts : nowMs,
          ));
        }
        _notifySources(list);
        if (trimmedUrl != null && trimmedUrl.isNotEmpty) {
          await loadSource(index);
        }
      } else {
        // 单源模式：名称与 URL 都可改，名称持久化到 live_name
        if (trimmedName != null && trimmedName.isNotEmpty) {
          await _persistName(trimmedName);
        }
        // 立刻把名称刷进列表，不依赖 loadFromUrl 是否成功
        _notifySources([
          LiveSource(
            name: displayName,
            loaded: true,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          )
        ]);
        if (trimmedUrl != null && trimmedUrl.isNotEmpty) {
          await loadFromUrl(trimmedUrl);
        }
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
    } catch (e) { /* ignore */ }
  }

  Future<String> _fetch(String url, {String? ua}) async {
    final dio = Dio(BaseOptions(
      // 收紧超时：慢源不要卡住整个直播页 20s
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      headers: {
        if (ua != null && ua.isNotEmpty) HttpHeaders.userAgentHeader: ua,
        if (ua == null || ua.isEmpty)
          HttpHeaders.userAgentHeader: 'Mozilla/5.0 (NewTv Live)',
      },
    ));
    final res = await dio.get<String>(url);
    return res.data ?? '';
  }

  // ============================================================
  // 频道列表本地缓存：先展示缓存，网络返回后再覆盖
  // ============================================================

  static const String _channelCacheKey = 'live_channel_cache_v1';

  String _cacheKeyFor(String id) => '$_channelCacheKey|$id';

  Future<void> _saveChannelCache(String id, List<LiveChannel> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = jsonEncode({
        'ts': DateTime.now().millisecondsSinceEpoch,
        'channels': list
            .map((c) => {
                  'name': c.name,
                  'urls': c.urls,
                  'group': c.group,
                  if (c.logo != null) 'logo': c.logo,
                })
            .toList(),
      });
      await prefs.setString(_cacheKeyFor(id), payload);
    } catch (e) { /* ignore */ }
  }

  Future<List<LiveChannel>?> _readChannelCache(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKeyFor(id));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final list = decoded['channels'];
      if (list is! List) return null;
      final result = <LiveChannel>[];
      for (final item in list) {
        if (item is! Map) continue;
        final name = (item['name'] ?? '').toString();
        final urls = (item['urls'] as List?)?.map((e) => e.toString()).toList() ??
            const <String>[];
        if (name.isEmpty || urls.isEmpty) continue;
        result.add(LiveChannel(
          name: name,
          urls: urls,
          group: (item['group'] ?? '未分组').toString(),
          logo: item['logo']?.toString(),
        ));
      }
      return result.isEmpty ? null : result;
    } catch (_) {
      return null;
    }
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
    final s = u.toLowerCase().trim();
    if (s.isEmpty) return false;
    // 协议：http(s)/rtmp/rtsp/rtp/udp/p3p/mms/mmsh
    if (s.startsWith('http://') ||
        s.startsWith('https://') ||
        s.startsWith('rtmp://') ||
        s.startsWith('rtmps://') ||
        s.startsWith('rtsp://') ||
        s.startsWith('rtsps://') ||
        s.startsWith('rtp://') ||
        s.startsWith('udp://') ||
        s.startsWith('p3p://') ||
        s.startsWith('mms://') ||
        s.startsWith('mmsh://')) {
      return true;
    }
    // 常见流媒体封装/播放列表后缀
    const exts = [
      '.m3u8', '.m3u', '.flv', '.ts', '.mp4', '.mkv', '.mpd',
      '.mp3', '.aac', '.m4a', '.ism', '.isml',
    ];
    return exts.any(s.contains);
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
    } catch (e) { /* ignore */ }
  }

  Future<void> _persistName(String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('live_name', name);
      _persistedName = name;
    } catch (e) { /* ignore */ }
  }

  /// 清空全部直播数据（删除直播源）
  Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('live_url');
      await prefs.remove('live_lives');
      await prefs.remove('live_name');
    } catch (e) { /* ignore */ }
    _persistedUrl = null;
    _persistedName = null;
    channels.value = [];
    groups.value = [];
    _notifySources(const []);
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

/// 直播源条目（名称 + 加载态 + 最近更新时间）
class LiveSource {
  final String name;
  final bool loaded;

  /// 最近一次更新/安装时间（毫秒时间戳），用于状态文案
  final int? updatedAt;

  const LiveSource({
    required this.name,
    required this.loaded,
    this.updatedAt,
  });

  /// 状态文案：30 分钟内 →「刚刚更新」，否则显示日期
  String statusText({DateTime? now}) {
    final t = updatedAt;
    if (t == null) return '刚刚添加';
    final n = now ?? DateTime.now();
    final dt = DateTime.fromMillisecondsSinceEpoch(t);
    final diff = n.difference(dt);
    if (diff < const Duration(minutes: 30)) return '刚刚更新';
    String two(int v) => v.toString().padLeft(2, '0');
    if (dt.year != n.year) {
      return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
    }
    return '${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}
