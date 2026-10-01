import 'package:get/get.dart';
import '../../services/app_log.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/player_engine.dart';
import '../../services/player_prefs.dart';
import '../../services/api_config.dart';
import '../../services/app_state.dart';
import '../../services/nodejs_manager.dart';
import '../../common/constants.dart';
import '../../models/cache_store.dart';
import '../../services/cache_manager_service.dart';

enum PendingMultiRepoTarget { vod }

class PendingMultiRepoSelection {
  final String id;
  final PendingMultiRepoTarget target;
  final String sourceUrl;
  final List<MultiRepoOption> options;

  PendingMultiRepoSelection({
    required this.id,
    required this.target,
    required this.sourceUrl,
    required this.options,
  });
}

class SettingsController extends GetxController {
  final vodApiUrl = ''.obs;
  final isLoadingConfig = false.obs;
  final configError = Rx<String?>(null);
  final configSuccess = false.obs;
  final pendingMultiRepoSelection = Rx<PendingMultiRepoSelection?>(null);
  final apiHistory = <String>[].obs;
  final vodPlayerEngine = PlayerEngine.avplayer.obs;
  final decodeMode = VideoDecodeMode.auto.obs;
  final vlcBufferMode = VLCBufferMode.balanced.obs;
  final playTimeStep = 10.obs;
  final cacheSizeString = '0 KB'.obs;

  bool _nodeJSStarted = false;

  final playTimeStepOptions = [5, 10, 15, 30, 60];
  List<PlayerEngine> get playerEngineOptions => PlayerEngine.availableEngines;
  List<VideoDecodeMode> get decodeModeOptions => VideoDecodeMode.values;
  List<VLCBufferMode> get vlcBufferModeOptions => VLCBufferMode.values;

  @override
  void onInit() {
    super.onInit();
    _initSettings();
  }

  Future<void> _initSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedVod = prefs.getString(AppConstants.apiUrl) ?? '';
    vodApiUrl.value = savedVod;

    await _loadApiHistory();

    // 兼容老版本单一播放器字段到新字段
    final hasLegacyPlayer = prefs.containsKey(AppConstants.playType);
    final legacyPlayerRaw = prefs.getInt(AppConstants.playType) ?? 0;
    // 默认内核必须与 PlayerPrefs.load() 的兜底一致（avplayer），
    // 否则全新安装会被写成 mpv → OS 上 isSharedIosAv=false → 小窗不可用。
    final defaultRaw = PlayerEngine.avplayer.value;

    if (!prefs.containsKey(AppConstants.playTypeVod)) {
      await prefs.setInt(
        AppConstants.playTypeVod,
        hasLegacyPlayer ? legacyPlayerRaw : defaultRaw,
      );
    }

    // 播放内核/选项统一走 PlayerPrefs（详情页实时监听）
    await PlayerPrefs.instance.load();
    vodPlayerEngine.value = PlayerPrefs.instance.vodEngine.value;
    decodeMode.value = PlayerPrefs.instance.decodeMode.value;
    vlcBufferMode.value = PlayerPrefs.instance.bufferMode.value;

    final savedStep = prefs.getInt('play_time_step') ?? 0;
    playTimeStep.value = savedStep > 0 ? savedStep : 10;

    refreshCacheSize();
  }

  Future<void> loadConfig() async {
    final trimmedVod = vodApiUrl.value.trim();

    if (trimmedVod.isEmpty) {
      configError.value = '请输入点播接口地址';
      return;
    }

    isLoadingConfig.value = true;
    configError.value = null;
    configSuccess.value = false;
    pendingMultiRepoSelection.value = null;

    try {
      // 若探测到多仓库入口，先中断加载并弹出候选
      final pending = await _detectPendingMultiRepoSelection(
        vodUrl: trimmedVod,
      );
      if (pending != null) {
        pendingMultiRepoSelection.value = pending;
        isLoadingConfig.value = false;
        return;
      }

      await ApiConfig.instance.loadConfigs(vodApiUrl: trimmedVod);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.apiUrl, trimmedVod);
      vodApiUrl.value = trimmedVod;
      await addToApiHistory(trimmedVod);
      configSuccess.value = true;

      // 对应 Swift: ensureNodeJSAndLoadSource()
      // 配置加载成功后启动 Node.js 并获取 Spider 配置
      try {
        final appState = Get.find<AppState>();
        await appState.ensureNodeJSAndLoadSource();
        appState.applyLoadedConfigState();
      } catch (e) {
        /* ignore */
      }
    } catch (e) {
      configError.value = e.toString();
    }

    isLoadingConfig.value = false;
  }

  Future<void> selectPendingMultiRepoOption(MultiRepoOption option) async {
    final pending = pendingMultiRepoSelection.value;
    if (pending == null) return;

    final normalizedSource = ApiConfig.normalizeConfigUrl(pending.sourceUrl);

    switch (pending.target) {
      case PendingMultiRepoTarget.vod:
        vodApiUrl.value = option.url;
        break;
    }

    pendingMultiRepoSelection.value = null;
    await loadConfig();
  }

  void cancelPendingMultiRepoSelection() {
    pendingMultiRepoSelection.value = null;
    isLoadingConfig.value = false;
  }

  Future<PendingMultiRepoSelection?> _detectPendingMultiRepoSelection({
    required String vodUrl,
  }) async {
    final vodOptions = await ApiConfig.instance.fetchMultiRepoOptions(vodUrl);
    if (vodOptions != null) {
      if (vodOptions.isEmpty) {
        throw Exception('点播多仓库配置中没有可用地址');
      }
      return PendingMultiRepoSelection(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        target: PendingMultiRepoTarget.vod,
        sourceUrl: vodUrl,
        options: vodOptions,
      );
    }

    return null;
  }

  Future<void> _loadApiHistory() async {
    final prefs = await SharedPreferences.getInstance();
    apiHistory.value = prefs.getStringList('api_history') ?? [];
  }

  Future<void> addToApiHistory(String url) async {
    apiHistory.remove(url);
    apiHistory.insert(0, url);
    if (apiHistory.length > 10) {
      apiHistory.removeRange(10, apiHistory.length);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('api_history', apiHistory.toList());
  }

  Future<void> removeApiHistory(String url) async {
    apiHistory.remove(url);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('api_history', apiHistory.toList());
  }

  /// 实际清除 Flutter 端所有缓存（图片 / HTTP 磁盘 / temp / app cache 目录）
  ///
  /// 涉及到的缓存：
  /// - `PaintingBinding.instance.imageCache` —— Flutter 内存图片缓存
  /// 清除缓存 —— **委托给 [CacheManagerService]**（单一来源）。
  ///
  /// ── 为什么改成委托（C 类重复的第 1 处）────────────────────────
  /// 原来这里自己清了 5 样东西（内存图片 / DefaultCacheManager /
  /// getTemporaryDirectory / getApplicationCacheDirectory / Hive cache_items），
  /// 而**新建的 `CacheManagerService` 又清了一遍类似的东西** ——
  /// 两份清单迟早会走偏（事实上就偏了：以前两者都**没覆盖**音乐和阅读的缓存）。
  ///
  /// 现在"量什么、清什么"只在 `CacheManagerService` 一处定义，
  /// 这里只是把它全清 + 给用户反馈。
  Future<void> clearCache() async {
    final all = await CacheManagerService.instance.list();
    await CacheManagerService.clearAll(all);
    AppLog.instance.log('[Settings] clearCache: 已清 ${all.length} 类缓存');
    Get.snackbar(
      '清除缓存',
      '已清空图片 / 临时文件 / 页面缓存 / 音乐与阅读缓存',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
    await refreshCacheSize();
  }

  /// 只清「页面数据缓存」（首页列表 / 分类 / 清晰度 / TMDB 刮削结果）。
  ///
  /// 不动图片缓存与临时文件 —— 用户遇到「首页列表不更新 / 详情信息是旧的」
  /// 时用它精准刷新，代价比「全部清除」小得多（图片不用重新下载）。
  Future<void> clearBusinessCache() async {
    try {
      await CacheStore.instance.clearItemsCache();
      Get.snackbar(
        '刷新页面缓存',
        '首页列表 / 详情 / 刮削结果已清空，重新进入即可获取最新',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      AppLog.instance.log('=== clearBusinessCache failed: $e ===');
    }
    await refreshCacheSize();
  }

  /// 清理源文件缓存（删除 Documents 下已下载的源 JS），不清图片等
  Future<void> clearSourceCache() async {
    try {
      final ok = await NodeJSManager.instance.deleteSource();
      Get.snackbar(
        '源文件缓存',
        ok ? '已删除本地源文件' : '源文件清理失败或本无源文件',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      Get.snackbar(
        '源文件缓存',
        '清理失败：$e',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    }
    await refreshCacheSize();
  }

  /// 重置配置：清除已保存的源 URL + 历史记录 + 下载的源缓存
  /// 下次启动 App 会回到 setupView（输入源 URL 的初始页面）
  /// 不会清播放器设置 / 主题 / 字体大小等本地化设置
  Future<bool> resetConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConstants.apiUrl);
    await prefs.remove(AppConstants.homeApi);
    await prefs.remove('api_history');

    // 清内存中的状态
    vodApiUrl.value = '';
    apiHistory.clear();

    // 删下载的源缓存（<Documents>/nodejs/source/）
    // 下次进 setupView 输入新 URL 时会重新下载
    try {
      await NodeJSManager.instance.deleteSource();
    } catch (e) {
      /* ignore */
    }

    return true;
  }

  Future<void> setPlayTimeStep(int step) async {
    if (step <= 0) return;
    playTimeStep.value = step;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('play_time_step', step);
  }

  Future<void> setVodPlayerEngine(PlayerEngine engine) async {
    if (!playerEngineOptions.contains(engine)) return;
    vodPlayerEngine.value = engine;
    await PlayerPrefs.instance.setEngine(engine);
  }

  Future<void> setDecodeMode(VideoDecodeMode mode) async {
    if (!decodeModeOptions.contains(mode)) return;
    decodeMode.value = mode;
    await PlayerPrefs.instance.setDecodeMode(mode);
  }

  Future<void> setVLCBufferMode(VLCBufferMode mode) async {
    if (!vlcBufferModeOptions.contains(mode)) return;
    vlcBufferMode.value = mode;
    await PlayerPrefs.instance.setBufferMode(mode);
  }

  /// 重新计算并刷新"缓存大小"显示
  ///
  /// 实际意义 = imageCache 内存估算 + temp 目录 + app cache 目录
  /// （cached_network_image_ce 的磁盘缓存在 app cache 下面的
  /// `libCachedImageData/` 子目录，递归算 app cache 时已包含）
  /// 按设置周期自动清缓存（启动设置页时调用）
  Future<void> runAutoCacheCleanIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mode =
          prefs.getInt('source_cache_auto_clean') ??
          0; // 0 off 1 day 2 week 3 month
      if (mode == 0) return;
      final last = DateTime.fromMillisecondsSinceEpoch(
        prefs.getInt('cache_last_clean') ?? 0,
      );
      final now = DateTime.now();
      final days = switch (mode) {
        1 => 1,
        2 => 7,
        3 => 30,
        _ => 0,
      };
      if (days == 0) return;
      if (now.difference(last).inDays < days) return;
      // 清图片缓存与临时文件 —— **同样走 CacheManagerService**（C 类重复的第 4 处）
      //
      // 原来这里自己清了一遍内存图片 + 临时目录，与 `clearCache()`、
      // `DataCleanupPage` 的清单各写一份。现在统一按 entry id 清。
      final entries = await CacheManagerService.instance.list();
      for (final e in entries) {
        if (e.id == 'app_image_memory' || e.id == 'app_temp') {
          try {
            await e.clear();
          } catch (_) {
            /* 单项失败不影响自动清理 */
          }
        }
      }
      await prefs.setInt('cache_last_clean', now.millisecondsSinceEpoch);
      AppLog.instance.log('[Settings] auto cache clean mode=$mode');
    } catch (e) {
      AppLog.instance.log('[Settings] auto cache clean fail: $e');
    }
  }

  /// 刷新"缓存总大小"显示 —— **委托给 [CacheManagerService]**（单一来源）。
  ///
  /// 原来这里自己算 4 项（内存图片 / 临时目录 / 应用缓存目录 / Hive 业务缓存），
  /// 与 `CacheManagerService` 的口径各写一份；现在统一由后者计算，
  /// 于是"显示的大小"和"清掉的东西"必然是同一套范围。
  /// （顺带把音乐/阅读的缓存也计入了 —— 以前它们的占用是"隐形"的。）
  Future<void> refreshCacheSize() async {
    try {
      final total = await CacheManagerService.totalSize();
      cacheSizeString.value = CacheManagerService.formatSize(total);
    } catch (e) {
      AppLog.instance.log('=== refreshCacheSize failed: $e ===');
    }
  }
}
