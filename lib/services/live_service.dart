import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'app_log.dart';
import 'prefs_mirror.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/live_models.dart';
import 'xtream_service.dart';

/// 直播源服务：解析 tvbox `lives` 配置 / m3u 播放列表 / 内嵌 channels / Xtream 账号
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
      var saved = prefs.getString('live_lives');
      // prefs 里没有（或 plist 整域丢失）→ 尝试文件备份兜底。
      // 与 api_url.bak / subscriptions.bak 同款：进程被硬打断时 plist 可能没落盘，
      // 文件写是独立的，用它把直播源救回来，避免「直播源随重启/切源变化」。
      if (saved == null || saved.isEmpty) {
        final backup = await _readLivesBackup();
        if (backup != null && backup.isNotEmpty) {
          saved = backup;
          await prefs.setString('live_lives', backup);
          AppLog.instance.log('[Live] 直播源已从文件备份恢复');
        }
      }
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

  static const String _livesBackupName = 'live_lives.bak';

  static Future<File?> _livesBackupFile() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      return File('${docs.path}/$_livesBackupName');
    } catch (e) {
      return null;
    }
  }

  static Future<String?> _readLivesBackup() async {
    try {
      final f = await _livesBackupFile();
      if (f == null || !await f.exists()) return null;
      return await f.readAsString();
    } catch (e) {
      return null;
    }
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

  /// 载入序号：切换直播源/地址时自增，**只有最后一次载入允许写 channels/groups**。
  ///
  /// 为什么需要：多源快速连点会并发发起多次拉取，没有守卫时
  /// "后点的先回来、先点的后回来" → 列表被先点那个源覆盖，
  /// 而标题/选中态还停在最后一个源上（看起来就是"切源串台/不生效"）。
  int _loadSeq = 0;

  /// [seq] 是否已被更新的载入请求取代
  bool _stale(int seq) => seq != _loadSeq;

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
    final seq = ++_loadSeq;
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
        await _loadSourceLocked(0, seq: seq);
        if (_stale(seq)) return;
        selectedSourceIndex.value = 0;
      } else {
        channels.value = [];
        groups.value = [];
        selectedSourceIndex.value = 0;
      }
    } finally {
      // 已被更新的载入取代时不要收掉 loading（那个请求还在跑）
      if (!_stale(seq)) isLoading.value = false;
    }
  }

  /// 切换直播源（索引对应 sources）
  Future<void> loadSource(int index) async {
    if (_rawLives == null || index < 0 || index >= _rawLives!.length) return;
    final seq = ++_loadSeq;
    final prevIndex = selectedSourceIndex.value;
    isLoading.value = true;
    error.value = null;
    // 选中态**立刻**切到目标源：标题/高亮马上给出反馈，
    // 不用等整份列表拉完（用户会以为"点了没反应"）。
    selectedSourceIndex.value = index;
    try {
      await _loadSourceLocked(index, seq: seq);
      // 被更新的切换取代：不写"最近更新/选中态"，避免串台
      if (_stale(seq)) return;
      // 加载成功 → 该源视为「刚刚更新」并持久化
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      _rawLives![index]['updatedAt'] = nowMs;
      await _persistLives();
      if (_stale(seq)) return;
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
    } catch (e) {
      // 失败时把选中态退回原来源，避免"标题是 B、列表还是 A"
      if (!_stale(seq)) selectedSourceIndex.value = prevIndex;
      rethrow;
    } finally {
      if (!_stale(seq)) isLoading.value = false;
    }
  }

  /// 按源索引解析并替换当前频道/分组
  Future<void> _loadSourceLocked(int index, {int? seq}) async {
    final map = _rawLives![index];
    // Xtream 账号源：走 player_api，不当 m3u 拉取
    if (map['type'] == 'xtream') {
      await _loadXtreamSourceLocked(index, map, seq: seq);
      return;
    }
    // 麦优订阅源：json.txt 分类接口 + 分类文件频道列表
    if (map['type'] == 'maiyou') {
      await _loadMaiyouSourceLocked(index, map, seq: seq);
      return;
    }
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
    if (seq != null && _stale(seq)) return;
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
    if (seq != null && _stale(seq)) return;
    channels.value = all;
    _rebuildGroups();
  }

  /// 加载 Xtream 账号源：拉分类+频道，顺带记录到期时间。
  Future<void> _loadXtreamSourceLocked(
    int index,
    Map<String, dynamic> map, {
    int? seq,
  }) async {
    final account = XtreamService.instance.accountFromStored(map);
    if (account == null) {
      error.value = 'Xtream 账号信息不完整（缺少地址或用户名/密码）。';
      return;
    }
    // 缓存优先：先出列表再走网络
    final cacheId = 'xtream:${account.user}@${account.base}';
    final cached = await _readChannelCache(cacheId);
    if (seq != null && _stale(seq)) return;
    if (cached != null && cached.isNotEmpty) {
      channels.value = cached;
      _rebuildGroups();
    }

    // 账号信息（到期时间）与频道并行拉取；账号信息失败不致命
    final Future<XtreamAccount?> infoFuture = XtreamService.instance
        .fetchAccount(account)
        .then<XtreamAccount?>((a) => a)
        .catchError((_) => null);
    try {
      final list = await XtreamService.instance.fetchChannels(account);
      if (seq != null && _stale(seq)) return;
      if (list.isNotEmpty) {
        await _saveChannelCache(cacheId, list);
      }
      if (seq != null && _stale(seq)) return;
      channels.value = list;
      _rebuildGroups();
    } catch (e) {
      AppLog.instance.log('[LiveService] 加载 Xtream 源失败 ${account.base}: $e');
      if (cached == null || cached.isEmpty) {
        error.value = e is XtreamException
            ? e.message
            : humanizeLiveError(e);
      }
    }

    // 记录到期时间 / 状态，供设置页副标题展示
    final info = await infoFuture;
    if (info != null) {
      map['xtreamStatus'] = info.status;
      if (info.expDate != null) {
        map['exp'] = info.expDate!.millisecondsSinceEpoch;
      }
      await _persistLives();
    }
  }

  /// 该索引的源是否为 Xtream 账号源（设置页展示标记用）。
  bool isXtreamSource(int index) {
    final raw = _rawLives;
    if (raw == null || index < 0 || index >= raw.length) return false;
    return raw[index]['type'] == 'xtream';
  }

  /// 该索引的源是否为麦优订阅源（设置页展示标记用）。
  bool isMaiyouSource(int index) {
    final raw = _rawLives;
    if (raw == null || index < 0 || index >= raw.length) return false;
    return raw[index]['type'] == 'maiyou';
  }

  /// 麦优订阅源：`json.txt` 返回 pingtai 分类，每个分类是一个 json 文件，
  /// 文件内 `zhubo` 数组即频道（title / address / img）。
  /// 分类文件并发拉取（[_maiyouPoolSize] 并发），频道分组=分类名。
  static const int _maiyouPoolSize = 6;

  Future<void> _loadMaiyouSourceLocked(
    int index,
    Map<String, dynamic> map, {
    int? seq,
  }) async {
    final subUrl = map['url']?.toString() ?? '';
    if (subUrl.isEmpty) {
      error.value = '麦优订阅地址为空';
      return;
    }
    final uri = Uri.tryParse(subUrl);
    if (uri == null) {
      error.value = '麦优订阅地址无效';
      return;
    }

    // 缓存优先：先出列表再走网络
    final cacheId = 'maiyou:$subUrl';
    final cached = await _readChannelCache(cacheId);
    if (seq != null && _stale(seq)) return;
    if (cached != null && cached.isNotEmpty) {
      channels.value = cached;
      _rebuildGroups();
    }

    try {
      // 1) 拉分类索引 json.txt → pingtai
      final body = await _fetch(subUrl);
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw Exception('分类索引不是 JSON 对象');
      final pingtai = decoded['pingtai'];
      if (pingtai is! List || pingtai.isEmpty) {
        throw Exception('分类索引里没有 pingtai 分类');
      }
      final cats = <({String title, String file, String? img})>[];
      for (final c in pingtai) {
        if (c is! Map) continue;
        final title = (c['title'] ?? '').toString().trim();
        final file = (c['address'] ?? '').toString().trim();
        if (title.isEmpty || file.isEmpty) continue;
        cats.add((
          title: title,
          file: file,
          img: c['xinimg']?.toString(),
        ));
      }
      if (cats.isEmpty) throw Exception('没有可用的分类');

      // 2) 并发拉取全部分类文件 → 频道列表
      final all = <LiveChannel>[];
      var cursor = 0;
      Future<void> worker() async {
        while (true) {
          final idx = cursor++;
          if (idx >= cats.length) break;
          final c = cats[idx];
          try {
            final catUri = uri.resolve(c.file);
            final catBody = await _fetch(catUri.toString());
            final catDecoded = jsonDecode(catBody);
            final zhubo = catDecoded is Map ? catDecoded['zhubo'] : null;
            if (zhubo is! List) continue;
            for (final z in zhubo) {
              if (z is! Map) continue;
              final name = (z['title'] ?? '').toString().trim();
              final addr = (z['address'] ?? '').toString().trim();
              if (name.isEmpty || addr.isEmpty) continue;
              all.add(LiveChannel(
                name: name,
                urls: [addr],
                group: c.title,
                logo: z['img']?.toString(),
              ));
            }
          } catch (e) {
            AppLog.instance.log('[LiveService] 麦优分类拉取失败 ${c.file}: $e');
          }
        }
      }

      await Future.wait(List.generate(_maiyouPoolSize, (_) => worker()));

      if (all.isNotEmpty) {
        await _saveChannelCache(cacheId, all);
      }
      if (seq != null && _stale(seq)) return;
      channels.value = all;
      _rebuildGroups();
      if (all.isEmpty && (cached == null || cached.isEmpty)) {
        error.value = '麦优订阅未解析到频道';
      }
    } catch (e) {
      AppLog.instance.log('[LiveService] 加载麦优订阅失败 $subUrl: $e');
      if (cached == null || cached.isEmpty) {
        error.value = humanizeLiveError(e);
      }
    }
  }

  /// Xtream 源的到期文案（如「到期 2026-01-01」/「已过期 2026-01-01」）；
  /// 尚未拿到到期时间时返回 null。
  String? xtreamExpiryText(int index) {
    final raw = _rawLives;
    if (raw == null || index < 0 || index >= raw.length) return null;
    final ts = raw[index]['exp'];
    if (ts is! int) return null;
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int v) => v.toString().padLeft(2, '0');
    final date = '${dt.year}-${two(dt.month)}-${two(dt.day)}';
    if (dt.isBefore(DateTime.now())) return '已过期 $date';
    return '到期 $date';
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
    // 体积超限（多半是直播流直链当节目单填了）：直接说明，别当普通网络失败
    if (e is _NotPlaylistException) return '$e';
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
    final seq = ++_loadSeq;
    isLoading.value = true;
    error.value = null;
    try {
      // 缓存优先：立刻恢复上次频道，避免长时间空白
      final cached = await _readChannelCache('url:$url');
      if (_stale(seq)) return;
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
      if (_stale(seq)) return;
      final list = parseM3uOrTxt(body);
      if (list.isNotEmpty) {
        await _saveChannelCache('url:$url', list);
      }
      if (_stale(seq)) return;
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
      if (!_stale(seq)) error.value = '加载失败：$e';
    } finally {
      if (!_stale(seq)) isLoading.value = false;
    }
  }

  /// 删除单个直播源（设置页）：多源从 lives 移除并重建，自定义单源清空全部
  Future<void> removeSource(int index) async {
    if (index < 0 || index >= sources.length) return;
    await _markLivesManaged();
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

  /// 手动调整直播源顺序（设置页拖动排序）。单源模式（_rawLives == null）直接返回。
  ///
  /// [newIndex] 遵循 ReorderableListView.onReorder 的约定：向下拖动时它指向
  /// 「目标位置之后」的插槽，这里先归一化（newIndex > oldIndex 时减一）。
  /// 只重排 [_rawLives]，不重新联网；通过保留原始条目的对象引用，
  /// 让「当前已加载的源」在重排后仍然指向同一个源（loaded 标记跟着源走）。
  Future<void> reorderSource(int oldIndex, int newIndex) async {
    final raw = _rawLives;
    if (raw == null) return;
    if (oldIndex < 0 || oldIndex >= raw.length) return;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    target = target.clamp(0, raw.length - 1);
    if (target == oldIndex) return;
    await _markLivesManaged();
    final loadedRef = _loadedRaw();
    final item = raw.removeAt(oldIndex);
    raw.insert(target, item);
    await _persistLives();
    _rebuildSourcesKeepingLoaded(loadedRef);
  }

  /// 一键自动排序。规则（固定、可解释）：
  ///   1) Xtream 账号源（type == 'xtream'）统一排在最后，普通源在前；
  ///   2) 同组内按名称升序（[String.compareTo]，中文按 Unicode 码点/本地序）；
  ///   3) 名称相同再按 url 升序兜底，保证结果可复现。
  /// 排序后同样保留「当前已加载的源」。单源模式（_rawLives == null）直接返回。
  Future<void> autoSortSources() async {
    final raw = _rawLives;
    if (raw == null) return;
    await _markLivesManaged();
    final loadedRef = _loadedRaw();
    int rank(Map<String, dynamic> m) => m['type'] == 'xtream' ? 1 : 0;
    String nameOf(Map<String, dynamic> m) =>
        (m['name']?.toString() ?? '').trim();
    raw.sort((a, b) {
      final r = rank(a) - rank(b);
      if (r != 0) return r;
      final byName = nameOf(a).compareTo(nameOf(b));
      if (byName != 0) return byName;
      return (a['url']?.toString() ?? '').compareTo(b['url']?.toString() ?? '');
    });
    await _persistLives();
    _rebuildSourcesKeepingLoaded(loadedRef);
  }

  /// 找到当前「已加载」条目对应的原始 Map（按对象引用）。
  Map<String, dynamic>? _loadedRaw() {
    final raw = _rawLives;
    if (raw == null) return null;
    for (var i = 0; i < sources.length && i < raw.length; i++) {
      if (sources[i].loaded) return raw[i];
    }
    return null;
  }

  /// 按 [_rawLives] 顺序重建 [sources]，并让 [loadedRef] 指向的那个源保持 loaded。
  ///
  /// 重排/排序只改变顺序，不联网；这里用 [identical] 按引用定位同一个源，
  /// 因此 loaded 标记（以及 selectedSourceIndex）会跟着源移动，而不是钉在原下标。
  void _rebuildSourcesKeepingLoaded(Map<String, dynamic>? loadedRef) {
    final raw = _rawLives;
    if (raw == null) {
      _notifySources(const []);
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final list = <LiveSource>[];
    var loadedIndex = -1;
    for (var i = 0; i < raw.length; i++) {
      final n = (raw[i]['name']?.toString() ?? '').trim();
      final ts = raw[i]['updatedAt'];
      list.add(LiveSource(
        name: n.isEmpty ? '直播源${i + 1}' : n,
        loaded: false,
        updatedAt: ts is int ? ts : nowMs,
      ));
      if (loadedRef != null && identical(raw[i], loadedRef)) {
        loadedIndex = i;
      }
    }
    if (loadedIndex >= 0) {
      final s = list[loadedIndex];
      list[loadedIndex] = LiveSource(
        name: s.name,
        loaded: true,
        updatedAt: s.updatedAt,
      );
      selectedSourceIndex.value = loadedIndex;
    }
    _notifySources(list);
  }

  /// 添加一个新的直播源（追加到列表末尾）
  /// 单源模式下自动转成多源模式
  ///
  /// [xtream] 或地址形如 Xtream 账号链接时，保存为 `type=xtream` 源：
  /// 存 `{base}/get.php?username=&password=` 链接，并另存 user/pass，
  /// 加载时走 [XtreamService.fetchChannels]（不再当 m3u 拉取）。
  ///
  /// [maiyou] 或地址指向麦优订阅（含 `maiyoux.com` / `/mf/json`）时，
  /// 保存为 `type=maiyou` 源：加载时走麦优分类式接口
  /// （json.txt → pingtai 分类 → 分类文件 → zhubo 频道）。
  Future<void> addSource(
    String url, {
    String? name,
    bool xtream = false,
    bool maiyou = false,
  }) async {
    url = url.trim();
    if (url.isEmpty) return;
    await _markLivesManaged();
    isLoading.value = true;
    error.value = null;
    try {
      final isXtream =
          xtream || XtreamService.instance.looksLikeXtream(url);
      final isMaiyou = maiyou || _looksLikeMaiyouUrl(url);
      final Map<String, dynamic> newItem;
      if (isXtream) {
        final acc = XtreamService.instance.parseAccount(url);
        if (acc == null || acc.user.isEmpty || acc.pass.isEmpty) {
          error.value = '无法从地址解析出 Xtream 账号（需包含 base 与 username/password）。';
          return;
        }
        newItem = <String, dynamic>{
          'name': name?.trim().isEmpty ?? true
              ? '直播源${sources.length + 1}'
              : name!,
          'url': XtreamService.instance
              .buildAccountUrl(acc.base, acc.user, acc.pass),
          'type': 'xtream',
          'user': acc.user,
          'pass': acc.pass,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        };
      } else if (isMaiyou) {
        newItem = <String, dynamic>{
          'name': name?.trim().isEmpty ?? true
              ? '麦优订阅${sources.length + 1}'
              : name!,
          'url': url,
          'type': 'maiyou',
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        };
      } else {
        newItem = <String, dynamic>{
          'name': name?.trim().isEmpty ?? true
              ? '直播源${sources.length + 1}'
              : name!,
          'url': url,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        };
      }
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
    await _markLivesManaged();
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

  /// 持久化多源配置到本地（prefs + 文件备份）
  Future<void> _persistLives() async {
    if (_rawLives == null) return;
    try {
      final json = jsonEncode(_rawLives);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('live_lives', json);
      try {
        final f = await _livesBackupFile();
        await f?.writeAsString(json, flush: true);
      } catch (e) {
        AppLog.instance.log('[Live] 直播源备份写入失败: $e');
      }
    } catch (e) { /* ignore */ }
  }

  /// 播放列表正文的体积上限（超过即判定"这不是节目单"）。
  ///
  /// ⚠️ 用户把 **FLV 直播流直链**当"直播源"填进来时（添加框 hint 写的是
  /// m3u/txt，但用户会填 `http://…/xxx.flv`），这个 GET 拿到的是**永不结束**
  /// 的流：`receiveTimeout` 只管"两次数据之间的间隔"，而直播流一直在发数据
  /// ⇒ 永不触发 ⇒ Dio 把整条无限流读进内存，`isLoading` 也永远为 true
  /// （设置页的转圈动画一直转）⇒ 内存持续上涨、主线程被动画 + 收包拖满。
  /// 用户 2026-10-11 的 `Runner.wakeups_resource-17:57:06.ips` 正是这一刻：
  /// 200s 内内存 233MB→367MB、平均 224 次/秒唤醒（超 150 上限）、主线程持续渲染。
  /// ⇒ 读到 [_maxListBytes] 立即取消请求，并判定"这不是节目单"。
  static const int _maxListBytes = 4 * 1024 * 1024;

  /// 拉取播放列表正文（受 [_maxListBytes] 与 20s 总时长双重约束，
  /// 保证无限直播流也不可能把 App 拖死）。
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
    final cancelToken = CancelToken();
    var tooLarge = false;
    // receiveTimeout 挡不住无限流（数据一直在来），再加一道总时长硬闸
    final hardTimeout = Timer(const Duration(seconds: 20), () {
      if (!cancelToken.isCancelled) cancelToken.cancel('hard-timeout');
    });
    try {
      final res = await dio.get<String>(
        url,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (received > _maxListBytes && !cancelToken.isCancelled) {
            tooLarge = true;
            cancelToken.cancel('oversize');
          }
        },
      );
      return res.data ?? '';
    } on DioException {
      if (tooLarge) throw const _NotPlaylistException(_maxListBytes);
      rethrow;
    } finally {
      hardTimeout.cancel();
      dio.close(force: true); // 局部新建的 Dio 必须显式释放，否则遗留 HttpClient 连接池
    }
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

  /// 麦优订阅地址识别：域名含 maiyoux.com 或路径含 /mf/json
  /// （如 http://api.maiyoux.com:81/mf/json.txt）
  bool _looksLikeMaiyouUrl(String url) {
    final s = url.toLowerCase();
    return s.contains('maiyoux.com') || s.contains('/mf/json');
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

  /// 临时展示一组频道（不持久化、不改直播源列表）。
  ///
  /// 供独立直播应用（如麦优订阅页）点频道后把列表交给直播页播放：
  /// 只覆盖当前 channels/groups，直播源列表（sources/_rawLives）保持不变。
  void showEphemeralChannels(List<LiveGroup> groupsIn) {
    final flat = <LiveChannel>[];
    for (final g in groupsIn) {
      flat.addAll(g.channels);
    }
    channels.value = flat;
    _rebuildGroups();
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
      // 🔴 2026-10-14 修（洞 J）：单源模式这两个键以前**只写 prefs、没备份也没刷镜像**
      //   —— 多源（live_lives）有 .bak，单源没有，而 prefs 整域丢失正是常见情形。
      //   这里补一次"改完即落盘 + 刷新文件镜像"，与其它设置写入点保持一致。
      PrefsMirror.snapshotSoon();
    } catch (e) { /* ignore */ }
  }

  Future<void> _persistName(String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('live_name', name);
      _persistedName = name;
      PrefsMirror.snapshotSoon();
    } catch (e) { /* ignore */ }
  }

  /// 用户是否手动增删改过直播源。
  /// 手动管理过后，接口配置（api_config）下发的 lives 不再覆盖本地列表 ——
  /// 否则「设置页删了源，重启又被接口配置整个灌回来」。
  Future<bool> get livesUserManaged async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('live_lives_managed') == true) return true;
      // 兼容老用户：本地已有 live_lives 多源配置，直接视为已管理
      final saved = prefs.getString('live_lives');
      return saved != null && saved.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  Future<void> _markLivesManaged() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('live_lives_managed', true);
    } catch (e) { /* ignore */ }
  }

  /// 清空全部直播数据（删除直播源）
  Future<void> clearAll() async {
    // 清空后任何在途的载入都不许再写回列表
    _loadSeq++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('live_url');
      await prefs.remove('live_lives');
      await prefs.remove('live_name');
      // 同步清掉文件备份，否则下次启动又被 _restoreLives 兜回来
      final f = await _livesBackupFile();
      if (f != null && await f.exists()) await f.delete();
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

/// [_fetch] 读满 [LiveService._maxListBytes] 仍未结束：该地址不像播放列表
/// （多半是直播流直链或媒体文件直链）。
///
/// 用自定义 `toString` 让 `'$e'` 直接就是人话（不带 "Exception:" 前缀），
/// 这样 [LiveService.humanizeLiveError] 与 `loadFromUrl` 的兜底文案都能直接用。
class _NotPlaylistException implements Exception {
  final int bytes;
  const _NotPlaylistException(this.bytes);
  @override
  String toString() =>
      '该地址不是 m3u/txt 节目单（像是直播流直链，已读取超过 ${bytes ~/ (1024 * 1024)}MB）';
}
