// ⚠️ 本文件的 269 个抽象方法声明是「跨 part 调用」的类型契约，**不是死代码**。
//    方法体已按 P0.1 拆到 `reader_parts/` 下 7 个 `mixin ... on 本类` 里；
//    基类必须保留全部签名，任意 part 才能调用任意方法（顺序无关，这是拆分
//    方案成立的前提）。副作用：若某方法只被「它自己所在的 mixin」调用，分析器
//    会判定基类这份声明未被引用 → 报 `unused_element`（实测 130 条）与
//    `unused_element_parameter`（19 条）。逐条删除会破坏跨 part 调用，故统一豁免。
// ignore_for_file: unused_element, unused_element_parameter
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/reading/models/book_source.dart';
import 'package:tvbox/reading/models/book_content.dart';
import 'package:tvbox/reading/models/reader_style.dart';
import 'package:tvbox/reading/models/reader_bg_assets.dart';
import 'package:tvbox/reading/models/reader_title_style.dart';
import 'package:tvbox/reading/models/reading_settings.dart';
import 'package:tvbox/reading/novel_source/novel_chinese_converter.dart';
import 'package:tvbox/reading/services/book_paginator.dart';
import 'package:tvbox/reading/services/book_source_service.dart';
import 'package:tvbox/reading/services/chapter_alignment.dart';
import 'package:tvbox/reading/services/chapter_text_cache.dart';
import 'package:tvbox/reading/services/reader_font_service.dart';
import 'package:tvbox/reading/services/reader_notes_service.dart';
import 'package:tvbox/reading/services/reader_style_store.dart';
import 'package:tvbox/services/translate_service.dart';
import 'package:tvbox/services/file_export_service.dart';
import 'package:tvbox/reading/pages/reader_styles_page.dart';
import 'package:tvbox/reading/pages/webview_page.dart';
import 'package:tvbox/reading/pages/reader_title_styles_page.dart';
import 'package:tvbox/reading/services/srs_style_importer.dart';
import 'package:tvbox/reading/services/title_html_parser.dart';
import 'package:tvbox/reading/services/tts_service.dart';
import 'package:tvbox/reading/services/tts_source_store.dart';
import 'package:tvbox/reading/services/ai_service.dart';
import 'package:tvbox/reading/services/reading_time_service.dart';
import 'package:tvbox/reading/services/bsr_independent_layout.dart';
import 'package:tvbox/reading/utils/header_footer_format.dart';
import 'package:tvbox/reading/widgets/book_page_cover.dart';
import 'package:tvbox/reading/widgets/book_page_curl.dart';
import 'package:tvbox/reading/widgets/jelly_filter_sheet.dart';
import 'package:tvbox/reading/widgets/jelly_mode_picker.dart';
import 'package:tvbox/reading/widgets/color_picker_dialog.dart';
import 'package:tvbox/reading/widgets/pomodoro_button.dart';
import 'package:tvbox/reading/widgets/wavy_underline.dart';
import 'package:tvbox/reading/pages/tts_engine_page.dart';
import 'package:tvbox/reading/pages/book_source_editor_page.dart';
import 'package:tvbox/reading/pages/book_source_search_page.dart';
import 'package:tvbox/reading/pages/tts_full_player_page.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/common/system_ui.dart';
import 'package:tvbox/reading/theme/jelly_theme.dart';
import 'package:tvbox/widgets/app_image_cache.dart';

part 'reader_parts/reader_part_01.dart';
part 'reader_parts/reader_part_02.dart';
part 'reader_parts/reader_part_03.dart';
part 'reader_parts/reader_part_04.dart';
part 'reader_parts/reader_part_05.dart';
part 'reader_parts/reader_part_06.dart';
part 'reader_parts/reader_part_07.dart';



/// 分页模式的 PageView 专用 physics：滑动必须位移满 touch slop 才启动 drag。
///
/// 默认 `PageScrollPhysics` 在 iOS 上走 `DragStartBehavior.down` —— 手指刚按下
/// 就抢占手势竞技场，单指轻点常被它抢赢 ⇒ 「点中间呼不出面板」✗（5d65950 /
/// 65273fa 两次来回的根因）。设了 `dragStartDistanceMotionThreshold` 后，
/// Scrollable 自动改用 `DragStartBehavior.start`：位移 < kTouchSlop 的轻点
/// 必然被外层 GestureDetector 的 tap 抢到 ✓；真正滑动（位移 ≥ slop）时
/// drag 照常赢得竞技场、翻页不受影响 ✓。与漫画阅读器手势行为对齐。
class _TapFriendlyPagePhysics extends PageScrollPhysics {
  const _TapFriendlyPagePhysics();

  @override
  double? get dragStartDistanceMotionThreshold => kTouchSlop;
}

/// ✅ **页号夹取**（blocker 修复的纯函数核心 ✓ —— 独立出来是为了**可单测** ✓）。
///
/// 背景：`_paginate()` 会在循环里把 `_pages` 换成"只排了第一批"的**短列表** ✗，
/// 而 `_pageIndex` 在此期间仍是上一次的值（多达几十页 ✓）→
/// 渲染层 `_pages[_pageIndex]` 就会 **`RangeError` 崩溃** ✗
/// （触发路径都是日常操作：仿真模式读到大页号点「下一章」/ 旋屏 ✓）。
///
/// 契约：**永不 throw** ✓，返回值一定落在 `[0, pageCount - 1]` ✓（`pageCount == 0` 时返回 0 ✓）。
/// ⚠️ 这里绝不能写成 `index.clamp(0, pageCount - 1)` ✗ —— `pageCount == 0` 时上界为 -1 ✓，
/// `num.clamp` 在 `lowerLimit > upperLimit` 时**真抛 `ArgumentError`** ✗
/// （同 `book_reader_page.dart:790-796` 已记录的那个坑 ✓）。
int clampPageIndexToPages(int index, int pageCount) {
  if (pageCount <= 0) return 0;
  if (index < 0) return 0;
  if (index >= pageCount) return pageCount - 1;
  return index;
}

/// 书源在线阅读器。
///
/// ── 为什么不复用 `BookReaderPage` ──────────────────────────────
/// cmbok 的 `BookReaderPage` 吃的是 `BookContent`（整本书一次性解析好的
/// 本地文件），入口是 `BookDownloadTask` + 本地字节流。
/// 书源是**在线逐章抓取**：章节数量几十上百，不可能进页面就把全书拉下来。
/// 硬塞进旧阅读器要改它的加载链路（侵入很大、且会波及本地书那条路径）。
/// 所以这里做一个**同风格**的在线阅读器，共用同一套配色与翻页手势。
///
/// ── 关键设计 ──────────────────────────────────────────────────
///   · **懒加载 + 预取**：只抓当前章，同时后台预取下一章（翻页不卡）
///   · **缓存**：同一章重复读不再抓（缓存上限，防长篇小说吃爆内存）
///   · **进度持久化**：书名+源 作为 key，回来能续读
class BookSourceReaderPage extends StatefulWidget {
  const BookSourceReaderPage({
    super.key,
    required this.source,
    required this.bookName,
    required this.author,
    required this.chapters,
    this.initialIndex = 0,
    // 🔴 新增（**可选** ✓，所以调用点不改也能编译 ✓ —— 零回归 ✓）：
    //   用于修掉下面 `:1743` 那个"**读一个从不被写入的键**" ✗ ——
    //   那里读 `source.raw['coverUrl']` ✓，但 224 个内置 Legado 源顶层
    //   **都没有这个键** ✓，config 源的封面又在 `config.search_cover_dom` 里 ✓
    //   → 结果是**全屏听书页永远只显示占位图** ✗。
    // ✓ 改由**调用方把封面传进来** ✓（详情页与书架手里都有封面 ✓）
    this.coverUrl,
  });

  final BookSource source;
  final String bookName;
  final String author;
  final List<BookSourceChapter> chapters;
  final int initialIndex;

  /// 可选的封面地址 ✓（由调用方传入 ✓）—— 为 null 时全屏听书页照旧显示占位图 ✓
  final String? coverUrl;

  @override
  State<BookSourceReaderPage> createState() => _BookSourceReaderPageStateImpl();
}

abstract class _BookSourceReaderPageState extends State<BookSourceReaderPage>
    with WidgetsBindingObserver {
late int _index;

late final PageController _pageCtrl;

/// 章节内容缓存：章节下标 → 段落列表
  final Map<int, List<String>> _cache = {};

static const int _cacheLimit = 12;

bool _loading = false;

String? _error;

List<String> _paragraphs = const [];

/// 字号 / 行距 / 背景（与设置页同一把尺子）
  double _fontSize = 18;

// 默认排版按中文正文的"标准呼吸感"调过（2026-10-23）：
  // 行距 1.9 → 1.72、段距 1.0 字 → 0.5 字、字距 0 → 0.3，
  // 原来 18px + 1.9 行高 + 整整一行段距叠起来，整体过松、看着"散"。
  double _lineHeight = 1.72;

/// 阅读底色索引（见 [_bgs]）。
  ///
  /// 初始值按**系统**深色模式取；真正的值随后由 `_restorePrefs`
  /// 从阅读器自己的设置里读回（用户 2026-10-25：阅读器的日夜以阅读器设置为准）。
  int _bgIndex = WidgetsBinding
          .instance.platformDispatcher.platformBrightness ==
      Brightness.dark
      ? 5
      : 0;

/// 自定义背景色（主题 tab「自定义」，参考图 IMG_8500；null = 用 _bgs）
  Color? _customBgColor;

/// 自定义背景图片路径（「选择图片」选图后复制到应用文档目录；
  /// 非空时优先于颜色作为正文背景）
  String? _customBgPath;

/// 夜间自定义背景图（.srs 自带日/夜两张；null = 夜间用 [_customBgPath] 并压暗）
  String? _customBgPathNight;

/// 内置阅读背景壁纸（清单集中在 [ReaderBgAssets]，与样式编辑器共用）
  ///
  /// 用 [ReaderBgAssets.picker]（不含成对夜间版）：古风/泼墨/皮卡的夜版
  /// 选中日版时自动带出，避免列表里同一张图占两格、用户选错。
  static const List<String> _builtinBgImages = ReaderBgAssets.picker;

/// 当前选中的内置壁纸（null = 不用壁纸，走 `_bgIndex` 的纯色底 ✓）
  String? _bgImageAsset;

/// 夜间专用壁纸（样式自带；null = 夜间沿用日间图并压暗）
  String? _bgImageAssetNight;

/// 当前壁纸是否为深色（A3：深色壁纸自动换浅字，避免深底黑字）。
  /// null = 未分析（尚未选壁纸）。
  bool? _bgImageDark;

/// **自选文件**背景图是否深色（与 `_bgImageDark` 同语义，用于自选图片）。
  /// null = 未分析（尚无自选图）。选图 / 恢复 / 套样式后异步采样。
  bool? _fileBgDark;

/// 日夜切换时记住的浅色背景索引（从夜间切回时还原）
  int _dayBgIndex = 0;

/// 顶栏 + 「阅读设置」面板是否展开。
  ///
  /// ── 🔴 默认值必须是 **false**（用户实测反馈）─────────────────────
  /// 原来是 `true` ✗ ⇒ **点「阅读」一进来看到的就是那个「阅读设置」面板**，
  /// 而该面板 `maxHeight: 屏幕高 * 0.8`（见 [_settingsPanel]）——
  /// 直接盖住 80% 正文，用户原话：「**整个阅读器乱七八糟的，
  /// 点击阅读直接就有这个设置**」✗
  ///
  /// 副作用比"挡视线"更重：面板展开时 `onTapUp`（:868）**只做收起、不翻页** ✗
  /// ⇒ 想翻页得先点一下把它关掉，**左/右 1/3 点击翻章完全失效** ✗
  ///
  /// 改成 false 后：
  ///   · 进来是**干净的正文**（与 `book_reader_page.dart:197`
  ///     `_showControls = false` 的既有设计一致 ✓）
  ///   · 点屏幕中间 → 展开顶栏 + 设置面板（:880）✓
  ///   · 双击右下悬浮球 → 同样展开（:4773）✓
  ///   · 左/右 1/3 点击 → **一开始就能翻章** ✓
  bool _showBar = false;

/// 「阅读设置」面板是否展开。
  /// 从 `_showBar` 里**拆出来**：否则点中间弹面板会把底部功能栏整个盖住 ✗。
  /// 现在只有功能栏里的「设置」项才打开它 ✓。
  bool _showSettingsPanel = false;

// ── 排版（截图 IMG_8491~8499 全文可调）───────────────────────
  double _fontWeight = 400;

// 字重
  double _letterSpacing = 0.3;

// 字间距
  double _paraSpacing = 0.5;

// 段间距（× 字号）
  // 边距（内容区）
  double _padLeft = 20, _padRight = 20, _padTop = 16, _padBottom = 40;

double _indent = 2;

// 首行缩进（字符数）
  // 页眉 / 页脚（负值移进状态栏区域）
  double _headerPadH = 15, _headerPadTop = 0;

double _footerPadH = 15, _footerPadBottom = 0;

// 底线
  // ⚠️ 默认必须是 0（无）—— 用户实测："默认打开就有下划线" ✗。
  //   原来写死 3（实线）⇒ 一进阅读器**整屏正文都带下划线** ✗。
  int _underlineStyle = 0;

// 0无 1短虚线 2长虚线 3实线 4波浪
  Color? _underlineColor;

// null = 跟随文字（参考图 IMG_8497/8498）
  double _underlineAlpha = 0.35;

double _underlineWidth = 1.2;

double _underlineGap = 3.0;

bool _underlineFull = false;

// 满行底线
  /// 自定义字色（null = 跟随主题）
  Color? _fgOverride;

/// 夜间字色（样式里 db 的 `textColorNight`）。夜间时优先于 [_fgOverride]
  Color? _fgNightOverride;

/// 样式带来的日 / 夜底色（切日夜时恢复，避免"一套样式只有一种底色"）
  int? _styleBgDay;

int? _styleBgNight;

/// 章标题字号（null = 正文 +3）与字重（db `titleBold < 0` → 不加粗）
  double? _titleFontSize;

bool _titleBold = true;

/// 章节标题**整体缩放**（1.0 = 原尺寸，0.6~1.6）。
  ///
  /// 内置 HTML 标题样式（泼墨山水 / 仙鹤 / 古风…）里的 `font-size:1.5em~2.6em`
  /// 是相对正文的固定倍数，屏幕窄、正文字号大时会撑满半页甚至换行截断。
  /// 除了下面的按屏宽自动系数，再给用户一个手动缩放（排版面板里的「标题大小」）。
  double _titleScale = 1.0;

/// HTML 标题下方的额外留白（0~40，默认 0）。
  ///
  /// 内置样式的间距写死在 CSS 的 margin 里（em 相对标题字号），不同屏幕/字号下
  /// 观感差异很大；给一个统一的「标题间距」让用户把标题往下推、和正文拉开。
  double _titleGap = 0;

/// 夜间压暗强度（0~0.8）。夜间无专属壁纸时，用这层黑遮罩压暗日间壁纸。
  /// 原来是写死的 `0x73`（≈45%），现在可调、且随样式保存。
  double _nightDimOpacity = 0.45;

/// 已保存的排版预设名
  final List<String> _savedPresets = [];

/// 「阅读样式」：用户自己存的样式（内置样式在 [ReaderStyle.builtins]）
  List<ReaderStyle> _myStyles = [];

/// 章标题版式（默认 / 仙鹤·日间 / 仙鹤·夜间 / 微信读书 / 自定义）
  ReaderTitleStyle _chapterTitleStyle = ReaderTitleStyle.none;

/// 自定义标题样式的 HTML 源码（`_chapterTitleStyle == custom` 时生效）
  String _chapterTitleHtml = '';

/// 夜间标题 HTML（样式自带；空 = 夜间沿用 [_chapterTitleHtml]）
  String _chapterTitleHtmlNight = '';

/// 我保存的标题样式（HTML + 名字），来自 [ReaderStyleStore]
  List<TitleStylePreset> _myTitleStyles = [];

/// 自定义字体 id（null = 系统默认）；[_fontFamily] 是注册到引擎后的 family
  String? _fontId;

String? _fontFamily;

/// 页眉 / 页脚自定义格式串（左 / 中 / 右）。
  /// 只要有一个非空就走"格式串"渲染，否则退回「信息栏项目」开关的老逻辑。
  String _headerL = '';

String _headerC = '';

String _headerR = '';

String _footerL = '';

String _footerC = '';

String _footerR = '';

/// 电量缓存（格式串里的 `b` 用它；60 秒有效，避免每页都去问一次原生）
  int? _batteryPct;

DateTime? _batteryAt;

bool _batteryFetching = false;

/// 当前生效的样式 id（只用于卡片上打「当前」标；null = 手调过、无样式）
  String? _activeStyleId;

/// 日夜自动切换：白天 / 夜间各绑定一套样式（null = 只切底色，不换样式）
  String? _dayStyleId;

String? _nightStyleId;

/// 日夜是否跟随系统 / 全局明暗（默认跟随；用户手动切过一次就关掉，
  /// 避免"我自己点了夜间，系统一翻白天又被切回去"）。
  bool _followSystem = true;

/// 偏好是否已恢复完（恢复前的全局明暗回调要忽略，否则会按默认值乱切）
  bool _prefsReady = false;

final ReaderStyleStore _styleStore = ReaderStyleStore();

/// 专注加粗：长段开头加粗描述（参考图 IMG_8494/8495）
  bool _focusBold = false;

/// 标题对齐：0 靠左 / 1 居中
  int _titleAlign = 0;

/// 标题样式：0 朴素
  int _titleStyle = 0;

/// 隐藏重复标题：章首正文与章名相同时不再显示一遍（默认开）
  bool _hideRepeatTitle = true;

// ── 阅读设置（截图 IMG_71a10）────────────────────────────────
  ReadingSettings _rs = ReadingSettings();

/// 分页结果（上下模式为空 —— 那个模式不分页）
  List<BookPage> _pages = const [];

/// `_pages` 里**每一页所属的章号**（与 `_pages` 等长）。
  ///
  /// 为什么需要：无缝翻页会把**下一章的页**直接拼到 `_pages` 末尾
  /// （内容级无缝，参考 Legado：滑到章末继续滑就是下一章），
  /// 于是 `_pages` 不再"只属于一章" ⇒ 页码、进度、书签、标题都必须按
  /// **每页自己的章号**来判，而不是统用 `_index`。
  List<int> _pageChapterOf = const [];

/// 已经拼到 `_pages` 末尾的章节号（-1 = 尚未拼）
  int _appendedChapter = -1;

/// 正在后台排版的"下一章"（防重复拼接：分页要跨多帧，期间可能被再次触发）
  int _appendingChapter = -1;

/// 无缝拼接的页数上限：防止一次读几十章后 `_pages` 无限增长。
  /// 超过后停止"提前拼下一章"，退化成原来的点击/按钮翻章（功能不受影响）。
  static const int _kSeamlessPageCap = 400;

/// 章末/章首"越界滑动"切章的节流时间戳 —— 一次拖动会连续派发多帧
  /// `OverscrollNotification`，不节流会被切到后面好几章去。
  DateTime? _lastEdgeTurnAt;

// ── 上下滚动模式的「无缝连读」────────────────────────────────
  //
  // 滚动模式没有"页"，所以无缝不是拼页、而是把**下一章的正文接着排在
  // 同一个滚动视图里**：滚到底自然接下一章，不用点「下一章」。
  /// 当前滚动视图里按顺序渲染的章节（首项 = 基准章；换章/目录跳转时重建）
  List<int> _scrollChapters = const [];

/// 每一章在滚动视图里的定位键（判断"滚到哪一章了"用）
  final Map<int, GlobalKey> _scrollKeys = {};

/// 滚动时判定"当前章"的节流时间戳
  DateTime? _scrollSyncAt;

/// 滚动视图的"代次"：换章时 +1 ⇒ key 变化 ⇒ 回到章首。
  /// 章链内部追加/裁剪章节**不动它**（否则滚动位置会被重置）。
  int _scrollEpoch = 0;

/// 还没缓存、正在为"无缝连读"补抓的章节（防每次滚动都重复请求）
  int _appendFetchChapter = -1;

DateTime? _appendFetchAt;

// ── 漫画（Legado bookSourceType=2）───────────────────────────
  //
  // 漫画源的正文规则返回的是**图片 URL 列表**，不是文字。
  // 引擎返回 `{ok:true, type:'images', images:[...]}`；
  // `BookSourceService.content()` 已把它带出来。
  //
  // 渲染策略：**纵向连续滚动**（不是一图一页）。
  // 理由：手机窄屏下单张漫画图通常比屏幕高，一图一页要额外缩放，
  // 而纵向滚动是主流漫画 App 的做法，也省掉分页度量。
  List<String> _images = const [];

/// 本章图片的请求头（引擎从正文规则尾部 `@Header:{...}` 解析出来）。
  /// 漫画图床（如 i.hamreus.com）按 Referer/UA 判防盗链，缺失就是 403 空图。
  Map<String, String> _mangaImgHeaders = const {};

/// **文字章附带的插图**（引擎随 `content` 一起回的 `images`）。
  /// 纯图章不存在这里（那种章走 [_images] → 图片阅读模式）✓；
  /// 这里只用于「图片模式」面板列图/保存 ✓，不参与正文渲染 ✓。
  List<String> _chapterImages = const [];

/// 当前页下标（分页模式下用，与 _index 章节下标区分）
  int _pageIndex = 0;

/// 分页进行中
  bool _paginating = false;

/// 分页用的视口尺寸（LayoutBuilder 给出）
  Size _viewport = Size.zero;

/// 🆕 **分页代次号**（单调递增 ✓）—— `_paginate()` 是"忘了 await 的后台任务" ✓，
  ///   每批之间 `await endOfFrame` 会跨很多帧 ✗ → 分页途中切章 / 旋屏会让
  ///   **两次分页同时在跑** ✗，后结束的那个把 `_pages` 覆盖成**上一章**的页 ✗。
  ///   每次开始分页 `final gen = ++_paginateGen;` ✓，
  ///   `await` 回来先校验 `gen == _paginateGen` ✓，不等就直接 return ✓。
  int _paginateGen = 0;

/// ✅ **`_pages` 属于哪一章**（`_index` ✓）。`_pages` 被换成**章节不同**的
  ///   分页时，页号语义完全变了 ✗ → 必须把 `_pageIndex` 归零 ✓（越界崩溃的根因 ✓）。
  ///   同一章内重排（改字号 / 旋屏 ✓）则**保留阅读位置** ✓（见 [_pageAnchor]）✓。
  int _pagesChapter = -1;

/// 重排前记下的"当前页首块"锚点 ✓ —— 同章重排后按它把 `_pageIndex` 找回来 ✓
  /// （`null` = 不需要恢复 ✓）。字段类型：(块下标 ✓, 块内字符偏移 ✓)。
  (int, int)? _pageAnchor;

// ── 朗读（听书）─────────────────────────────────────────────
  //
  // ⚠️ 不需要任何插件：iOS 端 `ios/Runner/TtsEngine.swift` 用系统自带的
  // `AVSpeechSynthesizer` 实现，已在 AppDelegate 注册；Dart 侧 TtsService
  // 已有 rate/pitch/currentIndex/onFinished。
  // **加 flutter_tts 反而会闪退**（TrollStore 侧载不能新增原生插件）。
  final _tts = TtsService.instance;

/// 跟读高亮的颜色下标（截图里的 6 个颜色）
  int _ttsColor = 2;

/// 跟读高亮：关 / 当前句 / 当前段
  int _ttsHighlight = 1;

/// 定时（分钟）；0 = 关
  int _ttsTimer = 0;

/// 音量（0~100，参考图 IMG_8489 显示 100%）
  int _ttsVolume = 100;

/// 跟随系统音色（参考图 IMG_8488「跟随系统」）
  bool _ttsFollowSystem = true;

/// A4 双音色朗读（旁白/对话各一个音色，仅 EasyVoice 网络源生效）
  bool _ttsDualVoice = false;

/// A4 旁白音色（EasyVoice 音色名，空 = 源默认）
  String _ttsNarratorVoice = '';

/// A4 对话音色（EasyVoice 音色名，空 = 源默认）
  String _ttsDialogueVoice = '';

/// A4 旁白音色输入框（UI 层，与 `_ttsNarratorVoice` 同步）
  final TextEditingController _ttsNarratorCtl = TextEditingController();

/// A4 对话音色输入框（UI 层，与 `_ttsDialogueVoice` 同步）
  final TextEditingController _ttsDialogueCtl = TextEditingController();

/// 番茄钟浮层是否显示
  bool _showPomodoro = false;

/// 右侧竖条**亮度滑杆**的当前值（0.1~1.0，直接写系统屏幕亮度）。
  ///
  /// 用户 2026-10-14：「右侧的亮度调整能不能直接有个调整条、不是只有一个按钮，
  /// 而且拖不动」⇒ 竖条里直接放滑杆（与漫画阅读器同款），
  /// 原来那个"点开→底部弹层里再拖"的实现已删。
  double _dockBrightnessValue = 1.0;

/// 听书迷你条已收成光碟（向左快滑收起 ✓，点光碟展开 ✓，朗读不停 ✓）
  bool _ttsDiscCollapsed = false;

/// 光碟位置（Stack 内左上角坐标，null = 首次收起时按右下角初始化）
  Offset? _ttsDiscPos;

// ✅ **TTS 面板的两个真实设置**（本轮新增 ✓）——此前那两个开关是**纯装饰** ✗：
  //   `_ttsSwitch` 写死 `onChanged: null` ✗ + `value` 写死 `false` ✗ → 永远显示关闭、且点不动 ✗✗。
  //   `_ttsSwitch` 现已支持回调 ✓（本轮同批 ✓）→ 这两个字段让它**真的能拨 + 会落盘** ✓✓。
  //   ⚠️ **行为接线分两步** ✗✓：本轮到"能拨、会记住"✓；"点朗读真的进播放页 / 朗读真的自动翻页"
  //     需要改两处调用点（底栏朗读入口 ✓ 跟读高亮 ✓）→ **下一轮**做 ✓，
  //     所以开关标题暂时保留"**行为待接**"字样 ✓（**不提前摘标注** ✗ —— 摘了就是新的假话 ✓）。
  /// 点底栏「朗读」时是否**直接进沉浸式播放页** ✓（`TtsFullPlayerPage` ✓ 本页已有用法 ✓）
  bool _ttsDirectPlayer = false;

/// 朗读时是否**自动把正在读的段落滚进视口**（跟读高亮本来就有 ✓）
///
/// 用户 2026-10-29：「为啥朗读的时候不跟随翻页呢」——
/// 默认原来是 **false**，等于这个功能默认是关的，用户根本不知道要去开。
/// 现在默认开：朗读不跟着翻页才是"坏了"的行为。
/// 存过偏好的用户仍以自己存的那个值为准（见 `_restorePrefs`）。
  bool _ttsAutoLocate = true;

// ── 屏幕休眠 ────────────────────────────────────────────────
  /// 当前是否已请求"禁止息屏"（避免重复调用 + 退出时要知道该不该关）
  bool _awakeRequested = false;

// ── 书签（截图 IMG_8100）────────────────────────────────────
  /// 6 种书签颜色（截图里的那 6 个圆点）
  static const _bookmarkColors = <Color>[
    Color(0xFFF5C842), // 黄
    Color(0xFF8FD48F), // 绿
    Color(0xFF7EC8F0), // 蓝
    Color(0xFFF07E9E), // 粉
    Color(0xFFC88FE8), // 紫
    Color(0xFFA8B4E0), // 蓝紫
  ];

/// 本章书签：段落下标 → 颜色
  final Map<int, Color> _bookmarks = {};

/// 书签备注：段落下标 → 备注文字（用户 2026-10-25：加书签要能写备注，
  /// 默认填「章节名 + 正文片段」）。与颜色分开存，老存档照样能读。
  final Map<int, String> _bookmarkNotes = {};

/// `_bookmarks` 当前反映的章节下标（-1 = 尚未加载）。
  /// 修复「书签串章」：`_go` / `_jumpTo` / 目录跳转都是**先** `_index = next`
  /// **再** `_loadChapter(next)` ⇒ 旧代码在 `_loadChapter` 里用 `if (i != _index)`
  /// 判断"是否切章"**恒为假** ⇒ 切章从不换书签，A 章书签在每章同段落处都显示。
  /// 这里显式记住"这批书签属于哪一章"，切章时按章换入换出。
  int _bookmarksChapter = -1;

/// 「不再提示」—— 下次直接用上次选的颜色
  bool _bookmarkNoAsk = false;

int _bookmarkLastColor = 0;

/// 信息栏可选项（顺序 = 横向滑动的顺序）
  static const List<String> _statusItemKeys = [
    '时间',
    '章节',
    '电量',
    '书名',
    '页码',
    '进度',
  ];

/// 顶部 / 底部功能面板的位置（屏幕坐标）。
  ///
  /// 用来把**壁纸在面板位置上的那一块**裁出来当面板背景 —— 所以必须知道
  /// 面板真实落在屏幕哪个位置。build 结束后量一次，位置变了才 setState。
  final GlobalKey _topBarKey = GlobalKey();

final GlobalKey _bottomBarKey = GlobalKey();

Rect? _topBarRect;

Rect? _bottomBarRect;

static const _bgs = <List<Color>>[
    [Color(0xFFFFFFFF), Color(0xFF1A1A1A)], // 默认（白）
    [Color(0xFFC7E0C0), Color(0xFF23301F)], // 护眼
    [Color(0xFFD7C4A1), Color(0xFF3B2F1E)], // 牛皮纸
    [Color(0xFFF5EFE0), Color(0xFF3A3226)], // 米黄
    [Color(0xFFE6E9DA), Color(0xFF33332A)], // 竹露
    [Color(0xFF2B2B2B), Color(0xFFB8B8B8)], // 夜间
  ];

/// 底线可选色（参考图 IMG_8497/8498；银白对应浅底上的银灰）
  static const _underlineColors = <String, Color>{
    '墨黑': Color(0xFF1A1A1A),
    '深灰': Color(0xFF4A4A4A),
    '赭棕': Color(0xFF8B5A2B),
    '靛青': Color(0xFF1F3A5F),
    '银白': Color(0xFFB0B0B0),
  };

/// 护眼提醒定时器（C7，30s 检查一次）
  Timer? _eyeTimer;

/// 本次连续阅读起点（墙钟，后台恢复自动补齐 ✓）
  DateTime _eyeBreakStart = DateTime.now();

/// 已弹过提醒（避免重复弹）
  bool _eyeBreakShown = false;

Timer? _sleepTimer;

// ── 自动阅读（对齐 Legado，2026-10-23）────────────────────────
  /// 是否正在自动阅读（运行态，不持久化；速度持久化在 `_rs.autoReadIntervalSec`）
  bool _autoReadOn = false;

Timer? _autoReadTimer;

/// 「上下滚动」模式下自动滚屏用的控制器（分页模式不用它）
  final ScrollController _scrollReadCtrl = ScrollController();

/// ⚡ `_savePrefs` 的**防抖句柄** ✓（性能项 ✓）。
  ///   背景 ✓：`_savePrefs` 一次要串行写 8~15 个 prefs ✗，而滑杆/悬浮球拖动
  ///   会**每秒触发几十次** ✗✗ → 大量 platform channel 往返 = 卡顿 ✓。
  ///   `_savePrefs` 是**幂等**的 ✓（写的是当前字段值，不累加 ✓）→ 合并安全 ✓✓。
  ///   用法 ✓：**高频、不等结果**的调用点改用 [_scheduleSavePrefs] ✓；
  ///   **需要"已保存"语义**的调用点（如"存预设后弹提示"✓）继续 `await _savePrefs()` ✗。
  Timer? _saveDebounce;

/// ✅ **重排防抖**（[high] 修复 ✓）：排版面板的字号 / 行距 / 边距滑杆改动后
  ///   必须重排 ✓（否则 `_pages` 还是按旧字号度量的 ✗，正文按新字号渲染 ✗ →
  ///   每页内容高于视口，而承载它的 `ListView` 是 `NeverScrollableScrollPhysics`
  ///   ✓ → 超出的部分**既不能滚也读不到** ✗）。
  ///   滑杆 `onChanged` 每秒触发几十次 ✗ → 与 [_scheduleSavePrefs] 同款 300ms 防抖 ✓。
  Timer? _repaginateDebounce;

/// ✅ **阅读时长：本次会话"已累计到"的时间点** ✓（`ReadingTimeService` 接线 ✓ ——
  ///   为「阅读计划 / 阅读热力图」提供真实数据 ✓；此前这两处**完全没有时长数据** ✗）。
  ///   为什么要"**增量累计**"✗：本页高频改动（滑杆/悬浮球拖动 ✓）会反复调 [_scheduleSavePrefs] ✓ ——
  ///   若每次都交"会话开始的整段差值" ✗ → **重复计时长** ✗✗；这里每交一次就把时间点**前移** ✓，
  ///   于是每次只交"上次之后"的增量 ✓✓（多次增量之和 = 真实停留时长 ✓）。
  ///   `addSession` 内部另有 1 秒下限 ✓ 与单次 2 小时上限 ✓（防"忘记退出"刷爆一天 ✓）。
  DateTime _sessionStamp = DateTime.now();

/// 本书是否开启了「独立排版」✓ —— 由 [_restorePrefs] 读入 ✓、由那 3 个开关切换 ✓、
  /// 由 [_savePrefs] 决定"改动写覆盖还是写全局" ✓（**分流** ✓）。
  bool _independent = false;

/// 是否已经「进入」沉浸态（避免没进过就调 exit —— exit 在无现场记录时会
  /// 强制回到默认模式并重置方向，可能覆盖别的页面设的锁 ✗）。
  bool _readerImmersive = false;

// ── 章节加载 ────────────────────────────────────────────────

  /// "当前这一次**可见**加载"的序号（只有非预取的加载才自增 ✓）。
  /// 用来丢弃**过期响应** ✓ —— 见 [_loadChapter] 里 await 之后的校验 ✓
  int _loadSeq = 0;

/// SelectionArea 当前选中的纯文本（浮动工具条的动作都读它）
  String _selectedText = '';

/// 本书是否开启净化（默认关，按书单独记）
  bool _purifyOn = false;

/// 滚动视图里"下一章"的段落（带繁简转换的**按章缓存**）。
  ///
  /// 不缓存的话每帧滚动同步都会把后面几章全转换一遍（繁简表不便宜）；
  /// 缓存里记了当时的转换模式，模式一变自动重算。
  final Map<int, ({ChineseConvertMode mode, List<String> paras})> _scrollConv =
      {};

// ── A1 对话气泡几何 ────────────────────────────────────────────
  //
  // 🔴 这 4 个常量是**渲染与分页共用的唯一真源** ✗：气泡把对话段落缩窄 +
  //    加内衬 ✗，分页若仍按正文全宽度量 ✓，渲染就会比量出来高 ⇒ 整页溢出
  //    屏幕底部 ✗（用户实测："气泡以及里面的文字容易出整个屏幕" ✓）。
  //    改这里两边一起变 ✓，不可能再各算一套 ✓。
  static const double _kBubbleWidthFactor = 0.72;

// 气泡最大宽 = 视口宽 × 此系数
  static const double _kBubblePadH = 12;

// 左右内衬
  static const double _kBubblePadV = 8;

// 上下内衬
  static const double _kBubbleBorder = 1;

// ── 呼出面板：双击 或 双指单击（2026-10-22 用户拍板）──────────────
  // 全部走 Listener 的**原始指针流**，不进手势竞技场：
  //   正文里的 long-press / 滚动 / PageView 识别器抢不到，单指双指都稳定
  // · 双击：两次"单击候选"间隔 ≤[_tapWindowMs]、位移 ≤60 ⇒ 开合面板，并取消第一击的翻页
  // · 双指：两指同时按着且各自都是轻点（≤400ms、位移 ≤22）⇒ 开合面板（只触发一次）
  // · 单击：延迟 [_tapWindowMs] 后翻页 / 收面板；单击不再呼出面板
  //
  // ⚠️ 双击窗口与单击延迟**必须是同一个值**：
  //   · 延迟 < 窗口 → 第一击先翻页、第二击又弹面板（"翻页 + 呼出"）
  //   · 延迟 > 窗口 → 中间那段（窗口~延迟）的"慢双击"被拆成两次单击（盲区）
  //   相等时：窗口内的第二击一定会走双击分支并 cancel 第一击的 timer，
  //   所以不会出现"一次双击翻两页"；超过窗口的两次点击本来就是两次单击。
  static const int _tapWindowMs = 320;

final Map<int, ({Offset pos, DateTime at})> _ptrs = {};

bool _twoFingerSeq = false;

bool _firedTwoFinger = false;

DateTime? _lastTapAt;

Offset? _lastTapPos;

Timer? _tapTimer;

/// 选区容器（滚动 / 分页各一个），用来在双击呼面板时清掉选区
  final GlobalKey<SelectableRegionState> _selKeyScroll = GlobalKey();

final GlobalKey<SelectableRegionState> _selKeyPage = GlobalKey();

/// 这段时间内不弹选区菜单（双击会误选一个词，见 [_onPtrUp]）
  DateTime _menuSuppressUntil = DateTime.fromMillisecondsSinceEpoch(0);

/// 右侧竖条里的**亮度滑杆**（竖向，直接拖，不走弹层）。
  ///
  /// 为什么不再是"一个按钮点开"（用户 2026-10-14）：
  ///   ① 要"直接有个调整条"；② 原来那个底部弹层的滑杆**拖不动** ——
  ///   根因是 `var value = v;` 写在了 `StatefulBuilder` 的 builder **里面**，
  ///   每次 rebuild 都被重置回初始值 ⇒ 拇指一拖就被弹回。这里改成竖条内联滑杆，
  ///   值存在 State 字段里，天然不会被重置。
  ///
  /// 2026-10-21 重做视觉（用户："弄好看点"）：
  ///   不再用 Material `Slider`（旋转 90° 后轨道粗、两端留白大、还有一段很长的
  ///   灰条 ✗）。改成自绘的三件套：
  ///     · 细胶囊轨道（5 宽、淡底）
  ///     · 自下而上的**渐变**填充（亮度越低越淡）
  ///     · 小圆点拇指（带描边 + 轻微投影）
  ///   高度固定 [_brightnessTrackH]，比原来 130 短得多 ✓。
  static const double _brightnessTrackH = 120;

/// 轨道宽度（用户 2026-10-21：加宽一点）
  static const double _brightnessTrackW = 16;

/// 章标题块的固定高度（null = 用默认标题，按文本度量）。
  ///
  /// 用解析器的**离线度量**（TextPainter + 同一套样式/宽度）⇒ 分页与渲染一致。
  ///
  /// **带缓存**：翻页/重排时同一章会被反复问高度，而 `TitleHtml.measure`
  /// 要做完整的 compile + TextPainter 布局，开销不小。
  /// key 覆盖**所有影响高度的变量**（任一变化即整体失效），所以结果与现算等价。
  final Map<int, double?> _titleHeightCache = <int, double?>{};

String _titleHeightKey = '';

static const _layoutTabs = ['样式', '主题', '文字', '边距', '底线'];

// ── 内置背景（参考图 IMG_8502）──────────────────────────────
  /// 16 款内置背景：名称 + 主色（质感用色值近似表达，
  /// 选中即设为阅读背景，和"自定义背景"同一条链路）
  static const _builtinBgs = <(String, Color)>[
    ('纯白', Color(0xFFFFFFFF)),
    ('纯色米黄', Color(0xFFF5EFE0)),
    ('纯色护眼', Color(0xFFC7E0C0)),
    ('牛皮纸', Color(0xFFD7C4A1)),
    ('竹露', Color(0xFFE6E9DA)),
    ('纸张纹理', Color(0xFFF4F0E6)),
    ('光影纹理', Color(0xFFF2EEE8)),
    ('植物影子', Color(0xFFE2E8D8)),
    ('光影投影', Color(0xFFE6E2DA)),
    ('天空', Color(0xFFDFE8F0)),
    ('晨光', Color(0xFFFFF6E6)),
    ('暮色', Color(0xFFB0A8C8)),
    ('靛蓝', Color(0xFFDFE3F0)),
    ('青绿', Color(0xFFD8EAD9)),
    ('淡粉', Color(0xFFF8E4E4)),
    ('夜空', Color(0xFF1E1E26)),
  ];

/// 听书「念完自动续下一章」的预约标记。
  ///
  /// 为什么需要它（2026-10-14 修）：原实现是 `onFinished → _go(1)` 之后用
  /// `addPostFrameCallback` **下一帧**就调 `_startTts()`。但 `_go` 只发起
  /// **异步**加载（`_loadChapter` 会先把 `_paragraphs` 清空，新正文要等网络
  /// 回来），下一帧 `_paragraphs` 仍是空 ⇒ `_startTts()` 误判"这一章没有可
  /// 朗读的正文" ⇒ **自动连播当场中断** ✗。现在改成"预约"：真正的续读发生在
  /// `_loadChapter` 的正文就绪处。
  bool _ttsAutoNext = false;

static const _ttsTabs = ['声音', '跟读', '定时', '高级'];

Timer? _ttsTimerHandle;

/// TtsService 切出来的段落（供面板显示"正在念的那句"）
  /// 缓存同一份切分结果，章节内容变化时清缓存（否则每次访问都全量重切）
  List<String>? _ttsSegsCache;

  void _closeSettingsPanel();
  Future<void> _setIndependent(bool v);
  double  get _autoTitleScale;
  double  get _titleHtmlBase;
  double  get _defaultTitleFontSize;
  double  get _titlePxScale;
  bool  get _showChapterTitle;
  int  get _blockOffset;
  double  get _pomodoroBottomOffset;
  Color  get _fg;
  String?  get _activeFileBgPath;
  String?  get _activeBgAsset;
  bool  get _hasImageBg;
  double  get _safeTop;
  double  get _safeBottom;
  bool  get _paperIsDark;
  Widget _pagePaper();
  void _precachePaper();
  Widget _nightDim(Widget child, {bool nightVersionInUse = false});
  Color  get _fgMuted;
  Color  get _bgTop;
  bool  get _isDarkBg;
  Color  get _sheetBg;
  void _clearHeaderFooterFormats();
  void _scheduleBarRectMeasure();
  Widget? _barBackdropImage();
  Widget _barBackdrop(Rect? rect, {required Widget child, required BorderRadius radius, required Color fallbackColor, List<BoxShadow>? shadow});
  Widget _sheetHandle();
  bool _onKey(KeyEvent e);
  void _applySleepMode();
  void _stopAutoRead();
  void _toggleAutoRead();
  void _scheduleAutoRead();
  void _autoScrollStep();
  void _clearChapterCache();
  void _scheduleRepaginate();
  void _scheduleSavePrefs();
  void _checkEyeBreak();
  void _showEyeBreakDialog();
  String  get _progressKey;
  String _bookmarksKey(int chapter);
  String _bookmarkNotesKey(int chapter);
  Map<int, String> _decodeNotes(String? raw);
  String _defaultBookmarkNote(int paraIndex);
  String  get _indepKey;
  Map<String, Object?> _layoutSnapshot();
  Future<void> _restorePrefs();
  void _applyReaderSystemUi();
  Future<void> _savePrefs();
  Future<void> _saveProgress();
  Future<void> _switchBookmarksTo(int chapter);
  Future<({bool ok, String? error, String content, List<String> images, Map<String, String> headers})> _contentWithCache(String url, {bool force = false});
  Future<void> _loadChapter(int i, {bool prefetchOnly = false, bool force = false});
  void _prefetchAhead(int from);
  Future<void> _prefetchIfWifi(int from, int n);
  void _prefetch(int i);
  void _evictIfNeeded();
  Widget _selectionMenu(BuildContext ctx, SelectableRegionState state);
  int _paragraphIndexForSelection(String sel);
  Future<void> _addPurifyFromSelection(String raw, {bool fromParagraph = false});
  Future<void> _showPurifyRuleEditor({String seedPattern = '', String seedName = ''});
  Future<void> _showSelectionTools(String sel);
  Widget _toolBtn(IconData icon, String label, VoidCallback onTap);
  List<String> _segmentWords(String text);
  void _openWebPage(String url, String title);
  Future<void> _shareText(String text);
  String _applyPurify(String raw);
  String  get _displayChapterName;
  String  get _purifyKey;
  Future<void> _togglePurify();
  Future<String> _fetchText(String url);
  void _showPurifySheet();
  List<String> _splitParagraphs(String raw);
  List<String> _applyConvert(List<String> paras);
  String _convertLabel(ChineseConvertMode m);
  void _go(int delta);
  void _toast(String m);
  Widget _contentArea(Color fg);
  Map<String, String>  get _mangaHeaders;
  Widget _mangaView(Color fg);
  Widget _scrollView(Color fg);
  List<String> _scrollParas(int ch);
  Widget _scrollChapterBlock(int ch, Color fg, {required bool first});
  Widget _illustrationStrip(Color fg);
  Widget _paragraphWidget(int pi, Color fg, {String? overrideText, int? chapter});
  Future<void> _showNoteBubble(ReaderNote note);
  int?  get _ttsParagraph;
  BoxDecoration? _ttsHighlightDecoration(int pi);
  Widget _wrapWithHighlight(int pi, Widget child);
  /// 朗读推进时，把「正在念的那一段」翻进视野
  /// （分页模式翻页；滚动模式由 `_wrapWithHighlight` 自己滚 —— 见那里的注释）
  void _followTtsSegment();
  TextStyle _bodyStyle(Color fg, {bool bold = false, bool noUnderline = false});
  double  get _bubbleMaxWidth;
  double  get _bubbleTextWidth;
  double  get _bubbleExtraV;
  Color  get _customBubbleBg;
  Color  get _customBubbleText;
  Widget _bubbleWrap(String text, Color fg, bool alignRight, BubblePalette palette);
  Future<bool> _assetIsDark(String asset);
  Future<void> _analyzeFileBg(String path);
  Future<void> _showBgImageSheet();
  Widget _bgWallCell(BuildContext ctx, String? asset, Color labelColor, bool isDark);
  double  get _effectiveHeaderPadTop;
  double _headerFooterHeight();
  int _chapterOfPage(int i);
  Widget _pageContent(Color fg, BookPage page, {int? chapter, bool paper = true});
  bool  get _hasHeaderFormat;
  bool  get _hasFooterFormat;
  String _resolveFormat(String tpl, double progress, [int? chapter]);
  String _batteryValue();
  Widget _formatRow(Color fg, String left, String center, String right, double progress, {int? chapter});
  Widget _statusHeader(Color fg, {double? progressOverride, int? chapter});
  Widget _statusFooter(Color fg, {bool showPage = true, int? chapter});
  Widget _pageBody(Color fg, BookPage page, {int? chapter});
  void _nextPageOrChapter();
  void _prevPageOrChapter();
  int _paragraphIndexOf(ParagraphBlock b);
  TextStyle _statusStyle(Color fg);
  Widget _statusText(String s, Color fg);
  Widget _batteryText(Color fg);
  void _clearSelectionSoon();
  void _onPtrDown(PointerDownEvent e);
  void _onPtrUp(PointerUpEvent e);
  void _onPtrCancel(PointerCancelEvent e);
  void _toggleBar();
  void _handleSingleTap(Offset pos);
  void _toggleDayNight({bool manual = true, bool silent = false});
  void _syncSystemDayNight({bool silent = true});
  void _markManualDayNight();
  ReaderStyle? _styleById(String? id);
  Widget _topBarCard(Color fg);
  void _applyDockBrightness(double dy);
  Widget _dockBrightness(Color fg);
  Future<void> _syncDockBrightness();
  Widget _topIcon(IconData icon, String tooltip, VoidCallback onTap, Color fg);
  Widget _sideDock(Color fg);
  Widget _dockButton(IconData icon, String tooltip, VoidCallback onTap, Color fg, {String? imageAsset});
  Widget _ttsMiniBar(Color fg);
  double _nextTtsRate(double v);
  void _openFullTtsPlayer();
  Widget _bottomNav(Color fg);
  Widget _navItem(IconData icon, String label, VoidCallback onTap, Color fg);
  FontWeight _fontWeightToW(double v);
  int _safePageIndex();
  (int, int)? _currentPageAnchor();
  int _pageIndexForAnchor((int, int) a, List<BookPage> pages);
  bool  get _seamlessPaging;
  (int, int) _chapterPageRange(int chapter);
  int  get _localPageNo;
  int  get _localPageCount;
  String  get _chapterTitleSource;
  TitleHtmlDoc? _titleDoc(int chapter);
  String _titleHeightSignature();
  double? _titleHeightFor(int chapter);
  Widget _titleWidget(int chapter, {required Color fallbackColor, double? height});
  BookTypography _layoutTypography([int? chapter]);
  List<BookBlock> _blocksForChapter(int chapter, List<String> paras);
  double  get _textAreaHeight;
  Future<void> _appendNextChapter(int gen, int cur);
  void _maybeAppendAhead();
  bool  get _atLastDisplayedPage;
  bool _onPageScrollNotification(ScrollNotification n);
  void _edgeTurn(int delta);
  bool  get _dualPageActive;
  void _setPageIndex(int i);
  void _requestAppendFetch(int chapter);
  void _resetScrollChain(int chapter);
  List<int>  get _scrollChain;
  void _maybeAppendScrollAhead();
  void _trimScrollChainBefore();
  bool _onScrollNotification(ScrollNotification n);
  void _syncChapterFromScrollViewport();
  void _syncChapterFromScroll(int ch);
  void _syncChapterWithPage(int pageIndex);
  void _repaginateLayout();
  Future<void> _paginate();
  Future<void> _showBookSearch();
  void _jumpTo(int i);
  void _showLayoutSheet();
  List<Widget> _layoutStyleTab(BuildContext ctx, StateSetter setSheet);
  Widget _styleCard(ReaderStyle s, StateSetter setSheet);
  Widget _titleStyleChip(TitleStylePreset t, StateSetter setSheet);
  Widget _myStyleRow(ReaderStyle s, StateSetter setSheet);
  Widget _styleThumb(ReaderStyle s, {bool selected = false});
  String _pageModeLabel(String id);
  Widget _stylePreview(ReaderStyle s, {bool selected = false});
  Future<void> _showStyleActions(ReaderStyle s);
  Widget _bgImageChip(String? asset, void Function(VoidCallback) upd);
  List<Widget> _layoutThemeTab(void Function(VoidCallback) upd);
  Future<void> _showBuiltinBgPanel(void Function(VoidCallback) upd);
  Future<void> _showImageBgPicker(void Function(VoidCallback) upd);
  bool _isPreset(_TextPreset p);
  List<Widget> _layoutTextTab(void Function(VoidCallback) upd);
  Widget _layoutToggleRow(String title, String desc, bool value, ValueChanged<bool> onChanged);
  List<Widget> _layoutMarginTab(void Function(VoidCallback) upd);
  List<Widget> _layoutUnderlineTab(void Function(VoidCallback) upd);
  Widget _layoutLabel(String s);
  Future<void> _showAddBookmark(int paraIndex);
  String _bookmarkColorName(int i);
  Future<void> _onParagraphLongPress(int i);
  Future<void> _translateParagraph(String text);
  String _searchSeed(String t);
  /// 长按菜单里的一个动作（**纯文字，不带图标**，见实现处说明）
  Widget _longPressAction(String label, VoidCallback onTap);
  Future<String?> _showNoteInput(String text);
  Map<String, dynamic> _presetSnapshot();
  void _applyPresetMap(Map<String, dynamic> m);
  Future<void> _applyPreset(String name);
  Future<void> _showSavePresetDialog(TextEditingController ctrl);
  Future<String?> _promptTitleHtml(String initial);
  Future<void> _editTitleHtml();
  Future<String?> _promptName(String title, String label, String initial);
  Future<void> _saveCurrentTitleStyle();
  Future<void> _deleteTitleStyle(TitleStylePreset t);
  void _applyTitleStyle(TitleStylePreset t);
  Future<({String hL, String hC, String hR, String fL, String fC, String fR})?> _promptHeaderFooter({required String hL, required String hC, required String hR, required String fL, required String fC, required String fR});
  Future<void> _editHeaderFooter();
  Future<void> _showStyleShare();
  Future<void> _importSrsStyle();
  ReaderStyle _styleSnapshot(String id, String name, {bool builtin = false});
  Future<void> _openTitleStylesPage();
  Future<void> _openStylesPage();
  void _applyReaderStyle(ReaderStyle s);
  void _applyFontId(String id);
  Future<void> _showFontLibrary();
  Future<void> _importFont();
  Future<void> _deleteFont(ReaderFont f);
  Future<void> _saveCurrentAsStyle();
  Future<void> _renameStyle(ReaderStyle s);
  Future<void> _deleteStyle(ReaderStyle s);
  ReaderStyle _patched(ReaderStyle s, Map<String, dynamic> patch);
  Future<void> _duplicateStyle(ReaderStyle s);
  Future<void> _editStyle(ReaderStyle style);
  Future<void> _importStyle();
  Widget _layoutSlider(String label, double value, double min, double max, String display, ValueChanged<double> onChanged, {double? step});
  void _showTtsSheet();
  Future<void> _startTts();
  List<String?>? _buildSegmentVoices();
  List<Widget> _ttsVoiceTab(void Function(VoidCallback) upd);
  Widget _ttsStepper(String label, String display, {required VoidCallback onMinus, required VoidCallback onPlus});
  void _showTtsVoicePanel();
  void _ttsSpeakSample();
  Widget _ttsVoiceField(String label, TextEditingController ctl, VoidCallback onChanged);
  List<Widget> _ttsFollowTab(void Function(VoidCallback) upd);
  List<Widget> _ttsTimerTab(void Function(VoidCallback) upd);
  List<Widget> _ttsAdvancedTab();
  void _scheduleTtsTimer(int minutes);
  Widget _ttsLabel(String s);
  Widget _ttsSwitch(String title, String sub, bool value, {ValueChanged<bool>? onChanged});
  List<String>  get _ttsSegments;
  void _invalidateTtsSegs();
  void _showAiSummary();
  Future<void> _showAiConfig();
  Future<void> _runAiAction(String action);
  Future<void> _askAiQuestion();
  Future<void> _showAiLoading(String title, Future<String> Function() task);
  void _showAiResult(String title, String content);
  void _showImageMode();
  Future<void> _previewImage(BuildContext parentCtx, String url);
  Future<bool> _saveImage(String url);
  Future<void> _jumpToChapter(int chapterIndex);
  Widget _settingsPanel(Color fg, {double extraBottom = 0});
  Widget _setRowRight(String label, Widget child);
  Widget _setSwitch(String label, String sub, bool value, ValueChanged<bool> onChanged);
  Widget _bubbleColorChip(String label, Color color, ValueChanged<Color> onPicked);
  Widget _chip(String label, bool on, VoidCallback onTap, {bool compact = false});
  Widget _sectionLabel(String text);
  Future<void> _showTapZoneEditor();
  Widget _zoneBtn(String label, VoidCallback onTap);
  Widget _tocJumpBtn(IconData icon, String tip, VoidCallback onTap);
  Future<void> _showToc({int initialTab = 0});
  int? _pageOfParagraph(int pi);
}

class _BookSourceReaderPageStateImpl
    extends _BookSourceReaderPageState
    with _ReaderPart01, _ReaderPart02, _ReaderPart03, _ReaderPart04, _ReaderPart05, _ReaderPart06, _ReaderPart07 {}


/// 手机状态栏样式的**电量图形**（空心电池 + 右侧电极 + 按比例填充）。
///
/// 尺寸随「信息栏字号」缩放（[height]），颜色沿用信息栏的淡前景色 ✓。
class _BatteryGlyph extends StatelessWidget {
  const _BatteryGlyph({
    required this.level,
    required this.color,
    this.height = 10,
  });

  /// 0.0 ~ 1.0
  final double level;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(height * 2.0, height),
      painter: _BatteryGlyphPainter(level: level, color: color),
    );
  }
}

class _BatteryGlyphPainter extends CustomPainter {
  _BatteryGlyphPainter({required this.level, required this.color});

  final double level;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final stroke = (h * 0.09).clamp(0.8, 2.0);
    final capW = h * 0.13;
    final bodyW = size.width - capW - h * 0.06;
    final radius = Radius.circular(h * 0.28);

    final paint = Paint()
      ..isAntiAlias = true
      ..color = color;

    // 外壳（描边）
    final border = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(stroke / 2, stroke / 2, bodyW - stroke, h - stroke),
        radius,
      ),
      border,
    );

    // 右侧电极
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(bodyW + h * 0.06, h * 0.3, capW, h * 0.4),
        Radius.circular(capW * 0.5),
      ),
      paint,
    );

    // 电量填充
    final inset = h * 0.22;
    final innerW = (bodyW - inset * 2) * level.clamp(0.0, 1.0);
    if (innerW > 0.5) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(inset, inset, innerW, h - inset * 2),
          Radius.circular(h * 0.14),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BatteryGlyphPainter old) =>
      old.level != level || old.color != color;
}

/// 正文排版预设（中文正文的三种"呼吸感"）。
///
/// - 紧凑：小字 + 紧行距，一屏字多，适合快速扫读
/// - 标准：默认，18px / 1.72 行距 / 0.5 字段距 / 0.3 字距
/// - 宽松：大字 + 松行距，适合长时间慢读
enum _TextPreset {
  compact('紧凑', 17, 1.55, 0.2, 0.35),
  standard('标准', 18, 1.72, 0.3, 0.5),
  loose('宽松', 19, 1.9, 0.5, 0.9);

  const _TextPreset(
    this.label,
    this.size,
    this.lineHeight,
    this.letterSpacing,
    this.paraSpacing,
  );

  final String label;
  final double size;
  final double lineHeight;
  final double letterSpacing;
  final double paraSpacing;
}

/// 「左滑露出操作」的小容器（样式卡片 / 列表行用）。
///
/// 为什么自己做：`Dismissible` 只能"滑走删除"，不会停在中途露出按钮；
/// 这里用 Transform + 横向拖拽就够，不引入依赖。
class _SwipeActions extends StatefulWidget {
  const _SwipeActions({
    required this.child,
    required this.actions,
    this.background,
  });

  final Widget child;
  final List<({String label, IconData icon, Color tint, VoidCallback onTap})>
  actions;

  /// 前景卡片的不透明底色（否则滑开时会透出后面的按钮）
  final Color? background;

  @override
  State<_SwipeActions> createState() => _SwipeActionsState();
}

class _SwipeActionsState extends State<_SwipeActions> {
  static const double _actionWidth = 56;

  double _dx = 0;
  bool _dragging = false;

  double get _max => widget.actions.length * _actionWidth;

  void _endDrag(DragEndDetails d) {
    final v = d.velocity.pixelsPerSecond.dx;
    final open = v < -250 || (v <= 250 && _dx < -_max / 2);
    setState(() {
      _dragging = false;
      _dx = open ? -_max : 0;
    });
  }

  void _close() => setState(() => _dx = 0);

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        // 背后的操作按钮：只占右端 _max 宽，滑开多少露多少
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: _max,
          child: Row(
            children: [
              for (final a in widget.actions)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _close();
                      a.onTap();
                    },
                    child: Container(
                      color: a.tint,
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(a.icon, size: 18, color: Colors.white),
                          const SizedBox(height: 2),
                          Text(
                            a.label,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => setState(() => _dragging = true),
          onHorizontalDragUpdate: (d) {
            setState(() {
              _dx = (_dx + d.delta.dx).clamp(-_max, 0.0);
            });
          },
          onHorizontalDragEnd: _endDrag,
          child: AnimatedContainer(
            duration: _dragging
                ? Duration.zero
                : const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(_dx, 0, 0),
            child: Container(color: widget.background, child: widget.child),
          ),
        ),
      ],
    );
  }
}
