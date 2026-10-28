import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/models/player_engine.dart';
import 'package:tvbox/common/constants.dart';
import 'package:tvbox/common/theme.dart';

/// 全局播放内核与各内核选项（设置页写入，播放器实时读取）
class PlayerPrefs {
  static final PlayerPrefs instance = PlayerPrefs._();
  PlayerPrefs._();

  /// 嗅探黑名单的**出厂默认值**：常见的切片广告路径/厂商关键词
  ///（小写子串匹配，命中即丢弃）。用户编辑过黑名单后以用户内容为准。
  static const List<String> kDefaultSniffBlacklist = [
    '/ads/',
    '/ad/',
    '/advert',
    '/guanggao/',
    '/qita/',
    '/promo/',
    'doubleclick',
    'googlead',
  ];

  /// 当前点播内核
  final vodEngine = PlayerEngine.avplayer.obs;

  /// 当前直播内核（与点播独立：直播常遇 flv/ts/rtmp 等 AVPlayer 不支持的流，
  /// 用户需要单独把直播切到 mpv，而不影响点播的内核选择）
  final liveEngine = PlayerEngine.avplayer.obs;

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

  // ============================================================
  // 嗅探 / 解析 规则（用户 2026-10-15：
  // 「嗅探只要 m3u8、MP4、flv 等影视链接；加个嗅探设置，
  //  能指定不嗅探哪些链接、只嗅探哪些链接去广告；解析也限定网页类型」）
  // ============================================================

  /// 嗅探**黑名单**关键词（小写子串匹配，命中的媒体链接直接丢弃，去广告用）。
  /// 首次安装给一组常见广告路径默认值；用户清空/编辑后以用户内容为准。
  final sniffBlacklist = <String>[].obs;

  /// 嗅探**白名单**关键词（小写子串匹配）。非空时**只**嗅探命中的链接，
  /// 为空表示不限制（仍受后缀 + 黑名单约束）。
  final sniffWhitelist = <String>[].obs;

  /// **需要解析**的额外域名（在 play_route.dart 内置的主流站点清单之外追加）。
  /// 域名边界匹配：`a.com` 命中 `a.com` 与 `*.a.com`，不命中 `evil-a.com`。
  final parseHostsExtra = <String>[].obs;

  /// **不解析**的域名（优先级最高，命中即不做解析直接嗅探/播放）。
  /// 用来从内置清单里剔除（例如不想让 qq.com 走解析）。
  final parseHostsBlock = <String>[].obs;

  /// **影视直链后缀清单**（用户 2026-10-15：「后缀列表要能自己加/删」）。
  ///
  /// 每项带点（如 `.m3u8`），默认**空** = 用 play_route.kDefaultMediaExtensions
  /// 出厂清单。填了就以用户清单为准 —— 它同时决定：
  ///   · 什么算"可直接播放的直链"（各链路的直链判定）；
  ///   · 嗅探只接受哪些后缀（含嗅探页 JS 里注入的正则）。
  /// 注意「空」不是"什么都不认"，而是"回退出厂清单"，避免误清空后全播不了。
  final mediaExtensions = <String>[].obs;

  /// **解析结果只要哪些媒体格式**（在影视直链清单里的子集）。空 = 不限。
  /// 解析接口返回的直链若不在勾选格式内，视为未命中（继续试其它接口）。
  final parseFormats = <String>[].obs;

  /// **嗅探总开关**（用户 2026-10-15：设置里要能开关嗅探）。
  /// 默认**关闭**（2026-10-15 用户要求）：网页地址不进嗅探页，直接落
  /// 内嵌网页播放器；开启后网页地址**自动**进嗅探页抓 m3u8/mp4 直链。
  final sniffEnabled = false.obs;

  /// **解析总开关**（用户 2026-10-15：设置里要能开关解析）。
  /// 默认**关闭**（2026-10-15 用户要求）：任何网页都不请求解析接口；
  /// 开启后命中规则的网页先请求解析接口。
  final parseEnabled = false.obs;

  /// **脚本内置解析优先**（2026-10-28）。
  ///
  /// 用户问：「解析是直接用脚本内置还是解析线路？如果脚本有内置的咋弄？」
  /// Spider / 聚合源常自带解析（`parse:1` / `jx:1`，或直接返回自家解析站地址）。
  ///   · `true`（默认）= 尊重脚本作者：脚本声明要解析时，App **不插手**，
  ///     直接用脚本给的地址；
  ///   · `false` = 一律用用户自己的解析线路（并把脚本解析地址里的
  ///     `url=` 内层原始页面取出来重解）。
  /// 用户在「解析 / 嗅探」面板里**主动选过线路**后会自动置 false 并持久化。
  final preferScriptParse = true.obs;

  /// **嗅探播放是否带 Referer**（用户 2026-10-15 拍板加的开关）。
  ///
  /// 开启后，嗅探/解析到的直链在播放时会带上 `Referer: <当前网页地址>` ——
  /// 有些 CDN 强制校验 Referer，不带就 403；但也有站点不校验 Referer 时
  /// 带上反而被拒，所以**默认关闭**（= 维持不带 Referer 的既有行为）。
  final sniffSendReferer = false.obs;

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

  // ============================================================
  // 首页列表外观（筛选菜单里的三项）
  // ============================================================

  /// 分类屏蔽：被屏蔽的分类名称（这些分类不出现在首页分类栏）
  final blockedCategories = <String>[].obs;

  /// 隐藏筛选：true 时首页分类栏下方的筛选行不显示
  final hideFilters = false.obs;

  /// 布局列数：2 / 3 / 4（首页网格每行卡片数）
  final gridColumns = 3.obs;

  /// REX 页面的列数（默认 2 —— 用户 2026-10-23：「REX 页面默认卡片一行 2 列」）
  final rexGridColumns = 2.obs;

  /// REX 订阅管理页视图：0 = 列表，2/3/4 = 一行几列（默认 2 列卡片）
  final rexManageView = 2.obs;

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

    // 直播内核（与点播独立持久化；无历史值时默认 AVPlayer，
    // 与旧行为一致 —— 旧版本直播读的就是 vodEngine 的默认值）
    liveEngine.value = PlayerEngine.fromStoredValue(
        prefs.getInt('play_live_engine') ?? PlayerEngine.avplayer.value);

    decodeMode.value =
        VideoDecodeMode.fromStoredValue(prefs.getInt('play_decode_mode') ?? 0);
    bufferMode.value =
        VLCBufferMode.fromStoredValue(prefs.getInt('play_vlc_buffer_mode') ?? 0);
    avAutoNext.value = prefs.getBool('av_auto_next') ?? true;
    webviewForceLandscape.value =
        prefs.getBool('webview_force_landscape') ?? true;
    webviewEnableJs.value = prefs.getBool('webview_enable_js') ?? true;

    // 嗅探 / 解析规则：
    // 黑名单首次安装（键不存在）给出厂默认；用户主动清空后存的是 []，
    // getStringList 返回空数组 ⇒ 尊重用户的"清空"，不会又塞回默认值。
    sniffBlacklist
      ..clear()
      ..addAll(prefs.getStringList('sniff_blacklist') ??
          kDefaultSniffBlacklist);
    sniffWhitelist
      ..clear()
      ..addAll(prefs.getStringList('sniff_whitelist') ?? const []);
    parseHostsExtra
      ..clear()
      ..addAll(prefs.getStringList('parse_hosts_extra') ?? const []);
    parseHostsBlock
      ..clear()
      ..addAll(prefs.getStringList('parse_hosts_block') ?? const []);
    mediaExtensions
      ..clear()
      ..addAll(prefs.getStringList('media_extensions') ?? const []);
    parseFormats
      ..clear()
      ..addAll(prefs.getStringList('parse_formats') ?? const []);
    // 嗅探/解析总开关：默认关闭（用户 2026-10-15 要求）
    sniffEnabled.value = prefs.getBool('sniff_enabled') ?? false;
    parseEnabled.value = prefs.getBool('parse_enabled') ?? false;
    // 脚本内置解析优先：默认 true（尊重脚本作者）
    preferScriptParse.value = prefs.getBool('prefer_script_parse') ?? true;
    // 嗅探播放带 Referer：默认关闭（维持既有"不带 Referer"行为）
    sniffSendReferer.value = prefs.getBool('sniff_send_referer') ?? false;
    final step = prefs.getInt('play_time_step') ?? 0;
    playTimeStep.value = step > 0 ? step : 10;
    silentKeepAlive.value = prefs.getBool('silent_keepalive') ?? true;

    final q = prefs.getInt('play_default_quality') ?? 0;
    defaultQuality.value = q == 1 ? 1 : 0;
    // #10：字号缩放的**持久化与入口都移到 AppTheme** 了
    // （它是外观设置，不属于播放器）。
    //   · 读取入口：AppTheme.fontScale（ValueNotifier）
    //   · 加载：main.dart 启动时 AppTheme.loadFontScale()（在本方法之前）
    //   · 写入：AppTheme.setFontScale()
    // 这个 .obs 字段只是**兼容壳**：全项目已无人读它，
    // 保留是为了不破坏外部可能的引用。可以随时删。
    fontScale.value = AppTheme.fontScale.value;

    // 首页列表外观
    blockedCategories
      ..clear()
      ..addAll(prefs.getStringList('home_blocked_categories') ?? const []);
    hideFilters.value = prefs.getBool('home_hide_filters') ?? false;
    final cols = prefs.getInt('home_grid_columns') ?? 3;
    gridColumns.value = (cols >= 2 && cols <= 4) ? cols : 3;
    final rc = prefs.getInt('rex_grid_columns') ?? 2;
    rexGridColumns.value = (rc >= 2 && rc <= 4) ? rc : 2;
    final rmv = prefs.getInt('rex_manage_view') ?? 2;
    rexManageView.value = (rmv == 0 || (rmv >= 2 && rmv <= 4)) ? rmv : 2;
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

  Future<void> setRexGridColumns(int n) async {
    rexGridColumns.value = n.clamp(2, 4);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('rex_grid_columns', rexGridColumns.value);
  }

  /// REX 订阅管理页视图：0 = 列表，2/3/4 = 一行几列
  Future<void> setRexManageView(int v) async {
    rexManageView.value = (v == 0 || (v >= 2 && v <= 4)) ? v : 2;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('rex_manage_view', rexManageView.value);
  }

  Future<void> setEngine(PlayerEngine e) async {
    vodEngine.value = e;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(AppConstants.playTypeVod, e.value);
  }

  /// 设置直播内核（独立于点播的 [setEngine]）
  Future<void> setLiveEngine(PlayerEngine e) async {
    liveEngine.value = e;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('play_live_engine', e.value);
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

  // ---- 嗅探 / 解析 规则 setter ----

  /// 统一写一个字符串列表规则项：去空白、去空行、去重后落盘并刷新内存。
  Future<void> _setRuleList(RxList<String> field, String key,
      List<String> values) async {
    final cleaned = <String>{
      for (final v in values.map((e) => e.trim()))
        if (v.isNotEmpty) v.toLowerCase(),
    }.toList();
    field
      ..clear()
      ..addAll(cleaned);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(key, cleaned);
  }

  /// 嗅探黑名单（不嗅探的链接关键词）
  Future<void> setSniffBlacklist(List<String> v) =>
      _setRuleList(sniffBlacklist, 'sniff_blacklist', v);

  /// 嗅探白名单（非空时只嗅探命中的链接）
  Future<void> setSniffWhitelist(List<String> v) =>
      _setRuleList(sniffWhitelist, 'sniff_whitelist', v);

  /// 需要解析的额外域名
  Future<void> setParseHostsExtra(List<String> v) =>
      _setRuleList(parseHostsExtra, 'parse_hosts_extra', v);

  /// 不解析的域名
  Future<void> setParseHostsBlock(List<String> v) =>
      _setRuleList(parseHostsBlock, 'parse_hosts_block', v);

  /// 嗅探总开关
  Future<void> setSniffEnabled(bool v) async {
    sniffEnabled.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sniff_enabled', v);
  }

  /// 解析总开关
  Future<void> setParseEnabled(bool v) async {
    parseEnabled.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('parse_enabled', v);
  }

  /// 脚本内置解析优先（true = 尊重脚本；false = 一律用用户解析线路）
  Future<void> setPreferScriptParse(bool v) async {
    preferScriptParse.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('prefer_script_parse', v);
  }

  /// 嗅探播放是否带 Referer（默认关）
  Future<void> setSniffSendReferer(bool v) async {
    sniffSendReferer.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sniff_send_referer', v);
  }

  /// 影视直链后缀清单（空 = 用出厂清单）
  Future<void> setMediaExtensions(List<String> v) =>
      _setRuleList(mediaExtensions, 'media_extensions', v);

  /// 解析结果只要哪些媒体格式（空 = 不限）
  Future<void> setParseFormats(List<String> v) =>
      _setRuleList(parseFormats, 'parse_formats', v);

  /// 把嗅探黑名单恢复成出厂默认（其余各项清空）。
  Future<void> resetSniffRules() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('sniff_blacklist', kDefaultSniffBlacklist);
    await prefs.setStringList('sniff_whitelist', const []);
    await prefs.setStringList('parse_hosts_extra', const []);
    await prefs.setStringList('parse_hosts_block', const []);
    await prefs.setStringList('media_extensions', const []);
    await prefs.setStringList('parse_formats', const []);
    // 嗅探播放带 Referer 也回到默认（关闭）
    await prefs.setBool('sniff_send_referer', false);
    sniffSendReferer.value = false;
    sniffBlacklist
      ..clear()
      ..addAll(kDefaultSniffBlacklist);
    sniffWhitelist.clear();
    parseHostsExtra.clear();
    parseHostsBlock.clear();
    mediaExtensions.clear();
    parseFormats.clear();
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

  /// 设置全局字号缩放（委托给 AppTheme —— #10 字号是外观设置）
  Future<void> setFontScale(double s) async {
    await AppTheme.setFontScale(s);
    fontScale.value = AppTheme.fontScale.value; // 兼容壳同步
  }
}
