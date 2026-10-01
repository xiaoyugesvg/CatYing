import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
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
import 'reading/services/tts_service.dart';
import 'music/services/settings_store.dart';
import 'music/services/player_manager.dart';
import 'music/theme/music_theme.dart';
import 'reading/services/book_favorites_service.dart';
import 'reading/services/favorites_service.dart';
import 'reading/services/browse_history_service.dart';
import 'reading/services/download_service.dart';
import 'reading/services/reading_progress_service.dart';
import 'reading/services/trim_preset_service.dart';
import 'reading/services/view_mode.dart';
import 'reading/services/book_view_mode.dart';
import 'reading/source/source_manager.dart';
import 'services/player_prefs.dart';
import 'services/rfw_theme_service.dart';
import 'services/tmdb_service.dart';
import 'pages/search/controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化 AppLog — 必须早于 runApp, 否则 handleSceneActive 等
  // 关键事件写不进 <Documents>/nodejs-project/runtime/app.log
  await AppLog.instance.init();

  // 初始化 media_kit（备用 MPV 内核；AVPlayer 为主时也需 init，设置里可切换）
  MediaKit.ensureInitialized();

  // 初始化 Hive 数据目录
  final appDir = await getApplicationDocumentsDirectory();
  Hive.init(appDir.path);

  // 播放内核与选项
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
  // 注意：RemoteConfigService / ZlibraryService 依赖服务端配置与账号，
  // 本项目不做账号，这两项**故意不初始化**（对应页面也不会被导航到）。
  await SettingsService().init();
  await ReaderOverrideService().init();
  await BookFontService().init();
  await SourceManager().init();
  await ViewMode().init();
  await BookViewMode().init();
  await FavoritesService().init();
  await BookFavoritesService().init();
  await BrowseHistoryService().init();
  await BookshelfService().init();
  await DownloadService().init();
  await TrimPresetService().init();
  await ReadingProgressService().init();
  await BookReadingProgressService().init();
  await BookDownloadService().init();
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
  await MusicPlayerSkin.instance.init();
  await MusicPlayerManager.instance.init();

  // 首页导航栏功能开关与顺序（设置 → 主页页面）
  await NavFeatureService.instance.load();

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

  // RFW 自定义首页主题引擎（.rfwtxt 主题文件管理 + 解析）
  Get.put<RfwThemeService>(RfwThemeService.instance, permanent: true);
  await RfwThemeService.instance.init();

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
        await prefs.setString(AppConstants.apiUrl, active.url);
        AppLog.instance.log('[Subscription] 启动校正接口地址 → ${active.name}');
      }
    }
  } catch (e) {
    AppLog.instance.log('[Subscription] 启动校正失败: $e');
  }

  // 「随启动自动同步」：只对勾了自动更新的订阅生效。
  //
  // **故意不 await** —— 同步要走网络（可能好几秒），绝不能卡住启动画面。
  // 内部自带节流（6 小时）与内容指纹比对，重复启动不会反复拉。
  unawaited(subSvc.autoSyncOnLaunch());

  runApp(const TVBoxApp());
}
