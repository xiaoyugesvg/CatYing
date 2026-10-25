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

import '../models/book_source.dart';
import '../models/book_content.dart';
import '../models/reader_style.dart';
import '../models/reader_bg_assets.dart';
import '../models/reader_title_style.dart';
import '../models/reading_settings.dart';
import '../novel_source/novel_chinese_converter.dart';
import '../services/book_paginator.dart';
import '../services/book_source_service.dart';
import '../services/chapter_alignment.dart';
import '../services/reader_font_service.dart';
import '../services/reader_notes_service.dart';
import '../services/reader_style_store.dart';
import 'reader_styles_page.dart';
import 'reader_title_styles_page.dart';
import '../services/srs_style_importer.dart';
import '../services/title_html_parser.dart';
import '../services/tts_service.dart';
import '../services/ai_service.dart';
import '../services/reading_time_service.dart';
import '../services/bsr_independent_layout.dart';
import '../utils/header_footer_format.dart';
import '../widgets/book_page_cover.dart';
import '../widgets/book_page_curl.dart';
import '../widgets/jelly_filter_sheet.dart';
import '../widgets/jelly_mode_picker.dart';
import '../widgets/color_picker_dialog.dart';
import '../widgets/pomodoro_button.dart';
import '../widgets/wavy_underline.dart';
import 'tts_engine_page.dart';
import 'book_source_editor_page.dart';
import 'book_source_search_page.dart';
import 'tts_full_player_page.dart';
import '../../common/theme.dart';
import '../../common/system_ui.dart';
import '../theme/jelly_theme.dart';
import '../../widgets/app_image_cache.dart';

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
  State<BookSourceReaderPage> createState() => _BookSourceReaderPageState();
}

class _BookSourceReaderPageState extends State<BookSourceReaderPage> {
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
  /// ⚠️ 默认值**按全局明暗取**：全局是深色就默认"夜间"，浅色就默认"白"。
  int _bgIndex = AppBrightness.isLight.value ? 0 : 5;

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

  /// 关闭阅读设置面板。
  ///
  /// 用户 2026-10-21：面板里的选项**点了就生效**，不再需要「确认」——
  /// 所以底栏整个去掉了，这里只负责关闭（改动早已写入 `_rs` 并落盘）。
  void _closeSettingsPanel() {
    setState(() => _showSettingsPanel = false);
    _scheduleSavePrefs();
  }

  /// 切换「独立排版」（设置面板开关与排版面板分段控件共用）。
  Future<void> _setIndependent(bool v) async {
    setState(() => _independent = v);
    if (v) {
      await BsrIndependentLayout.instance.enable(_indepKey, _layoutSnapshot());
    } else {
      await BsrIndependentLayout.instance.disable(_indepKey);
    }
    _scheduleSavePrefs();
    if (mounted) setState(() {});
  }

  // ── 排版（截图 IMG_8491~8499 全文可调）───────────────────────
  double _fontWeight = 400; // 字重
  double _letterSpacing = 0.3; // 字间距
  double _paraSpacing = 0.5; // 段间距（× 字号）
  // 边距（内容区）
  double _padLeft = 20, _padRight = 20, _padTop = 16, _padBottom = 40;
  double _indent = 2; // 首行缩进（字符数）
  // 页眉 / 页脚（负值移进状态栏区域）
  double _headerPadH = 15, _headerPadTop = 0;
  double _footerPadH = 15, _footerPadBottom = 0;
  // 底线
  // ⚠️ 默认必须是 0（无）—— 用户实测："默认打开就有下划线" ✗。
  //   原来写死 3（实线）⇒ 一进阅读器**整屏正文都带下划线** ✗。
  int _underlineStyle = 0; // 0无 1短虚线 2长虚线 3实线 4波浪
  Color? _underlineColor; // null = 跟随文字（参考图 IMG_8497/8498）
  double _underlineAlpha = 0.35;
  double _underlineWidth = 1.2;
  double _underlineGap = 3.0;
  bool _underlineFull = false; // 满行底线
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

  /// 标题的自动屏幕系数：窄屏缩小、宽屏不放大（0.82 ~ 1.0）。
  ///
  /// 以 400 逻辑像素为基准（iPhone 14/15 ≈ 390、Pro Max ≈ 430）。
  /// 只缩不放 —— 大屏本来就有空间，放大反而更容易顶到页眉。
  double get _autoTitleScale {
    final w = _viewport.width;
    if (w <= 0) return 1.0;
    return (w / 400).clamp(0.82, 1.0).toDouble();
  }

  /// HTML 章节标题的基准字号（CSS 里 `1em` 的实际大小）。
  ///
  /// 取**正文字号**而不是样式的 `titleFontSize`：CSS 的 em 本来就是相对正文，
  /// 而 db 的 titleSize 语义是"默认标题字号"（常为 25~30），一旦拿它当 em 基准，
  /// 内置样式里 `2.6em` 就会被放大到离谱。再乘自动屏宽系数 + 手动缩放。
  double get _titleHtmlBase =>
      _fontSize * _autoTitleScale * _titleScale;

  /// 默认（无 HTML）标题字号：保持「正文 +3」的既有观感，但同样吃手动缩放。
  double get _defaultTitleFontSize =>
      (_titleFontSize ?? _fontSize + 3) * _titleScale;

  /// HTML 标题里**写死 px 的字号/内衬**的缩放系数。
  ///
  /// px 是绝对值，不像 em 那样跟着正文字号走 ⇒ 换手机尺寸后完全不变。
  /// 这里只乘屏幕自适应 + 用户手动缩放（不含「标题字号」设置，那是 em 的基准）。
  double get _titlePxScale => _autoTitleScale * _titleScale;

  /// HTML 标题下方的额外留白（0~40，默认 0）。
  ///
  /// 内置样式的间距写死在 CSS 的 margin 里（em 相对标题字号），不同屏幕/字号下
  /// 观感差异很大；给一个统一的「标题间距」让用户把标题往下推、和正文拉开。
  double _titleGap = 0;

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

  /// 是否生成章标题块。
  ///
  /// 默认隐藏（正文里已经有章名）；但选了自定义「标题样式」时必须画 ——
  /// 那套版式（仙鹤插画 / 药丸）本身就是靠标题块呈现的。
  bool get _showChapterTitle =>
      !_hideRepeatTitle || _chapterTitleSource.trim().isNotEmpty;

  /// 分页块列表里「段落 pi」与「块下标」的偏移：
  /// 有章标题块时是 1，隐藏标题（`_hideRepeatTitle`）时不生成标题块 ⇒ 0。
  /// 两处（`_pageBody` / `_pageOfParagraph`）与 `_paginate` 必须用同一个偏移，
  /// 否则书签 / 划线会落到上一段。
  int get _blockOffset => _showChapterTitle ? 1 : 0;

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

  /// 朗读时是否**自动把正在读的段落滚进视口** ✓（跟读高亮本来就有 ✓）
  bool _ttsAutoLocate = false;

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

  /// 番茄钟浮层 bottom 偏移：根据底部功能栏高度 + TTS 迷你条状态动态计算。
  /// 底部功能栏（悬浮卡片）高度 ≈ margin(10) + padding(16) + 进度行(48)
  ///   + SizedBox(14) + 2 行宫格(110) = 198；TTS 迷你条可见时再加 ~38。
  double get _pomodoroBottomOffset {
    const gap = 12.0;
    final ttsActive = _tts.isSpeaking.value || _tts.isPaused.value;
    // 功能栏现在只在 `_showBar` 时覆盖显示 —— 未显示时不要把番茄钟顶得太高 ✓。
    final navHeight = _showBar ? 198.0 : 0.0;
    return navHeight + gap + (ttsActive ? 38.0 : 0.0);
  }

  /// 本章书签：段落下标 → 颜色
  final Map<int, Color> _bookmarks = {};

  /// `_bookmarks` 当前反映的章节下标（-1 = 尚未加载）。
  /// 修复「书签串章」：`_go` / `_jumpTo` / 目录跳转都是**先** `_index = next`
  /// **再** `_loadChapter(next)` ⇒ 旧代码在 `_loadChapter` 里用 `if (i != _index)`
  /// 判断"是否切章"**恒为假** ⇒ 切章从不换书签，A 章书签在每章同段落处都显示。
  /// 这里显式记住"这批书签属于哪一章"，切章时按章换入换出。
  int _bookmarksChapter = -1;

  /// 「不再提示」—— 下次直接用上次选的颜色
  bool _bookmarkNoAsk = false;
  int _bookmarkLastColor = 0;

  /// 按住下滑一键书签（Cmbok 同款手势）：长按触发后本次拖动是否待消费
  bool _bookmarkPressArmed = false;

  /// 长按触发时的起始 Y（判定"向下拖过阈值"用）
  double _bookmarkPressStartDy = 0;

  /// 当前背景下的前景色（正文/图标用）。
  /// 「主题」tab 选了自定义字色就以它为准；
  /// 自定义/内置背景为深色时自动换浅色文字，避免深底黑字。
  Color get _fg {
    // 夜间：优先样式的 textColorNight；没配就用浅色（深底必须浅字，
    // 不能回落到日间深色字）。手动选的浅色字也保留。
    if (_bgIndex == 5) {
      final n = _fgNightOverride;
      if (n != null) return n;
      final d = _fgOverride;
      if (d != null && d.computeLuminance() > 0.35) return d;
      return const Color(0xFFB8B8B8);
    }
    if (_fgOverride != null) return _fgOverride!;
    // A3：选了壁纸 → 按壁纸明暗决定文字色（深图浅字 / 浅图深字）✓
    if (_bgImageAsset != null && _bgImageDark != null) {
      return _bgImageDark! ? const Color(0xFFE2E2E2) : const Color(0xFF1A1A1A);
    }
    return _bgTop.computeLuminance() < 0.4
        ? const Color(0xFFB8B8B8)
        : _bgs[_bgIndex][1];
  }

  /// 当前模式下真正生效的自选背景图（夜间优先夜图）
  String? get _activeFileBgPath =>
      _bgIndex == 5 ? (_customBgPathNight ?? _customBgPath) : _customBgPath;

  /// 当前模式下真正生效的壁纸 asset（夜间优先夜版）
  String? get _activeBgAsset =>
      _bgIndex == 5 ? (_bgImageAssetNight ?? _bgImageAsset) : _bgImageAsset;

  /// 当前模式是否有图片背景（自选图或内置壁纸，含夜间版）
  bool get _hasImageBg {
    final path = _activeFileBgPath;
    return (path != null && File(path).existsSync()) || _activeBgAsset != null;
  }

  /// 屏幕顶部安全区（正文层现在是整屏，文字内衬要用它）
  double get _safeTop {
    final mq = MediaQuery.of(context);
    return mq.padding.top > 0 ? mq.padding.top : mq.viewPadding.top;
  }

  /// 屏幕底部安全区（Home 指示条）
  double get _safeBottom {
    final mq = MediaQuery.of(context);
    return mq.padding.bottom > 0 ? mq.padding.bottom : mq.viewPadding.bottom;
  }

  /// 当前纸面是否偏深（翻页纸背 / 番茄钟玻璃面板 / 状态栏图标用）
  bool get _paperIsDark =>
      _bgIndex == 5 ||
      // 有图片背景时看**图片实测亮度**（内置壁纸分析过 `_bgImageDark`，
      // 自选文件分析过 `_fileBgDark`）：日间选深色自选图也要换浅字/浅图标，
      // 不能因为"不是夜间"就一律当浅色纸。
      (_bgImageDark ?? _fileBgDark ?? false) ||
      (!_hasImageBg && _bgTop.computeLuminance() < 0.45);

  /// 单页的"纸"：壁纸（日/夜版）或纯色底。
  ///
  /// 翻页动画要"纸跟着页走"就必须画在页里（Android 阅读器的位图方案同理），
  /// 外层背景层只负责滚动模式与兜底。
  Widget _pagePaper() {
    final path = _activeFileBgPath;
    if (path != null && File(path).existsSync()) {
      return _nightDim(
        Image.file(
          File(path),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => ColoredBox(color: _bgTop),
        ),
        nightVersionInUse: _bgIndex == 5 && _customBgPathNight != null,
      );
    }
    final asset = _activeBgAsset;
    if (asset != null) {
      return _nightDim(
        Image.asset(
          asset,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => ColoredBox(color: _bgTop),
        ),
        nightVersionInUse: _bgImageAssetNight != null,
      );
    }
    return ColoredBox(color: _bgTop);
  }

  /// 预解码当前纸面图。
  ///
  /// 仿真翻页会把整页栅格化：图还没解码完时第一下会翻出"白纸"。
  /// 换样式 / 切日夜 / 选壁纸后先预热一下（已在缓存里时几乎零成本）。
  void _precachePaper() {
    if (!mounted) return;
    void err(Object _, StackTrace? __) {}
    final path = _activeFileBgPath;
    if (path != null && File(path).existsSync()) {
      unawaited(precacheImage(FileImage(File(path)), context, onError: err));
      return;
    }
    final asset = _activeBgAsset;
    if (asset != null) {
      unawaited(precacheImage(AssetImage(asset), context, onError: err));
    }
  }

  /// 夜间模式：把壁纸压暗一层。
  ///
  /// 样式自带的壁纸都是日间纸色；夜间如果只把字换成浅色、底图不动，
  /// 就成了"浅底浅字"，正文几乎看不见（用户截图里的古风/泼墨就是这个问题）。
  ///
  /// [nightVersionInUse] 为真 = 这层图**本身就是夜间版**，不要再压暗
  /// （自选图片没有夜间版，切夜间时永远压暗）。
  Widget _nightDim(Widget child, {bool nightVersionInUse = false}) {
    if (_bgIndex != 5 || nightVersionInUse) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        const ColoredBox(color: Color(0x73000000)),
      ],
    );
  }

  /// 当前背景下的次要前景色（说明文字用）
  Color get _fgMuted => _fg.withValues(alpha: 0.6);

  /// 当前阅读背景色（自定义背景优先，参考图 IMG_8500）。
  ///
  /// ⚠️ **强制不透明**：自定义背景色可能是半透明的（取色器允许），
  /// 而页面背景层用的是 `_bgs[_bgIndex][0]`（不透明常量）——
  /// 于是只有面板/顶栏/底栏会透出正文（截图里那种发灰的重影字）✗。
  /// 这里把 alpha 拉满，RGB 不变 ✓。
  Color get _bgTop =>
      (_customBgColor ?? _bgs[_bgIndex][0]).withValues(alpha: 1.0);

  /// 当前背景是否为深色（面板层次色用）
  bool get _isDarkBg => _bgTop.computeLuminance() < 0.4;

  /// 面板卡片底色：**刻意和阅读背景拉开一档**。
  ///
  /// 用户 2026-10-21：「弹窗没有层次感，背景和阅读页接上了」——
  /// 之前面板直接铺 `_bgTop`（= 阅读背景），加上没有遮罩，
  /// 看起来就像正文的延续 ✗。现在：
  ///   · 浅底 → 往白里提一档（纸色 → 近白卡片）
  ///   · 深底 → 往亮里提一档（炭灰 → 浮起的深灰卡片）
  /// 再配合「背后压一层黑色遮罩 + 向上投影」，层次就出来了 ✓
  Color get _sheetBg {
    if (_isDarkBg) {
      return Color.alphaBlend(Colors.white.withValues(alpha: 0.09), _bgTop);
    }
    return Color.alphaBlend(Colors.white.withValues(alpha: 0.78), _bgTop);
  }

  /// 信息栏可选项（顺序 = 横向滑动的顺序）
  static const List<String> _statusItemKeys = [
    '时间',
    '章节',
    '电量',
    '书名',
    '页码',
    '进度',
  ];

  /// 底部面板顶部的拖动条（视觉锚点，纯装饰）✓
  Widget _sheetHandle() => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: _fg.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );

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

  /// 音量键翻页：HardwareKeyboard 能拿到音量上/下键
  /// （Flutter 3.44 的 `LogicalKeyboardKey.audioVolumeUp/Down`）。
  ///
  /// ⚠️ 「会接管音量键」是截图里的原话 —— 开了之后按音量键不再调音量。
  /// iOS 上系统可能仍在硬件层拦截，那时这里收不到事件（属平台限制）。
  bool _onKey(KeyEvent e) {
    if (!_rs.volumeKeys) return false;
    if (e is! KeyDownEvent) return false;
    if (e.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
      _nextPageOrChapter();
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
      _prevPageOrChapter();
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.chapters.length - 1);
    _pageCtrl = PageController();
    HardwareKeyboard.instance.addHandler(_onKey);
    // 跟随系统日夜：全局明暗（设置里的明暗 / 系统深色）一变就跟着换
    AppBrightness.isLight.addListener(_onAppAppearanceChanged);
    _restorePrefs();
    _syncDockBrightness();
    _loadChapter(_index);
    // C7 护眼休息提醒：墙钟计时（后台恢复后自动补齐），30s 检查一次
    _eyeBreakStart = DateTime.now();
    _eyeTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkEyeBreak();
    });
  }

  /// 护眼提醒定时器（C7，30s 检查一次）
  Timer? _eyeTimer;

  /// 本次连续阅读起点（墙钟，后台恢复自动补齐 ✓）
  DateTime _eyeBreakStart = DateTime.now();

  /// 已弹过提醒（避免重复弹）
  bool _eyeBreakShown = false;

  /// 应用「屏幕休眠」设置（截图里的 默认 / 10分钟 / 永不息屏）。
  ///
  /// ── 三种模式怎么落地 ──────────────────────────────────────────
  ///   永不息屏 → 直接禁止息屏（UIApplication.isIdleTimerDisabled = true）
  ///   10 分钟  → 禁止息屏，并起一个 10 分钟的 Timer 到点后恢复系统息屏
  ///              （**不是**"10 分钟后息屏"的字面实现 —— 那是系统亮度/锁屏策略，
  ///                App 无法精确控制；这里按"最多亮 10 分钟"来实现，
  ///                对用户的实际意义是"不会读着读着黑屏，但也不会亮一整晚"）
  ///   默认     → 立刻恢复系统息屏
  void _applySleepMode() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    final d = _rs.sleepMode.duration;
    if (_rs.sleepMode == SleepMode.never) {
      _tts.keepAwake();
      _awakeRequested = true;
    } else if (d != null) {
      _tts.keepAwake();
      _awakeRequested = true;
      _sleepTimer = Timer(d, () {
        _tts.allowSleep();
        _awakeRequested = false;
      });
    } else {
      _tts.allowSleep();
      _awakeRequested = false;
    }
  }

  Timer? _sleepTimer;

  // ── 自动阅读（对齐 Legado，2026-10-23）────────────────────────
  /// 是否正在自动阅读（运行态，不持久化；速度持久化在 `_rs.autoReadIntervalSec`）
  bool _autoReadOn = false;
  Timer? _autoReadTimer;

  /// 「上下滚动」模式下自动滚屏用的控制器（分页模式不用它）
  final ScrollController _scrollReadCtrl = ScrollController();

  /// 停自动阅读（触摸屏幕、切章、退出都会调；幂等）
  void _stopAutoRead() {
    final was = _autoReadOn;
    _autoReadTimer?.cancel();
    _autoReadTimer = null;
    if (_autoReadOn && mounted) setState(() => _autoReadOn = false);
    // 自动阅读期间强制亮屏；停掉后按用户的「屏幕休眠」设置还原
    if (was) _applySleepMode();
  }

  /// 开关自动阅读
  void _toggleAutoRead() {
    if (_autoReadOn) {
      _stopAutoRead();
      return;
    }
    // 自动翻页期间不能息屏（否则翻着翻着黑屏了）
    _tts.keepAwake();
    _awakeRequested = true;
    setState(() => _autoReadOn = true);
    _scheduleAutoRead();
    _toast('自动阅读：${_rs.autoReadIntervalSec} 秒/页（点屏幕停止）');
  }

  /// 按当前间隔排下一次翻页
  void _scheduleAutoRead() {
    _autoReadTimer?.cancel();
    if (!_autoReadOn) return;
    _autoReadTimer = Timer(Duration(seconds: _rs.autoReadIntervalSec), () {
      if (!mounted || !_autoReadOn) return;
      // 正在换章/加载：等这一轮结束再翻，避免连翻两页
      if (_loading) {
        _scheduleAutoRead();
        return;
      }
      if (_rs.pageMode.paginates) {
        // 末页 + 末章：没有可翻的了 ⇒ 自动停
        final hasNextPage = _pageIndex + 1 < _pages.length;
        final hasNextChapter = _index + 1 < widget.chapters.length;
        if (!hasNextPage && !hasNextChapter) {
          _stopAutoRead();
          return;
        }
        _nextPageOrChapter();
      } else {
        _autoScrollStep();
      }
      _scheduleAutoRead();
    });
  }

  /// 滚动模式：每次往下滚约 0.85 屏；到底则切下一章
  void _autoScrollStep() {
    if (!_scrollReadCtrl.hasClients) return;
    final p = _scrollReadCtrl.position;
    final target =
        (p.pixels + p.viewportDimension * 0.85).clamp(0.0, p.maxScrollExtent);
    _scrollReadCtrl.animateTo(
      target,
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOut,
    );
    if (target >= p.maxScrollExtent - 1) {
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted && _autoReadOn) _go(1);
      });
    }
  }

  /// 清空章节缓存（保留当前章，避免正文闪空）
  void _clearChapterCache() {
    final cur = _cache[_index];
    setState(() {
      _cache.clear();
      if (cur != null) _cache[_index] = cur;
    });
    _toast('已清空章节缓存');
  }

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

  /// 排版参数改动后节流重排一次 ✓（保留当前阅读位置 —— 见 [_repaginateLayout] ✓）。
  void _scheduleRepaginate() {
    _repaginateDebounce?.cancel();
    _repaginateDebounce = Timer(
      const Duration(milliseconds: 300),
      () {
        if (!mounted) return;
        _repaginateLayout();
      },
    );
  }

  /// ✅ **阅读时长：本次会话"已累计到"的时间点** ✓（`ReadingTimeService` 接线 ✓ ——
  ///   为「阅读计划 / 阅读热力图」提供真实数据 ✓；此前这两处**完全没有时长数据** ✗）。
  ///   为什么要"**增量累计**"✗：本页高频改动（滑杆/悬浮球拖动 ✓）会反复调 [_scheduleSavePrefs] ✓ ——
  ///   若每次都交"会话开始的整段差值" ✗ → **重复计时长** ✗✗；这里每交一次就把时间点**前移** ✓，
  ///   于是每次只交"上次之后"的增量 ✓✓（多次增量之和 = 真实停留时长 ✓）。
  ///   `addSession` 内部另有 1 秒下限 ✓ 与单次 2 小时上限 ✓（防"忘记退出"刷爆一天 ✓）。
  DateTime _sessionStamp = DateTime.now();

  /// 合并 300ms 内的多次保存请求 ✓（写法照 `trim_preview_page.dart:182` 的现成防抖 ✓）。
  /// ⚠️ 防抖的**命门**：离开页面时必须在 [dispose] 里**兜底落盘一次** ✗✓，
  ///   否则"拖完立刻退出"会**丢设置** ✗✗（那比不优化严重得多 ✓）。
  void _scheduleSavePrefs() {
    // 顺路记一次阅读时长 ✓（按天累计 ✓，只交"上次到现在"的增量 ✓ 不会重复 ✓）
    final stampNow = DateTime.now();
    ReadingTimeService.instance.addSession(stampNow.difference(_sessionStamp));
    _sessionStamp = stampNow;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(
      const Duration(milliseconds: 300),
      () => _savePrefs(),
    );
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    AppBrightness.isLight.removeListener(_onAppAppearanceChanged);
    // 🆕 **退出阅读器必须停掉朗读** ✓ —— `TtsService` 是**进程单例** ✓，
    //   原来这里既不 `stop()` 也不清 `onFinished` ✗ → 用户点朗读后按返回键
    //   离开阅读器，语音会**继续在书架/首页念** ✗；`onFinished` 闭包还一直
    //   持有已销毁的 State ✗（直到被别处覆盖 ✓）。
    //   与 `book_reader_page.dart` 的 dispose 同款写法 ✓
    _tts.onFinished = null;
    _tts.stop();
    // 自动阅读定时器 / 滚动控制器（退出必须停，否则会继续翻页）
    _autoReadTimer?.cancel();
    _autoReadTimer = null;
    _scrollReadCtrl.dispose();
    // ⚠️ 必须恢复息屏：否则用户离开阅读器后屏幕永远不灭（严重耗电）
    if (_awakeRequested) _tts.allowSleep();
    _sleepTimer?.cancel();
    // 🆕 **兜底落盘**（防抖的命门 ✓）：把还在等待中的那次保存**立刻执行** ✗✓，
    //   否则"拖完滑杆/挪完悬浮球**立刻退出**"会丢掉最后一次修改 ✗✗。
    //   `_savePrefs` 幂等 ✓，多存一次无害 ✓
    _saveDebounce?.cancel();
    // ⚠️ **这里必须是 `_savePrefs()`，不能是 `_scheduleSavePrefs()`** ✗✗ ——
    //   页面正在销毁 ✓，再排一个 300ms 后的定时器**可能根本不会执行** ✗
    //   → 就变成"拖完立刻退出 = 丢设置" ✗（这正是防抖的命门 ✓）
    _savePrefs();
    // 退出阅读器必须还原系统状态栏（否则出了阅读器状态栏还是隐藏的 ✗）
    if (_readerImmersive) {
      _readerImmersive = false;
      SystemUiController.exit('bsr-reader');
    }
    // 🆕 **补上漏掉的定时器取消** ✓ —— 原来 `_ttsTimerHandle` 只在
    //   `_scheduleTtsTimer` 内部被取消 ✗，离开阅读器时**没人取消它** ✗
    //   （定时器会在页面销毁后照常触发 → 潜在泄漏/异常 ✓）
    _ttsTimerHandle?.cancel();
    _repaginateDebounce?.cancel();
    // C7 护眼提醒定时器
    _eyeTimer?.cancel();
    _tapTimer?.cancel();
    _pageCtrl.dispose();
    super.dispose();
  }

  // ── 偏好与进度 ──────────────────────────────────────────────

  /// C7：连续阅读达到时长后弹休息提醒（不强退；可推迟/关闭）。
  void _checkEyeBreak() {
    if (!mounted) return;
    if (!_rs.eyeBreakEnabled || _eyeBreakShown) return;
    final elapsed = DateTime.now().difference(_eyeBreakStart);
    if (elapsed.inMinutes < _rs.eyeBreakMinutes) return;
    _eyeBreakShown = true;
    _showEyeBreakDialog();
  }

  /// C7：护眼休息提醒弹窗（关掉或推迟都重新计时，不打断阅读）。
  void _showEyeBreakDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _bgTop,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          '护眼提醒',
          style: TextStyle(
            fontSize: AppTheme.fontTitle3,
            fontWeight: FontWeight.w700,
            color: _fg,
          ),
        ),
        content: Text(
          '已连续阅读 ${_rs.eyeBreakMinutes} 分钟，休息一下眼睛吧。',
          style: TextStyle(fontSize: AppTheme.fontBody, color: _fgMuted),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _eyeBreakStart = DateTime.now();
              _eyeBreakShown = false;
            },
            child: Text('再读 10 分钟', style: TextStyle(color: _fg)),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _eyeBreakStart = DateTime.now();
              _eyeBreakShown = false;
            },
            style: FilledButton.styleFrom(
              backgroundColor: _fg.withValues(alpha: 0.9),
              foregroundColor: _bgTop,
            ),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  String get _progressKey =>
      ChapterAlignment.progressKey(widget.source.id, widget.bookName);

  /// 书签的存储键（**按章**存 ✓）：同一本书不同章各存各的，
  /// 避免"整本只存一份、重进时把上次那章的书签装到当前章"的串章。
  String _bookmarksKey(int chapter) => 'bsr.bookmarks.$_progressKey.$chapter';

  /// ✅ **「独立排版」的身份键**（本会话新增 ✓）—— 与**进度 / 书签 / 笔记**用**同一个身份** ✓
  /// （`source.id` + `bookName` ✓）⇒ 用户视角"同一本书"处处一致 ✓（不会出现"进度算一本、排版算另一本"✗）
  String get _indepKey => '${widget.source.id}.${widget.bookName}';

  /// 本书是否开启了「独立排版」✓ —— 由 [_restorePrefs] 读入 ✓、由那 3 个开关切换 ✓、
  /// 由 [_savePrefs] 决定"改动写覆盖还是写全局" ✓（**分流** ✓）。
  bool _independent = false;

  /// 本页**排版快照**（独立排版用 ✓ —— 第 3 轮 ✓）。
  /// ℹ️ 只收"本页此刻确实存在的排版项" ✓；**下一轮**接入标题对齐/样式、底线、边距时，
  ///   在这里**同步加键**即可 ✓（一个地方进、一个地方出 ✓ 不会两处不一致 ✗）。
  Map<String, Object?> _layoutSnapshot() => <String, Object?>{
    'fontSize': _fontSize,
    'lineHeight': _lineHeight,
    'bgIndex': _bgIndex,
    'dayBgIndex': _dayBgIndex,
    // ✅ 第 4 轮补齐 ✓：自定义背景色/图 ✓ 底线色/样式 ✓ 标题对齐/样式 ✓ 加粗 ✓
    // ⚠️ `Color` 不能直接进 JSON ✗ → 存 `toARGB32()` 整数 ✓（读回时 `Color(...)` ✓ 与全局键同款 ✓）
    'bgCustom': _customBgColor?.toARGB32(),
    'bgCustomPath': _customBgPath,
    'bgCustomPathNight': _customBgPathNight,
    'bgImage': _bgImageAsset,
    'underlineColor': _underlineColor?.toARGB32(),
    'underlineStyle': _underlineStyle,
    'focusBold': _focusBold,
    'titleAlign': _titleAlign,
    'titleStyle': _titleStyle,
    // ℹ️ 有意**不含** `hideRepeatTitle` ✓：它在 `_savePrefs` 里**没有**对应全局写入 ✓
    //   （只读不写 ✓），纳入覆盖会变成"独立时改了却没处存"✗ —— 不纳入才是自洽的 ✓
    // ✅ 字号之外的排版项全部入快照（原来漏了这几项 ⇒ 「独立排版」下
    //   调完段距 / 字距 / 字重 / 边距 / 缩进，退出再进又回到默认值）
    'fontWeight': _fontWeight,
    'letterSpacing': _letterSpacing,
    'paraSpacing': _paraSpacing,
    'padLeft': _padLeft,
    'padRight': _padRight,
    'padTop': _padTop,
    'padBottom': _padBottom,
    'indent': _indent,
  };

  Future<void> _restorePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      final fs = p.getDouble('reading.fontSize');
      final lh = p.getDouble('reading.lineHeight');
      final bg = p.getInt('reading.bgIndex');
      // ✅ **独立排版：优先用"本书自己的"覆盖值**（本会话第 2 轮 ✓ —— 接"读"这条路 ✓）
      //   · 未开启独立 ✓ → `_independent == false` → `ov == null` → 下面**完全按全局** ✓
      //     （与从前**一字不差** ✓ 现有用户零影响 ✓）
      //   · 已开启 ✓ → 用覆盖里的值 ✓；**缺项逐项回退全局** ✓
      //     （不会出现"开了独立却读不到值、变成默认值"✗ 那种坑 ✓）
      //   ℹ️ 本轮只覆盖**字号 / 行高 / 背景** ✓（就在下面几行 ✓）；标题对齐/样式、底线、边距
      //     等其余排版项在**下一轮**同样接入 ✓（一次只接一段、每段都跑闸门 ✓ 不半截 ✓）
      _independent = await BsrIndependentLayout.instance.isIndependent(
        _indepKey,
      );
      final ov = _independent
          ? await BsrIndependentLayout.instance.read(_indepKey)
          : null;
      // ✅ 一次性排版迁移（2026-10-23）
      //   旧默认「行距 1.9 + 段距 1.0 字」叠起来整体过松，看着"散"。新默认 1.72。
      //   但 `reading.lineHeight` 是老用户已经存下的值 ⇒ 不迁移的话新默认永远
      //   不生效。只把**还停在旧默认 1.9** 的改过来，自己拖过滑杆的不碰。
      final typoV2 = p.getBool('reading.typoV2') ?? false;
      // 阅读设置（截图 IMG_71a10）
      final rsRaw = p.getString('reading.settings');
      // 已保存的排版预设名列表
      final presetRaw = p.getString('reading.presetNames');
      if (presetRaw != null && presetRaw.isNotEmpty) {
        try {
          _savedPresets
            ..clear()
            ..addAll((jsonDecode(presetRaw) as List).cast<String>());
        } catch (_) {}
      }
      // 只在用户**没有从详情页指定章节**时才恢复进度，
      // 否则点"第 5 章"却被跳到上次读到的地方就很怪。
      final savedIdx = p.getInt(_progressKey);
      // 「阅读样式」：用户样式列表 + 当前选中的样式 id
      final myStyles = await _styleStore.loadCustom();
      final activeStyle = await _styleStore.loadActiveId();
      _dayStyleId = await _styleStore.loadDayStyleId();
      _nightStyleId = await _styleStore.loadNightStyleId();
      _followSystem = await _styleStore.loadFollowSystem();
      final myTitles = await _styleStore.loadTitleStyles();
      // 自定义字体：把 family 注册到引擎（分页度量必须用同一个 family）
      await ReaderFontService.instance.load();
      final fontId = p.getString('reading.fontId');
      final fontFamily = await ReaderFontService.instance.familyOf(fontId);
      if (!mounted) return;
      _myStyles = myStyles;
      _activeStyleId = activeStyle;
      _myTitleStyles = myTitles;
      _fontId = fontFamily == null ? null : fontId;
      _fontFamily = fontFamily;
      setState(() {
        // ✅ **覆盖值优先，逐项回退全局**（本会话第 2 轮 ✓）
        final fsV = (ov?['fontSize'] as num?)?.toDouble() ?? fs;
        final lhRaw = (ov?['lineHeight'] as num?)?.toDouble() ?? lh;
        final bgV = (ov?['bgIndex'] as num?)?.toInt() ?? bg;
        // 旧默认 1.9 → 新默认 1.72（只迁移一次）
        final lhV = (!typoV2 &&
                lhRaw != null &&
                (lhRaw - 1.9).abs() < 0.001)
            ? 1.72
            : lhRaw;
        if (fsV != null && fsV >= 12 && fsV <= 30) _fontSize = fsV;
        if (lhV != null && lhV >= 1.2 && lhV <= 3.0) _lineHeight = lhV;
        if (bgV != null && bgV >= 0 && bgV < _bgs.length) _bgIndex = bgV;
        final dayBg =
            (ov?['dayBgIndex'] as num?)?.toInt() ??
            p.getInt('reading.dayBgIndex');
        if (dayBg != null && dayBg >= 0 && dayBg < _bgs.length) {
          _dayBgIndex = dayBg;
        }
        final bgC =
            (ov?['bgCustom'] as num?)?.toInt() ?? p.getInt('reading.bgCustom');
        if (bgC != null) _customBgColor = Color(bgC);
        final bgPath =
            (ov?['bgCustomPath'] as String?) ??
            p.getString('reading.bgCustomPath');
        if (bgPath != null && File(bgPath).existsSync()) {
          _customBgPath = bgPath;
          // _fileBgDark 不持久化，重启后重采自选图明暗（_paperIsDark 用）
          unawaited(_analyzeFileBg(bgPath));
        }
        // 夜间那张也是独立存的（.srs 有日/夜两张图）
        final bgPathNight =
            (ov?['bgCustomPathNight'] as String?) ??
            p.getString('reading.bgCustomPathNight');
        if (bgPathNight != null && File(bgPathNight).existsSync()) {
          _customBgPathNight = bgPathNight;
        }
        // 内置壁纸（与 `_savePrefs` 的 `reading.bgImage` 配对 ✓）
        final bgImg =
            (ov?['bgImage'] as String?) ?? p.getString('reading.bgImage');
        // 夜间壁纸要**独立读取**：只配了夜间图的样式（跨日/夜成对但日间为空）
        // 一旦被挂在 `if (bgImg != null)` 里就会丢
        _bgImageAssetNight = p.getString('reading.bgImageNight');
        if (bgImg != null && bgImg.isNotEmpty) {
          _bgImageAsset = bgImg;
          _bgImageDark = p.getBool('reading.bgImageDark');
        }
        // ✅ 书签**按章**读回 ✓ —— 只读"即将显示的那一章"的键 ✓，
        // 不再把整本一份的书签装到当前章（那正是串章的根因 ✓）。
        // 与下面 `_index = savedIdx`（:576 附近）用同一判定 ✓，保证章号一致 ✓。
        final bmIdx =
            (widget.initialIndex == 0 &&
                savedIdx != null &&
                savedIdx > 0 &&
                savedIdx < widget.chapters.length)
            ? savedIdx
            : _index;
        _bookmarksChapter = bmIdx;
        final bkRaw = p.getString(_bookmarksKey(bmIdx));
        if (bkRaw != null && bkRaw.isNotEmpty) {
          try {
            final m = jsonDecode(bkRaw);
            if (m is Map) {
              _bookmarks
                ..clear()
                ..addAll(
                  m.map(
                    (k, v) => MapEntry(
                      int.tryParse('$k') ?? 0,
                      Color((v as num).toInt()),
                    ),
                  ),
                );
            }
          } catch (_) {}
        }
        // ✅ 第 4 轮 ✓：这 5 项也**覆盖优先、逐项回退全局** ✓（与上面 3 项同一写法 ✓）
        final uc =
            (ov?['underlineColor'] as num?)?.toInt() ??
            p.getInt('reading.underlineColor');
        if (uc != null) _underlineColor = Color(uc);
        final us =
            (ov?['underlineStyle'] as num?)?.toInt() ??
            p.getInt('reading.underlineStyle');
        if (us != null && us >= 0 && us < 5) _underlineStyle = us;
        final fb =
            (ov?['focusBold'] as bool?) ?? p.getBool('reading.focusBold');
        final ta =
            (ov?['titleAlign'] as num?)?.toInt() ??
            p.getInt('reading.titleAlign');
        final ts =
            (ov?['titleStyle'] as num?)?.toInt() ??
            p.getInt('reading.titleStyle');
        final hr = p.getBool('reading.hideRepeatTitle');
        if (fb != null) _focusBold = fb;
        if (ta != null) _titleAlign = ta;
        if (ts != null) _titleStyle = ts;
        // ✅ 字号之外的排版项：覆盖优先、逐项回退全局（与上面同款写法）。
        //   这几项原来**既没存全局也没读回** ⇒ 调完退出再进又回到默认值。
        double? num2(String k) =>
            (ov?[k] as num?)?.toDouble() ?? p.getDouble('reading.$k');
        final fw = num2('fontWeight');
        if (fw != null && fw >= 300 && fw <= 900) _fontWeight = fw;
        final ls = num2('letterSpacing');
        // 字距允许负值（db 里有负字距，套用样式时也是 -2~8）——
        // 原来只收 >= 0，重启后负字距被打回旧值
        if (ls != null && ls >= -2 && ls <= 8) _letterSpacing = ls;
        final ps = num2('paraSpacing');
        // 与套用样式时的 clamp（0~2）一致：原来这里收 0~3，重启后会出现
        // 阅读器 UI 显示 2、实际渲染 3 的错位
        if (ps != null && ps >= 0 && ps <= 2) _paraSpacing = ps;
        final tfs = num2('titleFontSize');
        if (tfs != null && tfs >= 8 && tfs <= 60) _titleFontSize = tfs;
        final tsc = num2('titleScale');
        if (tsc != null && tsc >= 0.6 && tsc <= 1.6) _titleScale = tsc;
        final tgp = num2('titleGap');
        if (tgp != null && tgp >= 0 && tgp <= 40) _titleGap = tgp;
        final tb =
            (ov?['titleBold'] as bool?) ?? p.getBool('reading.titleBold');
        if (tb != null) _titleBold = tb;
        final sbgD =
            (ov?['styleBgDay'] as num?)?.toInt() ??
            p.getInt('reading.styleBgDay');
        if (sbgD != null) _styleBgDay = sbgD;
        final sbgN =
            (ov?['styleBgNight'] as num?)?.toInt() ??
            p.getInt('reading.styleBgNight');
        if (sbgN != null) _styleBgNight = sbgN;
        final fgn =
            (ov?['fgNightOverride'] as num?)?.toInt() ??
            p.getInt('reading.fgNightOverride');
        if (fgn != null && fgn != 0) _fgNightOverride = Color(fgn);
        final fgd =
            (ov?['fgOverride'] as num?)?.toInt() ??
            p.getInt('reading.fgOverride');
        if (fgd != null && fgd != 0) _fgOverride = Color(fgd);
        final pl = num2('padLeft');
        if (pl != null && pl >= 0 && pl <= 60) _padLeft = pl;
        final pr = num2('padRight');
        if (pr != null && pr >= 0 && pr <= 60) _padRight = pr;
        final pt = num2('padTop');
        if (pt != null && pt >= 0 && pt <= 60) _padTop = pt;
        final pb = num2('padBottom');
        if (pb != null && pb >= 0 && pb <= 60) _padBottom = pb;
        final idt = num2('indent');
        if (idt != null && idt >= 0 && idt <= 4) _indent = idt;
        if (hr != null) _hideRepeatTitle = hr;
        // 章标题版式（默认 / 仙鹤日间 / 仙鹤夜间 / 微信读书 / 自定义）
        _chapterTitleStyle = ReaderTitleStyle.fromId(
          p.getString('reading.chapterTitleStyle'),
        );
        _chapterTitleHtml = p.getString('reading.chapterTitleHtml') ?? '';
        _chapterTitleHtmlNight =
            p.getString('reading.chapterTitleHtmlNight') ?? '';
        // 页眉 / 页脚自定义格式（空 = 用「信息栏项目」开关）
        _headerL = p.getString('reading.headerL') ?? '';
        _headerC = p.getString('reading.headerC') ?? '';
        _headerR = p.getString('reading.headerR') ?? '';
        _footerL = p.getString('reading.footerL') ?? '';
        _footerC = p.getString('reading.footerC') ?? '';
        _footerR = p.getString('reading.footerR') ?? '';
        if (rsRaw != null && rsRaw.isNotEmpty) {
          try {
            _rs = ReadingSettings.fromJson(
              Map<String, dynamic>.from(jsonDecode(rsRaw) as Map),
            );
          } catch (_) {}
        }
        if (widget.initialIndex == 0 &&
            savedIdx != null &&
            savedIdx > 0 &&
            savedIdx < widget.chapters.length) {
          _index = savedIdx;
        }
        // TTS 设置（朗读面板，参考图 IMG_8488/8489）
        final tc = p.getInt('bsr.tts.color');
        final th = p.getInt('bsr.tts.highlight');
        final tt = p.getInt('bsr.tts.timer');
        final tv = p.getInt('bsr.tts.volume');
        final tf = p.getBool('bsr.tts.followSystem');
        final tdp = p.getBool('bsr.tts.directPlayer');
        final tal = p.getBool('bsr.tts.autoLocate');
        if (tc != null) _ttsColor = tc;
        if (th != null) _ttsHighlight = th;
        if (tt != null) _ttsTimer = tt;
        if (tv != null) _ttsVolume = tv;
        if (tf != null) _ttsFollowSystem = tf;
        _ttsDualVoice = p.getBool('bsr.tts.dualVoice') ?? false;
        _ttsNarratorVoice = p.getString('bsr.tts.narratorVoice') ?? '';
        _ttsDialogueVoice = p.getString('bsr.tts.dialogueVoice') ?? '';
        // 恢复完成后把输入框初值同步上（initState 时还是默认空 ✓）
        _ttsNarratorCtl.text = _ttsNarratorVoice;
        _ttsDialogueCtl.text = _ttsDialogueVoice;
        if (tdp != null) _ttsDirectPlayer = tdp;
        if (tal != null) _ttsAutoLocate = tal;
      });
      if (_index != widget.initialIndex) _loadChapter(_index);
      // 恢复完排版/字体后再排一次：首帧那次可能还是默认字号/系统字体
      _scheduleRepaginate();
      // 迁移只做一次（下次不再动用户的行距）
      if (!typoV2) await p.setBool('reading.typoV2', true);
      // 恢复完偏好要立刻应用屏幕休眠设置
      _applySleepMode();
      // 以及「隐藏状态栏」（沉浸全屏）设置
      _applyReaderSystemUi();
      // 跟随系统：偏好就绪后按当前全局明暗对齐一次（含绑定样式的自动套用）
      _prefsReady = true;
      _onAppAppearanceChanged();
      _precachePaper();
    } catch (_) {
      // 偏好读不到就用默认值，不影响阅读
    }
  }

  /// 是否已经「进入」沉浸态（避免没进过就调 exit —— exit 在无现场记录时会
  /// 强制回到默认模式并重置方向，可能覆盖别的页面设的锁 ✗）。
  bool _readerImmersive = false;

  /// 应用「隐藏状态栏」（沉浸全屏）设置。
  ///
  /// 用 [SystemUiController] 的**入栈/出栈**（见 `common/system_ui.dart`）——
  /// 退出时恢复「进入阅读器之前」的状态，而不是写死 `edgeToEdge` ✗，
  /// 这样从别的全屏页进来再退出也不会互相覆盖 ✓。
  void _applyReaderSystemUi() {
    if (_rs.hideStatusBar) {
      if (_readerImmersive) return;
      _readerImmersive = true;
      // ⚠️ 用 `manual + overlays: []` 而不是 `immersiveSticky`：
      //   iOS 上后者并不稳定生效（状态栏照旧显示 ⇒ 用户"开了全屏还是有遮盖"）。
      //   `manual` 明确告诉系统"两个 overlay 都不要" ⇒ iOS / Android 都会
      //   隐藏状态栏与 Home 指示条，行为一致、可预期 ✓
      SystemUiController.enter(
        'bsr-reader',
        mode: SystemUiMode.manual,
        overlays: const <SystemUiOverlay>[],
      );
    } else {
      if (!_readerImmersive) return;
      _readerImmersive = false;
      SystemUiController.exit('bsr-reader');
    }
  }

  Future<void> _savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      // ✅ **独立排版：写路径分流**（本会话第 3 轮 ✓ —— 让"独立"的值真的存得住 ✓）
      //   · 已开独立 ✓ → 只把**本书快照**写进覆盖 ✓，**不动物理全局值** ✓
      //     （这样"这本书改了字号"**不会**影响其它书 ✓✓ —— 正是"独立"的含义 ✓）
      //   · 未开独立 ✓ → 与从前**一字不差**写全局 ✓（现有用户零影响 ✓✓）
      if (_independent) {
        await BsrIndependentLayout.instance.update(
          _indepKey,
          _layoutSnapshot(),
        );
      } else {
        await p.setDouble('reading.fontSize', _fontSize);
        await p.setDouble('reading.lineHeight', _lineHeight);
        await p.setInt('reading.bgIndex', _bgIndex);
        await p.setInt('reading.dayBgIndex', _dayBgIndex);
      }
      // ✅ **独立排版：这 7 项也只在"未独立"时写全局**（第 4 轮 ✓）——
      //   原来它们无条件写全局 ✗ → 开独立后改标题/底线会**把别的书也改了** ✗（"半独立"✗）。
      //   现在整段挪进 `if (!_independent)` ✓：独立时它们**只**由上面那句
      //   `update(_indepKey, _layoutSnapshot())` 写进**本书覆盖** ✓✓。
      if (!_independent) {
        if (_customBgColor != null) {
          await p.setInt('reading.bgCustom', _customBgColor!.toARGB32());
        } else {
          await p.remove('reading.bgCustom');
        }
        if (_customBgPath != null) {
          await p.setString('reading.bgCustomPath', _customBgPath!);
        } else {
          await p.remove('reading.bgCustomPath');
        }
        if (_customBgPathNight != null) {
          await p.setString('reading.bgCustomPathNight', _customBgPathNight!);
        } else {
          await p.remove('reading.bgCustomPathNight');
        }
        if (_bgImageAsset != null) {
          await p.setString('reading.bgImage', _bgImageAsset!);
        } else {
          await p.remove('reading.bgImage');
        }
        if (_bgImageAssetNight != null) {
          await p.setString('reading.bgImageNight', _bgImageAssetNight!);
        } else {
          await p.remove('reading.bgImageNight');
        }
        if (_bgImageDark != null) {
          await p.setBool('reading.bgImageDark', _bgImageDark!);
        } else {
          await p.remove('reading.bgImageDark');
        }
        if (_underlineColor != null) {
          await p.setInt('reading.underlineColor', _underlineColor!.toARGB32());
        } else {
          await p.remove('reading.underlineColor');
        }
        await p.setInt('reading.underlineStyle', _underlineStyle);
        await p.setBool('reading.focusBold', _focusBold);
        await p.setInt('reading.titleAlign', _titleAlign);
        await p.setInt('reading.titleStyle', _titleStyle);
        if (_titleFontSize != null) {
          await p.setDouble('reading.titleFontSize', _titleFontSize!);
        } else {
          await p.remove('reading.titleFontSize');
        }
        await p.setDouble('reading.titleScale', _titleScale);
        await p.setDouble('reading.titleGap', _titleGap);
        await p.setBool('reading.titleBold', _titleBold);
        // ✅ 段距 / 字距 / 字重 / 边距 / 缩进也要**落全局**：
        //   原来只写进「独立排版」快照，全局一个键都没有 ⇒ 调完退出再进
        //   又回到默认值（用户视角："怎么调都不舒服/调了没用"）。
        await p.setDouble('reading.fontWeight', _fontWeight);
        await p.setDouble('reading.letterSpacing', _letterSpacing);
        await p.setDouble('reading.paraSpacing', _paraSpacing);
        await p.setDouble('reading.padLeft', _padLeft);
        await p.setDouble('reading.padRight', _padRight);
        await p.setDouble('reading.padTop', _padTop);
        await p.setDouble('reading.padBottom', _padBottom);
        await p.setDouble('reading.indent', _indent);
      }
      // ✅ TTS 面板的两个新设置也落盘 ✓（键名与 `_restorePrefs` 里的读回一一对应 ✓）
      await p.setBool('bsr.tts.directPlayer', _ttsDirectPlayer);
      await p.setBool('bsr.tts.autoLocate', _ttsAutoLocate);
      // ✅ 书签**按章**落盘 ✓（键含章号 ✓）—— 与 `_restorePrefs` 侧配对读回 ✓。
      // 写"`_bookmarks` 当前所属的那一章"的键 ✓；加载空窗（`= -1`）跳过 ✓，
      // 否则会拿空表覆盖某章书签 ✗。
      if (_bookmarksChapter >= 0) {
        await p.setString(
          _bookmarksKey(_bookmarksChapter),
          jsonEncode(_bookmarks.map((k, v) => MapEntry('$k', v.toARGB32()))),
        );
      }
      await p.setBool('reading.hideRepeatTitle', _hideRepeatTitle);
      await p.setString('reading.chapterTitleStyle', _chapterTitleStyle.id);
      await p.setString('reading.chapterTitleHtml', _chapterTitleHtml);
      await p.setString(
        'reading.chapterTitleHtmlNight',
        _chapterTitleHtmlNight,
      );
      await p.setString('reading.fontId', _fontId ?? '');
      // 样式带来的日/夜底色与夜间字色（切日夜、重进都按这套来）
      if (_styleBgDay != null) {
        await p.setInt('reading.styleBgDay', _styleBgDay!);
      } else {
        await p.remove('reading.styleBgDay');
      }
      if (_styleBgNight != null) {
        await p.setInt('reading.styleBgNight', _styleBgNight!);
      } else {
        await p.remove('reading.styleBgNight');
      }
      if (_fgNightOverride != null) {
        await p.setInt(
          'reading.fgNightOverride',
          _fgNightOverride!.toARGB32(),
        );
      } else {
        await p.remove('reading.fgNightOverride');
      }
      // 日间字色也要落盘：原来只存了夜间，重启后样式 textColor 丢失、
      // 回退成"按背景自动取色"（白底上的 #1A1A1A / 米黄上的深棕）
      if (_fgOverride != null) {
        await p.setInt('reading.fgOverride', _fgOverride!.toARGB32());
      } else {
        await p.remove('reading.fgOverride');
      }
      await p.setString('reading.headerL', _headerL);
      await p.setString('reading.headerC', _headerC);
      await p.setString('reading.headerR', _headerR);
      await p.setString('reading.footerL', _footerL);
      await p.setString('reading.footerC', _footerC);
      await p.setString('reading.footerR', _footerR);
      await p.setString('reading.settings', jsonEncode(_rs.toJson()));
      await p.setString('reading.presetNames', jsonEncode(_savedPresets));
      await p.setInt('bsr.tts.color', _ttsColor);
      await p.setInt('bsr.tts.highlight', _ttsHighlight);
      await p.setInt('bsr.tts.timer', _ttsTimer);
      await p.setInt('bsr.tts.volume', _ttsVolume);
      await p.setBool('bsr.tts.followSystem', _ttsFollowSystem);
      await p.setBool('bsr.tts.dualVoice', _ttsDualVoice);
      await p.setString('bsr.tts.narratorVoice', _ttsNarratorVoice);
      await p.setString('bsr.tts.dialogueVoice', _ttsDialogueVoice);
    } catch (_) {}
  }

  Future<void> _saveProgress() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_progressKey, _index);
    } catch (e) {
      // ⚠️ 2026-10-14：原来是空 `catch (_) {}` —— 写盘失败（磁盘满 / 平台异常）
      //   完全静默：用户下次进来莫名回到旧位置，日志里也查不到原因。补日志。
      debugPrint('[阅读] 保存阅读进度失败: $e');
    }
  }

  /// 切章时把书签**按章换入换出**（修复串章，见 `_bookmarksChapter`）。
  /// 先把上一章落盘，再清显示、读回新章；加载期间置 `-1`，让存盘跳过书签分支，
  /// 避免用空表覆盖新章的键。读回后若 `_index` 已再次变化则丢弃（过期响应）。
  Future<void> _switchBookmarksTo(int chapter) async {
    if (_bookmarksChapter != -1 && _bookmarksChapter != chapter) {
      await _savePrefs();
    }
    if (!mounted) return;
    setState(() {
      _bookmarks.clear();
      _bookmarksChapter = -1;
    });
    final raw = (await SharedPreferences.getInstance()).getString(
      _bookmarksKey(chapter),
    );
    final m = <int, Color>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is Map) {
          d.forEach((k, v) {
            final idx = int.tryParse('$k');
            if (idx != null) m[idx] = Color((v as num).toInt());
          });
        }
      } catch (_) {}
    }
    if (!mounted || _index != chapter) return;
    setState(() {
      _bookmarks
        ..clear()
        ..addAll(m);
      _bookmarksChapter = chapter;
    });
  }

  // ── 章节加载 ────────────────────────────────────────────────

  /// "当前这一次**可见**加载"的序号（只有非预取的加载才自增 ✓）。
  /// 用来丢弃**过期响应** ✓ —— 见 [_loadChapter] 里 await 之后的校验 ✓
  int _loadSeq = 0;

  Future<void> _loadChapter(int i, {bool prefetchOnly = false}) async {
    if (i < 0 || i >= widget.chapters.length) return;
    // 🔴 **代次守卫** ✓：快速连点换章时，**先发的请求可能后回来** ✗ →
    // 会把旧章的正文盖到新章上 ✓（章号/标题已经变了、正文还是上一章 ✓，
    // 与"缓存命中没重分页"是同一类观感问题 ✓）。
    // 只让**非预取**的加载推进序号 ✓ —— 否则后台预取会把用户正在看的这次作废 ✗
    final seq = prefetchOnly ? -1 : ++_loadSeq;

    // 切章：书签按章换入换出（见 `_bookmarksChapter` 说明 ✓）。
    // `-1`（首次、`_restorePrefs` 尚未建立章节）时跳过 ✓ —— 初始章由 `_restorePrefs` 负责 ✓。
    if (!prefetchOnly && _bookmarksChapter != -1 && _bookmarksChapter != i) {
      await _switchBookmarksTo(i);
    }

    // 命中缓存：直接切换
    if (_cache.containsKey(i)) {
      if (!prefetchOnly) {
        setState(() {
          // ✅ 书签切章换入换出已上移到 `_loadChapter` 开头（`_switchBookmarksTo` ✓）——
          //    原来这里的 `if (i != _index) _bookmarks.clear();` **恒为假** ✗
          //（调用方 `_go` / `_jumpTo` 都先把 `_index` 改好 ✓），是从不生效的死代码 ✓。
          // 🔴 缓存命中时原来**只换了 `_paragraphs`** ✗ —— `_images`（上一章的配图 ✗）
          // 和 `_pages`（上一章的分页 ✗）都还留在原处 ✓ → 表现就是
          //「章号/标题已经变了、**正文或配图还是上一章**」✗。
          // 这里先清掉 `_images` ✓ —— 文字章本来就不该有图片列表 ✓，
          // 与未命中分支的 `_images = r.images / _paragraphs = const []` 语义一致 ✓
          //（未命中分支见下面 :507-510 ✓），**零回归风险** ✓。
          // ⚠️ 遗留：`_pages`（分页数组）这里**故意没清** ✗ —— 我还没确认它是
          //    在哪里按 `_paragraphs` 重算的 ✓，乱清可能让正文变空白 ✗，
          //    确认后再补 ✓
          _images = const [];
          _chapterImages = const [];
          _mangaImgHeaders = const {};
          _paragraphs = _applyConvert(_cache[i]!);
          // 换章 ⇒ 滚动章链回到单章（滚动视图随之重建、回到章首）
          _resetScrollChain(i);
          _invalidateTtsSegs();
          _loading = false;
          _error = null;
        });
        // 🔴 缓存命中时**没有重新分页** ✗ —— 未命中的文字路径会调 `_paginate()`
        //（见本文件 :541 ✓），这里却直接 `return` ✓ → `_pages` 仍是**上一章的分页** ✗
        //（正文/页数/页脚对不上、翻到后面是空的 ✓）。
        // 先清旧分页再重算 ✓（与 :1911 的 `_pages = const []` 同款 ✓）
        setState(() => _pages = const []);
        _paginate();
        // 🔴 缓存命中也必须「回到第 1 页 + 落盘进度」✗ —— 原来只有未命中分支
        //    有这两步 ✓ ⇒ 从目录点到一个**读过/已预取**的章节时：
        //      · 上下滚动模式：`_scrollView` 的滚动位置保持上一章的 ✗
        //        （落到新章中间/底部，看着像"跳错章"）；
        //      · 进度键没更新 ✗ ⇒ 退出再进还是回到旧章。
        //    `_paginate()` 里换章已把 `_pageIndex` 归零 ✓，这里同步 PageView。
        if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(0);
        await _saveProgress();
      }
      _prefetchAhead(i);
      return;
    }

    // 听书连播标记：**读走即清**（只在"可见加载"时消费）—— 这样后面任何
    // 提前 return（纯图章 / 加载失败）都不会把它残留到别的章节上。
    var ttsAutoNext = false;
    if (!prefetchOnly) {
      ttsAutoNext = _ttsAutoNext;
      _ttsAutoNext = false;
      setState(() {
        // 同上：书签换章在 `_loadChapter` 开头统一处理 ✓（这里原来是死代码 ✓）
        _loading = true;
        _error = null;
        _paragraphs = const [];
        _invalidateTtsSegs();
      });
    }

    final ch = widget.chapters[i];
    try {
      final r = await BookSourceService.instance.content(widget.source, ch.url);
      if (!mounted) return;
      // ✅ 响应回来时确认"我还是最新那次**可见**加载" ✓ —— 否则直接丢弃 ✓
      //（`seq == -1` 表示这是后台预取 ✓，它本来就不该影响界面 ✓）
      if (seq != -1 && seq != _loadSeq) return;
      if (!r.ok) {
        if (!prefetchOnly) {
          setState(() {
            _loading = false;
            _error = r.error ?? '正文获取失败';
          });
        }
        return;
      }
      // ✅ 是否**纯图**章：正文为空 + 有图片 ⇒ 图片模式。
      //    规则：**只有全部是图片内容才能进入图片模式** ✓
      //    （有文字 ⇒ 一律文本流；插图另存到 `_chapterImages`，
      //      供「图片模式」面板查看/保存 ✓）
      // ⚠️ 但 `bookSourceType=2`（漫画源）**本身就是图片源** ✓ ——
      //   其正文常带零星文字（章节标题/“本章完”）✗，若按上面的规则会
      //   退化成文本流、整章看不到图 ✗ ⇒ 漫画源只要有图就保持图片模式 ✓
      // （客户端模型的类型 getter 名为 `type`，取自 raw.bookSourceType）
      // 用统一判据：没写 bookSourceType 的漫画脚本也算漫画源
      // （否则正文带零星文字时会退化成文字流、整章看不到图）。
      final isMangaSource = widget.source.isComicSource;
      final isPureImage =
          r.images.isNotEmpty && (isMangaSource || r.content.trim().isEmpty);
      if (isPureImage) {
        // ⚠️ 不能写 `_cache[i] = const []`：`_cache.containsKey(i)` 是"正文
        // 已加载"的判据 ⇒ 再次进入该章会命中文本缓存、把图片章渲染成空白。
        // 直接移除键（同时清掉上一本/上一章残留的文本）。
        _cache.remove(i);
        if (!prefetchOnly) {
          setState(() {
            _images = r.images;
            // 规则 `@Header:{...}` 给的图片头（Referer/UA）——缺它图床 403
            _mangaImgHeaders = r.headers;
            _chapterImages = const [];
            _paragraphs = const [];
            _resetScrollChain(i);
            _invalidateTtsSegs();
            _pages = const [];
            _pageChapterOf = const [];
            _appendedChapter = -1;
            _loading = false;
            _error = null;
          });
          await _saveProgress();
        }
        // 漫画章不缓存图片列表 ⇒ 预取结果会被丢弃（纯白耗流量/请求数），
        // 所以图片源不预取；文字源照旧预取下一章正文。
        if (!isMangaSource) _prefetchAhead(i);
        return;
      }
      // C9 正文净化：净化 → 繁简 → 气泡（装载链路固定顺序）
      final paras = _splitParagraphs(_applyPurify(r.content));
      _cache[i] = paras; // 缓存**净化后原文**（A2 繁简切换时从原文重转 ✓）
      _evictIfNeeded();
      // 预取晚到 ⇒ 补一次"拼下一章"（用户可能已经停在章末等无缝连读了）
      if (prefetchOnly) {
        _maybeAppendAhead();
        _maybeAppendScrollAhead();
      }
      if (!prefetchOnly) {
        setState(() {
          _paragraphs = _applyConvert(paras);
          // 换章 ⇒ 滚动章链回到单章（滚动视图随之重建、回到章首）
          _resetScrollChain(i);
          _invalidateTtsSegs();
          _images = const []; // 切回文字章节要把漫画图清掉
          _mangaImgHeaders = const {};
          // 文字章附带的插图（上游按 content-is-empty 已排除纯图章）
          _chapterImages = r.images;
          _loading = false;
          _error = null;
        });
        // 新章节 → 重新分页（分页模式）或清空分页（滚动模式）
        _paginate();
        if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(0);
        await _saveProgress();
        // 听书连播：上一章念完预约了续读、且本章正文**已就绪** ⇒ 现在开读
        if (ttsAutoNext) unawaited(_startTts());
      }
      _prefetchAhead(i);
    } catch (e) {
      if (!prefetchOnly && mounted) {
        setState(() {
          _loading = false;
          _error = '加载失败：$e';
        });
      }
    }
  }

  /// 预取下一章 —— 翻页体验的关键。
  /// 不预取的话每次翻章都要等一次网络往返，长篇小说会非常难受。
  /// 按设置预取「当前章之后 N 章」（N = `preloadChapters`，0 = 不预取）。
  ///
  /// 勾了「仅 WiFi 预取」时先查网络类型，非 WiFi 直接跳过（不偷跑流量）。
  void _prefetchAhead(int from) {
    final n = _rs.preloadChapters.clamp(0, 5);
    if (n <= 0) return;
    if (_rs.preloadWifiOnly) {
      unawaited(_prefetchIfWifi(from, n));
      return;
    }
    for (var k = 1; k <= n; k++) {
      _prefetch(from + k);
    }
  }

  Future<void> _prefetchIfWifi(int from, int n) async {
    try {
      final res = await Connectivity().checkConnectivity();
      final wifi = res.any(
        (c) =>
            c == ConnectivityResult.wifi || c == ConnectivityResult.ethernet,
      );
      if (!wifi) return;
    } catch (_) {
      return;
    }
    if (!mounted) return;
    for (var k = 1; k <= n; k++) {
      _prefetch(from + k);
    }
  }

  void _prefetch(int i) {
    if (i < 0 || i >= widget.chapters.length) return;
    // 🔴 **必须有窗口上限** ✗：原来只挡"越界 / 已缓存" ✓，于是每抓完一章又会
    // `_prefetch(i + 1)` ✓ → **打开一章 = 把整本几百章全抓一遍** ✓（几百次网络请求、
    // 几百次正文解析 ✓）；而缓存本身有上限（`_cacheLimit`，见下面 `_evictIfNeeded` ✓）
    // → 刚抓进来的很快又被淘汰 ✓，最后等于**白抓 + 白耗流量** ✓。
    // 只预取"当前章之后 2 章" ✓：保住"下一章秒开" ✓，同时让链式预取**到此为止** ✓
    //（`_index` 就是当前章 ✓，另见 `_loadChapter` 的 `i != _index` 与
    //  `_evictIfNeeded` 的 `(b - _index).abs()` ✓）
    if (i <= _index || i > _index + _rs.preloadChapters.clamp(1, 5)) return;
    if (_cache.containsKey(i)) return;
    // 不 await：后台跑，失败也不影响当前阅读
    _loadChapter(i, prefetchOnly: true);
  }

  /// 缓存超限时丢掉离当前位置最远的章节
  void _evictIfNeeded() {
    if (_cache.length <= _cacheLimit) return;
    final keys = _cache.keys.toList()
      ..sort((a, b) => (b - _index).abs().compareTo((a - _index).abs()));
    while (_cache.length > _cacheLimit && keys.isNotEmpty) {
      _cache.remove(keys.removeAt(0));
    }
  }

  /// C9：正文净化（正则/纯文本替换）。坏正则跳过，不打断阅读。
  String _applyPurify(String raw) => applyPurifyRules(raw, _rs.purifyRules);

  /// C9：正文净化设置弹窗。规则列表 + 启停开关 + 删除自定义规则 +
  /// 新增规则（正则替换），改完即时重排当前章（从净化后原文缓存重转）。
  void _showPurifySheet() {
    final list = List<PurifyRule>.from(_rs.purifyRules);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _bgTop,
      shape: jellySheetShape,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void commit() {
            setSheet(() {});
            setState(() => _rs = _rs.copyWith(purifyRules: List.from(list)));
            _scheduleSavePrefs();
            // 已加载章节：从缓存（净化后原文）重走转换与分页
            _invalidateTtsSegs();
            if (_cache.containsKey(_index)) {
              _paragraphs = _applyConvert(_cache[_index]!);
            }
            _repaginateLayout();
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const JellySheetHandle(),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        '正文净化',
                        style: TextStyle(
                          fontSize: AppTheme.fontTitle2,
                          fontWeight: FontWeight.w700,
                          color: _fg,
                        ),
                      ),
                      const Spacer(),
                      // 导出：把当前规则集复制成 JSON（可分享/换机导入）
                      IconButton(
                        tooltip: '导出规则（复制 JSON）',
                        icon: Icon(
                          Icons.file_upload_outlined,
                          color: _fgMuted,
                          size: 20,
                        ),
                        onPressed: () async {
                          final json = const JsonEncoder.withIndent('  ')
                              .convert(
                            list.map((r) => r.toJson()).toList(),
                          );
                          await Clipboard.setData(ClipboardData(text: json));
                          _toast('已复制 ${list.length} 条规则到剪贴板');
                        },
                      ),
                      // 2026-10-22：导入 legado 替换净化规则（JSON 或 legado:// 链接）
                      IconButton(
                        tooltip: '导入 legado 规则',
                        icon: Icon(
                          Icons.file_download_outlined,
                          color: _fgMuted,
                          size: 20,
                        ),
                        onPressed: () async {
                          final c = TextEditingController();
                          final ok = await showDialog<bool>(
                            context: ctx,
                            builder: (dctx) => AlertDialog(
                              backgroundColor: _bgTop,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                              title: Text(
                                '导入替换净化',
                                style: TextStyle(
                                  fontSize: AppTheme.fontTitle3,
                                  color: _fg,
                                ),
                              ),
                              content: TextField(
                                controller: c,
                                maxLines: 8,
                                minLines: 4,
                                style: TextStyle(color: _fg, fontSize: 13),
                                decoration: InputDecoration(
                                  hintText:
                                      '粘贴 legado 的 replaceRule JSON（数组），\n'
                                      '或 legado://import/replaceRule?src=...',
                                  hintStyle: TextStyle(
                                    color: _fgMuted,
                                    fontSize: 12,
                                  ),
                                  filled: true,
                                  fillColor: _fg.withValues(alpha: 0.05),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(dctx, false),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(dctx, true),
                                  child: const Text('导入'),
                                ),
                              ],
                            ),
                          );
                          if (ok != true) return;
                          var raw = c.text.trim();
                          if (raw.isEmpty) return;
                          // legado://import/replaceRule?src=<urlencoded JSON/URL>
                          if (raw.startsWith('legado://')) {
                            final q = Uri.tryParse(raw)?.queryParameters;
                            raw = (q?['src'] ?? '').trim();
                            if (raw.isEmpty) {
                              _toast('链接里没有 src 参数');
                              return;
                            }
                            raw = Uri.decodeComponent(raw);
                          }
                          try {
                            final parsed = parseLegadoReplaceRules(
                              jsonDecode(raw),
                            );
                            if (parsed.isEmpty) {
                              _toast('没有解析到规则');
                              return;
                            }
                            var added = 0;
                            final exist = list.map((e) => e.pattern).toSet();
                            for (final r in parsed) {
                              if (exist.add(r.pattern)) {
                                list.add(r);
                                added++;
                              }
                            }
                            commit();
                            _toast('已导入 $added 条（重复 ${parsed.length - added} 条已跳过）');
                          } catch (e) {
                            _toast('导入失败：$e（若是远程链接，请先打开它把内容复制过来）');
                          }
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          color: _fgMuted,
                          size: 22,
                        ),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  Text(
                    '正则替换章节正文里的站点残留文案（净化 → 繁简 → 气泡）',
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: _fgMuted,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: list.length + 1,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        color: _fg.withValues(alpha: 0.08),
                      ),
                      itemBuilder: (_, i) {
                        if (i == list.length) {
                          // ── 新增规则 ──
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: InkWell(
                              onTap: () async {
                                final patternC = TextEditingController();
                                final replC = TextEditingController();
                                final ok = await showDialog<bool>(
                                  context: ctx,
                                  builder: (dctx) => AlertDialog(
                                    backgroundColor: _bgTop,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    title: Text(
                                      '新增净化规则',
                                      style: TextStyle(
                                        fontSize: AppTheme.fontTitle3,
                                        color: _fg,
                                      ),
                                    ),
                                    content: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        TextField(
                                          controller: patternC,
                                          style: TextStyle(color: _fg),
                                          decoration: InputDecoration(
                                            labelText: '正则（匹配要清除的文本）',
                                            labelStyle: TextStyle(
                                              color: _fgMuted,
                                            ),
                                            filled: true,
                                            fillColor: _fg.withValues(
                                              alpha: 0.05,
                                            ),
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              borderSide: BorderSide.none,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        TextField(
                                          controller: replC,
                                          style: TextStyle(color: _fg),
                                          decoration: InputDecoration(
                                            labelText: '替换为（默认留空=删除）',
                                            labelStyle: TextStyle(
                                              color: _fgMuted,
                                            ),
                                            filled: true,
                                            fillColor: _fg.withValues(
                                              alpha: 0.05,
                                            ),
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              borderSide: BorderSide.none,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(dctx, false),
                                        child: Text(
                                          '取消',
                                          style: TextStyle(color: _fg),
                                        ),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(dctx, true),
                                        child: const Text('添加'),
                                      ),
                                    ],
                                  ),
                                );
                                if (ok == true &&
                                    patternC.text.trim().isNotEmpty) {
                                  list.add(
                                    PurifyRule(
                                      pattern: patternC.text.trim(),
                                      replacement: replC.text,
                                    ),
                                  );
                                  commit();
                                }
                              },
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.add_circle_outline_rounded,
                                    color: JellyTheme.primary,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    '新增规则',
                                    style: TextStyle(
                                      fontSize: AppTheme.fontBody,
                                      color: _fg,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }
                        final rule = list[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  rule.pattern,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppTheme.fontBody,
                                    color: rule.enabled ? _fg : _fgMuted,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.delete_outline_rounded,
                                  size: 18,
                                  color: _fgMuted,
                                ),
                                onPressed: () {
                                  list.removeAt(i);
                                  commit();
                                },
                              ),
                              Switch(
                                value: rule.enabled,
                                onChanged: (v) {
                                  list[i] = rule.copyWith(enabled: v);
                                  commit();
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 把抓到的正文切成段落。
  ///
  /// 书源返回的正文形态不统一：有的每段换行，有的用 `<br>`（引擎已转成 \n），
  /// 有的还带前后空白、连续空行。这里统一清洗，
  /// 否则段间距会忽大忽小、出现大片空白。
  List<String> _splitParagraphs(String raw) {
    final out = <String>[];
    for (var line in raw.split('\n')) {
      line = line.replaceAll('\r', '').trim();
      if (line.isEmpty) continue;
      // 全角空格也当空白去掉
      line = line.replaceAll('\u3000', ' ').trim();
      if (line.isEmpty) continue;
      out.add(line);
    }
    return out;
  }

  /// A2 繁简转换：按 `_rs.convertMode` 把段落列表整体转换（原文缓存不变）。
  List<String> _applyConvert(List<String> paras) {
    final m = _rs.convertMode;
    if (m == ChineseConvertMode.none || paras.isEmpty) return paras;
    return paras.map((p) => convertChinese(p, m)).toList(growable: false);
  }

  /// A2 设置面板的繁简模式文案
  String _convertLabel(ChineseConvertMode m) => switch (m) {
    ChineseConvertMode.none => '原文',
    ChineseConvertMode.traditionalToSimplified => '繁转简',
    ChineseConvertMode.simplifiedToTraditional => '简转繁',
  };

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0) {
      _toast('已经是第一章');
      return;
    }
    if (next >= widget.chapters.length) {
      _toast('已经是最后一章');
      return;
    }
    setState(() => _index = next);
    _loadChapter(next);
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          // 跟随当前纸色（默认黑底在米黄/古风纸上一块突兀的黑）
          content: Text(m, style: TextStyle(color: _fg, fontSize: 13)),
          backgroundColor: _sheetBg,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 1),
        ),
      );
  }

  // ── UI ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // 面板 / 顶栏 / 底栏也跟随样式：底色用当前实际背景（含样式自带底色），
    // 前景用 [_fg]（含样式日/夜字色）。原来固定用 `_bgs[_bgIndex]`，
    // 套了米黄/古风样式后正文变了、面板还是原来的灰白，观感割裂。
    final bg = <Color>[_bgTop, _fg];
    // ⚠️ 兜底安全区：iOS 上个别机型/系统版本会把 `MediaQuery.padding` 报成 0
    //   （用户截图：正文顶到状态栏、底栏压到 Home 条 —— 就是"字被遮住"）。
    //   `viewPadding` 是设备真实的安全区（不会被上层 SafeArea 消费），
    //   只在 padding 为 0 时用它补，正常机型完全无影响 ✓
    final mq = MediaQuery.of(context);
    final extraTop = mq.padding.top > 0 ? 0.0 : mq.viewPadding.top;
    final extraBottom = mq.padding.bottom > 0 ? 0.0 : mq.viewPadding.bottom;
    // 自选图片（`_customBgPath`）：优先级最高 ✓
    //   夜间优先用夜间那张（.srs 自带日/夜两套），没有再沿用日间图并压暗
    final fileBgPath = _activeFileBgPath;
    final useFileBg = fileBgPath != null && File(fileBgPath).existsSync();
    // 有任何图片背景（自选图 / 内置壁纸）⇒ Scaffold 底色透明，露出图片 ✓
    // 夜间优先用样式自带的夜间壁纸（古风/泼墨都有单独的黑白两版）
    final bgAsset = _activeBgAsset;
    final useImgBg = useFileBg || bgAsset != null;
    // 状态栏 / Home 指示条图标明暗（db 的 darkStatusIcon）：深底换浅色图标，
    // 否则夜间是一排看不见的黑色图标。按**实际纸面**判断（夜间纸 / 深色壁纸 /
    // 深色自定义底），不看昼夜按钮。
    final darkSurface = _paperIsDark;
    final overlayStyle =
        (darkSurface ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
            .copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
            );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        backgroundColor: useImgBg ? Colors.transparent : bg[0],
        body: Stack(
        fit: StackFit.expand,
        children: [
          // 背景层：自定义图片优先（cover 铺满），否则内置/自定义色
          if (useFileBg)
            _nightDim(
              Image.file(
                File(fileBgPath),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => Container(color: bg[0]),
              ),
              // 用的就是夜间那张 ⇒ 不再叠遮罩
              nightVersionInUse: _bgIndex == 5 && _customBgPathNight != null,
            )
          else if (bgAsset != null)
            // 内置壁纸（14 张里选的一张 ✓）
            _nightDim(
              Image.asset(
                bgAsset,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => Container(color: bg[0]),
              ),
              // 夜间版壁纸本身已经压暗过，不再叠遮罩（自选图片没有夜间版 ⇒ 仍压暗）
              nightVersionInUse: _bgImageAssetNight != null,
            )
          else
            Container(color: bg[0]),
          // ✅ 正文层：**整屏**（含状态栏 / Home 条）——
          //   翻页时"页自带纸"（见 [_pagePaper]），覆盖 / 仿真 / 左右滑动时
          //   纸面跟着页一起移动，和静止时像素一致；文字的安全区内衬改由
          //   [_pageBody] 负责（原来正文被 SafeArea 缩小，页里再画壁纸必然错位）。
          //   点击判定与漫画阅读器同款：Listener 原始指针流（双指/连点都稳）。
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onPtrDown,
              onPointerUp: _onPtrUp,
              onPointerCancel: _onPtrCancel,
              child: _contentArea(bg[1]),
            ),
          ),
          // 悬浮 UI（顶栏 / 底栏 / 侧栏 / 番茄钟）仍留在安全区内
          SafeArea(
            child: Padding(
              padding: EdgeInsets.only(top: extraTop, bottom: extraBottom),
              child: Stack(
              children: [
                // 顶栏：悬浮在正文之上（不占布局高度）
                if (_showBar)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _topBarCard(bg[1]),
                  ),
                // 底部功能栏：悬浮在正文之上
                if (_showBar)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _bottomNav(bg[1]),
                  ),
                // TTS 迷你条：浮在底部功能栏**上方**；功能栏收起时贴底
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: _showBar ? 198 : 0,
                  child: _ttsMiniBar(bg[1]),
                ),
                // 右侧竖向悬浮栏（朗读 / 亮度 / 白夜 / 编辑）：与漫画阅读器同款。
                // 设置面板从底部盖上来时让位（否则会被面板压住 ✗）。
                if (_showBar && !_showSettingsPanel) _sideDock(bg[1]),
                // 分页模式没有"正文末尾插图条"的位置 ⇒ 给一个悬浮入口
                // （「查看插图」开启且本章有插图时才出现）
                if (_rs.showIllustrations &&
                    _chapterImages.isNotEmpty &&
                    _rs.pageMode.paginates &&
                    !_showSettingsPanel)
                  Positioned(
                    right: 12,
                    bottom: 110,
                    child: GestureDetector(
                      onTap: _showImageMode,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: _sheetBg,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.16),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.image_outlined,
                              size: 16,
                              color: bg[1].withValues(alpha: 0.8),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '插图 ${_chapterImages.length}',
                              style: TextStyle(
                                fontSize: 12,
                                color: bg[1].withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                // 阅读设置面板见 build 末尾：它被放在 SafeArea **外面**，
                // 才能一直铺到屏幕最底部（含 Home 指示条那一截）✓
                // 番茄钟浮层：bottom 动态计算，避免悬浮功能栏改后错位
                if (_showPomodoro)
                  Obx(
                    () => Positioned(
                      right: 12,
                      bottom: _pomodoroBottomOffset,
                      // 番茄钟玻璃面板按**当前纸色**取明暗（不跟 App 主题）
                      child: PomodoroButton(dark: _paperIsDark),
                    ),
                  ),
                // 听书光碟（Cmbok 同款）：迷你条左滑收起后悬浮，点按展开回迷你条、
                // 拖动换位置，朗读不停 ✓。封面用本书 coverUrl（缺省回退占位底色）。
                if (_ttsDiscCollapsed)
                  Obx(() {
                    final active = _tts.isSpeaking.value || _tts.isPaused.value;
                    if (!active) {
                      // 朗读已停止 → 自动还原迷你条状态（否则下次朗读迷你条被藏住 ✗）
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && _ttsDiscCollapsed) {
                          setState(() => _ttsDiscCollapsed = false);
                        }
                      });
                      return const SizedBox.shrink();
                    }
                    final size = MediaQuery.of(context).size;
                    final pos =
                        _ttsDiscPos ??
                        Offset(size.width - 76, size.height - 210);
                    final cover =
                        widget.coverUrl ??
                        widget.source.raw['coverUrl']?.toString();
                    return Positioned(
                      left: pos.dx.clamp(0.0, size.width - 60),
                      top: pos.dy.clamp(0.0, size.height - 60),
                      child: GestureDetector(
                        onTap: () => setState(() => _ttsDiscCollapsed = false),
                        onPanUpdate: (d) => setState(() {
                          _ttsDiscPos = Offset(
                            ((_ttsDiscPos?.dx ?? pos.dx) + d.delta.dx).clamp(
                              0.0,
                              size.width - 60,
                            ),
                            ((_ttsDiscPos?.dy ?? pos.dy) + d.delta.dy).clamp(
                              0.0,
                              size.height - 60,
                            ),
                          );
                        }),
                        child: Container(
                          width: 54,
                          height: 54,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: bg[1].withValues(alpha: 0.12),
                            border: Border.all(
                              color: bg[1].withValues(alpha: 0.3),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.28),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                            image: cover != null && cover.isNotEmpty
                                ? DecorationImage(
                                    image: NetworkImage(cover),
                                    fit: BoxFit.cover,
                                    onError: (_, __) {},
                                  )
                                : null,
                          ),
                          // 光碟中孔
                          child: Center(
                            child: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: bg[0],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
              ],
            ),
            ),
          ),
          // 阅读设置面板：放在外层 Stack（SafeArea 之外）↓
          //   放里面时 `bottom: 0` 是"安全区上沿"，Home 指示条那截会露出正文
          if (_showSettingsPanel)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeSettingsPanel,
                // 背后压一层遮罩：面板才「浮」在正文之上，而不是和正文连成一片
                child: Container(
                  color: Colors.black.withValues(alpha: 0.32),
                ),
              ),
            ),
          if (_showSettingsPanel) _settingsPanel(bg[1], extraBottom: extraBottom),
        ],
        ),
      ),
    );
  }

  Widget _contentArea(Color fg) {
    // ── 漫画模式：正文是图片列表 ──────────────────────────────
    //
    // 放在最前面判断 —— 漫画源根本没有 _paragraphs，
    // 走后面的"这一章没有正文"分支会显示成空目录。
    if (_images.isNotEmpty) return _mangaView(fg);

    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              strokeWidth: 2,
              color: fg.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 14),
            Text(
              '正在加载正文...',
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                color: fg.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 44,
                color: fg.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 14),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: fg.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () => _loadChapter(_index),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
              TextButton.icon(
                onPressed: () => _go(1),
                icon: const Icon(Icons.skip_next_rounded),
                label: const Text('看下一章'),
              ),
            ],
          ),
        ),
      );
    }
    if (_paragraphs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.article_outlined,
              size: 40,
              color: fg.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(
              '这一章没有正文',
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                color: fg.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '（如果是漫画源，检查 ruleContent.content 是否返回图片）',
              style: TextStyle(
                fontSize: AppTheme.fontFootnote,
                color: fg.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
      );
    }
    // 用 LayoutBuilder 拿到真实视口 —— 分页度量必须和渲染用同一个尺寸，
    // 否则页底要么溢出要么留白。
    return LayoutBuilder(
      builder: (context, box) {
        final vp = Size(box.maxWidth, box.maxHeight);
        if (vp != _viewport) {
          // 尺寸变了（旋屏 / 首次进入）→ 下一帧重新分页
          _viewport = vp;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _paginate();
          });
        }
        // 上下模式：不分页，整章滚动
        if (!_rs.pageMode.paginates || _pages.isEmpty) {
          return _scrollView(fg);
        }
        // 双页模式：横屏左右并排（截图里的「双页模式」）。
        // 放到仿真/覆盖之前 —— 双页是**布局约束**（左右并排 + 平移），
        // 与翻页动画互斥；原来双页只在「左右/无动画」下生效，而仿真/覆盖下
        // 被各自的分支抢走（仿真 → 单页卷曲、覆盖 → 双页平移），表现不一致。
        // 统一规则：开了双页就是 spread 平移，动画样式不叠加。
        if (_dualPageActive && _pages.length > 1) {
          // 把页成对合并：第 0 页单独，之后 (1,2) (3,4) …
          final spreads = <List<int>>[];
          for (var i = 0; i < _pages.length; i += 2) {
            if (i == 0) {
              spreads.add([0]);
            } else {
              spreads.add([i, if (i + 1 < _pages.length) i + 1]);
            }
          }
          return NotificationListener<ScrollNotification>(
            // 章末再滑一次 → 下一章（无缝拼接接不上时的兜底）
            onNotification: _onPageScrollNotification,
            child: PageView.builder(
              controller: _pageCtrl,
              physics: const _TapFriendlyPagePhysics(),
              itemCount: spreads.length,
              onPageChanged: (i) {
                final page = spreads[i].first;
                setState(() => _pageIndex = page);
                _syncChapterWithPage(page);
                _maybeAppendAhead();
                _saveProgress();
              },
              itemBuilder: (c, i) {
                final pair = spreads[i];
                // 纯色底 + 双页并排时，两半页之间加一条软分隔投影（与单页
                // 页缘投影同款），避免"无缝得看不出是两页"；有壁纸时壁纸是
                // 连续一整幅，不需要分隔。
                final sep = !_hasImageBg && pair.length == 2;
                // 分隔投影同样只用黑（深色纸上白色会亮成一条线），深色纸加深
                final sepAlpha = _paperIsDark ? 0.22 : 0.10;
                return Row(
                  children: [
                    for (var k = 0; k < pair.length; k++)
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _pageContent(
                              fg,
                              _pages[pair[k]],
                              chapter: _chapterOfPage(pair[k]),
                              // 两个半页不各铺一次纸（会被裁成两张不同的图）
                              paper: false,
                            ),
                            if (sep)
                              Positioned(
                                left: k == 0 ? null : 0,
                                right: k == 0 ? 0 : null,
                                top: 0,
                                bottom: 0,
                                width: 8,
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.centerLeft,
                                        end: Alignment.centerRight,
                                        colors: k == 0
                                            ? [
                                                Colors.transparent,
                                                Colors.black.withValues(
                                                  alpha: sepAlpha,
                                                ),
                                              ]
                                            : [
                                                Colors.black.withValues(
                                                  alpha: sepAlpha,
                                                ),
                                                Colors.transparent,
                                              ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          );
        }
        // 仿真翻页：用 2.0.3 原有的 BookPageCurl（真卷曲，自绘）
        //
        // 它不是 PageView —— 自己处理拖动/点击与卷曲光栅化，
        // 所以这里单独一条分支，而不是塞进 PageView 的 itemBuilder。
        if (_rs.pageMode == PageMode.curl) {
          // ✅ **越界保护**（blocker 修复 ✓）：`_paginate()` 会在循环里把 `_pages`
          //   换成"只排了第一批"的短列表 ✗，而 `_pageIndex` 是上一次的值 ✗ →
          //   这里 `_pages[_pageIndex]` 会直接 `RangeError` 崩掉 ✓
          //   （触发路径都是日常操作：仿真模式读到大页号点「下一章」/ 旋屏 ✓）。
          //   统一走 [_safePageIndex]：越界就夹回合法范围 + 记一条日志 ✓，**不 throw** ✓
          final pi = _safePageIndex();
          // 与覆盖模式一致：按住下滑一键书签（原来仿真模式漏了这层包装）
          return withPressDownBookmark(
            BookPageCurl(
            page: _pageContent(fg, _pages[pi], chapter: _chapterOfPage(pi)),
            nextPage: pi + 1 < _pages.length
                ? _pageContent(
                    fg,
                    _pages[pi + 1],
                    chapter: _chapterOfPage(pi + 1),
                  )
                : null,
            prevPage: pi > 0
                ? _pageContent(fg, _pages[pi - 1], chapter: _chapterOfPage(pi - 1))
                : null,
            // 页自己已经铺了纸（含壁纸）⇒ 这里不需要再垫一层纯色
            background: const SizedBox.shrink(),
            // 纸面明暗按**样式底色**判断，不看 App 主题：米黄/古风纸在深色主题下
            // 若按 App 主题算，卷起的纸背会被画成近黑色（明显的"翻页发黑"）
            dark: _paperIsDark,
            // 纸背颜色从当前样式底色同一色调推导（米黄纸卷出米黄纸背）。
            // 有壁纸时不能推 —— `_bgTop` 只是"无壁纸时的底色"，和壁纸颜色无关，
            // 推出来的纸背会跟壁纸对不上；这时交给 dark 用固定两档。
            paperTint: _hasImageBg ? null : _bgTop,
            canNext: pi + 1 < _pages.length,
            canPrev: pi > 0,
            onTurnNext: () {
              if (pi + 1 < _pages.length) {
                _setPageIndex(pi + 1);
              } else {
                _go(1);
              }
            },
            onTurnPrev: () {
              if (pi > 0) {
                _setPageIndex(pi - 1);
              } else {
                _go(-1);
              }
            },
            onTapCenter: _toggleBar,
            ),
          );
        }

        // ✅ 覆盖翻页：复用图书阅读器的 `BookPageCover` —— 新页从侧边滑入**覆盖**，
        //    滑入页自带不透明底色 ⇒ 不会与当前页文字**重叠** ✓。
        //    原来「覆盖」只是把 PageView 换成 Clamping 物理 ✗ → 实际效果与「左右」
        //    一模一样（仍是整页平移），用户实测"翻页样式太丑、还重叠" ✗
        if (_rs.pageMode == PageMode.cover) {
          final pi = _safePageIndex();
          return withPressDownBookmark(
            BookPageCover(
              // 页自己已经铺了纸（含壁纸）⇒ 滑动页不再需要垫色
              backgroundColor: Colors.transparent,
              // 前沿投影随纸面明暗（深色纸用浅投影，否则黑投影隐形）
              dark: _paperIsDark,
              page: _pageContent(fg, _pages[pi], chapter: _chapterOfPage(pi)),
              nextPage: pi + 1 < _pages.length
                  ? _pageContent(
                      fg,
                      _pages[pi + 1],
                      chapter: _chapterOfPage(pi + 1),
                    )
                  : null,
              prevPage: pi > 0
                  ? _pageContent(
                      fg,
                      _pages[pi - 1],
                      chapter: _chapterOfPage(pi - 1),
                    )
                  : null,
              canNext: pi + 1 < _pages.length,
              canPrev: pi > 0,
              onTurnNext: () {
                if (pi + 1 < _pages.length) {
                  _setPageIndex(pi + 1);
                } else {
                  _go(1);
                }
              },
              onTurnPrev: () {
                if (pi > 0) {
                  _setPageIndex(pi - 1);
                } else {
                  _go(-1);
                }
              },
              onTapCenter: _toggleBar,
            ),
          );
        }

        // 其余模式（左右 / 无动画）走 PageView
        return Stack(
          children: [
            withPressDownBookmark(
              NotificationListener<ScrollNotification>(
                // 章末再滑一次 → 下一章（无缝拼接接不上时的兜底）
                onNotification: _onPageScrollNotification,
                child: PageView.builder(
                  controller: _pageCtrl,
                  physics: _rs.pageMode == PageMode.none
                      // 无动画：**不滑动**，点点击区/翻页按钮瞬切（Duration.zero）
                      ? const NeverScrollableScrollPhysics()
                      : const _TapFriendlyPagePhysics(),
                  itemCount: _pages.length,
                  onPageChanged: (i) {
                    setState(() => _pageIndex = i);
                    // 无缝翻页：翻到的页若属于下一章，立刻把"当前章"切过去
                    _syncChapterWithPage(i);
                    _maybeAppendAhead();
                    _saveProgress();
                  },
                  itemBuilder: (context, i) =>
                      _pageContent(fg, _pages[i], chapter: _chapterOfPage(i)),
                ),
              ),
            ),
            if (_paginating)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                  color: fg.withValues(alpha: 0.4),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 漫画章节的图片请求头。
  ///
  /// ⚠️ 漫画图床**基本都要 Referer**，没有就是 403 / 空图。
  /// 这里用「书源 header + 以书源站点为 Referer」——
  /// 与项目里 `reader_page.dart` 的 `_imageHeaders` 同一思路
  /// （那边是 MangaSource.imageHeaders + refererForChapter）。
  Map<String, String> get _mangaHeaders {
    final h = <String, String>{};
    final raw = widget.source.raw['header'];
    Map<dynamic, dynamic>? m;
    if (raw is Map) {
      m = raw;
    } else if (raw is String && raw.trim().isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is Map) m = d;
      } catch (_) {}
    }
    m?.forEach((k, v) => h['$k'] = '$v');
    // 补 Referer（大多数图床以此判防盗链）
    final site = widget.source.url;
    if (site.isNotEmpty && !h.keys.any((k) => k.toLowerCase() == 'referer')) {
      h['Referer'] = site;
    }
    // 再兜一层 UA：源没配 header 时很多站直接拒。
    // 优先用源自己的 `httpUserAgent`（Legado 独立字段，移动站按 UA 分流）。
    if (!h.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      final ua = (widget.source.raw['httpUserAgent'] ?? '').toString().trim();
      h['User-Agent'] = ua.isNotEmpty
          ? ua
          : 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
                'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
                'Mobile/15E148 Safari/604.1';
    }
    // 最后覆盖本章 `@Header:{...}`（源的显式声明优先级最高：漫画源就是靠
    // 它把 Referer 指向 m.manhuagui.com 才能从 i.hamreus.com 取到图）。
    _mangaImgHeaders.forEach((k, v) {
      if (v.isEmpty) return;
      // 大小写不同的同名头只保留一个（Referer vs referer 会重复发送）
      final old = h.keys
          .where((x) => x.toLowerCase() == k.toLowerCase() && x != k)
          .toList();
      for (final x in old) {
        h.remove(x);
      }
      h[k] = v;
    });
    return h;
  }

  /// 漫画渲染：**纵向连续滚动**（一图一行）。
  ///
  /// ── 为什么不做"一图一页"的分页 ────────────────────────────────
  /// 手机窄屏下单张漫画图通常比屏幕高，一图一页还得额外缩放；
  /// 纵向滚动是主流漫画 App 的做法，也省掉分页度量。
  /// （横向分页/双页/仿真那套留给**文字**阅读，见 _contentArea。）
  Widget _mangaView(Color fg) {
    final headers = _mangaHeaders;
    // 点击判定统一由正文区 GestureDetector（_onTapUp）负责：
    // 左/右 1/3 翻章、中间 1/3 呼出、面板开时点空白收起（逻辑在 _onTapUp）。
    return ListView.builder(
      // 正文层是整屏（页自带纸）⇒ 漫画也要让开刘海底部的 Home 条
      padding: EdgeInsets.only(
        top: _safeTop + _padTop,
        bottom: _safeBottom + _padBottom + 40,
      ),
      // 图片数量 + 1（末尾放"下一章"）
      itemCount: _images.length + 1,
      itemBuilder: (c, i) {
        if (i == _images.length) {
          // 末尾：本章读完 → 下一章
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: FilledButton.icon(
                onPressed: () => _nextPageOrChapter(),
                style: FilledButton.styleFrom(
                  backgroundColor: fg.withValues(alpha: 0.9),
                  foregroundColor: _bgTop,
                ),
                icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                label: Text(
                  _index + 1 < widget.chapters.length
                      ? '下一章：${widget.chapters[_index + 1].name}'
                      : '已是最后一章',
                  style: const TextStyle(fontSize: AppTheme.fontSubhead),
                ),
              ),
            ),
          );
        }
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: _padLeft / 4),
          child: CachedNetworkImage(
            imageUrl: _images[i],
            // ⚠️ 参数名是 httpHeaders（不是 headers）；
            // 并且复用项目共享的 appImageCacheManager ——
            // 漫画图很大，另建一个 cacheManager 会重复占盘。
            httpHeaders: headers,
            cacheManager: appImageCacheManager,
            fit: BoxFit.fitWidth,
            width: double.infinity,
            // 加载中占位：给个和屏幕同比例的空块，避免滚动条乱跳
            placeholder: (c, u) => Container(
              height: 280,
              alignment: Alignment.center,
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: fg.withValues(alpha: 0.35),
                ),
              ),
            ),
            // 失败：显示序号 + 重试（**不静默空白** —— 空白最难查）
            errorWidget: (c, u, e) => Container(
              height: 200,
              margin: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: fg.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.broken_image_outlined,
                    size: 30,
                    color: fg.withValues(alpha: 0.4),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '第 ${i + 1} 张加载失败',
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: fg.withValues(alpha: 0.6),
                    ),
                  ),
                  Text(
                    '（图床可能需要 Referer，或该图已失效）',
                    style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: fg.withValues(alpha: 0.45),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 上下模式 / 分页失败时的兜底：整章滚动
  Widget _scrollView(Color fg) {
    // 无缝连读：滚动视图里可以**连着排多章**（首章 = 基准章）。
    // 换章 / 目录跳转会把章链重置成单章 ⇒ key 变了 ⇒ 自然回到章首。
    final chain = _scrollChain;
    final scroll = NotificationListener<ScrollNotification>(
      // 快到底 → 续排下一章；停手 → 同步"当前章"
      onNotification: _onScrollNotification,
      // 换章必须重建滚动视图（= 回到章首）：key 用**代次** ⇒
      // 章链内部追加/裁剪章节时 key 不变（位置不跳），真正换章时才换 key。
      // ⚠️ 滚动视图上**不能挂 GlobalKey**：GlobalKey 会让旧 Element 被复用，
      //    代次变化时滚动位置就"回不到章首"了。
      child: KeyedSubtree(
        key: ValueKey('reader-scroll-$_scrollEpoch'),
        child: SingleChildScrollView(
          // 自动阅读（上下模式）要用它滚屏
          controller: _scrollReadCtrl,
          padding: EdgeInsets.fromLTRB(_padLeft, _padTop, _padRight, _padBottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var k = 0; k < chain.length; k++)
                _scrollChapterBlock(chain[k], fg, first: k == 0),
            ],
          ),
        ),
      ),
    );
    // ✅ 信息栏在「上下滚动」模式下也要显示（用户 2026-10-21：
    //   "信息栏开了也不显示"）—— 原来页眉页脚只做在分页的 `_pageBody` 里，
    //   滚动模式完全没渲染 ✗。这里用 Column **预留**上下两条的位置，
    //   而不是盖在正文上 ⇒ 不遮挡任何文字 ✓
    final showHeader = _rs.statusItems.isNotEmpty || _hasHeaderFormat;
    final showFooter = _rs.statusItems.isNotEmpty || _hasFooterFormat;
    final content = (!showHeader && !showFooter)
        ? scroll
        : Column(
            children: [
              if (showHeader)
                _statusHeader(
                  fg,
                  // 滚动模式没有页码，进度用"读到第几章"，至少是个真实数值
                  progressOverride: widget.chapters.isEmpty
                      ? 0
                      : (_index + 1) / widget.chapters.length,
                ),
              Expanded(child: scroll),
              if (showFooter) _statusFooter(fg, showPage: false),
            ],
          );
    // 正文层现在是整屏（含刘海/Home 条）⇒ 文字让开安全区；壁纸仍由外层铺满
    return Padding(
      padding: EdgeInsets.only(top: _safeTop, bottom: _safeBottom),
      child: content,
    );
  }

  /// 滚动视图里"下一章"的段落（带繁简转换的**按章缓存**）。
  ///
  /// 不缓存的话每帧滚动同步都会把后面几章全转换一遍（繁简表不便宜）；
  /// 缓存里记了当时的转换模式，模式一变自动重算。
  final Map<int, ({ChineseConvertMode mode, List<String> paras})> _scrollConv =
      {};

  List<String> _scrollParas(int ch) {
    if (ch == _index) return _paragraphs;
    final raw = _cache[ch];
    if (raw == null) return const <String>[];
    final mode = _rs.convertMode;
    final hit = _scrollConv[ch];
    if (hit != null && hit.mode == mode) return hit.paras;
    final conv = _applyConvert(raw);
    _scrollConv[ch] = (mode: mode, paras: conv);
    return conv;
  }

  /// 滚动视图里的一"章"：章标题 + 全部段落（下一章就是接着往下排）。
  ///
  /// 只有当前章的段落走 [_paragraphWidget]（带 TTS 高亮 / 书签 / 笔记），
  /// 其它章用缓存的段落文本渲染 —— 点长按会先把当前章切过去，再走原有菜单。
  Widget _scrollChapterBlock(
    int ch,
    Color fg, {
    required bool first,
  }) {
    final current = ch == _index;
    final paras = current ? _paragraphs : _scrollParas(ch);
    final key = _scrollKeys.putIfAbsent(ch, () => GlobalKey());
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!first) const SizedBox(height: 26),
        if (_titleHeightFor(ch) != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _titleWidget(
              ch,
              fallbackColor: fg,
              height: _titleHeightFor(ch),
            ),
          )
        else
          Text(
            widget.chapters[ch].name,
            style: TextStyle(
              fontFamily: _fontFamily,
              fontSize: _fontSize + 3,
              fontWeight: FontWeight.w700,
              color: fg,
              height: 1.5,
            ),
          ),
        const SizedBox(height: 18),
        for (var pi = 0; pi < paras.length; pi++)
          current
              ? _paragraphWidget(pi, fg)
              : _paragraphWidget(pi, fg, overrideText: paras[pi], chapter: ch),
        // 「查看插图」：正文末尾展示本章插图（点开走既有的大图查看器）
        if (current && _rs.showIllustrations && _chapterImages.isNotEmpty) ...[
          const SizedBox(height: 18),
          _illustrationStrip(fg),
        ],
      ],
    );
  }

  /// 本章插图条（设置里的「查看插图」开关控制显隐）。
  ///
  /// 说明：文字章附带的插图原本只存在 `_chapterImages` 里，正文流不渲染；
  /// 这里在**上下滚动模式**末尾补一排缩略图，点任意一张打开既有的
  /// `_showImageMode()`（可捏合放大）✓。
  Widget _illustrationStrip(Color fg) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '插图 ${_chapterImages.length} 张',
          style: TextStyle(
            fontSize: 12,
            color: fg.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final u in _chapterImages)
              GestureDetector(
                onTap: _showImageMode,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: u,
                    httpHeaders: _mangaImgHeaders,
                    width: 92,
                    height: 92,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(
                      width: 92,
                      height: 92,
                      color: fg.withValues(alpha: 0.06),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.image_outlined,
                        size: 20,
                        color: fg.withValues(alpha: 0.3),
                      ),
                    ),
                    errorWidget: (_, __, ___) => Container(
                      width: 92,
                      height: 92,
                      color: fg.withValues(alpha: 0.06),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.broken_image_outlined,
                        size: 20,
                        color: fg.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  /// 一个段落的渲染（含首行缩进 / 字间距 / 字重 / 底线 / 书签竖线 / 划线背景 / 长按菜单）
  ///
  /// [chapter]：上下滚动无缝连读时，排在后面的**下一章的段落**要按它自己的
  /// 章号过滤笔记/书签，且不做 TTS 高亮（朗读分段只属于当前章，段落下标会串）。
  Widget _paragraphWidget(
    int pi,
    Color fg, {
    String? overrideText,
    int? chapter,
  }) {
    final ch = chapter ?? _index;
    final current = ch == _index;
    final text = overrideText ?? _paragraphs[pi];
    final note = ReaderNotesService.instance.all
        .where(
          (n) =>
              n.sourceId == widget.source.id &&
              n.bookName == widget.bookName &&
              n.chapterIndex == ch &&
              n.paragraphIndex == pi,
        )
        .firstOrNull;
    final hasNote = note != null;
    final noteBg = note == null
        ? null
        : Color(note.color).withValues(alpha: 0.35);
    // 书签是按章存换的：只有"书签当前所在章"才画竖线
    final bookmark = (_bookmarksChapter == ch) ? _bookmarks[pi] : null;
    return Padding(
      padding: EdgeInsets.only(bottom: _fontSize * _paraSpacing),
      child: GestureDetector(
        onLongPress: () {
          // 下一章的段落：先切过去（书签/笔记/划线都按章存），再弹菜单
          if (!current) _syncChapterFromScroll(ch);
          _onParagraphLongPress(pi);
        },
        // 有笔记/划线的段落：点一下弹「笔记气泡」，可直接改批注或删除
        onTap: note == null ? null : () => _showNoteBubble(note),
        child: Container(
          decoration: BoxDecoration(
            color: noteBg,
            border: Border(
              left: BorderSide(
                color:
                    bookmark ??
                    (note != null ? Color(note.color) : Colors.transparent),
                width: 3,
              ),
            ),
          ),
          padding: EdgeInsets.only(
            left: (bookmark != null || hasNote) ? 8 : 0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (current)
                _wrapWithHighlight(
                  pi,
                  Text(
                    _indent > 0 ? '\u3000' * _indent.round() + text : text,
                    style: _bodyStyle(fg),
                  ),
                )
              else
                Text(
                  _indent > 0 ? '\u3000' * _indent.round() + text : text,
                  style: _bodyStyle(fg),
                ),
              if (note != null)
                WavyUnderline(
                  color: Color(note.color),
                  height: 5,
                  amplitude: 1.1,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 笔记气泡：展示摘录 + 批注，并可直接编辑/删除。
  Future<void> _showNoteBubble(ReaderNote note) async {
    final excerpt = note.text.trim();
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _bgTop,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.format_quote_rounded,
                      size: 18,
                      color: Color(note.color),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '笔记',
                      style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w700,
                        color: _fg,
                      ),
                    ),
                    const Spacer(),
                    if (note.chapterName.isNotEmpty)
                      Text(
                        note.chapterName,
                        style: TextStyle(
                          fontSize: 11,
                          color: _fgMuted,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                if (excerpt.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                    decoration: BoxDecoration(
                      color: Color(note.color).withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                      border: Border(
                        left: BorderSide(color: Color(note.color), width: 3),
                      ),
                    ),
                    child: Text(
                      excerpt,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        height: 1.5,
                        color: _fg,
                      ),
                    ),
                  ),
                if (note.note.trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    note.note,
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      height: 1.5,
                      color: _fg,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.pop(ctx, 'edit'),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('编辑批注'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.pop(ctx, 'delete'),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                        ),
                        label: const Text('删除'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'delete') {
      await ReaderNotesService.instance.remove(note.id);
      if (!mounted) return;
      setState(() {});
      _toast('已删除笔记');
      return;
    }
    if (action == 'edit') {
      final text = await _showNoteInput(excerpt);
      if (text == null || !mounted) return;
      await ReaderNotesService.instance.addNote(
        sourceId: widget.source.id,
        sourceName: widget.source.name,
        bookName: widget.bookName,
        chapterIndex: note.chapterIndex,
        chapterName: note.chapterName,
        paragraphIndex: note.paragraphIndex,
        text: excerpt.isEmpty ? note.text : excerpt,
        note: text,
        color: note.color,
      );
      if (!mounted) return;
      setState(() {});
      _toast('批注已更新');
    }
  }

  /// 当前正在朗读的「全局段落下标」。
  ///
  /// TtsService 把整章按段落+标点切成 _segments（句子级），
  /// `currentIndex` 是**句**下标。要把它映射回**段**下标：
  /// 逐段用 splitSegments 算该段占几句，累加到 currentIndex 落在哪段。
  ///
  /// 为什么要这个映射：高亮是按段画的（一句一个底色太碎），
  /// 而 TtsService 的进度是按句的。
  int? get _ttsParagraph {
    if (!_tts.isSpeaking.value && !_tts.isPaused.value) return null;
    final segs = _ttsSegments;
    if (segs.isEmpty) return null;
    final target = _tts.currentIndex.value;
    if (target < 0) return null;
    var acc = 0;
    for (var pi = 0; pi < _paragraphs.length; pi++) {
      final n = TtsService.splitSegments(_paragraphs[pi]).length;
      if (target < acc + n) return pi;
      acc += n;
    }
    return _paragraphs.isEmpty ? null : _paragraphs.length - 1;
  }

  /// 正在朗读那一段的底色（跟读高亮）。
  ///
  /// ⚠️ 这里**返回 BoxDecoration 而不是 Widget** ——
  /// 一开始我返回的是带 decoration 的 Container，然后想在
  /// Obx 里读 `d.decoration` 复用，但 Widget 上没有那个字段。
  /// 拆成"算出装饰"和"套上装饰"两步更直接。
  ///
  /// 关于「高亮：关 / 当前句 / 当前段」：
  /// 两者都用**同一段**的高亮 —— 逐句高亮要按句切分正文，那会破坏
  /// 整段的可选性（用户就没法长按选一整段了）。所以按段画，
  /// 区别只在"当前句模式"下会额外用左边框标出正在念的那句的位置感。
  BoxDecoration? _ttsHighlightDecoration(int pi) {
    if (_ttsHighlight == 0) return null;
    if (pi != _ttsParagraph) return null;
    const colors = [
      Color(0xFFF5C842),
      Color(0xFF8FD48F),
      Color(0xFF7EC8F0),
      Color(0xFFF07E9E),
      Color(0xFFC88FE8),
      Color(0xFFA8B4E0),
    ];
    final c = colors[_ttsColor.clamp(0, colors.length - 1)];
    return BoxDecoration(
      color: c.withValues(alpha: 0.22),
      borderRadius: BorderRadius.circular(10),
      // 当前句模式：左侧竖线标出句首位置
      border: _ttsHighlight == 1
          ? Border(left: BorderSide(color: c, width: 3))
          : null,
    );
  }

  /// 把一段正文包上跟读高亮（用 Obx 订阅 TtsService 的进度变化）
  Widget _wrapWithHighlight(int pi, Widget child) {
    if (_ttsHighlight == 0) return child;
    return Obx(() {
      final d = _ttsHighlightDecoration(pi);
      if (d == null) return child;
      return Container(
        decoration: d,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        // ✅ **自动定位阅读位置**（本轮接上 ✓ —— 对应 TTS 面板里的那个开关 ✓）：
        //   · 这个 `Obx` **本身就在"朗读进度变化"时重建** ✓✓，而 `d != null`（判据在
        //     `_ttsHighlightDecoration:1212` ✓）恰好表示 **`pi` 就是"正在念的那一段"** ✓
        //     ⇒ 所以**不需要**另加监听/定时器 ✓，只在"成为当前段"时滚一次即可 ✓。
        //   · ⚠️ 用 `Builder` 取一个**段内**的 `BuildContext` ✓ —— `Obx` 的 builder **不带** context ✗，
        //     而 `Scrollable.ensureVisible` 需要一个**已挂载**的 context ✓✓。
        //   · ⚠️ 放进 `addPostFrameCallback` ✓：重建当帧**尚未布局** ✗，滚动目标要等一帧才准确 ✓。
        //   · ⚠️ `alignment: 0.35` ✓：让当前段停在视口**偏上**处 ✓（下方还留得住下一段 ✓ 更好读 ✓）。
        child: Builder(
          builder: (ctx) {
            if (_ttsAutoLocate) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || !ctx.mounted) return;
                Scrollable.ensureVisible(
                  ctx,
                  alignment: 0.35,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOut,
                );
              });
            }
            return child;
          },
        ),
      );
    });
  }

  TextStyle _bodyStyle(
    Color fg, {
    bool bold = false,
    bool noUnderline = false,
  }) => TextStyle(
    fontFamily: _fontFamily,
    fontSize: _fontSize,
    height: _lineHeight,
    letterSpacing: _letterSpacing,
    fontWeight: bold ? FontWeight.w700 : _fontWeightToW(_fontWeight),
    color: fg,
    decoration: _underlineStyle == 0 || noUnderline
        ? TextDecoration.none
        : TextDecoration.underline,
    decorationColor: (_underlineColor ?? fg).withValues(alpha: _underlineAlpha),
    decorationStyle: _underlineStyle == 1
        ? TextDecorationStyle.dashed
        : _underlineStyle == 2
        ? TextDecorationStyle.dotted
        : _underlineStyle == 4
        ? TextDecorationStyle.wavy
        : TextDecorationStyle.solid,
    decorationThickness: _underlineWidth,
  );

  // ── A1 对话气泡几何 ────────────────────────────────────────────
  //
  // 🔴 这 4 个常量是**渲染与分页共用的唯一真源** ✗：气泡把对话段落缩窄 +
  //    加内衬 ✗，分页若仍按正文全宽度量 ✓，渲染就会比量出来高 ⇒ 整页溢出
  //    屏幕底部 ✗（用户实测："气泡以及里面的文字容易出整个屏幕" ✓）。
  //    改这里两边一起变 ✓，不可能再各算一套 ✓。
  static const double _kBubbleWidthFactor = 0.72; // 气泡最大宽 = 视口宽 × 此系数
  static const double _kBubblePadH = 12; // 左右内衬
  static const double _kBubblePadV = 8; // 上下内衬
  static const double _kBubbleBorder = 1; // 边框

  /// 气泡外层最大宽度。用**渲染同一视口** `_viewport`（不用 MediaQuery）——
  /// 分页度量也按它算，两边才不会各算一套 ✗。
  ///
  /// 并且要和**正文内容区宽度**取小 ✓：左右边距调得很大时，`0.72×宽` 会超过
  /// 内容区 ✗ → 渲染被父级夹窄 ✓ 而度量仍按 0.72×宽 ✓ ⇒ 又变成"度量宽、渲染
  /// 窄"的老毛病 ✗。取小后两边一致 ✓。
  double get _bubbleMaxWidth {
    final w = _viewport.width > 0
        ? _viewport.width
        : MediaQuery.of(context).size.width;
    final factorW = w * _kBubbleWidthFactor;
    final contentW = w - _padLeft - _padRight;
    return (contentW > 0 && contentW < factorW) ? contentW : factorW;
  }

  /// 气泡**文字区**宽度（= 最大宽 - 左右内衬 - 边框）→ 交给分页器度量
  double get _bubbleTextWidth =>
      _bubbleMaxWidth - (_kBubblePadH + _kBubbleBorder) * 2;

  /// 每个气泡**额外占的高度**（上下内衬 + 上下边框）→ 交给分页器计入
  double get _bubbleExtraV => (_kBubblePadV + _kBubbleBorder) * 2;

  /// 自定义气泡底色：没挑过色时用一个低调的浅底（跟随前景派生）
  Color get _customBubbleBg =>
      Color(_rs.bubbleBgColor ?? _fg.withValues(alpha: 0.08).toARGB32());

  /// 自定义气泡文字色：没挑过色时跟随正文前景
  Color get _customBubbleText => Color(_rs.bubbleTextColor ?? _fg.toARGB32());

  /// A1 对话气泡容器：圆角卡片 + 配色（浅 / 深 / 护眼 / 自定义），跟随全局明暗。
  /// [alignRight] 为真时右对齐（对称气泡的偶数段）。
  Widget _bubbleWrap(
    String text,
    Color fg,
    bool alignRight,
    BubblePalette palette,
  ) {
    final isDark = fg.computeLuminance() > 0.45; // 前景亮 = 深色模式
    late final Color bg, border, textColor;
    switch (palette) {
      case BubblePalette.light:
        bg = fg.withValues(alpha: 0.06);
        border = fg.withValues(alpha: 0.10);
        textColor = fg;
      case BubblePalette.dark:
        bg = fg.withValues(alpha: 0.13);
        border = fg.withValues(alpha: 0.20);
        textColor = fg;
      case BubblePalette.eye:
        bg = isDark ? const Color(0xFF1F2E24) : const Color(0xFFE9F5EC);
        border = isDark ? const Color(0xFF31463A) : const Color(0xFFC9E4D0);
        textColor = isDark ? const Color(0xFFD9E9DD) : const Color(0xFF2E4A38);
      case BubblePalette.custom:
        // 用户自选底色 / 文字色；描边只画淡淡的（对比交给底色本身）
        bg = _customBubbleBg;
        border = fg.withValues(alpha: 0.12);
        textColor = _customBubbleText;
    }
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: _bubbleMaxWidth),
        padding: const EdgeInsets.symmetric(
          horizontal: _kBubblePadH,
          vertical: _kBubblePadV,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border, width: _kBubbleBorder),
        ),
        child: Text(
          text,
          style: _bodyStyle(textColor, noUnderline: true),
        ),
      ),
    );
  }

  /// A3：分析内置壁纸图片的平均亮度（暗图 → 自动换浅字）。
  Future<bool> _assetIsDark(String asset) async {
    try {
      final data = await rootBundle.load(asset);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final px = bytes.buffer.asUint8List();
      var sum = 0, n = 0;
      // 每 64 字节（16 像素）抽样一个，够算平均亮度
      for (var i = 0; i + 4 <= px.length; i += 64) {
        sum += (px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) ~/ 1000;
        n++;
      }
      return n > 0 && sum / n < 128;
    } catch (_) {
      return false;
    }
  }

  /// 自选**文件**背景图是否为深色（与 [_assetIsDark] 同款抽样，用于
  /// [_fileBgDark]）。结果异步回填并 setState，状态栏/纸背/番茄钟随之明暗。
  Future<void> _analyzeFileBg(String path) async {
    bool dark;
    try {
      final data = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(data);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final px = bytes.buffer.asUint8List();
      var sum = 0, n = 0;
      for (var i = 0; i + 4 <= px.length; i += 64) {
        sum += (px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) ~/ 1000;
        n++;
      }
      dark = n > 0 && sum / n < 128;
    } catch (_) {
      dark = false;
    }
    if (!mounted || _fileBgDark == dark) return;
    setState(() => _fileBgDark = dark);
  }

  /// A3：背景壁纸选择弹窗（14 张内置 + 无壁纸），深色图自动换浅字。
  Future<void> _showBgImageSheet() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labelColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      shape: jellySheetShape,
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              // 弹窗一律**最高半屏**（用户 2026-10-12）：内容区自带滚动 ✓
              maxHeight: MediaQuery.of(ctx).size.height * 0.5,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const JellySheetHandle(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 16, 10),
                  child: Row(
                    children: [
                      Text(
                        '背景壁纸',
                        style: TextStyle(
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w700,
                          color: labelColor,
                        ),
                      ),
                      const Spacer(),
                      JellySheetCircleButton(
                        isDark: isDark,
                        icon: Icons.close_rounded,
                        onTap: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.78,
                    children: [
                      _bgWallCell(ctx, null, labelColor, isDark),
                      for (final asset in _builtinBgImages)
                        _bgWallCell(ctx, asset, labelColor, isDark),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null) return;
    // 空字符串 = 选「无壁纸」（回到纯色底）
    if (picked.isEmpty) {
      setState(() {
        _bgImageAsset = null;
        _bgImageAssetNight = null;
        _bgImageDark = null;
      });
      _scheduleSavePrefs();
      return;
    }
    final dark = await _assetIsDark(picked);
    if (!mounted) return;
    setState(() {
      _bgImageAsset = picked;
      // 黑白成对的图（古风/泼墨/皮卡）顺手带出夜间版；其余夜间压暗
      _bgImageAssetNight = ReaderBgAssets.pairOf(picked);
      _bgImageDark = dark;
    });
    _precachePaper();
    _scheduleSavePrefs();
  }

  /// A3：壁纸弹窗里的一个格子（null = 「无壁纸」）。
  Widget _bgWallCell(
    BuildContext ctx,
    String? asset,
    Color labelColor,
    bool isDark,
  ) {
    final selected = asset == _activeBgAsset;
    final isNone = asset == null;
    return GestureDetector(
      onTap: () => Navigator.pop(ctx, asset ?? ''),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? JellyTheme.primary
                : (isDark
                      ? Colors.white.withValues(alpha: 0.10)
                      : Colors.black.withValues(alpha: 0.07)),
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: JellyTheme.primary.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: isNone
            ? ColoredBox(
                color: isDark
                    ? const Color(0xFF2B2B2B)
                    : const Color(0xFFF5EFE0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.format_color_reset_rounded,
                      size: 26,
                      color: labelColor,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '无壁纸',
                      style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: labelColor,
                      ),
                    ),
                  ],
                ),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(asset, fit: BoxFit.cover),
                  if (selected)
                    Container(
                      color: JellyTheme.primary.withValues(alpha: 0.10),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.check_circle_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  /// 页眉 + 页脚（信息栏）占掉的高度 —— 分页度量要把它从可用高度里减掉 ✓。
  /// 信息栏关闭（`statusItems` 为空）时两者都不渲染 ⇒ 返回 0 ✓。
  ///
  /// ⚠️ 状态文字没有显式 `height`，行高随字体（约 1.17~1.3 倍字号）——
  ///   这里按 **1.3** 估：宁可多留一点（页底略空），也不能少留（会把末行裁掉 ✗）。
  /// 页眉上边距的**实际值**。
  ///
  /// db 的 `headerPaddingTop` 是"距屏幕顶部"的距离（包含状态栏），
  /// 而阅读器外层已经套了 SafeArea —— 直接照用会让页眉整体下移一整条状态栏
  /// （微信读书那套 58 尤其明显：正文区凭空少 40~50px）。这里先减掉状态栏。
  double get _effectiveHeaderPadTop {
    final inset = _safeTop;
    return (_headerPadTop - inset).clamp(0.0, 120.0);
  }

  double _headerFooterHeight() {
    // 正文层现在是**整屏**（页自带纸）⇒ 安全区要算进"页眉页脚占位"里：
    // 页内布局是 Padding(safeTop) → 页眉 → 正文 → 页脚 → Padding(safeBottom)。
    final safeTop = _safeTop;
    final safeBottom = _safeBottom;
    // 行高必须包含**信息栏字号**（`_rs.statusTextScale`）和系统字体缩放：
    // 页眉页脚的字号是 `fontCaption * statusTextScale`，Text 还会再乘
    // MediaQuery.textScaler。原来只算 `fontCaption * 1.3` ⇒ 选「超大」或
    // 系统大字号时预留高度偏小 ⇒ 正文可用高度偏大 ⇒ 页底最后一行被裁。
    final scale =
        _rs.statusTextScale *
        MediaQuery.textScalerOf(context).scale(1.0);
    final line = AppTheme.fontCaption * 1.3 * scale;
    // 格式串模式：只为**实际有内容**的那一条留位置（与渲染条件一致）
    final hasHeader = _hasHeaderFormat || _rs.statusItems.isNotEmpty;
    final hasFooter = _hasFooterFormat || _rs.statusItems.isNotEmpty;
    final header = hasHeader ? _effectiveHeaderPadTop + 6 + line + 4 : 0.0;
    final footer = hasFooter ? 4 + line + _footerPadBottom + 6 : 0.0;
    return safeTop + header + footer + safeBottom;
  }

  /// 某一页属于哪一章（无缝拼接后 `_pages` 里混有多章）
  int _chapterOfPage(int i) =>
      (i >= 0 && i < _pageChapterOf.length) ? _pageChapterOf[i] : _index;

  /// 一页的内容（含页眉 / 页脚信息栏 + 页自己的"纸"）
  ///
  /// [paper] 为真时这一页自己铺壁纸/底色（翻页动画里纸跟着页走，
  /// 与静止时像素一致）；双页模式传 false —— 两个半页各铺一次壁纸会被
  /// 各自裁切成"两张不同的图"，此时沿用外层整屏壁纸。
  Widget _pageContent(
    Color fg,
    BookPage page, {
    int? chapter,
    bool paper = true,
  }) {
    final body = _pageBody(fg, page, chapter: chapter);
    if (!paper) return body;
    final content = Stack(
      fit: StackFit.expand,
      children: [_pagePaper(), body],
    );
    // 页缘投影：只在"两页并排平移"的模式（左右 / 无动画）+ 纯色纸时画 ——
    // 给两页之间一个可见软边界；壁纸纸面画阴影会像"两张一样的图拼在一起"。
    if (_hasImageBg ||
        (_rs.pageMode != PageMode.slide && _rs.pageMode != PageMode.none)) {
      return content;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: 8,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.10),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── 页眉 / 页脚「格式串」（对齐源阅读的"编辑小组件"）───────────
  //
  // 变量：# 章节名 · c 章节序号 · C 总章数 · p 本章页码 · P 本章总页数
  //       % 进度百分比 · t 时间 · b 电量 · B 书名
  // 三个位置（左 / 中 / 右）各一条；为空则退回到「信息栏项目」开关的老逻辑。

  bool get _hasHeaderFormat =>
      _headerL.trim().isNotEmpty ||
      _headerC.trim().isNotEmpty ||
      _headerR.trim().isNotEmpty;

  bool get _hasFooterFormat =>
      _footerL.trim().isNotEmpty ||
      _footerC.trim().isNotEmpty ||
      _footerR.trim().isNotEmpty;

  /// 一次扫描替换（避免替换出来的内容里再被二次替换）
  ///
  /// [chapter] 是**这一页所属**的章（无缝连读时 `_index` 可能还没跟上，
  /// 页眉页脚会短暂显示上一章的章名/章号）。
  String _resolveFormat(String tpl, double progress, [int? chapter]) {
    if (tpl.trim().isEmpty) return '';
    final scrollMode = _rs.pageMode == PageMode.scroll;
    final ch = (chapter ?? _index).clamp(0, widget.chapters.length - 1);
    return resolveHeaderFooterTemplate(tpl, {
      '%': '${(progress * 100).round()}%',
      '#': widget.chapters[ch].name,
      'C': '${widget.chapters.length}',
      'P': scrollMode ? '-' : '$_localPageCount',
      'B': widget.bookName,
      'c': '${ch + 1}',
      'p': scrollMode ? '-' : '$_localPageNo',
      't': TimeOfDay.now().format(context),
      'b': _batteryValue(),
      // `n` = 纯数字电量（不带 %）—— db 的 `format` 里 % 是字面量，
      // 如 `#%` / `#个想法`，需要能单独拿到数字
      'n': _batteryPct == null ? '--' : '$_batteryPct',
    });
  }

  /// 电量（带 60 秒缓存；首次拿不到显示 `--`，拿到后自动刷新）
  String _batteryValue() {
    final now = DateTime.now();
    final at = _batteryAt;
    final stale = at == null || now.difference(at) > const Duration(minutes: 1);
    if (!_batteryFetching && (_batteryPct == null || stale)) {
      _batteryFetching = true;
      _batteryAt = now;
      unawaited(
        _tts.batteryLevel().then((v) {
          _batteryFetching = false;
          if (!mounted || v == null) return;
          _batteryPct = v;
          setState(() {});
        }),
      );
    }
    return _batteryPct == null ? '--' : '$_batteryPct%';
  }

  /// 左 / 中 / 右 三等分的格式行
  Widget _formatRow(
    Color fg,
    String left,
    String center,
    String right,
    double progress, {
    int? chapter,
  }) {
    Widget slot(String tpl, TextAlign align) {
      final t = _resolveFormat(tpl, progress, chapter);
      return Text(
        t,
        textAlign: align,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _statusStyle(fg),
      );
    }

    final templates = [left, center, right];
    final used = templates.where((t) => t.trim().isNotEmpty).toList();
    // 只填了一个位置 ⇒ 直接按它自己的对齐占满整行（长章节名不会被挤成 1/3）
    if (used.length <= 1) {
      final idx = templates.indexWhere((t) => t.trim().isNotEmpty);
      if (idx < 0) return const SizedBox.shrink();
      const aligns = [
        TextAlign.left,
        TextAlign.center,
        TextAlign.right,
      ];
      const boxes = [
        Alignment.centerLeft,
        Alignment.center,
        Alignment.centerRight,
      ];
      return Align(
        alignment: boxes[idx],
        child: slot(templates[idx], aligns[idx]),
      );
    }
    return Row(
      children: [
        Expanded(child: slot(left, TextAlign.left)),
        Expanded(child: slot(center, TextAlign.center)),
        Expanded(child: slot(right, TextAlign.right)),
      ],
    );
  }

  /// 页眉（信息栏上排）：时间 · 书名 · 进度
  ///
  /// 分页 / 上下滚动两种模式共用（滚动模式没有页码，进度按章节位置算）。
  Widget _statusHeader(Color fg, {double? progressOverride, int? chapter}) {
    final items = _rs.statusItems;
    final progress =
        progressOverride ??
        (_pages.isEmpty ? 0.0 : _localPageNo / _localPageCount);
    if (_hasHeaderFormat) {
      return Padding(
        padding: EdgeInsets.fromLTRB(
          _headerPadH,
          _effectiveHeaderPadTop + 6,
          _headerPadH,
          4,
        ),
        child: _formatRow(
          fg,
          _headerL,
          _headerC,
          _headerR,
          progress,
          chapter: chapter,
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _headerPadH,
        _effectiveHeaderPadTop + 6,
        _headerPadH,
        4,
      ),
      child: Row(
        children: [
          if (items.contains('时间'))
            _statusText(TimeOfDay.now().format(context), fg),
          if (items.contains('书名'))
            Expanded(
              child: Text(
                widget.bookName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _statusStyle(fg),
              ),
            ),
          const Spacer(),
          if (items.contains('进度'))
            _statusText('${(progress * 100).round()}%', fg),
        ],
      ),
    );
  }

  /// 页脚（信息栏下排）：章节 · 电量 · 页码
  Widget _statusFooter(Color fg, {bool showPage = true, int? chapter}) {
    final items = _rs.statusItems;
    // 滚动模式没有页码 ⇒ 用"读到第几章"当进度
    final progress = _pages.isEmpty
        ? (widget.chapters.isEmpty
              ? 0.0
              : (_index + 1) / widget.chapters.length)
        : _localPageNo / _localPageCount;
    if (_hasFooterFormat) {
      return Padding(
        padding: EdgeInsets.fromLTRB(
          _footerPadH,
          4,
          _footerPadH,
          _footerPadBottom + 6,
        ),
        child: _formatRow(
          fg,
          _footerL,
          _footerC,
          _footerR,
          progress,
          chapter: chapter,
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _footerPadH,
        4,
        _footerPadH,
        _footerPadBottom + 6,
      ),
      child: Row(
        children: [
          if (items.contains('章节'))
            Expanded(
              child: Text(
                widget.chapters[(chapter ?? _index).clamp(
                  0,
                  widget.chapters.length - 1,
                )].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _statusStyle(fg),
              ),
            ),
          const Spacer(),
          if (items.contains('电量')) _batteryText(fg),
          if (showPage && items.contains('页码'))
            _statusText('$_localPageNo/$_localPageCount', fg),
        ],
      ),
    );
  }

  /// 一页的**内容本体**（页眉 / 正文 / 页脚）。
  /// 由 [_pageContent] 铺上"纸"（壁纸/底色）后使用 ✓。
  Widget _pageBody(Color fg, BookPage page, {int? chapter}) {
    // 这一页属于哪一章（无缝拼接后可能不是 `_index`；章标题/页脚都用它）
    final pageChapter = chapter ?? _index;
    final items = _rs.statusItems;
    final showHeader = items.isNotEmpty || _hasHeaderFormat;
    final showFooter = items.isNotEmpty || _hasFooterFormat;
    // 点击判定统一由正文区 GestureDetector（_onTapUp）负责，这里不再注册
    return Padding(
      // 页是整屏的（纸铺到刘海里）⇒ 文字自己让开安全区
      padding: EdgeInsets.only(top: _safeTop, bottom: _safeBottom),
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 页眉 ────────────────────────────────────────────
        if (showHeader) _statusHeader(fg, chapter: pageChapter),
        // ── 正文 ────────────────────────────────────────────
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 0),
            child: ListView.builder(
              physics: const NeverScrollableScrollPhysics(),
              // ✅ 左右 / 上下边距在这里**真正生效** —— 与 `_paginate` 的可用区域一致 ✓
              //   （原来写死 `(0, 2, 0, 2)` ✗ ⇒「排版」里的边距滑块调了没反应 ✗）
              padding: EdgeInsets.fromLTRB(
                _padLeft,
                _padTop + 2,
                _padRight,
                _padBottom + 2,
              ),
              itemCount: page.entries.length,
              itemBuilder: (c, i) {
                final e = page.entries[i];
                final b = e.block;
                if (b is HeadingBlock) {
                  final headingText = e.partialText ?? b.text;
                  // 自定义「标题样式」：HTML 模板解析出的复合版式
                  // （固定高度已由分页器按同一套度量计入）
                  final titleH = _titleHeightFor(pageChapter);
                  if (titleH != null) {
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: _fontSize * _paraSpacing,
                      ),
                      child: _titleWidget(
                        pageChapter,
                        fallbackColor: fg,
                        height: titleH,
                      ),
                    );
                  }
                  // 隐藏重复标题：章首标题与章节名相同时不再显示（IMG_8495）
                  if (_hideRepeatTitle &&
                      headingText.trim() ==
                          widget.chapters[pageChapter].name.trim()) {
                    return const SizedBox.shrink();
                  }
                  // 上下留白与分页器一致（top 4 + 段距）——分页器按
                  // `tp.height + 4 + blockSpacing` 量，这里必须一模一样，
                  // 否则每章第一页底部被裁 / 顶部留白。
                  return Padding(
                    padding: EdgeInsets.only(
                      top: 4,
                      // 默认标题也吃「标题间距」滑杆（分页端同参：headingExtraBottom）
                      bottom: _fontSize * _paraSpacing + _titleGap,
                    ),
                    child: Text(
                      headingText,
                      textAlign: _titleAlign == 1
                          ? TextAlign.center
                          : TextAlign.left,
                      style: TextStyle(
                        fontSize: _defaultTitleFontSize,
                        fontWeight: _titleBold
                            ? FontWeight.w700
                            : FontWeight.w400,
                        color: fg,
                        height: 1.5,
                        // 标题不带正文字距（与分页器 headingStyle 一致）
                        letterSpacing: 0,
                      ),
                    ),
                  );
                }
                if (b is ParagraphBlock) {
                  // 分页后可能是半段（partialText），直接用它的文本渲染；
                  // 🔴 段落下标用**分页器带下来的全书块下标**直接换算 ✓
                  // 本页 `blocks = [章标题?, ...段落]` ⇒ 段落下标 = blockIndex - 首块数 ✓。
                  // 原实现 `_paragraphs.indexOf(b.text)` 会命中**第一个同文本段** ✗：
                  // 正文里重复段（空行、"……"、重复短句）的第 2 处及之后，
                  // 书签/批注都会落到第 1 处 ✗（与笔记定位同源的错位 ✓）。
                  // ⚠️ 隐藏重复标题时 `blocks` 里没有标题块 ⇒ 偏移量是 0，不是 1
                  //   （见 `_paginate` 的 `hasHeading`）。
                  final pi = e.blockIndex >= 0
                      ? e.blockIndex - _blockOffset
                      : _paragraphIndexOf(b);
                  // ✅ 首行缩进已在**分页块**里加过（见 `_paginate`）⇒ 这里直接用 ✓
                  //   （原来度量用原文、渲染再加 2 个全角空格 ✗ ⇒ 渲染比量出来的多占 36px 宽、
                  //    多折行 ⇒ 页面底部溢出被裁，看着就是"文字被切片" ✗）
                  final paraText = e.partialText ?? b.text;
                  // ✅ A1 对话/旁白气泡（Cmbok 差距文档）：
                  //   引号开头识别为对话行 → 渲染为气泡卡片；旁白平铺。
                  //   对称模式按段落下标奇偶左右交错。识别在渲染层动态做
                  //   （不重建块数据，书签/笔记定位零影响 ✓）
                  final bubbleOn = _rs.bubbleMode != BubbleMode.none;
                  // 🔴 判定必须用**整段原文**、不能用 `paraText` ✗：
                  //    长对话段被分页切成多块时，第 2 块起的 `partialText`
                  //    已不含开头的引号 ✓ ⇒ 按 `paraText` 判会把后半段判成
                  //    旁白、渲染成平铺 ✗（同一段"半截气泡半截平铺" ✓），
                  //    而分页器是按**整段**判的 ✓ ⇒ 两边不一致 ⇒ 页底留白/漂移 ✗。
                  final fullPara = (pi >= 0 && pi < _paragraphs.length)
                      ? _paragraphs[pi]
                      : paraText;
                  final isBubble =
                      bubbleOn &&
                      paragraphKindOf(fullPara) == ParagraphKind.dialogue;
                  final bubbleRight =
                      isBubble &&
                      _rs.bubbleMode == BubbleMode.symmetric &&
                      pi.isOdd;
                  // 满行底线（信纸）：每行拉满整行宽，用段落底边线实现（IMG_8497/8498）
                  Widget body = isBubble
                      ? _bubbleWrap(
                          paraText,
                          fg,
                          bubbleRight,
                          _rs.bubblePalette,
                        )
                      : Text(
                          paraText,
                          style: _bodyStyle(
                            fg,
                            bold: _focusBold && pi == 0,
                            noUnderline: _underlineFull,
                          ),
                        );
                  if (_underlineFull && !isBubble) {
                    body = Container(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: (_underlineColor ?? fg).withValues(
                              alpha: _underlineAlpha,
                            ),
                            width: _underlineWidth,
                          ),
                        ),
                      ),
                      child: body,
                    );
                  }
                  return Padding(
                    padding: EdgeInsets.only(bottom: _fontSize * _paraSpacing),
                    child: GestureDetector(
                      onLongPress: () => _onParagraphLongPress(pi),
                      child: _wrapWithHighlight(pi, body),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
        // ── 页脚 ────────────────────────────────────────────
        if (showFooter) _statusFooter(fg, chapter: pageChapter),
      ],
      ),
    );
  }

  /// 下一页；已在末页则进下一章（分页模式）
  ///
  /// 翻页与翻章是同一件事的两端：用户点"下一页"到章末时，
  /// 期望自然进入下一章，而不是卡住。
  void _nextPageOrChapter() {
    if (_rs.pageMode.paginates && _pages.isNotEmpty) {
      if (_pageIndex < _pages.length - 1) {
        // 仿真 / 覆盖模式**没有挂载 PageView** ⇒ `_pageCtrl` 无 clients，
        // 直接 `nextPage()` 会因为取不到 position 抛异常 ✗ → 这类模式直接切页 ✓
        final noPager =
            _rs.pageMode == PageMode.curl ||
            _rs.pageMode == PageMode.cover ||
            !_pageCtrl.hasClients;
        if (noPager) {
          _setPageIndex(_pageIndex + 1);
        } else {
          _pageCtrl.nextPage(
            duration: _rs.pageMode == PageMode.none
                ? Duration.zero
                : const Duration(milliseconds: 260),
            curve: Curves.easeOut,
          );
        }
        return;
      }
    }
    _go(1);
  }

  /// 上一页；已在首页则回上一章
  void _prevPageOrChapter() {
    if (_rs.pageMode.paginates && _pages.isNotEmpty) {
      if (_pageIndex > 0) {
        // 同 `_nextPageOrChapter`：仿真 / 覆盖无 PageView，直接切页 ✓
        final noPager =
            _rs.pageMode == PageMode.curl ||
            _rs.pageMode == PageMode.cover ||
            !_pageCtrl.hasClients;
        if (noPager) {
          _setPageIndex(_pageIndex - 1);
        } else {
          _pageCtrl.previousPage(
            duration: _rs.pageMode == PageMode.none
                ? Duration.zero
                : const Duration(milliseconds: 260),
            curve: Curves.easeOut,
          );
        }
        return;
      }
    }
    _go(-1);
  }

  /// 段落文本 → 段落下标（书签按段落存，分页后要能找回来）
  int _paragraphIndexOf(ParagraphBlock b) {
    final i = _paragraphs.indexOf(b.text);
    return i < 0 ? 0 : i;
  }

  TextStyle _statusStyle(Color fg) => TextStyle(
    // 用户 2026-10-21：信息栏字号可调（设置面板「信息栏字号」）
    fontSize: AppTheme.fontCaption * _rs.statusTextScale,
    color: fg.withValues(alpha: 0.5),
  );

  Widget _statusText(String s, Color fg) => Padding(
    padding: const EdgeInsets.only(right: 10),
    child: Text(s, style: _statusStyle(fg)),
  );

  /// 电量（截图信息栏里有「电量」项）。
  ///
  /// ⚠️ 我第一版写的是 `MethodChannel('dsh/battery')` —— **那个 channel
  /// 原生端根本不存在**，所以永远拿不到值、恒显示 `--%`。
  /// 现在走 `tts_engine`（同一个原生文件里加的 `battery` 方法）——
  /// 理由同 TtsService 的注释：新增 Swift 文件要改 pbxproj，风险太高，
  /// 而一个 channel 支持任意多方法名。
  ///
  /// 2026-10-21 用户要求：电量**用手机状态栏那种电池图形**（不再只是裸数字）。
  /// 电池图标与百分比都跟随「信息栏字号」缩放 ✓。
  Widget _batteryText(Color fg) {
    return FutureBuilder<int?>(
      future: _tts.batteryLevel(),
      builder: (c, snap) {
        final lv = snap.data;
        final s = _rs.statusTextScale;
        final color = fg.withValues(alpha: 0.5);
        return Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _BatteryGlyph(
                level: lv == null ? 0 : (lv / 100).clamp(0.0, 1.0),
                color: color,
                height: 10 * s,
              ),
              SizedBox(width: 3 * s),
              Text(lv == null ? '--' : '$lv%', style: _statusStyle(fg)),
            ],
          ),
        );
      },
    );
  }

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

  void _onPtrDown(PointerDownEvent e) {
    // 自动阅读：任意触摸都停（与 Legado 一致，避免"想停下来却翻过去"）
    if (_autoReadOn) _stopAutoRead();
    _ptrs[e.pointer] = (pos: e.position, at: DateTime.now());
    if (_ptrs.length >= 2) {
      // 第二根手指落下：本序列按双指处理，取消挂起的单击翻页
      _twoFingerSeq = true;
      _tapTimer?.cancel();
      _lastTapAt = null;
      _lastTapPos = null;
    }
  }

  void _onPtrUp(PointerUpEvent e) {
    final d = _ptrs.remove(e.pointer);
    if (d == null) return;
    final dt = DateTime.now().difference(d.at).inMilliseconds;
    final dist = (e.position - d.pos).distance;
    final isTap = dt <= 400 && dist <= 22;

    // 还有别的手指按着 ⇒ 双指手势：任一指针轻点抬起即触发（只触发一次）
    if (_ptrs.isNotEmpty) {
      if (isTap && !_firedTwoFinger) {
        _firedTwoFinger = true;
        _toggleBar();
      }
      return;
    }

    final wasTwoFinger = _twoFingerSeq;
    _twoFingerSeq = false;
    _firedTwoFinger = false;
    // 双指序列收尾：不当作单击/双击
    if (wasTwoFinger) {
      _tapTimer?.cancel();
      _lastTapAt = null;
      _lastTapPos = null;
      return;
    }
    // 滑动 / 长按：不算点击
    if (!isTap) {
      _lastTapAt = null;
      _lastTapPos = null;
      return;
    }
    // 双击配对
    final now = DateTime.now();
    final lastAt = _lastTapAt;
    final lastPos = _lastTapPos;
    if (lastAt != null &&
        lastPos != null &&
        now.difference(lastAt).inMilliseconds <= _tapWindowMs &&
        (e.position - lastPos).distance <= 60) {
      _lastTapAt = null;
      _lastTapPos = null;
      _tapTimer?.cancel();
      _toggleBar();
      return;
    }
    _lastTapAt = now;
    _lastTapPos = e.position;
    _tapTimer?.cancel();
    _tapTimer = Timer(const Duration(milliseconds: _tapWindowMs), () {
      _lastTapAt = null;
      _lastTapPos = null;
      _handleSingleTap(e.position);
    });
  }

  void _onPtrCancel(PointerCancelEvent e) {
    _ptrs.remove(e.pointer);
    if (_ptrs.isEmpty) {
      _twoFingerSeq = false;
      _firedTwoFinger = false;
    }
  }

  /// 双击 / 双指的统一出口：开合功能面板（设置面板开着则先收设置面板）
  void _toggleBar() {
    if (!mounted) return;
    if (_showSettingsPanel) {
      _closeSettingsPanel();
      return;
    }
    setState(() => _showBar = !_showBar);
  }

  /// 单击动作（延迟 [_tapWindowMs] 后执行）：面板开着 → 收起；否则按区域翻页/翻章。
  void _handleSingleTap(Offset pos) {
    if (!mounted) return;
    final size = MediaQuery.of(context).size;
    if (size.width <= 0 || size.height <= 0) return;
    // 面板 / 顶栏打开时：点击正文空白任意位置先收起（不翻页、不误切换）
    if (_showBar || _showSettingsPanel) {
      if (_showSettingsPanel) {
        _closeSettingsPanel();
        return;
      }
      setState(() => _showBar = false);
      return;
    }
    // 漫画模式：固定 左/右 1/3 翻章；中间 1/3 单击不动（双击/双指呼出）
    //
    // 必须放在「仿真/覆盖」提前 return 之前（用户 2026-10-18）：
    //   漫画页也会沿用文字阅读的 pageMode；如果用户之前设成仿真/覆盖，
    //   下面那句 return 会把图片模式的点击全吞掉。
    if (_images.isNotEmpty) {
      final x = pos.dx;
      final w = size.width;
      final flip = _rs.flipReverse;
      if (x < w / 3) {
        if (flip) {
          _nextPageOrChapter();
        } else {
          _prevPageOrChapter();
        }
      } else if (x > w * 2 / 3) {
        if (flip) {
          _prevPageOrChapter();
        } else {
          _nextPageOrChapter();
        }
      }
      return;
    }
    // 仿真/覆盖（仅文字模式）：组件内部自绘点击稳定（无 Scrollable 竞争），
    // 交给组件处理。图片模式已在上面的分支里处理完并 return。
    if (_rs.pageMode == PageMode.curl || _rs.pageMode == PageMode.cover) {
      return;
    }
    // 文字模式：3×3 分区 + 「点击区域」配置；menu 动作由双击/双指承担
    final col = (pos.dx / (size.width / 3)).floor().clamp(0, 2);
    final row = (pos.dy / (size.height / 3)).floor().clamp(0, 2);
    final zone = row * 3 + col;
    final zones = _rs.tapZones.isEmpty
        ? ReadingSettings.defaultZones()
        : _rs.tapZones;
    var action = _rs.oneHand
        ? (zone == 4 ? TapAction.menu : TapAction.next)
        : (zones[zone] ?? TapAction.none);
    // 翻页反转：左点下一页 / 右点上一页 对调
    if (_rs.flipReverse) {
      if (action == TapAction.prev) {
        action = TapAction.next;
      } else if (action == TapAction.next) {
        action = TapAction.prev;
      }
    }
    switch (action) {
      case TapAction.prev:
        _prevPageOrChapter();
      case TapAction.next:
        _nextPageOrChapter();
      case TapAction.menu:
        // 单击中间区域直接呼出功能栏/设置面板（原来被改成 none，必须双击才出）
        _toggleBar();
      case TapAction.none:
        break;
    }
  }

  /// 顶栏日夜切换：浅色背景 ↔ 夜间背景（记住切走前的浅色索引）
  ///
  /// 若在「阅读样式」里给白天 / 夜间各绑了一套样式，切换后自动套用那一套
  /// （先切明暗，再套用 —— `_applyReaderStyle` 按当前模式取对应配色）。
  ///
  /// [manual] 为真 = 用户自己点的 ⇒ 关闭「跟随系统」（之后系统翻昼夜不再抢）；
  /// 由 [AppBrightness] 回调触发时传 false，保持跟随。
  void _toggleDayNight({bool manual = true}) {
    final toNight = _bgIndex != 5;
    setState(() {
      if (!toNight) {
        // 夜间 → 日间：优先恢复样式的日间底色，否则回到记下的浅色索引
        _bgIndex = _dayBgIndex;
        _customBgColor = _styleBgDay == null ? null : Color(_styleBgDay!);
      } else {
        // 日间 → 夜间：优先用样式的夜间底色（db 的 bgStrNight）
        _dayBgIndex = _bgIndex;
        _bgIndex = 5;
        _customBgColor = _styleBgNight == null ? null : Color(_styleBgNight!);
      }
    });
    if (manual && _followSystem) {
      _followSystem = false;
      _styleStore.saveFollowSystem(false);
    }
    // 自选图片不再在切夜间时被清掉（原来清一次就永久丢了，切回白天也回不来）；
    // 夜里照常显示，没有夜间专属壁纸时由 `_nightDim` 压暗。
    final bound = _styleById(toNight ? _nightStyleId : _dayStyleId);
    if (bound != null) {
      _applyReaderStyle(bound);
      _toast('已切换到「${bound.name}」');
    }
    // 夜间标题 HTML 的高度通常与日间不同（headingFixedHeight），
    // 不重排会让已分好的页按旧高度渲染（标题页底部被裁/留白）
    _scheduleRepaginate();
    _precachePaper();
    _scheduleSavePrefs();
  }

  /// 全局明暗（跟随系统 / 设置里的明暗开关）变化 → 阅读器跟着切。
  ///
  /// 只在「跟随系统」且偏好已恢复时生效；手动切过昼夜就不再被覆盖。
  void _onAppAppearanceChanged() {
    if (!mounted || !_prefsReady || !_followSystem) return;
    final wantNight = !AppBrightness.isLight.value;
    if (wantNight == (_bgIndex == 5)) return;
    _toggleDayNight(manual: false);
  }

  /// 按 id 找样式（内置 + 我的）
  ReaderStyle? _styleById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final s in ReaderStyle.builtins) {
      if (s.id == id) return s;
    }
    for (final s in _myStyles) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// ⚠️ 原来这里有个 `_showBrightnessSheet()`（点右侧「亮度」按钮 → 底部弹层里拖滑杆）。
  /// 用户 2026-10-14：① 要"直接就有调整条"，不要按钮中转；
  ///   ② 那个弹层的滑杆**拖不动** —— `var value = v;` 写在 `StatefulBuilder`
  ///   的 builder 里，每次 rebuild 都被重置回初值 ⇒ 拇指一拖就弹回。
  /// ⇒ 已删除，改为竖条内联滑杆 [_dockBrightness]（值存在 State 字段，不会被重置）。

  Widget _topBarCard(Color fg) {
    return Padding(
      // 悬浮卡片外观保留（四周留白 + 圆角 + 投影），但它是**布局内**的，
      // 占掉的高度由正文让出 ⇒ 永远不会压住文字 ✓
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        decoration: BoxDecoration(
          color: _bgTop.withValues(alpha: 0.97),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            _topIcon(
              Icons.arrow_back_rounded,
              '返回',
              () => Navigator.pop(context),
              fg,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.bookName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                  // 副标题是**当前章节名**（截图 IMG_8110 里就是"第一章 礼物"），
                  // 不是源名 —— 源名在详情页看，读到哪一章才是这里要回答的
                  Text(
                    widget.chapters.isEmpty
                        ? widget.source.name
                        : widget.chapters[_index].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: fg.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            // 顶栏只留：搜索 / 刷新 / 书签
            //（朗读 / 亮度 / 白夜 / 编辑 已挪到右侧竖向悬浮栏 —— 用户要求，顶栏放 8 个太挤）
            _topIcon(Icons.search_rounded, '搜索全书', _showBookSearch, fg),
            _topIcon(
              Icons.refresh_rounded,
              '刷新本章',
              () => _loadChapter(_index),
              fg,
            ),
            _topIcon(
              _bookmarks.isEmpty
                  ? Icons.bookmark_border_rounded
                  : Icons.bookmark_rounded,
              _bookmarks.isEmpty ? '加书签' : '本书已有 ${_bookmarks.length} 个书签',
              () => _showAddBookmark(0),
              fg,
            ),
            // ⚠️ 语音朗读**不放顶栏**（用户 2026-10-21 纠正）：
            //   它在右侧竖栏的最上面（`_sideDock` 第一个按钮）✓。
          ],
        ),
      ),
    );
  }

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

  void _applyDockBrightness(double dy) {
    // dy 从轨道顶端往下量；亮度是「越往上越亮」
    final t = (1 - dy / _brightnessTrackH).clamp(0.0, 1.0);
    final v = (0.1 + t * 0.9).clamp(0.1, 1.0);
    if ((v - _dockBrightnessValue).abs() < 0.005) return;
    setState(() => _dockBrightnessValue = v);
    ScreenBrightness().setScreenBrightness(v);
  }

  Widget _dockBrightness(Color fg) {
    final t = ((_dockBrightnessValue - 0.1) / 0.9).clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 实心太阳（与竖栏其它实心图标同一套）
        Icon(
          Icons.brightness_5,
          size: 16,
          color: fg.withValues(alpha: 0.85),
        ),
        const SizedBox(height: 6),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _applyDockBrightness(d.localPosition.dy),
          onVerticalDragStart: (d) => _applyDockBrightness(d.localPosition.dy),
          onVerticalDragUpdate: (d) => _applyDockBrightness(d.localPosition.dy),
          child: SizedBox(
            width: 34,
            height: _brightnessTrackH,
            child: Center(
              // ⚠️ 必须给内层固定宽度，并用 Positioned 定位填充：
              //   之前 `Align` 作为 Stack 的非定位子项会**撑满父约束**（34 宽），
              //   而轨道只有 12 宽 ⇒ 填充被居中到 34 宽里、和轨道错开 ✗
              //   （用户截图里"背景和条没重合"就是这个）。
              child: SizedBox(
                width: _brightnessTrackW,
                height: _brightnessTrackH,
                child: Stack(
                  children: [
                    // 轨道底
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: fg.withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(
                            _brightnessTrackW / 2,
                          ),
                        ),
                      ),
                    ),
                    // 已填充部分（自底向上）
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: (_brightnessTrackH * t).clamp(
                        0.0,
                        _brightnessTrackH,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: fg.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(
                            _brightnessTrackW / 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 读一次当前系统亮度做滑杆初值（读不到就按 1.0）。
  Future<void> _syncDockBrightness() async {
    try {
      final v = await ScreenBrightness().current;
      if (!mounted) return;
      // 系统"自动亮度"会返回 0 → 按 1.0 展示（与旧实现同一口径）
      setState(
        () => _dockBrightnessValue = (v < 0.05 ? 1.0 : v).clamp(0.1, 1.0),
      );
    } catch (_) {
      // 读不到就保持 1.0，不影响使用
    }
  }

  /// 悬浮顶栏/卡片里的紧凑图标按钮：统一 40×40，
  /// 避免 8 个默认 48dp 的 IconButton 把卡片挤到溢出。
  Widget _topIcon(IconData icon, String tooltip, VoidCallback onTap, Color fg) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      icon: Icon(icon, size: 20, color: fg),
      onPressed: onTap,
    );
  }

  /// 右侧竖向悬浮栏：朗读 / 亮度 / 白夜 / 编辑。
  /// 与漫画阅读器的右侧竖条同款 —— 这 4 个原来挤在顶栏里（用户要求挪出来）。
  ///
  /// ⚠️ 2026-10-21 用户要求：竖栏**不要背景**（去掉原来的白色胶囊卡片与投影），
  ///   只留图标本身悬浮在正文上 ✓。
  Widget _sideDock(Color fg) {
    // 只看"当前是不是夜间模式"（背景索引 5）。
    // 原来还要求 `_customBgColor == null` ⇒ 套了样式（自带底色）之后
    // 图标永远停在月亮、tooltip 也一直是「切换夜间」，看起来就像没切换。
    final ink = _bgIndex == 5;
    return Positioned(
      right: 12,
      top: 0,
      bottom: 0,
      child: Center(
        child: SizedBox(
          width: 46,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dockButton(
                Icons.record_voice_over,
                '朗读',
                () => _showTtsSheet(),
                fg,
              ),
              const SizedBox(height: 12),
              // 亮度：一个和圆形按钮同语言的竖胶囊（内含太阳图标 + 滑杆）
              _dockBrightness(fg),
              const SizedBox(height: 12),
              _dockButton(
                ink ? Icons.light_mode : Icons.dark_mode,
                ink ? '切换白天' : '切换夜间',
                _toggleDayNight,
                fg,
                // 用户 2026-10-21 提供的图标：夜→日 用太阳，日→夜 用月亮
                imageAsset: ink
                    ? 'assets/icons/reader/day.png'
                    : 'assets/icons/reader/night.png',
              ),
              const SizedBox(height: 12),
              // 对齐 Cmbok：书源书籍的阅读器「编辑」= 编辑该书源
              // （划线与笔记入口在底部宫格「笔记」里，不冲突）
              // 图标用齿轮（用户 2026-10-21 指定）✓
              _dockButton(Icons.settings, '书源编辑', () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => BookSourceEditorPage(source: widget.source),
                  ),
                );
              }, fg),
              // ⚠️ 番茄钟**不在这里**了：它已经回到底部宫格第一格
              //    （用户 2026-10-14：宫格那格本来就是番茄钟，右侧竖条不再重复放）。
            ],
            ),
          ),
        ),
      ),
    );
  }

  /// 竖条里的圆形按钮。
  ///
  /// [imageAsset]：用图片代替 Material 图标（竖栏的日夜切换按钮，
  /// 用户 2026-10-21 提供素材）。图片加载失败时自动回落到 [icon]。
  Widget _dockButton(
    IconData icon,
    String tooltip,
    VoidCallback onTap,
    Color fg, {
    String? imageAsset,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            // 参考图：**实心浅灰圆底 + 实心图标**（去掉了描边）
            color: fg.withValues(alpha: 0.10),
            shape: BoxShape.circle,
          ),
          child: imageAsset == null
              ? Icon(icon, size: 19, color: fg.withValues(alpha: 0.95))
              : Padding(
                  padding: const EdgeInsets.all(6),
                  child: ClipOval(
                    child: Image.asset(
                      imageAsset,
                      width: 26,
                      height: 26,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          Icon(icon, size: 19, color: fg.withValues(alpha: 0.95)),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  /// 听书迷你控制栏（参考图 IMG_8506）：
  /// `第一章旧土·8/71句` + ◀◀ ▶/⏯ ■ ▶▶ + 1× 倍速 + 更多(朗读面板) + 全屏听书
  Widget _ttsMiniBar(Color fg) {
    return Obx(() {
      final speaking = _tts.isSpeaking.value;
      final paused = _tts.isPaused.value;
      if (!speaking && !paused) return const SizedBox.shrink();
      // 已收成光碟：迷你条隐藏（光碟在 Stack 层渲染 ✓），朗读不停 ✓
      if (_ttsDiscCollapsed) return const SizedBox.shrink();
      final i = _tts.currentIndex.value;
      final n = _ttsSegments.length;
      final rate = _tts.rate.value;
      final rateLabel = '${rate.toStringAsFixed(1).replaceAll('.0', '')}×';
      return GestureDetector(
        // 向左快滑 → 收成右下角封面光碟（Cmbok 同款 ✓）
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v < -250) {
            final size = MediaQuery.of(context).size;
            setState(() {
              _ttsDiscPos ??= Offset(size.width - 76, size.height - 210);
              _ttsDiscCollapsed = true;
            });
          }
        },
        child: Container(
          // ✅ 与底部功能栏同款的**悬浮卡片**（四周留白 + 四角圆 + 向下投影 ✓）——
          //    原来是通栏贴边（只有一条 `top` 边框分隔 ✓），与底部悬浮卡不统一 ✗。
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          decoration: BoxDecoration(
            color: _bgTop.withValues(alpha: 0.97),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.16),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.chapters[_index].name}·${i + 1}/$n句',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    color: fg.withValues(alpha: 0.7),
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '上一句',
                onPressed: () => _tts.jumpTo(i - 1),
                icon: Icon(
                  Icons.skip_previous_rounded,
                  size: 22,
                  color: fg.withValues(alpha: 0.85),
                ),
              ),
              GestureDetector(
                onTap: () {
                  if (speaking) {
                    _tts.pause();
                  } else if (paused) {
                    _tts.resume();
                  }
                },
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: fg.withValues(alpha: 0.92),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    speaking ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 20,
                    color: _bgTop,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '停止朗读',
                onPressed: () => _tts.stop(),
                icon: Icon(
                  Icons.stop_rounded,
                  size: 22,
                  color: fg.withValues(alpha: 0.85),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '下一句',
                onPressed: () => _tts.jumpTo(i + 1),
                icon: Icon(
                  Icons.skip_next_rounded,
                  size: 22,
                  color: fg.withValues(alpha: 0.85),
                ),
              ),
              // 倍速循环 0.5× / 1× / 1.5× / 2×（朗读面板可调出中间值，就近取档）
              TextButton(
                onPressed: () {
                  _tts.setRate(_nextTtsRate(_tts.rate.value));
                },
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(
                  rateLabel,
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ),
              // 更多 → 朗读面板
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '更多',
                onPressed: () => _showTtsSheet(),
                icon: Icon(
                  Icons.more_horiz_rounded,
                  size: 22,
                  color: fg.withValues(alpha: 0.85),
                ),
              ),
              // 全屏听书（参考图 IMG_8509）
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '全屏听书',
                onPressed: _openFullTtsPlayer,
                icon: Icon(
                  Icons.fullscreen_rounded,
                  size: 20,
                  color: fg.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  /// 倍速档位：当前值就近取下一档（0.5→1→1.5→2→0.5 循环）
  double _nextTtsRate(double v) {
    const rates = [0.5, 1.0, 1.5, 2.0];
    for (final r in rates) {
      if (r > v + 1e-6) return r;
    }
    return rates.first;
  }

  /// 打开独立听书全屏页（参考图 IMG_8509）
  void _openFullTtsPlayer() {
    final speaking = _tts.isSpeaking.value;
    final paused = _tts.isPaused.value;
    if (!speaking && !paused) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TtsFullPlayerPage(
          bookName: widget.bookName,
          author: widget.author,
          chapterName: widget.chapters[_index].name,
          segments: _ttsSegments,
          // ✅ 优先用**调用方传进来的**封面 ✓ —— 原来只读 `raw['coverUrl']` ✗，
          //   而那个键**从不被写入**（224 个内置 Legado 源顶层没有它 ✓；
          //   config 源的封面在 `config.search_cover_dom` 里 ✓）
          //   → 全屏听书页**永远只有占位图** ✗。
          //   保留旧 raw 键作兜底 ✓（万一某个第三方源自己填了 ✓）
          coverUrl:
              widget.coverUrl ?? widget.source.raw['coverUrl']?.toString(),
          chapterNames: [for (final c in widget.chapters) c.name],
          onSelectChapter: (ci) {
            if (ci != _index) {
              setState(() => _index = ci);
              _loadChapter(ci);
              _saveProgress();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _startTts();
              });
            }
          },
        ),
      ),
    );
  }

  /// 底部菜单（按截图 IMG_8485/8487）：
  ///   上一页 [页码 1 ─── 6] 下一页      （分页模式下是**本章页**进度）
  ///   AI / 朗读 / 图片模式 / 笔记
  ///   排版 / 设置 / 目录 / 番茄钟
  Widget _bottomNav(Color fg) {
    final bgTop = _bgTop;
    // 文字分页模式：进度条显示本章页码（IMG_8487「< 1 ●──── 6 >」）
    final pageMode =
        _rs.pageMode.paginates && _pages.isNotEmpty && _images.isEmpty;
    return Container(
      // ✅ 用户 2026-10-07：「书源的功能栏改成这种**悬浮**的」——
      //   原来：整条**贴边**（`BorderRadius.vertical(top:…)` 只有上两角是圆角，
      //         左右/下都顶到屏幕边）⇒ 看着就是"底部工具条" ✗
      //   现在：四周留白 + **四角全圆** + 向下投影 ⇒ 一张**悬浮卡片** ✓
      //   ⚠️ 用 `margin`（而不是改成 `Positioned` 覆盖）：本页这个功能栏是
      //     **常驻**的（不随 `_showBar` 一起收起），若改成覆盖式，
      //     正文最后几行会被**永久压在面板下面** ✗ —— 留白式同样有悬浮观感，
      //     又不吃正文 ✓
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      decoration: BoxDecoration(
        color: bgTop.withValues(alpha: 0.97),
        // 四角全圆（原来是 `BorderRadius.vertical(top: …)`，只有上两角）
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 20,
            // 投影朝**下**（原来朝上 `Offset(0, -4)`，因为贴边只能往上打影）
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── 进度条：分页模式 = 本章页码；否则 = 章节进度 ─────
          Row(
            children: [
              IconButton(
                onPressed: pageMode ? _prevPageOrChapter : () => _go(-1),
                icon: Icon(
                  Icons.chevron_left_rounded,
                  size: 24,
                  color: fg.withValues(alpha: 0.85),
                ),
              ),
              if (pageMode)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    '$_localPageNo',
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      color: fg.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                    activeTrackColor: fg.withValues(alpha: 0.75),
                    inactiveTrackColor: fg.withValues(alpha: 0.18),
                    thumbColor: fg.withValues(alpha: 0.85),
                  ),
                  child: pageMode
                      ? Slider(
                          // 滑块按**本章**的页范围走（拼进来的下一章不算在内），
                          // 否则会出现"第 3/12 页"的页码配 58 页的滑块。
                          value: _localPageNo.toDouble().clamp(
                            1.0,
                            _localPageCount.toDouble(),
                          ),
                          min: 1,
                          max: _localPageCount.toDouble(),
                          onChanged: (v) {
                            final (start, _) = _chapterPageRange(_index);
                            final i = start + v.round() - 1;
                            if (i != _pageIndex) {
                              if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(i);
                            }
                          },
                        )
                      : Slider(
                          value: (_index + 1).toDouble().clamp(
                            1.0,
                            widget.chapters.length.toDouble(),
                          ),
                          min: 1,
                          max: widget.chapters.length.toDouble().clamp(
                            1.0,
                            1e9,
                          ),
                          onChanged: (v) {
                            final i = v.round() - 1;
                            if (i != _index) _jumpTo(i);
                          },
                        ),
                ),
              ),
              if (pageMode)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    '$_localPageCount',
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      color: fg.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              IconButton(
                onPressed: pageMode ? _nextPageOrChapter : () => _go(1),
                icon: Icon(
                  Icons.chevron_right_rounded,
                  size: 24,
                  color: fg.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          // ── 8 宫格（Cmbok 截图第一行：番茄钟 / 朗读 / AI / 图片模式）──
          // ✅ 用户 2026-10-14：这一格原来是「夜间模式」，而**右侧竖条已经有**
          //    白夜切换了（重复）⇒ 换成「番茄钟」（它原来在右侧竖条里，
          //    挪回这里，右侧竖条不再重复放）。
          Row(
            children: [
              _navItem(
                Icons.timer_outlined,
                '番茄钟',
                () => setState(() => _showPomodoro = !_showPomodoro),
                fg,
              ),
              _navItem(
                Icons.record_voice_over_outlined,
                '朗读',
                // ✅ **接上「点朗读进播放页」** ✓（本页 TTS 面板里的那个开关 ✓）：
                //   · 开启 → 先 `_startTts()` ✓（沉浸式页要在"念着"的状态才有内容 ✓），
                //     再 push `TtsFullPlayerPage` ✓ —— 参数与本页既有的那处用法**完全一致** ✓
                //     （`:1810-1832` ✓），所以**不新增任何朗读逻辑** ✓，只是把入口改成直达 ✓。
                //   · 关闭 → 仍是原来的「弹朗读设置面板」✓（`_showTtsSheet()` ✓）—— **向后兼容** ✓。
                //   ⚠️ 唯一代价 ✓：这段 push 与 `:1808` 那处**参数重复** ✗
                //     （那处在一个"从播放条进入"的方法里 ✓，我暂不抽公共方法 ✗，
                //      避免为了去重而改动那条**已经在用**的路径 ⛔ —— 稳定优先 ✓）。
                _ttsDirectPlayer
                    ? () {
                        _startTts();
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => TtsFullPlayerPage(
                              bookName: widget.bookName,
                              author: widget.author,
                              chapterName: widget.chapters[_index].name,
                              segments: _ttsSegments,
                              coverUrl:
                                  widget.coverUrl ??
                                  widget.source.raw['coverUrl']?.toString(),
                              chapterNames: [
                                for (final c in widget.chapters) c.name,
                              ],
                              onSelectChapter: (ci) {
                                if (ci != _index) {
                                  setState(() => _index = ci);
                                  _loadChapter(ci);
                                  _saveProgress();
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    if (mounted) _startTts();
                                  });
                                }
                              },
                            ),
                          ),
                        );
                      }
                    : () => _showTtsSheet(),
                fg,
              ),
              _navItem(Icons.auto_awesome_rounded, 'AI', _showAiSummary, fg),
              _navItem(Icons.image_outlined, '图片模式', _showImageMode, fg),
            ],
          ),
          const SizedBox(height: 8),
          // ── 第二行（Cmbok 截图第二行：笔记 / 排版 / 设置 / 目录）──
          Row(
            children: [
              _navItem(
                Icons.edit_note_rounded,
                '笔记',
                () => _showToc(initialTab: 2),
                fg,
              ),
              _navItem(Icons.text_fields_rounded, '排版', _showLayoutSheet, fg),
              _navItem(
                Icons.settings_outlined,
                '设置',
                () => setState(() => _showSettingsPanel = true),
                fg,
              ),
              _navItem(Icons.menu_book_rounded, '目录', _showToc, fg),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  /// 宫格里的一个项（图标 + 文字）
  Widget _navItem(IconData icon, String label, VoidCallback onTap, Color fg) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: fg.withValues(alpha: 0.88)),
              const SizedBox(height: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  color: fg.withValues(alpha: 0.88),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 数值字重（300~900）转 Flutter 的 FontWeight。
  ///
  /// 截图里「字重」是个 400 这样的数字，而 FontWeight 只有
  /// w100~w900 九个枚举 —— 所以要就近映射。
  FontWeight _fontWeightToW(double v) {
    final i = ((v / 100).round() * 100).clamp(100, 900);
    return FontWeight.values[(i ~/ 100) - 1];
  }

  /// ✅ **越界安全的页号**（blocker 修复 ✓）—— 渲染层读 `_pages[_pageIndex]` 前
  /// 必须过这里 ✓。
  ///
  /// 背景：`_paginate()` 会在循环里把 `_pages` 换成"只排了第一批"的**短列表** ✗，
  /// 而 `_pageIndex` 在此期间仍是上一次的值 ✓ → 直接取页就是
  /// `RangeError: Invalid value: Not in inclusive range 0..N` ✗。
  /// 这里夹到合法范围并**记一条日志** ✓，**绝不 throw** ✓。
  int _safePageIndex() {
    final i = _pageIndex;
    final cl = clampPageIndexToPages(i, _pages.length);
    if (cl != i) {
      // 记一条日志（禁止 throw ✓）—— 越界说明分页列表被换短了 ✓
      debugPrint(
        '[BsrReader] _pageIndex 越界夹取: $i -> $cl (共 ${_pages.length} 页)',
      );
    }
    return cl;
  }

  /// **当前页的锚点**（重排定位用 ✓）：本页第一个 entry 的「块下标 + 块内字符偏移」✓。
  /// 返回 `null` 表示拿不到锚点（不需要恢复位置 ✓）。
  (int, int)? _currentPageAnchor() {
    if (_pages.isEmpty) return null;
    final p = _pages[_safePageIndex()];
    if (p.entries.isEmpty) return null;
    final e = p.entries.first;
    return (e.blockIndex >= 0 ? e.blockIndex : p.firstBlockIndex, 0);
  }

  /// 按锚点在**新**分页里找回页号 ✓ —— 找不到就退回 0 ✓。
  /// ⚠️ `PageEntry.blockIndex` 为 -1 表示"分页器没填"（见 `book_paginator.dart:84-100` ✓），
  ///   那种 entry **不能用 `firstBlockIndex` 兜底去比对** ✗ —— 会误命中上一页 ✓；
  ///   先只认**精确**的 entry ✓，全都没有才退回 `firstBlockIndex` 比对 ✓。
  int _pageIndexForAnchor((int, int) a, List<BookPage> pages) {
    for (var i = 0; i < pages.length; i++) {
      for (final e in pages[i].entries) {
        if (e.blockIndex == a.$1) return i;
      }
    }
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].firstBlockIndex == a.$1) return i;
    }
    return 0;
  }

  /// 当前是否走「内容级无缝翻页」：把下一章的页直接拼到 `_pages` 末尾。
  ///
  /// **所有分页模式**（左右 / 无动画 / 仿真 / 覆盖 / 双页横屏）都开启：
  /// 拼进来之后 `canNext` 依然成立，翻页组件的"翻不过去"就自然失效了。
  /// 上下滚动模式不分页，走另一套（[_scrollChapters] 连排多章）。
  bool get _seamlessPaging => _rs.pageMode.paginates;

  /// 某章在 `_pages` 里的页范围 `[start, end)`（无缝拼接后一章可能有多段）。
  /// 找不到时返回整段（退化成旧行为）。
  (int, int) _chapterPageRange(int chapter) {
    var start = -1;
    var end = -1;
    for (var i = 0; i < _pageChapterOf.length; i++) {
      if (_pageChapterOf[i] != chapter) continue;
      if (start < 0) start = i;
      end = i + 1;
    }
    if (start < 0) return (0, _pages.length);
    return (start, end);
  }

  /// 当前**章内**页码（1 起）与本章总页数 —— 页眉页码、进度、滑块都用它，
  /// 这样拼了下一章之后也不会显示成 "12/58"（58 里含下一章的页）。
  int get _localPageNo {
    final (start, end) = _chapterPageRange(_index);
    final n = _pageIndex - start + 1;
    return n.clamp(1, (end - start).clamp(1, 1 << 30));
  }

  int get _localPageCount {
    final (start, end) = _chapterPageRange(_index);
    return (end - start).clamp(1, 1 << 30);
  }

  // ── 标题样式（章标题版式）──────────────────────────────────

  /// 当前标题样式的 HTML 源（默认样式 = 空串；自定义 = 用户粘贴的那份）
  ///
  /// 夜间且有夜间专属 HTML（db 的 `titleStyleHtmlNight`）时用夜间那份：
  /// 白天的深色标题在深底上几乎看不见。
  String get _chapterTitleSource {
    if (_chapterTitleStyle == ReaderTitleStyle.custom) {
      if (_bgIndex == 5 && _chapterTitleHtmlNight.trim().isNotEmpty) {
        return _chapterTitleHtmlNight;
      }
      return _chapterTitleHtml;
    }
    // 内置模板也有夜版（颜色写死的模板必须换一套，否则深底深字）
    final t = _chapterTitleStyle;
    if (_bgIndex == 5 && t.nightHtml.isNotEmpty) return t.nightHtml;
    return t.html;
  }

  /// 编译某一章的标题文档（章节数 / 章节名已代入）；空模板返回 null
  TitleHtmlDoc? _titleDoc(int chapter) {
    final src = _chapterTitleSource;
    if (src.trim().isEmpty) return null;
    if (chapter < 0 || chapter >= widget.chapters.length) return null;
    final doc = TitleHtml.compile(
      src,
      // 章号按"全书第几章"传真实值（1 起）。
      // 原来传空串是为了消掉某些样式里孤立的「1、2」，但那会让「第{n}章」
      // 这类版式整块消失（参考图里左上角是有的）。现在传真值：
      // 样式写了「第…章」就正常显示，只写占位符的也至少是"第几章"而不是空。
      chapterNumber: '${chapter + 1}',
      chapterName: widget.chapters[chapter].name,
    );
    return doc.isEmpty ? null : doc;
  }

  /// 章标题块的固定高度（null = 用默认标题，按文本度量）。
  ///
  /// 用解析器的**离线度量**（TextPainter + 同一套样式/宽度）⇒ 分页与渲染一致。
  double? _titleHeightFor(int chapter) {
    final doc = _titleDoc(chapter);
    if (doc == null) return null;
    // 双页模式下每页只有半屏宽 ⇒ 度量也必须用半宽（原来用全宽，
    // 标题在并排页里会多折行、高度被低估，底部被 ClipRect 裁掉）
    final pageW = _dualPageActive ? _viewport.width / 2 : _viewport.width;
    final width = (pageW - _padLeft - _padRight)
        .clamp(1.0, pageW)
        .toDouble();
    final h = TitleHtml.measure(
      doc,
      width: width,
      // em 的基准 = 标题字号 × 自动屏宽系数 × 手动缩放（见 _titleHtmlBase）
      baseFontSize: _titleHtmlBase,
      textScaler: MediaQuery.textScalerOf(context),
      fontFamily: _fontFamily,
      pxScale: _titlePxScale,
    );
    // 标题再大也不能吃掉半页（否则正文没地方放；分页器会把它挤到下一页）
    return (h + _titleGap).clamp(0.0, _textAreaHeight * 0.55);
  }

  /// 渲染某一章的标题。
  ///
  /// [height] 传分页时预留的高度（[_titleHeightFor]）：正常情况下两者相等；
  /// 极端情况下（标题被 55% 上限截断）用 ClipRect 裁掉溢出，绝不撑破这一页。
  Widget _titleWidget(
    int chapter, {
    required Color fallbackColor,
    double? height,
  }) {
    final doc = _titleDoc(chapter);
    if (doc == null) return const SizedBox.shrink();
    final child = TitleHtml.build(
      doc,
      baseFontSize: _titleHtmlBase,
      fallbackColor: fallbackColor,
      fontFamily: _fontFamily,
      pxScale: _titlePxScale,
    );
    final h = height ?? _titleHeightFor(chapter);
    if (h == null) return child;
    return SizedBox(
      height: h,
      child: ClipRect(
        child: OverflowBox(
          // 「标题对齐」对 HTML 标题样式也生效：OverflowBox 自身撑满页宽，
          // 用 alignment 把真实宽度的标题推到左 / 居中（不破坏内部 CSS 版式）。
          // minWidth: 0 让内容按自身宽度收缩，否则 Column 被紧约束撑满、
          // alignment 不起作用。
          alignment: _titleAlign == 1
              ? Alignment.topCenter
              : Alignment.topLeft,
          minWidth: 0,
          maxHeight: double.infinity,
          child: child,
        ),
      ),
    );
  }

  /// 分页用的排版参数（`_paginate` 与「拼下一章」共用，避免两处漂移）。
  /// [chapter] 用于量出**这一章**的标题高度（标题里有章节名，换行行数可能不同）。
  BookTypography _layoutTypography([int? chapter]) {
    return BookTypography(
      fontSize: _fontSize,
      lineHeight: _lineHeight,
      padding: (_padLeft + _padRight) / 2,
      verticalPadding: _padTop,
      // 上下边距分开（db 的 paddingTop / paddingBottom）：原来只传上边距、
      // 分页器扣 `*2`，导致 paddingBottom 永远不生效
      verticalPaddingBottom: _padBottom,
      fontFamily: _fontFamily,
      inheritedStyle: TextStyle(
        letterSpacing: _letterSpacing,
        fontWeight: _fontWeightToW(_fontWeight),
      ),
      // 章标题在渲染端是「正文 +3 / 行高 1.5」，与分页器默认公式（+12）不同；
      // 配了样式的 db titleSize / titleBold 就以样式为准（两边必须同参）
      headingFontSizeOverride: _defaultTitleFontSize,
      headingFontWeight: _titleBold ? FontWeight.w700 : FontWeight.w400,
      headingHeightOverride: 1.5,
      paragraphSpacingFactor: _paraSpacing,
      textScaler: MediaQuery.textScalerOf(context),
      // 自定义标题样式是复合版式 ⇒ 用固定高度，度量与渲染一致
      headingFixedHeight: _titleHeightFor(chapter ?? _index),
      // 默认标题走文本度量 ⇒ 把「标题间距」也计入（与渲染端 Padding 同参）
      headingExtraBottom: _titleGap,
    );
  }

  /// 某章的 blocks：章标题（可选）+ 正文段落（含首行缩进）。
  ///
  /// · 「隐藏重复标题」打开时**连标题块都不生成**（`_blockOffset == 0`）：
  ///   否则度量按标题算（约 30px 字号 + 行高 ≈ 65px）、渲染却被
  ///   `SizedBox.shrink()` 吃掉 ⇒ 每章第一页顶上凭空空一大块；
  /// · 首行缩进**一并交给分页度量**（渲染侧不再重复加），否则渲染比量出来
  ///   多占宽、多折行 ⇒ 页面底部溢出被裁。
  List<BookBlock> _blocksForChapter(int chapter, List<String> paras) {
    return <BookBlock>[
      if (_blockOffset == 1) BookBlock.heading(widget.chapters[chapter].name, 1),
      ...paras.map(
        (p) => BookBlock.paragraph(
          _indent > 0 ? '\u3000' * _indent.round() + p : p,
        ),
      ),
    ];
  }

  /// 实际可排文字的高度（扣掉页眉 + 页脚）
  double get _textAreaHeight =>
      (_viewport.height - _headerFooterHeight()).clamp(1.0, _viewport.height);

  /// 把**下一章**的页拼到 `_pages` 末尾（内容级无缝）。
  ///
  /// 时机：本章分页完成后；以及翻页接近已拼区域末尾时（链式补）。
  /// 只拼**已缓存**的章节 —— 没预取到就不拼，用户滑到章末仍可点/按钮进下一章。
  Future<void> _appendNextChapter(int gen, int cur) async {
    if (!_seamlessPaging) return;
    final next = cur + 1;
    if (next >= widget.chapters.length) return;
    if (_appendedChapter == next) return;
    // 已经在排同一章 → 不重复开一份（分页跨多帧，翻页期间会被反复触发）
    if (_appendingChapter == next) return;
    if (_pages.length >= _kSeamlessPageCap) return;
    final paras = _cache[next];
    if (paras == null || paras.isEmpty) {
      // 下一章还没缓存（网络慢 / 关了预取）→ 主动补抓一次；
      // 抓回来后会走 `_loadChapter` 里的 `_maybeAppendAhead()` 自动补拼。
      _requestAppendFetch(next);
      return;
    }
    // 视口还没量出来（首帧）→ 拼出来的页高不对，等下次翻页再补
    if (_viewport.width <= 0 || _viewport.height <= 0) return;

    _appendingChapter = next;
    try {
      final BookPaginator pg;
      try {
        pg = BookPaginator(
          blocks: _blocksForChapter(next, paras),
          viewportWidth: _viewport.width,
          viewportHeight: _textAreaHeight,
          typo: _layoutTypography(next),
          chapterStarts: const {0},
          bubbleInnerWidth:
              _rs.bubbleMode == BubbleMode.none ? 0 : _bubbleTextWidth,
          bubbleExtraV: _bubbleExtraV,
        );
      } catch (_) {
        return; // 度量失败就放弃拼接（不影响本章阅读）
      }
      final out = <BookPage>[];
      while (!pg.finished) {
        pg.stepInto(out, chunk: 60);
        if (!mounted || gen != _paginateGen) return; // 期间换章/重排 → 丢弃
        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted || gen != _paginateGen || out.isEmpty) return;
      // 双页横屏：新章最好从**左侧单页**开始。spread 是 [0], (1,2), (3,4)…
      // ⇒ 只有奇数下标是"左页"；当前页数为偶数时补一张空白页对齐。
      final pad = (_dualPageActive && _pages.length.isEven) ? 1 : 0;
      setState(() {
        _pages = [
          ..._pages,
          if (pad == 1) const BookPage(firstBlockIndex: -1, entries: []),
          ...out,
        ];
        _pageChapterOf = [
          ..._pageChapterOf,
          if (pad == 1) cur,
          ...List<int>.filled(out.length, next),
        ];
        _appendedChapter = next;
      });
    } finally {
      if (_appendingChapter == next) _appendingChapter = -1;
    }
  }

  /// 翻页时检查：快到已拼区域末尾就继续拼下一章（保证连读不断档）。
  void _maybeAppendAhead() {
    if (!_seamlessPaging) return;
    if (_pages.isEmpty) return;
    if (_pages.length - _pageIndex > 12) return; // 还有得翻，不用提前拼
    // 基准章：已经拼过就用拼到的那一章，没拼过（下一章当时还没预取到）就用本章
    // —— 这样预取晚到也能在下次翻页时补上拼接，不会一直停在"没拼"状态。
    final base = _appendedChapter >= 0 ? _appendedChapter : _pagesChapter;
    if (base < 0) return;
    _appendNextChapter(_paginateGen, base);
  }

  /// 是不是已经翻到"最后一张可显示的页 / spread"
  bool get _atLastDisplayedPage {
    if (_pages.isEmpty) return true;
    if (!_dualPageActive) return _pageIndex >= _pages.length - 1;
    // 双页 spread：[0], (1,2), (3,4)… ⇒ 末页若是偶数下标，它属于 (L-1, L)
    final l = _pages.length - 1;
    final lastSpreadFirst = l == 0 ? 0 : (l.isEven ? l - 1 : l);
    return _pageIndex >= lastSpreadFirst;
  }

  /// PageView 越界滑动的兜底：无缝拼接接不上时，章末再滑一次就进下一章。
  ///
  /// 接不上的情况有三种：
  ///   · 下一章还没预取到（网络慢 / 用户把「预取章节数」设成 0）；
  ///   · `_pages` 已经到无缝拼接的页数上限；
  ///   · 这本书就剩这一章了（此时 `_go` 会提示"已经是最后一章"）。
  bool _onPageScrollNotification(ScrollNotification n) {
    if (n is! OverscrollNotification) return false;
    if (n.depth != 0) return false; // 只认 PageView 自身的越界
    if (!_rs.pageMode.paginates) return false;
    if (n.overscroll > 4 && _atLastDisplayedPage) {
      _edgeTurn(1);
    } else if (n.overscroll < -4 && _pageIndex <= 0) {
      _edgeTurn(-1);
    }
    return false;
  }

  void _edgeTurn(int delta) {
    final now = DateTime.now();
    final last = _lastEdgeTurnAt;
    if (last != null && now.difference(last) < const Duration(milliseconds: 700)) {
      return;
    }
    _lastEdgeTurnAt = now;
    _go(delta);
  }

  /// 双页横屏是否生效（页码 / 切片 / spread 语义与单页不同）
  bool get _dualPageActive =>
      _rs.dualPage &&
      MediaQuery.of(context).orientation == Orientation.landscape;

  /// 仿真 / 覆盖 / 无 PageView 的"翻一页"入口：统一走这里。
  ///
  /// 无缝拼接后 `_pages[i]` 可能已经属于**下一章** ⇒ 页号一变就必须
  /// 同步章节（书签 / TTS / 进度跟着走），并检查要不要继续拼下一章。
  void _setPageIndex(int i) {
    if (i < 0 || i >= _pages.length) return;
    setState(() => _pageIndex = i);
    _syncChapterWithPage(i);
    _maybeAppendAhead();
  }

  /// 无缝连读要"下一章"但还没缓存 → 补抓一次。
  /// 同一章 10 秒内只抓一次，避免每次翻页都重复请求。
  void _requestAppendFetch(int chapter) {
    if (chapter < 0 || chapter >= widget.chapters.length) return;
    if (_cache.containsKey(chapter)) return;
    final now = DateTime.now();
    final last = _appendFetchAt;
    if (_appendFetchChapter == chapter &&
        last != null &&
        now.difference(last) < const Duration(seconds: 10)) {
      return;
    }
    _appendFetchChapter = chapter;
    _appendFetchAt = now;
    _loadChapter(chapter, prefetchOnly: true);
  }

  // ── 上下滚动模式的无缝连读 ─────────────────────────────────

  /// 换章 / 目录跳转：滚动章链回到"只有这一章"（滚动视图随之重建、回到章首）
  void _resetScrollChain(int chapter) {
    _scrollChapters = [chapter];
    _scrollKeys.clear();
    _scrollConv.clear();
    _scrollEpoch++;
  }

  /// 当前滚动视图里实际渲染的章链。
  ///
  /// 换过章 / 从目录跳转后 `_scrollChapters` 可能是旧的 ⇒ 只认**包含当前章**的
  /// 那一份，否则退回"只渲染本章"（等价于旧行为）。
  List<int> get _scrollChain {
    if (_scrollChapters.isNotEmpty && _scrollChapters.contains(_index)) {
      return _scrollChapters;
    }
    return <int>[_index];
  }

  /// 滚到接近底部时，把**下一章**的正文接在同一个滚动视图后面。
  ///
  /// 滚动模式没有"页"，所以这里拼的是"章节段落"而不是 `BookPage`。
  /// 章链上限 12 章：到顶时把**当前章之前**的部分剪掉（见 [_trimScrollChainBefore]）
  /// 再继续拼 —— 这样连读可以一直往下，内存也不会无限涨。
  void _maybeAppendScrollAhead() {
    if (_rs.pageMode != PageMode.scroll) return;
    final chain = _scrollChain;
    final next = chain.last + 1;
    if (next >= widget.chapters.length) return;
    if (chain.contains(next)) return;
    final paras = _cache[next];
    if (paras == null || paras.isEmpty) {
      _requestAppendFetch(next);
      return;
    }
    if (chain.length >= 12) {
      // 同一帧里"删 + 加"容易让滚动位置算错 ⇒ 先剪，下一次滚动通知再拼
      _trimScrollChainBefore();
      return;
    }
    setState(() => _scrollChapters = [...chain, next]);
  }

  /// 章链太长：把当前章**之前**的章节从视图里剪掉。
  ///
  /// 剪掉的内容都在视口上方 ⇒ 直接删会让可见内容整体上移（跳一下）。
  /// 所以先量出被剪章节的总高度，重建后把滚动偏移减去同样的高度 ——
  /// 视觉上完全不动。
  void _trimScrollChainBefore() {
    final chain = _scrollChain;
    if (chain.length < 6) return;
    final idx = chain.indexOf(_index);
    if (idx <= 0) return; // 当前章就是链首 → 没得剪（交给翻章按钮）
    var removed = 0.0;
    for (var k = 0; k < idx; k++) {
      final box = _scrollKeys[chain[k]]?.currentContext?.findRenderObject();
      if (box is RenderBox) removed += box.size.height;
    }
    final offset = _scrollReadCtrl.hasClients ? _scrollReadCtrl.offset : null;
    final removedChapters = chain.sublist(0, idx);
    setState(() {
      _scrollChapters = chain.sublist(idx);
      for (final ch in removedChapters) {
        _scrollKeys.remove(ch);
        _scrollConv.remove(ch);
      }
    });
    if (offset == null) return;
    final target = offset - removed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollReadCtrl.hasClients) return;
      final max = _scrollReadCtrl.position.maxScrollExtent;
      _scrollReadCtrl.jumpTo(target.clamp(0.0, max).toDouble());
    });
  }

  /// 滚动视图的通知：快到底就续排下一章；停手时同步"当前章"。
  bool _onScrollNotification(ScrollNotification n) {
    if (n.depth != 0) return false;
    final nearBottom = n.metrics.extentAfter < 900;
    final ended = n is ScrollEndNotification;
    if (!nearBottom && !ended) return false;
    // 通知可能来自布局阶段 ⇒ 统一推到帧后执行（setState 时机才安全）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeAppendScrollAhead();
      if (ended) _syncChapterFromScrollViewport();
    });
    return false;
  }

  /// 按"视口顶部落在哪一章"反推当前章（滚动模式下没有页号可用）
  void _syncChapterFromScrollViewport() {
    if (_rs.pageMode != PageMode.scroll) return;
    final chain = _scrollChain;
    if (chain.length <= 1) return;
    if (!_scrollReadCtrl.hasClients) return;
    final now = DateTime.now();
    final last = _scrollSyncAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 250)) {
      return;
    }
    _scrollSyncAt = now;
    final pixels = _scrollReadCtrl.position.pixels;
    int? visible;
    for (final ch in chain) {
      final box = _scrollKeys[ch]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      // 该章顶部对齐视口顶部时需要的滚动偏移
      double off;
      try {
        off = RenderAbstractViewport.of(box).getOffsetToReveal(box, 0.0).offset;
      } catch (_) {
        continue;
      }
      // 已经滚过它顶部（+48px 余量）⇒ 算"读到这一章"（取最后一个满足的）
      if (off <= pixels + 48) visible = ch;
    }
    if (visible != null && visible != _index) _syncChapterFromScroll(visible);
  }

  /// 滚动中翻到了别的章 → 把"当前章"切过去（页码 / 书签 / TTS / 进度跟着走）。
  /// **不重建滚动视图**（key 用代次，只有 `_loadChapter` 才 +1），所以位置不跳。
  void _syncChapterFromScroll(int ch) {
    if (ch == _index || ch < 0 || ch >= widget.chapters.length) return;
    final paras = _cache[ch];
    setState(() {
      _index = ch;
      _pagesChapter = ch;
      if (paras != null) _paragraphs = _applyConvert(paras);
      _chapterImages = const [];
    });
    _invalidateTtsSegs();
    unawaited(_switchBookmarksTo(ch));
    unawaited(_saveProgress());
    _prefetchAhead(ch);
    _maybeAppendScrollAhead();
  }

  /// 页号落在别的章上 → 把"当前章"切过去（无缝翻页的核心）。
  ///
  /// 只改章节状态，**不重新分页**（目标页已经在 `_pages` 里了）。
  /// 书签、TTS 分段、阅读进度都跟着章节走。
  void _syncChapterWithPage(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= _pageChapterOf.length) return;
    final ch = _pageChapterOf[pageIndex];
    if (ch == _index || ch < 0) return;
    // 正文段落也换成新章（拼进来的页自带文本，渲染不受影响；
    // 但 TTS、书签按段落定位、全书搜索都要用 `_paragraphs`，不换会读到上一章）
    final paras = _cache[ch];
    setState(() {
      _index = ch;
      _pagesChapter = ch;
      if (paras != null) _paragraphs = _applyConvert(paras);
      // 上一章的插图列表对本章无意义（图片模式面板会展示错章）
      _chapterImages = const [];
    });
    _invalidateTtsSegs();
    unawaited(_switchBookmarksTo(ch));
    unawaited(_saveProgress());
    // 走的是"无缝切章"，没经过 `_loadChapter` ⇒ 预取要在这里补一次，
    // 否则下一章永远不会被抓到缓存，拼接链断在一章之后。
    _prefetchAhead(ch);
    _maybeAppendAhead();
  }

  /// 调参重排（改字号 / 行距 / 边距 ✓）：**不换章** ✓，只是按新排版重量一遍 ✓。
  /// 与 [_paginate] 的区别：先把旧页清掉（旧页是按**旧**字号度量的 ✗，
  /// 而渲染已经用新字号 ✓ → 正文被 `NeverScrollableScrollPhysics` 的
  /// `ListView` 裁掉且滚不动 ✗），并按锚点**保留当前阅读位置** ✓。
  void _repaginateLayout() {
    if (!mounted) return;
    if (!_rs.pageMode.paginates) return; // 滚动模式本来就不分页 ✓
    // 先记锚点 ✓（`_pages` 清掉之后就取不到了 ✓），再让 `_paginate()` 复用 ✓
    final anchor = _currentPageAnchor();
    setState(() {
      _pages = const [];
      _pageChapterOf = const [];
      _appendedChapter = -1;
      _pageIndex = 0;
      _pagesChapter = -1; // 强制走"清干净"分支 ✓
    });
    _pageAnchor = anchor;
    _paginate();
  }

  /// 按当前视口与排版参数，把本章段落切成页。
  ///
  /// ── 为什么复用 BookPaginator 而不是自己写 ─────────────────────
  /// 项目里 `services/book_paginator.dart` 已经有一个**经过实测的**
  /// TextPainter 分页器（2910 行的 book_reader_page 就在用它）：
  ///   · 段落跨页按 `getLineBoundary` 断行，**不切断半行**
  ///   · 留 0.5px sub-pixel 余量 + 4px 页底安全余量，防末行被裁
  ///   · 度量与渲染共用同一个 strut / textScaler / textHeightBehavior
  ///     （否则不同设备字体度量不同，多行累积到页底会溢出）
  ///
  /// 这些坑单靠"看起来能分页"是发现不了的 —— 所以直接复用。
  Future<void> _paginate() async {
    if (_viewport.width <= 0 || _viewport.height <= 0) return;
    if (!_rs.pageMode.paginates) {
      // 上下模式是滚动的，不需要分页
      if (_pages.isNotEmpty) setState(() => _pages = const []);
      return;
    }
    // ✅ **代次号**（high 修复 ✓）：分页是后台任务 ✓（调用点均不 await ✓），
    //   每批 `await endOfFrame` 会跨很多帧 ✗ → 分页途中切章 / 旋屏会让两次
    //   分页同时跑 ✗，后结束的那个把 `_pages` 覆盖成**上一章**的页 ✗
    //   （现象：标题已是新章，正文与页数还是旧章 ✓）。
    //   每次开始都自增 ✓；`await` 回来校验 ✓，不相等立即放弃 ✓（不做任何 setState ✓）。
    final gen = ++_paginateGen;
    final chapter = _index;
    // ✅ 同章重排 → 记下当前页锚点 ✓，排完把页号找回来 ✓（位置不丢 ✓）；
    //    换章 → 页号语义完全变了 ✗ → 归零 ✓，并把 `_pages` 清干净 ✓
    //    （清不干净正是 blocker 的根因：短列表配旧页号 = 越界 ✓）。
    final sameChapter = _pagesChapter == chapter && _pages.isNotEmpty;
    final liveAnchor = sameChapter ? _currentPageAnchor() : null;
    if (sameChapter) {
      _pageAnchor ??= liveAnchor;
    } else {
      _pageAnchor = null;
    }
    setState(() {
      _paginating = true;
      if (!sameChapter) {
        _pages = const [];
        _pageChapterOf = const [];
        _appendedChapter = -1;
        _appendingChapter = -1; // 上一轮拼接作废（代次已变，它的 setState 会被丢弃）
        _pageIndex = 0;
      }
      _pagesChapter = chapter;
    });
    // 🔴 分页的"可用区域"必须与**实际渲染**一致 ✗（原来两处对不上 ✓）：
    //   · 横向：渲染侧给正文 ListView 加了 `_padLeft/_padRight`（本轮补上 ✓）
    //   · 纵向：渲染侧上 / 下还有**页眉 + 页脚**占位 ✓
    //     原来 `viewportHeight` 直接用整块高度 ✗ ⇒ 量出来的页比真正能放文本的
    //     区域高约一个页眉 + 页脚 ⇒ 每页最后一行被裁 ✗
    //   · 字距 / 字重 / 系统字号缩放：渲染端 `_bodyStyle` 带 letterSpacing，
    //     且 `Text` 自动套 MediaQuery.textScaler ✓ —— 度量不带这些 ✗ ⇒
    //     渲染比量出来更宽 ⇒ 每段多折行 ⇒ 页底被裁（"字间距怎么看都别扭"）
    //
    // ⚠️ blocks / 排版参数 / 可用高度都抽到 `_blocksForChapter` /
    //   `_layoutTypography` / `_textAreaHeight` —— 「拼下一章」必须用**同一套**，
    //   否则拼进来的页会和本章的页度量不一致（页底被裁/留白）。
    final blocks = _blocksForChapter(_index, _paragraphs);
    final typo = _layoutTypography(_index);
    final textAreaH = _textAreaHeight;
    try {
      final pg = BookPaginator(
        blocks: blocks,
        viewportWidth: _viewport.width,
        viewportHeight: textAreaH,
        typo: typo,
        chapterStarts: const {0},
        // ✅ A1 气泡：把渲染用的气泡内宽 / 内衬高度**交给分页器** ✗ ⇒
        //    对话段落按气泡宽度量、并计入内衬，渲染与度量一致 ⇒ 不再溢出屏 ✓
        //    （关闭气泡时两个参数为 0 ✓，分页行为与改动前完全相同 ✓）
        bubbleInnerWidth: _rs.bubbleMode == BubbleMode.none
            ? 0
            : _bubbleTextWidth,
        bubbleExtraV: _bubbleExtraV,
      );
      final out = <BookPage>[];
      // ✅ **今天修好的一处真·UI 冻结** ✓（原来这里**只有注释、没有实现** ✗）：
      //   旧代码是一个**同步 `while` + `chunk: 60`** 一次量到底 ✓ →
      //   **整章分页期间界面冻结** ✗✗；而上面那句注释却声称"每批让出一次
      //   事件循环、避免冻结" ✓（实测：当时本文件**没有任何** scheduleFrame /
      //   endOfFrame / Future.delayed ✓ —— 注释与实现完全不符 ✗）。
      // ✓ 现在（**两步一起做**才行 ✓，缺一不可 ✗）：
      //   ① 本方法签名 → `Future<void> _paginate() async` ✓
      //      （4 个调用点 `:497 / :559 / :790 / :4980` **无需改动** ✓ ——
      //        Dart 允许忽略返回的 Future ✓，analyze 已证明 ✓）
      //   ② 循环里每批之后 `scheduleFrame()` + `await endOfFrame` ✓，
      //      并 `setState(() => _pages = List<BookPage>.of(out))` 增量上报 ✓
      //      → 边分边显示 ✓（照 `book_reader_page.dart:757-758` 的已验证写法 ✓）
      // ⚠️ 这是**行为改动** ✓：失败路径未变（下面 `catch` 仍退回整章滚动 ✓），
      //   但"边分边看"的实际观感**需要真机确认** ✓
      // stepInto 把已完成的页**追加进传入的列表**，签名是
      // stepInto(List<BookPage> out, {int chunk = 12})
      while (!pg.finished) {
        pg.stepInto(out, chunk: 60);
        // ⚠️ 代次校验必须放在 `setState` **之前** ✓（await 回来后先校验 ✓）
        if (!mounted || gen != _paginateGen) return;
        setState(() {
          _pages = List<BookPage>.of(out);
          // 边分边显示时每页都属于本章（下一章要等全部排完再拼）
          _pageChapterOf = List<int>.filled(out.length, chapter);
          // ✅ 每批都夹一次页号（blocker 修复 ✓）：`out` 在循环里从 0 页长到 N 页 ✓，
          //    旧页号（切章前 / 上一份排版 ✓）随时可能超出当前长度 ✗ → 不夹就是 RangeError ✓
          if (_pages.isNotEmpty) _pageIndex = _safePageIndex();
        });
        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted || gen != _paginateGen) return;
      final anchor = _pageAnchor;
      setState(() {
        _pages = out;
        _pageChapterOf = List<int>.filled(out.length, chapter);
        _appendedChapter = -1;
        _pageIndex = anchor == null ? 0 : _pageIndexForAnchor(anchor, out);
        _pagesChapter = chapter;
        _paginating = false;
      });
      _pageAnchor = null;
      // 内容级无缝：本章排完就把**下一章**的页接在后面，
      // 用户滑到章末继续滑 = 直接进下一章（不用点「下一章」）。
      unawaited(_appendNextChapter(gen, chapter));
    } catch (_) {
      // 分页失败就退回整章滚动 —— 能读比"分页正确"重要
      if (mounted && gen == _paginateGen) {
        setState(() {
          _pages = const [];
          _pageChapterOf = const [];
          _appendedChapter = -1;
          _appendingChapter = -1;
          _pageIndex = 0;
          _pageAnchor = null;
          _paginating = false;
        });
      }
    }
  }

  /// 全书搜索（截图 IMG_8116）。
  ///
  /// ── 能搜到什么 ──────────────────────────────────────────────
  /// 只搜**已下载/已缓存**的章节（`_cache`）+ **章节标题**。
  /// 不搜"全书"是因为在线阅读器不会把 1455 章全拉下来 ——
  /// 那是一次几千个网络请求。截图里也说「命中后点击跳转原文」，
  /// 所以搜到就能跳。
  ///
  /// 这是**诚实的范围**：搜不到不等于书里没有，界面里写明了。
  Future<void> _showBookSearch() async {
    final ctrl = TextEditingController();
    // 结果：章下标 + 段落下标 + 命中片段
    var results = <({int ch, int para, String snippet})>[];
    var query = '';

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void run(String q) {
            query = q.trim();
            final next = <({int ch, int para, String snippet})>[];
            if (query.isNotEmpty) {
              // 章节标题命中
              for (var i = 0; i < widget.chapters.length; i++) {
                if (widget.chapters[i].name.contains(query)) {
                  next.add((ch: i, para: -1, snippet: widget.chapters[i].name));
                }
              }
              // 正文命中（仅已缓存章节）
              _cache.forEach((ci, paras) {
                for (var pi = 0; pi < paras.length; pi++) {
                  final at = paras[pi].indexOf(query);
                  if (at < 0) continue;
                  final from = (at - 20).clamp(0, paras[pi].length);
                  final to = (at + query.length + 20).clamp(
                    0,
                    paras[pi].length,
                  );
                  next.add((
                    ch: ci,
                    para: pi,
                    snippet: paras[pi].substring(from, to),
                  ));
                }
              });
            }
            setSheet(() => results = next);
          }

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Container(
              constraints: BoxConstraints(
                // 最高半屏（用户 2026-10-12）
                maxHeight: MediaQuery.of(ctx).size.height * 0.5,
              ),
              decoration: BoxDecoration(
                color: _bgTop,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(22),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 顶部：返回 + 搜索框
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () => Navigator.pop(ctx),
                            icon: Icon(
                              Icons.arrow_back_rounded,
                              size: 22,
                              color: _fg,
                            ),
                          ),
                          Expanded(
                            child: Container(
                              // ✅ **统一成 B 组规格** ✓（本次目标：阅读器内 4 个搜索框同款 ✓）
                              //   —— 原来这里是 **40 高 / 圆角 20 / `prefixIcon` 19px** ✗，
                              //   而同页「搜索书签」「搜索摘录或批注」是
                              //   **34 高 / 圆角 17 / Row 前置 Icon 16px** ✓。
                              //   ℹ️ 底色**本来就相同** ✓（都是 `_fg.withValues(alpha: 0.07)` ✓），
                              //   所以这里只改**尺寸 + 图标位置 + 字号** ✓，纯视觉 ✓、无行为变化 ✓
                              //   （`controller` / `autofocus` / `onChanged` 全不动 ✓）
                              height: 34,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              decoration: BoxDecoration(
                                color: _fg.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(17),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.search_rounded,
                                    size: 16,
                                    color: _fgMuted,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: TextField(
                                      controller: ctrl,
                                      autofocus: true,
                                      onChanged: run,
                                      style: TextStyle(
                                        fontSize: AppTheme.fontFootnote,
                                        color: _fg,
                                      ),
                                      decoration: InputDecoration(
                                        hintText: '搜索全书内容',
                                        hintStyle: TextStyle(
                                          fontSize: AppTheme.fontFootnote,
                                          color: _fgMuted,
                                        ),
                                        border: InputBorder.none,
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          query.isEmpty
                              ? '输入关键词搜索全书'
                              : '已搜 ${_cache.length} 章缓存 · 命中 ${results.length} 处',
                          style: TextStyle(
                            fontSize: AppTheme.fontFootnote,
                            color: _fgMuted,
                          ),
                        ),
                      ),
                    ),
                    Flexible(
                      child: results.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(40),
                                child: Text(
                                  query.isEmpty
                                      ? '搜索正文与章节标题，命中后点击跳转原文'
                                      : '没找到。\n\n'
                                            '只搜「已缓存的 $_cache.length 章」和章节标题 —— '
                                            '在线阅读器不会把全部 '
                                            '${widget.chapters.length} 章拉下来，'
                                            '所以搜不到不代表书里没有。',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: AppTheme.fontSubhead,
                                    height: 1.7,
                                    color: _fgMuted,
                                  ),
                                ),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: results.length,
                              itemBuilder: (c, i) {
                                final r = results[i];
                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    r.para < 0
                                        ? '章节 · ${r.snippet}'
                                        : widget.chapters[r.ch].name,
                                    style: TextStyle(
                                      fontSize: AppTheme.fontBody,
                                      color: _fg,
                                    ),
                                  ),
                                  subtitle: r.para < 0
                                      ? null
                                      : Text(
                                          '…${r.snippet}…',
                                          style: TextStyle(
                                            fontSize: AppTheme.fontFootnote,
                                            color: _fgMuted,
                                          ),
                                        ),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    if (r.ch != _index) _jumpTo(r.ch);
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 跳转到指定章（进度条拖动用）
  void _jumpTo(int i) {
    if (i < 0 || i >= widget.chapters.length) return;
    setState(() {
      _index = i;
      _loading = true;
    });
    _loadChapter(i);
  }

  /// 排版面板（按截图 IMG_8090~8095）：5 个 tab
  ///
  ///   预设 / 主题 / 文字 / 边距 / 底线
  ///   底部：取消 · 存预设 · 阅读 · 确认
  ///
  /// ⚠️ 我上一版说"段落间距/字间距/字重/边距需要渲染层改造，所以不放
  /// 假控件"——**这个判断是错的**。Flutter 的 TextStyle 原生就有
  /// `letterSpacing`（字间距）、`fontWeight`（字重）、`height`（行距），
  /// 段落间距/边距用 Padding 就行。所以这里**全部做成真能调的**。
  ///
  /// 唯一仍需渲染层改造的是「满行底线」和「页眉页脚独立排版」，
  /// 那两项在界面上明确标注。
  void _showLayoutSheet() {
    var tab = 0;
    final ctrl = TextEditingController();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void upd(VoidCallback fn) {
            setSheet(() {});
            setState(fn);
            _scheduleSavePrefs();
          }

          /// ✅ **排版类**改动（字号/字重/段间距/字间距/行距/边距/缩进 ✓）——
          ///   这些会改变正文度量 ✓，只 `upd()`（仅 setState ✓）不够 ✗：
          ///   `_pages` 仍按旧度量 ✓，新字号渲染会把正文裁掉且滚不动 ✗ →
          ///   这里额外排一次防抖重排 ✓（300ms ✓，拖滑杆不会每帧重排 ✓）。
          void updLayout(VoidCallback fn) {
            upd(fn);
            _scheduleRepaginate();
          }

          return Container(
            constraints:
                // 最高半屏（用户 2026-10-12）
                BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
            decoration: BoxDecoration(
              color: _sheetBg,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.22),
                  blurRadius: 32,
                  offset: const Offset(0, -10),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sheetHandle(),
                  // ── 标题行：排版 · 独立排版 · 存预设 / 阅读 ──────────
                  // 用户 2026-10-21：底栏（取消/存预设/阅读）去掉 ——「取消」
                  // 本来就是即时生效、点了也只是关面板，没用；
                  // 「存预设」「阅读」提到右上角，「独立排版」左移 ✓
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
                    child: Row(
                      children: [
                        Text(
                          '排版',
                          style: TextStyle(
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.w700,
                            color: _fg,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '独立排版',
                          style: TextStyle(
                            fontSize: AppTheme.fontFootnote,
                            color: _fgMuted,
                          ),
                        ),
                        const SizedBox(width: 4),
                        // ✅ 已接线（不再是假控件 ✓）：拨动即写 / 删 `BsrIndependentLayout`
                        //   的本书记录（`enable/disable(_indepKey, _layoutSnapshot())` ✓），
                        //   下次进这本书时 `_restorePrefs` 会把覆盖项读回来 ✓。
                        //   ℹ️ 排版行、朗读面板、阅读设置面板三处共用同一个 `_independent` ✓。
                        SizedBox(
                          width: 46,
                          height: 30,
                          child: FittedBox(
                            child: Switch(
                              value: _independent,
                              activeThumbColor: _bgTop,
                              activeTrackColor: _fg.withValues(alpha: 0.85),
                              inactiveThumbColor: _bgTop,
                              inactiveTrackColor: _fg.withValues(alpha: 0.16),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: (v) async {
                                setState(() => _independent = v);
                                if (v) {
                                  await BsrIndependentLayout.instance.enable(
                                    _indepKey,
                                    _layoutSnapshot(),
                                  );
                                } else {
                                  await BsrIndependentLayout.instance.disable(
                                    _indepKey,
                                  );
                                }
                                _scheduleSavePrefs();
                                if (mounted) setState(() {});
                              },
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        TextButton(
                          onPressed: () => _showSavePresetDialog(ctrl),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: _fg,
                          ),
                          child: const Text(
                            '存预设',
                            style: TextStyle(
                              fontSize: AppTheme.fontFootnote,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: _bgTop,
                            backgroundColor: _fg.withValues(alpha: 0.9),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text(
                            '阅读',
                            style: TextStyle(
                              fontSize: AppTheme.fontFootnote,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // ── 默认排版 / 自研排版（对齐参考图的分段控件）──────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: _fg.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _fg.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Row(
                        children: [
                          for (final e in const [
                            ('默认排版', false),
                            ('自研排版', true),
                          ])
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () async {
                                  await _setIndependent(e.$2);
                                  setSheet(() {});
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  curve: Curves.easeOut,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: _independent == e.$2
                                        ? _fg.withValues(alpha: 0.88)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(9),
                                  ),
                                  child: Text(
                                    e.$1,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: _independent == e.$2
                                          ? _bgTop
                                          : _fg.withValues(alpha: 0.6),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    color: _fg.withValues(alpha: 0.08),
                  ),
                  const SizedBox(height: 8),
                  // ── 5 个 tab ──────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (var i = 0; i < _layoutTabs.length; i++)
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setSheet(() => tab = i),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                curve: Curves.easeOut,
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 9,
                                ),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: tab == i
                                      ? _fg.withValues(alpha: 0.88)
                                      : _fg.withValues(alpha: 0.05),
                                  borderRadius: BorderRadius.circular(11),
                                  border: Border.all(
                                    color: tab == i
                                        ? Colors.transparent
                                        : _fg.withValues(alpha: 0.10),
                                  ),
                                ),
                                child: Text(
                                  _layoutTabs[i],
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: tab == i
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: tab == i
                                        ? _bgTop
                                        : _fg.withValues(alpha: 0.78),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  // ── tab 内容 ─────────────────────────────────
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (tab == 0) ..._layoutStyleTab(ctx, setSheet),
                          if (tab == 1) ..._layoutThemeTab(upd),
                          if (tab == 2) ..._layoutTextTab(updLayout),
                          if (tab == 3) ..._layoutMarginTab(updLayout),
                          if (tab == 4) ..._layoutUnderlineTab(upd),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static const _layoutTabs = ['样式', '主题', '文字', '边距', '底线'];

  /// 「样式」tab：内置样式 / 我的样式（点一下整套套用）+ 老的排版预设。
  ///
  /// 与「主题/文字/边距/底线」四个 tab 的分工：
  ///   · 这里是**成套**的（配色 + 排版 + 边距 + 信息栏 + 翻页一起换）；
  ///   · 那四个是**单项微调**（调完如果想留下来 → 「存当前样式」）。
  List<Widget> _layoutStyleTab(BuildContext ctx, StateSetter setSheet) {
    return [
      Row(
        children: [
          Expanded(
            child: _chip(
              '存当前样式',
              false,
              () async {
                await _saveCurrentAsStyle();
                setSheet(() {});
              },
              compact: true,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _chip(
              '导入 Legado 排版',
              false,
              () async {
                await _importStyle();
                setSheet(() {});
              },
              compact: true,
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      _sectionLabel('标题样式'),
      // 章标题版式（参考用户提供的源阅读标题样式：仙鹤日间/夜间、微信读书）
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final t in ReaderTitleStyle.values)
            _chip(
              t.label,
              _chapterTitleStyle == t,
              () {
                setState(() {
                  _chapterTitleStyle = t;
                  // 选「自定义」且还没存过 → 先用仙鹤日间当起点，方便改
                  if (t == ReaderTitleStyle.custom &&
                      _chapterTitleHtml.trim().isEmpty) {
                    _chapterTitleHtml = ReaderTitleStyle.starterTemplate;
                  }
                });
                _scheduleSavePrefs();
                // 标题高度变了 ⇒ 章首那页要重排
                _scheduleRepaginate();
                setSheet(() {});
              },
              compact: true,
            ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: _chip(
            '管理标题样式（预览 / 复制 / 编辑 HTML）',
            false,
            () async {
              await _openTitleStylesPage();
              setSheet(() {});
            },
            compact: true,
          ),
        ),
      ),
      if (_chapterTitleStyle == ReaderTitleStyle.custom)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _chip(
              '编辑 HTML',
              false,
              () async {
                await _editTitleHtml();
                setSheet(() {});
              },
              compact: true,
            ),
          ),
        ),
      if (_myTitleStyles.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Text(
            '我的标题样式（长按删除）',
            style: TextStyle(
              fontSize: AppTheme.fontFootnote,
              color: _fgMuted,
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in _myTitleStyles) _titleStyleChip(t, setSheet),
          ],
        ),
      ],
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _chip(
              '存为我的标题样式',
              false,
              () async {
                await _saveCurrentTitleStyle();
                setSheet(() {});
              },
              compact: true,
            ),
            _chip(
              '页眉页脚格式',
              false,
              () async {
                await _editHeaderFooter();
                setSheet(() {});
              },
              compact: true,
            ),
            _chip(
              '样式分享',
              false,
              () async {
                await _showStyleShare();
                setSheet(() {});
              },
              compact: true,
            ),
            _chip(
              '导入 .srs',
              false,
              () async {
                await _importSrsStyle();
                setSheet(() {});
              },
              compact: true,
            ),
          ],
        ),
      ),
      _sectionLabel('样式库'),
      Align(
        alignment: Alignment.centerLeft,
        child: _chip(
          '打开样式库（内置 ${ReaderStyle.builtins.length} · 我的 ${_myStyles.length}）',
          false,
          () async {
            await _openStylesPage();
            setSheet(() {});
          },
          compact: true,
        ),
      ),
      if (_savedPresets.isNotEmpty) ...[
        _sectionLabel('排版预设'),
        for (final name in _savedPresets)
          ListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            title: Text(
              name,
              style: TextStyle(fontSize: AppTheme.fontBody, color: _fg),
            ),
            trailing: IconButton(
              icon: Icon(Icons.delete_outline, size: 20, color: _fgMuted),
              onPressed: () => setSheet(() => _savedPresets.remove(name)),
            ),
            onTap: () => _applyPreset(name),
          ),
      ],
      const SizedBox(height: 12),
    ];
  }

  /// 一张样式卡片：小样 + 名字；当前生效的打勾。
  // ignore: unused_element
  Widget _styleCard(ReaderStyle s, StateSetter setSheet) {
    final selected = _activeStyleId == s.id;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        _applyReaderStyle(s);
        setSheet(() {});
      },
      onLongPress: s.builtin
          ? null
          : () async {
              await _showStyleActions(s);
              setSheet(() {});
            },
      child: SizedBox(
        width: 96,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                _stylePreview(s, selected: selected),
                if (selected)
                  Positioned(
                    right: 3,
                    top: 3,
                    child: Icon(
                      Icons.check_circle_rounded,
                      size: 15,
                      color: _fg,
                      shadows: const [
                        Shadow(color: Colors.white, blurRadius: 3),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTheme.fontFootnote,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? _fg : _fg.withValues(alpha: 0.72),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「我的标题样式」的一个 chip：点=套用，长按=删除
  Widget _titleStyleChip(TitleStylePreset t, StateSetter setSheet) {
    final active =
        _chapterTitleStyle == ReaderTitleStyle.custom &&
        _chapterTitleHtml.trim() == t.html.trim();
    return GestureDetector(
      onLongPress: () async {
        await _deleteTitleStyle(t);
        setSheet(() {});
      },
      child: _chip(
        t.name,
        active,
        () {
          _applyTitleStyle(t);
          setSheet(() {});
        },
        compact: true,
      ),
    );
  }

  /// 「我的样式」的一行：小缩略图 + 名字 + 关键参数；**左滑**露出「编辑 / 删除」。
  // ignore: unused_element
  Widget _myStyleRow(ReaderStyle s, StateSetter setSheet) {
    final selected = _activeStyleId == s.id;
    final titleLabel = ReaderTitleStyle.fromId(s.chapterTitleStyle).label;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _SwipeActions(
        background: _sheetBg,
        actions: [
          (
            label: '编辑',
            icon: Icons.edit_outlined,
            tint: const Color(0xFF3A7BD5),
            onTap: () async {
              await _editStyle(s);
              setSheet(() {});
            },
          ),
          (
            label: '删除',
            icon: Icons.delete_outline,
            tint: const Color(0xFFE05252),
            onTap: () async {
              await _deleteStyle(s);
              setSheet(() {});
            },
          ),
        ],
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _applyReaderStyle(s);
            setSheet(() {});
          },
          onLongPress: () async {
            await _showStyleActions(s);
            setSheet(() {});
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                _styleThumb(s, selected: selected),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w600,
                          color: selected ? _fg : _fg.withValues(alpha: 0.85),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$titleLabel · ${s.fontSize.toStringAsFixed(0)}px · ${_pageModeLabel(s.pageMode)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTheme.fontFootnote,
                          color: _fgMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle_rounded, size: 18, color: _fg),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 列表里的小缩略图（比卡片小样简单，保证 44×54 不溢出）
  Widget _styleThumb(ReaderStyle s, {bool selected = false}) {
    final night = _bgIndex == 5;
    final bgc = night ? (s.bgColorNight ?? s.bgColor) : s.bgColor;
    final bg = bgc != null
        ? Color(bgc)
        : _bgs[(night ? 5 : s.bgIndex).clamp(0, _bgs.length - 1)][0];
    final dark = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
    final fgc = night ? (s.fgColorNight ?? s.fgColor) : s.fgColor;
    final fg = fgc != null
        ? Color(fgc)
        : (dark ? const Color(0xFFE2E2E2) : const Color(0xFF1A1A1A));
    final asset = night
        ? (s.bgImageAssetNight ?? s.bgImageAsset)
        : s.bgImageAsset;
    return Container(
      width: 44,
      height: 54,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected ? _fg : _fg.withValues(alpha: 0.18),
          width: selected ? 2 : 0.8,
        ),
        image: asset == null
            ? null
            : DecorationImage(image: AssetImage(asset), fit: BoxFit.cover),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 3,
            width: 20,
            color: fg.withValues(alpha: 0.8),
          ),
          const SizedBox(height: 3),
          for (var i = 0; i < 3; i++) ...[
            Container(
              height: 2,
              width: i == 2 ? 14 : double.infinity,
              color: fg.withValues(alpha: 0.55),
            ),
            const SizedBox(height: 2),
          ],
        ],
      ),
    );
  }

  /// 翻页模式 id → 中文名
  String _pageModeLabel(String id) {
    for (final m in PageMode.values) {
      if (m.name == id) return m.label;
    }
    return '左右';
  }

  /// 样式小样：按样式自己的底色 / 壁纸 / 文字色 / 行距画一张"迷你书页"，
  /// 让用户在**点之前**就大致看出观感（不是纯色块）。
  ///
  /// 跟随阅读器当前日夜：夜间时预览样式的**夜间**配色与夜版壁纸。
  Widget _stylePreview(ReaderStyle s, {bool selected = false}) {
    final night = _bgIndex == 5;
    final bgc = night ? (s.bgColorNight ?? s.bgColor) : s.bgColor;
    final bg = bgc != null
        ? Color(bgc)
        : _bgs[(night ? 5 : s.bgIndex).clamp(0, _bgs.length - 1)][0];
    final dark = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
    final fgc = night ? (s.fgColorNight ?? s.fgColor) : s.fgColor;
    final fg = fgc != null
        ? Color(fgc)
        : (dark ? const Color(0xFFE2E2E2) : const Color(0xFF1A1A1A));
    final asset = night
        ? (s.bgImageAssetNight ?? s.bgImageAsset)
        : s.bgImageAsset;
    // 夜版壁纸本身已经压暗，不再叠遮罩
    final dimAsset = s.bgImageDark && !(night && s.bgImageAssetNight != null);
    // 迷你行距：把真实行高（相对字号）压到 2~5px，看得出松紧即可
    final gap = (s.lineHeight - 1).clamp(0.15, 1.2) * 4;
    final showHeader = s.statusItems.contains('时间') ||
        s.statusItems.contains('书名');
    final showFooter = s.statusItems.contains('页码') ||
        s.statusItems.contains('进度');
    return Container(
      width: 96,
      height: 118,
      padding: const EdgeInsets.fromLTRB(7, 6, 7, 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? _fg : _fg.withValues(alpha: 0.16),
          width: selected ? 2 : 0.8,
        ),
        image: asset == null
            ? null
            : DecorationImage(
                image: AssetImage(asset),
                fit: BoxFit.cover,
                colorFilter: dimAsset
                    ? ColorFilter.mode(
                        Colors.black.withValues(alpha: 0.45),
                        BlendMode.darken,
                      )
                    : null,
              ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeader) ...[
            Container(
              height: 2,
              width: 22,
              color: fg.withValues(alpha: 0.45),
            ),
            const SizedBox(height: 3),
          ],
          // 标题
          Container(
            height: 4,
            width: 34,
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          SizedBox(height: gap + 2),
          // 正文若干行（最后一行短，像真实段落）
          for (var i = 0; i < 5; i++) ...[
            Container(
              height: 2.6,
              width: i == 4 ? 38 : double.infinity,
              color: fg.withValues(alpha: 0.62),
            ),
            SizedBox(height: gap),
          ],
          const Spacer(),
          if (showFooter)
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                height: 2,
                width: 18,
                color: fg.withValues(alpha: 0.4),
              ),
            ),
        ],
      ),
    );
  }

  /// 长按「我的样式」：重命名 / 用当前排版覆盖 / 删除
  Future<void> _showStyleActions(ReaderStyle s) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _sheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (c) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(s.name, style: TextStyle(color: _fgMuted)),
            ),
            ListTile(
              leading: Icon(Icons.drive_file_rename_outline, color: _fg),
              title: Text('重命名', style: TextStyle(color: _fg)),
              onTap: () => Navigator.pop(c, 'rename'),
            ),
            ListTile(
              leading: Icon(Icons.save_as_outlined, color: _fg),
              title: Text('用当前排版覆盖', style: TextStyle(color: _fg)),
              onTap: () => Navigator.pop(c, 'update'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: _fg),
              title: Text('删除', style: TextStyle(color: _fg)),
              onTap: () => Navigator.pop(c, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    switch (action) {
      case 'rename':
        await _renameStyle(s);
      case 'update':
        final updated = _styleSnapshot(s.id, s.name);
        setState(() {
          _myStyles = [
            for (final e in _myStyles) e.id == s.id ? updated : e,
          ];
          _activeStyleId = s.id;
        });
        await _styleStore.saveCustom(_myStyles);
        await _styleStore.saveActiveId(s.id);
        _toast('已用当前排版覆盖「${s.name}」');
      case 'delete':
        await _deleteStyle(s);
    }
  }

  /// 「背景图」里的一张小卡片（asset = null ⇒ 「无」= 不用壁纸）。
  Widget _bgImageChip(String? asset, void Function(VoidCallback) upd) {
    final selected = _bgImageAsset == asset;
    return GestureDetector(
      onTap: () {
        upd(() {
          _bgImageAsset = asset;
          // 成对的图自动带出夜间版（古风/泼墨/皮卡）
          _bgImageAssetNight = ReaderBgAssets.pairOf(asset);
        });
        _precachePaper();
      },
      child: Container(
        width: 44,
        height: 52,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: _fg.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? _fg : _fg.withValues(alpha: 0.25),
            width: selected ? 2.5 : 1,
          ),
          image: asset == null
              ? null
              : DecorationImage(image: AssetImage(asset), fit: BoxFit.cover),
        ),
        alignment: Alignment.center,
        child: asset == null
            ? Text(
                '无',
                style: TextStyle(fontSize: AppTheme.fontCaption, color: _fg),
              )
            : null,
      ),
    );
  }

  /// 「主题」tab：背景 + 字色 + 图片（截图 IMG_8492/8499）
  List<Widget> _layoutThemeTab(void Function(VoidCallback) upd) {
    const bgNames = ['默认', '护眼', '牛皮纸', '米黄', '竹露', '夜间'];
    const fgNames = ['自动', '墨黑', '深灰', '赭棕', '靛青', '银白'];
    const fgColors = [
      null,
      Color(0xFF1A1A1A),
      Color(0xFF4A4A4A),
      Color(0xFF8B5A2B),
      Color(0xFF1F3A5F),
      Color(0xFFB0B0B0),
    ];
    return [
      _layoutLabel('背景'),
      Wrap(
        spacing: 14,
        runSpacing: 10,
        children: [
          for (var i = 0; i < _bgs.length; i++)
            GestureDetector(
              onTap: () => upd(() {
                _customBgColor = null;
                // 手选底色 ⇒ 不再跟随样式的日/夜配色
                _styleBgDay = null;
                _styleBgNight = null;
                _bgIndex = i;
              }),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: _bgs[i][0],
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _bgIndex == i && _customBgColor == null
                            ? _fg
                            : _fg.withValues(alpha: 0.25),
                        width: _bgIndex == i && _customBgColor == null
                            ? 2.5
                            : 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    bgNames[i],
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: _fg,
                    ),
                  ),
                ],
              ),
            ),
          // 自定义背景（参考图 IMG_8500）
          GestureDetector(
            onTap: () async {
              final picked = await ColorPickerDialog.show(
                context,
                initial: _bgTop,
                title: '自定义背景',
              );
              if (picked != null) upd(() => _customBgColor = picked);
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: _customBgColor ?? _bgTop,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _customBgColor != null
                          ? _fg
                          : _fg.withValues(alpha: 0.25),
                      width: _customBgColor != null ? 2.5 : 1,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '自定义',
                  style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      // ── 背景图（内置壁纸：来自 cmbok 的 14 张 ✓）────────────────
      _layoutLabel('背景图'),
      SizedBox(
        height: 56,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            _bgImageChip(null, upd),
            for (final a in _builtinBgImages) _bgImageChip(a, upd),
          ],
        ),
      ),
      const SizedBox(height: 14),
      _layoutLabel('字色'),
      Wrap(
        spacing: 14,
        runSpacing: 10,
        children: [
          for (var i = 0; i < fgNames.length; i++)
            GestureDetector(
              onTap: () => upd(() {
                _fgOverride = fgColors[i];
                // 手动选的字色是"通用色"：夜间也用它（否则夜间会被
                // 自动浅色盖掉，用户会觉得"选了没用"）
                _fgNightOverride = fgColors[i];
              }),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: fgColors[i] ?? _fg,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _fgOverride == fgColors[i]
                            ? _fg
                            : _fg.withValues(alpha: 0.25),
                        width: _fgOverride == fgColors[i] ? 2.5 : 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    fgNames[i],
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: _fg,
                    ),
                  ),
                ],
              ),
            ),
          // 自定义字色
          GestureDetector(
            onTap: () async {
              final picked = await ColorPickerDialog.show(
                context,
                initial: _fg,
                title: '自定义文字颜色',
              );
              if (picked != null)
                upd(() {
                  _fgOverride = picked;
                  _fgNightOverride = picked;
                });
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: _fgOverride ?? _fg,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _fgOverride != null
                          ? _fg
                          : _fg.withValues(alpha: 0.25),
                      width: _fgOverride != null ? 2.5 : 1,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '自定义',
                  style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      _layoutLabel('图片'),
      Row(
        children: [
          // 无：清掉内置背景（回到 _bgs 底色）
          GestureDetector(
            onTap: () => upd(() {
              _customBgColor = null;
              _styleBgDay = null;
              _styleBgNight = null;
            }),
            child: Container(
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: _customBgColor == null
                    ? _fg.withValues(alpha: 0.85)
                    : _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '无',
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: _customBgColor == null ? _bgTop : _fg,
                ),
              ),
            ),
          ),
          // 内置：16 款内置背景（参考图 IMG_8502「共16款，点击即用」）
          GestureDetector(
            onTap: () => _showBuiltinBgPanel(upd),
            child: Container(
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '内置',
                style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg),
              ),
            ),
          ),
          // 选择图片：走系统图库（ImagePicker 由系统文件选择实现）
          GestureDetector(
            onTap: () => _showImageBgPicker(upd),
            child: Container(
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '选择图片',
                style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg),
              ),
            ),
          ),
        ],
      ),
    ];
  }

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

  Future<void> _showBuiltinBgPanel(void Function(VoidCallback) upd) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          constraints:
              // 最高半屏（用户 2026-10-12）
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
          decoration: BoxDecoration(
            color: _bgTop,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '内置背景',
                    style: TextStyle(
                      fontSize: AppTheme.fontTitle3,
                      fontWeight: FontWeight.w700,
                      color: _fg,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '共16款，点击即用',
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: _fgMuted,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: GridView.builder(
                      shrinkWrap: true,
                      physics: const BouncingScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.78,
                          ),
                      itemCount: _builtinBgs.length,
                      itemBuilder: (c, i) {
                        final e = _builtinBgs[i];
                        final active = _customBgColor == e.$2;
                        return GestureDetector(
                          onTap: () {
                            setSheet(() {});
                            upd(() => _customBgColor = e.$2);
                            Navigator.pop(ctx);
                            _toast('已应用内置背景「${e.$1}」');
                          },
                          child: Column(
                            children: [
                              Expanded(
                                child: Container(
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    color: e.$2,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: active
                                          ? _fg
                                          : _fg.withValues(alpha: 0.18),
                                      width: active ? 2.5 : 1,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                e.$1,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppTheme.fontFootnote,
                                  color: _fg,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 「选择图片」：相册选图 → 复制到应用文档目录 → 设为正文背景
  ///（优先于自定义颜色与内置背景，_savePrefs 持久化路径）
  Future<void> _showImageBgPicker(void Function(VoidCallback) upd) async {
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 4096,
        maxHeight: 4096,
        imageQuality: 90,
      );
    } catch (e) {
      _toast('打开相册失败：$e');
      return;
    }
    if (picked == null) return; // 用户取消
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/reader_bg');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final dest =
          '${dir.path}/bg_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(picked.path).copy(dest);
      // 删掉旧的自定义背景图（避免文档目录堆积）
      final old = _customBgPath;
      upd(() {
        _customBgPath = dest;
        // 手动选的新图没有夜间版 ⇒ 清掉旧样式带的夜间图（否则夜里还是旧图）
        _customBgPathNight = null;
        _customBgColor = null; // 图片背景优先于颜色
        _styleBgDay = null;
        _styleBgNight = null;
      });
      // 异步分析新图明暗：深色自选图要换浅字/浅图标（_paperIsDark 用）
      unawaited(_analyzeFileBg(dest));
      if (old != null && old != dest) {
        try {
          final f = File(old);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
      _scheduleSavePrefs();
      _toast('已应用自定义背景图片');
    } catch (e) {
      _toast('保存图片失败：$e');
    }
  }

  /// 当前排版是否正好等于某个预设（用于高亮预设 chip）
  bool _isPreset(_TextPreset p) =>
      (_fontSize - p.size).abs() < 0.01 &&
      (_lineHeight - p.lineHeight).abs() < 0.01 &&
      (_letterSpacing - p.letterSpacing).abs() < 0.01 &&
      (_paraSpacing - p.paraSpacing).abs() < 0.01;

  /// 「文字」tab：字号/字重/段间距/字间距/行距/字体/标题对齐/隐藏重复标题
  List<Widget> _layoutTextTab(void Function(VoidCallback) upd) {
    return [
      // ── 一键预设：中文正文的三种"呼吸感" ────────────────────
      // 6 个滑杆各调一遍很难调到舒服的组合；给三档预设，点一下就是
      // 「字号 / 行距 / 字距 / 段距」成套的推荐值（也可当"恢复默认"用）。
      Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 8),
        child: Row(
          children: [
            Text(
              '预设',
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                color: _fgMuted,
              ),
            ),
            const SizedBox(width: 10),
            for (final p in _TextPreset.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _chip(
                  p.label,
                  _isPreset(p),
                  () {
                    upd(() {
                      _fontSize = p.size;
                      _lineHeight = p.lineHeight;
                      _letterSpacing = p.letterSpacing;
                      _paraSpacing = p.paraSpacing;
                      _fontWeight = 400;
                    });
                    _scheduleSavePrefs();
                  },
                  compact: true,
                ),
              ),
          ],
        ),
      ),
      // ── 自定义字体（导入 ttf/otf，长按删除）────────────────────
      Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(
                '字体',
                style: TextStyle(fontSize: AppTheme.fontBody, color: _fgMuted),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip(
                    '默认',
                    _fontId == null,
                    () {
                      upd(() {
                        _fontId = null;
                        _fontFamily = null;
                      });
                      _scheduleRepaginate();
                    },
                    compact: true,
                  ),
                  for (final f in ReaderFontService.instance.fonts)
                    GestureDetector(
                      onLongPress: () async {
                        await _deleteFont(f);
                        upd(() {});
                      },
                      child: _chip(
                        f.name,
                        _fontId == f.id,
                        () async {
                          final fam = await ReaderFontService.instance
                              .familyOf(f.id);
                          if (!mounted) return;
                          if (fam == null) {
                            _toast('字体加载失败（文件可能已丢失）');
                            return;
                          }
                          setState(() {
                            _fontId = f.id;
                            _fontFamily = fam;
                          });
                          _scheduleSavePrefs();
                          _scheduleRepaginate();
                          upd(() {});
                        },
                        compact: true,
                      ),
                    ),
                  _chip(
                    '导入字体',
                    false,
                    () async {
                      await _importFont();
                      upd(() {});
                    },
                    compact: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      _layoutSlider(
        '字号',
        _fontSize,
        12,
        30,
        '${_fontSize.round()}',
        (v) => upd(() => _fontSize = v),
        step: 1,
      ),
      _layoutSlider(
        '字重',
        _fontWeight,
        300,
        900,
        '${_fontWeight.round()}',
        (v) => upd(() => _fontWeight = v),
        step: 50,
      ),
      _layoutSlider(
        '段间距',
        _paraSpacing,
        0,
        3,
        '${_paraSpacing.toStringAsFixed(1)}x',
        (v) => upd(() => _paraSpacing = v),
        step: 0.1,
      ),
      _layoutSlider(
        '字间距',
        _letterSpacing,
        0,
        5,
        _letterSpacing.toStringAsFixed(1),
        (v) => upd(() => _letterSpacing = v),
        step: 0.1,
      ),
      _layoutSlider(
        '行距',
        _lineHeight,
        1.2,
        2.6,
        _lineHeight.toStringAsFixed(2),
        (v) => upd(() => _lineHeight = v),
        step: 0.05,
      ),
      const SizedBox(height: 6),
      _layoutLabel('字体'),
      Row(
        children: [
          for (final n in ['跟随模式', '系统默认'])
            Container(
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: n == '跟随模式'
                    ? _fg.withValues(alpha: 0.85)
                    : _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                n,
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: n == '跟随模式' ? _bgTop : _fg,
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      // 章标题整体缩放 + 下方留白。
      // 内置 HTML 标题样式（泼墨山水 / 仙鹤 / 古风…）的 font-size 是相对正文的
      // **固定倍数**（1.5em ~ 2.6em），换手机尺寸、调大正文字号后就"标题比正文
      // 大太多、还换行截断"。这里给两个滑杆直接调，不必去改样式源码。
      _layoutSlider(
        '标题大小',
        _titleScale,
        0.6,
        1.6,
        '${(_titleScale * 100).round()}%',
        (v) => upd(() => _titleScale = v),
        step: 0.05,
      ),
      _layoutSlider(
        '标题间距',
        _titleGap,
        0,
        40,
        '${_titleGap.round()}',
        (v) => upd(() => _titleGap = v),
        step: 2,
      ),
      const SizedBox(height: 8),
      _layoutLabel('标题对齐'),
      Row(
        children: [
          for (final n in ['靠左', '居中'])
            Container(
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              decoration: BoxDecoration(
                color: _titleAlign == (n == '靠左' ? 0 : 1)
                    ? _fg.withValues(alpha: 0.85)
                    : _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                n,
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: _titleAlign == (n == '靠左' ? 0 : 1) ? _bgTop : _fg,
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 6),
      _layoutToggleRow(
        '专注加粗',
        '长段开头加粗描述',
        _focusBold,
        (v) => upd(() => _focusBold = v),
      ),
      const SizedBox(height: 12),
      // 「标题样式 · 朴素」原本是死 UI：只有一个选项、也没有 onTap，
      // 渲染端从未读过 `_titleStyle` ⇒ 已删除。章标题版式请用上面的
      // 「章标题版式」chip（ReaderTitleStyle）或标题样式库。
      _layoutToggleRow(
        '隐藏重复标题',
        '章首正文与章名相同时不再显示一遍（默认开）',
        _hideRepeatTitle,
        // 会改变分页块结构（有无标题块）⇒ 必须重排（本 tab 传入的就是 updLayout）
        (v) => upd(() => _hideRepeatTitle = v),
      ),
      const SizedBox(height: 14),
      _layoutLabel('首行缩进'),
      _layoutSlider(
        '缩进',
        _indent,
        0,
        4,
        '${_indent.round()}',
        (v) => upd(() => _indent = v),
        step: 1,
      ),
    ];
  }

  /// 排版面板里的开关行（标题 + 说明 + Switch）
  Widget _layoutToggleRow(
    String title,
    String desc,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  fontWeight: FontWeight.w600,
                  color: _fg,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                desc,
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  color: _fgMuted,
                ),
              ),
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }

  /// 「边距」tab：内容边距 + 页眉 + 页脚（截图 IMG_8093/8094）
  List<Widget> _layoutMarginTab(void Function(VoidCallback) upd) {
    return [
      _layoutLabel('内容'),
      _layoutSlider(
        '左边距',
        _padLeft,
        0,
        60,
        '${_padLeft.round()}',
        (v) => upd(() => _padLeft = v),
        step: 1,
      ),
      _layoutSlider(
        '右边距',
        _padRight,
        0,
        60,
        '${_padRight.round()}',
        (v) => upd(() => _padRight = v),
        step: 1,
      ),
      _layoutSlider(
        '上边距',
        _padTop,
        0,
        60,
        '${_padTop.round()}',
        (v) => upd(() => _padTop = v),
        step: 1,
      ),
      _layoutSlider(
        '下边距',
        _padBottom,
        0,
        60,
        '${_padBottom.round()}',
        (v) => upd(() => _padBottom = v),
        step: 1,
      ),
      const SizedBox(height: 10),
      _layoutLabel('页眉（负值移进状态栏区域）'),
      _layoutSlider(
        '左右边距',
        _headerPadH,
        0,
        40,
        '${_headerPadH.round()}',
        (v) => upd(() => _headerPadH = v),
        step: 1,
      ),
      _layoutSlider(
        '上边距',
        _headerPadTop,
        -20,
        80,
        '${_headerPadTop.round()}',
        (v) => upd(() => _headerPadTop = v),
        step: 1,
      ),
      const SizedBox(height: 10),
      _layoutLabel('页脚'),
      _layoutSlider(
        '左右边距',
        _footerPadH,
        0,
        40,
        '${_footerPadH.round()}',
        (v) => upd(() => _footerPadH = v),
        step: 1,
      ),
      _layoutSlider(
        '下边距',
        _footerPadBottom,
        -20,
        40,
        '${_footerPadBottom.round()}',
        (v) => upd(() => _footerPadBottom = v),
        step: 1,
      ),
      const SizedBox(height: 8),
      Text(
        '页眉/页脚需要正文分页器配合才显示，当前阅读器是整章滚动。',
        style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted),
      ),
    ];
  }

  /// 「底线」tab：线型 / 颜色 / 透明度 / 粗细 / 下间隔 / 满行底线（IMG_8095）
  List<Widget> _layoutUnderlineTab(void Function(VoidCallback) upd) {
    const styles = ['无', '短虚线', '长虚线', '实线', '波浪'];
    return [
      _layoutLabel('线型'),
      Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          for (var i = 0; i < styles.length; i++)
            GestureDetector(
              onTap: () => upd(() => _underlineStyle = i),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: _underlineStyle == i
                      ? _fg.withValues(alpha: 0.85)
                      : _fg.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  styles[i],
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: _underlineStyle == i ? _bgTop : _fg,
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      _layoutLabel('颜色'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final n in ['跟随文字', '墨黑', '深灰', '赭棕', '靛青', '银白'])
            GestureDetector(
              onTap: () => upd(
                () =>
                    _underlineColor = n == '跟随文字' ? null : _underlineColors[n],
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color:
                      (_underlineColor ==
                          (n == '跟随文字' ? null : _underlineColors[n]))
                      ? _fg.withValues(alpha: 0.85)
                      : _fg.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  n,
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    color:
                        (_underlineColor ==
                            (n == '跟随文字' ? null : _underlineColors[n]))
                        ? _bgTop
                        : _fg,
                  ),
                ),
              ),
            ),
          // 自定义底线颜色
          GestureDetector(
            onTap: () async {
              final picked = await ColorPickerDialog.show(
                context,
                initial: _underlineColor ?? _fg,
              );
              if (picked != null) upd(() => _underlineColor = picked);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '自定义',
                style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fg),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      _layoutSlider(
        '透明度',
        _underlineAlpha * 100,
        0,
        100,
        '${(_underlineAlpha * 100).round()}%',
        (v) => upd(() => _underlineAlpha = v / 100),
      ),
      _layoutSlider(
        '粗细',
        _underlineWidth,
        0.5,
        4,
        _underlineWidth.toStringAsFixed(1),
        (v) => upd(() => _underlineWidth = v),
        step: 0.1,
      ),
      _layoutSlider(
        '下间隔',
        _underlineGap,
        0,
        10,
        _underlineGap.toStringAsFixed(1),
        (v) => upd(() => _underlineGap = v),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '满行底线',
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                    color: _fg,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '开 = 每行拉满整行宽（信纸）；关 = 跟随文字宽',
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    color: _fgMuted,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: _underlineFull,
            onChanged: (v) => upd(() => _underlineFull = v),
          ),
        ],
      ),
    ];
  }

  Widget _layoutLabel(String s) => Padding(
    padding: const EdgeInsets.only(bottom: 8, top: 2),
    child: Text(
      s,
      style: TextStyle(
        fontSize: AppTheme.fontBody,
        fontWeight: FontWeight.w600,
        color: _fg,
      ),
    ),
  );

  /// 当前页首段下标（按住下滑书签的锚点 ✓）：blocks = [章标题?, ...段落] ⇒
  /// 段落下标 = blockIndex - [_blockOffset]（隐藏重复标题时没有标题块 ⇒ 偏移 0）。
  /// 空页 / 漫画回退 0。
  int _currentPageAnchorParagraph() {
    if (_images.isNotEmpty || _pages.isEmpty) return 0;
    final p = _pages[_safePageIndex()];
    if (p.entries.isEmpty) return 0;
    final e = p.entries.first;
    final bi = e.blockIndex >= 0 ? e.blockIndex : p.firstBlockIndex;
    final pi = bi - _blockOffset;
    return pi > 0 ? pi : 0;
  }

  /// 按住下滑一键书签（对齐 Cmbok）：当前页已有书签 → 直接取消；
  /// 没有 → 走「添加书签」流程（未勾"不再提示"时先弹选色面板 ✓）。
  Future<void> _gestureToggleBookmark() async {
    final anchor = _currentPageAnchorParagraph();
    if (_bookmarks.containsKey(anchor)) {
      setState(() => _bookmarks.remove(anchor));
      await _savePrefs();
      _toast('已取消书签');
    } else {
      await _showAddBookmark(anchor);
    }
  }

  /// 包一层「按住稍作停顿再向下拖」手势 → 一键书签（Cmbok 同款 ✓）。
  /// 仅包裹分页平移 / 覆盖 / 无动画三种模式；上下滚动 / 仿真翻页禁用 ✓。
  Widget withPressDownBookmark(Widget child) {
    return GestureDetector(
      onLongPressStart: (d) {
        _bookmarkPressArmed = true;
        _bookmarkPressStartDy = d.globalPosition.dy;
      },
      onLongPressMoveUpdate: (d) {
        if (_bookmarkPressArmed &&
            d.globalPosition.dy - _bookmarkPressStartDy > 56) {
          _bookmarkPressArmed = false;
          _gestureToggleBookmark();
        }
      },
      onLongPressEnd: (_) => _bookmarkPressArmed = false,
      onLongPressCancel: () => _bookmarkPressArmed = false,
      child: child,
    );
  }

  /// 「添加书签」弹层（截图 IMG_8100）：
  ///   标题「添加书签」+ 6 个颜色圆点 + 「不再提示」勾选框
  ///
  /// 「不再提示」勾上后，下次加书签**不再弹这个框**，直接用上次的颜色 ——
  /// 这正是截图里那行说明的意思（"下次直接使用上次选择的颜色"）。
  Future<void> _showAddBookmark(int paraIndex) async {
    if (_bookmarkNoAsk) {
      setState(() {
        _bookmarks[paraIndex] = _bookmarkColors[_bookmarkLastColor];
      });
      _toast('已用${_bookmarkColorName(_bookmarkLastColor)}加书签');
      await _savePrefs();
      return;
    }
    var noAsk = false;
    final picked = await showModalBottomSheet<Color>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          decoration: BoxDecoration(
            color: _bgTop,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '添加书签',
                    style: TextStyle(
                      fontSize: AppTheme.fontTitle3,
                      fontWeight: FontWeight.w700,
                      color: _fg,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      for (var i = 0; i < _bookmarkColors.length; i++)
                        GestureDetector(
                          onTap: () => Navigator.pop(ctx, _bookmarkColors[i]),
                          child: Container(
                            width: 38,
                            height: 38,
                            margin: const EdgeInsets.only(right: 14),
                            decoration: BoxDecoration(
                              color: _bookmarkColors[i],
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _fg.withValues(alpha: 0.15),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // 「不再提示」
                  GestureDetector(
                    onTap: () => setSheet(() => noAsk = !noAsk),
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      children: [
                        Icon(
                          noAsk
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 21,
                          color: _fgMuted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '不再提示（下次直接使用上次选择的颜色）',
                            style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: _fg,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (picked == null) return;
    setState(() {
      _bookmarks[paraIndex] = picked;
      if (noAsk) {
        _bookmarkNoAsk = true;
        _bookmarkLastColor = _bookmarkColors.indexOf(picked);
      }
    });
    await _savePrefs();
    _toast('已加书签');
  }

  String _bookmarkColorName(int i) {
    const names = ['黄色', '绿色', '蓝色', '粉色', '紫色', '蓝紫'];
    return names[i % names.length];
  }

  /// 长按段落 → 菜单：📌 加书签 / 🖍 划线 / ✍️ 划线+批注
  Future<void> _onParagraphLongPress(int i) async {
    if (_paragraphs.isEmpty || i < 0 || i >= _paragraphs.length) return;
    final text = _paragraphs[i];
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _bgTop,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text.length > 42 ? '${text.substring(0, 42)}…' : text,
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    color: _fgMuted,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _longPressAction(
                        Icons.bookmark_add_rounded,
                        '加书签',
                        () => Navigator.pop(ctx, 'bookmark'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _longPressAction(
                        Icons.border_color_rounded,
                        '划线',
                        () => Navigator.pop(ctx, 'highlight'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _longPressAction(
                        Icons.edit_note_rounded,
                        '划线+批注',
                        () => Navigator.pop(ctx, 'note'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 第二行：对齐 Legado 的选中菜单（复制 / 搜索 / 朗读）
                Row(
                  children: [
                    Expanded(
                      child: _longPressAction(
                        Icons.copy_rounded,
                        '复制',
                        () => Navigator.pop(ctx, 'copy'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _longPressAction(
                        Icons.search_rounded,
                        '搜索',
                        () => Navigator.pop(ctx, 'search'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _longPressAction(
                        Icons.headphones_rounded,
                        '朗读这段',
                        () => Navigator.pop(ctx, 'tts'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'bookmark':
        await _showAddBookmark(i);
      case 'highlight':
        final kept = await ReaderNotesService.instance.toggleHighlight(
          sourceId: widget.source.id,
          sourceName: widget.source.name,
          bookName: widget.bookName,
          chapterIndex: _index,
          chapterName: widget.chapters[_index].name,
          paragraphIndex: i,
          text: text,
        );
        if (!mounted) return;
        setState(() {});
        _toast(kept ? '已划线' : '已取消划线');
      case 'note':
        final note = await _showNoteInput(text);
        if (note == null || !mounted) return;
        await ReaderNotesService.instance.addNote(
          sourceId: widget.source.id,
          sourceName: widget.source.name,
          bookName: widget.bookName,
          chapterIndex: _index,
          chapterName: widget.chapters[_index].name,
          paragraphIndex: i,
          text: text,
          note: note,
        );
        if (!mounted) return;
        setState(() {});
        _toast('已划线并写入批注');
      case 'copy':
        await Clipboard.setData(ClipboardData(text: text));
        _toast('已复制这一段');
      case 'search':
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => BookSourceSearchPage(
            initialKeyword: _searchSeed(text),
          ),
        ));
      case 'tts':
        await _tts.speak(text);
        _toast('正在朗读这一段');
    }
  }

  /// 从段落里截一个"可搜索"的关键词（去掉空白/引号，最多 20 字）
  String _searchSeed(String t) {
    final cleaned = t
        .replaceAll(RegExp(r'[\s\u3000]+'), ' ')
        .replaceAll(RegExp(r'^[“”"「」『』\s]+|[“”"「」『』\s]+$'), '')
        .trim();
    if (cleaned.isEmpty) return t.trim();
    return cleaned.length <= 20 ? cleaned : cleaned.substring(0, 20);
  }

  Widget _longPressAction(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: _fg.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: _fg),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fg),
            ),
          ],
        ),
      ),
    );
  }

  /// 批注输入框。返回批注文字（空字符串 = 只划线不批注）。
  Future<String?> _showNoteInput(String text) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _bgTop,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          '写批注',
          style: TextStyle(fontSize: AppTheme.fontTitle3, color: _fg),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text.length > 60 ? '${text.substring(0, 60)}…' : text,
              style: TextStyle(
                fontSize: AppTheme.fontFootnote,
                color: _fgMuted,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: '写下你的想法…',
                hintStyle: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: _fgMuted,
                ),
                filled: true,
                fillColor: _fg.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(
              '取消',
              style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fgMuted),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  /// 应用一个排版预设。
  ///
  /// 预设目前只存名字（够界面用）；真正要跨书复用需要把
  /// 整组排版值序列化进 SharedPreferences —— 那是下一步。
  /// 当前排版状态 → 预设快照（Map 由 [_savePrefs]/存预设共用）
  Map<String, dynamic> _presetSnapshot() => {
    'fontSize': _fontSize,
    'lineHeight': _lineHeight,
    'bgIndex': _bgIndex,
    'customBg': _customBgColor?.toARGB32() ?? 0,
    'fgOverride': _fgOverride?.toARGB32() ?? 0,
    'underlineColor': _underlineColor?.toARGB32() ?? 0,
    'underlineStyle': _underlineStyle,
    'underlineAlpha': _underlineAlpha,
    'underlineWidth': _underlineWidth,
    'underlineGap': _underlineGap,
    'underlineFull': _underlineFull,
    'fontWeight': _fontWeight,
    'letterSpacing': _letterSpacing,
    'paraSpacing': _paraSpacing,
    'padLeft': _padLeft,
    'padRight': _padRight,
    'padTop': _padTop,
    'padBottom': _padBottom,
    'indent': _indent,
    'headerPadH': _headerPadH,
    'headerPadTop': _headerPadTop,
    'footerPadH': _footerPadH,
    'footerPadBottom': _footerPadBottom,
    'focusBold': _focusBold,
    'titleAlign': _titleAlign,
    'titleStyle': _titleStyle,
    'hideRepeatTitle': _hideRepeatTitle,
  };

  /// 预设快照 → 恢复排版字段
  void _applyPresetMap(Map<String, dynamic> m) {
    setState(() {
      _fontSize = (m['fontSize'] as num?)?.toDouble() ?? _fontSize;
      _lineHeight = (m['lineHeight'] as num?)?.toDouble() ?? _lineHeight;
      final bg = m['bgIndex'] as int?;
      if (bg != null && bg >= 0 && bg < _bgs.length) _bgIndex = bg;
      final cb = m['customBg'] as int?;
      _customBgColor = (cb == null || cb == 0) ? null : Color(cb);
      final fo = m['fgOverride'] as int?;
      _fgOverride = (fo == null || fo == 0) ? null : Color(fo);
      final uc = m['underlineColor'] as int?;
      _underlineColor = (uc == null || uc == 0) ? null : Color(uc);
      _underlineStyle =
          (m['underlineStyle'] as num?)?.toInt() ?? _underlineStyle;
      _underlineAlpha =
          (m['underlineAlpha'] as num?)?.toDouble() ?? _underlineAlpha;
      _underlineWidth =
          (m['underlineWidth'] as num?)?.toDouble() ?? _underlineWidth;
      _underlineGap = (m['underlineGap'] as num?)?.toDouble() ?? _underlineGap;
      _underlineFull = m['underlineFull'] as bool? ?? _underlineFull;
      _fontWeight = (m['fontWeight'] as num?)?.toDouble() ?? _fontWeight;
      _letterSpacing =
          (m['letterSpacing'] as num?)?.toDouble() ?? _letterSpacing;
      _paraSpacing = (m['paraSpacing'] as num?)?.toDouble() ?? _paraSpacing;
      _padLeft = (m['padLeft'] as num?)?.toDouble() ?? _padLeft;
      _padRight = (m['padRight'] as num?)?.toDouble() ?? _padRight;
      _padTop = (m['padTop'] as num?)?.toDouble() ?? _padTop;
      _padBottom = (m['padBottom'] as num?)?.toDouble() ?? _padBottom;
      _indent = (m['indent'] as num?)?.toDouble() ?? _indent;
      _headerPadH = (m['headerPadH'] as num?)?.toDouble() ?? _headerPadH;
      _headerPadTop = (m['headerPadTop'] as num?)?.toDouble() ?? _headerPadTop;
      _footerPadH = (m['footerPadH'] as num?)?.toDouble() ?? _footerPadH;
      _footerPadBottom =
          (m['footerPadBottom'] as num?)?.toDouble() ?? _footerPadBottom;
      _focusBold = m['focusBold'] as bool? ?? _focusBold;
      _titleAlign = m['titleAlign'] as int? ?? _titleAlign;
      _titleStyle = m['titleStyle'] as int? ?? _titleStyle;
      _hideRepeatTitle = m['hideRepeatTitle'] as bool? ?? _hideRepeatTitle;
    });
  }

  Future<void> _applyPreset(String name) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('reading.preset.$name');
      if (raw == null || raw.isEmpty) {
        _toast('预设「$name」不存在');
        return;
      }
      _applyPresetMap(Map<String, dynamic>.from(jsonDecode(raw) as Map));
      await _savePrefs();
      _toast('已应用预设「$name」');
    } catch (_) {
      _toast('应用预设失败');
    }
  }

  /// 「存预设」对话框（截图 IMG_8096）
  Future<void> _showSavePresetDialog(TextEditingController ctrl) async {
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _bgTop,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          '保存排版预设',
          style: TextStyle(fontSize: AppTheme.fontTitle3, color: _fg),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '预设名',
            labelStyle: TextStyle(
              fontSize: AppTheme.fontSubhead,
              color: _fgMuted,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text('取消', style: TextStyle(color: _fgMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            style: FilledButton.styleFrom(
              backgroundColor: _fg.withValues(alpha: 0.9),
              foregroundColor: _bgTop,
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('reading.preset.$name', jsonEncode(_presetSnapshot()));
    } catch (_) {}
    setState(() {
      if (!_savedPresets.contains(name)) _savedPresets.add(name);
    });
    await _savePrefs();
    _toast('已保存预设「$name」');
  }

  // ── 阅读样式（预设样式 / 我的样式 / Legado 排版导入）────────────

  /// 标题 HTML 输入框（返回 null = 取消）。阅读器全局与「样式编辑」共用。
  Future<String?> _promptTitleHtml(String initial) async {
    final ctrl = TextEditingController(text: initial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _bgTop,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          '自定义标题 HTML',
          style: TextStyle(fontSize: AppTheme.fontTitle3, color: _fg),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '把源阅读的「标题样式」整段粘进来即可（章节名 / 章节数 用原文那两个词）。\n'
                '支持 color、font-size、margin/padding、background-color、'
                'background-image(url)、border-radius、box-shadow、text-shadow、text-align。',
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  color: _fgMuted,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 220,
                child: TextField(
                  controller: ctrl,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: TextStyle(fontSize: 12, color: _fg),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: _fg.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final data = await Clipboard.getData('text/plain');
              final text = data?.text;
              if (text != null && text.trim().isNotEmpty) {
                ctrl.text = text.trim();
                ctrl.selection = TextSelection.collapsed(
                  offset: ctrl.text.length,
                );
              }
            },
            child: Text('粘贴', style: TextStyle(color: _fgMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('取消', style: TextStyle(color: _fgMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(
              backgroundColor: _fg.withValues(alpha: 0.9),
              foregroundColor: _bgTop,
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final text = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || text.isEmpty) return null;
    return text;
  }

  /// 编辑阅读器当前的「自定义标题 HTML」
  Future<void> _editTitleHtml() async {
    final text = await _promptTitleHtml(
      _chapterTitleHtml.trim().isEmpty
          ? ReaderTitleStyle.starterTemplate
          : _chapterTitleHtml,
    );
    if (text == null) return;
    setState(() {
      _chapterTitleHtml = text;
      // 手动改的 HTML 日夜通用（否则夜里还在用样式自带的夜间标题）
      _chapterTitleHtmlNight = '';
      _chapterTitleStyle = ReaderTitleStyle.custom;
    });
    _scheduleSavePrefs();
    // 标题高度变了 ⇒ 章首那页要重排
    _scheduleRepaginate();
    _toast('标题样式已更新');
  }

  /// 通用「输入一个名字」对话框
  Future<String?> _promptName(
    String title,
    String label,
    String initial,
  ) async {
    final ctrl = TextEditingController(text: initial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _bgTop,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          title,
          style: TextStyle(fontSize: AppTheme.fontTitle3, color: _fg),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: _fg),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(
              fontSize: AppTheme.fontSubhead,
              color: _fgMuted,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('取消', style: TextStyle(color: _fgMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(
              backgroundColor: _fg.withValues(alpha: 0.9),
              foregroundColor: _bgTop,
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final text = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || text.isEmpty) return null;
    return text;
  }

  /// 把**当前标题样式**（内置或自定义的 HTML）存进「我的标题样式」
  Future<void> _saveCurrentTitleStyle() async {
    final src = _chapterTitleSource.trim();
    if (src.isEmpty) {
      _toast('当前是「默认」标题，没有可保存的 HTML');
      return;
    }
    final name = await _promptName(
      '保存标题样式',
      '标题样式名',
      _chapterTitleStyle == ReaderTitleStyle.custom
          ? '我的标题样式'
          : _chapterTitleStyle.label,
    );
    if (name == null) return;
    final preset = TitleStylePreset(
      id: 'title:${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      html: src,
    );
    setState(() {
      // 同名 = 覆盖
      _myTitleStyles = [
        ..._myTitleStyles.where((e) => e.name != name),
        preset,
      ];
    });
    await _styleStore.saveTitleStyles(_myTitleStyles);
    _toast('已保存标题样式「$name」');
  }

  Future<void> _deleteTitleStyle(TitleStylePreset t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _bgTop,
        title: Text(
          '删除标题样式',
          style: TextStyle(fontSize: AppTheme.fontTitle3, color: _fg),
        ),
        content: Text(
          '确定删除「${t.name}」？',
          style: TextStyle(fontSize: AppTheme.fontBody, color: _fgMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('取消', style: TextStyle(color: _fgMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(
              backgroundColor: _fg.withValues(alpha: 0.9),
              foregroundColor: _bgTop,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _myTitleStyles = [..._myTitleStyles.where((e) => e.id != t.id)];
    });
    await _styleStore.saveTitleStyles(_myTitleStyles);
    _toast('已删除「${t.name}」');
  }

  /// 套用一个「我的标题样式」
  void _applyTitleStyle(TitleStylePreset t) {
    setState(() {
      _chapterTitleStyle = ReaderTitleStyle.custom;
      _chapterTitleHtml = t.html;
      // 手动套用的标题样式日夜通用
      _chapterTitleHtmlNight = '';
    });
    _scheduleSavePrefs();
    _scheduleRepaginate();
    _toast('已应用标题样式「${t.name}」');
  }

  /// 页眉 / 页脚格式串编辑对话框（返回 6 个值；null = 取消）
  Future<({String hL, String hC, String hR, String fL, String fC, String fR})?>
  _promptHeaderFooter({
    required String hL,
    required String hC,
    required String hR,
    required String fL,
    required String fC,
    required String fR,
  }) async {
    final ctrls = {
      'HL': TextEditingController(text: hL),
      'HC': TextEditingController(text: hC),
      'HR': TextEditingController(text: hR),
      'FL': TextEditingController(text: fL),
      'FC': TextEditingController(text: fC),
      'FR': TextEditingController(text: fR),
    };
    Widget field(String key, String label, String hint) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: ctrls[key],
        style: TextStyle(fontSize: 13, color: _fg),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          hintStyle: TextStyle(fontSize: 11, color: _fgMuted),
          isDense: true,
          filled: true,
          fillColor: _fg.withValues(alpha: 0.05),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _bgTop,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          '页眉 / 页脚格式',
          style: TextStyle(fontSize: AppTheme.fontTitle3, color: _fg),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '变量：# 章节名 · c 章节序号 · C 总章数 · p 本章页码\n'
                  'P 本章总页数 · % 进度 · t 时间 · b 电量 · B 书名\n'
                  '留空 = 该位置不显示；三条都空 = 回到「信息栏项目」开关。',
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    color: _fgMuted,
                  ),
                ),
                const SizedBox(height: 10),
                field('HL', '页眉 · 左', '例如：#'),
                field('HC', '页眉 · 中', '留空'),
                field('HR', '页眉 · 右', '例如：t'),
                field('FL', '页脚 · 左', '例如：B'),
                field('FC', '页脚 · 中', '留空'),
                field('FR', '页脚 · 右', '例如：p/P'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('取消', style: TextStyle(color: _fgMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(
              backgroundColor: _fg.withValues(alpha: 0.9),
              foregroundColor: _bgTop,
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final result = ok == true
        ? (
            hL: ctrls['HL']!.text.trim(),
            hC: ctrls['HC']!.text.trim(),
            hR: ctrls['HR']!.text.trim(),
            fL: ctrls['FL']!.text.trim(),
            fC: ctrls['FC']!.text.trim(),
            fR: ctrls['FR']!.text.trim(),
          )
        : null;
    for (final c in ctrls.values) {
      c.dispose();
    }
    return result;
  }

  /// 页眉 / 页脚格式串编辑（作用到阅读器当前状态）
  Future<void> _editHeaderFooter() async {
    final r = await _promptHeaderFooter(
      hL: _headerL,
      hC: _headerC,
      hR: _headerR,
      fL: _footerL,
      fC: _footerC,
      fR: _footerR,
    );
    if (r == null) return;
    setState(() {
      _headerL = r.hL;
      _headerC = r.hC;
      _headerR = r.hR;
      _footerL = r.fL;
      _footerC = r.fC;
      _footerR = r.fR;
    });
    _scheduleSavePrefs();
    // 页眉页脚显隐变了 ⇒ 可排版区域高度变了
    _scheduleRepaginate();
    _toast('页眉页脚已更新');
  }

  /// 样式分享：导出到剪贴板 / 从剪贴板导入
  Future<void> _showStyleShare() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _sheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (c) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.ios_share_rounded, color: _fg),
              title: Text('导出当前样式（复制 JSON）', style: TextStyle(color: _fg)),
              subtitle: Text(
                '发给别人，粘到下面的「导入」即可',
                style: TextStyle(fontSize: 12, color: _fgMuted),
              ),
              onTap: () => Navigator.pop(c, 'export'),
            ),
            ListTile(
              leading: Icon(Icons.download_rounded, color: _fg),
              title: Text('从剪贴板导入样式', style: TextStyle(color: _fg)),
              onTap: () => Navigator.pop(c, 'import'),
            ),
          ],
        ),
      ),
    );
    if (action == 'export') {
      final s = _styleSnapshot(
        'user:${DateTime.now().millisecondsSinceEpoch}',
        '分享的样式',
      );
      await Clipboard.setData(ClipboardData(text: jsonEncode(s.toJson())));
      _toast('样式已复制到剪贴板');
    } else if (action == 'import') {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        _toast('剪贴板是空的');
        return;
      }
      try {
        final map = jsonDecode(text);
        if (map is! Map) {
          _toast('剪贴板内容不是样式 JSON');
          return;
        }
        final style = ReaderStyle.fromJson(Map<String, dynamic>.from(map));
        final copy = _patched(style, {
          'id': 'user:${DateTime.now().millisecondsSinceEpoch}',
          'builtin': false,
          'name': '${style.name} 导入',
        });
        setState(() => _myStyles = [..._myStyles, copy]);
        await _styleStore.saveCustom(_myStyles);
        _toast('已导入样式「${copy.name}」');
      } catch (_) {
        _toast('解析失败：不是样式 JSON');
      }
    }
  }

  /// 导入「源阅读」`.srs` 样式（Base64 → 逐字节 XOR 0x60）。
  ///
  /// 也接受已经解密好的 `.json`（10MB 左右，含内嵌背景图）。
  /// 背景图会落盘到 `<Documents>/reader_styles/`，样式里存的是本地路径。
  Future<void> _importSrsStyle() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['srs', 'json', 'srsx', 'txt'],
    );
    if (files.isEmpty) return;
    final picked = files.first;
    _toast('正在解析样式…');
    // 让 SnackBar 先画出来（下面解析 10MB 左右的 JSON 会占住 UI 线程）
    await Future<void>.delayed(const Duration(milliseconds: 40));

    Map<String, dynamic>? json;
    try {
      final bytes = await picked.readAsBytes();
      json = SrsStyleImporter.parse(bytes);
    } catch (_) {
      _toast('读取文件失败');
      return;
    }
    if (json == null) {
      _toast('解析失败：不是源阅读 .srs / 样式 JSON');
      return;
    }

    // 日 / 夜两张背景图**都落盘**：.srs 里是两套图，
    // 只在导入时按当前模式取一张 ⇒ 切到另一个模式就图不匹配（夜里导入的
    // 白天也显示夜景）。
    Future<String?> saveBg(int kind) async {
      final img = SrsStyleImporter.backgroundBytes(json!, night: kind == 1);
      if (img == null) return null;
      try {
        final dir = await getApplicationDocumentsDirectory();
        final d = Directory('${dir.path}/reader_styles');
        if (!d.existsSync()) d.createSync(recursive: true);
        final f = File(
          '${d.path}/srs_${DateTime.now().millisecondsSinceEpoch}_${kind == 1 ? 'n' : 'd'}.png',
        );
        await f.writeAsBytes(img, flush: true);
        return f.path;
      } catch (_) {
        return null;
      }
    }

    final imagePath = await saveBg(0);
    final imagePathNight = await saveBg(1);

    final id = 'srs:${DateTime.now().millisecondsSinceEpoch}';
    // 内嵌字体（fontData）：注册到引擎并落盘（4~5MB 的 ttf 很常见）
    String? fontId;
    final fontBytes = SrsStyleImporter.fontBytes(json);
    if (fontBytes != null) {
      final f = await ReaderFontService.instance.importBytes(
        fontBytes,
        name: SrsStyleImporter.fontName(json) ?? '源阅读字体',
        ext: 'ttf',
      );
      fontId = f?.id;
    }
    final style = SrsStyleImporter.toReaderStyle(
      json,
      id: id,
      bgImagePath: imagePath,
      bgImagePathNight: imagePathNight,
      fontId: fontId,
    );
    setState(() => _myStyles = [..._myStyles, style]);
    await _styleStore.saveCustom(_myStyles);
    _applyReaderStyle(style);
    _toast('已导入「${style.name}」');
  }

  /// 当前阅读外观 → [ReaderStyle] 快照（「保存当前为样式」用）
  ReaderStyle _styleSnapshot(String id, String name, {bool builtin = false}) {
    // 日夜底色要分开存：夜间保存时 `_customBgColor` 是**夜间**底色，
    // 直接当 bgColor 会把日间也存成深色（反之夜里没 bgColorNight ⇒ 浅底浅字）
    final dayBg = _bgIndex == 5
        ? (_styleBgDay ??
              _bgs[_dayBgIndex.clamp(0, _bgs.length - 1)][0].toARGB32())
        : _customBgColor?.toARGB32();
    final nightBg = _bgIndex == 5
        ? (_customBgColor?.toARGB32() ?? _bgs[5][0].toARGB32())
        : (_styleBgNight ?? _bgs[5][0].toARGB32());
    return ReaderStyle(
      id: id,
      name: name,
      builtin: builtin,
      bgIndex: _bgIndex,
      dayBgIndex: _dayBgIndex,
      bgColor: dayBg,
      bgColorNight: nightBg,
      fgColor: _fgOverride?.toARGB32(),
      fgColorNight: _fgNightOverride?.toARGB32(),
      bgImageAsset: _bgImageAsset,
      bgImageAssetNight: _bgImageAssetNight,
      bgImagePath: _customBgPath,
      bgImagePathNight: _customBgPathNight,
      bgImageDark: _bgImageDark ?? false,
      fontSize: _fontSize,
      lineHeight: _lineHeight,
      letterSpacing: _letterSpacing,
      fontWeight: _fontWeight,
      fontId: _fontId ?? '',
      paraSpacing: _paraSpacing,
      indent: _indent,
      titleAlign: _titleAlign,
      titleStyle: _titleStyle,
      titleFontSize: _titleFontSize,
      titleScale: _titleScale,
      titleGap: _titleGap,
      titleBold: _titleBold,
      hideRepeatTitle: _hideRepeatTitle,
      focusBold: _focusBold,
      padLeft: _padLeft,
      padRight: _padRight,
      padTop: _padTop,
      padBottom: _padBottom,
      headerPadH: _headerPadH,
      headerPadTop: _headerPadTop,
      footerPadH: _footerPadH,
      footerPadBottom: _footerPadBottom,
      statusItems: _rs.statusItems.toList(),
      hideStatusBar: _rs.hideStatusBar,
      statusTextScale: _rs.statusTextScale,
      headerL: _headerL,
      headerC: _headerC,
      headerR: _headerR,
      footerL: _footerL,
      footerC: _footerC,
      footerR: _footerR,
      pageMode: _rs.pageMode.name,
      dualPage: _rs.dualPage,
      chapterTitleStyle: _chapterTitleStyle.id,
      chapterTitleHtml: _chapterTitleHtml,
      chapterTitleHtmlNight: _chapterTitleHtmlNight,
      underlineColor: _underlineColor?.toARGB32(),
      underlineStyle: _underlineStyle,
      underlineAlpha: _underlineAlpha,
      underlineWidth: _underlineWidth,
      underlineGap: _underlineGap,
      underlineFull: _underlineFull,
    );
  }

  /// 打开「标题样式」库：内置模板 + 我的 HTML（预览 / 复制 / 编辑 / 删除）
  Future<void> _openTitleStylesPage() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ReaderTitleStylesPage(
          mine: _myTitleStyles,
          current: _chapterTitleStyle,
          currentHtml: _chapterTitleHtml,
          background: _sheetBg,
          foreground: _fg,
          onApply: (style, html) {
            setState(() {
              _chapterTitleStyle = style;
              if (html.trim().isNotEmpty) {
                _chapterTitleHtml = html;
                // 手动选的标题样式日夜通用
                _chapterTitleHtmlNight = '';
              }
            });
            _scheduleSavePrefs();
            _scheduleRepaginate();
          },
          onChanged: (list) {
            if (!mounted) return;
            setState(() => _myTitleStyles = list);
          },
        ),
      ),
    );
  }

  /// 打开独立的「阅读样式」库页面（内置 + 我的）。
  ///
  /// 点卡片 → 页面 pop 回选中的样式 → 这里套用；保存/编辑/删除在页面内完成，
  /// 每次操作后把最新的「我的样式」列表回传给页面刷新。
  Future<void> _openStylesPage() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ReaderStylesPage(
          builtins: ReaderStyle.builtins,
          mine: _myStyles,
          activeId: _activeStyleId,
          background: _sheetBg,
          foreground: _fg,
          night: _bgIndex == 5,
          onApply: _applyReaderStyle,
          onChanged: (list) {
            if (!mounted) return;
            setState(() => _myStyles = list);
          },
          onSaveCurrent: () async {
            await _saveCurrentAsStyle();
            return List.of(_myStyles);
          },
        ),
      ),
    );
    if (!mounted) return;
    // 页里可能改了「白天 / 夜间绑定样式」或「跟随系统」，回来后同步
    final d = await _styleStore.loadDayStyleId();
    final n = await _styleStore.loadNightStyleId();
    final f = await _styleStore.loadFollowSystem();
    if (!mounted) return;
    setState(() {
      _dayStyleId = d;
      _nightStyleId = n;
      _followSystem = f;
    });
    // 刚把「跟随系统」打开 ⇒ 立刻按当前全局明暗对齐一次
    if (f) _onAppAppearanceChanged();
  }

  /// 一键套用一套样式：配色 / 背景 / 排版 / 边距 / 信息栏 / 翻页动画一次改完。
  ///
  /// 改完必须**重排**（字号行距边距全变了，旧 `_pages` 是按旧度量切的），
  /// 但用防抖 —— 用户可能连着点好几张卡片对比效果。
  void _applyReaderStyle(ReaderStyle s) {
    final mode = PageMode.values.firstWhere(
      (m) => m.name == s.pageMode,
      orElse: () => PageMode.slide,
    );
    // 保持当前昼夜模式（夜间套样式仍是夜间），只换成这套样式的对应配色
    final night = _bgIndex == 5;
    final dayColor = s.bgColor;
    final nightColor = s.bgColorNight ?? s.bgColor;
    final custom = night ? nightColor : dayColor;
    final path = s.bgImagePath;
    final pathNight = s.bgImagePathNight;
    setState(() {
      _styleBgDay = dayColor;
      _styleBgNight = nightColor;
      _bgIndex = night
          ? 5
          : s.bgIndex.clamp(0, _bgs.length - 1);
      _dayBgIndex = s.dayBgIndex.clamp(0, _bgs.length - 1);
      _customBgColor = custom == null ? null : Color(custom);
      _fgOverride = s.fgColor == null ? null : Color(s.fgColor!);
      _fgNightOverride = s.fgColorNight == null
          ? null
          : Color(s.fgColorNight!);
      _titleFontSize = s.titleFontSize;
      // 标题缩放/间距是样式的组成部分（样式库里可调、可导出）
      _titleScale = s.titleScale.clamp(0.6, 1.6);
      _titleGap = s.titleGap.clamp(0.0, 40.0);
      _titleBold = s.titleBold;
      _bgImageAsset = s.bgImageAsset;
      _bgImageAssetNight = s.bgImageAssetNight;
      _bgImageDark = s.bgImageAsset == null ? null : s.bgImageDark;
      _customBgPath = (path != null && File(path).existsSync()) ? path : null;
      _customBgPathNight =
          (pathNight != null && File(pathNight).existsSync()) ? pathNight : null;
      _fontSize = s.fontSize.clamp(12.0, 30.0);
      _lineHeight = s.lineHeight.clamp(1.05, 3.0);
      _letterSpacing = s.letterSpacing.clamp(-2.0, 8.0);
      _fontWeight = s.fontWeight.clamp(100.0, 900.0);
      _paraSpacing = s.paraSpacing.clamp(0.0, 2.0);
      _indent = s.indent.clamp(0.0, 4.0);
      _titleAlign = s.titleAlign;
      _titleStyle = s.titleStyle;
      _chapterTitleStyle = ReaderTitleStyle.fromId(s.chapterTitleStyle);
      if (s.chapterTitleHtml.isNotEmpty) _chapterTitleHtml = s.chapterTitleHtml;
      // 夜间标题（db 的 titleStyleHtmlNight）；样式没带就清空，避免沿用上一套
      _chapterTitleHtmlNight = s.chapterTitleHtmlNight;
      _headerL = s.headerL;
      _headerC = s.headerC;
      _headerR = s.headerR;
      _footerL = s.footerL;
      _footerC = s.footerC;
      _footerR = s.footerR;
      _hideRepeatTitle = s.hideRepeatTitle;
      _focusBold = s.focusBold;
      _padLeft = s.padLeft.clamp(0.0, 80.0);
      _padRight = s.padRight.clamp(0.0, 80.0);
      _padTop = s.padTop.clamp(0.0, 120.0);
      _padBottom = s.padBottom.clamp(0.0, 120.0);
      _headerPadH = s.headerPadH.clamp(0.0, 80.0);
      _headerPadTop = s.headerPadTop.clamp(0.0, 80.0);
      _footerPadH = s.footerPadH.clamp(0.0, 80.0);
      _footerPadBottom = s.footerPadBottom.clamp(0.0, 80.0);
      _underlineColor = s.underlineColor == null
          ? null
          : Color(s.underlineColor!);
      _underlineStyle = s.underlineStyle;
      _underlineAlpha = s.underlineAlpha;
      _underlineWidth = s.underlineWidth;
      _underlineGap = s.underlineGap;
      _underlineFull = s.underlineFull;
      _rs = _rs.copyWith(
        pageMode: mode,
        statusItems: s.statusItems.toSet(),
        hideStatusBar: s.hideStatusBar,
        statusTextScale: s.statusTextScale,
        dualPage: s.dualPage,
      );
      // 上下滚动模式不分页 ⇒ 和 `_paginate()` 的清理保持一致
      if (!mode.paginates) _pages = const [];
      _activeStyleId = s.id;
    });
    _styleStore.saveActiveId(s.id);
    _precachePaper();
    // 套样式后重采自选图明暗（_fileBgDark 用，_paperIsDark 依赖它）
    if (path != null && File(path).existsSync()) {
      unawaited(_analyzeFileBg(path));
    }
    _scheduleSavePrefs();
    _scheduleRepaginate();
    // 字体是异步注册的 → 单独处理（同步能拿到就直接切，省一次重排）
    _applyFontId(s.fontId);
    _toast('已套用「${s.name}」');
  }

  /// 切换自定义字体（[id] 为空 = 恢复系统默认）
  void _applyFontId(String id) {
    if (id.isEmpty) {
      setState(() {
        _fontId = null;
        _fontFamily = null;
      });
      _scheduleRepaginate();
      return;
    }
    final sync = ReaderFontService.instance.familyOfSync(id);
    if (sync != null) {
      setState(() {
        _fontId = id;
        _fontFamily = sync;
      });
      _scheduleRepaginate();
      return;
    }
    unawaited(() async {
      final fam = await ReaderFontService.instance.familyOf(id);
      if (!mounted) return;
      setState(() {
        _fontId = fam == null ? null : id;
        _fontFamily = fam;
      });
      _scheduleRepaginate();
    }());
  }

  /// 导入自定义字体（ttf / otf / ttc）并立即应用
  Future<void> _importFont() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['ttf', 'otf', 'ttc'],
    );
    if (files.isEmpty) return;
    final picked = files.first;
    final baseName = picked.name.replaceAll(
      RegExp(r'\.(ttf|otf|ttc)$', caseSensitive: false),
      '',
    );
    _toast('正在导入字体…');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    ReaderFont? font;
    try {
      final bytes = await picked.readAsBytes();
      font = await ReaderFontService.instance.importBytes(
        bytes,
        name: baseName,
        ext: picked.extension,
      );
    } catch (_) {}
    if (font == null) {
      _toast('字体加载失败（请确认是 ttf / otf 文件）');
      return;
    }
    final fam = await ReaderFontService.instance.familyOf(font.id);
    if (!mounted) return;
    setState(() {
      _fontId = font!.id;
      _fontFamily = fam;
    });
    _scheduleSavePrefs();
    _scheduleRepaginate();
    _toast('已应用字体「${font.name}」');
  }

  /// 删除一个自定义字体（正在用就退回系统默认）
  Future<void> _deleteFont(ReaderFont f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _bgTop,
        title: Text(
          '删除字体',
          style: TextStyle(fontSize: AppTheme.fontTitle3, color: _fg),
        ),
        content: Text(
          '确定删除「${f.name}」？',
          style: TextStyle(fontSize: AppTheme.fontBody, color: _fgMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('取消', style: TextStyle(color: _fgMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(
              backgroundColor: _fg.withValues(alpha: 0.9),
              foregroundColor: _bgTop,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ReaderFontService.instance.remove(f);
    if (!mounted) return;
    setState(() {
      if (_fontId == f.id) {
        _fontId = null;
        _fontFamily = null;
      }
    });
    _scheduleSavePrefs();
    _scheduleRepaginate();
    _toast('已删除字体「${f.name}」');
  }

  /// 「保存当前为样式」：把此刻的外观存成一条**我的样式**
  Future<void> _saveCurrentAsStyle() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _bgTop,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          '保存为阅读样式',
          style: TextStyle(fontSize: AppTheme.fontTitle3, color: _fg),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '样式名',
            labelStyle: TextStyle(
              fontSize: AppTheme.fontSubhead,
              color: _fgMuted,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text('取消', style: TextStyle(color: _fgMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            style: FilledButton.styleFrom(
              backgroundColor: _fg.withValues(alpha: 0.9),
              foregroundColor: _bgTop,
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    final id = 'user:${DateTime.now().millisecondsSinceEpoch}';
    final style = _styleSnapshot(id, name);
    setState(() {
      // 同名 = 覆盖（用户视角"我的样式"里不该出现两个同名）
      _myStyles = [
        ..._myStyles.where((s) => s.name != name),
        style,
      ];
      _activeStyleId = id;
    });
    await _styleStore.saveCustom(_myStyles);
    await _styleStore.saveActiveId(id);
    await _savePrefs();
    _toast('已保存样式「$name」');
  }

  Future<void> _renameStyle(ReaderStyle s) async {
    final ctrl = TextEditingController(text: s.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _bgTop,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          '重命名样式',
          style: TextStyle(fontSize: AppTheme.fontTitle3, color: _fg),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '样式名',
            labelStyle: TextStyle(
              fontSize: AppTheme.fontSubhead,
              color: _fgMuted,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text('取消', style: TextStyle(color: _fgMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            style: FilledButton.styleFrom(
              backgroundColor: _fg.withValues(alpha: 0.9),
              foregroundColor: _bgTop,
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    setState(() {
      _myStyles = [
        for (final e in _myStyles) e.id == s.id ? e.renamed(name) : e,
      ];
    });
    await _styleStore.saveCustom(_myStyles);
    _toast('已重命名为「$name」');
  }

  Future<void> _deleteStyle(ReaderStyle s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _bgTop,
        title: Text(
          '删除样式',
          style: TextStyle(fontSize: AppTheme.fontTitle3, color: _fg),
        ),
        content: Text(
          '确定删除「${s.name}」？',
          style: TextStyle(fontSize: AppTheme.fontBody, color: _fgMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('取消', style: TextStyle(color: _fgMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(
              backgroundColor: _fg.withValues(alpha: 0.9),
              foregroundColor: _bgTop,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _myStyles = [..._myStyles.where((e) => e.id != s.id)];
      if (_activeStyleId == s.id) _activeStyleId = null;
    });
    await _styleStore.saveCustom(_myStyles);
    _toast('已删除「${s.name}」');
  }

  /// 在 [s] 的基础上改几项（用 JSON 往返，避免给 ReaderStyle 写一大堆 copyWith）
  ReaderStyle _patched(ReaderStyle s, Map<String, dynamic> patch) =>
      ReaderStyle.fromJson({...s.toJson(), ...patch});

  /// 「复制成我的样式」：内置样式不能直接改，先复制一份再打开编辑器。
  // ignore: unused_element
  Future<void> _duplicateStyle(ReaderStyle s) async {
    final id = 'user:${DateTime.now().millisecondsSinceEpoch}';
    final copy = ReaderStyle.fromJson({
      ...s.toJson(),
      'id': id,
      'name': '${s.name} 副本',
      'builtin': false,
    });
    setState(() => _myStyles = [..._myStyles, copy]);
    await _styleStore.saveCustom(_myStyles);
    await _editStyle(copy);
  }

  /// 「编辑样式」：名称 / 标题样式 / 排版 / 边距 / 配色 / 信息栏 / 翻页。
  Future<void> _editStyle(ReaderStyle style) async {
    var draft = style;
    final nameCtrl = TextEditingController(text: draft.name);
    final saved = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void upd(Map<String, dynamic> patch) =>
              setSheet(() => draft = _patched(draft, patch));
          final titleNow = ReaderTitleStyle.fromId(draft.chapterTitleStyle);
          final items = draft.statusItems;
          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            decoration: BoxDecoration(
              color: _sheetBg,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sheetHandle(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
                    child: Row(
                      children: [
                        Text(
                          '编辑样式',
                          style: TextStyle(
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.w700,
                            color: _fg,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(
                            '取消',
                            style: TextStyle(color: _fgMuted),
                          ),
                        ),
                        const SizedBox(width: 4),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 34),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            backgroundColor: _fg.withValues(alpha: 0.9),
                            foregroundColor: _bgTop,
                          ),
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      children: [
                        TextField(
                          controller: nameCtrl,
                          style: TextStyle(color: _fg),
                          decoration: InputDecoration(
                            labelText: '样式名',
                            labelStyle: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: _fgMuted,
                            ),
                          ),
                        ),
                        _sectionLabel('标题样式'),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final t in ReaderTitleStyle.values)
                              _chip(
                                t.label,
                                titleNow == t,
                                () {
                                  final patch = <String, dynamic>{
                                    'chapterTitleStyle': t.id,
                                  };
                                  if (t == ReaderTitleStyle.custom &&
                                      draft.chapterTitleHtml.trim().isEmpty) {
                                    patch['chapterTitleHtml'] =
                                        ReaderTitleStyle.starterTemplate;
                                  }
                                  upd(patch);
                                },
                                compact: true,
                              ),
                          ],
                        ),
                        if (titleNow == ReaderTitleStyle.custom)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: _chip(
                                '编辑 HTML',
                                false,
                                () async {
                                  final text = await _promptTitleHtml(
                                    draft.chapterTitleHtml.trim().isEmpty
                                        ? ReaderTitleStyle.starterTemplate
                                        : draft.chapterTitleHtml,
                                  );
                                  if (text != null) {
                                    upd({
                                      'chapterTitleHtml': text,
                                      'chapterTitleStyle': 'custom',
                                    });
                                  }
                                },
                                compact: true,
                              ),
                            ),
                          ),
                        _sectionLabel('排版'),
                        _layoutSlider(
                          '字号',
                          draft.fontSize,
                          12,
                          30,
                          draft.fontSize.toStringAsFixed(1),
                          (v) => upd({'fontSize': v}),
                          step: 1,
                        ),
                        _layoutSlider(
                          '行距',
                          draft.lineHeight,
                          1.2,
                          2.6,
                          draft.lineHeight.toStringAsFixed(2),
                          (v) => upd({'lineHeight': v}),
                          step: 0.05,
                        ),
                        _layoutSlider(
                          '字距',
                          draft.letterSpacing,
                          -1,
                          6,
                          draft.letterSpacing.toStringAsFixed(1),
                          (v) => upd({'letterSpacing': v}),
                          step: 0.1,
                        ),
                        _layoutSlider(
                          '段距',
                          draft.paraSpacing,
                          0,
                          1.5,
                          draft.paraSpacing.toStringAsFixed(1),
                          (v) => upd({'paraSpacing': v}),
                          step: 0.1,
                        ),
                        _layoutSlider(
                          '缩进',
                          draft.indent,
                          0,
                          4,
                          draft.indent.toStringAsFixed(0),
                          (v) => upd({'indent': v}),
                          step: 1,
                        ),
                        _sectionLabel('边距'),
                        _layoutSlider(
                          '左右',
                          (draft.padLeft + draft.padRight) / 2,
                          0,
                          60,
                          ((draft.padLeft + draft.padRight) / 2)
                              .toStringAsFixed(0),
                          (v) => upd({'padLeft': v, 'padRight': v}),
                          step: 1,
                        ),
                        _layoutSlider(
                          '上',
                          draft.padTop,
                          0,
                          80,
                          draft.padTop.toStringAsFixed(0),
                          (v) => upd({'padTop': v}),
                          step: 1,
                        ),
                        _layoutSlider(
                          '下',
                          draft.padBottom,
                          0,
                          80,
                          draft.padBottom.toStringAsFixed(0),
                          (v) => upd({'padBottom': v}),
                          step: 1,
                        ),
                        _sectionLabel('配色'),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            for (var i = 0; i < _bgs.length; i++)
                              GestureDetector(
                                onTap: () => upd({
                                  'bgIndex': i,
                                  'dayBgIndex': i,
                                  'bgColor': null,
                                  'bgColorNight': null,
                                  'bgImageAsset': null,
                                  'bgImagePath': null,
                                }),
                                child: Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: _bgs[i][0],
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: draft.bgColor == null &&
                                              draft.bgImageAsset == null &&
                                              draft.bgIndex == i
                                          ? _fg
                                          : _fg.withValues(alpha: 0.2),
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final e in const [
                              ('自动', null),
                              ('墨黑', 0xFF1A1A1A),
                              ('深灰', 0xFF4A4545),
                              ('米白', 0xFFE2E2E2),
                            ])
                              _chip(
                                e.$1,
                                draft.fgColor == e.$2,
                                () => upd({'fgColor': e.$2}),
                                compact: true,
                              ),
                          ],
                        ),
                        _sectionLabel('信息栏'),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final item in const [
                              '时间',
                              '书名',
                              '章节',
                              '电量',
                              '页码',
                              '进度',
                            ])
                              _chip(
                                item,
                                items.contains(item),
                                () {
                                  final next = [...items];
                                  if (next.contains(item)) {
                                    next.remove(item);
                                  } else {
                                    next.add(item);
                                  }
                                  upd({'statusItems': next});
                                },
                                compact: true,
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: _chip(
                            '页眉页脚格式',
                            draft.headerL.isNotEmpty ||
                                draft.headerC.isNotEmpty ||
                                draft.headerR.isNotEmpty ||
                                draft.footerL.isNotEmpty ||
                                draft.footerC.isNotEmpty ||
                                draft.footerR.isNotEmpty,
                            () async {
                              final r = await _promptHeaderFooter(
                                hL: draft.headerL,
                                hC: draft.headerC,
                                hR: draft.headerR,
                                fL: draft.footerL,
                                fC: draft.footerC,
                                fR: draft.footerR,
                              );
                              if (r != null) {
                                upd({
                                  'headerL': r.hL,
                                  'headerC': r.hC,
                                  'headerR': r.hR,
                                  'footerL': r.fL,
                                  'footerC': r.fC,
                                  'footerR': r.fR,
                                });
                              }
                            },
                            compact: true,
                          ),
                        ),
                        _sectionLabel('翻页'),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final m in PageMode.values)
                              _chip(
                                m.label,
                                draft.pageMode == m.name,
                                () => upd({'pageMode': m.name}),
                                compact: true,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    final newName = nameCtrl.text.trim();
    nameCtrl.dispose();
    if (saved != true) return;
    final next = _patched(draft, {
      'name': newName.isEmpty ? draft.name : newName,
      'builtin': false,
    });
    setState(() {
      _myStyles = [for (final e in _myStyles) e.id == style.id ? next : e];
    });
    await _styleStore.saveCustom(_myStyles);
    if (_activeStyleId == next.id) _applyReaderStyle(next);
    _toast('已保存样式「${next.name}」');
  }

  /// 导入 Legado 排版：贴「导入排版」链接（`legado://import/readConfig?src=…`
  /// 或裸 zip 地址），也可以直接从本地选 `.zip` / `.json`。
  ///
  /// 站点给的就是 `.../yuedu/theme/readcode/id/<id>.zip`，里面是
  /// `readConfig.json` —— 只含排版参数，不含背景图片（见 [ReaderStyle.fromLegado]）。
  Future<void> _importStyle() async {
    final ctrl = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _bgTop,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          '导入 Legado 排版',
          style: TextStyle(fontSize: AppTheme.fontTitle3, color: _fg),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '粘贴「导入排版」链接（legado://… 或 readcode/id/xx.zip）',
              style: TextStyle(
                fontSize: AppTheme.fontFootnote,
                color: _fgMuted,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'https://…/readcode/id/108.zip',
                hintStyle: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: _fgMuted,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, '__file__'),
            child: Text(
              '选文件',
              style: TextStyle(color: _fgMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text('取消', style: TextStyle(color: _fgMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            style: FilledButton.styleFrom(
              backgroundColor: _fg.withValues(alpha: 0.9),
              foregroundColor: _bgTop,
            ),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (input == null) return;

    Map<String, dynamic>? cfg;
    if (input == '__file__') {
      // file_picker 13：静态方法，直接返回 List<PlatformFile>（无 withData，
      // 取字节走 `readAsBytes()`）
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip', 'json'],
      );
      if (files.isEmpty) return;
      try {
        final bytes = await files.first.readAsBytes();
        cfg = ReaderStyleImporter.decodeConfig(bytes);
      } catch (_) {
        _toast('读取文件失败');
        return;
      }
    } else {
      final url = ReaderStyleImporter.extractUrl(input);
      if (url == null) {
        _toast('链接不对，需要 http(s) 地址');
        return;
      }
      _toast('正在下载排版…');
      cfg = await ReaderStyleImporter.fetchConfig(url);
    }
    if (cfg == null) {
      _toast('解析失败：不是 Legado 的排版文件');
      return;
    }
    final id = 'import:${DateTime.now().millisecondsSinceEpoch}';
    final rawName = (cfg['name'] as String?)?.trim() ?? '';
    final style = ReaderStyle.fromLegado(
      cfg,
      id: id,
      nameOverride: rawName.isEmpty ? '导入样式' : rawName,
    );
    setState(() => _myStyles = [..._myStyles, style]);
    await _styleStore.saveCustom(_myStyles);
    _applyReaderStyle(style);
  }

  /// 排版面板里的一行"标签 + 滑块 + 减 + 数值 + 加"
  ///
  /// [step] 显式步进（字号 1 / 行距 · 段距 · 字距 0.1 / 字重 50）：
  /// 原来按 `(max-min)/20` 算 ⇒ 行距是 0.07 一档，显示成「1.9」但真实值是
  /// 1.87，分页按 1.87 量、肉眼看着和 1.9 又不完全一样（"怎么调都不舒服"）。
  Widget _layoutSlider(
    String label,
    double value,
    double min,
    double max,
    String display,
    ValueChanged<double> onChanged, {
    double? step,
  }) {
    final st = step ?? (max - min) / 20;
    double snap(double v) =>
        ((v / st).round() * st).clamp(min, max).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: TextStyle(fontSize: AppTheme.fontBody, color: _fg),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: (v) => onChanged(snap(v)),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => onChanged(snap(value - st)),
            icon: Icon(Icons.remove, size: 17, color: _fgMuted),
          ),
          SizedBox(
            width: 46,
            child: Text(
              display,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w600,
                color: _fg,
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => onChanged(snap(value + st)),
            icon: Icon(Icons.add, size: 17, color: _fgMuted),
          ),
        ],
      ),
    );
  }

  /// 朗读面板（截图 IMG_8082~8085）—— **真的能发声**。
  ///
  /// ── 声音从哪来 ────────────────────────────────────────────────
  /// iOS 端 `ios/Runner/TtsEngine.swift` 用系统自带 `AVSpeechSynthesizer`
  /// 实现，已在 AppDelegate 注册；这里通过 `TtsService` 驱动。
  ///
  /// ⚠️ **不要引 flutter_tts**：TrollStore 侧载不能新增原生插件，
  /// 新增 pub 依赖若没重新 pod install → 插件库不被链接 → 启动闪退。
  ///
  /// ── 4 个分段 ──────────────────────────────────────────────────
  ///   声音：语速 / 音调 / 音量（真接 TtsService）+ 朗读引擎入口
  ///   跟读：高亮 关/当前句/当前段 + 样式 + 6 色 + 范围 本章/整本
  ///   定时：关/15/30/45/60/90 分钟 + 读完本章
  ///   高级：点朗读进播放页 / 自动定位阅读位置
  void _showTtsSheet() {
    var tab = 0;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void upd(VoidCallback fn) {
            setSheet(() {});
            setState(fn);
            _scheduleSavePrefs();
          }

          return Container(
            constraints:
                // 最高半屏（用户 2026-10-12）
                BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
            decoration: BoxDecoration(
              color: _bgTop,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标题 + 独立设置
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 16, 4),
                    child: Row(
                      children: [
                        Text(
                          '朗读',
                          style: TextStyle(
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.w700,
                            color: _fg,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '独立设置',
                          style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            color: _fgMuted,
                          ),
                        ),
                        const SizedBox(width: 4),
                        // ✅ 与排版行的「独立排版」同源（同一个 `_independent` ✓），已接线：
                        //   拨动即写 / 删 `BsrIndependentLayout` 的本书记录 ✓。
                        SizedBox(
                          width: 46,
                          height: 30,
                          child: FittedBox(
                            child: Switch(
                              value: _independent,
                              activeThumbColor: _bgTop,
                              activeTrackColor: _fg.withValues(alpha: 0.85),
                              inactiveThumbColor: _bgTop,
                              inactiveTrackColor: _fg.withValues(alpha: 0.16),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: (v) async {
                                setState(() => _independent = v);
                                if (v) {
                                  await BsrIndependentLayout.instance.enable(
                                    _indepKey,
                                    _layoutSnapshot(),
                                  );
                                } else {
                                  await BsrIndependentLayout.instance.disable(
                                    _indepKey,
                                  );
                                }
                                _scheduleSavePrefs();
                                if (mounted) setState(() {});
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 正在念的那句
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                    child: Obx(() {
                      final i = _tts.currentIndex.value;
                      final s = _ttsSegments;
                      final cur = (i >= 0 && i < s.length) ? s[i] : '';
                      return Text(
                        cur.isEmpty ? '点下方播放开始朗读本章' : cur,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          height: 1.5,
                          color: _fgMuted,
                        ),
                      );
                    }),
                  ),
                  // 播放控制
                  Obx(() {
                    final speaking = _tts.isSpeaking.value;
                    final paused = _tts.isPaused.value;
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          onPressed: () =>
                              _tts.jumpTo(_tts.currentIndex.value - 1),
                          icon: Icon(
                            Icons.skip_previous_rounded,
                            size: 30,
                            color: _fgMuted,
                          ),
                        ),
                        const SizedBox(width: 18),
                        GestureDetector(
                          onTap: () {
                            if (speaking) {
                              _tts.pause();
                            } else if (paused) {
                              _tts.resume();
                            } else {
                              _startTts();
                            }
                          },
                          child: Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: _fg.withValues(alpha: 0.92),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              speaking
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 30,
                              color: _bgTop,
                            ),
                          ),
                        ),
                        const SizedBox(width: 18),
                        IconButton(
                          onPressed: () =>
                              _tts.jumpTo(_tts.currentIndex.value + 1),
                          icon: Icon(
                            Icons.skip_next_rounded,
                            size: 30,
                            color: _fgMuted,
                          ),
                        ),
                      ],
                    );
                  }),
                  const SizedBox(height: 6),
                  // 4 个分段
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (var i = 0; i < _ttsTabs.length; i++)
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setSheet(() => tab = i),
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 9,
                                ),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: tab == i
                                      ? _fg.withValues(alpha: 0.85)
                                      : _fg.withValues(alpha: 0.06),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  _ttsTabs[i],
                                  style: TextStyle(
                                    fontSize: AppTheme.fontBody,
                                    fontWeight: tab == i
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                    color: tab == i ? _bgTop : _fg,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (tab == 0) ..._ttsVoiceTab(upd),
                          if (tab == 1) ..._ttsFollowTab(upd),
                          if (tab == 2) ..._ttsTimerTab(upd),
                          if (tab == 3) ..._ttsAdvancedTab(),
                        ],
                      ),
                    ),
                  ),
                  // 底部：停止朗读 · 收起
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: () {
                            _tts.stop();
                            setSheet(() {});
                          },
                          child: Text(
                            '停止朗读',
                            style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              color: _fg,
                            ),
                          ),
                        ),
                        const Spacer(),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: FilledButton.styleFrom(
                            backgroundColor: _fg.withValues(alpha: 0.9),
                            foregroundColor: _bgTop,
                          ),
                          child: const Text('收起'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

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

  /// 开始朗读本章
  Future<void> _startTts() async {
    // 朗读与自动翻页互斥（否则会出现"念着念着又被翻走"）
    _stopAutoRead();
    final text = _paragraphs.join('\n');
    if (text.trim().isEmpty) {
      _toast('这一章没有可朗读的正文');
      return;
    }
    // 念完自动进下一章（长按连续听书）
    _tts.onFinished = () {
      if (!mounted) return;
      // 已是最后一章 → 不预约（否则 `_go` 会被拒绝，标记会残留到下次加载）
      if (_index + 1 >= widget.chapters.length) return;
      _ttsAutoNext = true;
      _go(1); // 只发起加载；续读交给 `_loadChapter` 正文就绪处
    };
    // TtsService 自己切段（splitSegments 会按标点再切过长段）
    // A4 双音色：逐段音色覆盖（对话段 → 对话音色，其余 → 旁白音色）✓
    _tts.setNowPlayingMeta(widget.bookName, widget.chapters[_index].name);
    await _tts.speak(text, segmentVoices: _buildSegmentVoices());
    if (mounted) setState(() {});
  }

  /// A4：按段生成音色覆盖（双音色关 → null；开 → 对话段/旁白段各用对应音色；
  /// 音色名为空 → 该段用源默认，不强制覆盖 ✓）。
  List<String?>? _buildSegmentVoices() {
    if (!_ttsDualVoice) return null;
    final segs = _ttsSegments;
    if (segs.isEmpty) return null;
    return segs
        .map((s) {
          final isDialogue =
              paragraphKindOf(s.trim()) == ParagraphKind.dialogue;
          final v = isDialogue ? _ttsDialogueVoice : _ttsNarratorVoice;
          return v.trim().isEmpty ? null : v.trim();
        })
        .toList(growable: false);
  }

  List<Widget> _ttsVoiceTab(void Function(VoidCallback) upd) {
    return [
      // ── 语速 / 音调 / 音量（参考图 IMG_8489 的 − 值 + 样式）──
      Obx(
        () => _ttsStepper(
          '语速',
          '${_tts.rate.value.toStringAsFixed(2)}x',
          onMinus: () {
            upd(() {});
            _tts.setRate((_tts.rate.value - 0.05).clamp(0.5, 2.0));
          },
          onPlus: () {
            upd(() {});
            _tts.setRate((_tts.rate.value + 0.05).clamp(0.5, 2.0));
          },
        ),
      ),
      Obx(
        () => _ttsStepper(
          '音调',
          _tts.pitch.value.toStringAsFixed(2),
          onMinus: () {
            upd(() {});
            _tts.setPitch((_tts.pitch.value - 0.05).clamp(0.5, 2.0));
          },
          onPlus: () {
            upd(() {});
            _tts.setPitch((_tts.pitch.value + 0.05).clamp(0.5, 2.0));
          },
        ),
      ),
      _ttsStepper(
        '音量',
        '$_ttsVolume%',
        onMinus: () {
          upd(() => _ttsVolume = (_ttsVolume - 5).clamp(0, 100));
        },
        onPlus: () {
          upd(() => _ttsVolume = (_ttsVolume + 5).clamp(0, 100));
        },
      ),
      const SizedBox(height: 6),
      Divider(color: _fg.withValues(alpha: 0.10)),
      // ── 音色（参考图 IMG_8488：音色（共1个）/ 系统朗读 / 跟随系统）──
      InkWell(
        onTap: () => _showTtsVoicePanel(),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Icon(Icons.face_rounded, size: 20, color: _fg),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '音色',
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: _fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _ttsFollowSystem ? '系统朗读 · 跟随系统' : '系统朗读',
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: _fgMuted,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                '1个',
                style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: _fgMuted),
            ],
          ),
        ),
      ),
      Divider(color: _fg.withValues(alpha: 0.10)),
      // ── A4 双音色朗读（旁白/对话各一音色，EasyVoice 网络源生效）──
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(Icons.graphic_eq_rounded, size: 20, color: _fg),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '双音色朗读',
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: _fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '旁白与对话各配一个音色（EasyVoice 源生效）',
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: _fgMuted,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: _ttsDualVoice,
              onChanged: (v) => upd(() => _ttsDualVoice = v),
            ),
          ],
        ),
      ),
      if (_ttsDualVoice) ...[
        _ttsVoiceField('旁白音色', _ttsNarratorCtl, () {
          _ttsNarratorVoice = _ttsNarratorCtl.text.trim();
          _scheduleSavePrefs();
        }),
        _ttsVoiceField('对话音色', _ttsDialogueCtl, () {
          _ttsDialogueVoice = _ttsDialogueCtl.text.trim();
          _scheduleSavePrefs();
        }),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '留空 = 该角色用源默认音色；例如 zh-CN-XiaoxiaoNeural',
            style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted),
          ),
        ),
      ],
      Divider(color: _fg.withValues(alpha: 0.10)),
      // ── 朗读引擎（参考图 IMG_8489：更换 / 试听）──
      InkWell(
        onTap: () async {
          Navigator.pop(context);
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const TtsEnginePage()),
          );
          if (mounted) setState(() {});
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Icon(Icons.record_voice_over_rounded, size: 20, color: _fg),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '朗读引擎',
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: _fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '系统朗读 · 跟随系统',
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: _fgMuted,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => _ttsSpeakSample(),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _fg.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    '试听',
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      color: _fg,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '更换',
                style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: _fgMuted),
            ],
          ),
        ),
      ),
      Divider(color: _fg.withValues(alpha: 0.10)),
      Text(
        '音量由系统控制，此处仅记录偏好。'
        '语速/音调改完立刻对下一句生效。',
        style: TextStyle(
          fontSize: AppTheme.fontFootnote,
          height: 1.7,
          color: _fgMuted,
        ),
      ),
    ];
  }

  /// 朗读面板里的「− 值 +」步进行（参考图 IMG_8489）
  Widget _ttsStepper(
    String label,
    String display, {
    required VoidCallback onMinus,
    required VoidCallback onPlus,
  }) {
    Widget btn(IconData icon, VoidCallback onTap) => GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _fg.withValues(alpha: 0.08),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 16, color: _fg),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(
              label,
              style: TextStyle(fontSize: AppTheme.fontBody, color: _fg),
            ),
          ),
          const Spacer(),
          btn(Icons.remove_rounded, onMinus),
          Container(
            width: 76,
            alignment: Alignment.center,
            child: Text(
              display,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w600,
                color: _fg,
              ),
            ),
          ),
          btn(Icons.add_rounded, onPlus),
        ],
      ),
    );
  }

  /// 音色面板（参考图 IMG_8488）
  void _showTtsVoicePanel() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void upd(VoidCallback fn) {
            setSheet(() {});
            setState(fn);
            _scheduleSavePrefs();
          }

          return Container(
            constraints: BoxConstraints(
              // 最高半屏（用户 2026-10-12）
              maxHeight: MediaQuery.of(ctx).size.height * 0.5,
            ),
            decoration: BoxDecoration(
              color: _bgTop,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(22),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                    child: Row(
                      children: [
                        Text(
                          '音色（共 1 个）',
                          style: TextStyle(
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.w700,
                            color: _fg,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => Navigator.pop(ctx),
                          child: Icon(
                            Icons.expand_more_rounded,
                            size: 26,
                            color: _fgMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                    child: Text(
                      '音色跟随系统设置 · 文字转语音；换引擎在朗读引擎设置里',
                      style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        height: 1.5,
                        color: _fgMuted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 系统朗读
                  InkWell(
                    onTap: () => upd(() => _ttsFollowSystem = false),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.record_voice_over_rounded,
                            size: 20,
                            color: _fg,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '系统朗读',
                              style: TextStyle(
                                fontSize: AppTheme.fontBody,
                                fontWeight: FontWeight.w600,
                                color: _fg,
                              ),
                            ),
                          ),
                          Icon(
                            !_ttsFollowSystem
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            size: 20,
                            color: !_ttsFollowSystem
                                ? JellyTheme.primary
                                : _fgMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Divider(
                    color: _fg.withValues(alpha: 0.08),
                    indent: 20,
                    endIndent: 20,
                  ),
                  // 跟随系统
                  InkWell(
                    onTap: () => upd(() => _ttsFollowSystem = true),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.settings_suggest_rounded,
                            size: 20,
                            color: _fg,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '跟随系统',
                                  style: TextStyle(
                                    fontSize: AppTheme.fontBody,
                                    fontWeight: FontWeight.w600,
                                    color: _fg,
                                  ),
                                ),
                                Text(
                                  '用系统当前默认音色',
                                  style: TextStyle(
                                    fontSize: AppTheme.fontFootnote,
                                    color: _fgMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            _ttsFollowSystem
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            size: 20,
                            color: _ttsFollowSystem
                                ? JellyTheme.primary
                                : _fgMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 试听：念当前正在读的一句（没有就念第一句）
  void _ttsSpeakSample() {
    if (_tts.isSpeaking.value) {
      _toast('正在朗读中，可先暂停');
      return;
    }
    final s = _ttsSegments;
    if (s.isEmpty) return;
    _tts.speak(s[0], startAt: 0);
    setState(() {});
  }

  /// A4：双音色音色名输入行
  Widget _ttsVoiceField(
    String label,
    TextEditingController ctl,
    VoidCallback onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(fontSize: AppTheme.fontBody, color: _fg),
            ),
          ),
          Expanded(
            child: TextField(
              controller: ctl,
              style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg),
              decoration: InputDecoration(
                isDense: true,
                hintText: '空 = 用源默认音色',
                hintStyle: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  color: _fgMuted,
                ),
                filled: true,
                fillColor: _fg.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              onChanged: (_) => onChanged(),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _ttsFollowTab(void Function(VoidCallback) upd) {
    const styles = ['◆', '✎', 'U', '···', '—', '=', '≈'];
    const colors = [
      Color(0xFFF5C842),
      Color(0xFF8FD48F),
      Color(0xFF7EC8F0),
      Color(0xFFF07E9E),
      Color(0xFFC88FE8),
      Color(0xFFA8B4E0),
    ];
    return [
      _ttsLabel('高亮'),
      Row(
        children: [
          for (var i = 0; i < 3; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => upd(() => _ttsHighlight = i),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _ttsHighlight == i
                        ? _fg.withValues(alpha: 0.85)
                        : _fg.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    ['关', '当前句', '当前段'][i],
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: _ttsHighlight == i ? _bgTop : _fg,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      // ⚠️ **本格原来是个"假控件"** ✗（与今天清理的假开关同类 ✓）：
      //   ① `onTap: () => upd(() {})` ✓ —— 点了**只重绘、不改任何状态** ✗
      //   ② 选中态**写死 `i == 0`** ✗ → 看起来"第 1 个永远选中" ✓，点别的没反应 ✗✗
      // ✅ **本轮按代码事实处理** ✓（不改后端、不硬造能力 ✗）：
      //   · 底层**没有"风格/情感"参数** ✗ —— `TtsService` 对 EasyVoice 只传
      //     **`voice`（音色）/ `rate`（语速）/ `pitch`（音调）** ✓（`tts_service.dart:358-360` ✓），
      //     所以这排 chip 无论怎么点都**驱动不了任何东西** ✗。
      //   · 而**音色选择本来就有真正的入口** ✓✓：**「朗读引擎」页** ✓
      //     （选 easyvoice 源 ✓ → 「拉取音色列表」✓ → 写进 `src.voice` ✓，我核实过那是真实现 ✓）。
      //   ⇒ 因此这里**不再假装可切** ✓：chips 变成**禁用外观** ✓ 并指向真入口 ✓。
      _ttsLabel(
        '样式：EasyVoice 只有「音色 / 语速 / 音调」✓ —— '
        '音色请到「朗读引擎」页选源并拉取 ✓（本格无"风格/情感"参数 ✗）',
      ),
      Row(
        children: [
          for (var i = 0; i < styles.length; i++)
            GestureDetector(
              // ⛔ **有意不响应** ✗✓：底层无此参数，做成可点就是新的假控件 ✗
              onTap: null,
              child: Container(
                width: 36,
                height: 36,
                margin: const EdgeInsets.only(right: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  // 统一"禁用"外观 ✓（不再有"第 1 个被选中"的假象 ✗）
                  color: _fg.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  styles[i],
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    color: _fg.withValues(alpha: 0.35),
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      _ttsLabel('颜色'),
      Row(
        children: [
          for (var i = 0; i < colors.length; i++)
            GestureDetector(
              onTap: () => upd(() => _ttsColor = i),
              child: Container(
                width: 32,
                height: 32,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: colors[i],
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _ttsColor == i ? _fg : _fg.withValues(alpha: 0.15),
                    width: _ttsColor == i ? 2.5 : 1,
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      // 🔴 下面这个「本章 / 整本」选择器是**纯装饰** ✗，两个毛病都在这一处：
      //   ① `onTap: () => upd(() {})` ✓ —— 点了只重绘、**不改任何状态** ✓，
      //      也就是说这个"选择"从来没有被存下来、也没人读它 ✗
      //   ② 而「整本」那一格的底色是**写死的 `alpha: 0.85`** ✗ → 不管选没选
      //      都画成"高亮已选中" ✓（用户会以为"整本朗读"是开着的 ✗）
      // ✓ 先把范围标签如实写明（功能未接入 ✓，不假装能选 ✓）
      // ⚠️ 遗留：要真做"整本朗读"需把选择接进 `_ttsSegments` 的构造 ✓
      //   （让它跨章拼段 ✓）—— 那是一次功能改动，不是文案 ✓
      // ⚠️ 上面那句「范围（本章 ✓ 整本未接入 ✗）」**原来是不准的** ✗ —— 已按代码事实改正 ✓：
      //   本页 `_startTts()`（`:3848-3866` ✓）里 **`onFinished` → `_go(1)` → 自动 `_startTts()`** ✓✓，
      //   注释自己写着「**念完自动进下一章（长按连续听书）**」✓ —— 也就是**整本连读本来就实现了** ✓。
      //   而"到哪儿停"也有现成开关 ✓：「**定时**」页的「**读完本章**」选项 ✓
      //   ⇒ 选它 = 读完本章停 ✓；不选 = 一路连到全书 ✓✓ **两种模式都在** ✓。
      _ttsLabel('范围（本章 ✓ 整本连读 ✓ —— 用「定时」页的「读完本章」决定到哪停）'),
      Row(
        children: [
          for (final n in ['本章', '整本'])
            Expanded(
              child: GestureDetector(
                onTap: () => upd(() {}),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: n == '本章'
                        ? _fg.withValues(alpha: 0.06)
                        : _fg.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    n,
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: n == '本章' ? _fg : _bgTop,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        '跟读高亮会在正文里给正在念的句子加底色，方便对照着听。',
        style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted),
      ),
    ];
  }

  List<Widget> _ttsTimerTab(void Function(VoidCallback) upd) {
    return [
      _ttsLabel('定时'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final m in [0, 15, 30, 45, 60, 90])
            GestureDetector(
              onTap: () {
                upd(() => _ttsTimer = m);
                _scheduleTtsTimer(m);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _ttsTimer == m
                      ? _fg.withValues(alpha: 0.85)
                      : _fg.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  m == 0 ? '关' : '$m 分钟',
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: _ttsTimer == m ? _bgTop : _fg,
                  ),
                ),
              ),
            ),
          GestureDetector(
            onTap: () => upd(() => _ttsTimer = -1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: _ttsTimer == -1
                    ? _fg.withValues(alpha: 0.85)
                    : _fg.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '读完本章',
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: _ttsTimer == -1 ? _bgTop : _fg,
                ),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        '定时到点为暂停，按播放键即接着读。',
        style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted),
      ),
    ];
  }

  List<Widget> _ttsAdvancedTab() {
    return [
      // 🔴 下面两个开关是**纯装饰** ✗：喂进来的 `value` 是**写死的 `false`** ✓，
      // 而 `_ttsSwitch` 内部固定 `onChanged: null`（`:4263` ✓）→
      // 开关**永远显示"关"、且永远点不动** ✓，可 `sub` 文案却写着"开启后…" ✗
      // → 用户会一直找不到"在哪儿开" ✓。
      // ✓ 先如实标注（标题加"未接入" ✓）。
      // ⚠️ 遗留：真正接线要把它们变成**真实设置**（落盘 + 被 TTS 逻辑读取 ✓，
      //   例如"点朗读是否直接进播放页" / "朗读是否自动翻页" ✓）—— 功能改动 ✓
      // ✅ 这两个开关**已完全接通** ✓（本轮收尾 ✓）：`value` 取真实字段 ✓、`onChanged` 改值并落盘 ✓，
      //   而且**行为也接了** ✓✓ ——
      //     · 「点朗读进播放页」→ 朗读格按它分派 ✓（开启时直达 `TtsFullPlayerPage` ✓，见 `:1948` 一带 ✓）
      //     · 「自动定位阅读位置」→ 跟读高亮的 `Obx` 里按它滚动 ✓（`_wrapWithHighlight` ✓ `:1247` ✓）
      //   ⇒ **标注已摘掉** ✓（原先写的「行为待接 ✗」现在已不成立 ✗ → 不摘就是新的假话 ✓）。
      _ttsSwitch(
        '点朗读进播放页',
        '开启后点底栏「朗读」直接进沉浸式播放页'
            '（封面+当前句大字）；关闭时也可从播放条上的唱片键进入',
        _ttsDirectPlayer,
        onChanged: (v) => setState(() {
          _ttsDirectPlayer = v;
          _scheduleSavePrefs();
        }),
      ),
      _ttsSwitch(
        '自动定位阅读位置',
        '朗读时自动翻到正在读的那一页；'
            '关闭后由播放条上的定位键手动跳',
        _ttsAutoLocate,
        onChanged: (v) => setState(() {
          _ttsAutoLocate = v;
          _scheduleSavePrefs();
        }),
      ),
    ];
  }

  /// 定时器：到点暂停
  void _scheduleTtsTimer(int minutes) {
    _ttsTimerHandle?.cancel();
    if (minutes <= 0) return;
    _ttsTimerHandle = Timer(Duration(minutes: minutes), () {
      if (mounted && _tts.isSpeaking.value) _tts.pause();
    });
  }

  Timer? _ttsTimerHandle;

  Widget _ttsLabel(String s) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      s,
      style: TextStyle(
        fontSize: AppTheme.fontBody,
        fontWeight: FontWeight.w600,
        color: _fg,
      ),
    ),
  );

  /// 朗读面板里的一个开关行 ✓。
  ///
  /// ✅ **本轮新增 `onChanged`** ✓ —— 此前它把开关的 `onChanged` **写死为 `null`** ✗，
  ///   于是「高级」页里凡是走它的开关都**永远显示关闭、而且永远点不动** ✗✗
  ///   （`_ttsAdvancedTab` 上方的注释自己也写着"这两个开关是**纯装饰**"✗）。
  ///   ⇒ 现在把回调传进来，它就能变成**真设置** ✓（落盘 ✓ + 被 TTS 逻辑读取 ✓）。
  /// ℹ️ 用**可选参数** ✓：暂时没传 `onChanged` 的调用点行为完全不变（仍不可点 ✓），
  ///   既不会引入编译问题 ✓，也不会误伤害别处"有意禁用"的开关 ⛔（如独立排版/独立设置 ✓）。
  Widget _ttsSwitch(
    String title,
    String sub,
    bool value, {
    ValueChanged<bool>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                    color: _fg,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  sub,
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    height: 1.5,
                    color: _fgMuted,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  /// TtsService 切出来的段落（供面板显示"正在念的那句"）
  /// 缓存同一份切分结果，章节内容变化时清缓存（否则每次访问都全量重切）
  List<String>? _ttsSegsCache;
  List<String> get _ttsSegments {
    final c = _ttsSegsCache;
    if (c != null) return c;
    final s = TtsService.splitSegments(_paragraphs.join('\n'));
    _ttsSegsCache = s;
    return s;
  }

  void _invalidateTtsSegs() => _ttsSegsCache = null;

  /// AI 面板（真实可用）：四个动作走 OpenAI 兼容 chat 接口，
  /// 未配置时引导填写自己的接口地址 / API Key / 模型名。
  void _showAiSummary() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _bgTop,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Text(
                      'AI',
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w700,
                        color: _fg,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'AI 接口配置',
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showAiConfig();
                      },
                      icon: Icon(
                        Icons.settings_outlined,
                        size: 20,
                        color: _fgMuted,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: _fgMuted,
                      ),
                    ),
                  ],
                ),
              ),
              for (final a in ['总结本章', '解释这段', '生成书评', '问答'])
                ListTile(
                  title: Text(
                    a,
                    style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      color: _fg,
                    ),
                  ),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: _fgMuted,
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _runAiAction(a);
                  },
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Text(
                  'AI 调用你自己的对话接口（OpenAI 兼容）。未配置时点动作会先弹配置：'
                  '接口地址 / API Key / 模型名（支持 DeepSeek、通义、智谱、本地 vLLM 等）。',
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    height: 1.7,
                    color: _fgMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// AI 接口配置 sheet：接口地址 / API Key / 模型名
  Future<void> _showAiConfig() async {
    final ai = AiService();
    final baseCtrl = TextEditingController(text: ai.baseUrl);
    final keyCtrl = TextEditingController(text: ai.apiKey);
    final modelCtrl = TextEditingController(text: ai.model);
    final fg = _fg;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _bgTop,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 10,
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI 接口配置',
                  style: TextStyle(
                    fontSize: AppTheme.fontTitle3,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'OpenAI 兼容对话接口，Key 只存在本机。默认填 DeepSeek，'
                  '可改成通义/智谱/Moonshot/本地 vLLM 的地址。',
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    height: 1.6,
                    color: _fgMuted,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: baseCtrl,
                  style: TextStyle(color: fg),
                  decoration: InputDecoration(
                    labelText: '接口地址',
                    hintText: 'https://api.deepseek.com',
                    labelStyle: TextStyle(color: _fgMuted),
                    hintStyle: TextStyle(color: _fgMuted),
                    isDense: true,
                    border: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: _fgMuted.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: keyCtrl,
                  style: TextStyle(color: fg),
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: 'sk-…',
                    labelStyle: TextStyle(color: _fgMuted),
                    hintStyle: TextStyle(color: _fgMuted),
                    isDense: true,
                    border: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: _fgMuted.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: modelCtrl,
                  style: TextStyle(color: fg),
                  decoration: InputDecoration(
                    labelText: '模型名',
                    hintText: 'deepseek-chat',
                    labelStyle: TextStyle(color: _fgMuted),
                    hintStyle: TextStyle(color: _fgMuted),
                    isDense: true,
                    border: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: _fgMuted.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    TextButton(
                      onPressed: () async {
                        if (keyCtrl.text.trim().isEmpty) {
                          _toast('先填 API Key 才能测试');
                          return;
                        }
                        _toast('正在测试连接…');
                        try {
                          final savedBase = baseCtrl.text.trim();
                          final savedKey = keyCtrl.text.trim();
                          final savedModel = modelCtrl.text.trim().isEmpty
                              ? 'deepseek-chat'
                              : modelCtrl.text.trim();
                          // AiService 是**单例** ✓ → 直接改字段会**污染已保存的配置** ✗。
                          // 这里先快照、测完在 finally 还原 ✓（"测试连接"不该改变真实配置 ✓）。
                          final tmp = AiService();
                          final prevBase = tmp.baseUrl;
                          final prevKey = tmp.apiKey;
                          final prevModel = tmp.model;
                          tmp
                            ..baseUrl = savedBase.isEmpty
                                ? 'https://api.deepseek.com'
                                : savedBase
                            ..apiKey = savedKey
                            ..model = savedModel;
                          try {
                            final r = await tmp.chat(
                              system: '你是连接测试助手。',
                              user: '请只回复两个字：正常',
                              timeout: const Duration(seconds: 30),
                            );
                            _toast('连接成功：$r');
                          } finally {
                            tmp
                              ..baseUrl = prevBase
                              ..apiKey = prevKey
                              ..model = prevModel;
                          }
                        } catch (e) {
                          _toast('连接失败：$e');
                        }
                      },
                      child: Text(
                        '测试连接',
                        style: TextStyle(
                          fontSize: 13,
                          color: JellyTheme.primary,
                        ),
                      ),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () async {
                        await ai.saveConfig(
                          baseUrl: baseCtrl.text,
                          apiKey: keyCtrl.text,
                          model: modelCtrl.text,
                        );
                        if (ctx.mounted) Navigator.pop(ctx);
                        _toast('AI 配置已保存');
                      },
                      child: const Text('保存并返回'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 执行 AI 动作：未配置先弹配置；已配置直接调用
  Future<void> _runAiAction(String action) async {
    final ai = AiService();
    if (!ai.isConfigured) {
      _toast('先配置 AI 接口');
      _showAiConfig();
      return;
    }
    if (action == '问答') {
      _askAiQuestion();
      return;
    }
    final chapterText = _paragraphs.join('\n');
    final body = chapterText.length > 8000
        ? chapterText.substring(0, 8000)
        : chapterText;
    if (body.trim().isEmpty) {
      _toast('本章没有可用的正文内容');
      return;
    }
    final String system;
    final String user;
    switch (action) {
      case '总结本章':
        system =
            '你是小说阅读助手。用简体中文给出本章的简洁总结'
            '（人物/事件/伏笔要点，200 字以内）。';
        user = '《${widget.bookName}》本章内容：\n$body';
      case '解释这段':
        system =
            '你是小说阅读助手，用简体中文通俗解释文中的关键剧情'
            '与难懂之处，300 字以内。';
        user = '《${widget.bookName}》本章内容：\n$body';
      case '生成书评':
        system =
            '你是资深书评人，用简体中文写一段 150 字左右的短书评'
            '（风格/亮点/阅读感受）。';
        user = '《${widget.bookName}》本章内容：\n$body';
      default:
        return;
    }
    _showAiLoading(action, () => ai.chat(system: system, user: user));
  }

  /// 问答：先弹输入框，再用本章做上下文回答
  Future<void> _askAiQuestion() async {
    final ai = AiService();
    final ctrl = TextEditingController();
    final question = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _bgTop,
        title: Text('问 AI', style: TextStyle(color: _fg)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: _fg),
          decoration: const InputDecoration(hintText: '输入你的问题'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: _fgMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('提问'),
          ),
        ],
      ),
    );
    if (question == null || question.isEmpty) return;
    final chapterText = _paragraphs.join('\n');
    final body = chapterText.length > 8000
        ? chapterText.substring(0, 8000)
        : chapterText;
    _showAiLoading(
      '问答',
      () => ai.chat(
        system:
            '你是小说阅读助手，基于给出的本章内容用简体中文回答读者问题。'
            '内容无关时如实说明。',
        user: '《${widget.bookName}》本章内容：\n$body\n\n读者问题：$question',
      ),
    );
  }

  /// 调 AI 并展示结果（loading → 结果 sheet / 错误 toast）
  Future<void> _showAiLoading(
    String title,
    Future<String> Function() task,
  ) async {
    final fg = _fg;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: _bgTop,
          content: Row(
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 16),
              Text('$title中…', style: TextStyle(color: fg)),
            ],
          ),
        ),
      ),
    );
    String? result;
    String? error;
    try {
      result = await task();
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    Navigator.pop(context); // 关 loading
    if (error != null) {
      _toast('AI 失败：$error');
      return;
    }
    _showAiResult(title, result ?? '（无返回内容）');
  }

  /// AI 结果展示 sheet（可选中复制）
  void _showAiResult(String title, String content) {
    final fg = _fg;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints:
            // 最高半屏（用户 2026-10-12）
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
        decoration: BoxDecoration(
          color: _bgTop,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
                child: Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w700,
                        color: fg,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '复制结果',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: content));
                        _toast('已复制');
                      },
                      icon: Icon(Icons.copy_rounded, size: 20, color: _fgMuted),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: _fgMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: fg.withValues(alpha: 0.1)),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  child: SelectableText(
                    content,
                    style: TextStyle(fontSize: 14, height: 1.7, color: fg),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 图片模式：把本章的图片单独列出来看/保存。
  ///
  /// 图片来源有三处（去重合并）✓：
  ///   · `_images` —— **纯图章**的正文图片（引擎 `type:'images'`）✓
  ///   · `_chapterImages` —— **文字章**附带的插图（引擎与 content 一起回）✓
  ///   · 正文里的图片 URL —— 契约为纯文本的源，`<img>` 会以文本留下 ✓
  void _showImageMode() {
    final urls = <String>[];
    for (final u in [..._images, ..._chapterImages]) {
      if (u.isNotEmpty && !urls.contains(u)) urls.add(u);
    }
    for (final p in _paragraphs) {
      for (final m in RegExp(
        r'https?://[^\s"'
        '<>]+\.(?:jpg|jpeg|png|gif|webp)',
        caseSensitive: false,
      ).allMatches(p)) {
        final u = m.group(0)!;
        if (!urls.contains(u)) urls.add(u);
      }
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints:
            // 最高半屏（用户 2026-10-12）
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
        decoration: BoxDecoration(
          color: _bgTop,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Text(
                      '图片模式',
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w700,
                        color: _fg,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${urls.length} 张',
                      style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        color: _fgMuted,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: _fgMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: urls.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(40),
                          child: Text(
                            '这一章没有图片。\n\n'
                            '图片模式会把正文里的插图单独列出来看和保存。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              height: 1.7,
                              color: _fgMuted,
                            ),
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                            ),
                        itemCount: urls.length,
                        itemBuilder: (c, i) => GestureDetector(
                          onTap: () => _previewImage(ctx, urls[i]),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.network(
                              urls[i],
                              headers: _mangaHeaders,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: _fg.withValues(alpha: 0.07),
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  size: 22,
                                  color: _fgMuted,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 大图预览 + 保存到相册。
  ///
  /// 下载走 `BookSourceService` 的 dio（带书源的 header，能过防盗链），
  /// 然后交给原生 `saveImage` 写进相册 —— 零插件。
  Future<void> _previewImage(BuildContext parentCtx, String url) async {
    await showDialog<void>(
      context: context,
      // ⚠️ showDialog 没有 backgroundColor（那是 showModalBottomSheet 的参数），
      // 要全屏黑底得自己用 Dialog + insetPadding: zero 撑满
      barrierColor: Colors.black,
      builder: (ctx) => Dialog(
        insetPadding: EdgeInsets.zero,
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: Image.network(
                  url,
                  headers: _mangaHeaders,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            Positioned(
              top: MediaQuery.of(ctx).padding.top + 8,
              right: 12,
              child: IconButton(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(
                  Icons.close_rounded,
                  size: 26,
                  color: Colors.white,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 30,
              child: Center(
                child: FilledButton.icon(
                  onPressed: () async {
                    final ok = await _saveImage(url);
                    if (ok && ctx.mounted) Navigator.pop(ctx);
                  },
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('保存到相册'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 下载并保存一张图到相册。返回是否成功。
  Future<bool> _saveImage(String url) async {
    _toast('正在下载…');
    try {
      // 用引擎的 dio（带书源 header），否则很多图床会 403
      final bytes = await BookSourceService.instance.fetchBytes(
        widget.source,
        url,
        headers: _mangaHeaders,
      );
      if (bytes == null || bytes.isEmpty) {
        _toast('下载失败：图片为空');
        return false;
      }
      final r = await _tts.saveImageToAlbum(bytes);
      if (r.ok) {
        _toast('已保存到相册');
        return true;
      }
      _toast('保存失败：${r.error ?? "未知原因"}');
      return false;
    } catch (e) {
      _toast('保存失败：$e');
      return false;
    }
  }

  /// 跳转到某章节（笔记点击用；分页模式回第一页）。
  Future<void> _jumpToChapter(int chapterIndex) async {
    if (chapterIndex < 0 || chapterIndex >= widget.chapters.length) return;
    if (_index != chapterIndex) {
      _index = chapterIndex;
      await _loadChapter(_index);
      await _saveProgress();
      if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(0);
    }
    _toast('已跳转到${widget.chapters[chapterIndex].name}');
  }

  /// 阅读设置面板（截图 IMG_71a10）。
  ///
  /// ── 与旧面板的区别 ────────────────────────────────────────────
  /// 旧面板只有"字号 + 行距"两根滑杆。截图里这一整页是**8 组设置**：
  ///   阅读模式 / 翻页反转 / 单手模式 / 点击区域 / 双页模式 /
  ///   信息栏（6 项可逐项开关）/ 音量键翻页 / 屏幕休眠
  /// 底部：取消 · 排版 · 确认
  ///
  /// 其中"阅读模式"是真的会影响渲染的（见 _contentArea）：
  /// 上下 = 不分页改滚动；其余 4 种 = 分页。
  Widget _settingsPanel(Color fg, {double extraBottom = 0}) {
    return Positioned(
      // 面板已在 SafeArea 之外（见 build 末尾）⇒ 这里 bottom:0 就是屏幕最底部 ✓
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        constraints:
            // 最高半屏（用户 2026-10-12）
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
        decoration: BoxDecoration(
          color: _sheetBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 32,
              offset: const Offset(0, -10),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          // 兜底：padding 报 0 时也要给 Home 指示条留出位置（见 build 里的说明）
          minimum: EdgeInsets.only(bottom: extraBottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetHandle(),
              // 标题：阅读设置 + 独立设置
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 16, 10),
                child: Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '阅读设置',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                            color: _fg,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '翻页 · 信息栏 · 文本',
                          style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 0.2,
                            color: _fg.withValues(alpha: 0.45),
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      '独立设置',
                      style: TextStyle(
                        fontSize: 12,
                        color: _fgMuted,
                      ),
                    ),
                    const SizedBox(width: 4),
                    // ✅ 三处「独立设置 / 独立排版」共用同一个 `_independent` ✓，均已接线：
                    //   拨动即写 / 删 `BsrIndependentLayout` 的本书记录，`_restorePrefs` 读回 ✓。
                    SizedBox(
                      width: 46,
                      height: 30,
                      child: FittedBox(
                        child: Switch(
                          value: _independent,
                          activeThumbColor: _bgTop,
                          activeTrackColor: _fg.withValues(alpha: 0.85),
                          inactiveThumbColor: _bgTop,
                          inactiveTrackColor: _fg.withValues(alpha: 0.16),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onChanged: (v) => _setIndependent(v),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 标题与内容之间的分隔线（滚动时不会和标题糊在一起）
              Divider(
                height: 1,
                thickness: 0.5,
                color: _fg.withValues(alpha: 0.08),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  children: [
                    // ── 阅读模式（5 种）────────────────────────
                    _sectionLabel('翻页'),
                    // 阅读模式：标签在左、5 个模式块在右（同一行，截图如此）。
                    // 用户 2026-10-15：纯文字 chip 辨识度差 ⇒ 换成
                    // 「图标 + 名称」的等宽小块（JellyModePicker）。
                    _setRowRight(
                      '阅读模式',
                      JellyModePicker(
                        fg: _fg,
                        // 用户 2026-10-21：模式按钮上不要那个符号/图标，只留文字
                        showSymbol: false,
                        items: [
                          for (final m in PageMode.values)
                            JellyModeItem(
                              label: m.label,
                              symbol: pageModeSymbol(m),
                              selected: _rs.pageMode == m,
                              onTap: () {
                                setState(() => _rs = _rs.copyWith(pageMode: m));
                                _scheduleSavePrefs();
                                // 模式变了要重新分页（上下模式不分页）
                                _paginate();
                              },
                            ),
                        ],
                      ),
                    ),
                    // ── 自动阅读（对齐 Legado：按间隔自动翻页/滚屏）────
                    _setRowRight(
                      '自动阅读',
                      _chip(
                        _autoReadOn ? '停止' : '开始',
                        _autoReadOn,
                        () {
                          _toggleAutoRead();
                        },
                        compact: true,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 82,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                '翻页间隔',
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: _fg,
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final s in const [3, 5, 8, 12, 20, 30])
                                  _chip(
                                    '$s 秒',
                                    _rs.autoReadIntervalSec == s,
                                    () {
                                      setState(
                                        () => _rs = _rs.copyWith(
                                          autoReadIntervalSec: s,
                                        ),
                                      );
                                      _scheduleSavePrefs();
                                      if (_autoReadOn) {
                                        _scheduleAutoRead();
                                      }
                                    },
                                    compact: true,
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    // ── 预取与缓存（对齐 Legado：预下载 N 章 + 仅 WiFi）──
                    _setRowRight(
                      '预取章节',
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final n in const [0, 1, 2, 3, 5])
                            _chip(
                              '$n 章',
                              _rs.preloadChapters == n,
                              () {
                                setState(
                                  () => _rs = _rs.copyWith(preloadChapters: n),
                                );
                                _scheduleSavePrefs();
                                // 立刻按新设置补预取，不用等翻章
                                if (n > 0) _prefetchAhead(_index);
                              },
                              compact: true,
                            ),
                        ],
                      ),
                    ),
                    _setRowRight(
                      '仅 WiFi 预取',
                      Switch.adaptive(
                        value: _rs.preloadWifiOnly,
                        onChanged: (v) {
                          setState(
                            () => _rs = _rs.copyWith(preloadWifiOnly: v),
                          );
                          _scheduleSavePrefs();
                        },
                      ),
                    ),
                    _setRowRight(
                      '章节缓存',
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${_cache.length} 章',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: _fg.withValues(alpha: 0.55),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _chip('清空', false, _clearChapterCache, compact: true),
                        ],
                      ),
                    ),
                    // ── 正文替换（对齐参考图：已启用 N 条规则 + 管理）──
                    _setRowRight(
                      '正文替换',
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '已启用 '
                            '${_rs.purifyRules.where((r) => r.enabled).length}'
                            ' 条规则',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: _fg.withValues(alpha: 0.55),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _chip('管理', false, _showPurifySheet, compact: true),
                        ],
                      ),
                    ),
                    // 点击区域：进入 3×3 编辑页（截图 IMG_8117）
                    InkWell(
                      onTap: _showTapZoneEditor,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            Text(
                              '点击区域',
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: _fg,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '自定义各区域触发上一页/菜单/下一页',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: _fg.withValues(alpha: 0.5),
                                ),
                              ),
                            ),
                            Icon(
                              Icons.grid_view_rounded,
                              size: 20,
                              color: _fgMuted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // ── 简繁转换（位置对齐参考图：紧跟在点击区域之后）──
                    _setRowRight(
                      '简繁转换',
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final cm in ChineseConvertMode.values)
                            _chip(_convertLabel(cm), _rs.convertMode == cm, () {
                              setState(
                                () => _rs = _rs.copyWith(convertMode: cm),
                              );
                              _scheduleSavePrefs();
                              _invalidateTtsSegs();
                              // 从**原文缓存**重转（不改缓存），保留锚点重排 ✓
                              if (_cache.containsKey(_index)) {
                                _paragraphs = _applyConvert(_cache[_index]!);
                              }
                              _repaginateLayout();
                            }, compact: true),
                        ],
                      ),
                    ),
                    // ── 屏幕休眠（对齐参考图：简繁转换之后）────────
                    _setRowRight(
                      '屏幕休眠',
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final s in SleepMode.values)
                            _chip(s.label, _rs.sleepMode == s, () {
                              setState(() => _rs = _rs.copyWith(sleepMode: s));
                              _scheduleSavePrefs();
                              _applySleepMode();
                            }, compact: true),
                        ],
                      ),
                    ),
                    _setSwitch('翻页反转', '左点下一页、右点上一页', _rs.flipReverse, (v) {
                      setState(() => _rs = _rs.copyWith(flipReverse: v));
                      _scheduleSavePrefs();
                    }),
                    _setSwitch('单手模式', '屏幕左右点击都是下一页', _rs.oneHand, (v) {
                      setState(() => _rs = _rs.copyWith(oneHand: v));
                      _scheduleSavePrefs();
                    }),
                    // 查看插图（对齐参考图）：正文末展示本章插图，点开可放大
                    _setSwitch(
                      '查看插图',
                      '在正文末尾展示本章插图，点击放大查看',
                      _rs.showIllustrations,
                      (v) {
                        setState(
                          () => _rs = _rs.copyWith(showIllustrations: v),
                        );
                        _scheduleSavePrefs();
                        _repaginateLayout();
                      },
                    ),
                    _setSwitch('双页模式', '横屏左右并排（上下模式除外）', _rs.dualPage, (v) {
                      setState(() => _rs = _rs.copyWith(dualPage: v));
                      _scheduleSavePrefs();
                    }),
                    // ── 信息栏（6 项逐项开关）──────────────────
                    _sectionLabel('信息栏'),
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 6),
                      child: Row(
                        children: [
                          Text(
                            '信息栏',
                            style: TextStyle(
                              fontSize: AppTheme.fontHeadline,
                              color: _fg,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '页眉页脚显示的信息，可逐项开关',
                              style: TextStyle(
                                fontSize: AppTheme.fontSubhead,
                                color: _fgMuted,
                              ),
                            ),
                          ),
                          // 总开关：一键显示/隐藏整条信息栏（全不选 = 隐藏）
                          Switch(
                            value: _rs.statusItems.isNotEmpty,
                            onChanged: (v) {
                              setState(
                                () => _rs = _rs.copyWith(
                                  statusItems: v
                                      ? const {'章节', '页码', '进度'}
                                      : <String>{},
                                ),
                              );
                              _scheduleSavePrefs();
                              _repaginateLayout();
                            },
                          ),
                        ],
                      ),
                    ),
                    // 信息栏选项：**横向滑动**（用户 2026-10-21 参考图）
                    // 一行放不下时左右滑，而不是换行把面板撑高 ✓
                    SizedBox(
                      height: 38,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        itemCount: _statusItemKeys.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (c, i) {
                          final k = _statusItemKeys[i];
                          return Center(
                            child: _chip(k, _rs.statusItems.contains(k), () {
                              final next = Set<String>.of(_rs.statusItems);
                              if (!next.remove(k)) next.add(k);
                              setState(
                                () => _rs = _rs.copyWith(statusItems: next),
                              );
                              _scheduleSavePrefs();
                            }),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 信息栏字号/图标缩放（用户 2026-10-21）
                    _setRowRight(
                      '信息栏字号',
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final e in const [
                            ('小', 0.85),
                            ('标准', 1.0),
                            ('大', 1.15),
                            ('超大', 1.3),
                          ])
                            _chip(
                              e.$1,
                              (_rs.statusTextScale - e.$2).abs() < 0.01,
                              () {
                                setState(
                                  () => _rs = _rs.copyWith(
                                    statusTextScale: e.$2,
                                  ),
                                );
                                _scheduleSavePrefs();
                                // 页脚高了/矮了 ⇒ 正文可用高度变了，要重排
                                _repaginateLayout();
                              },
                              compact: true,
                            ),
                        ],
                      ),
                    ),
                    // 隐藏系统状态栏（沉浸全屏，用户 2026-10-21）
                    _setSwitch(
                      '隐藏状态栏',
                      '阅读时全屏，不显示手机顶部状态栏',
                      _rs.hideStatusBar,
                      (v) {
                        setState(() => _rs = _rs.copyWith(hideStatusBar: v));
                        _scheduleSavePrefs();
                        _applyReaderSystemUi();
                      },
                    ),
                    const SizedBox(height: 8),
                    _sectionLabel('其他'),
                    _setSwitch('音量键翻页', '按音量上/下键翻页（会接管音量键）', _rs.volumeKeys, (
                      v,
                    ) {
                      setState(() => _rs = _rs.copyWith(volumeKeys: v));
                      _scheduleSavePrefs();
                    }),
                    // ── A1 对话气泡（Cmbok 差距文档）────────────
                    _setRowRight(
                      '对话气泡',
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final bm in BubbleMode.values)
                            _chip(bm.label, _rs.bubbleMode == bm, () {
                              setState(
                                () => _rs = _rs.copyWith(bubbleMode: bm),
                              );
                              _scheduleSavePrefs();
                              // 🔴 必须重排：气泡把对话段落**变窄 ⇒ 折行更多、更高** ✗
                              //    ⇒ 沿用旧分页会立刻溢出屏幕 ✗（用户实测的
                              //    "弄成对话气泡后容易出整个屏幕" 一半来自这里 ✓）
                              _repaginateLayout();
                            }, compact: true),
                        ],
                      ),
                    ),
                    if (_rs.bubbleMode != BubbleMode.none)
                      _setRowRight(
                        '气泡配色',
                        Wrap(
                          spacing: 6,
                          children: [
                            for (final bp in BubblePalette.values)
                              _chip(bp.label, _rs.bubblePalette == bp, () {
                                setState(
                                  () => _rs = _rs.copyWith(bubblePalette: bp),
                                );
                                _scheduleSavePrefs();
                              }, compact: true),
                          ],
                        ),
                      ),
                    // 选了「自定义」→ 给两个取色入口（底色 / 文字色）。
                    // 颜色**不改变布局** ⇒ 不需要重排 ✓
                    if (_rs.bubbleMode != BubbleMode.none &&
                        _rs.bubblePalette == BubblePalette.custom)
                      _setRowRight(
                        '气泡颜色',
                        Wrap(
                          spacing: 8,
                          children: [
                            _bubbleColorChip('底色', _customBubbleBg, (c) {
                              setState(
                                () => _rs = _rs.copyWith(
                                  bubbleBgColor: c.toARGB32(),
                                ),
                              );
                              _scheduleSavePrefs();
                            }),
                            _bubbleColorChip('文字', _customBubbleText, (c) {
                              setState(
                                () => _rs = _rs.copyWith(
                                  bubbleTextColor: c.toARGB32(),
                                ),
                              );
                              _scheduleSavePrefs();
                            }),
                          ],
                        ),
                      ),
                    // ── A3 背景壁纸（点开 14 张内置壁纸 + 无壁纸）──
                    InkWell(
                      onTap: _showBgImageSheet,
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _bgImageAsset == null ? '背景壁纸' : '背景壁纸',
                                style: TextStyle(
                                  fontSize: AppTheme.fontBody,
                                  color: _fg,
                                ),
                              ),
                            ),
                            Text(
                              _bgImageAsset == null
                                  ? '纯色底'
                                  : (_bgImageDark ?? false
                                        ? '壁纸 · 浅字'
                                        : '壁纸 · 深字'),
                              style: TextStyle(
                                fontSize: AppTheme.fontSubhead,
                                color: _fgMuted,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.image_outlined,
                              size: 18,
                              color: _fgMuted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // ── C7 护眼休息提醒（关 / 30 / 45 / 60 分钟）──
                    _setRowRight(
                      '护眼提醒',
                      Wrap(
                        spacing: 6,
                        children: [
                          _chip('关', !_rs.eyeBreakEnabled, () {
                            setState(
                              () => _rs = _rs.copyWith(eyeBreakEnabled: false),
                            );
                            _scheduleSavePrefs();
                            _eyeBreakStart = DateTime.now();
                            _eyeBreakShown = false;
                          }, compact: true),
                          for (final m in [30, 45, 60])
                            _chip(
                              '${m}分钟',
                              _rs.eyeBreakEnabled && _rs.eyeBreakMinutes == m,
                              () {
                                setState(
                                  () => _rs = _rs.copyWith(
                                    eyeBreakEnabled: true,
                                    eyeBreakMinutes: m,
                                  ),
                                );
                                _scheduleSavePrefs();
                                _eyeBreakStart = DateTime.now();
                                _eyeBreakShown = false;
                              },
                              compact: true,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // ⚠️ 底栏（取消 / 排版 / 确认）已按用户要求**整条去掉** ——
              //   面板里的选项点了就即时生效，不需要再确认 ✓
            ],
          ),
        ),
      ),
    );
  }

  /// 一行"标签在左、控件在右"（截图里 阅读模式 / 屏幕休眠 就是这样）。
  ///
  /// ⚠️ 我一开始对这两行用错了 [_setRow]（上下布局）——
  /// 截图里标签和按钮是**同一行**的。
  Widget _setRowRight(String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: _fg,
              ),
            ),
          ),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: child),
          ),
        ],
      ),
    );
  }

  Widget _setSwitch(
    String label,
    String sub,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _fg,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    color: _fg.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 统一开关的配色与紧凑度（原来默认蓝色 + 48dp 触控区，视觉太抢）
          SizedBox(
            width: 46,
            height: 30,
            child: FittedBox(
              child: Switch(
                value: value,
                activeThumbColor: _bgTop,
                activeTrackColor: _fg.withValues(alpha: 0.85),
                inactiveThumbColor: _bgTop,
                inactiveTrackColor: _fg.withValues(alpha: 0.16),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 自定义气泡颜色入口：色块 + 名称，点开 HSV 取色器。
  /// （改色**不影响排版** ⇒ 不需要 `_repaginateLayout()` ✓）
  Widget _bubbleColorChip(
    String label,
    Color color,
    ValueChanged<Color> onPicked,
  ) {
    return GestureDetector(
      onTap: () async {
        final picked = await ColorPickerDialog.show(
          context,
          initial: color,
          title: '气泡$label',
        );
        if (picked == null || !mounted) return;
        onPicked(picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: _fg.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: _fg.withValues(alpha: 0.25)),
              ),
            ),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 13, color: _fg)),
          ],
        ),
      ),
    );
  }

  Widget _chip(
    String label,
    bool on,
    VoidCallback onTap, {
    bool compact = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 16,
          vertical: compact ? 8 : 9,
        ),
        decoration: BoxDecoration(
          // 选中：实底；未选中：淡底 + 细描边（原来只有淡底，跟背景糊在一起 ✗）
          color: on ? _fg.withValues(alpha: 0.88) : _fg.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: on ? Colors.transparent : _fg.withValues(alpha: 0.10),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: compact ? 13 : 13.5,
            fontWeight: on ? FontWeight.w600 : FontWeight.w500,
            color: on ? _bgTop : _fg.withValues(alpha: 0.78),
          ),
        ),
      ),
    );
  }

  /// 设置面板里的小节标题（把一长串行分组，便于扫读）
  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: _fg.withValues(alpha: 0.45),
        ),
      ),
    );
  }

  /// 点击区域编辑器（截图 IMG_8117）：
  ///   顶部黑条提示「点击屏幕上的区域，在弹层中选择该区域的动作」
  ///   中间 3×3 网格，白色分界线
  ///   底部：恢复默认 · 完成
  Future<void> _showTapZoneEditor() async {
    var zones = Map<int, TapAction>.of(
      _rs.tapZones.isEmpty ? ReadingSettings.defaultZones() : _rs.tapZones,
    );
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => Dialog(
          insetPadding: EdgeInsets.zero,
          backgroundColor: Colors.transparent,
          child: Stack(
            children: [
              // 3×3 网格（带白色分界线）
              Positioned.fill(
                child: Column(
                  children: [
                    for (var row = 0; row < 3; row++)
                      Expanded(
                        child: Row(
                          children: [
                            for (var col = 0; col < 3; col++)
                              Expanded(
                                child: GestureDetector(
                                  onTap: () async {
                                    final z = row * 3 + col;
                                    final a =
                                        await showModalBottomSheet<TapAction>(
                                          context: ctx,
                                          backgroundColor: Colors.transparent,
                                          builder: (c) => Container(
                                            decoration: BoxDecoration(
                                              color: _bgTop,
                                              borderRadius:
                                                  const BorderRadius.vertical(
                                                    top: Radius.circular(22),
                                                  ),
                                            ),
                                            child: SafeArea(
                                              top: false,
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  for (final a
                                                      in TapAction.values)
                                                    ListTile(
                                                      title: Text(
                                                        a.label,
                                                        style: TextStyle(
                                                          fontSize: AppTheme
                                                              .fontHeadline,
                                                          color: _fg,
                                                        ),
                                                      ),
                                                      trailing: zones[z] == a
                                                          ? Icon(
                                                              Icons
                                                                  .check_rounded,
                                                              size: 20,
                                                              color: _fg,
                                                            )
                                                          : null,
                                                      onTap: () =>
                                                          Navigator.pop(c, a),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        );
                                    if (a != null) {
                                      setDlg(() => zones[z] = a);
                                    }
                                  },
                                  child: Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: 0.5,
                                        ),
                                        width: 1,
                                      ),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      (zones[row * 3 + col] ?? TapAction.none)
                                          .label,
                                      style: TextStyle(
                                        fontSize: AppTheme.fontHeadline,
                                        color: _fg,
                                        shadows: const [
                                          Shadow(
                                            color: Colors.black26,
                                            blurRadius: 4,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              // 顶部黑条提示
              Positioned(
                top: MediaQuery.of(ctx).padding.top + 8,
                left: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '点击屏幕上的区域，在弹层中选择该区域的动作',
                          style: TextStyle(
                            fontSize: AppTheme.fontBody,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 20,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 底部：恢复默认 · 完成
              Positioned(
                left: 0,
                right: 0,
                bottom: 24,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _zoneBtn('恢复默认', () {
                      setDlg(() => zones = ReadingSettings.defaultZones());
                    }),
                    _zoneBtn('完成', () {
                      setState(
                        () => _rs = _rs.copyWith(tapZones: Map.of(zones)),
                      );
                      _scheduleSavePrefs();
                      Navigator.pop(ctx);
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _zoneBtn(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: AppTheme.fontHeadline,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  /// 目录右侧「到顶 / 到底」竖条里的一个按钮
  Widget _tocJumpBtn(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 32,
          height: 34,
          child: Icon(
            icon,
            size: 20,
            color: _fg.withValues(alpha: 0.72),
          ),
        ),
      ),
    );
  }

  /// 目录抽屉（截图 IMG_8077）。
  ///
  /// ── 三个 tab ──────────────────────────────────────────────────
  ///   目录  ：章数 + 搜索章节 + 排序 + 章节列表（已缓存的显示 ☁ 标记）
  ///   书签  ：本书的书签（按颜色）
  ///   笔记  ：划线/批注（入口，交互未做）
  /// 右侧还有 ↑↓ 快速拖动条。
  Future<void> _showToc({int initialTab = 0}) async {
    var tab = initialTab;
    // 三个 tab 各自的搜索词/controller 独立，避免切 tab 时词残留
    final ctrlToc = TextEditingController();
    final ctrlBm = TextEditingController();
    final ctrlNote = TextEditingController();
    var kwToc = '';
    var kwBm = '';
    var kwNote = '';
    var asc = true;
    Color? filterColor; // 书签/笔记颜色筛选（null = 全部）
    const tabNames = ['目录', '书签', '笔记'];
    // 目录 tab 右缘快速拖动定位（Cmbok 同款）：拖动只滚动列表不跳转 ✓，
    // 拖动时浮现章节标题提示 ✓，搜索状态不可用 ✓。
    // 定位/滚动改用漫画阅读器同款 ScrollablePositionedList ✓：
    // jumpTo(index:) 按条目下标精确跳，不再估行高 ✓。
    final itemScrollController = ItemScrollController();
    final itemPositionsListener = ItemPositionsListener.create();
    var showDragTip = false;
    var dragTipName = '';
    var dragTipY = 0.0;
    var didAutoScrollToc = false;
    // 滚动时浮现「到顶 / 到底」竖条：滚动开始显示、静止 900ms 后淡出
    var tocScrolling = false;
    Timer? tocHideTimer;

    // 和漫画阅读器一致：目录 / 书签 / 笔记从**右侧滑入**（不是底部弹层）。
    final drawerWidth = MediaQuery.sizeOf(context).width * 0.78;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '目录',
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (ctx, anim, secondary) => Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: drawerWidth,
            height: double.infinity,
            decoration: BoxDecoration(
              color: _bgTop,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(22),
                bottomLeft: Radius.circular(22),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.22),
                  blurRadius: 26,
                  offset: const Offset(-4, 0),
                ),
              ],
            ),
            child: SafeArea(
              child: StatefulBuilder(
                builder: (ctx, setSheet) {
          final chapters = <int>[
            for (var i = 0; i < widget.chapters.length; i++)
              if (kwToc.isEmpty || widget.chapters[i].name.contains(kwToc)) i,
          ];
          if (!asc) {
            final rev = chapters.reversed.toList();
            chapters
              ..clear()
              ..addAll(rev);
          }
          // 首次打开：定位到「当前章」（漫画阅读器同款 ✓）。
          //   · jumpTo(index:) 按条目下标精确跳，100% 命中 ✓；
          //   · ⚠️ 只跳一次（didAutoScrollToc）—— 搜索/切排序重建列表时
          //     不重新定位，否则会边打字边乱滚 ✓；
          //   · 必须等首帧（列表 attach 后）再跳 ✓。
          if (!didAutoScrollToc) {
            didAutoScrollToc = true;
            final cur = chapters.indexOf(_index);
            if (cur > 0) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (itemScrollController.isAttached) {
                  itemScrollController.jumpTo(index: cur);
                }
              });
            }
          }
          // 右缘拖动 → 按比例换算成章节下标精确跳 ✓
          //（比旧版按偏移比例滚动更准：目标章一定贴在列表顶部），并记录提示章节名
          void dragTocTo(double localY, double stripH) {
            if (chapters.isEmpty) return;
            final ratio = (localY / stripH).clamp(0.0, 1.0);
            final idx = (ratio * (chapters.length - 1)).round();
            if (itemScrollController.isAttached) {
              itemScrollController.jumpTo(index: idx);
            }
            dragTipName = widget.chapters[chapters[idx]].name;
            dragTipY = localY;
          }

          return Column(
            mainAxisSize: MainAxisSize.max,
                children: [
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final e in [
                        ('目录', '${widget.chapters.length} 章'),
                        ('书签', '${_bookmarks.length} 条'),
                        (
                          '笔记',
                          '${ReaderNotesService.instance.forBook(widget.source.id, widget.bookName).length} 条',
                        ),
                      ])
                        Expanded(
                          child: GestureDetector(
                            onTap: () =>
                                setSheet(() => tab = tabNames.indexOf(e.$1)),
                            child: Column(
                              children: [
                                Text(
                                  e.$1,
                                  style: TextStyle(
                                    fontSize: AppTheme.fontHeadline,
                                    fontWeight: tab == tabNames.indexOf(e.$1)
                                        ? FontWeight.w700
                                        : FontWeight.normal,
                                    color: tab == tabNames.indexOf(e.$1)
                                        ? _fg
                                        : _fgMuted,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  e.$2,
                                  style: TextStyle(
                                    fontSize: AppTheme.fontFootnote,
                                    color: _fgMuted,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  height: 2,
                                  width: 26,
                                  color: tab == tabNames.indexOf(e.$1)
                                      ? _fg
                                      : Colors.transparent,
                                ),
                              ],
                            ),
                          ),
                        ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: Icon(
                          Icons.close_rounded,
                          size: 22,
                          color: _fgMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (tab == 0) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              // ✅ **统一成 B 规格** ✓ —— 本页最后 1 处 ✓。
                              //   ⚠️ 原本同一页里有 **三套规格** ✗：
                              //     40/prefixIcon19/约束38 · **38/prefixIcon18/约束36（这里）** · 34/前置Icon16 ✓
                              //   → 统一后**四框一致** ✓（底色本来就相同 ✓，只改尺寸与图标位置 ✓）
                              height: 34,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              decoration: BoxDecoration(
                                color: _fg.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(17),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.search_rounded,
                                    size: 16,
                                    color: _fgMuted,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: TextField(
                                      controller: ctrlToc,
                                      // ⚠️ **`setSheet` 必须照抄** ✗ —— 这是弹层自己的刷新函数 ✓，
                                      //   误写成 `setState` 会导致**输入不生效** ✗✗
                                      onChanged: (v) =>
                                          setSheet(() => kwToc = v.trim()),
                                      // ⚠️ **不要加 `autofocus`** ✗ —— 章节列表弹层
                                      //   一打开就弹键盘会很难用 ✓（现状没有 ✓，保持 ✓）
                                      style: TextStyle(
                                        fontSize: AppTheme.fontFootnote,
                                        color: _fg,
                                      ),
                                      decoration: InputDecoration(
                                        hintText: '搜索章节',
                                        hintStyle: TextStyle(
                                          fontSize: AppTheme.fontFootnote,
                                          color: _fgMuted,
                                        ),
                                        border: InputBorder.none,
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          // 排序：改成上下双箭头（参考 Cmbok 的 t↓ 样式），
                          // 不再用单向上/下箭头 —— 单箭头看着像"跳到顶/底" ✗
                          IconButton(
                            tooltip: asc ? '正序（点击切倒序）' : '倒序（点击切正序）',
                            onPressed: () => setSheet(() => asc = !asc),
                            icon: Icon(
                              Icons.swap_vert_rounded,
                              size: 20,
                              color: _fg.withValues(alpha: asc ? 0.9 : 0.55),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: Stack(
                        children: [
                          NotificationListener<ScrollNotification>(
                            onNotification: (n) {
                              // 一滚动就让「到顶/到底」竖条浮现，静止后淡出
                              if (!tocScrolling) {
                                setSheet(() => tocScrolling = true);
                              }
                              tocHideTimer?.cancel();
                              tocHideTimer = Timer(
                                const Duration(milliseconds: 900),
                                () {
                                  if (ctx.mounted) {
                                    setSheet(() => tocScrolling = false);
                                  }
                                },
                              );
                              return false;
                            },
                            child: ScrollConfiguration(
                            // 关掉系统滚动条：目录动辄上千章，原生 thumb 会拉成
                            // 一条很长的灰条压在云朵图标上（用户反馈"太长"）✗
                            behavior: ScrollConfiguration.of(
                              context,
                            ).copyWith(scrollbars: false),
                            child: ScrollablePositionedList.builder(
                            itemScrollController: itemScrollController,
                            itemPositionsListener: itemPositionsListener,
                            itemCount: chapters.length,
                            itemBuilder: (c, i) {
                              final ci = chapters[i];
                              final current = ci == _index;
                              // 已缓存 = 已下载（截图里的 ☁ 标记）
                              final downloaded = _cache.containsKey(ci);
                              return GestureDetector(
                                onTap: () {
                                  Navigator.pop(ctx);
                                  if (ci != _index) _jumpTo(ci);
                                },
                                child: Container(
                                  color: current
                                      ? _fg.withValues(alpha: 0.06)
                                      : null,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 14,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          widget.chapters[ci].name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: AppTheme.fontHeadline,
                                            color: _fg,
                                            fontWeight: current
                                                ? FontWeight.w700
                                                : FontWeight.normal,
                                          ),
                                        ),
                                      ),
                                      Icon(
                                        downloaded
                                            ? Icons.cloud_done_rounded
                                            : Icons.cloud_outlined,
                                        size: 18,
                                        color: downloaded
                                            ? _fg.withValues(alpha: 0.7)
                                            : _fgMuted.withValues(alpha: 0.5),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                          ),
                          ),
                          // 滚动时浮现的「到顶 / 到底」竖条
                          Positioned(
                            right: 2,
                            top: 0,
                            bottom: 0,
                            child: Center(
                              child: IgnorePointer(
                                ignoring: !tocScrolling,
                                child: AnimatedOpacity(
                                  opacity: tocScrolling ? 1 : 0,
                                  duration: const Duration(milliseconds: 160),
                                  child: Container(
                                    width: 32,
                                    decoration: BoxDecoration(
                                      color: _fg.withValues(alpha: 0.10),
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.08,
                                          ),
                                          blurRadius: 8,
                                        ),
                                      ],
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _tocJumpBtn(
                                          Icons.keyboard_arrow_up_rounded,
                                          '回到顶部',
                                          () {
                                            if (itemScrollController
                                                .isAttached) {
                                              itemScrollController.jumpTo(
                                                index: 0,
                                              );
                                            }
                                          },
                                        ),
                                        Container(
                                          width: 14,
                                          height: 0.5,
                                          color: _fg.withValues(alpha: 0.22),
                                        ),
                                        _tocJumpBtn(
                                          Icons.keyboard_arrow_down_rounded,
                                          '跳到底部',
                                          () {
                                            if (itemScrollController
                                                    .isAttached &&
                                                chapters.isNotEmpty) {
                                              itemScrollController.jumpTo(
                                                index: chapters.length - 1,
                                              );
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 右缘快速拖动定位条（Cmbok 同款）：按住上下拖动 →
                          // 列表按比例滚动，浮现章节标题提示；搜索状态隐藏 ✓
                          if (kwToc.isEmpty)
                            Positioned(
                              right: 2,
                              top: 40,
                              bottom: 40,
                              // 滚动时「到顶/到底」竖条浮现 → 右缘拖动条让位，
                              // 否则它的透明热区会吃掉竖条上的点击 ✗
                              child: IgnorePointer(
                                ignoring: tocScrolling,
                                child: LayoutBuilder(
                                builder: (c, cons) {
                                  final h = cons.maxHeight;
                                  return GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onVerticalDragStart: (d) {
                                      setSheet(() {
                                        showDragTip = true;
                                        dragTocTo(d.localPosition.dy, h);
                                      });
                                    },
                                    onVerticalDragUpdate: (d) {
                                      setSheet(
                                        () => dragTocTo(d.localPosition.dy, h),
                                      );
                                    },
                                    onVerticalDragEnd: (_) {
                                      Future.delayed(
                                        const Duration(milliseconds: 700),
                                        () {
                                          if (ctx.mounted) {
                                            setSheet(() => showDragTip = false);
                                          }
                                        },
                                      );
                                    },
                                    // 只留一个细短指示块，**不再画整条灰底 + ⌃⌄ 图标** ——
                                    // 用户反馈"这么长的滑动样式"太碍眼 ✗。
                                    // 热区仍是整条（24 宽，透明），拖动功能不受影响 ✓。
                                    child: SizedBox(
                                      width: 24,
                                      child: Stack(
                                        children: [
                                          // 拖动指示块（按当前可见章下标比例定位；
                                          // 监听 ItemPositions，滚动时自动刷新 ✓）
                                          Positioned(
                                            top: 0,
                                            left: 10,
                                            child: ValueListenableBuilder<
                                                Iterable<ItemPosition>>(
                                              valueListenable:
                                                  itemPositionsListener
                                                      .itemPositions,
                                              builder: (c, positions, _) {
                                                final ratio =
                                                    positions.isEmpty ||
                                                            chapters.length <= 1
                                                        ? 0.0
                                                        : (positions
                                                              .reduce((a, b) =>
                                                                  a.index <
                                                                          b.index
                                                                      ? a
                                                                      : b)
                                                              .index /
                                                          (chapters.length -
                                                              1));
                                                return Transform.translate(
                                                  offset: Offset(
                                                    0,
                                                    (ratio.clamp(0.0, 1.0) *
                                                            (h - 44))
                                                        .clamp(0.0, h - 44),
                                                  ),
                                                  child: Container(
                                                    width: 4,
                                                    height: 44,
                                                    decoration: BoxDecoration(
                                                      color: _fg.withValues(
                                                        alpha: 0.22,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              2),
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                              ),
                            ),
                          // 拖动时浮现的章节标题提示（只读 ✓）
                          if (showDragTip && dragTipName.isNotEmpty)
                            Positioned(
                              right: 40,
                              top: (40 + dragTipY - 20).clamp(
                                0.0,
                                double.infinity,
                              ),
                              child: Container(
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(ctx).size.width * 0.62,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: _fg.withValues(alpha: 0.85),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  dragTipName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppTheme.fontFootnote,
                                    color: _bgTop,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ] else if (tab == 1) ...[
                    // ── 书签 tab（参考图 IMG_8504：搜索书签 + 全部 + 空态）──
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 34,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              decoration: BoxDecoration(
                                color: _fg.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(17),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.search_rounded,
                                    size: 16,
                                    color: _fgMuted,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: TextField(
                                      controller: ctrlBm,
                                      style: TextStyle(
                                        fontSize: AppTheme.fontFootnote,
                                        color: _fg,
                                      ),
                                      decoration: InputDecoration(
                                        hintText: '搜索书签',
                                        hintStyle: TextStyle(
                                          fontSize: AppTheme.fontFootnote,
                                          color: _fgMuted,
                                        ),
                                        border: InputBorder.none,
                                        isDense: true,
                                      ),
                                      onChanged: (v) =>
                                          setSheet(() => kwBm = v.trim()),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: asc ? '正序（点击切倒序）' : '倒序（点击切正序）',
                            onPressed: () => setSheet(() => asc = !asc),
                            icon: Icon(
                              Icons.swap_vert_rounded,
                              size: 20,
                              color: _fg.withValues(alpha: asc ? 0.9 : 0.55),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 全部 + 6 色筛选
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: () => setSheet(() => filterColor = null),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: filterColor == null
                                    ? _fg.withValues(alpha: 0.85)
                                    : _fg.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                '全部',
                                style: TextStyle(
                                  fontSize: AppTheme.fontFootnote,
                                  fontWeight: FontWeight.w600,
                                  color: filterColor == null ? _bgTop : _fg,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          for (final c in _bookmarkColors)
                            GestureDetector(
                              onTap: () => setSheet(
                                () => filterColor = filterColor == c ? null : c,
                              ),
                              child: Container(
                                width: 22,
                                height: 22,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: filterColor == c
                                      ? Border.all(color: _fg, width: 2.5)
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Flexible(
                      child: () {
                        final kw2 = kwBm.toLowerCase();
                        final entries = _bookmarks.entries.where((e) {
                          if (filterColor != null && e.value != filterColor) {
                            return false;
                          }
                          if (kw2.isEmpty) return true;
                          final t = _paragraphs.length > e.key
                              ? _paragraphs[e.key]
                              : '';
                          return t.toLowerCase().contains(kw2);
                        }).toList();
                        if (entries.isEmpty) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(30),
                              child: Text(
                                '还没有书签',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: AppTheme.fontSubhead,
                                  height: 1.7,
                                  color: _fgMuted,
                                ),
                              ),
                            ),
                          );
                        }
                        return ListView.builder(
                          shrinkWrap: true,
                          itemCount: entries.length,
                          itemBuilder: (c, i) {
                            final e = entries[i];
                            return ListTile(
                              leading: Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: e.value,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              title: Text(
                                _paragraphs.length > e.key
                                    ? _paragraphs[e.key]
                                    : '第 ${e.key + 1} 段',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppTheme.fontBody,
                                  color: _fg,
                                ),
                              ),
                              trailing: IconButton(
                                icon: Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                  color: _fgMuted,
                                ),
                                onPressed: () => setSheet(() {
                                  setState(() => _bookmarks.remove(e.key));
                                  _scheduleSavePrefs();
                                }),
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                final p = _pageOfParagraph(e.key);
                                if (p != null && _pageCtrl.hasClients) {
                                  _pageCtrl.jumpToPage(p);
                                }
                              },
                            );
                          },
                        );
                      }(),
                    ),
                  ] else ...[
                    // ── 笔记 tab（参考图 IMG_8505：搜索摘录或批注 + 全部 + 空态）──
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Container(
                        height: 34,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: _fg.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(17),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.search_rounded,
                              size: 16,
                              color: _fgMuted,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: TextField(
                                controller: ctrlNote,
                                style: TextStyle(
                                  fontSize: AppTheme.fontFootnote,
                                  color: _fg,
                                ),
                                decoration: InputDecoration(
                                  hintText: '搜索摘录或批注',
                                  hintStyle: TextStyle(
                                    fontSize: AppTheme.fontFootnote,
                                    color: _fgMuted,
                                  ),
                                  border: InputBorder.none,
                                  isDense: true,
                                ),
                                onChanged: (v) =>
                                    setSheet(() => kwNote = v.trim()),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 全部 + 6 色筛选
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: () => setSheet(() => filterColor = null),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: filterColor == null
                                    ? _fg.withValues(alpha: 0.85)
                                    : _fg.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                '全部',
                                style: TextStyle(
                                  fontSize: AppTheme.fontFootnote,
                                  fontWeight: FontWeight.w600,
                                  color: filterColor == null ? _bgTop : _fg,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          for (final c in _bookmarkColors)
                            GestureDetector(
                              onTap: () => setSheet(
                                () => filterColor = filterColor == c ? null : c,
                              ),
                              child: Container(
                                width: 22,
                                height: 22,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: filterColor == c
                                      ? Border.all(color: _fg, width: 2.5)
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Flexible(
                      child: () {
                        final all = ReaderNotesService.instance.forBook(
                          widget.source.id,
                          widget.bookName,
                        );
                        final kw2 = kwNote.toLowerCase();
                        final notes = all.where((n) {
                          if (filterColor != null &&
                              Color(n.color) != filterColor) {
                            return false;
                          }
                          if (kw2.isEmpty) return true;
                          return n.text.toLowerCase().contains(kw2) ||
                              n.note.toLowerCase().contains(kw2);
                        }).toList();
                        if (notes.isEmpty) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(30),
                              child: Text(
                                all.isEmpty ? '还没有划线，长按正文试试' : '没有匹配的笔记',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: AppTheme.fontSubhead,
                                  height: 1.7,
                                  color: _fgMuted,
                                ),
                              ),
                            ),
                          );
                        }
                        return ListView.builder(
                          shrinkWrap: true,
                          itemCount: notes.length,
                          itemBuilder: (c, i) {
                            final n = notes[i];
                            return Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _fg.withValues(alpha: 0.05),
                                borderRadius: BorderRadius.circular(14),
                                border: Border(
                                  left: BorderSide(
                                    color: Color(n.color),
                                    width: 3,
                                  ),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        n.hasNote
                                            ? Icons.edit_note_rounded
                                            : Icons.border_color_rounded,
                                        size: 16,
                                        color: Color(n.color),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          '${n.chapterName.isEmpty ? '第${n.chapterIndex + 1}章' : n.chapterName}'
                                          '${n.chapterIndex == _index ? '（当前）' : ''}',
                                          style: TextStyle(
                                            fontSize: AppTheme.fontFootnote,
                                            color: _fgMuted,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: () async {
                                          await ReaderNotesService.instance
                                              .remove(n.id);
                                          if (ctx.mounted) {
                                            Navigator.pop(ctx);
                                            setState(() {});
                                          }
                                        },
                                        child: Icon(
                                          Icons.close_rounded,
                                          size: 16,
                                          color: _fgMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    n.text,
                                    style: TextStyle(
                                      fontSize: AppTheme.fontSubhead,
                                      color: _fg,
                                      height: 1.5,
                                    ),
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (n.hasNote) ...[
                                    const SizedBox(height: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Color(
                                          n.color,
                                        ).withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        '批注：${n.note}',
                                        style: TextStyle(
                                          fontSize: AppTheme.fontFootnote,
                                          color: _fg,
                                          height: 1.4,
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (n.chapterIndex != _index)
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: GestureDetector(
                                        onTap: () {
                                          Navigator.pop(ctx);
                                          _jumpToChapter(n.chapterIndex);
                                        },
                                        child: Text(
                                          '跳到本章 →',
                                          style: TextStyle(
                                            fontSize: AppTheme.fontFootnote,
                                            color: JellyTheme.primary,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        );
                      }(),
                    ),
                  ],
                ],
          );
                },
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (ctx, anim, secondary, child) {
        final offset = Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        );
        return SlideTransition(position: offset, child: child);
      },
    );
    // 抽屉关闭 → 收掉「到顶/到底」竖条的淡出定时器
    tocHideTimer?.cancel();
    // ItemScrollController / ItemPositionsListener 是普通对象（非 ChangeNotifier），
    // 不需要 dispose ✓。
    // ⚠️ 三个 TextEditingController 不能在这里立刻 dispose ✗：
    //   `await showGeneralDialog` 在**退场动画开始**时就返回了 ✓，
    //   接下来 260ms 内 TextField 还挂在 Overlay 上 ⇒ 提前 dispose 会让
    //   TextField 在重建/销毁时用到已销毁的 controller（"used after being
    //   disposed" ✗）。等退场动画走完再回收 ✓。
    Future<void>.delayed(const Duration(milliseconds: 320), () {
      ctrlToc.dispose();
      ctrlBm.dispose();
      ctrlNote.dispose();
    });
  }

  /// 段落 → 所在页下标（书签跳转用）
  int? _pageOfParagraph(int pi) {
    if (pi >= _paragraphs.length) return null;
    // 优先用「块下标」定位：`_pages` 是由 `[章标题?, 段0, 段1, …]` 分页来的
    // ⇒ 段落 pi 对应块 pi + [_blockOffset]（见 `_paginate` 里构造 blocks 的地方）。
    // 原来按「段落文本相等」匹配 ✗ —— 同一章出现重复句子（"……"、"他说"）时
    // 会命中第一处 ⇒ 书签跳到错误页。
    final offset = _blockOffset;
    for (var i = 0; i < _pages.length; i++) {
      // ⚠️ 只看**本章**的页：无缝拼接后 `_pages` 末尾混有下一章的页，
      //   而下一章的 blockIndex 是从 0 重新数的 ⇒ 不筛章会跳到别的章里。
      if (i < _pageChapterOf.length && _pageChapterOf[i] != _index) continue;
      for (final e in _pages[i].entries) {
        if (e.blockIndex >= 0 && e.blockIndex - offset == pi) return i;
      }
    }
    // 兜底：极少数旧分页数据没有 blockIndex，仍按文本匹配
    final text = _paragraphs[pi];
    for (var i = 0; i < _pages.length; i++) {
      if (i < _pageChapterOf.length && _pageChapterOf[i] != _index) continue;
      for (final e in _pages[i].entries) {
        final b = e.block;
        if (b is ParagraphBlock && b.text == text) return i;
      }
    }
    return null;
  }
}

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