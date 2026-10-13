import 'dart:async';

import 'package:flutter/material.dart';
import 'common/theme.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'miniapp/services/mini_app_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'common/constants.dart';
import 'models/cache_store.dart';
import 'models/subscription.dart';
import 'services/api_config.dart';
import 'services/nav_feature_service.dart';
import 'services/app_log.dart';
import 'services/app_state.dart';
import 'services/background_service.dart';
import 'services/epg_service.dart';
import 'services/live_service.dart';
import 'reading/services/book_download_service.dart';
import 'reading/services/book_font_service.dart';
import 'reading/services/settings_service.dart';
import 'reading/services/reader_override_service.dart';
import 'reading/services/bookshelf_service.dart';
import 'reading/services/book_reading_progress_service.dart';
import 'reading/services/zlibrary_service.dart';
import 'reading/services/remote_config_service.dart';
import 'reading/models/book_source.dart';
import 'reading/services/tts_service.dart';
import 'music/services/now_playing_service.dart';
import 'music/services/settings_store.dart';
import 'music/services/player_manager.dart';
import 'music/services/download_service.dart';
import 'common/module_theme_store.dart';
import 'common/module_theme_sync.dart';
import 'common/theme_mode_store.dart';
import 'music/theme/music_theme.dart';
import 'reading/services/book_favorites_service.dart';
import 'reading/services/favorites_service.dart';
import 'reading/services/browse_history_service.dart';
import 'reading/services/download_service.dart';
import 'reading/services/reading_progress_service.dart';
import 'reading/services/trim_preset_service.dart';
import 'reading/services/view_mode.dart';
import 'reading/services/book_view_mode.dart';
import 'reading/services/reading_layout.dart';
import 'reading/source/source_manager.dart';
import 'services/player_prefs.dart';
import 'services/tmdb_service.dart';
import 'pages/search/controller.dart';
import 'music/services/library_store.dart';
import 'widgets/app_toast.dart';
import 'widgets/video_player_pip.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化 AppLog — 必须早于 runApp, 否则 handleSceneActive 等
  // 关键事件写不进 <Documents>/nodejs-project/runtime/app.log
  await AppLog.instance.init();

  // ✅ **把 `debugPrint` 重定向进「软件日志」**（我的 → 通用设置 → 软件日志 ✓）——
  //   为什么需要这一行 ✓：全项目（含阅读模块 **34 个文件的 `_log()`**）此前只用
  //   `if (kDebugMode) debugPrint(...)` ✗ → **发布版一个字都不落盘** ✗，
  //   于是日志页永远显示"（暂无日志）"✗ —— 用户遇到"下载/换源/书源失败"时**看不到原因** ✗✗。
  //   这一行之后：所有既有 `_log()` **自动入日志** ✓✓（无需改动任何业务文件 ✓）。
  //   ⚠️ 不会递归 ✓：`AppLog` 内部用的是 `print`（`app_log.dart:195` ✓），不是 `debugPrint` ✓。
  //   ⚠️ 重复风险 ✓：已手工桥接过 `AppLog` 的文件（download_service / book_download_service）
  //      会各多写一行 ✓ —— 无害 ✓（日志里同一事件两行 ✓）。
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) AppLog.instance.log(message);
  };

  // 初始化 media_kit（备用 MPV 内核；AVPlayer 为主时也需 init，设置里可切换）
  MediaKit.ensureInitialized();

  // 初始化 Hive 数据目录
  final appDir = await getApplicationDocumentsDirectory();
  Hive.init(appDir.path);

  // 播放内核与选项
  // #10：字号缩放是外观设置，由 AppTheme 负责加载（PlayerPrefs 是兼容壳）
    await AppTheme.loadFontScale();
    await PlayerPrefs.instance.load();



  // 注册 ApiConfig 为 GetxController - 对应 Swift ApiConfig.shared
  Get.put<ApiConfig>(ApiConfig());

  // 注册 AppState 为 GetxController - 对应 Swift @StateObject private var appState = AppState()
  Get.put<AppState>(AppState());

  // 注册 BackgroundService 为永久实例 - 负责全应用背景渐变/自定义图片
  // 必须在 runApp 之前 await onInit() 完成,确保首帧就用已保存的背景
  await Get.putAsync<BackgroundService>(() async {
    final svc = BackgroundService();
    svc.onInit(); // sync 触发 _loadFromPrefs,后台异步读 SharedPreferences
    return svc;
  }, permanent: true);

  // 注册 TvSearchController 为永久实例 - 避免在 SearchPage 中 Get.put 创建新实例替换
  Get.put<TvSearchController>(TvSearchController(), permanent: true);

  // 阅读模块 —— 完整移植 cmbok_app
  //
  // 这里的初始化顺序**严格对齐 cmbok 的 main()**：
  // 书架/收藏/历史/进度之间会在 init 里互相查询（例如书架要为已下载的书
  // 回填收藏角标），顺序错了会出现"首次启动状态丢失"。改动前先看 cmbok。
  //
  await SettingsService().init();
  await ReaderOverrideService().init();
  await BookFontService().init();
  // 🔴 这里原来是**裸调用** `await SourceManager().init()` ✗ —— 它的内部
  // （加载 sources.json / 逐条实例化源 / 恢复当前源）任何一处抛异常都会
  // 一路冒到 main()，**启动即崩** ✗（用户看到的是"打开就闪退"，
  // 而根因只是某一条源数据坏了）。
  // → 现在 try/catch 兜住：初始化失败**只记日志**（debugPrint + AppLog 落盘）✓，
  //   然后**继续往下启动** ✓ —— 影视/直播/音乐等其它模块不受影响，
  //   漫画源退化为零源（SourceManager.current 有 _NoSource 哨兵兜底，UI 不崩 ✓）。
  try {
    await SourceManager().init();
  } catch (e) {
    debugPrint('[SourceManager] 初始化失败（已隔离，继续启动）: $e');
    AppLog.instance.log('[SourceManager] 初始化失败（已隔离，继续启动）: $e');
  }
  await ViewMode().init();
  await BookViewMode().init();
  // 阅读模块宫格列数（3/4/5）+ 书源页视图模式（用户 2026-10-07）
  await ReadingLayout().init();
  await SourceViewMode().init();
  await FavoritesService().init();
  await BookFavoritesService().init();
  await BrowseHistoryService().init();
  await BookshelfService().init();
  await DownloadService().init();
  await TrimPresetService().init();
  await ReadingProgressService().init();
  await BookReadingProgressService().init();
  // 小说书源（Legado 格式）：导入 / 管理在「阅读 → 我的 → 书源仓库」
  await BookSourceStore.instance.init();
  await BookDownloadService().init();
  // Z-Library 图书服务：RemoteConfigService 后台拉取云端域名配置，
  // ZlibraryService 初始化后并发探测选最优节点（不阻塞启动）。
  // 之前因"项目不做账号"而跳过初始化，但实际上内置账号 + 搜索/下载
  // 功能都依赖这两个服务，现恢复。
  await RemoteConfigService().init();
  await ZlibraryService().init();
  // 听书：走原生 tts_engine channel（系统 AVSpeechSynthesizer，零插件）
  Get.put<TtsService>(TtsService(), permanent: true);

  // 音乐模块 —— 按 Beans-Music 的结构重建（与影视侧完全独立）
  //
  //   · MusicPlayerManager  播放核心（media_kit，复用已有依赖，零新增插件）
  //   · SettingsStore       音质 / 音源开关等偏好
  //   · MusicThemeStore     明暗 + 9 种强调色（音乐模块自己的主题体系）
  //   · MusicPlayerSkin     封面形态 / 背景氛围
  //
  // 顺序：SettingsStore.init 里连带初始化 ThirdPartySourceStore（音源列表），
  // 所以它要排在主题之前，保证首帧就有正确的强调色与音源数据。
  await SettingsStore.instance.init();
  await MusicThemeStore.instance.init();

  // ── 锁屏 / 控制中心 / 耳机按键 的媒体控制（用户 2026 要求）──────────
  //
  // 原生侧在 `ios/Runner/MusicNowPlaying.swift`（由 AppDelegate 注册），
  // 这里只是**开始跟随播放器**：换歌/播放态变化时把元数据推给系统，
  // 并接收系统的播放/暂停/上下首/拖动。
  //
  // ⚠️ 必须在音乐初始化之后调 —— 它会立刻同步一次当前状态。
  // ⚠️ 桌面/单测环境没有原生侧，它会静默忽略（见 `_invoke` 的
  //    `MissingPluginException` 处理），不会崩。
  NowPlayingService.instance.start();

  // ── 统一主题（影视/直播/音乐/阅读 分模块配色）─────────────────
  // 顺序要求：必须在 SettingsService().init() 之后 ——
  // 因为要读它当前的阅读主题 id 来解析"跟随阅读"。
  await ModuleThemeStore.instance.init();
  ModuleThemeStore.instance.syncReadingPreset(SettingsService().themePreset);
  // 音乐模块的强调色由统一主题驱动：注册桥接（写在音乐侧，避免反向依赖）
  MusicThemeBridge.register((primary) {
    MusicTheme.setCustomAccent(primary);
  });
  // 配色变化 → 通知音乐 UI 重建。
  // MusicTheme 的颜色是静态 getter，不通知的话没有任何 widget 会重建
  //（`MusicThemeStore.notifyPaletteChanged` 原来在全仓无人调用）。
  MusicThemeBridge.registerNotify(
      () => MusicThemeStore.instance.notifyPaletteChanged());
  // 立刻落地一次，让影视/直播/音乐一启动就是用户选的方案
  await applyModuleThemes();
  // （音乐明暗桥 `MusicBrightnessBridge` 已删除：明暗不再由模块反向决定全局，
  //   模块的开关改为经 `GlobalThemeSync` 写回 `ThemeModeStore`。
  //   详见 `common/appearance_sync.dart` 顶部说明。）
  // 音乐调色板桥：音乐模块要读"用户在统一主题页给它选的方案"
  MusicPaletteBridge.register(
      () => ModuleThemeStore.instance.paletteFor(ModuleThemeStore.music));

  // ── 全局主题明暗同步（三模块统一开关，以全局 prefs 为基准）────────────
  //
  // 注册双向同步回调：
  //   · 全局 ThemeModeStore 变了 → 推给音乐和阅读
  //   · 音乐 / 阅读自己的开关被用户拨动 → 回写 ThemeModeStore（已在模块侧实现）
  GlobalThemeSync.registerMusic((mode) {
    MusicThemeStore.instance.applyFromGlobal(mode);
  });
  GlobalThemeSync.registerReading((mode) {
    SettingsService().applyThemeModeFromGlobal(mode);
  });
  // 启动：从 prefs 加载全局主题模式（含 'system'，不再被覆盖丢失），
  // 然后以全局为基准把音乐 / 阅读 / 壁纸那一套拉齐。
  await ThemeModeStore.load();
  final globalMode = ThemeModeStore.mode;
  GlobalThemeSync.pushToModules(globalMode);
  // ⚠️ 这里原来还会 `await BackgroundService.setAppearanceMode(...)`，
  // 把明暗**再写给壁纸服务一份** —— 那正是"第二套外观状态"的来源：
  // 壁纸层会拿这份可能过期的快照去选场景。已彻底删除。
  // 现在壁纸只读 `AppBrightness`
  //（见 `BackgroundService.isLight` / `currentSceneKey`）。

  // ── 随机图源：启动时取一张（每次冷启动背景都不一样）─────────────
  //
  // ⚠️ 必须**不 await**（fire-and-forget）：
  // 这些随机图 API 实测有 1.4~5.5s 延迟，有的（zylearning）还会先失败再重试。
  // 阻塞启动会让白屏明显变长。取到之后 `_sceneVersion` 自增，
  // 背景层会自动换成新图（那之前先显示上一张/渐变，不会空）。
  unawaited(BackgroundService.instance.warmUpRandomImageIfNeeded());

  // 外观协调 `AppearanceSync.start()` 已移到 `TVBoxApp.initState`。
  // 原因：它需要 `MainTabController` 已注册，而那个注册发生在
  // `TVBoxApp.build` 里；在 main() 里调用只会撞上守卫直接 return
  // —— 阅读侧的明暗监听从未注册过（真实 bug，不是重构）。
  await MusicPlayerSkin.instance.init();
  // #4/#5：音乐库（最近播放 + 收藏）—— 要在 PlayerManager 之前
    // 准备好，否则第一首播放时 addRecent 还在 init 中
    await MusicLibraryStore.instance.init();
    // 🔴 下载清单**必须在 PlayerManager 之前**初始化：
    // `player_manager` 的"本地优先播放"是**同步**读 `bySong()`，
    // 清单还没加载 → 已下载的歌被当成没下载 → 走去网络解析
    //（离线直接播不了；等于"下载了也白下"）。
    await MusicDownloadService.instance.init();
    await MusicPlayerManager.instance.init();

  // 首页导航栏功能开关与顺序（设置 → 主页页面）
  await NavFeatureService.instance.load();

  // 「程序」模块：重启后把已装程序的 CMS 影视源重新注册进视频源列表
  // （这样不进程序页也能在搜索/首页搜到这些源）
  await MiniAppService.instance.ensureLoaded();

  // 多订阅管理（订阅列表 / 激活切换 / 上锁）
  // 必须在 ApiConfig 首次加载前就绪：启动时要按"已激活的订阅"决定加载哪个地址。
  final subSvc = SubscriptionService.instance;
  await subSvc.load();

  // 直播源服务（解析 lives / m3u）
  Get.put<LiveService>(LiveService(), permanent: true);
  Get.put<EpgService>(EpgService(), permanent: true);

  // TMDB 智能刮削
  Get.put<TmdbService>(TmdbService(), permanent: true);
  await TmdbService.instance.loadPrefs();

  // 初始化窗口管理器（桌面端）- 对应 Swift .defaultSize(width: 1200, height: 800)
  try {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1200, 800),
      minimumSize: Size(800, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
      title: '猫影',
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  } catch (_) {
    // 非桌面平台忽略
  }

  // 初始化缓存
  await CacheStore.instance.init();

  // 启动时按「已激活的订阅」校正接口地址：
  // 用户上次可能切过订阅，而 AppConstants.apiUrl 里存的是当时写入的值。
  // 两边不一致时以订阅为准（订阅是"地址簿"，是唯一事实来源）。
  try {
    final active = subSvc.active;
    if (active != null && active.url.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(AppConstants.apiUrl) ?? '';
      if (saved != active.url) {
        await ApiConfig.persistApiUrl(active.url);
        AppLog.instance.log('[Subscription] 启动校正接口地址 → ${active.name}');
      }
    }
  } catch (e) {
    AppLog.instance.log('[Subscription] 启动校正失败: $e');
  }

  // 接口地址的**文件备份** + 首帧同步值 + 配置预取（原因见下）
  //
  //  ① 文件备份：老装机首次升级时补上（之后由 ApiConfig.persistApiUrl 维护）。
  //     prefs 被写坏时它就是兜底，避免"重启回第一页要重新填源"。
  //  ② startupSavedApiUrl：ContentView 首帧要用它判断"用户有没有配置" ——
  //     prefs 只有异步 API，不提前给就会先渲染一帧「填入订阅」页（"闪一哈"）。
  //  ③ 配置预取：ContentView 要等第一帧之后才发起这次网络请求，而 ApiConfig
  //     有 20s 的原始配置缓存 ⇒ 这里先 fire-and-forget 拉一遍，等它真正解析时
  //     直接命中缓存，少等一次完整网络往返（用户反馈"启动要好久"）。
  try {
    final prefs = await SharedPreferences.getInstance();
    final cur = prefs.getString(AppConstants.apiUrl) ?? '';
    if (cur.isNotEmpty) {
      await ApiConfig.persistApiUrl(cur);
      AppState.startupSavedApiUrl = cur;
      unawaited(ApiConfig.prefetchConfig(cur));
    }
  } catch (e) {
    AppLog.instance.log('[ApiConfig] 接口地址备份/预取初始化失败: $e');
  }

  // 「随启动自动同步」：只对勾了自动更新的订阅生效。
  //
  // **故意不 await** —— 同步要走网络（可能好几秒），绝不能卡住启动画面。
  // 内部自带节流（6 小时）与内容指纹比对，重复启动不会反复拉。
  unawaited(subSvc.autoSyncOnLaunch());

  // 🔴 注入 AppToast 的 navigatorKey —— 这一步以前**从来没有被调用过**！
  //
  // `AppToast.show()` 内部是：
  //     final overlay = _key?.currentState?.overlay;
  //     if (overlay == null) return;      // ← _key 一直是 null，直接 return
  // 所以阅读模块所有 AppToast 提示（下载完成、保存失败等）
  // **一条都没有显示过**，而且是完全静默的 —— 不报错、不提示，
  // 排查时会以为是"业务逻辑没走到"。
  //
  // 用 App 已有的 `VideoPlayerPip.navigatorKey`（就是 GetMaterialApp 的
  // navigatorKey），这样气泡挂在 root Overlay 上，浮在所有路由之上。
  AppToast.init(VideoPlayerPip.navigatorKey);

  runApp(const TVBoxApp());
}
