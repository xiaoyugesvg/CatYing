import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/module_theme_sync.dart';
import 'package:tvbox/common/theme_mode_store.dart';
import 'package:tvbox/services/prefs_mirror.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';
import 'package:tvbox/reading/theme/jelly_theme.dart';
import 'package:tvbox/reading/utils/constants.dart';
import 'package:tvbox/reading/utils/safe_num.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    debugPrint('[Settings] $message');
  }
}

/// 漫画阅读模式：
/// - pageTurn：从右往左翻页（横向逐页，日漫方向，图片从右翻入）
/// - leftToRight：从左往右翻页（图片从左翻入）
/// - dissolve：消散（当前页淡出、下一页淡入）
/// - continuous：拼页（上下连续滚动）
/// - none：无动画（点击直接切换，不滑动；方向同 pageTurn）
/// 注：leftToRight 加在 dissolve 之后，none 追加末尾，保持旧持久化 index 不变。
enum ReadingMode { pageTurn, continuous, dissolve, leftToRight, none }

/// 图书阅读模式：翻页（左右平移）/ 仿真翻页（卷曲） / 覆盖（新页滑入覆盖当前页）
/// - vertical：上下翻页（纵向平移）
/// - none：无动画（点击直接切换，不滑动；方向同 pageTurn）
/// 注：vertical/none 追加末尾，保持旧持久化 index 不变。
enum BookReadingMode { pageTurn, simulation, cover, vertical, none }

/// 底部导航 tab 枚举（与导航栏顺序一致）
enum NavTab { manga, book, bookshelf, favorites, me }

/// 启动默认首页（对应底部导航 tab）
enum DefaultHomePage { manga, book, bookshelf, favorites, me }

/// 收藏/书架/下载三页默认显示的内容类型
enum PageDefaultContent { manga, book }

/// 首页顶部幻灯片（轮播）样式 —— 用户可在「设置 → 菜单设置」切换。
///
/// ⚠️ 持久化**存 name**（老数据存的是 index，读取时按
/// [kLegacyHomeBannerOrder] 迁移一次）。原来存 index，于是一旦在中间
/// 删/加样式，老用户已选的样式就会**悄悄漂到另一种** ——
/// 2026-10-16 换掉 3 种样式时正是这个坑。
enum HomeBannerStyle {
  /// 横版大图（原样式）：16:9 大图铺满，左下标题 + 右下来源角标
  wide,

  /// 卡片轮播：中间竖版海报放大居中，两侧海报缩小 / 倾斜 / 压暗露出
  /// （coverflow 观感，对齐用户 2026-10-13 给的参考图）
  cards,

  /// 沉浸大图（新增）：**满宽出血**画面 + 底部多层渐变 + 大字标题 + 元信息行
  /// + 右下圆形播放钮；指示器是**细长分段进度条**（不是圆点）。
  /// 参考 Disney+ 新版 hero carousel：让画面主体"顶到边"，文字压在渐变上。
  hero,

  /// 主次三栏（2026-10-14 **换掉**原「叠卡堆」）：左边一张大竖版海报 +
  /// 右侧竖排 3 条小卡（缩略图 + 标题）。杂志排版：一条主推 + 三条次要。
  /// 用户原话：「叠卡堆和三格海报太他妈丑了，这两个换其他样式」。
  feature,

  /// 交错瀑布（2026-10-15 新增）：2 列错位 —— 左边 1 张**满高**大卡，
  /// 右边上下 2 张短卡。比"规整网格"更有节奏感。
  masonry,

  /// 编辑推荐（2026-10-16 换掉「双排海报」）：一页 1 张 —— 左边**竖版封面**
  /// + 右边**文字栏**（年份·地区·分类 / 大标题 / 简介 / 「立即播放」胶囊）。
  /// 唯一"以文为主"的样式：适合认真看一条推荐，而不是扫一墙海报。
  spotlight,

  /// 高低错落（2026-10-16 换掉「左右双卡」）：一页 3 张竖版海报，**中间那张
  /// 抬高、左右两张下沉**（并略窄）⇒ 三张不等高的错落节奏。
  /// 与「交错瀑布」的区别：那边是 2 列 / 1 大 2 小，这边是 3 列等宽不等高。
  stair,

  /// 走马灯（2026-10-16 **换掉**「上下双联」）：一页 1 张横版图文，
  /// 图上叠加**左右箭头** + **底部圆点指示器**，5 秒自动播放 + 可拖动 / 点箭头。
  /// 就是最常见的那种 Banner 走马灯（自动播 + 左右箭头 + 圆点）。
  carousel,

  /// 扑克牌（2026-10-16 新增）：卡牌**前后堆叠**，左右两张各露出一角，
  /// 切换时带抽离 / 滑动（拖动过程中缩放、下沉、微旋与位移是连续的）。
  /// 比"并排"更有层次，适合影视推荐这类偏年轻化的模块。
  poker,

  /// 标签页（2026-10-16 新增）：上方**标签条** + 下方卡片**联动** ——
  /// 滑卡片时标签跟着切，点标签卡片滑过去。适合按"最新 / 精选 / 快看"分档展示。
  tabs;

  String get label => switch (this) {
        // 名称统一**最多 4 个字**（用户 2026-10-14：多了去掉，卡片宽度才一致）
        HomeBannerStyle.wide => '横版大图',
        HomeBannerStyle.cards => '卡片轮播',
        HomeBannerStyle.hero => '沉浸大图',
        HomeBannerStyle.feature => '主次三栏',
        HomeBannerStyle.masonry => '交错瀑布',
        HomeBannerStyle.spotlight => '编辑推荐',
        HomeBannerStyle.stair => '高低错落',
        HomeBannerStyle.carousel => '走马灯',
        HomeBannerStyle.poker => '扑克牌',
        HomeBannerStyle.tabs => '标签页',
      };
}

/// **旧版** `HomeBannerStyle` 的取值顺序（存 index 时代的枚举顺序）。
///
/// 2026-10-16 把「双排海报 / 左右双卡 / 九宫格」换成「编辑推荐 / 高低错落 /
/// 上下双联」，同时把持久化从 **index 改成 name**。老用户 prefs 里还留着
/// index，读的时候用这张表换回名字，才不会让"我明明选的是交错瀑布"变成别的。
///
/// ⚠️ 这张表是**历史快照，只增不改**（改了就迁移错）。
const List<String> kLegacyHomeBannerOrder = [
  'wide',
  'cards',
  'hero',
  'feature',
  'grid', // 已删除 → 迁移时回落到 wide
  'duo', // 已删除 → 迁移时回落到 wide
  'nine', // 已删除 → 迁移时回落到 wide
  'masonry',
];

/// 把老数据（index）转成样式；越界 / 已删除的样式 → `wide`。
HomeBannerStyle homeBannerStyleFromLegacyIndex(int idx) {
  if (idx < 0 || idx >= kLegacyHomeBannerOrder.length) {
    return HomeBannerStyle.wide;
  }
  final name = kLegacyHomeBannerOrder[idx];
  for (final st in HomeBannerStyle.values) {
    if (st.name == name) return st;
  }
  return HomeBannerStyle.wide;
}

/// 首页幻灯片最多取几个视频（兜底抓取 / 缓存按这个上限来，显示时再按样式裁）。
const int kHomeBannerMaxItems = 9;

/// **每种幻灯片样式取几个视频**（用户 2026-10-16：「根据幻灯片的样式调整到 6~9 个」）。
///
/// 之前是**写死 6 个**（view.dart 里 `sublist(0, 6)`），于是
/// 一页 9 张的样式只有 6 张、「主次三栏」一页 4 张第 2 页只剩 2 张，
/// 密度差被这个固定值抹平了。
///
/// 取值规则：**落在 6~9 之间，且尽量是"每页张数"的整数倍**（末页不留半屏空位）。
/// ⚠️ 各样式"每页张数"的定义在 `pages/home/view.dart` 的 `_kBanner*PerPage`，
/// 改那边记得同步这里。
int homeBannerItemCount(HomeBannerStyle style) => switch (style) {
      // 一页 1 张（大图 / 卡片轮播 / 沉浸大图 / 编辑推荐 / 走马灯 / 扑克牌）
      // → 9 张，轮播久一点
      HomeBannerStyle.wide ||
      HomeBannerStyle.cards ||
      HomeBannerStyle.hero ||
      HomeBannerStyle.spotlight ||
      HomeBannerStyle.carousel ||
      HomeBannerStyle.poker =>
        9,
      // 一页 1 张，但上方还有一条**标签**要排 → 只取 6 个，
      // 标签条不至于挤成一条缝（用户 2026-10-16 新增「标签页」）
      HomeBannerStyle.tabs => 6,
      // 一页 3 张（交错瀑布 / 高低错落）→ 9
      HomeBannerStyle.masonry || HomeBannerStyle.stair => 9,
      // 一页 4 张（主次三栏：1 大 + 3 小）→ 8
      HomeBannerStyle.feature => 8,
    };

/// NavTab 与 DefaultHomePage 的双向转换辅助（两者值一一对应）
extension NavTabDefaultHomePageX on NavTab {
  DefaultHomePage toDefaultHomePage() => DefaultHomePage.values[index];
}

extension DefaultHomePageNavTabX on DefaultHomePage {
  NavTab toNavTab() => NavTab.values[index];
}

/// 应用设置服务（单例 + ChangeNotifier）
/// 持久化：
/// - 下载并发参数：同时下载量、分片并发量
/// - 下载保存位置（自定义目录；空 = 默认应用私有目录）
/// - 漫画章节合并 EPUB 及合并后是否保留图片
/// - 阅读模式：翻页 / 拼页
/// - 在线阅读预加载图片数
/// - 暗色模式（首次跟随系统，之后保留用户选择）
/// - 主题跟随系统（默认开启；开启时实时跟随系统明暗，关闭后用手动选择）
class SettingsService extends ChangeNotifier {
  SettingsService._();
  static final SettingsService _instance = SettingsService._();
  factory SettingsService() => _instance;

  static const _chaptersKey = 'download_max_concurrent_chapters';
  static const _imagesKey = 'download_max_concurrent_images';
  static const _readingModeKey = 'reading_mode';
  static const _preloadKey = 'reader_preload_image_count';
  static const _savePathKey = 'download_save_path';
  static const _mergeEpubKey = 'download_merge_epub';
  static const _keepImagesKey = 'download_keep_images_after_epub';
  static const _mergeChaptersCountKey = 'download_merge_chapters_count';
  static const _trimWhitespaceKey = 'download_trim_whitespace';
  // ── 下载设置（参考图 IMG_8466~8468 补全）─────────────────────
  static const _kBackgroundDownloadKey = 'download_background';
  static const _kWifiOnlyKey = 'download_wifi_only';
  static const _kBookSourceConcurrencyKey = 'download_book_source_concurrency';
  static const _kBookFileConcurrencyKey = 'download_book_file_concurrency';
  static const _kOnlineBookCacheKey = 'download_online_book_cache_gb';
  static const _kOnlineComicCacheKey = 'download_online_comic_cache_gb';
  static const _kPauseMergeOnErrorKey = 'download_pause_merge_on_error';
  static const _kProtectFullBookKey = 'download_protect_full_book_cache';
  static const _defaultHomeKey = 'default_home_page';
  static const _kBuiltinAccountKey = 'use_builtin_account';
  static const _kGlobalProxyEnabledKey = 'global_proxy_enabled';
  static const _kGlobalProxyKey = 'global_proxy'; // "host:port"（空串=直连）
  // 「APP 代理」域名规则（Webhtv）：proxy_domain_only=false 时全部走代理（现状）；
  // =true 时**只有命中的域名**走代理，其余直连（见 global_proxy.dart）
  static const _kProxyDomainOnlyKey = 'proxy_domain_only';
  static const _kProxyDomainRulesKey = 'proxy_domain_rules';
  static const _kAutoSyncKey = 'auto_sync_backup'; // 同步与备份：自动同步开关
  static const _kDarkModeKey = 'dark_mode';
  static const _kThemeFollowSystemKey = 'theme_follow_system';
  static const _kThemePresetKey = 'theme_preset'; // 主题预设：jelly/pink/green
  // 「我的」页头像：'' = 默认图标；'a01'~'a40' = assets/avatars 内置；
  // 'custom' = 用户从相册上传（文件路径另存 _kReaderAvatarPathKey）
  static const _kReaderAvatarKey = 'reader_avatar';
  static const _kReaderAvatarPathKey = 'reader_avatar_path';
  static const _kBgAnimationKey = 'background_animation'; // 主题背景动画开关
  static const _kFrameRateReducedKey = 'frame_rate_reduced'; // 主题动画降帧省电
  static const _kCustomThemesKey = 'custom_themes'; // 自定义主题（JSON 数组）
  static const _kBookFontSizeKey = 'book_font_size';
  static const _kBookLineHeightKey = 'book_line_height';
  // 仿真翻页细节
  static const _kPageCurlShadowKey = 'page_curl_shadow';
  static const _kPageCurlQualityKey = 'page_curl_quality';
  static const _kPageCurlTextureKey = 'page_curl_texture';
  static const _kBookHorizontalPaddingKey = 'book_h_padding';
  static const _kBookVerticalPaddingKey = 'book_v_padding';
  static const _kBookReadingModeKey = 'book_reading_mode';
  // 图书正文字体覆盖：null = 跟随阅读模式（仿真→inkReadingKai，否则系统）；
  // 'system' = 强制系统字体；'inkReadingKai' = 内置楷体；其他 = 用户字体 family。
  static const _kBookFontFamilyKey = 'book_font_family';
  static const _kNavVisibleTabsKey = 'nav_visible_tabs';
  static const _kNavFloatingKey = 'nav_floating';
  static const _kNavIconOnlyKey = 'nav_icon_only';
  // 悬浮底栏外观（用户 2026-10-18）：风格 id + 各 tab 的自定义图标路径
  static const _kNavStyleKey = 'nav_style';
  static const _kNavCustomIconsKey = 'nav_custom_icons';

  /// 悬浮底栏不透明度（2026-10-24：用户「菜单栏太透明了」→ 可调）
  static const _kNavBarOpacityKey = 'nav_bar_opacity';
  static const _kNavOrderVersionKey =
      'nav_order_version'; // 导航 tab 顺序版本（v2: 书架与收藏互换）
  static const _kPageTabsFollowNavKey = 'page_tabs_follow_nav';
  static const _kHomeBannerStyleKey = 'home_banner_style'; // 首页幻灯片样式
  static const _kPageDefaultContentKey = 'page_default_content';
  // 翻页按钮反转：左点下一页、右点上一页（默认关）
  static const _kReverseTapKey = 'reader_reverse_tap';
  // 双页模式：横屏左右并排两页（默认关，仅翻页模式生效）
  static const _kDoublePageKey = 'reader_double_page';
  // 阅读信息栏：阅读时角落显示时间/页码/进度等（默认开）
  static const _kShowReaderHudKey = 'reader_show_hud';
  // 音量键翻页：阅读时按音量上/下键翻页（默认关，会接管音量键）
  static const _kVolumeKeyTurnKey = 'reader_volume_key_turn';
  // ── 以下 5 项按 cmbok V2.0.8「阅读设置」截图补齐 ──────────────
  static const _kCheckShelfUpdateKey = 'check_shelf_update_on_start';
  static const _kRememberZoomKey = 'reader_remember_zoom';
  static const _kPinchZoomKey = 'reader_pinch_zoom';
  static const _kSingleHandKey = 'reader_single_hand';
  /// C8 漫画点击九宫格：JSON List<int>（9 格，值 = TapAction.index；空 = 默认三列）
  static const _kMangaTapZonesKey = 'manga_tap_zones';
  // 书架排序方式（按用户截图里的"排序"按钮）
  static const _kShelfSortKey = 'shelf_sort';
  // 排序方向（true = 正序 Z→A / 旧→新）与"全局应用"
  static const _kShelfSortAscKey = 'shelf_sort_asc';
  static const _kShelfSortGlobalKey = 'shelf_sort_global';
  // 被隐藏的书架 id 列表（「管理书架」里的眼睛开关）
  static const _kHiddenShelfIdsKey = 'shelf_hidden_ids';
  // 从书架移除时是否同时删除本地文件（「书架设置」里的开关）
  static const _kRemoveDeletesFileKey = 'shelf_remove_deletes_file';
  static const _kScreenSleepKey = 'reader_screen_sleep';
  // 阅读背景样式：0纯白 / 1纸白 / 2米黄 / 3暗夜 / 4纯黑（默认暗夜=现黑底）
  static const _kReaderBackgroundStyleKey = 'reader_background_style';
  // 漫画阅读器边距（参考 cmbok「边距」tab：页眉左右16/上8、页脚左右16/下8）
  static const _kComicMarginKey = 'comic_reader_margin';

  /// 一次性迁移：2026-10-18 起漫画默认边距改为 0（贴边全屏）。
  static const _kComicMarginFullscreenKey = 'comic_margin_fullscreen_v1';
  // 端侧 AI 漫画超分（参考 cmbok「AI 超分」面板；仅 UI，不真实推理）
  static const _kUpscaleAutoCleanKey = 'upscale_auto_clean';
  static const _kUpscaleCleanLimitKey = 'upscale_clean_limit_gb';
  static const _kUpscaleDenoiseKey = 'upscale_denoise';
  static const _kUpscaleModelDownloadedKey = 'upscale_model_downloaded';
  static const _kAutoAddShelfKey = 'reader_auto_add_shelf';
  static const _kAutoAddShelfForBookKey = 'reader_auto_add_shelf_book';
  // 墨水屏模式：漫画黑白显示 + 柔和浅灰底（默认关）
  static const _kInkScreenModeKey = 'reader_ink_screen_mode';
  // 漫画阅读器页面亮度（独立叠加层，不调系统亮度；0.35~1.0，默认 1.0）
  static const _kComicBrightnessKey = 'comic_reader_brightness';
  // 番茄钟：循环次数 / 每轮休息分钟
  static const _kPomodoroLoopCountKey = 'pomodoro_loop_count';
  static const _kPomodoroRestMinutesKey = 'pomodoro_rest_minutes';

  /// 同时下载量：默认 2，范围 1~5
  static const int minConcurrentChapters = 1;
  static const int maxConcurrentChaptersLimit = 5;
  static const int defaultConcurrentChapters = 2;

  /// 分片并发量：默认 10，范围 1~20
  static const int minConcurrentImages = 1;
  static const int maxConcurrentImagesLimit = 20;
  static const int defaultConcurrentImages = 10;

  /// 在线阅读预加载图片数：默认 5，范围 2~10
  static const int minPreloadImages = 2;
  static const int maxPreloadImages = 10;
  static const int defaultPreloadImages = 5;

  /// 番茄钟：工作时长固定 25 分钟（不可配）
  static const int pomodoroWorkMinutes = 25;

  /// 番茄钟循环次数：默认 1，范围 1~5
  static const int minPomodoroLoopCount = 1;
  static const int maxPomodoroLoopCount = 5;
  static const int defaultPomodoroLoopCount = 1;

  /// 番茄钟每轮休息分钟：默认 5，范围 1~15
  static const int minPomodoroRestMinutes = 1;
  static const int maxPomodoroRestMinutes = 15;
  static const int defaultPomodoroRestMinutes = 5;

  /// 图书排版：字号 / 行距 / 四周边距
  static const double defaultBookFontSize = 18;
  static const double minBookFontSize = 12;
  static const double maxBookFontSize = 28;
  static const double defaultBookLineHeight = 1.6;
  static const double minBookLineHeight = 1.2;
  static const double maxBookLineHeight = 3.0;
  static const double defaultBookHorizontalPadding = 16; // 图书左右边距
  static const double minBookHorizontalPadding = 15;
  static const double maxBookHorizontalPadding = 30;
  static const double defaultBookVerticalPadding = 36; // 图书上下边距
  static const double minBookVerticalPadding = 15;
  static const double maxBookVerticalPadding = 55;

  int _maxConcurrentChapters = defaultConcurrentChapters;
  int _maxConcurrentImages = defaultConcurrentImages;
  ReadingMode _readingMode = ReadingMode.pageTurn;
  BookReadingMode _bookReadingMode = BookReadingMode.pageTurn;
  String? _downloadSavePath;
  bool _mergeChapterToEpub = true;
  bool _keepImagesAfterEpub = true;
  int _mergeChaptersPerEpub = 1; // 每 N 话合并为一个 EPUB（1~101，101=无限整本）
  bool _trimWhitespace = false; // 下载时去白边
  // ── 下载设置（参考图 IMG_8466~8468 补全）─────────────────────
  bool _backgroundDownload = true; // 后台下载（切后台/息屏继续）
  bool _wifiOnlyDownload = false; // 仅 Wi-Fi 下载
  int _bookSourceConcurrency = 15; // 书源下载并发量（1~50）
  int _bookFileConcurrency = 2; // 图书文件下载并发量（1~5）
  int _onlineBookCacheGb = 1; // 在线书临时缓存上限（GB，1~16）
  int _onlineComicCacheGb = 1; // 在线漫画图片缓存上限（GB，1~16）
  bool _pauseMergeOnError = false; // 失败或缺页时暂停合并
  bool _protectFullBookCache = true; // 缓存全本固定保护
  static const int minMergeChaptersPerEpub = 1;
  static const int maxMergeChaptersPerEpub = 101; // 101 = 无限（整本合并）

  /// 书源下载并发量：默认 15，范围 1~50
  static const int minBookSourceConcurrency = 1;
  static const int maxBookSourceConcurrency = 50;
  static const int defaultBookSourceConcurrency = 15;

  /// 图书文件下载并发量：默认 2，范围 1~5
  static const int minBookFileConcurrency = 1;
  static const int maxBookFileConcurrency = 5;
  static const int defaultBookFileConcurrency = 2;

  /// 在线书/漫画缓存上限（GB）：默认 1，范围 1~16
  static const int minOnlineCacheGb = 1;
  static const int maxOnlineCacheGb = 16;
  static const int defaultOnlineCacheGb = 1;
  DefaultHomePage _defaultHomePage = DefaultHomePage.manga;
  bool _useBuiltinAccount = true; // 图书下载未登录时是否回退内置账号（搜索一律回退内置账号）
  bool _globalProxyEnabled = false; // 全局网络代理开关（参考图 IMG_8465 网络代理）
  String _globalProxy = ''; // 全局代理 "host:port"
  bool _proxyDomainOnly = false; // 只对规则里的域名走代理（默认关 = 全部走）
  List<String> _proxyDomainRules = const []; // 域名规则（* 通配 / 也容忍粘贴整条 URL）
  bool _autoSyncBackup = false; // 同步与备份：自动同步开关
  bool _isDarkMode = false; // 暗色模式（首次跟随系统，之后保留用户选择）
  bool _themeFollowSystem = true; // 主题跟随系统明暗；关闭后用上面的手动选择
  String _themePreset = 'ink'; // 主题预设：ink(水墨书香,默认)/jelly/pink/green/... 或 custom_*
  String _readerAvatar = ''; // 头像：'' 默认 / 'aNN' 内置 / 'custom' 上传
  String _readerAvatarPath = ''; // 上传头像的本地绝对路径（'custom' 时用）
  bool _backgroundAnimation = true; // 主题背景动画开关
  bool _frameRateReduced = true; // 主题动画降帧省电（默认开启，减半重绘）
  List<ThemePresetInfo> _customThemes =
      []; // 用户自定义主题（运行时镜像，持久化于 _kCustomThemesKey）
  int _preloadImageCount = defaultPreloadImages; // 在线阅读预加载图片数
  double _bookFontSize = defaultBookFontSize; // 图书字号
  double _bookLineHeight = defaultBookLineHeight; // 图书行距

  // 仿真翻页：阴影强度 0~1 / 性能档位 0 流畅 1 标准 2 精细 / 纸张纹理
  double _pageCurlShadow = 0.75;
  int _pageCurlQuality = 1;
  bool _pageCurlTexture = true;
  double _bookHorizontalPadding = defaultBookHorizontalPadding; // 图书左右边距
  double _bookVerticalPadding = defaultBookVerticalPadding; // 图书上下边距
  // 图书正文字体：null = 跟随阅读模式；其他含义见 _kBookFontFamilyKey 注释。
  String? _bookFontFamily;
  List<NavTab> _visibleNavTabs = NavTab.values.toList(); // 导航栏可见 tab，默认全显示
  bool _navFloating = true; // 导航栏是否悬浮（胶囊型毛玻璃样式），默认开启
  bool _navIconOnly = false; // 导航栏只显示图标（隐藏文字标签），默认关
  String _navStyle = 'ink'; // 悬浮栏风格：ink / frost / aurora / neon / reverse / solid
  double _navBarOpacity = 0.95; // 悬浮底栏不透明度（0.30~1.0）
  final Map<String, String> _navCustomIcons = {}; // tab 标签 → 自定义图标文件路径
  bool _pageTabsFollowNav = true; // 收藏/书架/下载页 tab 是否跟随导航栏 manga/book 可见性

  // ── 书架 / 收藏 卡片外观（用户 2026-10-15：显示设置新增 3 项）────────
  static const _kListDensityKey = 'reading_list_density'; // 0紧凑 1标准 2宽松
  static const _kCoverRadiusKey = 'reading_cover_radius'; // 0小 1中 2大
  static const _kCardInfoKey = 'reading_card_info'; // 卡片信息（进度/来源/更新角标）

  int _listDensity = 1; // 0=紧凑 1=标准 2=宽松
  int _coverRadius = 1; // 0=小 1=中 2=大
  bool _cardInfo = true; // 是否显示卡片上的信息徽标

  /// 书架 / 收藏 卡片密度：0=紧凑 1=标准 2=宽松
  int get listDensity => _listDensity;

  /// 封面圆角档位：0=小 1=中 2=大
  int get coverRadius => _coverRadius;

  /// 卡片信息（进度 / 来源 / 更新角标）是否显示
  bool get cardInfo => _cardInfo;

  /// 封面圆角像素（档位 → px）
  double get coverRadiusPx => switch (_coverRadius) {
        0 => 6.0,
        2 => 16.0,
        _ => 10.0,
      };

  /// 卡片留白 / 间距的密度系数
  double get densityScale => switch (_listDensity) {
        0 => 0.8,
        2 => 1.3,
        _ => 1.0,
      };

  Future<void> setListDensity(int value) async {
    if (_listDensity == value) return;
    _listDensity = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kListDensityKey, value);
      PrefsMirror.snapshotSoon();
    } catch (e) {
      _log('保存列表密度失败: $e');
    }
  }

  Future<void> setCoverRadius(int value) async {
    if (_coverRadius == value) return;
    _coverRadius = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kCoverRadiusKey, value);
      PrefsMirror.snapshotSoon();
    } catch (e) {
      _log('保存封面圆角失败: $e');
    }
  }

  Future<void> setCardInfo(bool value) async {
    if (_cardInfo == value) return;
    _cardInfo = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kCardInfoKey, value);
      PrefsMirror.snapshotSoon();
    } catch (e) {
      _log('保存卡片信息开关失败: $e');
    }
  }
  HomeBannerStyle _homeBannerStyle =
      HomeBannerStyle.wide; // 首页幻灯片样式（默认保持原样：横版大图）
  PageDefaultContent _pageDefaultContent =
      PageDefaultContent.manga; // 收藏/书架/下载页默认显示内容
  bool _reverseTap = false; // 翻页按钮反转（左下一、右上一）
  bool _doublePage = false; // 双页模式（横屏左右并排两页）
  bool _showReaderHud = true; // 阅读信息栏（时间/页码/进度）
  bool _volumeKeyTurn = false; // 音量键翻页
  bool _inkScreenMode = false; // 墨水屏模式（漫画黑白 + 柔和浅灰底）
  double _comicBrightness = 1.0; // 漫画阅读器页面亮度（0.35~1.0，独立叠加层）
  // ── 下面 6 项对应 cmbok「阅读设置」里的开关（截图逐项对齐）──
  /// 启动时自动检查书架/收藏是否有新章节（有更新在封面/导航角标提示）
  bool _checkShelfUpdateOnStart = false;
  /// 翻页时保留当前缩放（需先开双指缩放）
  bool _rememberZoom = false;
  /// 双指缩放（拼页模式除外；图书仅图片模式）
  bool _pinchZoom = true;
  /// 单手模式：屏幕左右点击都是下一页
  bool _singleHand = false;
  /// 漫画点击九宫格（C8）：9 格动作（TapAction.index），空 = 默认三列
  List<int> _mangaTapZones = const [];
  List<int> get mangaTapZones => _mangaTapZones;
  /// 屏幕休眠：'default' 跟随系统 / '10min' / 'never'
  String _screenSleep = 'default';

  /// 阅读背景样式：0纯白 / 1纸白 / 2米黄 / 3暗夜 / 4纯黑
  int _readerBackgroundStyle = 3;

  /// 漫画阅读器边距（参考 cmbok「边距」tab）
  ///
  /// 用户 2026-10-18：「漫画为啥不是全屏那种？感觉只有中间这一段」
  /// ⇒ **默认边距改为 0**（图片贴屏幕左右边缘）；想留白仍可在
  /// 「阅读设置 → 边距」里自己调大。
  double _comicHeaderLeft = 0;
  double _comicHeaderRight = 0;
  double _comicHeaderTop = 0;
  double _comicFooterLeft = 0;
  double _comicFooterRight = 0;
  double _comicFooterBottom = 0;
  /// 端侧 AI 漫画超分设置（仅 UI 面板，不做真实推理）
  bool _upscaleAutoClean = false;
  double _upscaleCleanLimitGb = 1.0;
  int _upscaleDenoise = 0; // 0 保守 / 1 中等 / 2 强力
  bool _upscaleModelDownloaded = false;
  /// 漫画在线阅读满 N 话后自动加入「正在读」
  bool _autoAddShelfForManga = false;
  /// 图书在线阅读满 N 章后自动加入「正在读」
  bool _autoAddShelfForBook = false;
  /// 书架排序方式。
  ///
  /// 取值（与用户截图的排序面板一一对应）：
  ///   `default` 默认 / `title` 书名 / `author` 作者 /
  ///   `added` 加入时间 / `recent` 最近阅读 / `progress` 阅读进度
  String _shelfSort = 'default';

  /// 排序方向：false = 倒序（默认，新→旧 / Z→A）；true = 正序
  bool _shelfSortAsc = false;

  /// 是否对所有书架都应用（截图里那个「全局」开关）
  ///
  /// 关闭时只对**当前书架**生效。这里用一个 bool 简化：
  /// true = 所有书架同一套排序；false = 也只影响当前书架
  /// （每书架独立存排序的成本较高，而用户几乎不会逐架设不同排序）。
  bool _shelfSortGlobal = true;

  /// 被隐藏的书架 id。
  ///
  /// ⚠️ 预设书架（正在读/想读/已读完/已下载）**也能隐藏** ——
  /// 用户截图里「正在读」的眼睛就是划线态。
  /// 一开始我做成"预设不可隐藏"，与截图不符。
  Set<String> _hiddenShelfIds = {};

  /// 从书架移除时是否同时删除本地文件（含导入的原文件）
  bool _shelfRemoveDeletesFile = false;
  int _pomodoroLoopCount = defaultPomodoroLoopCount; // 番茄钟循环次数
  int _pomodoroRestMinutes = defaultPomodoroRestMinutes; // 番茄钟每轮休息分钟

  int get maxConcurrentChapters => _maxConcurrentChapters;
  int get maxConcurrentImages => _maxConcurrentImages;
  ReadingMode get readingMode => _readingMode;
  BookReadingMode get bookReadingMode => _bookReadingMode;
  String? get downloadSavePath => _downloadSavePath;
  bool get mergeChapterToEpub => _mergeChapterToEpub;
  bool get keepImagesAfterEpub => _keepImagesAfterEpub;
  int get mergeChaptersPerEpub => _mergeChaptersPerEpub;
  bool get trimWhitespace => _trimWhitespace;
  bool get backgroundDownload => _backgroundDownload;
  bool get wifiOnlyDownload => _wifiOnlyDownload;
  int get bookSourceConcurrency => _bookSourceConcurrency;
  int get bookFileConcurrency => _bookFileConcurrency;
  int get onlineBookCacheGb => _onlineBookCacheGb;
  int get onlineComicCacheGb => _onlineComicCacheGb;
  bool get pauseMergeOnError => _pauseMergeOnError;
  bool get protectFullBookCache => _protectFullBookCache;
  DefaultHomePage get defaultHomePage => _defaultHomePage;
  bool get useBuiltinAccount => _useBuiltinAccount;
  bool get globalProxyEnabled => _globalProxyEnabled;

  /// 只对规则里的域名走代理（Webhtv → APP 代理）。false = 全部走代理（原行为）
  bool get proxyDomainOnly => _proxyDomainOnly;

  /// 代理域名规则（`*.example.com` / `example.com`，也容忍粘贴整条 URL）
  List<String> get proxyDomainRules => List.unmodifiable(_proxyDomainRules);
  String get globalProxy => _globalProxy;
  bool get autoSyncBackup => _autoSyncBackup;
  bool get isDarkMode => _themeFollowSystem
      ? (PlatformDispatcher.instance.platformBrightness == Brightness.dark)
      : _isDarkMode;
  bool get themeFollowSystem => _themeFollowSystem;
  String get themePreset => _themePreset;

  /// 「我的」页头像：'' = 默认图标；'aNN' = 内置素材；'custom' = 相册上传
  String get readerAvatar => _readerAvatar;

  /// 上传头像的本地绝对路径（[readerAvatar] == 'custom' 时才有效）
  String get readerAvatarPath => _readerAvatarPath;
  bool get backgroundAnimation => _backgroundAnimation;
  bool get frameRateReduced => _frameRateReduced;
  List<ThemePresetInfo> get customThemes => List.unmodifiable(_customThemes);

  /// 当前主题信息（内置或自定义），未知 id 兜底 jelly；供 UI 显示主题名。
  ThemePresetInfo get currentThemeInfo {
    for (final t in _customThemes) {
      if (t.id == _themePreset) return t;
    }
    return themePresets.firstWhere(
      (p) => p.id == _themePreset,
      orElse: () => themePresets.first,
    );
  }

  /// 当前生效的背景配置：内置预设恒为其自身动画（保持原有行为）；自定义主题
  /// 返回其 [ThemeBackground]；未知 id 回退纯色。渲染层据此决定画动画/图片/纯色。
  ThemeBackground get currentBackground {
    switch (_themePreset) {
      case 'ink':
      case 'jelly':
      case 'pink':
      case 'green':
      case 'ocean':
      case 'sunset':
      case 'sky':
        return ThemeBackground.animation(_themePreset);
      default:
        for (final t in _customThemes) {
          if (t.id == _themePreset) return t.background;
        }
        return const ThemeBackground.none();
    }
  }

  /// 外部解析用：若 [id] 是已保存的自定义主题，返回它的调色板；否则 null。
  ///
  /// `JellyPalette.fromPreset` 不认识 `custom_*`，会回退成「魅力紫」——
  /// 影视/音乐「跟随阅读」时会因此变紫，所以由 main.dart 把它注入
  /// [ModuleThemeStore.customPaletteResolver]。
  JellyPalette? customPaletteOrNull(String id) {
    for (final t in _customThemes) {
      if (t.id == id) return t.palette;
    }
    return null;
  }

  /// 按 id 解析调色板：先查自定义，再回退内置 fromPreset。
  JellyPalette _resolvePalette(String id) {
    for (final t in _customThemes) {
      if (t.id == id) return t.palette;
    }
    return JellyPalette.fromPreset(id);
  }

  int get preloadImageCount => _preloadImageCount;
  double get bookFontSize => _bookFontSize;
  double get bookLineHeight => _bookLineHeight;
  double get pageCurlShadow => _pageCurlShadow;
  int get pageCurlQuality => _pageCurlQuality;
  bool get pageCurlTexture => _pageCurlTexture;
  double get bookHorizontalPadding => _bookHorizontalPadding;
  double get bookVerticalPadding => _bookVerticalPadding;
  String? get bookFontFamily => _bookFontFamily;
  List<NavTab> get visibleNavTabs => List.unmodifiable(_visibleNavTabs);
  bool get navFloating => _navFloating;
  bool get navIconOnly => _navIconOnly;
  String get navStyle => _navStyle;

  /// 悬浮底栏不透明度（0.30~1.0，1.0 = 完全不透）
  double get navBarOpacity => _navBarOpacity;

  /// 自定义底栏图标（tab 标签 → 图片路径）。
  Map<String, String> get navCustomIcons => Map.unmodifiable(_navCustomIcons);

  /// 某个 tab 是否上传了自定义图标；没有返回 null。
  String? navIconFor(String label) => _navCustomIcons[label];
  bool get pageTabsFollowNav => _pageTabsFollowNav;
  HomeBannerStyle get homeBannerStyle => _homeBannerStyle;
  PageDefaultContent get pageDefaultContent => _pageDefaultContent;
  bool get reverseTap => _reverseTap;
  bool get doublePage => _doublePage;
  bool get showReaderHud => _showReaderHud;
  bool get volumeKeyTurn => _volumeKeyTurn;
  bool get checkShelfUpdateOnStart => _checkShelfUpdateOnStart;
  bool get rememberZoom => _rememberZoom;
  bool get pinchZoom => _pinchZoom;
  bool get singleHand => _singleHand;
  String get screenSleep => _screenSleep;
  int get readerBackgroundStyle => _readerBackgroundStyle;
  double get comicHeaderLeft => _comicHeaderLeft;
  double get comicHeaderRight => _comicHeaderRight;
  double get comicHeaderTop => _comicHeaderTop;
  double get comicFooterLeft => _comicFooterLeft;
  double get comicFooterRight => _comicFooterRight;
  double get comicFooterBottom => _comicFooterBottom;
  bool get upscaleAutoClean => _upscaleAutoClean;
  double get upscaleCleanLimitGb => _upscaleCleanLimitGb;
  int get upscaleDenoise => _upscaleDenoise;
  bool get upscaleModelDownloaded => _upscaleModelDownloaded;
  bool get autoAddShelfForManga => _autoAddShelfForManga;
  bool get autoAddShelfForBook => _autoAddShelfForBook;
  String get shelfSort => _shelfSort;
  bool get shelfSortAsc => _shelfSortAsc;
  bool get shelfSortGlobal => _shelfSortGlobal;
  Set<String> get hiddenShelfIds => Set.unmodifiable(_hiddenShelfIds);
  bool isShelfHidden(String id) => _hiddenShelfIds.contains(id);
  bool get shelfRemoveDeletesFile => _shelfRemoveDeletesFile;
  bool get inkScreenMode => _inkScreenMode;
  /// 漫画阅读器页面亮度（独立叠加层，不调系统亮度；0.35~1.0）
  double get comicBrightness => _comicBrightness;
  int get pomodoroLoopCount => _pomodoroLoopCount;
  int get pomodoroRestMinutes => _pomodoroRestMinutes;

  /// 收藏/书架/下载三页的有效内容 tab 顺序（受 pageTabsFollowNav + visibleNavTabs 影响）。
  /// 跟随开关关：[漫画, 图书]；开：取 visibleNavTabs 中的漫画/图书（按固定顺序）；
  /// 若两者都被隐藏，强制保留默认内容 tab，保证页面始终可用。
  List<NavTab> effectiveContentTabs() {
    if (!pageTabsFollowNav) return const [NavTab.manga, NavTab.book];
    final visible = _visibleNavTabs.toSet();
    final tabs = <NavTab>[];
    if (visible.contains(NavTab.manga)) tabs.add(NavTab.manga);
    if (visible.contains(NavTab.book)) tabs.add(NavTab.book);
    if (tabs.isEmpty) {
      tabs.add(
        pageDefaultContent == PageDefaultContent.manga
            ? NavTab.manga
            : NavTab.book,
      );
    }
    return tabs;
  }

  /// 三页默认 tab index：pageDefaultContent 在有效 tabs 中的位置，不可见则 0。
  int defaultContentTabIndex() {
    final tabs = effectiveContentTabs();
    final want = pageDefaultContent == PageDefaultContent.manga
        ? NavTab.manga
        : NavTab.book;
    final idx = tabs.indexOf(want);
    return idx >= 0 ? idx : 0;
  }

  /// 图书正文字体由阅读模式派生：仿真翻页用水墨楷体，普通翻页用系统默认。
  /// 切换模式时自动联动，无需独立持久化。
  String? get bookFontFamilyName =>
      _bookReadingMode == BookReadingMode.simulation ? 'inkReadingKai' : null;

  /// 初始化：从本地加载设置
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _maxConcurrentChapters = _clamp(
        prefs.getInt(_chaptersKey) ?? defaultConcurrentChapters,
        minConcurrentChapters,
        maxConcurrentChaptersLimit,
      );
      _maxConcurrentImages = _clamp(
        prefs.getInt(_imagesKey) ?? defaultConcurrentImages,
        minConcurrentImages,
        maxConcurrentImagesLimit,
      );
      final modeIdx = prefs.getInt(_readingModeKey);
      if (modeIdx != null &&
          modeIdx >= 0 &&
          modeIdx < ReadingMode.values.length) {
        _readingMode = ReadingMode.values[modeIdx];
      }
      final brmIdx = prefs.getInt(_kBookReadingModeKey);
      if (brmIdx != null &&
          brmIdx >= 0 &&
          brmIdx < BookReadingMode.values.length) {
        _bookReadingMode = BookReadingMode.values[brmIdx];
      }
      _downloadSavePath = prefs.getString(_savePathKey);
      _mergeChapterToEpub = prefs.getBool(_mergeEpubKey) ?? true;
      _keepImagesAfterEpub = prefs.getBool(_keepImagesKey) ?? true;
      _trimWhitespace = prefs.getBool(_trimWhitespaceKey) ?? false;
      _mergeChaptersPerEpub =
          prefs
              .getInt(_mergeChaptersCountKey)
              ?.clamp(minMergeChaptersPerEpub, maxMergeChaptersPerEpub) ??
          1;
      _backgroundDownload = prefs.getBool(_kBackgroundDownloadKey) ?? true;
      _wifiOnlyDownload = prefs.getBool(_kWifiOnlyKey) ?? false;
      _bookSourceConcurrency = _clamp(
        prefs.getInt(_kBookSourceConcurrencyKey) ?? defaultBookSourceConcurrency,
        minBookSourceConcurrency,
        maxBookSourceConcurrency,
      );
      _bookFileConcurrency = _clamp(
        prefs.getInt(_kBookFileConcurrencyKey) ?? defaultBookFileConcurrency,
        minBookFileConcurrency,
        maxBookFileConcurrency,
      );
      _onlineBookCacheGb = _clamp(
        prefs.getInt(_kOnlineBookCacheKey) ?? defaultOnlineCacheGb,
        minOnlineCacheGb,
        maxOnlineCacheGb,
      );
      _onlineComicCacheGb = _clamp(
        prefs.getInt(_kOnlineComicCacheKey) ?? defaultOnlineCacheGb,
        minOnlineCacheGb,
        maxOnlineCacheGb,
      );
      _pauseMergeOnError = prefs.getBool(_kPauseMergeOnErrorKey) ?? false;
      _protectFullBookCache = prefs.getBool(_kProtectFullBookKey) ?? true;
      // 默认首页：v1 枚举顺序为 漫画/图书/收藏/书架/我的，v2 将书架与收藏互换。
      // v1 按下标持久化，换序后需按下标还原旧 tab 再映射到新枚举，避免老用户默认首页错位。
      final navOrderVersion = prefs.getInt(_kNavOrderVersionKey) ?? 1;
      final homeIdx = prefs.getInt(_defaultHomeKey);
      if (navOrderVersion < 2) {
        const v1Order = <NavTab>[
          NavTab.manga,
          NavTab.book,
          NavTab.favorites,
          NavTab.bookshelf,
          NavTab.me,
        ];
        final migrated =
            (homeIdx != null && homeIdx >= 0 && homeIdx < v1Order.length)
            ? v1Order[homeIdx].toDefaultHomePage()
            : DefaultHomePage.manga;
        _defaultHomePage = migrated;
        await prefs.setInt(_defaultHomeKey, migrated.index);
        await prefs.setInt(_kNavOrderVersionKey, 2);
      } else {
        _defaultHomePage =
            (homeIdx != null &&
                homeIdx >= 0 &&
                homeIdx < DefaultHomePage.values.length)
            ? DefaultHomePage.values[homeIdx]
            : DefaultHomePage.manga;
      }
      _useBuiltinAccount = prefs.getBool(_kBuiltinAccountKey) ?? true;
      _globalProxyEnabled =
          prefs.getBool(_kGlobalProxyEnabledKey) ?? false;
      _globalProxy = prefs.getString(_kGlobalProxyKey) ?? '';
      _proxyDomainOnly = prefs.getBool(_kProxyDomainOnlyKey) ?? false;
      _proxyDomainRules =
          prefs.getStringList(_kProxyDomainRulesKey) ?? const <String>[];
      _autoSyncBackup = prefs.getBool(_kAutoSyncKey) ?? false;
      // 暗色模式：有记录用记录，否则首次跟随系统
      _isDarkMode =
          prefs.getBool(_kDarkModeKey) ??
          (PlatformDispatcher.instance.platformBrightness == Brightness.dark);
      // 主题跟随系统：默认开启；开启时 isDarkMode 取系统明暗，并实时响应系统切换
      _themeFollowSystem = prefs.getBool(_kThemeFollowSystemKey) ?? true;
      // 自定义主题：JSON 解析，坏条目跳过（韧性，不阻断启动）
      _customThemes = _loadCustomThemes(prefs.getString(_kCustomThemesKey));
      // 主题预设：默认 jelly；加载后立即应用到 JellyTheme（runApp 前，冷启动即生效）
      _themePreset = prefs.getString(_kThemePresetKey) ?? 'ink';
      // 若存的主题已被删除，回退 jelly
      if (!_isKnownPreset(_themePreset)) _themePreset = 'ink';
      JellyTheme.apply(_resolvePalette(_themePreset));
      // 头像：'' 默认 / 'aNN' 内置 / 'custom' 上传（路径另存）
      _readerAvatar = prefs.getString(_kReaderAvatarKey) ?? '';
      _readerAvatarPath = prefs.getString(_kReaderAvatarPathKey) ?? '';
      _backgroundAnimation = prefs.getBool(_kBgAnimationKey) ?? true;
      _frameRateReduced = prefs.getBool(_kFrameRateReducedKey) ?? true;
      _preloadImageCount = _clamp(
        prefs.getInt(_preloadKey) ?? defaultPreloadImages,
        minPreloadImages,
        maxPreloadImages,
      );
      _pomodoroLoopCount = _clamp(
        prefs.getInt(_kPomodoroLoopCountKey) ?? defaultPomodoroLoopCount,
        minPomodoroLoopCount,
        maxPomodoroLoopCount,
      );
      _pomodoroRestMinutes = _clamp(
        prefs.getInt(_kPomodoroRestMinutesKey) ?? defaultPomodoroRestMinutes,
        minPomodoroRestMinutes,
        maxPomodoroRestMinutes,
      );
      _bookFontSize = _clampDouble(
        prefs.getDouble(_kBookFontSizeKey) ?? defaultBookFontSize,
        minBookFontSize,
        maxBookFontSize,
      );
      _bookLineHeight = _clampDouble(
        prefs.getDouble(_kBookLineHeightKey) ?? defaultBookLineHeight,
        minBookLineHeight,
        maxBookLineHeight,
      );
      _pageCurlShadow = _clampDouble(
        prefs.getDouble(_kPageCurlShadowKey) ?? 0.75,
        0.0,
        1.0,
      );
      _pageCurlQuality =
          (prefs.getInt(_kPageCurlQualityKey) ?? 1).clamp(0, 2);
      _pageCurlTexture = prefs.getBool(_kPageCurlTextureKey) ?? true;
      _bookHorizontalPadding = _clampDouble(
        prefs.getDouble(_kBookHorizontalPaddingKey) ??
            defaultBookHorizontalPadding,
        minBookHorizontalPadding,
        maxBookHorizontalPadding,
      );
      _bookVerticalPadding = _clampDouble(
        prefs.getDouble(_kBookVerticalPaddingKey) ?? defaultBookVerticalPadding,
        minBookVerticalPadding,
        maxBookVerticalPadding,
      );
      // 图书正文字体偏好（null/空字符串均视为未设置 = 跟随阅读模式）。
      final savedFont = prefs.getString(_kBookFontFamilyKey);
      _bookFontFamily = (savedFont == null || savedFont.isEmpty)
          ? null
          : savedFont;
      // 导航栏悬浮开关
      _navFloating = prefs.getBool(_kNavFloatingKey) ?? true;
      _navIconOnly = prefs.getBool(_kNavIconOnlyKey) ?? false;
      // 悬浮底栏风格 + 自定义图标
      _navStyle = prefs.getString(_kNavStyleKey) ?? 'ink';
      final navOp = prefs.getDouble(_kNavBarOpacityKey);
      _navBarOpacity = (navOp == null || navOp < 0.3 || navOp > 1.0)
          ? 0.95
          : navOp;
      final iconsRaw = prefs.getString(_kNavCustomIconsKey);
      if (iconsRaw != null && iconsRaw.isNotEmpty) {
        try {
          final decoded = jsonDecode(iconsRaw);
          if (decoded is Map) {
            _navCustomIcons
              ..clear()
              ..addAll(decoded.map(
                (k, v) => MapEntry('$k', '$v'),
              ));
          }
        } catch (e) {
          _log('读取自定义底栏图标失败: $e');
        }
      }
      // 书架/收藏 卡片外观（显示设置，2026-10-15）
      _listDensity = (prefs.getInt(_kListDensityKey) ?? 1).clamp(0, 2);
      _coverRadius = (prefs.getInt(_kCoverRadiusKey) ?? 1).clamp(0, 2);
      _cardInfo = prefs.getBool(_kCardInfoKey) ?? true;
      // 当前漫画源
      // 🔴 历史版本这里默认值硬编码成 'copymanga'：拷贝漫画在内置源列表里只排第
      // 14 个，从没主动选过源的用户打开漫画也被钉在拷贝，而不是列表第一个源。
      // 一次性迁移：老用户保存值若恰好是历史默认值 copymanga，清掉它，让
      // SourceManager 回退到「第一个启用源」；迁移只跑一次，之后用户手动选的源
      // （包括主动再选回拷贝）都会照常持久化。
      if (prefs.getBool(_kMangaDefaultMigratedKey) != true) {
        if (prefs.getString(_currentSourceKey) == 'copymanga') {
          await prefs.remove(_currentSourceKey);
        }
        await prefs.setBool(_kMangaDefaultMigratedKey, true);
      }
      _currentSourceId = prefs.getString(_currentSourceKey) ?? '';
      // 禁用漫画源列表
      _disabledSourceIds = prefs.getStringList(_disabledSourceIdsKey) ?? [];
      // 漫画源自定义顺序（长按源标签拖动后的顺序）
      _mangaSourceOrder =
          prefs.getStringList(_mangaSourceOrderKey) ?? const [];
      // 漫画源仓库云端 URL
      _sourceRepoUrl = prefs.getString(_sourceRepoUrlKey) ?? '';
      // 导航栏可见 tab
      final visibleTabNames = prefs.getStringList(_kNavVisibleTabsKey);
      if (visibleTabNames != null && visibleTabNames.isNotEmpty) {
        final parsed = <NavTab>[];
        for (final name in visibleTabNames) {
          final tab = NavTab.values.where((t) => t.name == name).firstOrNull;
          if (tab != null) parsed.add(tab);
        }
        _visibleNavTabs = _sanitizeVisibleNavTabs(parsed);
      }
      // 收藏/书架/下载页 tab 跟随导航栏
      _pageTabsFollowNav = prefs.getBool(_kPageTabsFollowNavKey) ?? true;
      // 首页幻灯片样式：新数据存 **name**（字符串）。
      // 老数据存的是 index（int）→ 走 kLegacyHomeBannerOrder 迁移一次，
      // 否则在中间删/加样式时老用户选中的样式会悄悄漂到另一种。
      final hbsName = prefs.getString(_kHomeBannerStyleKey);
      if (hbsName != null) {
        for (final st in HomeBannerStyle.values) {
          if (st.name == hbsName) {
            _homeBannerStyle = st;
            break;
          }
        }
      } else {
        final hbsIdx = prefs.getInt(_kHomeBannerStyleKey);
        if (hbsIdx != null) {
          _homeBannerStyle = homeBannerStyleFromLegacyIndex(hbsIdx);
        }
      }
      final pdcIdx = prefs.getInt(_kPageDefaultContentKey);
      if (pdcIdx != null &&
          pdcIdx >= 0 &&
          pdcIdx < PageDefaultContent.values.length) {
        _pageDefaultContent = PageDefaultContent.values[pdcIdx];
      }
      _reverseTap = prefs.getBool(_kReverseTapKey) ?? false;
      _doublePage = prefs.getBool(_kDoublePageKey) ?? false;
      _showReaderHud = prefs.getBool(_kShowReaderHudKey) ?? true;
      _volumeKeyTurn = prefs.getBool(_kVolumeKeyTurnKey) ?? false;
    _checkShelfUpdateOnStart =
        prefs.getBool(_kCheckShelfUpdateKey) ?? false;
    _rememberZoom = prefs.getBool(_kRememberZoomKey) ?? false;
    _pinchZoom = prefs.getBool(_kPinchZoomKey) ?? true;
    _singleHand = prefs.getBool(_kSingleHandKey) ?? false;
    final zonesRaw = prefs.getString(_kMangaTapZonesKey);
    if (zonesRaw != null) {
      try {
        final list = jsonDecode(zonesRaw) as List;
        _mangaTapZones = list
            .whereType<num>()
            .map((e) => e.toInt().clamp(0, 3))
            .toList();
        if (_mangaTapZones.length != 9) _mangaTapZones = const [];
      } catch (_) {
        _mangaTapZones = const [];
      }
    }
    _screenSleep = prefs.getString(_kScreenSleepKey) ?? 'default';
    _readerBackgroundStyle = _clamp(
      prefs.getInt(_kReaderBackgroundStyleKey) ?? 3,
      0,
      4,
    );
    final marginRaw = prefs.getString(_kComicMarginKey);
    if (marginRaw != null) {
      try {
        final m = jsonDecode(marginRaw) as Map<String, dynamic>;
        _comicHeaderLeft = asDoubleOrNull(m['hl']) ?? 0;
        _comicHeaderRight = asDoubleOrNull(m['hr']) ?? 0;
        _comicHeaderTop = asDoubleOrNull(m['ht']) ?? 0;
        _comicFooterLeft = asDoubleOrNull(m['fl']) ?? 0;
        _comicFooterRight = asDoubleOrNull(m['fr']) ?? 0;
        _comicFooterBottom = asDoubleOrNull(m['fb']) ?? 0;
      } catch (_) {}
    }
    // 2026-10-18：老默认边距（16/16/8）一次性改成 0 —— 用户没主动改过时
    // 图片会一直缩在中间（"感觉只有中间这一段"）。主动改过的自定义值不动。
    if (prefs.getBool(_kComicMarginFullscreenKey) != true) {
      if (_comicHeaderLeft == 16 &&
          _comicHeaderRight == 16 &&
          _comicHeaderTop == 8 &&
          _comicFooterLeft == 16 &&
          _comicFooterRight == 16 &&
          _comicFooterBottom == 8) {
        _comicHeaderLeft = 0;
        _comicHeaderRight = 0;
        _comicHeaderTop = 0;
        _comicFooterLeft = 0;
        _comicFooterRight = 0;
        _comicFooterBottom = 0;
      }
      await prefs.setBool(_kComicMarginFullscreenKey, true);
    }
    _autoAddShelfForManga =
        prefs.getBool(_kAutoAddShelfKey) ?? false;
    _autoAddShelfForBook =
        prefs.getBool(_kAutoAddShelfForBookKey) ?? false;
    _upscaleAutoClean = prefs.getBool(_kUpscaleAutoCleanKey) ?? false;
    _upscaleCleanLimitGb = _clampDouble(
      asDoubleOrNull(prefs.getDouble(_kUpscaleCleanLimitKey)) ?? 1.0,
      0.1,
      10,
    );
    _upscaleDenoise = _clamp(
      prefs.getInt(_kUpscaleDenoiseKey) ?? 0,
      0,
      2,
    );
    _upscaleModelDownloaded =
        prefs.getBool(_kUpscaleModelDownloadedKey) ?? false;
    _shelfSort = prefs.getString(_kShelfSortKey) ?? 'default';
    _shelfSortAsc = prefs.getBool(_kShelfSortAscKey) ?? false;
    _shelfSortGlobal = prefs.getBool(_kShelfSortGlobalKey) ?? true;
    _hiddenShelfIds =
        (prefs.getStringList(_kHiddenShelfIdsKey) ?? const []).toSet();
    _shelfRemoveDeletesFile =
        prefs.getBool(_kRemoveDeletesFileKey) ?? false;
      _inkScreenMode = prefs.getBool(_kInkScreenModeKey) ?? false;
      _comicBrightness =
          (prefs.getDouble(_kComicBrightnessKey) ?? 1.0).clamp(0.35, 1.0);
      // 若默认首页不在可见列表中，自动修正到第一个可见
      if (!_visibleNavTabs.any((t) => t == _defaultHomePage.toNavTab())) {
        _defaultHomePage = _visibleNavTabs.first.toDefaultHomePage();
      }
      _log(
        '设置加载: 同时下载量=$_maxConcurrentChapters, 分片并发=$_maxConcurrentImages, '
        '漫画阅读模式=$_readingMode, 图书阅读模式=$_bookReadingMode, 保存路径=${_downloadSavePath ?? "默认"}, '
        '合并EPUB=$_mergeChapterToEpub, 合并话数=$_mergeChaptersPerEpub, 保留图片=$_keepImagesAfterEpub, '
        '默认首页=$_defaultHomePage, 内置账号=$_useBuiltinAccount, 暗色模式=$_isDarkMode, 跟随系统=$_themeFollowSystem, 主题预设=$_themePreset, 预加载=$_preloadImageCount, '
        '图书排版: 字号=$_bookFontSize 行距=$_bookLineHeight 左右边距=$_bookHorizontalPadding 上下边距=$_bookVerticalPadding, '
        '翻页反转=$_reverseTap, 双页=$_doublePage, 信息栏=$_showReaderHud, 音量键翻页=$_volumeKeyTurn, 墨水屏=$_inkScreenMode',
      );
    } catch (e) {
      _log('加载设置失败: $e');
    }
    // 系统明暗变化时，若处于"跟随系统"则通知 UI 实时刷新（触发既有主题切换动画）
    PlatformDispatcher.instance.onPlatformBrightnessChanged = () {
      if (_themeFollowSystem) notifyListeners();
    };
    notifyListeners();
  }

  /// 设置同时下载量（自动 clamp）
  Future<void> setMaxConcurrentChapters(int value) async {
    final clamped = _clamp(
      value,
      minConcurrentChapters,
      maxConcurrentChaptersLimit,
    );
    if (_maxConcurrentChapters == clamped) return;
    _maxConcurrentChapters = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_chaptersKey, clamped);
    } catch (e) {
      _log('保存同时下载量失败: $e');
    }
  }

  /// 设置番茄钟循环次数（自动 clamp）
  Future<void> setPomodoroLoopCount(int value) async {
    final clamped = _clamp(value, minPomodoroLoopCount, maxPomodoroLoopCount);
    if (_pomodoroLoopCount == clamped) return;
    _pomodoroLoopCount = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPomodoroLoopCountKey, clamped);
    } catch (e) {
      _log('保存番茄钟循环次数失败: $e');
    }
  }

  /// 设置番茄钟每轮休息分钟（自动 clamp）
  Future<void> setPomodoroRestMinutes(int value) async {
    final clamped = _clamp(
      value,
      minPomodoroRestMinutes,
      maxPomodoroRestMinutes,
    );
    if (_pomodoroRestMinutes == clamped) return;
    _pomodoroRestMinutes = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPomodoroRestMinutesKey, clamped);
    } catch (e) {
      _log('保存番茄钟休息分钟失败: $e');
    }
  }

  /// 设置分片并发量（自动 clamp）
  Future<void> setMaxConcurrentImages(int value) async {
    final clamped = _clamp(
      value,
      minConcurrentImages,
      maxConcurrentImagesLimit,
    );
    if (_maxConcurrentImages == clamped) return;
    _maxConcurrentImages = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_imagesKey, clamped);
    } catch (e) {
      _log('保存分片并发量失败: $e');
    }
  }

  /// 设置阅读模式（翻页 / 拼页）
  Future<void> setReadingMode(ReadingMode mode) async {
    if (_readingMode == mode) return;
    _readingMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_readingModeKey, mode.index);
    } catch (e) {
      _log('保存阅读模式失败: $e');
    }
  }

  /// 设置图书阅读模式（翻页 / 仿真 / 覆盖）
  Future<void> setBookReadingMode(BookReadingMode mode) async {
    if (_bookReadingMode == mode) return;
    _bookReadingMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kBookReadingModeKey, mode.index);
    } catch (e) {
      _log('保存图书阅读模式失败: $e');
    }
  }

  /// 设置下载保存位置（null/空 = 默认应用私有目录）
  Future<void> setDownloadSavePath(String? value) async {
    final v = (value != null && value.trim().isEmpty) ? null : value;
    if (_downloadSavePath == v) return;
    _downloadSavePath = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (v == null) {
        await prefs.remove(_savePathKey);
      } else {
        await prefs.setString(_savePathKey, v);
      }
    } catch (e) {
      _log('保存下载位置失败: $e');
    }
  }

  /// 设置：漫画下载时是否去白边
  Future<void> setTrimWhitespace(bool value) async {
    if (_trimWhitespace == value) return;
    _trimWhitespace = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_trimWhitespaceKey, value);
    } catch (e) {
      _log('保存去白边开关失败: $e');
    }
  }

  Future<void> setBackgroundDownload(bool value) async {
    if (_backgroundDownload == value) return;
    _backgroundDownload = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kBackgroundDownloadKey, value);
    } catch (e) {
      _log('保存后台下载开关失败: $e');
    }
  }

  Future<void> setWifiOnlyDownload(bool value) async {
    if (_wifiOnlyDownload == value) return;
    _wifiOnlyDownload = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kWifiOnlyKey, value);
    } catch (e) {
      _log('保存仅WiFi下载开关失败: $e');
    }
  }

  Future<void> setBookSourceConcurrency(int value) async {
    final v = _clamp(
      value,
      minBookSourceConcurrency,
      maxBookSourceConcurrency,
    );
    if (_bookSourceConcurrency == v) return;
    _bookSourceConcurrency = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kBookSourceConcurrencyKey, v);
    } catch (e) {
      _log('保存书源并发量失败: $e');
    }
  }

  Future<void> setBookFileConcurrency(int value) async {
    final v = _clamp(value, minBookFileConcurrency, maxBookFileConcurrency);
    if (_bookFileConcurrency == v) return;
    _bookFileConcurrency = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kBookFileConcurrencyKey, v);
    } catch (e) {
      _log('保存图书文件并发量失败: $e');
    }
  }

  Future<void> setOnlineBookCacheGb(int value) async {
    final v = _clamp(value, minOnlineCacheGb, maxOnlineCacheGb);
    if (_onlineBookCacheGb == v) return;
    _onlineBookCacheGb = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kOnlineBookCacheKey, v);
    } catch (e) {
      _log('保存在线书缓存上限失败: $e');
    }
  }

  Future<void> setOnlineComicCacheGb(int value) async {
    final v = _clamp(value, minOnlineCacheGb, maxOnlineCacheGb);
    if (_onlineComicCacheGb == v) return;
    _onlineComicCacheGb = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kOnlineComicCacheKey, v);
    } catch (e) {
      _log('保存在线漫画缓存上限失败: $e');
    }
  }

  Future<void> setPauseMergeOnError(bool value) async {
    if (_pauseMergeOnError == value) return;
    _pauseMergeOnError = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPauseMergeOnErrorKey, value);
    } catch (e) {
      _log('保存失败暂停合并开关失败: $e');
    }
  }

  Future<void> setProtectFullBookCache(bool value) async {
    if (_protectFullBookCache == value) return;
    _protectFullBookCache = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kProtectFullBookKey, value);
    } catch (e) {
      _log('保存缓存全本保护开关失败: $e');
    }
  }

  /// 设置：漫画章节下载是否合并成 EPUB
  Future<void> setMergeChapterToEpub(bool value) async {
    if (_mergeChapterToEpub == value) return;
    _mergeChapterToEpub = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_mergeEpubKey, value);
    } catch (e) {
      _log('保存合并EPUB开关失败: $e');
    }
  }

  /// 设置：合并 EPUB 后是否保留原始图片（用于 App 内离线阅读）
  Future<void> setKeepImagesAfterEpub(bool value) async {
    if (_keepImagesAfterEpub == value) return;
    _keepImagesAfterEpub = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keepImagesKey, value);
    } catch (e) {
      _log('保存保留图片开关失败: $e');
    }
  }

  /// 设置：每 N 话合并为一个 EPUB（1~20）
  Future<void> setMergeChaptersPerEpub(int value) async {
    final clamped = value.clamp(
      minMergeChaptersPerEpub,
      maxMergeChaptersPerEpub,
    );
    if (_mergeChaptersPerEpub == clamped) return;
    _mergeChaptersPerEpub = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_mergeChaptersCountKey, clamped);
    } catch (e) {
      _log('保存合并话数失败: $e');
    }
  }

  /// 设置启动默认首页
  Future<void> setDefaultHomePage(DefaultHomePage value) async {
    if (_defaultHomePage == value) return;
    _defaultHomePage = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_defaultHomeKey, value.index);
    } catch (e) {
      _log('保存默认首页失败: $e');
    }
  }

  /// 设置：图书下载未登录时是否使用内置账号（关闭则下载必须登录；搜索不受影响，未登录一律回退内置账号）
  Future<void> setUseBuiltinAccount(bool value) async {
    if (_useBuiltinAccount == value) return;
    _useBuiltinAccount = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kBuiltinAccountKey, value);
    } catch (e) {
      _log('保存内置账号开关失败: $e');
    }
  }

  /// 设置：全局网络代理开关
  Future<void> setGlobalProxyEnabled(bool value) async {
    if (_globalProxyEnabled == value) return;
    _globalProxyEnabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kGlobalProxyEnabledKey, value);
    } catch (e) {
      _log('保存全局代理开关失败: $e');
    }
  }

  /// 「APP 代理」：是否只对规则里的域名走代理（默认关 = 全部走）
  Future<void> setProxyDomainOnly(bool value) async {
    if (_proxyDomainOnly == value) return;
    _proxyDomainOnly = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kProxyDomainOnlyKey, value);
    } catch (e) {
      _log('保存代理域名开关失败: $e');
    }
  }

  /// 「APP 代理」：整表替换域名规则
  Future<void> setProxyDomainRules(List<String> rules) async {
    _proxyDomainRules =
        rules.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kProxyDomainRulesKey, _proxyDomainRules);
    } catch (e) {
      _log('保存代理域名规则失败: $e');
    }
  }

  /// 域名是否命中代理规则（`*.x.com` / `x.com`；也容忍粘贴整条 URL）
  static bool hostMatchesProxyRules(String host, List<String> rules) {
    final h = host.toLowerCase().trim();
    if (h.isEmpty) return false;
    for (final raw in rules) {
      var p = raw.trim().toLowerCase();
      if (p.isEmpty) continue;
      if (p.contains('://')) p = p.split('://').last;
      if (p.contains('/')) p = p.split('/').first;
      if (p.startsWith('*.')) p = p.substring(2);
      if (p.isEmpty) continue;
      if (h == p || h.endsWith('.$p')) return true;
    }
    return false;
  }

  Future<void> setGlobalProxy(String value) async {
    final v = value.trim();
    if (_globalProxy == v) return;
    _globalProxy = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kGlobalProxyKey, v);
    } catch (e) {
      _log('保存全局代理失败: $e');
    }
  }

  /// 设置：自动同步开关
  Future<void> setAutoSyncBackup(bool value) async {
    if (_autoSyncBackup == value) return;
    _autoSyncBackup = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoSyncKey, value);
    } catch (e) {
      _log('保存自动同步开关失败: $e');
    }
  }

  /// 设置：暗色模式
  Future<void> setDarkMode(bool value) async {
    if (_isDarkMode == value) return;
    _isDarkMode = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kDarkModeKey, value);
    } catch (e) {
      _log('保存暗色模式失败: $e');
    }
    // ── 同步回全局主题存储 ─────────────────────────────────────
    //
    // 🔴 这里原来是 `if (!_themeFollowSystem && !_syncingTheme)`，
    // 而 `_themeFollowSystem` **默认是 true** —— 于是"跟随系统"期间
    // 用户点明暗图标（`reading/pages/me_page.dart` 的月亮/太阳）
    // **永远不会回写全局**：本地值改了、全局还是旧的。
    //
    // 改成"全局唯一真源"后这个 bug 会立刻变成用户可见的
    // ——全局是真源，不回写就等于**点击被静默吞掉**。
    //
    // 现在无论是否跟随系统都回写：跟随系统时把"跟随"这个意图
    // 也一并交给全局（用 ThemeMode.system）。
    if (!_syncingTheme) {
      _syncingTheme = true;
      try {
        await ThemeModeStore.notifyModuleChanged(
          _themeFollowSystem
              ? ThemeMode.system
              : (value ? ThemeMode.dark : ThemeMode.light),
          // 只跳过阅读自己，仍要推给音乐（原来会被整体吞掉）
          origin: GlobalThemeSync.reading,
        );
      } finally {
        _syncingTheme = false;
      }
    }
  }

  /// 防止递归：全局 → 阅读 → 全局
  bool _syncingTheme = false;

  /// 设置：主题背景动画开关
  Future<void> setBackgroundAnimation(bool value) async {
    if (_backgroundAnimation == value) return;
    _backgroundAnimation = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kBgAnimationKey, value);
    } catch (e) {
      _log('保存背景动画开关失败: $e');
    }
  }

  /// 设置：「我的」页头像（'' 默认 / 'aNN' 内置 / 'custom' 上传）。
  ///
  /// [path] 只在 id=='custom' 时传：相册上传后复制到 App 目录的绝对路径。
  Future<void> setReaderAvatar(String id, {String path = ''}) async {
    _readerAvatar = id;
    _readerAvatarPath = path;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kReaderAvatarKey, id);
      await prefs.setString(_kReaderAvatarPathKey, path);
    } catch (e) {
      _log('保存头像失败: $e');
    }
  }

  /// 设置：主题动画降帧省电
  Future<void> setFrameRateReduced(bool value) async {
    if (_frameRateReduced == value) return;
    _frameRateReduced = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kFrameRateReducedKey, value);
    } catch (e) {
      _log('保存降帧开关失败: $e');
    }
  }

  /// 设置：主题是否跟随系统明暗
  /// 关闭时把当前生效的暗色状态固化为手动选择，避免切到手动瞬间跳变。
  Future<void> setThemeFollowSystem(bool value) async {
    if (_themeFollowSystem == value) return;
    if (!value) {
      // 退出跟随系统前，用当前生效（可能来自系统）的状态初始化手动值
      _isDarkMode = isDarkMode;
    }
    _themeFollowSystem = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kThemeFollowSystemKey, value);
      if (!value) {
        await prefs.setBool(_kDarkModeKey, _isDarkMode);
      }
    } catch (e) {
      _log('保存主题跟随系统失败: $e');
    }
    // 同步回全局主题存储（以阅读为基准，阅读变了全局跟着变）
    if (!_syncingTheme) {
      _syncingTheme = true;
      try {
        final mode = value
            ? ThemeMode.system
            : (isDarkMode ? ThemeMode.dark : ThemeMode.light);
        await ThemeModeStore.notifyModuleChanged(mode,
            origin: GlobalThemeSync.reading);
      } finally {
        _syncingTheme = false;
      }
    }
  }

  /// 从全局主题同步进来（统一主题设置页改了明暗时调用）。
  ///
  /// 不走 [setDarkMode] / [setThemeFollowSystem] 避免递归。
  Future<void> applyThemeModeFromGlobal(ThemeMode mode) async {
    if (_syncingTheme) return;
    _syncingTheme = true;
    try {
      final followSystem = mode == ThemeMode.system;
      final dark = switch (mode) {
        ThemeMode.dark => true,
        ThemeMode.light => false,
        ThemeMode.system =>
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark,
      };
      if (_themeFollowSystem == followSystem &&
          _isDarkMode == dark) {
        return;
      }
      _themeFollowSystem = followSystem;
      _isDarkMode = dark;
      notifyListeners();
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kThemeFollowSystemKey, followSystem);
        if (!followSystem) {
          await prefs.setBool(_kDarkModeKey, dark);
        }
      } catch (e) {
        _log('保存主题同步失败: $e');
      }
    } finally {
      _syncingTheme = false;
    }
  }

  /// 设置：主题预设（内置 jelly/pink/green/ocean/sunset/sky，或 custom_* 自定义；
  /// 未知值兜底回 jelly）
  Future<void> setThemePreset(String value) async {
    final v = _isKnownPreset(value) ? value : 'ink';
    if (_themePreset == v) return;
    _themePreset = v;
    JellyTheme.apply(_resolvePalette(v));
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kThemePresetKey, v);
    } catch (e) {
      _log('保存主题预设失败: $e');
    }
    // 同步到 ModuleThemeStore：以阅读为基准，阅读改了
    // 选了"跟随阅读"的模块（影视/音乐默认都是）会跟着变
    syncReadingPresetToModules(v);
  }

  /// id 是否为已知主题（内置预设或已存自定义）。
  ///
  /// 🔴 2026-10-23 修：原来手写 7 个内置 id（ink/jelly/pink/green/ocean/sunset/sky），
  /// 后来新增的 forest、lavender、coffee、sand、四季主题、以及「公认最美的颜色」
  /// 八色（azure/warmSun/…/melo）全都不在白名单里 —— 点选后会被 [setThemePreset]
  /// 改写成 `ink`，用户看到的就是「选了半天没反应」。
  /// 现在改为直接查 [themePresets] 这一唯一来源，以后加主题不用再改这里。
  bool _isKnownPreset(String id) {
    if (themePresets.any((p) => p.id == id)) return true;
    return _customThemes.any((t) => t.id == id);
  }

  /// 新增自定义主题：生成唯一 id，加入列表并持久化；返回新建信息（不自动选中）。
  ///
  /// [background] 默认纯色；图片背景会把源图复制到 app 持久目录，持久化副本路径
  /// （源图在相册/缓存可能被系统清除）。复制失败时该主题降级为纯色，不阻断保存。
  Future<ThemePresetInfo> addCustomTheme({
    required String name,
    required JellyPalette palette,
    ThemeBackground background = const ThemeBackground(),
  }) async {
    final trimmed = name.trim().isEmpty ? '自定义主题' : name.trim();
    final id =
        'custom_${DateTime.now().millisecondsSinceEpoch}_${_customThemes.length}';
    final installed = await _installBackgroundImage(id, _normalize(background));
    final info = ThemePresetInfo(id, trimmed, palette, background: installed);
    _customThemes = [..._customThemes, info];
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCustomThemesKey, _encodeCustomThemes());
    } catch (e) {
      _log('保存自定义主题失败: $e');
    }
    return info;
  }

  /// 更新已有自定义主题（按 id）：name/palette/background 传非 null 才覆盖。
  /// 若更新的是当前选中主题，重新应用调色板（背景由 [currentBackground] 自动反映）。
  /// 图片背景按需复制新图/删除旧图（见 [_reconcileBackgroundImage]）。
  Future<void> updateCustomTheme(
    String id, {
    String? name,
    JellyPalette? palette,
    ThemeBackground? background,
  }) async {
    final idx = _customThemes.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final old = _customThemes[idx];
    final newName = (name == null || name.trim().isEmpty)
        ? old.name
        : name.trim();
    final newPalette = palette ?? old.palette;
    var newBg = old.background;
    if (background != null) {
      newBg = await _reconcileBackgroundImage(
        id,
        old.background,
        _normalize(background),
      );
    }
    final updated = ThemePresetInfo(id, newName, newPalette, background: newBg);
    final list = List<ThemePresetInfo>.of(_customThemes);
    list[idx] = updated;
    _customThemes = list;
    if (_themePreset == id) {
      JellyTheme.apply(newPalette); // 当前主题：重新应用调色板
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCustomThemesKey, _encodeCustomThemes());
    } catch (e) {
      _log('更新自定义主题失败: $e');
    }
  }

  /// 删除自定义主题；若删的正是当前选中，回退 jelly 并触发切换动画。
  Future<void> deleteCustomTheme(String id) async {
    ThemePresetInfo? target;
    for (final t in _customThemes) {
      if (t.id == id) {
        target = t;
        break;
      }
    }
    if (target == null) return;
    // 清理该主题的背景图片副本（best-effort，失败不阻断删除）
    if (target.background.type == ThemeBackgroundType.image &&
        target.background.imagePath != null) {
      await _deleteBackgroundImage(target.background.imagePath!);
    }
    _customThemes = _customThemes.where((t) => t.id != id).toList();
    final wasSelected = _themePreset == id;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCustomThemesKey, _encodeCustomThemes());
    } catch (e) {
      _log('删除自定义主题失败: $e');
    }
    if (wasSelected) {
      // 回退水墨书香：直接改字段+应用，再走持久化（避免 setThemePreset 的相同 id 短路）
      //
      // 🔴 原来写的是 `JellyTheme.apply(const JellyPalette.jelly())` ——
      // id 记成 ink、调色板却是「魅力紫」，于是列表显示选中水墨书香、
      // 实际全 App 是紫的（重启才恢复）。而且没同步影视/音乐。
      _themePreset = 'ink';
      JellyTheme.apply(const JellyPalette.ink());
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kThemePresetKey, 'ink');
      } catch (e) {
        _log('回退主题预设失败: $e');
      }
      syncReadingPresetToModules('ink');
    }
    notifyListeners();
  }

  /// 自定义主题列表序列化为 JSON 字符串。
  String _encodeCustomThemes() {
    return jsonEncode(
      _customThemes
          .map(
            (t) => {
              'id': t.id,
              'name': t.name,
              'colors': t.palette.toMap(),
              'background': t.background.toMap(),
            },
          )
          .toList(),
    );
  }

  /// 从 JSON 字符串解析自定义主题列表；坏条目跳过。
  List<ThemePresetInfo> _loadCustomThemes(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      final result = <ThemePresetInfo>[];
      for (final item in list) {
        if (item is! Map) continue;
        final id = item['id'];
        final name = item['name'];
        final colors = item['colors'];
        if (id is! String || name is! String || colors is! Map) continue;
        try {
          final palette = JellyPalette.fromMap(
            Map<String, dynamic>.from(colors),
          );
          result.add(
            ThemePresetInfo(
              id,
              name,
              palette,
              background: ThemeBackground.fromMap(item['background']),
            ),
          );
        } catch (e) {
          _log('跳过损坏的自定义主题 $id: $e');
        }
      }
      return result;
    } catch (e) {
      _log('解析自定义主题失败: $e');
      return [];
    }
  }

  /// 导出自定义主题为可分享的 JSON 文本（带 version/kind 外壳，便于将来兼容）。
  ///
  /// 不导出 id（导入端重新生成，避免与本地已有 id 冲突）；背景图片只导出路径，
  /// 跨设备导入时该路径不存在会自动降级为纯色（见 [importCustomThemes]）。
  String exportCustomThemes() {
    return const JsonEncoder.withIndent('  ').convert({
      'app': 'New-Tv',
      'kind': 'reading_themes',
      'version': 1,
      'themes': _customThemes
          .map(
            (t) => {
              'name': t.name,
              'colors': t.palette.toMap(),
              'background': t.background.toMap(),
            },
          )
          .toList(),
    });
  }

  /// 导入自定义主题 JSON；返回成功导入的条数（坏条目跳过，不会清掉已有主题）。
  ///
  /// 兼容入参：单主题对象 / 主题数组 / [exportCustomThemes] 的 `{themes:[...]}` 外壳。
  Future<int> importCustomThemes(String raw) async {
    final text = raw.trim();
    if (text.isEmpty) return 0;
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      _log('导入主题失败（JSON 无法解析）: $e');
      return 0;
    }
    List<dynamic> items;
    if (decoded is List) {
      items = decoded;
    } else if (decoded is Map && decoded['themes'] is List) {
      items = decoded['themes'] as List;
    } else if (decoded is Map && decoded['colors'] is Map) {
      items = [decoded];
    } else {
      return 0;
    }
    final added = <ThemePresetInfo>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final item in items) {
      if (item is! Map) continue;
      final colors = item['colors'];
      if (colors is! Map) continue;
      final String name;
      final rawName = item['name'];
      if (rawName is String && rawName.trim().isNotEmpty) {
        name = rawName.trim();
      } else {
        name = '导入主题';
      }
      JellyPalette palette;
      try {
        palette = JellyPalette.fromMap(Map<String, dynamic>.from(colors));
      } catch (e) {
        _log('跳过损坏的导入主题 $name: $e');
        continue;
      }
      var bg = ThemeBackground.fromMap(item['background']);
      // 背景图是「上次导出设备」的绝对路径，本机不存在 → 保留淡化/模糊参数，降级纯色
      if (bg.type == ThemeBackgroundType.image &&
          (bg.imagePath == null || !File(bg.imagePath!).existsSync())) {
        bg = ThemeBackground.none().copyWith(opacity: bg.opacity, blur: bg.blur);
      }
      final id = 'custom_${now}_${_customThemes.length + added.length}';
      added.add(ThemePresetInfo(id, name, palette, background: bg));
    }
    if (added.isEmpty) return 0;
    _customThemes = [..._customThemes, ...added];
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCustomThemesKey, _encodeCustomThemes());
    } catch (e) {
      _log('保存导入主题失败: $e');
    }
    return added.length;
  }

  /// 图片背景副本目录：`<appDocs>/theme_bg/`（不存在则建）。
  Future<Directory> _themeBgDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final d = Directory('${appDir.path}/theme_bg');
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }

  /// 把 [background] 的图片源文件复制到 app 持久目录，返回改写好 imagePath 的配置。
  /// 非 image 类型原样返回；复制失败降级纯色（不阻断保存）。
  Future<ThemeBackground> _installBackgroundImage(
    String id,
    ThemeBackground background,
  ) async {
    if (background.type != ThemeBackgroundType.image ||
        background.imagePath == null) {
      return background;
    }
    try {
      final src = File(background.imagePath!);
      if (!await src.exists()) {
        _log('背景图片源文件不存在，降级纯色: ${background.imagePath}');
        return const ThemeBackground.none().copyWith(
          opacity: background.opacity,
          blur: background.blur,
        );
      }
      final dir = await _themeBgDir();
      final dest = File('${dir.path}/bg_$id.${_pickImageExt(src.path)}');
      await src.copy(dest.path);
      // 只改路径，保留不透明度/模糊等其它字段
      return background.copyWith(imagePath: dest.path);
    } catch (e) {
      _log('复制背景图片失败，降级纯色: $e');
      return const ThemeBackground.none().copyWith(
        opacity: background.opacity,
        blur: background.blur,
      );
    }
  }

  /// 编辑时归一化：image 类型但无 imagePath（未选图）→ 视作纯色，避免存无效配置。
  ThemeBackground _normalize(ThemeBackground bg) =>
      (bg.type == ThemeBackgroundType.image && bg.imagePath == null)
      ? const ThemeBackground.none()
      : bg;

  /// 编辑主题时对图片背景做 reconciliation：
  /// - 切走图片（newBg 非 image）→ 删除旧副本；
  /// - 换新源图（路径不同且不在 theme_bg 内）→ 复制覆盖到 `bg_<id>.<ext>` 并删旧副本；
  /// - 同路径（仍是已安装副本）→ 原样返回。
  Future<ThemeBackground> _reconcileBackgroundImage(
    String id,
    ThemeBackground oldBg,
    ThemeBackground newBg,
  ) async {
    if (newBg.type != ThemeBackgroundType.image) {
      if (oldBg.type == ThemeBackgroundType.image && oldBg.imagePath != null) {
        await _deleteBackgroundImage(oldBg.imagePath!);
      }
      return newBg;
    }
    final newPath = newBg.imagePath!;
    if (newPath == oldBg.imagePath) return newBg; // 同图未换
    try {
      final src = File(newPath);
      if (!await src.exists()) {
        _log('编辑主题：新背景图源不存在，保留旧图');
        return oldBg.type == ThemeBackgroundType.image
            ? oldBg
            : const ThemeBackground.none();
      }
      final dir = await _themeBgDir();
      final dest = File('${dir.path}/bg_$id.${_pickImageExt(src.path)}');
      await src.copy(dest.path);
      if (oldBg.type == ThemeBackgroundType.image &&
          oldBg.imagePath != null &&
          oldBg.imagePath != dest.path) {
        await _deleteBackgroundImage(oldBg.imagePath!);
      }
      // 只改路径，保留新配置里的不透明度/模糊
      return newBg.copyWith(imagePath: dest.path);
    } catch (e) {
      _log('编辑主题：复制新背景图失败，保留旧图: $e');
      return oldBg.type == ThemeBackgroundType.image
          ? oldBg
          : const ThemeBackground.none();
    }
  }

  /// 删除背景图片副本（best-effort）。
  Future<void> _deleteBackgroundImage(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (e) {
      _log('删除背景图片失败: $e');
    }
  }

  /// 取源路径图片扩展名（小写，非法/缺失回退 jpg），用于副本命名。
  String _pickImageExt(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return 'jpg';
    final ext = path.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext) ? ext : 'jpg';
  }

  /// 设置：在线阅读预加载图片数（自动 clamp 到 2~10）
  Future<void> setPreloadImageCount(int value) async {
    final clamped = _clamp(value, minPreloadImages, maxPreloadImages);
    if (_preloadImageCount == clamped) return;
    _preloadImageCount = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_preloadKey, clamped);
    } catch (e) {
      _log('保存预加载图片数失败: $e');
    }
  }

  /// 设置：图书字号（自动 clamp）
  Future<void> setBookFontSize(double value) async {
    final clamped = _clampDouble(value, minBookFontSize, maxBookFontSize);
    if (_bookFontSize == clamped) return;
    _bookFontSize = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kBookFontSizeKey, clamped);
    } catch (e) {
      _log('保存图书字号失败: $e');
    }
  }

  /// 设置：图书行距（自动 clamp）
  Future<void> setBookLineHeight(double value) async {
    final clamped = _clampDouble(value, minBookLineHeight, maxBookLineHeight);
    if (_bookLineHeight == clamped) return;
    _bookLineHeight = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kBookLineHeightKey, clamped);
    } catch (e) {
      _log('保存图书行距失败: $e');
    }
  }

  /// 设置：仿真翻页阴影强度（0~1）
  Future<void> setPageCurlShadow(double value) async {
    final clamped = _clampDouble(value, 0.0, 1.0);
    if (_pageCurlShadow == clamped) return;
    _pageCurlShadow = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kPageCurlShadowKey, clamped);
    } catch (e) {
      _log('保存仿真翻页阴影失败: $e');
    }
  }

  /// 设置：仿真翻页性能档位（0 流畅 / 1 标准 / 2 精细）
  Future<void> setPageCurlQuality(int value) async {
    final v = value.clamp(0, 2);
    if (_pageCurlQuality == v) return;
    _pageCurlQuality = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPageCurlQualityKey, v);
    } catch (e) {
      _log('保存仿真翻页档位失败: $e');
    }
  }

  /// 设置：仿真翻页纸张纹理
  Future<void> setPageCurlTexture(bool value) async {
    if (_pageCurlTexture == value) return;
    _pageCurlTexture = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPageCurlTextureKey, value);
    } catch (e) {
      _log('保存仿真翻页纹理失败: $e');
    }
  }

  /// 设置：图书左右边距（自动 clamp）
  Future<void> setBookHorizontalPadding(double value) async {
    final clamped = _clampDouble(
      value,
      minBookHorizontalPadding,
      maxBookHorizontalPadding,
    );
    if (_bookHorizontalPadding == clamped) return;
    _bookHorizontalPadding = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kBookHorizontalPaddingKey, clamped);
    } catch (e) {
      _log('保存图书左右边距失败: $e');
    }
  }

  /// 设置：图书上下边距（自动 clamp）
  Future<void> setBookVerticalPadding(double value) async {
    final clamped = _clampDouble(
      value,
      minBookVerticalPadding,
      maxBookVerticalPadding,
    );
    if (_bookVerticalPadding == clamped) return;
    _bookVerticalPadding = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kBookVerticalPaddingKey, clamped);
    } catch (e) {
      _log('保存图书上下边距失败: $e');
    }
  }

  /// 设置：图书正文字体（value 同 [bookFontFamily] 约定）。
  Future<void> setBookFontFamily(String? value) async {
    final normalized = (value == null || value.isEmpty) ? null : value;
    if (_bookFontFamily == normalized) return;
    _bookFontFamily = normalized;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (normalized == null) {
        await prefs.remove(_kBookFontFamilyKey);
      } else {
        await prefs.setString(_kBookFontFamilyKey, normalized);
      }
    } catch (e) {
      _log('保存图书字体失败: $e');
    }
  }

  /// 设置导航栏可见 tab
  /// - "我的"始终显示
  /// - 漫画/图书/收藏/书架至少保留一个
  /// - 如果当前默认首页被隐藏，自动修正到第一个可见 tab
  Future<void> setVisibleNavTabs(List<NavTab> tabs) async {
    final sanitized = _sanitizeVisibleNavTabs(tabs);
    if (_listEquals(_visibleNavTabs, sanitized)) return;
    _visibleNavTabs = sanitized;

    // 若默认首页不在可见列表中，自动修正
    if (!_visibleNavTabs.any((t) => t == _defaultHomePage.toNavTab())) {
      _defaultHomePage = _visibleNavTabs.first.toDefaultHomePage();
    }

    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _kNavVisibleTabsKey,
        sanitized.map((t) => t.name).toList(),
      );
      // 同步保存可能被修正的默认首页
      await prefs.setInt(_defaultHomeKey, _defaultHomePage.index);
    } catch (e) {
      _log('保存导航栏可见 tab 失败: $e');
    }
  }

  /// 设置：收藏/书架/下载页 tab 是否跟随导航栏 manga/book 可见性
  Future<void> setPageTabsFollowNav(bool value) async {
    if (_pageTabsFollowNav == value) return;
    _pageTabsFollowNav = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPageTabsFollowNavKey, value);
    } catch (e) {
      _log('保存页面tab跟随导航栏失败: $e');
    }
  }

  /// 设置：首页幻灯片（轮播）样式
  Future<void> setHomeBannerStyle(HomeBannerStyle value) async {
    if (_homeBannerStyle == value) return;
    _homeBannerStyle = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      // 存 name（不是 index）：样式增删时老用户的选择不会漂到别的样式
      await prefs.setString(_kHomeBannerStyleKey, value.name);
      // 立刻落进文件镜像：这个值在「设置 → 菜单设置」里改，用户改完常直接
      // 杀 App，等 15s 周期快照就来不及了（见 prefs_mirror.snapshotSoon 说明）
      PrefsMirror.snapshotSoon();
    } catch (e) {
      _log('保存首页幻灯片样式失败: $e');
    }
  }

  /// 设置：收藏/书架/下载页默认显示内容（漫画/图书）
  Future<void> setPageDefaultContent(PageDefaultContent value) async {
    if (_pageDefaultContent == value) return;
    _pageDefaultContent = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPageDefaultContentKey, value.index);
    } catch (e) {
      _log('保存页面默认显示内容失败: $e');
    }
  }

  /// 设置：翻页按钮反转（左点下一页、右点上一页）
  Future<void> setReverseTap(bool value) async {
    if (_reverseTap == value) return;
    _reverseTap = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kReverseTapKey, value);
    } catch (e) {
      _log('保存翻页反转开关失败: $e');
    }
  }

  /// 恢复阅读设置为出厂默认：清空所有阅读相关偏好后重新加载默认值，
  /// 并通知监听方刷新 UI。不影响下载/网络/主题等非阅读设置。
  Future<void> resetReadingDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    const keys = [
      _readingModeKey,
      _kBookReadingModeKey,
      _kReverseTapKey,
      _kDoublePageKey,
      _kShowReaderHudKey,
      _kVolumeKeyTurnKey,
      _kCheckShelfUpdateKey,
      _kRememberZoomKey,
      _kPinchZoomKey,
      _kSingleHandKey,
      _kScreenSleepKey,
      _kReaderBackgroundStyleKey,
      _kComicMarginKey,
      _kUpscaleAutoCleanKey,
      _kUpscaleCleanLimitKey,
      _kUpscaleDenoiseKey,
      _kAutoAddShelfKey,
      _kAutoAddShelfForBookKey,
      _kInkScreenModeKey,
      _kComicBrightnessKey,
      _kBookFontSizeKey,
      _kBookLineHeightKey,
      _kBookHorizontalPaddingKey,
      _kBookVerticalPaddingKey,
      _kBookFontFamilyKey,
      _kPageCurlShadowKey,
      _kPageCurlQualityKey,
      _kPageCurlTextureKey,
    ];
    for (final k in keys) {
      await prefs.remove(k);
    }
    await init();
    notifyListeners();
  }

  /// 设置：墨水屏模式开关（漫画黑白 + 柔和浅灰底）
  Future<void> setInkScreenMode(bool value) async {
    if (_inkScreenMode == value) return;
    _inkScreenMode = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kInkScreenModeKey, value);
    } catch (e) {
      _log('保存墨水屏模式开关失败: $e');
    }
  }

  /// 设置漫画阅读器页面亮度（独立叠加层，0.35~1.0，不调系统亮度）。
  Future<void> setComicBrightness(double value) async {
    final v = value.clamp(0.35, 1.0).toDouble();
    if ((_comicBrightness - v).abs() < 0.001) return;
    _comicBrightness = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kComicBrightnessKey, v);
    } catch (e) {
      _log('保存漫画阅读器亮度失败: $e');
    }
  }

  /// 设置：双页模式（横屏左右并排两页，仅翻页模式生效）
  Future<void> setDoublePage(bool value) async {
    if (_doublePage == value) return;
    _doublePage = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kDoublePageKey, value);
    } catch (e) {
      _log('保存双页模式开关失败: $e');
    }
  }

  /// 设置：阅读信息栏（时间/页码/进度）
  Future<void> setShowReaderHud(bool value) async {
    if (_showReaderHud == value) return;
    _showReaderHud = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kShowReaderHudKey, value);
    } catch (e) {
      _log('保存阅读信息栏开关失败: $e');
    }
  }

  /// 设置：音量键翻页（阅读时按音量上/下键翻页）
  // ── 新增 6 项的 setter ──────────────────────────────────────

  Future<void> setCheckShelfUpdateOnStart(bool value) async {
    if (_checkShelfUpdateOnStart == value) return;
    _checkShelfUpdateOnStart = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCheckShelfUpdateKey, value);
  }

  Future<void> setRememberZoom(bool value) async {
    if (_rememberZoom == value) return;
    _rememberZoom = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRememberZoomKey, value);
  }

  Future<void> setPinchZoom(bool value) async {
    if (_pinchZoom == value) return;
    _pinchZoom = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPinchZoomKey, value);
  }

  Future<void> setSingleHand(bool value) async {
    if (_singleHand == value) return;
    _singleHand = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSingleHandKey, value);
  }

  /// C8：保存漫画点击九宫格（9 格 TapAction.index；空 = 恢复默认三列）
  Future<void> setMangaTapZones(List<int> value) async {
    final norm = value.length == 9
        ? value.map((e) => e.clamp(0, 3)).toList()
        : const <int>[];
    _mangaTapZones = norm;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMangaTapZonesKey, jsonEncode(norm));
  }

  Future<void> setScreenSleep(String value) async {
    if (_screenSleep == value) return;
    _screenSleep = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kScreenSleepKey, value);
  }

  /// 阅读背景样式：0纯白 / 1纸白 / 2米黄 / 3暗夜 / 4纯黑
  Future<void> setReaderBackgroundStyle(int value) async {
    final clamped = _clamp(value, 0, 4);
    if (_readerBackgroundStyle == clamped) return;
    _readerBackgroundStyle = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kReaderBackgroundStyleKey, clamped);
  }

  /// 漫画边距（页眉左右/上、页脚左右/下，逻辑像素）
  Future<void> setComicMargins({
    double headerLeft = 16,
    double headerRight = 16,
    double headerTop = 8,
    double footerLeft = 16,
    double footerRight = 16,
    double footerBottom = 8,
  }) async {
    _comicHeaderLeft = _clampDouble(headerLeft, 0, 96);
    _comicHeaderRight = _clampDouble(headerRight, 0, 96);
    _comicHeaderTop = _clampDouble(headerTop, 0, 96);
    _comicFooterLeft = _clampDouble(footerLeft, 0, 96);
    _comicFooterRight = _clampDouble(footerRight, 0, 96);
    _comicFooterBottom = _clampDouble(footerBottom, 0, 96);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kComicMarginKey,
      jsonEncode({
        'hl': _comicHeaderLeft,
        'hr': _comicHeaderRight,
        'ht': _comicHeaderTop,
        'fl': _comicFooterLeft,
        'fr': _comicFooterRight,
        'fb': _comicFooterBottom,
      }),
    );
  }

  /// 端侧 AI 超分：自动清理缓存开关
  Future<void> setUpscaleAutoClean(bool value) async {
    if (_upscaleAutoClean == value) return;
    _upscaleAutoClean = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUpscaleAutoCleanKey, value);
  }

  /// 端侧 AI 超分：清理上限（GB，0.1~10）
  Future<void> setUpscaleCleanLimitGb(double value) async {
    final clamped = _clampDouble(value, 0.1, 10);
    if (_upscaleCleanLimitGb == clamped) return;
    _upscaleCleanLimitGb = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kUpscaleCleanLimitKey, clamped);
  }

  /// 端侧 AI 超分：降噪强度（0 保守 / 1 中等 / 2 强力）
  Future<void> setUpscaleDenoise(int value) async {
    final clamped = _clamp(value, 0, 2);
    if (_upscaleDenoise == clamped) return;
    _upscaleDenoise = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kUpscaleDenoiseKey, clamped);
  }

  /// 端侧 AI 超分：模型已下载状态（仅 UI 记录）
  Future<void> setUpscaleModelDownloaded(bool value) async {
    if (_upscaleModelDownloaded == value) return;
    _upscaleModelDownloaded = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUpscaleModelDownloadedKey, value);
  }

  /// 切换书架显隐（「管理书架」里的眼睛）。
  Future<void> toggleShelfHidden(String id) async {
    if (!_hiddenShelfIds.remove(id)) _hiddenShelfIds.add(id);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kHiddenShelfIdsKey, _hiddenShelfIds.toList());
  }

  Future<void> setShelfRemoveDeletesFile(bool value) async {
    if (_shelfRemoveDeletesFile == value) return;
    _shelfRemoveDeletesFile = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRemoveDeletesFileKey, value);
  }

  Future<void> setShelfSortAsc(bool value) async {
    if (_shelfSortAsc == value) return;
    _shelfSortAsc = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShelfSortAscKey, value);
  }

  Future<void> setShelfSortGlobal(bool value) async {
    if (_shelfSortGlobal == value) return;
    _shelfSortGlobal = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShelfSortGlobalKey, value);
  }

  Future<void> setShelfSort(String value) async {
    if (_shelfSort == value) return;
    _shelfSort = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kShelfSortKey, value);
  }

  Future<void> setAutoAddShelfForManga(bool value) async {
    if (_autoAddShelfForManga == value) return;
    _autoAddShelfForManga = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoAddShelfKey, value);
  }

  Future<void> setAutoAddShelfForBook(bool value) async {
    if (_autoAddShelfForBook == value) return;
    _autoAddShelfForBook = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoAddShelfForBookKey, value);
  }

  Future<void> setVolumeKeyTurn(bool value) async {
    if (_volumeKeyTurn == value) return;
    _volumeKeyTurn = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kVolumeKeyTurnKey, value);
    } catch (e) {
      _log('保存音量键翻页开关失败: $e');
    }
  }

  /// 校验可见 tab 列表：
  /// - 必须包含 me
  /// - 漫画/图书/收藏/书架至少一个
  /// - 保持原始顺序（按 NavTab.values 顺序排序）
  static List<NavTab> _sanitizeVisibleNavTabs(List<NavTab> tabs) {
    final set = tabs.toSet();
    // 必须有"我的"
    set.add(NavTab.me);
    // 漫画/图书/收藏/书架至少一个
    const contentTabs = [
      NavTab.manga,
      NavTab.book,
      NavTab.bookshelf,
      NavTab.favorites,
    ];
    final hasContent = contentTabs.any((t) => set.contains(t));
    if (!hasContent) {
      set.add(NavTab.manga); // 默认保留漫画
    }
    // 按固定顺序返回
    return NavTab.values.where((t) => set.contains(t)).toList();
  }

  /// 设置导航栏是否悬浮（胶囊型毛玻璃样式）
  Future<void> setNavFloating(bool value) async {
    if (_navFloating == value) return;
    _navFloating = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kNavFloatingKey, value);
      PrefsMirror.snapshotSoon();
    } catch (e) {
      _log('保存导航栏悬浮开关失败: $e');
    }
  }

  /// 设置导航栏是否只显示图标（隐藏文字标签）
  Future<void> setNavIconOnly(bool value) async {
    if (_navIconOnly == value) return;
    _navIconOnly = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kNavIconOnlyKey, value);
      PrefsMirror.snapshotSoon();
    } catch (e) {
      _log('保存导航栏纯图标开关失败: $e');
    }
  }

  /// 设置悬浮底栏风格（值见 `FloatingNavStyle.id`：
  /// ink / frost / aurora / neon / reverse / solid）
  Future<void> setNavStyle(String id) async {
    if (_navStyle == id) return;
    _navStyle = id;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kNavStyleKey, id);
      PrefsMirror.snapshotSoon();
    } catch (e) {
      _log('保存底栏风格失败: $e');
    }
  }

  /// 设置悬浮底栏不透明度（0.30~1.0）。
  ///
  /// 底栏每次 build 都读这个值 ⇒ 拖滑杆立即生效，不需要重启页面。
  Future<void> setNavBarOpacity(double v) async {
    final next = v.clamp(0.30, 1.0);
    if ((_navBarOpacity - next).abs() < 0.001) return;
    _navBarOpacity = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kNavBarOpacityKey, next);
      PrefsMirror.snapshotSoon();
    } catch (e) {
      _log('保存底栏不透明度失败: $e');
    }
  }

  /// 上传自定义底栏图标：把选中的图片复制到应用目录后登记（源图可能被系统清理）。
  Future<bool> setNavCustomIcon(String label, String sourcePath) async {
    try {
      final src = File(sourcePath);
      if (!await src.exists()) return false;
      final root = await getApplicationDocumentsDirectory();
      final dir = Directory('${root.path}/nav_icons');
      if (!await dir.exists()) await dir.create(recursive: true);
      final ext = _pickImageExt(src.path);
      // ⚠️ 文件名必须**每次不同**：Flutter 的 `Image.file` 按「路径」做解码缓存，
      //   固定成 `nav_<label>.<ext>` 时第二次上传覆盖同名文件，界面仍显示旧图
      //   （用户 2026-10-20：「换一次能换，换第二次换不了」）。
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final dest =
          File('${dir.path}/nav_${label.codeUnits.join('_')}_$stamp.$ext');
      await src.copy(dest.path);
      final old = _navCustomIcons[label];
      _navCustomIcons[label] = dest.path;
      await _persistNavCustomIcons();
      notifyListeners();
      // 上一次的图标文件清理掉（路径已不同，不影响新图缓存）
      if (old != null && old.isNotEmpty && old != dest.path) {
        try {
          final f = File(old);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      return true;
    } catch (e) {
      _log('保存自定义底栏图标失败: $e');
      return false;
    }
  }

  /// 恢复某个 tab 的默认图标（删除已复制的图片）。
  Future<void> clearNavCustomIcon(String label) async {
    final old = _navCustomIcons.remove(label);
    await _persistNavCustomIcons();
    notifyListeners();
    if (old != null && old.isNotEmpty) {
      try {
        final f = File(old);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  Future<void> _persistNavCustomIcons() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kNavCustomIconsKey,
        jsonEncode(_navCustomIcons),
      );
      PrefsMirror.snapshotSoon();
    } catch (e) {
      _log('保存自定义底栏图标失败: $e');
    }
  }

  // === 漫画源 ===
  static const _currentSourceKey = 'current_source_id';
  /// 历史默认源硬编码迁移标记（见 init()）：清掉被钉死的 copymanga，回归列表第一个
  static const _kMangaDefaultMigratedKey = 'manga_default_source_migrated_v1';
  // 当前漫画源 id；空 = 未主动选择，SourceManager 自动取列表第一个启用源
  String _currentSourceId = '';
  String get currentSourceId => _currentSourceId;

  /// 设置当前漫画源 id
  Future<void> setCurrentSourceId(String value) async {
    if (_currentSourceId == value) return;
    _currentSourceId = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_currentSourceKey, value);
    } catch (e) {
      _log('保存当前漫画源失败: $e');
    }
  }

  static const _disabledSourceIdsKey = 'disabled_source_ids';
  List<String> _disabledSourceIds = []; // 禁用漫画源 id 列表（启用 = 不在此列表）
  List<String> get disabledSourceIds => _disabledSourceIds;

  /// 漫画源自定义顺序（用户 2026-10-18：长按源标签可左右移动）
  static const _mangaSourceOrderKey = 'manga_source_order_v1';
  List<String> _mangaSourceOrder = [];
  List<String> get mangaSourceOrder => List.unmodifiable(_mangaSourceOrder);

  Future<void> setMangaSourceOrder(List<String> value) async {
    _mangaSourceOrder = List<String>.of(value);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_mangaSourceOrderKey, _mangaSourceOrder);
    } catch (e) {
      _log('保存漫画源顺序失败: $e');
    }
  }

  /// 设置禁用漫画源 id 列表
  Future<void> setDisabledSourceIds(List<String> value) async {
    _disabledSourceIds = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_disabledSourceIdsKey, value);
    } catch (e) {
      _log('保存禁用源列表失败: $e');
    }
  }

  static const _sourceRepoUrlKey = 'source_repo_url';
  String _sourceRepoUrl = ''; // 漫画源仓库云端 URL（后续拉取用）
  String get sourceRepoUrl => _sourceRepoUrl;

  /// 设置漫画源仓库云端 URL
  Future<void> setSourceRepoUrl(String value) async {
    _sourceRepoUrl = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sourceRepoUrlKey, value);
    } catch (e) {
      _log('保存漫画源仓库URL失败: $e');
    }
  }

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static int _clamp(int v, int min, int max) =>
      v < min ? min : (v > max ? max : v);

  static double _clampDouble(double v, double min, double max) =>
      v < min ? min : (v > max ? max : v);

  /// 下载根目录：自定义保存位置优先（不存在则创建），否则回退应用私有目录下的 Cmbok。
  /// 漫画/图书下载服务共用，两者在该根下分 Comics / Books 子目录。
  static Future<Directory> downloadBaseDir() async {
    final custom = SettingsService().downloadSavePath;
    if (custom != null && custom.isNotEmpty) {
      try {
        final d = Directory(custom);
        if (!await d.exists()) {
          await d.create(recursive: true);
        }
        return d;
      } catch (e) {
        // 自定义目录不可用（权限被拒 / SD 卡未挂载等），回退默认，避免下载崩溃
        _log('自定义保存目录不可用，回退默认: $e');
      }
    }
    final doc = await getApplicationDocumentsDirectory();
    return Directory('${doc.path}/${CmbokConstants.downloadDir}');
  }
}
