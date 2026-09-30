import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/player_engine.dart';
import '../common/constants.dart';

/// 全局播放内核与各内核选项（设置页写入，播放器实时读取）
class PlayerPrefs {
  static final PlayerPrefs instance = PlayerPrefs._();
  PlayerPrefs._();

  /// 当前点播内核
  final vodEngine = PlayerEngine.avplayer.obs;

  /// MPV：解码方式
  final decodeMode = VideoDecodeMode.auto.obs;

  /// MPV：缓冲策略
  final bufferMode = VLCBufferMode.balanced.obs;

  /// AVPlayer：自动播放下一集（预留）
  final avAutoNext = true.obs;

  /// Webview：强制横屏
  final webviewForceLandscape = true.obs;

  /// Webview：允许页面 JS（解析站需要）
  final webviewEnableJs = true.obs;

  /// 静音后台保活 Node（关掉更省电、锁屏无「播放中」，但 Node 可能被冻结）
  final silentKeepAlive = true.obs;

  /// 快进步长（秒）
  final playTimeStep = 10.obs;

  // ============================================================
  // 播放器高级选项（对齐参考图的「播放器」设置页）
  // ============================================================

  /// 硬件加速（关闭后软解：更兼容但更耗电）
  final hardwareAccel = true.obs;

  /// 画面填充：0=原比例 / 1=裁剪铺满 / 2=拉伸铺满
  final videoFillMode = 0.obs;

  /// 默认倍速（0.5 ~ 3.0）
  final defaultSpeed = 1.0.obs;

  /// 长按倍速（1.5 ~ 5.0）
  final longPressSpeed = 3.0.obs;

  /// 长按滑动可调节倍速（关闭则长按只用固定倍速）
  final longPressAdjustable = true.obs;

  /// 优先横屏
  final preferLandscape = false.obs;

  /// 进度条显示总时长（关闭则显示剩余时长）
  final showTotalDuration = true.obs;

  /// 隐藏中央快进快退（双击时不再显示中央动画）
  final hideCenterSeek = false.obs;

  /// 进入后台暂停
  final pauseOnBackground = false.obs;

  /// 跳过提示（跳过片头片尾时显示横幅与轻提示）
  final skipHint = false.obs;

  /// 切集提示（切集时显示「正在切换至 第X集」轻提示）
  final switchEpisodeHint = false.obs;

  /// 显示帧率与编码（影响观影性能）
  final showFpsCodec = false.obs;

  /// 始终显示网速（无需开启信息栏即可看到下载速度）
  final alwaysShowSpeed = true.obs;

  /// 默认画质：0=自动（默认），1=最高清晰度
  final defaultQuality = 0.obs;

  /// 全局界面字号缩放（0.85 ~ 1.30，1.0 = 标准）
  final fontScale = 1.0.obs;

  /// 详情页样式：true = 刮削版（海报沉浸式，展示 TMDB 演职人员/类似作品），
  /// false = 默认版（播放器置顶 + 简介/推荐/快搜 tab）。
  /// 刮削版仅在已刮削出数据时生效，否则自动回退默认版。
  final scrapedDetailLayout = false.obs;

  // ============================================================
  // 首页列表外观（筛选菜单里的三项）
  // ============================================================

  /// 分类屏蔽：被屏蔽的分类名称（这些分类不出现在首页分类栏）
  final blockedCategories = <String>[].obs;

  /// 隐藏筛选：true 时首页分类栏下方的筛选行不显示
  final hideFilters = false.obs;

  /// 布局列数：2 / 3 / 4（首页网格每行卡片数）
  final gridColumns = 3.obs;

  /// 收藏页 / 历史页各自的列数（与首页独立，便于分别设置）
  final favGridColumns = 4.obs;
  final historyGridColumns = 4.obs;

  /// 收藏页 / 历史页的搜索关键词（不持久化，仅会话内）
  final favKeyword = ''.obs;
  final historyKeyword = ''.obs;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    // 旧值迁移：
    // 老枚举 mpv=0, webview=1
    // 新枚举 avplayer=0, mpv=1, webview=2
    final raw = prefs.getInt(AppConstants.playTypeVod);
    int mapped;
    if (raw == null) {
      mapped = PlayerEngine.avplayer.value;
    } else if (raw == 1) {
      // 老 webview=1 / 新 mpv=1 冲突：若从未写过 2，按老 webview 处理
      // 简化：1 → mpv（新），用户可在设置改
      mapped = PlayerEngine.mpv.value;
    } else if (raw == 0) {
      // 老 mpv=0 / 新 avplayer=0：升级为 AVPlayer 主内核
      mapped = PlayerEngine.avplayer.value;
    } else {
      mapped = raw;
    }
    await prefs.setInt(AppConstants.playTypeVod, mapped);
    vodEngine.value = PlayerEngine.fromStoredValue(mapped);

    decodeMode.value =
        VideoDecodeMode.fromStoredValue(prefs.getInt('play_decode_mode') ?? 0);
    bufferMode.value =
        VLCBufferMode.fromStoredValue(prefs.getInt('play_vlc_buffer_mode') ?? 0);
    avAutoNext.value = prefs.getBool('av_auto_next') ?? true;
    webviewForceLandscape.value =
        prefs.getBool('webview_force_landscape') ?? true;
    webviewEnableJs.value = prefs.getBool('webview_enable_js') ?? true;
    final step = prefs.getInt('play_time_step') ?? 0;
    playTimeStep.value = step > 0 ? step : 10;
    silentKeepAlive.value = prefs.getBool('silent_keepalive') ?? true;

    final q = prefs.getInt('play_default_quality') ?? 0;
    defaultQuality.value = q == 1 ? 1 : 0;
    final fs = prefs.getDouble('ui_font_scale') ?? 0;
    fontScale.value =
        (fs >= 0.85 && fs <= 1.30) ? fs : 1.0;
    scrapedDetailLayout.value = prefs.getBool('detail_scraped_layout') ?? false;

    // 首页列表外观
    blockedCategories
      ..clear()
      ..addAll(prefs.getStringList('home_blocked_categories') ?? const []);
    hideFilters.value = prefs.getBool('home_hide_filters') ?? false;
    final cols = prefs.getInt('home_grid_columns') ?? 3;
    gridColumns.value = (cols >= 2 && cols <= 4) ? cols : 3;
    final fc = prefs.getInt('fav_grid_columns') ?? 4;
    favGridColumns.value = (fc >= 2 && fc <= 6) ? fc : 4;
    final hc = prefs.getInt('history_grid_columns') ?? 4;
    historyGridColumns.value = (hc >= 2 && hc <= 6) ? hc : 4;

    // 播放器高级选项
    hardwareAccel.value = prefs.getBool('play_hardware_accel') ?? true;
    videoFillMode.value = (prefs.getInt('play_video_fill') ?? 0).clamp(0, 2);
    defaultSpeed.value =
        (prefs.getDouble('play_default_speed') ?? 1.0).clamp(0.5, 3.0);
    longPressSpeed.value =
        (prefs.getDouble('play_longpress_speed') ?? 3.0).clamp(1.5, 5.0);
    longPressAdjustable.value =
        prefs.getBool('play_longpress_adjustable') ?? true;
    preferLandscape.value = prefs.getBool('play_prefer_landscape') ?? false;
    showTotalDuration.value = prefs.getBool('play_show_total') ?? true;
    hideCenterSeek.value = prefs.getBool('play_hide_center_seek') ?? false;
    pauseOnBackground.value = prefs.getBool('play_pause_background') ?? false;
    skipHint.value = prefs.getBool('play_skip_hint') ?? false;
    switchEpisodeHint.value =
        prefs.getBool('play_switch_episode_hint') ?? false;
    showFpsCodec.value = prefs.getBool('play_show_fps_codec') ?? false;
    alwaysShowSpeed.value = prefs.getBool('play_always_show_speed') ?? true;
  }

  // ---- 播放器高级选项 setter ----

  Future<void> setHardwareAccel(bool v) async {
    hardwareAccel.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('play_hardware_accel', v);
  }

  Future<void> setVideoFillMode(int v) async {
    videoFillMode.value = v.clamp(0, 2);
    final p = await SharedPreferences.getInstance();
    await p.setInt('play_video_fill', videoFillMode.value);
  }

  Future<void> setDefaultSpeed(double v) async {
    defaultSpeed.value = v.clamp(0.5, 3.0);
    final p = await SharedPreferences.getInstance();
    await p.setDouble('play_default_speed', defaultSpeed.value);
  }

  Future<void> setLongPressSpeed(double v) async {
    longPressSpeed.value = v.clamp(1.5, 5.0);
    final p = await SharedPreferences.getInstance();
    await p.setDouble('play_longpress_speed', longPressSpeed.value);
  }

  Future<void> setLongPressAdjustable(bool v) async {
    longPressAdjustable.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('play_longpress_adjustable', v);
  }

  Future<void> setPreferLandscape(bool v) async {
    preferLandscape.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('play_prefer_landscape', v);
  }

  Future<void> setShowTotalDuration(bool v) async {
    showTotalDuration.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('play_show_total', v);
  }

  Future<void> setHideCenterSeek(bool v) async {
    hideCenterSeek.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('play_hide_center_seek', v);
  }

  Future<void> setPauseOnBackground(bool v) async {
    pauseOnBackground.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('play_pause_background', v);
  }

  Future<void> setSkipHint(bool v) async {
    skipHint.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('play_skip_hint', v);
  }

  Future<void> setSwitchEpisodeHint(bool v) async {
    switchEpisodeHint.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('play_switch_episode_hint', v);
  }

  Future<void> setShowFpsCodec(bool v) async {
    showFpsCodec.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('play_show_fps_codec', v);
  }

  Future<void> setAlwaysShowSpeed(bool v) async {
    alwaysShowSpeed.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('play_always_show_speed', v);
  }

  Future<void> setFavGridColumns(int n) async {
    favGridColumns.value = n.clamp(2, 6);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('fav_grid_columns', favGridColumns.value);
  }

  Future<void> setHistoryGridColumns(int n) async {
    historyGridColumns.value = n.clamp(2, 6);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('history_grid_columns', historyGridColumns.value);
  }

  /// 分类屏蔽：切换某个分类的屏蔽状态
  Future<void> toggleBlockCategory(String name) async {
    if (blockedCategories.contains(name)) {
      blockedCategories.remove(name);
    } else {
      blockedCategories.add(name);
    }
    blockedCategories.refresh();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('home_blocked_categories', blockedCategories.toList());
  }

  Future<void> setHideFilters(bool v) async {
    hideFilters.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('home_hide_filters', v);
  }

  Future<void> setGridColumns(int n) async {
    gridColumns.value = n.clamp(2, 4);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('home_grid_columns', gridColumns.value);
  }

  Future<void> setEngine(PlayerEngine e) async {
    vodEngine.value = e;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(AppConstants.playTypeVod, e.value);
  }

  Future<void> setDecodeMode(VideoDecodeMode m) async {
    decodeMode.value = m;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('play_decode_mode', m.value);
  }

  Future<void> setBufferMode(VLCBufferMode m) async {
    bufferMode.value = m;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('play_vlc_buffer_mode', m.value);
  }

  Future<void> setAvAutoNext(bool v) async {
    avAutoNext.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('av_auto_next', v);
  }

  /// 切换详情页样式（默认 / 刮削版）
  Future<void> setScrapedDetailLayout(bool v) async {
    scrapedDetailLayout.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('detail_scraped_layout', v);
  }

  Future<void> setWebviewForceLandscape(bool v) async {
    webviewForceLandscape.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('webview_force_landscape', v);
  }

  Future<void> setWebviewEnableJs(bool v) async {
    webviewEnableJs.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('webview_enable_js', v);
  }

  Future<void> setSilentKeepAlive(bool v) async {
    silentKeepAlive.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('silent_keepalive', v);
  }

  Future<void> setPlayTimeStep(int s) async {
    if (s <= 0) return;
    playTimeStep.value = s;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('play_time_step', s);
  }

  /// 设置默认画质：0=自动，1=最高
  Future<void> setDefaultQuality(int q) async {
    defaultQuality.value = q == 1 ? 1 : 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('play_default_quality', defaultQuality.value);
  }

  /// 设置全局字号缩放
  Future<void> setFontScale(double s) async {
    final v = s.clamp(0.85, 1.30);
    fontScale.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('ui_font_scale', v);
  }
}
