import 'dart:convert';
import 'dart:io';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'app_log.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_config.dart';
import '../models/source_bean.dart';
import '../common/constants.dart';
import 'network_manager.dart';
import 'live_service.dart';
import 'host_resolver.dart';

/// 配置错误枚举
enum ConfigError {
  parseError,
  networkError;

  String message([String? detail]) {
    switch (this) {
      case ConfigError.parseError:
        return '配置解析错误${detail != null ? ': $detail' : ''}';
      case ConfigError.networkError:
        return '网络错误${detail != null ? ': $detail' : ''}';
    }
  }
}

/// 多仓库可选项
class MultiRepoOption {
  final String name;
  final String url;

  const MultiRepoOption({required this.name, required this.url});

  String get id => url.toLowerCase();
}

/// 核心配置管理器 - 对应 Swift ApiConfig
/// 负责加载和解析远程 JSON 配置，管理视频源列表
class ApiConfig extends GetxController {
  static ApiConfig get instance => Get.find<ApiConfig>();

  static const int _maxConfigResolveDepth = 6;

  /// 安全解析 int - 对应 Swift as? Int ?? defaultValue
  /// 处理 null, int, double, String 类型
  static int _safeParseInt(dynamic value, int defaultValue) {
    if (value == null) return defaultValue;
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? defaultValue;
    return defaultValue;
  }
  static const int _maxRedirectCandidates = 20;
  static const int _rawConfigCacheTTL = 20; // 秒
  static const int _maxRawConfigCacheEntries = 24;

  final sourceBeanList = <SourceBean>[].obs;
  final homeSourceBean = Rx<SourceBean?>(null);
  final parseBeanList = <ParseBean>[].obs;
  final dohList = <(String, String)>[].obs;
  final isLoaded = false.obs;
  final configUrl = ''.obs;

  /// 整包是否为「单个 js/jar spider」配置（点播接口地址本身就是 .js/.jar）。
  ///
  /// true  → 按老流程：启动时把整包当 Node 的 index.js 载入，`/config` 返回的
  ///         线路列表**整表替换** sourceBeanList（这是唯一事实来源）。
  /// false → 聚合 TVBox 配置（sites[] 里混着 type=3 脚本源，如 huahua.json）：
  ///         脚本源各自按需载入引擎，**不能**走 /config 整表替换 ——
  ///         否则聚合线路会被单个脚本的站点列表冲掉，且首个脚本是 .py 时
  ///         Node 载入失败 → /config 为空 → 首页直接报错（用户 2026-10-13）。
  final isSingleScriptSpider = false.obs;

  /// 源配置阶段的错误（非空表示线路清单没拿到）。
  ///
  /// 之前这类失败只写日志、不暴露给 UI：配置"加载成功"但 homeSourceBean 为 null，
  /// 首页永久空白且没有任何提示。首页据此显示可重试的错误态。
  final apiConfigError = Rx<String?>(null);
  final wallpaper = ''.obs;

  final NetworkManager _network = NetworkManager.instance;

  /// 加载令牌，用于取消之前的加载
  int _activeLoadToken = 0;

  /// 原始配置缓存
  final Map<String, _RawConfigCacheEntry> _rawConfigCache = {};

  ApiConfig();

  // ============================================================
  // 公开 API
  // ============================================================

  /// 加载远程配置（点播）
  Future<void> loadConfig(String apiUrl) async {
    await loadConfigs(vodApiUrl: apiUrl);
  }

  /// 加载远程点播配置
  Future<void> loadConfigs({required String vodApiUrl}) async {
    final trimmedVod = vodApiUrl.trim();

    if (trimmedVod.isEmpty) {
      throw ConfigError.parseError.message('点播接口地址不能为空');
    }

    final loadToken = DateTime.now().microsecondsSinceEpoch;
    _activeLoadToken = loadToken;

    configUrl.value = trimmedVod;

    final configResult = await _fetchConfig(trimmedVod);
    if (_activeLoadToken != loadToken) return;
    await _parseConfig(
      configResult.config,
      apiUrl: configResult.loadedFrom,
      includeSources: true,
      loadToken: loadToken,
    );

    if (_activeLoadToken != loadToken) return;
    isLoaded.value = true;
  }

  /// 仅探测"多仓库入口"并返回可选项。
  /// 返回 null 表示不是多仓库入口；返回数组表示是多仓库入口（数组可能为空）。
  Future<List<MultiRepoOption>?> fetchMultiRepoOptions(String apiUrl) async {
    final normalizedUrl = normalizeConfigUrl(apiUrl);

    if (_isSpiderSourceUrl(normalizedUrl)) {
      return null;
    }

    final jsonStr = await _fetchConfigText(normalizedUrl);
    final cleanedJson = stripJsonComments(jsonStr);

    Map<String, dynamic>? decoded;
    try {
      decoded = jsonDecode(cleanedJson) as Map<String, dynamic>?;
    } catch (e) { /* ignore */ }

    if (decoded != null) {
      final config = AppConfigData.fromJson(decoded);
      if (config.hasUsableContent) return null;

      // 尝试多仓库
      try {
        final multiRepo = MultiRepoConfigData.fromJson(decoded);
        final normalizedCandidates = _uniqueUrlsInOrder(
          multiRepo.candidateUrls.map(normalizeConfigUrl).toList(),
        );

        final options = <MultiRepoOption>[];
        for (final candidate in normalizedCandidates) {
          final matchedEntry = multiRepo.urls?.firstWhere(
            (e) => normalizeConfigUrl(e.url ?? '') == candidate,
            orElse: () => MultiRepoEntry(),
          );
          final displayName = matchedEntry?.name?.trim();
          final fallbackName = Uri.tryParse(candidate)?.host ?? candidate;
          final resolvedName =
              (displayName != null && displayName.isNotEmpty) ? displayName : fallbackName;
          options.add(MultiRepoOption(name: resolvedName, url: candidate));
        }

        return options;
      } catch (_) {
        return null;
      }
    }

    return null;
  }

  /// 获取指定 key 的源
  SourceBean? getSource(String key) {
    return sourceBeanList.firstWhereOrNull((s) => s.key == key);
  }

  /// 获取可搜索的源列表
  List<SourceBean> getSearchableSources() {
    final result = sourceBeanList
        .where((s) => s.isSearchable && s.key != 'douban' && s.key != 'baseset')
        .toList();
    AppLog.instance.log('[ApiConfig] getSearchableSources: 总源数=${sourceBeanList.length}, 可搜索源数=${result.length}');
    return result;
  }

  /// 设置主页源
  Future<void> setHomeSource(SourceBean source) async {
    homeSourceBean.value = source;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.homeApi, source.key);
  }

  // ============================================================
  // 接口地址的「文件级」备份（防"重启后又要重新填源"）
  // ============================================================

  /// 为什么要在 prefs 之外再存一份文件：
  /// 首屏是否弹「填接口」**只看 prefs 里 `apiUrl` 是否为空**（content_view
  /// `_loadSavedConfig`）。而进程被硬打断（例如 CPython `Py_Initialize` 失败后
  /// `exit(1)`，见 Runner-2026-10-13-180034.ips）时，整个 prefs plist 可能没落盘/
  /// 被写坏 ⇒ 接口地址一起丢 ⇒ 重启"回到第一页要重新输入源"。
  /// 文件写是独立的一次 write(flush)，不受 plist 影响，用它兜底恢复。
  static const String _apiUrlBackupName = 'api_url.bak';

  static Future<File> _apiUrlBackupFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/$_apiUrlBackupName');
  }

  /// 保存接口地址：prefs + 文件备份（所有写入点都走这里）
  static Future<void> persistApiUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.apiUrl, url);
    try {
      final f = await _apiUrlBackupFile();
      await f.writeAsString(url, flush: true);
    } catch (e) {
      AppLog.instance.log('[ApiConfig] 接口地址备份写入失败: $e');
    }
  }

  /// 启动时兜底：prefs 里为空、但备份文件在 → 用它恢复（返回可用地址）
  static Future<String> restoreApiUrlIfLost(String current) async {
    if (current.trim().isNotEmpty) return current;
    try {
      final f = await _apiUrlBackupFile();
      if (!await f.exists()) return current;
      final v = (await f.readAsString()).trim();
      if (v.isEmpty) return current;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.apiUrl, v);
      AppLog.instance.log('[ApiConfig] 接口地址已从文件备份恢复');
      return v;
    } catch (e) {
      AppLog.instance.log('[ApiConfig] 接口地址备份恢复失败: $e');
      return current;
    }
  }

  /// 清掉备份（「重置配置」「数据清理」时必须同步调用，否则清完又被恢复）
  static Future<void> clearApiUrlBackup() async {
    try {
      final f = await _apiUrlBackupFile();
      if (await f.exists()) await f.delete();
    } catch (e) {
      AppLog.instance.log('[ApiConfig] 清除接口地址备份失败: $e');
    }
  }

  // ============================================================
  // 用户手动导入的视频线路（如 py 源）
  // ============================================================

  /// 用户线路落盘键。
  ///
  /// 为什么单独存：`updateSourceBeansFromSpiderConfig` / `loadFromConfig` 每次都是
  /// **整表替换** `sourceBeanList`（以接口下发的 sites 为准），用户自己导入的线路
  /// 会被一起冲掉 —— 表现就是「重启/切源后 py 线路在源列表里消失了，切不到」
  /// （用户 2026-10-13）。所以用户线路单独落盘，并在每次整表替换后合并回来
  /// （同 key 以接口下发的为准，避免和接口线路打架）。
  static const String _kUserVideoSources = 'user_video_sources';

  /// 导入一条用户视频线路：入列表 + 落盘
  Future<void> addUserVideoSource(SourceBean bean) async {
    sourceBeanList.removeWhere((s) => s.key == bean.key || s.api == bean.api);
    sourceBeanList.add(bean);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kUserVideoSources) ?? <String>[];
      raw.removeWhere((e) {
        try {
          return ((jsonDecode(e) as Map)['key'] ?? '').toString() == bean.key;
        } catch (_) {
          return false;
        }
      });
      raw.add(jsonEncode({
        'key': bean.key,
        'name': bean.name,
        'api': bean.api,
        'type': bean.type,
      }));
      await prefs.setStringList(_kUserVideoSources, raw);
      AppLog.instance.log('[ApiConfig] 已保存用户视频线路 ${bean.key}（共 ${raw.length} 条）');
    } catch (e) {
      AppLog.instance.log('[ApiConfig] 保存用户视频线路失败: $e');
    }
  }

  /// 把落盘的用户线路合并进 [target]（按 key 去重；接口已下发的同 key 不覆盖）
  Future<void> _mergeUserVideoSources(List<SourceBean> target) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kUserVideoSources) ?? const <String>[];
      if (raw.isEmpty) return;
      var added = 0;
      for (final e in raw) {
        final m = jsonDecode(e) as Map;
        final key = (m['key'] ?? '').toString().trim();
        if (key.isEmpty || target.any((s) => s.key == key)) continue;
        target.add(SourceBean(
          key: key,
          name: (m['name'] ?? key).toString(),
          api: (m['api'] ?? '').toString(),
          searchable: 1,
          filterable: 0,
          quickSearch: 0,
          playerType: 0,
          type: (m['type'] as num?)?.toInt() ?? 3,
          ext: null,
          indexs: 0,
        ));
        added++;
      }
      if (added > 0) {
        AppLog.instance.log('[ApiConfig] 已合并用户视频线路 $added 条');
      }
    } catch (e) {
      AppLog.instance.log('[ApiConfig] 合并用户视频线路失败: $e');
    }
  }

  /// 从 Spider /config 更新源列表
  Future<void> updateSourceBeansFromSpiderConfig(
    Map<String, dynamic> config,
    String spiderUrl,
  ) async {
    final video = config['video'] as Map<String, dynamic>?;
    final sites = video?['sites'] as List<dynamic>?;
    if (video == null || sites == null) {
      AppLog.instance.log('[ApiConfig] Spider /config 响应中没有 video.sites');
      // 原来的静默 return 会让 homeSourceBean 恒为 null → 首页永久空白且无提示。
      apiConfigError.value = '源未返回线路清单（video.sites 缺失），请检查源地址或换一个源';
      return;
    }
    apiConfigError.value = null;

    final newSources = <SourceBean>[];
    for (final site in sites) {
      final s = site as Map<String, dynamic>;
      var key = (s['key'] as String? ?? '').replaceAll('nodejs_', '');
      final name = s['name'] as String? ?? key;
      final api = s['api'] as String? ?? '';
      // 对应 Swift: as? Int ?? 1 - 使用安全转换避免 double/String 类型崩溃
      final type = _safeParseInt(s['type'], 3);
      final searchable = _safeParseInt(s['searchable'], 1);
      final filterable = _safeParseInt(s['filterable'], 1);
      final quickSearch = _safeParseInt(s['quickSearch'], 0);
      final playerType = _safeParseInt(s['playerType'], 0);
      final indexs = _safeParseInt(s['indexs'], 0);

      if (key.isEmpty) continue;

      newSources.add(SourceBean(
        key: key,
        name: name,
        api: api,
        searchable: searchable,
        filterable: filterable,
        quickSearch: quickSearch,
        playerType: playerType,
        type: type,
        ext: null,
        indexs: indexs,
      ));
    }

    if (newSources.isEmpty) {
      AppLog.instance.log('[ApiConfig] Spider /config 返回的 sites 为空');
      apiConfigError.value = '源的线路清单为空，请换一个源';
      return;
    }
    apiConfigError.value = null;

    // 用户手动导入的线路（py 源等）并回来：接口下发的 sites 不包含它们，
    // 不合并就会出现「导入的 py 线路切源/重启后消失」
    await _mergeUserVideoSources(newSources);
    sourceBeanList.value = newSources;

    // 关键修复：当前 homeSourceBean 可能是之前 _createSpiderSourceConfig
    // 临时创建的**占位 SourceBean**（基于 .js URL 派生），它的 key 不在
    // newSources 中。必须把 homeSourceBean 重置到新列表的真实第一项，
    // 否则用户在 PopupMenu 中看到的就是"基于源地址的占位线路"。
    final currentKey = homeSourceBean.value?.key;
    final isCurrentInNewList =
        currentKey != null && newSources.any((s) => s.key == currentKey);

    // 优先恢复保存的主页源
    await _restoreHomeSource(newSources);

    if (!isCurrentInNewList) {
      // 当前 homeSourceBean 是过时占位（key 不在新列表中），重置为新列表第一项
      homeSourceBean.value = newSources
              .where((s) => s.isSupportedInSwift)
              .firstOrNull ??
          newSources.firstOrNull;
    } else if (homeSourceBean.value == null) {
      // _restoreHomeSource 也没找到（保存的 key 在新列表中不存在），
      // 兜底选第一个支持的
      homeSourceBean.value = newSources
              .where((s) => s.isSupportedInSwift)
              .firstOrNull ??
          newSources.firstOrNull;
    }

    AppLog.instance.log('[ApiConfig] 从 Spider /config 更新了 ${newSources.length} 个线路，默认 homeSourceBean=${homeSourceBean.value?.key}');
  }

  // ============================================================
  // 配置获取（递归多仓库解析）
  // ============================================================

  Future<({AppConfigData config, String loadedFrom})> _fetchConfig(
    String apiUrl, {
    Set<String>? visitedUrls,
    int depth = 0,
  }) async {
    visitedUrls ??= {};

    if (depth > _maxConfigResolveDepth) {
      throw ConfigError.parseError.message('配置跳转层级过深（超过 $_maxConfigResolveDepth 层）');
    }

    final normalizedUrl = normalizeConfigUrl(apiUrl);
    if (normalizedUrl.isEmpty) {
      throw ConfigError.parseError.message('配置地址为空');
    }

    if (_isSpiderSourceUrl(normalizedUrl)) {
      final config = _createSpiderSourceConfig(normalizedUrl);
      return (config: config, loadedFrom: normalizedUrl);
    }

    final visitKey = normalizedUrl.toLowerCase();
    if (visitedUrls.contains(visitKey)) {
      throw ConfigError.parseError.message('检测到循环引用的配置地址: $normalizedUrl');
    }

    final nextVisited = Set<String>.from(visitedUrls);
    nextVisited.add(visitKey);

    final jsonStr = await _fetchConfigText(normalizedUrl);
    final cleanedJson = stripJsonComments(jsonStr);

    Map<String, dynamic>? decoded;
    try {
      decoded = jsonDecode(cleanedJson) as Map<String, dynamic>?;
    } catch (e) { /* ignore */ }

    // 尝试作为正常配置解析
    if (decoded != null) {
      final config = AppConfigData.fromJson(decoded);
      if (config.hasUsableContent) {
        return (config: config, loadedFrom: normalizedUrl);
      }

      // 尝试多仓库
      try {
        final multiRepo = MultiRepoConfigData.fromJson(decoded);
        final candidateUrls = _uniqueUrlsInOrder(
          multiRepo.candidateUrls.map(normalizeConfigUrl).toList(),
        );

        Object? lastError;
        for (final candidateUrl in candidateUrls) {
          try {
            return await _fetchConfig(
              candidateUrl,
              visitedUrls: nextVisited,
              depth: depth + 1,
            );
          } catch (e) {
            lastError = e;
          }
        }

        if (lastError != null) {
          throw ConfigError.parseError.message(
            '多仓库配置中没有可用地址，最后错误: $lastError',
          );
        }
        throw ConfigError.parseError.message('多仓库配置中没有可用地址');
      } catch (e) {
        if (e is String && e.contains('配置解析错误')) rethrow;
        // 不是多仓库格式，继续尝试其他方式
      }

      // 尝试从页面中提取配置跳转候选
      final redirectCandidates = _extractConfigRedirectCandidates(cleanedJson)
          .where((c) => c.toLowerCase() != visitKey && !nextVisited.contains(c.toLowerCase()))
          .toList();

      if (redirectCandidates.isNotEmpty) {
        Object? lastError;
        for (final candidate in redirectCandidates) {
          try {
            return await _fetchConfig(
              candidate,
              visitedUrls: nextVisited,
              depth: depth + 1,
            );
          } catch (e) {
            lastError = e;
          }
        }

        if (lastError != null) {
          throw ConfigError.parseError.message(
            '页面跳转配置解析失败，最后错误: $lastError',
          );
        }
      }

      // 解码成功但缺少可用内容
      throw ConfigError.parseError.message('配置缺少可用站点（sites / parses）');
    }

    throw ConfigError.parseError.message('配置格式不受支持');
  }

  /// 读取配置文本并做短时缓存（LRU：访问会刷新 lastAccess）
  Future<String> _fetchConfigText(String normalizedUrl) async {
    final key = normalizedUrl.toLowerCase();
    final now = DateTime.now();

    if (_rawConfigCache.containsKey(key)) {
      final entry = _rawConfigCache[key]!;
      if (now.difference(entry.fetchedAt).inSeconds <= _rawConfigCacheTTL) {
        entry.touch(now);
        return entry.content;
      }
      _rawConfigCache.remove(key);
    }

    final content = await _network.getString(normalizedUrl);
    _rawConfigCache[key] = _RawConfigCacheEntry(content: content, fetchedAt: now);
    _trimRawConfigCacheIfNeeded();
    return content;
  }

  void _trimRawConfigCacheIfNeeded() {
    if (_rawConfigCache.length <= _maxRawConfigCacheEntries) return;
    final overflow = _rawConfigCache.length - _maxRawConfigCacheEntries;
    // LRU：优先淘汰最久未访问
    final staleKeys = _rawConfigCache.entries.toList()
      ..sort((a, b) => a.value.lastAccess.compareTo(b.value.lastAccess));
    for (var i = 0; i < overflow && i < staleKeys.length; i++) {
      _rawConfigCache.remove(staleKeys[i].key);
    }
  }

  // ============================================================
  // 配置解析
  // ============================================================

  Future<void> _parseConfig(
    AppConfigData config, {
    required String apiUrl,
    required bool includeSources,
    required int loadToken,
  }) async {
    if (_activeLoadToken != loadToken) return;

    if (includeSources) {
      // 整包是不是「单个 js/jar spider」配置（决定后面对 homeSourceBean 的处置）
      isSingleScriptSpider.value = _isSpiderSourceUrl(apiUrl);

      // 解析站点列表
      final sources = <SourceBean>[];
      if (config.sites != null) {
        for (final site in config.sites!) {
          sources.add(SourceBean(
            key: site.key ?? '',
            name: site.name ?? '未命名',
            api: site.api ?? '',
            searchable: site.searchable?.value ?? 1,
            filterable: site.filterable?.value ?? 1,
            quickSearch: site.quickSearch?.value ?? 0,
            playerType: site.playerType?.value ?? 0,
            type: site.type?.value ?? 1,
            ext: site.ext?.stringValue,
            indexs: site.indexs?.value ?? 0,
          ));
        }
      }
      // 同上：把用户导入的线路（py 源等）并回列表
      await _mergeUserVideoSources(sources);
      sourceBeanList.value = sources;

      // 直播 lives：交给 LiveService 解析（内嵌 channels 或 m3u URL）
      try {
        final lives = config.lives;
        if (lives != null && lives.isNotEmpty) {
          // 用户手动增删改过直播源后以本地为准，接口下发的 lives 不再覆盖，
          // 否则「设置页删了源，重启又被接口配置整个灌回来」。
          if (await LiveService.instance.livesUserManaged) {
            AppLog.instance.log('[ApiConfig] 用户已手动管理直播源，跳过接口 lives 覆盖');
          } else {
            final raw = lives
                .map((e) => {
                      'name': e.name,
                      'url': e.url,
                      'ua': e.ua,
                      'type': e.type?.value,
                      'channels': e.channels
                          ?.map((ch) => {
                                'name': ch.name,
                                'urls': ch.urls,
                                'group': ch.group,
                                'logo': ch.logo,
                              })
                          .toList(),
                    })
                .toList();
            await LiveService.instance.loadFromLivesJson(raw);
          }
        }
      } catch (e) {
        AppLog.instance.log('[ApiConfig] lives 解析失败: $e');
      }

      // 关键修复：只有「整包就是一个 js/jar spider」的配置，sources 里那个
      // SourceBean 才是 _createSpiderSourceConfig 基于 .js URL 派生的**占位**
      // SourceBean（name='Spider源(host)'），真正的站点列表要等 NodeJS 启动 +
      // getCatConfig 后才会出现 —— 这种才**不**设 homeSourceBean。
      //
      // 聚合 TVBox 配置（sites[] 里混着 type=3 脚本源）不算：它的 sites 就是
      // 真实线路，脚本源按需载入引擎，不该让 /config 整表替换冲掉聚合线路。
      if (isSingleScriptSpider.value) {
        AppLog.instance.log('[ApiConfig] 当前 config 是单个 Spider 源，homeSourceBean 等待 getCatConfig 完成后设置');
      } else {
        // 普通源：按优先级选第一个
        await _restoreHomeSource(sources);
        if (homeSourceBean.value == null) {
          homeSourceBean.value = sources
                  .where((s) => !s.isSpiderSource && s.isSupportedInSwift)
                  .firstOrNull ??
              sources.where((s) => !s.isSpiderSource).firstOrNull ??
              sources.where((s) => s.isSupportedInSwift).firstOrNull ??
              sources.firstOrNull;
        }
      }

      // 解析解析器列表
      if (config.parses != null) {
        parseBeanList.value = config.parses!
            .map((p) => ParseBean(name: p.name ?? '', url: p.url ?? '', type: p.type?.value ?? 0))
            .toList();
      } else {
        parseBeanList.value = [];
      }

      // 解析 DoH 列表
      if (config.doh != null) {
        dohList.value = config.doh!
            .where((d) => d.name != null && d.url != null)
            .map((d) => (d.name!, d.url!))
            .toList();
      } else {
        dohList.value = [];
      }

      // 把 hosts / doh 真正下发给网络层的 DNS 解析器
      HostResolver.instance.load(hosts: config.hosts, doh: config.doh);

      // 壁纸
      wallpaper.value = config.wallpaper ?? '';
    }
  }

  Future<void> _restoreHomeSource(List<SourceBean> sources) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(AppConstants.homeApi);
      if (saved != null) {
        final found = sources.where((s) => s.key == saved).firstOrNull;
        if (found != null) {
          homeSourceBean.value = found;
          return;
        }
      }
    } catch (e) { /* ignore */ }
  }

  // ============================================================
  // URL 规范化（静态方法，与 Swift 一致）
  // ============================================================

  /// 统一规范配置 URL
  static String normalizeConfigUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return trimmed;

    final fixedScheme = _fixMalformedSchemeIfNeeded(trimmed);

    final normalizedProxy = _normalizeGhProxyWrappedUrl(fixedScheme);
    if (normalizedProxy != null) return normalizedProxy;

    final githubRaw = _convertGitHubBlobUrlToRaw(fixedScheme);
    if (githubRaw != null) return githubRaw;

    return fixedScheme;
  }

  static String _fixMalformedSchemeIfNeeded(String urlString) {
    var fixed = urlString.replaceFirst(RegExp(r'^https:/(?!/)'), 'https://');
    fixed = fixed.replaceFirst(RegExp(r'^http:/(?!/)'), 'http://');
    return fixed;
  }

  static String? _normalizeGhProxyWrappedUrl(String urlString) {
    final uri = Uri.tryParse(urlString);
    if (uri == null) return null;

    final host = uri.host.toLowerCase();
    if (!host.contains('gh-proxy')) return null;

    var path = uri.path;
    while (path.startsWith('/') && path.length > 1) {
      path = path.substring(1);
    }
    if (path.isEmpty) return null;

    final decodedPath = Uri.decodeFull(path);
    final fixedEmbedded = _fixMalformedSchemeIfNeeded(decodedPath);
    if (!fixedEmbedded.startsWith('http://') &&
        !fixedEmbedded.startsWith('https://')) {
      return null;
    }

    final normalizedEmbedded =
        _convertGitHubBlobUrlToRaw(fixedEmbedded) ?? fixedEmbedded;
    final scheme = uri.scheme.isEmpty ? 'https' : uri.scheme;
    final portSuffix = uri.hasPort ? ':${uri.port}' : '';

    var rebuilt = '$scheme://$host$portSuffix/$normalizedEmbedded';
    if (uri.hasQuery) rebuilt += '?${uri.query}';
    if (uri.hasFragment) rebuilt += '#${uri.fragment}';
    return rebuilt;
  }

  static String? _convertGitHubBlobUrlToRaw(String urlString) {
    final uri = Uri.tryParse(urlString);
    if (uri == null) return null;

    final host = uri.host.toLowerCase();
    if (host != 'github.com' && host != 'www.github.com') return null;

    final parts = uri.pathSegments;
    if (parts.length < 5 || parts[2] != 'blob') return null;

    final owner = parts[0];
    final repo = parts[1];
    final branch = parts[3];
    final filePath = parts.sublist(4).join('/');
    if (filePath.isEmpty) return null;

    var rawUrl = 'https://raw.githubusercontent.com/$owner/$repo/$branch/$filePath';
    if (uri.hasQuery) rawUrl += '?${uri.query}';
    if (uri.hasFragment) rawUrl += '#${uri.fragment}';
    return rawUrl;
  }

  static bool _isSpiderSourceUrl(String url) {
    final lower = url.toLowerCase();
    // 检查路径后缀
    final path = Uri.tryParse(lower)?.path ?? lower;
    return path.endsWith('.js') ||
        path.endsWith('.js.md5') ||
        path.endsWith('.jar') ||
        path.endsWith('.jar.md5');
  }

  static AppConfigData _createSpiderSourceConfig(String url) {
    final uri = Uri.tryParse(url);
    final pathSegments = uri?.pathSegments ?? [];

    String key;
    if (uri != null && uri.host.isNotEmpty && pathSegments.isNotEmpty) {
      final fileName = pathSegments.last
          .replaceAll('.js.md5', '')
          .replaceAll('.js', '')
          .replaceAll('.jar.md5', '')
          .replaceAll('.jar', '');
      key = fileName.isEmpty ? uri.host : fileName;
    } else if (uri != null && uri.host.isNotEmpty) {
      key = uri.host;
    } else {
      key = 'spider_source';
    }

    final name = (uri != null && uri.host.isNotEmpty)
        ? 'Spider源(${uri.host})'
        : 'Spider源';

    return AppConfigData(
      spider: url,
      sites: [
        SiteConfig(
          key: key,
          name: name,
          api: url,
          searchable: const FlexibleInt(1),
          filterable: const FlexibleInt(1),
          type: const FlexibleInt(3),
        ),
      ],
    );
  }

  // ============================================================
  // JSON 注释剥离
  // ============================================================

  /// 去除 JSON 中的 // 行注释，兼容 TVBox 配置文件格式
  static String stripJsonComments(String json) {
    // 先去掉 /* */ 块注释（跨行），再处理 // 行注释
    var text = json.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    final lines = text.split('\n');
    final result = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      // 跳过纯注释行
      if (trimmed.startsWith('//')) continue;
      // 处理行尾注释
      result.add(_removeInlineComment(line));
    }

    var joined = result.join('\n');
    // 修复尾部逗号问题：,] 或 ,}
    joined = joined.replaceAll(RegExp(r',\s*([}\]])'), r'$1');
    return joined;
  }

  /// 移除行内注释（只处理不在字符串内的 //）
  static String _removeInlineComment(String line) {
    var inString = false;
    var escape = false;
    final chars = line.split('');

    for (var i = 0; i < chars.length; i++) {
      final c = chars[i];
      if (escape) {
        escape = false;
        continue;
      }
      if (c == '\\' && inString) {
        escape = true;
        continue;
      }
      if (c == '"') {
        inString = !inString;
        continue;
      }
      if (!inString && c == '/' && i + 1 < chars.length && chars[i + 1] == '/') {
        // 找到行内注释，截断
        final before = line.substring(0, i).trimRight();
        if (before.endsWith(',')) {
          return before.substring(0, before.length - 1);
        }
        return line.substring(0, i);
      }
    }
    return line;
  }

  // ============================================================
  // 配置跳转候选提取
  // ============================================================

  static List<String> _extractConfigRedirectCandidates(String content) {
    final trimmed = content.trim();
    final rawCandidates = <String>[];

    // 明文 URL（单行且以 http 开头）
    if ((trimmed.startsWith('http://') || trimmed.startsWith('https://')) &&
        !trimmed.contains('\n')) {
      rawCandidates.add(trimmed);
    }

    // data-clipboard-text
    rawCandidates.addAll(
      _matchCaptureGroup(r'data-clipboard-text\s*=\s*["\x27]([^"\x27]+)["\x27]', content),
    );

    // JSON 中的 url 字段
    rawCandidates.addAll(
      _matchCaptureGroup(r'"url"\s*:\s*"([^"]+)"', content),
    );

    // 通用 URL 匹配
    rawCandidates.addAll(
      _matchCaptureGroup(r'(https?://[^\s"\x27<>\\]+)', content),
    );

    final normalized = rawCandidates
        .map(_sanitizeExtractedUrl)
        .map(normalizeConfigUrl)
        .where((u) => u.isNotEmpty)
        .where(_isLikelyConfigPointerUrl)
        .where((u) => !_isLikelyBinaryAssetUrl(u))
        .toList();

    return _uniqueUrlsInOrder(normalized).take(_maxRedirectCandidates).toList();
  }

  static List<String> _matchCaptureGroup(String pattern, String content) {
    final regex = RegExp(pattern, caseSensitive: false);
    return regex.allMatches(content).map((m) => m.group(1) ?? '').where((s) => s.isNotEmpty).toList();
  }

  static String _sanitizeExtractedUrl(String value) {
    var result = value.trim();
    result = result.replaceAll('&amp;', '&');
    result = result.replaceAll('\\/', '/');

    // 移除尾部标点
    while (result.isNotEmpty && ['.', ',', ';', ')', ']', '}', '"', "'"].contains(result[result.length - 1])) {
      result = result.substring(0, result.length - 1);
    }
    // 移除首部标点
    while (result.isNotEmpty && ['"', "'", '(', '[', '{'].contains(result[0])) {
      result = result.substring(1);
    }

    return result.trim();
  }

  static bool _isLikelyBinaryAssetUrl(String urlString) {
    final uri = Uri.tryParse(urlString);
    if (uri == null) return false;
    final path = uri.path.toLowerCase();
    return path.endsWith('.png') ||
        path.endsWith('.jpg') ||
        path.endsWith('.jpeg') ||
        path.endsWith('.webp') ||
        path.endsWith('.gif') ||
        path.endsWith('.svg') ||
        path.endsWith('.ico') ||
        path.endsWith('.css') ||
        path.endsWith('.woff') ||
        path.endsWith('.woff2') ||
        path.endsWith('.ttf');
  }

  static bool _isLikelyConfigPointerUrl(String urlString) {
    final uri = Uri.tryParse(urlString);
    if (uri == null) return false;

    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final query = uri.query.toLowerCase();

    if (host.contains('raw.githubusercontent.com') ||
        host.contains('githubusercontent.com')) {
      return true;
    }

    if (path.contains('.json') ||
        path.endsWith('/tv') ||
        path.endsWith('/tv/') ||
        path.endsWith('/m') ||
        path.endsWith('/m/') ||
        path.contains('tvbox') ||
        path.contains('box') ||
        query.contains('json') ||
        query.contains('config') ||
        query.contains('url=')) {
      return true;
    }

    return false;
  }

  static List<String> _uniqueUrlsInOrder(List<String> urls) {
    final seen = <String>{};
    final result = <String>[];

    for (final url in urls) {
      final trimmed = url.trim();
      if (trimmed.isEmpty) continue;
      final key = trimmed.toLowerCase();
      if (seen.contains(key)) continue;
      seen.add(key);
      result.add(trimmed);
    }

    return result;
  }
}

/// 原始配置缓存条目（LRU）
class _RawConfigCacheEntry {
  final String content;
  final DateTime fetchedAt;
  DateTime lastAccess;

  _RawConfigCacheEntry({required this.content, required this.fetchedAt})
      : lastAccess = fetchedAt;

  void touch(DateTime now) {
    lastAccess = now;
  }
}
