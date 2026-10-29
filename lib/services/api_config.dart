import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/local_python_sources.dart';
import 'package:tvbox/services/moontv_converter.dart';
import 'package:tvbox/services/prefs_mirror.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/models/app_config.dart';
import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/common/constants.dart';
import 'package:tvbox/services/network_manager.dart';
import 'package:tvbox/services/live_service.dart';
import 'package:tvbox/services/host_resolver.dart';
import 'package:tvbox/services/xbpq/xbpq_service.dart';

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

  /// 用户单独导入的本地 Python 源（与订阅线路**分开**）。
  ///
  /// 不放进 [sourceBeanList]：那张表是"以接口下发的 sites 为准整表替换"的，
  /// 本地源混进去会被 /config 覆盖/污染；这里单独一份，源面板单独成组。
  final localVideoSources = <SourceBean>[].obs;

  /// 「本地 Python 源」总开关（用户 2026-10-18）。
  ///
  /// 默认 **false**：启动时只加载订阅激活的线路，本地源不参与
  /// 主页源恢复 / 搜索 / 源面板 / Python 引擎启动；
  /// 打开后本地源才和以前一样全部可用。清单本身仍会读取，
  /// 所以「订阅管理 → 本地爬虫」里依旧能看到、管理已导入的脚本。
  final localSourcesEnabled = false.obs;

  /// 保存开关的 prefs 键
  static const String _kLocalSourcesEnabled = 'local_sources_enabled_v1';

  /// key 是否属于「本地源」两族之一（Python / XBPQ）。
  ///
  /// 收敛成一个判断，是为了以后再加一族引擎时不会漏掉主页源回退那几处。
  static bool _isLocalSourceKey(String key) =>
      key.startsWith('localpy_') ||
      key.startsWith(SourceBean.xbpqKeyPrefix);

  /// 本地源当前是否**参与**（源面板 / 搜索 / 主页源恢复）。
  ///
  /// Python / XBPQ 源都看总开关。订阅线路**不受**本地开关影响。
  bool isLocalSourceEnabled(SourceBean s) {
    if (s.key.startsWith('localpy_')) {
      return localSourcesEnabled.value;
    }
    if (s.key.startsWith(SourceBean.xbpqKeyPrefix)) {
      return localSourcesEnabled.value;
    }
    return true;
  }

  /// 本地 **Python** 源数量（`localpy_`）。
  ///
  /// 之前设置页「本地爬虫」那行显示的是 [localVideoSources] 的**总**长度，
  /// 把 JS 源也算进去了（用户截图里 114 个是 PY+JS 合数）—— 拆成两个开关后
  /// 必须各数各的，否则两行数字会互相矛盾。
  int get localPythonSourceCount =>
      localVideoSources.where((s) => s.key.startsWith('localpy_')).length;

  /// 本地 **XBPQ** 规则源数量（`localxbpq_`）。
  ///
  /// 与 PY / JS 一样各数各的：XBPQ 没有独立子开关，跟着「本地爬虫」总开关走，
  /// 但数量必须分开显示，否则用户看不出自己导了几条规则。
  int get localXbpqSourceCount => localVideoSources
      .where((s) => s.key.startsWith(SourceBean.xbpqKeyPrefix))
      .length;

  final dohList = <(String, String)>[].obs;
  final isLoaded = false.obs;
  final configUrl = ''.obs;

  /// 最近一次成功解析的配置里的**广告黑名单 / 过滤规则**。
  ///
  /// 为什么要暴露（用户 2026-10-14：「接口配置下载源文件好慢」）：
  /// 之前 `AppState._reloadAdFilterRules` 为了拿这两个列表，会把**整份配置
  /// 再下一次** —— 而且它直接走 NetworkManager，绕开了 20s 的原始文本缓存
  /// ⇒ 大配置（几 MB）等于白耗一倍流量、还和首页首屏请求抢带宽。
  /// 现在解析时顺手存下来，广告过滤直接读这份，**不再有第二次下载**。
  List<String> lastAds = const [];
  List<RuleConfig> lastRules = const [];

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
  ///
  /// **static**：这样 main() 里在实例还没注册之前就能预取（见 [prefetchConfig]），
  /// 预取结果对之后真正加载的那个实例同样有效。进程级缓存 + 20s TTL，语义不变。
  static final Map<String, _RawConfigCacheEntry> _rawConfigCache = {};

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

  /// 启动预取：只把「原始配置文本」预热进 [_rawConfigCache]（20s TTL），
  /// **不解析、不写状态、不抛错**。
  ///
  /// 用途：`ContentView` 要等第一帧之后才发起真正的加载，而这里是在 main() 里
  /// fire-and-forget 先拉一遍 ⇒ 真正加载时直接命中缓存，少等一次完整网络往返
  /// （用户反馈"启动要好久"）。失败完全静默 —— 预取只是优化，不影响主流程。
  ///
  /// **static**：main() 调它时 `ApiConfig` 实例还没注册（注册在 TVBoxApp.initState）。
  static Future<void> prefetchConfig(String apiUrl) async {
    try {
      final normalized = normalizeConfigUrl(apiUrl.trim());
      if (normalized.isEmpty) return;
      // 本地转换配置不走网络
      if (ConvertedConfigStore.isLocal(normalized)) return;
      // 单 js/jar spider 源不是 JSON，预取没意义（那类走 Node 加载那套）
      if (_isSpiderSourceUrl(normalized)) return;

      final key = normalized.toLowerCase();
      final now = DateTime.now();
      final content = await NetworkManager.instance.getString(normalized);
      _rawConfigCache[key] = _RawConfigCacheEntry(
        content: content,
        fetchedAt: now,
      );
      _trimRawConfigCacheIfNeeded();
      AppLog.instance.log('[ApiConfig] 配置预取完成（命中缓存后加载会更快）');
    } catch (_) {
      // 静默：预取失败就老老实实走正常加载路径
    }
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
    } catch (e) {
      /* ignore */
    }

    if (decoded != null) {
      final config = AppConfigData.fromJson(decoded);
      if (config.hasUsableContent) return null;

      // MoonTV 影视仓不是多仓库入口（加载时会现场转换），这里直接放行
      if (MoonTvConverter.tryConvert(decoded) != null) return null;

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
          final resolvedName = (displayName != null && displayName.isNotEmpty)
              ? displayName
              : fallbackName;
          options.add(MultiRepoOption(name: resolvedName, url: candidate));
        }

        return options;
      } catch (_) {
        return null;
      }
    }

    return null;
  }

  /// 获取指定 key 的源（订阅线路 + 本地 Python 源）
  ///
  /// 本地源只在「本地爬虫」开关打开时参与（用户 2026-10-18：默认优先订阅激活的源）。
  SourceBean? getSource(String key) {
    return sourceBeanList.firstWhereOrNull((s) => s.key == key) ??
        localVideoSources.firstWhereOrNull(
            (s) => s.key == key && isLocalSourceEnabled(s));
  }

  /// 获取可搜索的源列表（本地 Python 源也参与搜索）
  List<SourceBean> getSearchableSources() {
    final result = sourceBeanList
        .where((s) => s.isSearchable && s.key != 'douban' && s.key != 'baseset')
        .toList();
    final enabledLocal =
        localVideoSources.where((s) => s.isSearchable && isLocalSourceEnabled(s));
    result.addAll(enabledLocal);
    AppLog.instance.log(
      '[ApiConfig] getSearchableSources: 总源数=${sourceBeanList.length}'
      '+${enabledLocal.length} 本地源, '
      '可搜索源数=${result.length}',
    );
    return result;
  }

  /// 重新读取「本地源」清单（导入/删除/切开关后调用）。
  ///
  /// 只更新 [localVideoSources]，**不动** [sourceBeanList] —— 订阅线路与本地源是两套。
  ///
  /// 🔴 2026-10-29 修（用户：「本地源和订阅切换的时候，没切换过来」）：
  ///   以前整个方法体是**一个 try 包到底** —— `LocalPythonSources.load` /
  ///   `localVideoSources.assignAll` / 「主页源回退到
  ///   订阅线路」这几件事共用同一个 catch。只要前面任何一步抛错（本地目录
  ///   权限、清单损坏、路径拿不到…），后面**全部不执行**：
  ///     · 本地源清单停在旧值（删掉的源还在、新导入的看不到）；
  ///     · **主页源回退逻辑永远跑不到** ⇒ 主页源死钉在一个已经不可用的本地源上，
  ///       用户切回订阅线路也切不动，表现为「切了源没反应 / 内容不显示」。
  ///   现在四件事各自独立兜住：任何一步失败都不影响其余步骤，
  ///   尤其「主页源回退」一定会执行。
  Future<void> reloadLocalVideoSources() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      AppLog.instance.w('[ApiConfig] 读取本地源开关失败: $e');
    }

    // ── ① 开关口径：每次都同步一次（默认关），保证冷启动 / 切订阅时一致 ──
    if (prefs != null) {
      localSourcesEnabled.value = prefs.getBool(_kLocalSourcesEnabled) ?? false;
    }

    // ── ② 两套本地源各自独立加载：Python 那套抛错不能把 JS 那套一起带走 ──
    try {
      await LocalPythonSources.instance.load(force: true);
    } catch (e) {
      AppLog.instance.w('[ApiConfig] 读取本地 Python 源失败: $e');
    }
    try {
      await XbpqService.instance.ensureLoaded(force: true);
    } catch (e) {
      AppLog.instance.w('[ApiConfig] 读取本地 XBPQ 源失败: $e');
    }

    // ── ③ 汇总清单（单条转 bean 出错就跳过它，不整表作废）──
    final list = <SourceBean>[];
    for (final e in LocalPythonSources.instance.sources) {
      try {
        list.add(e.toSourceBean());
      } catch (_) {
        /* 单条坏数据不影响其它源 */
      }
    }
    for (final bean in XbpqService.instance.sourceBeans) {
      try {
        list.add(bean);
      } catch (_) {
        /* 同上 */
      }
    }
    localVideoSources.assignAll(list);

    // ── ④ 主页源回退：**无条件执行**（上面哪一步失败都要跑到这里）──
    try {
      final cur = homeSourceBean.value;
      if (cur != null && _isLocalSourceKey(cur.key)) {
        if (!isLocalSourceEnabled(cur)) {
          homeSourceBean.value = sourceBeanList.firstOrNull;
          await prefs?.remove(_kLocalHomeApi);
          AppLog.instance.log('[ApiConfig] 本地源开关已关闭，主页源切回订阅线路');
        } else {
          SourceBean? updated;
          for (final s in list) {
            if (s.key == cur.key) {
              updated = s;
              break;
            }
          }
          if (updated == null) {
            // 删掉的是当前本地源：**只在启用中的本地源里**挑一个，
            // 避免落到被「本地 JS 源」子开关关掉的源上（那样主页源等于不可用）。
            final enabledLocal = list.where(isLocalSourceEnabled).toList();
            homeSourceBean.value =
                enabledLocal.firstOrNull ?? sourceBeanList.firstOrNull;
            // 「全局锁定本地源」的键也要清掉，否则下次恢复会指向已删除的 key
            await prefs?.remove(_kLocalHomeApi);
            AppLog.instance.log(
              '[ApiConfig] 主页源指向的本地源已不存在，已切到 '
              '${homeSourceBean.value?.key ?? '(空)'}',
            );
          } else if (updated.name != cur.name) {
            homeSourceBean.value = updated;
          }
        }
      }
    } catch (e) {
      AppLog.instance.w('[ApiConfig] 主页源回退失败: $e');
    }
  }

  /// 「本地 Python 源」开关（用户 2026-10-18）。
  ///
  /// 关闭时：主页源若是本地源立刻切回订阅激活的第一条，并清掉本地源锁定键；
  /// 打开时：重新挂上本地源并注册进 Python 引擎（点开关就能直接用）。
  Future<void> setLocalSourcesEnabled(bool value) async {
    if (localSourcesEnabled.value == value) return;
    localSourcesEnabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLocalSourcesEnabled, value);
    PrefsMirror.snapshotSoon();
    await reloadLocalVideoSources();
    if (!value) return;
    // 打开：把脚本注册进引擎（registerAll 内部会按需启动 Python）
    try {
      await LocalPythonSources.instance.registerAll();
    } catch (e) {
      AppLog.instance.w('[ApiConfig] 本地源注册失败: $e');
    }
  }

  /// 主页源选择：按**订阅（配置地址）分别记住**。
  ///
  /// 之前只存一个全局 `homeApi` ⇒ 换了订阅、或换个订阅再切回来，都只能拿到
  /// "另一个订阅" 的那次选择（key 对不上就退回第一个）。用户 2026-10-13：
  /// 「不管是哪种线路，退出再开应该还是上次退出前的那个源」。
  static const String _kHomeApiMap = 'home_api_map';

  /// 本地 Python 源的主页选择（全局，与订阅地址无关）。
  ///
  /// 用户 2026-10-18：「我既然切换本地了，点播地址就应该是本地的，
  /// 而且一直是第一次导入的那个；订阅里再激活别的线路也不该把它换掉」。
  /// 所以本地源一旦被选为主页源，就单独记一份全局键，切订阅时优先恢复它；
  /// 选回订阅线路时再清掉。
  static const String _kLocalHomeApi = 'local_home_api';

  String get _homeScopeKey => configUrl.value.trim();

  /// 设置主页源
  Future<void> setHomeSource(SourceBean source) async {
    homeSourceBean.value = source;
    final prefs = await SharedPreferences.getInstance();
    // 仍写一份全局键，兼容旧逻辑/旧数据
    await prefs.setString(AppConstants.homeApi, source.key);
    // 本地源（Python）：全局锁定，不随订阅切换
    if (source.key.startsWith('localpy_')) {
      await prefs.setString(_kLocalHomeApi, source.key);
    } else {
      await prefs.remove(_kLocalHomeApi);
    }
    final scope = _homeScopeKey;
    if (scope.isEmpty) return;
    try {
      final raw = prefs.getString(_kHomeApiMap);
      final map = (raw == null || raw.isEmpty)
          ? <String, dynamic>{}
          : (jsonDecode(raw) as Map).cast<String, dynamic>();
      map[scope] = source.key;
      await prefs.setString(_kHomeApiMap, jsonEncode(map));
      // 🔴 2026-10-14 修（洞 G）：切主页源也要"改完即落盘 + 刷镜像"。
      // 这里以前漏了 snapshotSoon —— 切完主页源立刻被硬杀（这个 App 的常态），
      // 重启就回到旧主页源。其它设置写入点都调了，就这两处没调。
      PrefsMirror.snapshotSoon();
    } catch (e) {
      AppLog.instance.log('[ApiConfig] 保存主页源(按订阅)失败: $e');
    }
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

  /// 启动时校正接口地址：**文件备份是权威**，与 prefs 不同就以备份为准。
  ///
  /// 🔴 2026-10-14 修（洞 H）：原来是 `if (current.trim().isNotEmpty) return current;`
  ///   —— 只有"prefs 里连键都没有"才用备份。但 prefs 的常态是**部分丢失**
  ///   （键还在、值是旧的），而备份才是权威：每次 `persistApiUrl` 都带
  ///   `flush: true` 写它，它永远不会比 prefs 旧。那道门把备份挡在外面，
  ///   于是"改完立刻被硬杀 → 重启回旧源"。
  static Future<String> restoreApiUrlIfLost(String current) async {
    try {
      final f = await _apiUrlBackupFile();
      if (!await f.exists()) return current;
      final v = (await f.readAsString()).trim();
      // 备份为空、或与 prefs 一致 → 没什么可修正的
      if (v.isEmpty || v == current.trim()) return current;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.apiUrl, v);
      AppLog.instance.log('[ApiConfig] 接口地址以文件备份为准修正（prefs 里的值已过期或缺失）');
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

  /// 「源切换」里用户自定义的线路顺序（JSON：`{订阅前缀: [key, ...]}`）
  static const String _kVideoSourceOrder = 'video_source_order';

  /// 「失效线路」落盘键。
  ///
  /// ── 为什么需要（用户 2026-10-15）────────────────────────────────────
  /// 「已经订阅的线路里面的源我能删除吗？删除后不再加载呢」
  /// 「或者是移入失效分类，不加载不显示呢」
  ///
  /// 线路表是**以接口下发的 sites 为准整表替换**的 ⇒ 在界面上直接删掉一条，
  /// 下次加载（切源 / 重启 / 回前台重载）又被灌回来。
  /// ⇒ 做法：把这条线路**移出** sourceBeanList，连原字段一起落盘到「失效线路」，
  ///    并在每次重建线路表之后统一过滤 —— 于是它"不加载、不显示"，
  ///    但随时能在源面板的「失效」里移回（不丢数据）。
  ///
  /// 条目形如：`{"id":"<订阅配置地址>\u0001<key>", "key":…, "name":…, "api":…,
  ///           "type":…, "ext":…}`。
  /// id 里带订阅地址是为了**按订阅隔离** —— 不同订阅里的同名 key 不该互相影响。
  static const String _kInvalidVideoSources = 'invalid_video_sources';

  /// id → 原字段（"移回"时直接用它补回列表，不必重拉 /config）
  final Map<String, Map<String, dynamic>> _invalidVideoSources = {};

  bool _invalidLoaded = false;

  /// 当前订阅的失效线路条数（UI 用它做响应式刷新）
  final invalidVideoSourceCount = 0.obs;

  /// 导入/更新一条用户注入的站点：入列表 + 落盘
  ///
  /// [enabled] 关闭的站点**只落盘不入列表**（改回开启后下次整表替换会带回来）；
  /// [homePage]/[searchable] 等一并落盘，UI 用 [userInjectedSites] 读。
  Future<void> addUserVideoSource(
    SourceBean bean, {
    bool enabled = true,
    String homePage = '',
  }) async {
    sourceBeanList.removeWhere((s) => s.key == bean.key || s.api == bean.api);
    if (enabled) sourceBeanList.add(bean);
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
      raw.add(
        jsonEncode({
          'key': bean.key,
          'name': bean.name,
          'api': bean.api,
          'type': bean.type,
          'ext': bean.ext,
          // ── 站点注入留下的扩展字段（写入方已随 Webhtv 模块下线，
          //    这里保留读写口径：老用户盘上的数据仍会被合并进线路表）──
          'enabled': enabled,
          'indexs': bean.indexs, // -1 = 插到最前；0 = 末尾（默认）
          'searchable': bean.searchable,
          'quickSearch': bean.quickSearch,
          'filterable': bean.filterable,
          'homePage': homePage,
        }),
      );
      await prefs.setStringList(_kUserVideoSources, raw);
      // 🔴 2026-10-14 修（洞 G）：导入自定义线路同样要立刻落盘 + 刷镜像，
      // 否则导入完被硬杀 → 重启线路没了。
      PrefsMirror.snapshotSoon();
      AppLog.instance.log(
        '[ApiConfig] 已保存用户视频线路 ${bean.key}（共 ${raw.length} 条）',
      );
    } catch (e) {
      AppLog.instance.log('[ApiConfig] 保存用户视频线路失败: $e');
    }
  }

  /// 用户注入的站点列表（原始 JSON）
  ///
  /// ⚠️ 写入方（「Webhtv → 站点注入」）已随该模块下线（用户 2026-10-16）；
  ///    这里保留读取口径，只为不破坏老用户盘上的数据。
  Future<List<Map<String, dynamic>>> userInjectedSites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kUserVideoSources) ?? const <String>[];
      return raw
          .map((e) {
            try {
              final m = jsonDecode(e);
              return m is Map ? Map<String, dynamic>.from(m) : null;
            } catch (_) {
              return null;
            }
          })
          .whereType<Map<String, dynamic>>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 删除一条用户注入的站点
  Future<void> removeUserVideoSource(String key) async {
    sourceBeanList.removeWhere((s) => s.key == key);
    await _removeFromUserStore(key);
    AppLog.instance.log('[ApiConfig] 已删除用户视频线路 $key');
  }

  /// 从「用户线路」落盘里摘掉同 key 条目（否则下次整表替换又合并回来）
  Future<void> _removeFromUserStore(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kUserVideoSources) ?? <String>[];
      raw.removeWhere((e) {
        try {
          return ((jsonDecode(e) as Map)['key'] ?? '').toString() == key;
        } catch (_) {
          return false;
        }
      });
      await prefs.setStringList(_kUserVideoSources, raw);
      PrefsMirror.snapshotSoon();
    } catch (e) {
      AppLog.instance.log('[ApiConfig] 写入用户视频线路失败: $e');
    }
  }

  // ============================================================
  // 失效线路（用户 2026-10-15：「移入失效分类，不加载不显示」）
  // ============================================================

  /// 当前订阅维度的 id 前缀（空订阅地址时退化为"只按 key"，全局生效）
  String get _invalidIdPrefix {
    final url = configUrl.value.trim();
    return url.isEmpty ? '' : '$url\u0001';
  }

  String _invalidIdOf(String key) => '$_invalidIdPrefix${key.trim()}';

  Future<void> _ensureInvalidLoaded() async {
    if (_invalidLoaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      for (final e
          in p.getStringList(_kInvalidVideoSources) ?? const <String>[]) {
        try {
          final m = jsonDecode(e);
          if (m is! Map) continue;
          final map = Map<String, dynamic>.from(m);
          final id = (map['id'] ?? '').toString();
          if (id.isEmpty) continue;
          _invalidVideoSources[id] = map;
        } catch (_) {
          // 坏条目跳过，不影响其它
        }
      }
    } catch (_) {
      // 读失败按"没有失效线路"起步
    }
    _invalidLoaded = true;
    _syncInvalidCount();
  }

  Future<void> _persistInvalid() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(
        _kInvalidVideoSources,
        _invalidVideoSources.values.map((v) => jsonEncode(v)).toList(),
      );
      PrefsMirror.snapshotSoon();
    } catch (e) {
      AppLog.instance.log('[ApiConfig] 保存失效线路失败: $e');
    }
    _syncInvalidCount();
  }

  // ============================================================
  // 线路顺序（用户 2026-10-18：源切换里可以按住把手拖动排序）
  // ============================================================

  /// `{订阅前缀: [key, ...]}` 的 JSON
  final Map<String, List<String>> _videoSourceOrder = {};
  bool _orderLoaded = false;

  Future<void> _ensureOrderLoaded() async {
    if (_orderLoaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kVideoSourceOrder) ?? '';
      if (raw.isNotEmpty) {
        final d = jsonDecode(raw);
        if (d is Map) {
          d.forEach((k, v) {
            if (v is List) {
              _videoSourceOrder[k.toString()] = v
                  .map((e) => e.toString())
                  .where((e) => e.isNotEmpty)
                  .toList();
            }
          });
        }
      }
    } catch (_) {
      // 读失败按"没有自定义顺序"起步
    }
    _orderLoaded = true;
  }

  Future<void> _persistOrder() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kVideoSourceOrder, jsonEncode(_videoSourceOrder));
      PrefsMirror.snapshotSoon();
    } catch (e) {
      AppLog.instance.log('[ApiConfig] 保存线路顺序失败: $e');
    }
  }

  /// 按用户自定义顺序排一遍（没记录的 key 保持原来的相对位置，排在后面）
  Future<void> _applyVideoSourceOrder(List<SourceBean> list) async {
    if (list.length < 2) return;
    await _ensureOrderLoaded();
    final order = _videoSourceOrder[_invalidIdPrefix];
    if (order == null || order.isEmpty) return;
    final byKey = {for (final s in list) s.key: s};
    final sorted = <SourceBean>[];
    for (final k in order) {
      final hit = byKey.remove(k);
      if (hit != null) sorted.add(hit);
    }
    sorted.addAll(list.where((s) => byKey.containsKey(s.key)));
    list
      ..clear()
      ..addAll(sorted);
  }

  /// 源切换面板按住把手拖动后回写顺序（只动传进来的这些 key 占的坑位）
  Future<void> reorderVideoSources(List<String> visibleKeys) async {
    if (visibleKeys.isEmpty) return;
    await _ensureOrderLoaded();
    final list = List<SourceBean>.of(sourceBeanList);
    if (list.isEmpty) return;
    final wanted = visibleKeys.toSet();
    final byKey = {for (final s in list) s.key: s};
    final queue = List<String>.from(visibleKeys);
    final next = <SourceBean>[];
    var qi = 0;
    for (final s in list) {
      if (wanted.contains(s.key)) {
        final moved = byKey[queue[qi++]];
        if (moved != null) next.add(moved);
      } else {
        next.add(s);
      }
    }
    sourceBeanList.assignAll(next);
    _videoSourceOrder[_invalidIdPrefix] = next.map((s) => s.key).toList();
    await _persistOrder();
    AppLog.instance.log('[ApiConfig] 已保存线路顺序（${next.length} 条）');
  }

  void _syncInvalidCount() {
    invalidVideoSourceCount.value = invalidVideoSourcesForCurrentSub.length;
  }

  /// 当前订阅的失效线路（供「失效」面板展示 + 移回）
  List<Map<String, dynamic>> get invalidVideoSourcesForCurrentSub {
    final prefix = _invalidIdPrefix;
    return _invalidVideoSources.entries
        .where(
          (e) => prefix.isEmpty
              ? !e.key.contains('\u0001')
              : e.key.startsWith(prefix),
        )
        .map((e) => Map<String, dynamic>.from(e.value))
        .toList();
  }

  /// 这条线路是不是"已移入失效"（当前订阅维度）
  bool isVideoSourceInvalid(String key) =>
      _invalidVideoSources.containsKey(_invalidIdOf(key));

  /// 重建线路表之后统一过滤掉失效线路 ——
  /// 两处 `sourceBeanList.value = …`（/config 整表替换、配置解析）之前都要调。
  void _dropInvalidSources(List<SourceBean> list) {
    if (_invalidVideoSources.isEmpty || list.isEmpty) return;
    final before = list.length;
    list.removeWhere((s) => isVideoSourceInvalid(s.key));
    final dropped = before - list.length;
    if (dropped > 0) {
      AppLog.instance.log('[ApiConfig] 已过滤 $dropped 条失效线路（不加载 / 不显示）');
    }
  }

  /// 把一条线路**移入失效**：出列表 + 落盘（不加载、不显示，但随时能移回）
  Future<void> markVideoSourceInvalid(SourceBean bean) async {
    final key = bean.key.trim();
    if (key.isEmpty) return;
    await _ensureInvalidLoaded();
    final id = _invalidIdOf(key);
    _invalidVideoSources[id] = {
      'id': id,
      'key': key,
      'name': bean.name,
      'api': bean.api,
      'type': bean.type,
      'ext': bean.ext,
    };
    sourceBeanList.removeWhere((s) => s.key == key);
    await _removeFromUserStore(key);
    // 移的正好是当前主页源 ⇒ 换到剩下的第一条，别让首页挂着一个失效源
    if (homeSourceBean.value?.key == key) {
      final first = sourceBeanList.firstOrNull;
      if (first != null) setHomeSource(first);
    }
    await _persistInvalid();
    AppLog.instance.log(
      '[ApiConfig] 线路 $key 已移入失效'
      '（当前订阅共 ${invalidVideoSourceCount.value} 条）',
    );
  }

  /// 把一条失效线路**移回**列表（按 id）
  Future<bool> restoreInvalidVideoSource(String id) async {
    await _ensureInvalidLoaded();
    final m = _invalidVideoSources.remove(id);
    if (m == null) return false;
    final key = (m['key'] ?? '').toString().trim();
    if (key.isNotEmpty && !sourceBeanList.any((s) => s.key == key)) {
      sourceBeanList.add(
        SourceBean(
          key: key,
          name: (m['name'] ?? key).toString(),
          api: (m['api'] ?? '').toString(),
          type: (m['type'] as num?)?.toInt() ?? 3,
          ext: m['ext']?.toString(),
        ),
      );
    }
    await _persistInvalid();
    AppLog.instance.log('[ApiConfig] 失效线路已移回: $key');
    return true;
  }

  /// 把当前订阅的失效线路**全部移回**
  Future<int> restoreAllInvalidVideoSources() async {
    final items = invalidVideoSourcesForCurrentSub;
    var n = 0;
    for (final m in items) {
      if (await restoreInvalidVideoSource((m['id'] ?? '').toString())) n++;
    }
    return n;
  }

  /// 把落盘的用户线路合并进 [target]（按 key 去重；接口已下发的同 key 不覆盖）
  ///
  /// 「站点注入」留下的扩展字段（写入方已随 Webhtv 下线，合并逻辑保留）：
  ///   · `enabled == false` 的**跳过**（只是不显示，配置仍留在盘上，随时改回来）；
  ///   · `indexs == -1` 的插到**最前**，其余按落盘顺序追加在末尾；
  ///   · `searchable / quickSearch / filterable` 决定它参与搜索 / 快速搜索 / 筛选。
  Future<void> _mergeUserVideoSources(List<SourceBean> target) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kUserVideoSources) ?? const <String>[];
      if (raw.isEmpty) return;
      final head = <SourceBean>[];
      var added = 0;
      for (final e in raw) {
        final m = jsonDecode(e) as Map;
        if (m['enabled'] == false) continue;
        final key = (m['key'] ?? '').toString().trim();
        if (key.isEmpty || target.any((s) => s.key == key)) continue;
        // ── 用户 2026-10-15：py 源不再当影视「线路」──────────────────────
        // 历史版本把导入的 py 源也落盘成一条线路（api = `py_xxx.py`）。
        // 现在「导入 py 源」不再注册线路，这些历史条目也要**不再合并回来** ——
        // 否则它们仍然出现在线路列表里，并继续污染 /config 整表替换的判据
        //（allPlaceholder，见 updateSourceBeansFromSpiderConfig）。
        // ⚠️ 只**跳过**、不删盘：万一以后要恢复，数据还在。
        final userApi = (m['api'] ?? '').toString();
        if (userApi.toLowerCase().split('?').first.endsWith('.py')) continue;
        final indexs = (m['indexs'] as num?)?.toInt() ?? 0;
        final bean = SourceBean(
          key: key,
          name: (m['name'] ?? key).toString(),
          api: (m['api'] ?? '').toString(),
          searchable: (m['searchable'] as num?)?.toInt() ?? 1,
          filterable: (m['filterable'] as num?)?.toInt() ?? 0,
          quickSearch: (m['quickSearch'] as num?)?.toInt() ?? 0,
          playerType: 0,
          type: (m['type'] as num?)?.toInt() ?? 3,
          ext: m['ext']?.toString(),
          indexs: indexs,
        );
        if (indexs == -1) {
          head.add(bean);
        } else {
          target.add(bean);
        }
        added++;
      }
      if (head.isNotEmpty) target.insertAll(0, head);
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
    // 🔴 2026-10-14 修（用户：「花蚁/OmniBox/猫源三种订阅互切都不顺」）：
    // 整表替换**只**对两类配置合法：
    //   ① 整包就是一个 js/jar spider（点播接口地址本身 = .js/.jar）——
    //     sites 是 _createSpiderSourceConfig 造的占位，必须换成 /config 真实线路；
    //   ② CatVod 类 csp_ 占位配置——sites[].api 全是 csp_xxx 占位字符串，
    //     真实线路同样由 spider /config 下发。
    // 聚合配置（sites 里是真实 http/.py 线路，如 huahua.json）**不能**被
    // /config 冲掉——之前这里没有守卫，Node 一旦启动（聚合里含 js 源就会
    // 启动），/config 一返回就把聚合自己的线路整表替换，表现为「切换不顺」。
    // ⚠️ 判据必须与 `isSingleScriptSpider`（loadConfigs 里
    //    `_isSpiderSourceUrl(apiUrl) || config.spider 非空`）**对齐**：
    //    这里原来只看**配置 URL 的后缀**（`_isSpiderSourceUrl(configUrl)`），
    //    于是一份"以 .json/.txt 下发、但声明了 `spider` 字段"的 CatVod / TVBox
    //    订阅会被判成"聚合配置（线路自持）"⇒ **跳过 /config 整表替换**
    //    ⇒ 线路表永远停在 sites[] 里的 `csp_` / 数字 key 占位
    //    ⇒ 表现就是"猫源 / tvbox 全部没有内容"。
    //
    //    用户日志实证（app_2026-10-15.log，同一个源上自相矛盾）：
    //      [ApiConfig] 单个 Spider 配置：先给兜底主页源 index，/config 返回后再校正
    //      [AppState]  Spider 源加载成功
    //      [ApiConfig] 聚合配置（线路自持），跳过 /config 整表替换   ← 该替换的没替换
    //    这条守卫在当天日志里**命中 9 次**。
    //    （用户三次同样的抱怨 2026-10-13 / 10-14 / 10-15：
    //      「没加 py 源前，猫源和 tvbox 随时切换随时能播放」）
    final wholePackIsSpider =
        isSingleScriptSpider.value || _isSpiderSourceUrl(configUrl.value);
    // 「全是占位」的判定要**排除本地自持的线路**：py 模块的 api 是 `py_xxx.py`
    // （本地已注册模块，不是可下载线路），既不为空也不是 `csp_` —— 只要用户导入过
    // **任何一个 py 源**，这个判定就被打破，上面那条守卫随即误命中。
    // 这正是"加了 py 源之后猫源 / tvbox 就没内容了"的直接原因。
    final allPlaceholder =
        sourceBeanList.isNotEmpty &&
        sourceBeanList.every(
          (s) =>
              s.api.isEmpty ||
              s.api.toLowerCase().startsWith('csp_') ||
              s.isPythonScriptSource,
        );
    if (!wholePackIsSpider && !allPlaceholder) {
      // 把三个判据都打出来：下一次再出现"线路没内容"，一眼就能看出是哪个判据
      // 决定的，不用再靠猜（上面那段注释里的矛盾正是这么发现的）
      AppLog.instance.log(
        '[ApiConfig] 聚合配置（线路自持），跳过 /config 整表替换'
        '（isSingleScriptSpider=${isSingleScriptSpider.value}, '
        'urlIsSpider=${_isSpiderSourceUrl(configUrl.value)}, '
        'allPlaceholder=$allPlaceholder, '
        'lines=${sourceBeanList.length}）',
      );
      return;
    }

    // 🔴 2026-10-14 修（切源竞态）：这份 /config 属于**发起请求那一刻**的那个源。
    // 用户快速连切 A→B（或 A→B→A）时，A 的响应可能晚于 B 返回；没有这道校验
    // 就会把 **B 的线路表整表覆盖成 A 的**，而 Node 里驻留的已经是 B 的脚本 ——
    // 线路表与引擎不一致，表现为「切了但内容还是旧的 / 错乱」。
    // ⚠️ 调用方必须传"**请求前**的 configUrl 快照"（以前传的是空串，等于没校验）。
    if (spiderUrl.isNotEmpty && configUrl.value != spiderUrl) {
      AppLog.instance.log(
        '[ApiConfig] /config 回填作废（请求期间源已切换：$spiderUrl → ${configUrl.value}）',
      );
      return;
    }

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

      newSources.add(
        SourceBean(
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
        ),
      );
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

    // 🔴 2026-10-14 简修（洞 L）：整表替换时**保留"程序模块"注册的影视源**。
    //   它们 key 以 `app_` 开头，不在 /config 下发的站点里；而
    //   `MiniAppService.ensureLoaded` 有 `_loaded` 标志只跑一次，切源后**不会**
    //   重新注册 ⇒ 整表替换把它们清掉后，表现为"切源后程序里的影视源消失，
    //   重启才回来"（用户 2026-10-14 报）。这里原样带上（按 key 去重，避免重复）。
    final alreadyKeys = newSources.map((s) => s.key).toSet();
    var keptApp = 0;
    for (final s in sourceBeanList.where((s) => s.key.startsWith('app_'))) {
      if (alreadyKeys.contains(s.key)) continue;
      newSources.add(s);
      keptApp++;
    }
    if (keptApp > 0) {
      AppLog.instance.log('[ApiConfig] /config 整表替换：保留 $keptApp 条程序源(app_)');
    }

    // 失效线路（用户 2026-10-15：「移入失效分类，不加载不显示」）：
    // 必须放在**所有来源都补完之后、赋值之前**（含上面合并的用户线路与
    // 补回的 app_ 程序源），否则漏掉的那些又会被灌回来。
    await _ensureInvalidLoaded();
    _dropInvalidSources(newSources);
    // 用户手动拖过的顺序：重建线路表后照样生效
    await _applyVideoSourceOrder(newSources);
    // 订阅刚换过 ⇒ 失效条数是"当前订阅维度"的，要跟着一起刷新（顶部「失效 N」）
    _syncInvalidCount();

    sourceBeanList.value = newSources;
    // 本地 Python 源是独立一套：订阅线路整表替换后重新挂上（不混入 newSources）
    await reloadLocalVideoSources();

    // 优先恢复保存的主页源
    await _restoreHomeSource(newSources);

    // ⚠️ 恢复结果必须**再校验一次**才能兜底：
    //   原来用「恢复前」的 currentKey 判断，会把 _restoreHomeSource 刚恢复的
    //   本地 Python 源（或本订阅保存的源）又覆盖成列表第一条 ——
    //   表现为「切本地后一换订阅就跳回订阅线路 / 引擎没跟着切」。
    final restored = homeSourceBean.value;
    final restoredValid =
        restored != null &&
        (newSources.any((s) => s.key == restored.key) ||
            localVideoSources
                .any((s) => s.key == restored.key && isLocalSourceEnabled(s)));
    if (!restoredValid) {
      homeSourceBean.value = newSources.firstOrNull ??
          localVideoSources.firstWhereOrNull(isLocalSourceEnabled);
    }

    AppLog.instance.log(
      '[ApiConfig] 从 Spider /config 更新了 ${newSources.length} 个线路，默认 homeSourceBean=${homeSourceBean.value?.key}',
    );
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
      throw ConfigError.parseError.message(
        '配置跳转层级过深（超过 $_maxConfigResolveDepth 层）',
      );
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
    } catch (e) {
      /* ignore */
    }

    // 尝试作为正常配置解析
    if (decoded != null) {
      // MoonTV / LunaTV 影视仓（`api_site`）→ 现场转成 TVBox `sites`
      final moon = MoonTvConverter.tryConvert(decoded);
      if (moon != null) {
        AppLog.instance.log(
          '[ApiConfig] MoonTV video.json 已转换：${moon.sites.length} 个源'
          '${moon.warnings.isEmpty ? "" : "（跳过 ${moon.warnings.length} 条）"}',
        );
        return (
          config: AppConfigData.fromJson(moon.toConfig()),
          loadedFrom: normalizedUrl,
        );
      }

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
          .where(
            (c) =>
                c.toLowerCase() != visitKey &&
                !nextVisited.contains(c.toLowerCase()),
          )
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
      throw ConfigError.parseError.message('配置缺少可用站点（sites）');
    }

    throw ConfigError.parseError.message('配置格式不受支持');
  }

  /// 读取配置文本并做短时缓存（LRU：访问会刷新 lastAccess）
  Future<String> _fetchConfigText(String normalizedUrl) async {
    // 本地转换配置（`local://<name>`）：直接读 Documents，不走网络
    if (ConvertedConfigStore.isLocal(normalizedUrl)) {
      final content = await ConvertedConfigStore.read(normalizedUrl);
      if (content == null || content.trim().isEmpty) {
        throw ConfigError.parseError.message('本地转换配置不存在: $normalizedUrl');
      }
      return content;
    }

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

    try {
      final content = await _network.getString(normalizedUrl);
      _rawConfigCache[key] = _RawConfigCacheEntry(
        content: content,
        fetchedAt: now,
      );
      _trimRawConfigCacheIfNeeded();
      // 拉到就落一份到本地磁盘（用户 2026-10-13：把源下到本地，切换更稳）。
      // ⚠️ **不 await**（用户 2026-10-14：「接口配置下载好慢」）：
      //   这份配置常见几 MB，`writeAsString(flush: true)` 会真去 fsync ——
      //   摆在加载路径上等于让用户白等一次磁盘同步（慢机/大配置下很明显）。
      //   它只是离线兜底缓存，这次没写完下次再拉即可。
      unawaited(_writeDiskCache(normalizedUrl, content));
      return content;
    } catch (e) {
      // 网络失败 → 回退本地磁盘缓存，切源/离线时不再「一片空白」
      final cached = await _readDiskCache(normalizedUrl);
      if (cached != null && cached.trim().isNotEmpty) {
        AppLog.instance.log('[ApiConfig] 拉取失败，改用本地缓存配置: $normalizedUrl');
        _rawConfigCache[key] = _RawConfigCacheEntry(
          content: cached,
          fetchedAt: now,
        );
        return cached;
      }
      rethrow;
    }
  }

  // ============================================================
  // 本地磁盘配置缓存（<Documents>/config_cache/<md5(url)>.json）
  // ------------------------------------------------------------
  // 解决「切换订阅/离线时拉不到配置 → 首页空白、像坏了一样」。
  // 与内存缓存（20s TTL）互补：内存只是短时去重，磁盘才是离线兜底。
  // ============================================================
  static const String _kConfigCacheDir = 'config_cache';

  static Future<Directory> _diskCacheDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/$_kConfigCacheDir');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static String _diskKey(String url) =>
      md5.convert(utf8.encode(url.toLowerCase().trim())).toString();

  static Future<void> _writeDiskCache(String url, String content) async {
    try {
      final d = await _diskCacheDir();
      await File(
        '${d.path}/${_diskKey(url)}.json',
      ).writeAsString(content, flush: true);
    } catch (e) {
      AppLog.instance.log('[ApiConfig] 写配置缓存失败: $e');
    }
  }

  static Future<String?> _readDiskCache(String url) async {
    try {
      final d = await _diskCacheDir();
      final f = File('${d.path}/${_diskKey(url)}.json');
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (e) {
      AppLog.instance.log('[ApiConfig] 读配置缓存失败: $e');
      return null;
    }
  }

  static void _trimRawConfigCacheIfNeeded() {
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

    // 顺手把 ads / rules 存下来（广告过滤直接用，省掉第二次整份下载）
    lastAds = config.ads ?? const [];
    lastRules = config.rules ?? const [];

    if (includeSources) {
      // 整包线路**是不是由 spider 决定**的（这决定后面对 homeSourceBean 的处置，
      // 以及要不要让 Node 的 /config 结果整表替换线路）。
      //
      // 🔴 2026-10-13 修（用户：「导入猫源还有 tvbox 源后导入 py 源，重启后订阅
      // 里面全空了，并且这些猫源还有 tvbox 源全部没有内容」）：
      // 上一版只看「点播接口地址本身是不是 .js/.jar」⇒ **CatVod / TVBox-jar 类
      // 配置全被误判成"聚合配置"**。那类配置的 `sites[]` 只是 `csp_xxx` 占位，
      // 真正的线路清单（名字/搜索口）是 spider 启动后由 `/config` 下发的
      // ⇒ 跳过整表替换 = 线路表全是空壳 → 看起来"订阅空了、全部没有内容"。
      //
      // 所以：**配置声明了非空 `spider` 字段** 也要走 spider 线路流程（恢复旧行为）。
      // 只有「既不是 js/jar 接口、也没声明 spider」的纯聚合配置（如 huahua.json）
      // 才走新路径：脚本源按需载入、不被 /config 整表替换冲掉。
      isSingleScriptSpider.value =
          _isSpiderSourceUrl(apiUrl) ||
          ((config.spider ?? '').trim().isNotEmpty);

      // 🔴 2026-10-14 修（洞 C：错误提示残留）：
      //   走到这里说明本次配置**解析成功**（站点已经拿到），要把上一条源留下的
      //   错误清掉。以前只有 spider `/config` 成功路径
      //   （updateSourceBeansFromSpiderConfig）里会清，于是
      //   「先加载一个坏 js 源（留下 error）→ 切到好的聚合/py 源」时，
      //   首页内容已经正常，却还一直挂着"加载失败"（用户 2026-10-14 实测）。
      apiConfigError.value = null;

      // 解析站点列表
      final sources = <SourceBean>[];
      if (config.sites != null) {
        for (final site in config.sites!) {
          sources.add(
            SourceBean(
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
            ),
          );
        }
      }
      // CatVod 类配置常常 `sites: []`（线路全部由 jar 自己下发）→ 这里先塞一个
      // 基于 spider 地址的**占位线路**，保证首页/源切换有默认源；
      // /config 返回后由 updateSourceBeansFromSpiderConfig 整表替换掉。
      //
      // 🔴 2026-10-14 修（用户：「没加 py 源之前是不是支持猫源和 tvbox？」）：
      //   原来是 `sources.isEmpty && ...` —— **只在站点列表为空时**才补这条占位。
      //   但 CatVod/tvbox 那类配置是 **`spider` 字段 + 非空 `sites[]`**（站点是
      //   数字 key / `csp_` 占位，真正的实现全在 spider 脚本里）：
      //     · sites 非空 ⇒ 不会补占位 ⇒ 列表里没有任何 js 源 bean
      //     · AppState 于是判定「无 js/jar spider 源」→ **直接跳过 Node 启动**
      //       （用户日志实证：`[ApiConfig] 单个 Spider 配置：先给兜底主页源 …`
      //        紧接着 `[AppState] 无 js/jar spider 源，跳过 Node 启动/加载流程`）
      //     ⇒ spider 脚本永远不加载、所有线路没内容（看起来像"订阅空了"）。
      //   现在改成：只要声明了 `spider`、且列表里**没有任何 js 源 bean**，就补一条。
      //   （已有 js 源时不重复补，避免多出一条假线路。）
      final hasJsBean = sources.any(
        (s) => s.isSpiderSource && !s.isPythonScriptSource,
      );
      if (isSingleScriptSpider.value &&
          (config.spider ?? '').trim().isNotEmpty &&
          !hasJsBean) {
        final ph = _createSpiderSourceConfig(config.spider!.trim());
        final ps = ph.sites?.firstOrNull;
        if (ps != null) {
          sources.add(
            SourceBean(
              key: ps.key ?? '',
              name: ps.name ?? 'Spider源',
              api: ps.api ?? '',
              searchable: ps.searchable?.value ?? 1,
              filterable: ps.filterable?.value ?? 1,
              quickSearch: ps.quickSearch?.value ?? 0,
              playerType: ps.playerType?.value ?? 0,
              type: ps.type?.value ?? 3,
              ext: ps.ext?.stringValue,
              indexs: ps.indexs?.value ?? 0,
            ),
          );
        }
      }
      // 同上：把用户导入的线路（py 源等）并回列表
      await _mergeUserVideoSources(sources);
      // 失效线路：移出的那些不再灌回来（与 /config 整表替换同一套过滤）
      await _ensureInvalidLoaded();
      _dropInvalidSources(sources);
      await _applyVideoSourceOrder(sources);
      _syncInvalidCount();
      sourceBeanList.value = sources;
      // 本地 Python 源单独一组：每次配置解析后重新读取（切订阅不丢）
      await reloadLocalVideoSources();

      // 直播 lives：交给 LiveService 解析（内嵌 channels 或 m3u URL）
      //
      // 用户 2026-10-13：「直播能不能从订阅获取，不要随源切换变化」。
      // ⇒ 只在**本地一条直播源都没有**时，才用当前订阅的 lives 首次导入；
      //   一旦本地已有直播源（user managed / 内存里已有），切点播源一律不动它。
      try {
        final lives = config.lives;
        if (lives != null && lives.isNotEmpty) {
          final localHas = LiveService.instance.sources.isNotEmpty;
          if (await LiveService.instance.livesUserManaged || localHas) {
            AppLog.instance.log('[ApiConfig] 本地已有直播源，跳过接口 lives 覆盖（不随源切换变化）');
          } else {
            final raw = lives
                .map(
                  (e) => {
                    'name': e.name,
                    'url': e.url,
                    'ua': e.ua,
                    'type': e.type?.value,
                    'channels': e.channels
                        ?.map(
                          (ch) => {
                            'name': ch.name,
                            'urls': ch.urls,
                            'group': ch.group,
                            'logo': ch.logo,
                          },
                        )
                        .toList(),
                  },
                )
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
      // 用户 2026-10-13：「TVBox 和 catvod 切换的时候，没有默认源」。
      // 之前单 Spider 配置**故意不设** homeSourceBean（等 /config 下发真实线路），
      // 一旦 /config 慢或失败（日志里就是 `sourceLoaded:false` + 500），首页就
      // 一直没有默认源。现在改为：**所有配置**都先落一个兜底主页源（用户选过的
      // 按订阅命中优先）；单 Spider 的线路清单随后由 /config 再校正一次。
      await _restoreHomeSource(sources);
      // 兜底条件必须包含「旧主页源不在新列表」：切换订阅后 homeSourceBean
      // 残留的是上一个订阅的 key（非 null），只判 null 不会重置 → 首页继续
      // 指向已不存在的源，表现为「切了订阅但首页还是旧源/空白」。
      final curKey = homeSourceBean.value?.key;
      final curInList =
          curKey != null &&
          (sources.any((s) => s.key == curKey) ||
              localVideoSources
                  .any((s) => s.key == curKey && isLocalSourceEnabled(s)));
      if (!curInList) {
        homeSourceBean.value = sources.firstOrNull;
      }
      if (isSingleScriptSpider.value) {
        AppLog.instance.log(
          '[ApiConfig] 单个 Spider 配置：先给兜底主页源 '
          '${homeSourceBean.value?.key}，/config 返回后再校正',
        );
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

      // ① 本地 Python / JS 源是「全局选择」：只要它还存在于本地目录，就永远优先，
      //    不因切换订阅 / 激活其他线路而改变。
      //    ⚠️ 仅在「本地爬虫」开关打开时生效（用户 2026-10-18：优先订阅激活的源）；
      //    本地 JS 源还要看 JS 子开关。
      final localKey = prefs.getString(_kLocalHomeApi);
      if (localKey != null && localKey.isNotEmpty) {
        final local = localVideoSources
            .where((s) => s.key == localKey && isLocalSourceEnabled(s))
            .firstOrNull;
        if (local != null) {
          homeSourceBean.value = local;
          return;
        }
      }

      String? saved;
      // 先按当前订阅（配置地址）取 —— 每个订阅各记各的主页源
      final scope = _homeScopeKey;
      if (scope.isNotEmpty) {
        final raw = prefs.getString(_kHomeApiMap);
        if (raw != null && raw.isNotEmpty) {
          final map = jsonDecode(raw);
          if (map is Map) saved = map[scope]?.toString();
        }
      }
      // 再退回旧的全局键
      saved ??= prefs.getString(AppConstants.homeApi);
      if (saved != null) {
        final found = sources.where((s) => s.key == saved).firstOrNull;
        if (found != null) {
          homeSourceBean.value = found;
          return;
        }
        // 本地 Python / JS 源不在订阅线路表里，单独找一次（对应开关打开时才认）
        final local = localVideoSources
            .where((s) => s.key == saved && isLocalSourceEnabled(s))
            .firstOrNull;
        if (local != null) {
          homeSourceBean.value = local;
          return;
        }
      }
    } catch (e) {
      /* ignore */
    }
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

    var rawUrl =
        'https://raw.githubusercontent.com/$owner/$repo/$branch/$filePath';
    if (uri.hasQuery) rawUrl += '?${uri.query}';
    if (uri.hasFragment) rawUrl += '#${uri.fragment}';
    return rawUrl;
  }

  static bool _isSpiderSourceUrl(String url) {
    final lower = url.toLowerCase();
    // 检查路径后缀（.py 也是单脚本源：直接填 py 地址作为点播接口时，
    // 必须在这里被识别为脚本源，否则会被当成 JSON 配置去拉取，解析失败，
    // homeSourceBean 停在旧站点不动 —— 表现为「切了 py 源但首页还是旧猫源」）
    final path = Uri.tryParse(lower)?.path ?? lower;
    return path.endsWith('.js') ||
        path.endsWith('.js.md5') ||
        path.endsWith('.jar') ||
        path.endsWith('.jar.md5') ||
        path.endsWith('.py') ||
        path.endsWith('.py.md5');
  }

  static AppConfigData _createSpiderSourceConfig(String rawUrl) {
    // 🔴 2026-10-14 修（TVBox 的 `;md5;<hash>` 语法）：
    //   配置里的 spider 常见写成 `https://host/Omnibox.jar;md5;cc3b3d…` ——
    //   分号后面是**校验和**，不是 URL 的一部分。直接拿整串去下载只会拿到一个
    //   2KB 的错误页（实测：干净地址 5,489,871 字节，带后缀只有 2,020 字节）。
    //   ⇒ 只取第一个分号前的真实地址；key / 名字的派生也顺带干净了
    //   （否则 key 会变成 `Omnibox;md5;cc3b…` 这种带分号的非法值）。
    final url = rawUrl.split(';').first.trim();
    final uri = Uri.tryParse(url);
    final pathSegments = uri?.pathSegments ?? [];

    String key;
    if (uri != null && uri.host.isNotEmpty && pathSegments.isNotEmpty) {
      final fileName = pathSegments.last
          .replaceAll('.js.md5', '')
          .replaceAll('.js', '')
          .replaceAll('.jar.md5', '')
          .replaceAll('.jar', '')
          .replaceAll('.py.md5', '')
          .replaceAll('.py', '');
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
      if (!inString &&
          c == '/' &&
          i + 1 < chars.length &&
          chars[i + 1] == '/') {
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
      _matchCaptureGroup(
        r'data-clipboard-text\s*=\s*["\x27]([^"\x27]+)["\x27]',
        content,
      ),
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
    return regex
        .allMatches(content)
        .map((m) => m.group(1) ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static String _sanitizeExtractedUrl(String value) {
    var result = value.trim();
    result = result.replaceAll('&amp;', '&');
    result = result.replaceAll('\\/', '/');

    // 移除尾部标点
    while (result.isNotEmpty &&
        [
          '.',
          ',',
          ';',
          ')',
          ']',
          '}',
          '"',
          "'",
        ].contains(result[result.length - 1])) {
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
