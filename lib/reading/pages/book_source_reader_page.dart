import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import '../models/book_content.dart';
import '../models/reading_settings.dart';
import '../services/book_paginator.dart';
import '../services/book_source_service.dart';
import '../services/reader_notes_service.dart';
import '../services/tts_service.dart';
import '../services/ai_service.dart';
import '../services/reading_time_service.dart';
import '../services/bsr_independent_layout.dart';
import '../widgets/book_page_cover.dart';
import '../widgets/book_page_curl.dart';
import '../widgets/color_picker_dialog.dart';
import '../widgets/pomodoro_button.dart';
import 'tts_engine_page.dart';
import 'book_source_editor_page.dart';
import 'tts_full_player_page.dart';
import '../../common/theme.dart';
import '../theme/jelly_theme.dart';
import '../../widgets/app_image_cache.dart';

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
  double _lineHeight = 1.9;
  /// 阅读底色索引（见 [_bgs]）。
  ///
  /// ⚠️ 默认值**按全局明暗取**：全局是深色就默认"夜间"，浅色就默认"白"。
  int _bgIndex = AppBrightness.isLight.value ? 0 : 5;
  /// 自定义背景色（主题 tab「自定义」，参考图 IMG_8500；null = 用 _bgs）
  Color? _customBgColor;

  /// 自定义背景图片路径（「选择图片」选图后复制到应用文档目录；
  /// 非空时优先于颜色作为正文背景）
  String? _customBgPath;

  /// 内置阅读背景壁纸（14 张，来自 cmbok ✓；资源在 `assets/images/reader_bg/`）。
  /// ⚠️ 以后加壁纸：把图放进那个目录 + 这里加一行即可（pubspec 已声明该目录 ✓）。
  static const List<String> _builtinBgImages = [
    'assets/images/reader_bg/annie-spratt-6a3nqQ1YwBw-unsplash.jpg',
    'assets/images/reader_bg/augustine-wong-oebTM5wHTfw-unsplash.jpg',
    'assets/images/reader_bg/danielle-suijkerbuijk-66ydMRXW-b8-unsplash.jpg',
    'assets/images/reader_bg/h-co-mjPs0heWsek-unsplash.jpg',
    'assets/images/reader_bg/heather-green-1ITG8U0udqM-unsplash.jpg',
    'assets/images/reader_bg/jacob-dyer-rtA0U8QJHSg-unsplash.jpg',
    'assets/images/reader_bg/janke-laskowski-jz-ayLjk2nk-unsplash.jpg',
    'assets/images/reader_bg/marjan-blan-794QUz5-cso-unsplash.jpg',
    'assets/images/reader_bg/noita-digital-zcx5ztIjQAM-unsplash.jpg',
    'assets/images/reader_bg/p0074_m.jpg',
    'assets/images/reader_bg/p0087_m.jpg',
    'assets/images/reader_bg/resource-boy-t5-DgEcAUUg-unsplash.jpg',
    'assets/images/reader_bg/the-new-york-public-library-atDr7NECc_k-unsplash.jpg',
    'assets/images/reader_bg/tina-dawson-Kim9COAIEGc-unsplash.jpg',
  ];

  /// 当前选中的内置壁纸（null = 不用壁纸，走 `_bgIndex` 的纯色底 ✓）
  String? _bgImageAsset;
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
  double _fontWeight = 400;   // 字重
  double _letterSpacing = 0;  // 字间距
  double _paraSpacing = 1.0;  // 段间距（× 字号）
  // 边距（内容区）
  double _padLeft = 20, _padRight = 20, _padTop = 16, _padBottom = 40;
  double _indent = 2;         // 首行缩进（字符数）
  // 页眉 / 页脚（负值移进状态栏区域）
  double _headerPadH = 15, _headerPadTop = 0;
  double _footerPadH = 15, _footerPadBottom = 0;
  // 底线
  // ⚠️ 默认必须是 0（无）—— 用户实测："默认打开就有下划线" ✗。
  //   原来写死 3（实线）⇒ 一进阅读器**整屏正文都带下划线** ✗。
  int _underlineStyle = 0;    // 0无 1短虚线 2长虚线 3实线 4波浪
  Color? _underlineColor;     // null = 跟随文字（参考图 IMG_8497/8498）
  double _underlineAlpha = 0.35;
  double _underlineWidth = 1.2;
  double _underlineGap = 3.0;
  bool _underlineFull = false; // 满行底线
  /// 自定义字色（null = 跟随主题）
  Color? _fgOverride;
  /// 已保存的排版预设名
  final List<String> _savedPresets = [];
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
  /// 番茄钟浮层是否显示
  bool _showPomodoro = false;
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
  /// 阅读悬浮球的偏移（拖动后记住）
  Offset _ballOffset = Offset.zero;

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
    if (_fgOverride != null) return _fgOverride!;
    return _bgTop.computeLuminance() < 0.4
        ? const Color(0xFFB8B8B8)
        : _bgs[_bgIndex][1];
  }
  /// 当前背景下的次要前景色（说明文字用）
  Color get _fgMuted => _fg.withValues(alpha: 0.6);
  /// 当前阅读背景色（自定义背景优先，参考图 IMG_8500）
  Color get _bgTop => _customBgColor ?? _bgs[_bgIndex][0];

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
    _restorePrefs();
    _loadChapter(_index);
  }

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
    // 🆕 **退出阅读器必须停掉朗读** ✓ —— `TtsService` 是**进程单例** ✓，
    //   原来这里既不 `stop()` 也不清 `onFinished` ✗ → 用户点朗读后按返回键
    //   离开阅读器，语音会**继续在书架/首页念** ✗；`onFinished` 闭包还一直
    //   持有已销毁的 State ✗（直到被别处覆盖 ✓）。
    //   与 `book_reader_page.dart` 的 dispose 同款写法 ✓
    _tts.onFinished = null;
    _tts.stop();
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
    // 🆕 **补上漏掉的定时器取消** ✓ —— 原来 `_ttsTimerHandle` 只在
    //   `_scheduleTtsTimer` 内部被取消 ✗，离开阅读器时**没人取消它** ✗
    //   （定时器会在页面销毁后照常触发 → 潜在泄漏/异常 ✓）
    _ttsTimerHandle?.cancel();
    _repaginateDebounce?.cancel();
    _pageCtrl.dispose();
    super.dispose();
  }

  // ── 偏好与进度 ──────────────────────────────────────────────

  String get _progressKey =>
      'bsr.progress.${widget.source.id}.${widget.bookName}';

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
        'bgImage': _bgImageAsset,
        'underlineColor': _underlineColor?.toARGB32(),
        'underlineStyle': _underlineStyle,
        'focusBold': _focusBold,
        'titleAlign': _titleAlign,
        'titleStyle': _titleStyle,
        // ℹ️ 有意**不含** `hideRepeatTitle` ✓：它在 `_savePrefs` 里**没有**对应全局写入 ✓
        //   （只读不写 ✓），纳入覆盖会变成"独立时改了却没处存"✗ —— 不纳入才是自洽的 ✓
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
      _independent = await BsrIndependentLayout.instance.isIndependent(_indepKey);
      final ov = _independent
          ? await BsrIndependentLayout.instance.read(_indepKey)
          : null;
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
      if (!mounted) return;
      setState(() {
        // ✅ **覆盖值优先，逐项回退全局**（本会话第 2 轮 ✓）
        final fsV = (ov?['fontSize'] as num?)?.toDouble() ?? fs;
        final lhV = (ov?['lineHeight'] as num?)?.toDouble() ?? lh;
        final bgV = (ov?['bgIndex'] as num?)?.toInt() ?? bg;
        if (fsV != null && fsV >= 12 && fsV <= 30) _fontSize = fsV;
        if (lhV != null && lhV >= 1.2 && lhV <= 3.0) _lineHeight = lhV;
        if (bgV != null && bgV >= 0 && bgV < _bgs.length) _bgIndex = bgV;
        final dayBg =
            (ov?['dayBgIndex'] as num?)?.toInt() ?? p.getInt('reading.dayBgIndex');
        if (dayBg != null && dayBg >= 0 && dayBg < _bgs.length) {
          _dayBgIndex = dayBg;
        }
        final bgC =
            (ov?['bgCustom'] as num?)?.toInt() ?? p.getInt('reading.bgCustom');
        if (bgC != null) _customBgColor = Color(bgC);
        final bgPath =
            (ov?['bgCustomPath'] as String?) ?? p.getString('reading.bgCustomPath');
        if (bgPath != null && File(bgPath).existsSync()) _customBgPath = bgPath;
        // 内置壁纸（与 `_savePrefs` 的 `reading.bgImage` 配对 ✓）
        final bgImg =
            (ov?['bgImage'] as String?) ?? p.getString('reading.bgImage');
        if (bgImg != null && bgImg.isNotEmpty) _bgImageAsset = bgImg;
        // 🔴 与 `_savePrefs` 侧的 `bsr.ball.dx/dy` 配对读回 ✓
        //（原来写读两边都没有它 ✗ → 悬浮球位置"承诺持久化却从不生效" ✓）
        final bdx = p.getDouble('bsr.ball.dx');
        final bdy = p.getDouble('bsr.ball.dy');
        if (bdx != null && bdy != null) {
          _ballOffset = Offset(bdx, bdy);
        }
        // ✅ 书签**按章**读回 ✓ —— 只读"即将显示的那一章"的键 ✓，
        // 不再把整本一份的书签装到当前章（那正是串章的根因 ✓）。
        // 与下面 `_index = savedIdx`（:576 附近）用同一判定 ✓，保证章号一致 ✓。
        final bmIdx = (widget.initialIndex == 0 &&
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
                ..addAll(m.map((k, v) => MapEntry(
                      int.tryParse('$k') ?? 0,
                      Color((v as num).toInt()),
                    )));
            }
          } catch (_) {}
        }
        // ✅ 第 4 轮 ✓：这 5 项也**覆盖优先、逐项回退全局** ✓（与上面 3 项同一写法 ✓）
        final uc = (ov?['underlineColor'] as num?)?.toInt() ??
            p.getInt('reading.underlineColor');
        if (uc != null) _underlineColor = Color(uc);
        final us = (ov?['underlineStyle'] as num?)?.toInt() ??
            p.getInt('reading.underlineStyle');
        if (us != null && us >= 0 && us < 5) _underlineStyle = us;
        final fb = (ov?['focusBold'] as bool?) ?? p.getBool('reading.focusBold');
        final ta =
            (ov?['titleAlign'] as num?)?.toInt() ?? p.getInt('reading.titleAlign');
        final ts =
            (ov?['titleStyle'] as num?)?.toInt() ?? p.getInt('reading.titleStyle');
        final hr = p.getBool('reading.hideRepeatTitle');
        if (fb != null) _focusBold = fb;
        if (ta != null) _titleAlign = ta;
        if (ts != null) _titleStyle = ts;
        if (hr != null) _hideRepeatTitle = hr;
        if (rsRaw != null && rsRaw.isNotEmpty) {
          try {
            _rs = ReadingSettings.fromJson(
                Map<String, dynamic>.from(jsonDecode(rsRaw) as Map));
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
        if (tdp != null) _ttsDirectPlayer = tdp;
        if (tal != null) _ttsAutoLocate = tal;
      });
      if (_index != widget.initialIndex) _loadChapter(_index);
      // 恢复完偏好要立刻应用屏幕休眠设置
      _applySleepMode();
    } catch (_) {
      // 偏好读不到就用默认值，不影响阅读
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
        await BsrIndependentLayout.instance.update(_indepKey, _layoutSnapshot());
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
        if (_bgImageAsset != null) {
          await p.setString('reading.bgImage', _bgImageAsset!);
        } else {
          await p.remove('reading.bgImage');
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
      }
      // ✅ TTS 面板的两个新设置也落盘 ✓（键名与 `_restorePrefs` 里的读回一一对应 ✓）
      await p.setBool('bsr.tts.directPlayer', _ttsDirectPlayer);
      await p.setBool('bsr.tts.autoLocate', _ttsAutoLocate);
      // 🔴 悬浮球位置原来**从不落盘** ✗ —— 注释（:4175 附近）明写"移动后的位置
      // 记在 `_ballOffset`，重进阅读器还在原处" ✓，`onPanEnd` 也确实调了
      // `_savePrefs()` 假装在保存 ✓ → 实际每次重进都回到默认位置 ✗。
      // 现在两个分量真正写盘 ✓，`_restorePrefs` 侧配对读回 ✓（缺任一边都等于没做 ✓）
      await p.setDouble('bsr.ball.dx', _ballOffset.dx);
      await p.setDouble('bsr.ball.dy', _ballOffset.dy);
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
      await p.setString('reading.settings', jsonEncode(_rs.toJson()));
      await p.setString('reading.presetNames', jsonEncode(_savedPresets));
      await p.setInt('bsr.tts.color', _ttsColor);
      await p.setInt('bsr.tts.highlight', _ttsHighlight);
      await p.setInt('bsr.tts.timer', _ttsTimer);
      await p.setInt('bsr.tts.volume', _ttsVolume);
      await p.setBool('bsr.tts.followSystem', _ttsFollowSystem);
    } catch (_) {}
  }

  Future<void> _saveProgress() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_progressKey, _index);
    } catch (_) {}
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
    final raw = (await SharedPreferences.getInstance())
        .getString(_bookmarksKey(chapter));
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
          _paragraphs = _cache[i]!;
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
      }
      _prefetch(i + 1);
      return;
    }

    if (!prefetchOnly) {
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
      final isMangaSource = widget.source.type == '2';
      final isPureImage = r.images.isNotEmpty &&
          (isMangaSource || r.content.trim().isEmpty);
      if (isPureImage) {
        _cache[i] = const []; // 文本缓存置空，避免上一本的文字残留
        if (!prefetchOnly) {
          setState(() {
            _images = r.images;
            _chapterImages = const [];
            _paragraphs = const [];
            _invalidateTtsSegs();
            _pages = const [];
            _loading = false;
            _error = null;
          });
          await _saveProgress();
        }
        _prefetch(i + 1);
        return;
      }
      final paras = _splitParagraphs(r.content);
      _cache[i] = paras;
      _evictIfNeeded();
      if (!prefetchOnly) {
        setState(() {
          _paragraphs = paras;
          _invalidateTtsSegs();
          _images = const []; // 切回文字章节要把漫画图清掉
          // 文字章附带的插图（上游按 content-is-empty 已排除纯图章）
          _chapterImages = r.images;
          _loading = false;
          _error = null;
        });
        // 新章节 → 重新分页（分页模式）或清空分页（滚动模式）
        _paginate();
        if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(0);
        await _saveProgress();
      }
      _prefetch(i + 1);
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
  void _prefetch(int i) {
    if (i < 0 || i >= widget.chapters.length) return;
    // 🔴 **必须有窗口上限** ✗：原来只挡"越界 / 已缓存" ✓，于是每抓完一章又会
    // `_prefetch(i + 1)` ✓ → **打开一章 = 把整本几百章全抓一遍** ✓（几百次网络请求、
    // 几百次正文解析 ✓）；而缓存本身有上限（`_cacheLimit`，见下面 `_evictIfNeeded` ✓）
    // → 刚抓进来的很快又被淘汰 ✓，最后等于**白抓 + 白耗流量** ✓。
    // 只预取"当前章之后 2 章" ✓：保住"下一章秒开" ✓，同时让链式预取**到此为止** ✓
    //（`_index` 就是当前章 ✓，另见 `_loadChapter` 的 `i != _index` 与
    //  `_evictIfNeeded` 的 `(b - _index).abs()` ✓）
    if (i <= _index || i > _index + 2) return;
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
      ..showSnackBar(SnackBar(
        content: Text(m),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
      ));
  }

  // ── UI ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bg = _bgs[_bgIndex];
    // 自选图片（`_customBgPath`）：优先级最高 ✓
    final useFileBg =
        _customBgPath != null && File(_customBgPath!).existsSync();
    // 有任何图片背景（自选图 / 内置壁纸）⇒ Scaffold 底色透明，露出图片 ✓
    final useImgBg = useFileBg || _bgImageAsset != null;
    return Scaffold(
      backgroundColor: useImgBg ? Colors.transparent : bg[0],
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 背景层：自定义图片优先（cover 铺满），否则内置/自定义色
          if (useFileBg)
            Image.file(
              File(_customBgPath!),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => Container(color: bg[0]),
            )
          else if (_bgImageAsset != null)
            // 内置壁纸（14 张里选的一张 ✓）
            Image.asset(
              _bgImageAsset!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => Container(color: bg[0]),
            )
          else
            Container(color: bg[0]),
          GestureDetector(
            // 点屏幕中间切换菜单栏；点左/右 1/3 翻章
            onTapUp: (d) {
              final w = MediaQuery.of(context).size.width;
              final x = d.globalPosition.dx;
              if (_showBar || _showSettingsPanel) {
                setState(() {
                  _showBar = false;
                  _showSettingsPanel = false;
                });
                return;
              }
              // 翻页反转同样作用于整屏左 / 右 1/3 的翻章 ✓
              final flip = _rs.flipReverse;
              if (x < w * 0.3) {
                _go(flip ? 1 : -1);
              } else if (x > w * 0.7) {
                _go(flip ? -1 : 1);
              } else {
                setState(() => _showBar = true);
              }
            },
            child: SafeArea(
              child: Stack(
                children: [
                  Column(
                    children: [
                      Expanded(child: _contentArea(bg[1])),
                      _ttsMiniBar(bg[1]),
                    ],
                  ),
                  if (_showBar) _topBar(bg[1]),
                  // ✅ 底部功能栏改为**点菜单区才显示**（跟随 `_showBar` ✓），
                  //    并用 `Positioned` **覆盖**，不再常驻在 Column 里占正文高度 ——
                  //    用户实测："悬浮工具栏为啥一直显示？还占位置" ✗
                  //    （对齐漫画 / 图书两个阅读器：点中间才出上下栏 ✓）。
                  if (_showBar)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _bottomNav(bg[1]),
                    ),
                  // 右侧竖向悬浮栏（朗读 / 亮度 / 白夜 / 编辑）：与漫画阅读器同款。
                  // 设置面板从底部盖上来时让位（否则会被面板压住 ✗）。
                  if (_showBar && !_showSettingsPanel) _sideDock(bg[1]),
                  // 阅读设置面板拆成**独立开关**（只有功能栏里的「设置」打开它 ✓）——
                  // 否则点中间会连面板一起弹出、把刚出现的功能栏整个盖住 ✗。
                  if (_showSettingsPanel) _settingsPanel(bg[1]),
                  // 番茄钟浮层：bottom 动态计算，避免悬浮功能栏改后错位
                  if (_showPomodoro)
                    Obx(() => Positioned(
                          right: 12,
                          bottom: _pomodoroBottomOffset,
                          child: const PomodoroButton(),
                        )),
                  // 听书光碟（Cmbok 同款）：迷你条左滑收起后悬浮，点按展开回迷你条、
                  // 拖动换位置，朗读不停 ✓。封面用本书 coverUrl（缺省回退占位底色）。
                  if (_ttsDiscCollapsed)
                    Obx(() {
                      final active =
                          _tts.isSpeaking.value || _tts.isPaused.value;
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
                      final pos = _ttsDiscPos ??
                          Offset(size.width - 76, size.height - 210);
                      final cover = widget.coverUrl ??
                          widget.source.raw['coverUrl']?.toString();
                      return Positioned(
                        left: pos.dx.clamp(0.0, size.width - 60),
                        top: pos.dy.clamp(0.0, size.height - 60),
                        child: GestureDetector(
                          onTap: () =>
                              setState(() => _ttsDiscCollapsed = false),
                          onPanUpdate: (d) => setState(() {
                            _ttsDiscPos = Offset(
                              ((_ttsDiscPos?.dx ?? pos.dx) + d.delta.dx)
                                  .clamp(0.0, size.width - 60),
                              ((_ttsDiscPos?.dy ?? pos.dy) + d.delta.dy)
                                  .clamp(0.0, size.height - 60),
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
                  // 阅读悬浮球（截图里右下角那个球：单击翻页/双击菜单/拖动移动）
                  if (!_showBar) _readingBall(bg[1]),
                ],
              ),
            ),
          ),
        ],
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
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(height: 14),
            Text('正在加载正文...',
                style: TextStyle(fontSize: AppTheme.fontSubhead, color: fg.withValues(alpha: 0.6))),
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
              Icon(Icons.error_outline_rounded,
                  size: 44, color: fg.withValues(alpha: 0.4)),
              const SizedBox(height: 14),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: AppTheme.fontSubhead, color: fg.withValues(alpha: 0.7))),
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
            Icon(Icons.article_outlined,
                size: 40, color: fg.withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            Text('这一章没有正文',
                style: TextStyle(
                    fontSize: AppTheme.fontSubhead, color: fg.withValues(alpha: 0.6))),
            const SizedBox(height: 6),
            Text('（如果是漫画源，检查 ruleContent.content 是否返回图片）',
                style: TextStyle(
                    fontSize: AppTheme.fontFootnote, color: fg.withValues(alpha: 0.45))),
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
          return BookPageCurl(
            page: _pageContent(fg, _pages[pi]),
            nextPage: pi + 1 < _pages.length
                ? _pageContent(fg, _pages[pi + 1])
                : null,
            prevPage: pi > 0
                ? _pageContent(fg, _pages[pi - 1])
                : null,
            background: Container(color: _bgTop),
            canNext: pi + 1 < _pages.length,
            canPrev: pi > 0,
            onTurnNext: () {
              if (pi + 1 < _pages.length) {
                setState(() => _pageIndex = pi + 1);
              } else {
                _go(1);
              }
            },
            onTurnPrev: () {
              if (pi > 0) {
                setState(() => _pageIndex = pi - 1);
              } else {
                _go(-1);
              }
            },
            onTapCenter: () => setState(() => _showBar = !_showBar),
          );
        }

        // 双页模式：横屏左右并排（截图里的「双页模式」）
        final isLandscape =
            MediaQuery.of(context).orientation == Orientation.landscape;
        if (_rs.dualPage && isLandscape && _pages.length > 1) {
          // 把页成对合并：第 0 页单独，之后 (1,2) (3,4) …
          final spreads = <List<int>>[];
          for (var i = 0; i < _pages.length; i += 2) {
            if (i == 0) {
              spreads.add([0]);
            } else {
              spreads.add([i, if (i + 1 < _pages.length) i + 1]);
            }
          }
          return PageView.builder(
            controller: _pageCtrl,
            itemCount: spreads.length,
            onPageChanged: (i) {
              setState(() => _pageIndex = spreads[i].first);
              _saveProgress();
            },
            itemBuilder: (c, i) => Row(
              children: [
                for (final pi in spreads[i])
                  Expanded(child: _pageContent(fg, _pages[pi])),
              ],
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
              backgroundColor: _customBgColor ?? _bgs[_bgIndex][0],
              page: _pageContent(fg, _pages[pi]),
              nextPage: pi + 1 < _pages.length
                  ? _pageContent(fg, _pages[pi + 1])
                  : null,
              prevPage: pi > 0 ? _pageContent(fg, _pages[pi - 1]) : null,
              canNext: pi + 1 < _pages.length,
              canPrev: pi > 0,
              onTurnNext: () {
                if (pi + 1 < _pages.length) {
                  setState(() => _pageIndex = pi + 1);
                } else {
                  _go(1);
                }
              },
              onTurnPrev: () {
                if (pi > 0) {
                  setState(() => _pageIndex = pi - 1);
                } else {
                  _go(-1);
                }
              },
              onTapCenter: () => setState(() => _showBar = !_showBar),
            ),
          );
        }

        // 其余模式（左右 / 无动画）走 PageView
        return Stack(
          children: [
            withPressDownBookmark(
              PageView.builder(
                controller: _pageCtrl,
                physics: _rs.pageMode == PageMode.none
                    // 无动画：直接切换（拖动仍然可用，只是没有滑动惯性）
                    ? const ClampingScrollPhysics()
                    : const PageScrollPhysics(),
                itemCount: _pages.length,
                onPageChanged: (i) {
                  setState(() => _pageIndex = i);
                  _saveProgress();
                },
                itemBuilder: (context, i) => _pageContent(fg, _pages[i]),
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
    // 再兜一层 UA：源没配 header 时很多站直接拒
    if (!h.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      h['User-Agent'] =
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
          'Mobile/15E148 Safari/604.1';
    }
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
    return GestureDetector(
      // 点屏幕中间的 1/3 显隐工具栏；左右 1/3 翻章。
      // ✅ 补上"工具栏/面板已展开时，任意点击先收起"——与外层 Stack 手势一致 ✓。
      //    原来这里缺这一步 ✗ → 面板开着时左右点击会**翻页**而不是**收起面板** ✗。
      onTapUp: (d) {
        final w = MediaQuery.of(context).size.width;
        final x = d.localPosition.dx;
        if (_showBar || _showSettingsPanel) {
          setState(() {
            _showBar = false;
            _showSettingsPanel = false;
          });
          return;
        }
        // 翻页反转（左点下一页 / 右点上一页）在漫画模式同样生效 ✓
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
        } else {
          setState(() => _showBar = true);
        }
      },
      child: ListView.builder(
        padding: EdgeInsets.only(
            top: _padTop, bottom: _padBottom + 40),
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
                    Icon(Icons.broken_image_outlined,
                        size: 30, color: fg.withValues(alpha: 0.4)),
                    const SizedBox(height: 8),
                    Text('第 ${i + 1} 张加载失败',
                        style: TextStyle(
                            fontSize: AppTheme.fontFootnote, color: fg.withValues(alpha: 0.6))),
                    Text('（图床可能需要 Referer，或该图已失效）',
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption, color: fg.withValues(alpha: 0.45))),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 上下模式 / 分页失败时的兜底：整章滚动
  Widget _scrollView(Color fg) {
    return GestureDetector(
      // 点击区域的"菜单"动作（截图里的点击区域设置）
      onTapUp: (d) => _handleTap(d.localPosition, MediaQuery.of(context).size),
      child: SingleChildScrollView(
        padding:
            EdgeInsets.fromLTRB(_padLeft, _padTop, _padRight, _padBottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.chapters[_index].name,
              style: TextStyle(
                fontSize: _fontSize + 3,
                fontWeight: FontWeight.w700,
                color: fg,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            for (var pi = 0; pi < _paragraphs.length; pi++)
              _paragraphWidget(pi, fg),
          ],
        ),
      ),
    );
  }

  /// 一个段落的渲染（含首行缩进 / 字间距 / 字重 / 底线 / 书签竖线 / 划线背景 / 长按菜单）
  Widget _paragraphWidget(int pi, Color fg, {String? overrideText}) {
    final text = overrideText ?? _paragraphs[pi];
    final note = ReaderNotesService.instance.all.where((n) =>
        n.sourceId == widget.source.id &&
        n.bookName == widget.bookName &&
        n.chapterIndex == _index &&
        n.paragraphIndex == pi).firstOrNull;
    final hasNote = note != null;
    final noteBg = note == null
        ? null
        : Color(note.color).withValues(alpha: 0.35);
    return Padding(
      padding: EdgeInsets.only(bottom: _fontSize * _paraSpacing),
      child: GestureDetector(
        onLongPress: () => _onParagraphLongPress(pi),
        child: Container(
          decoration: BoxDecoration(
            color: noteBg,
            border: Border(
              left: BorderSide(
                color: _bookmarks[pi] ??
                    (note != null ? Color(note.color) : Colors.transparent),
                width: 3,
              ),
            ),
          ),
          padding: EdgeInsets.only(
              left: (_bookmarks.containsKey(pi) || hasNote) ? 8 : 0),
          child: _wrapWithHighlight(
            pi,
            Text(
              _indent > 0 ? '\u3000' * _indent.round() + text : text,
              style: _bodyStyle(fg),
            ),
          ),
        ),
      ),
    );
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
      Color(0xFFF5C842), Color(0xFF8FD48F), Color(0xFF7EC8F0),
      Color(0xFFF07E9E), Color(0xFFC88FE8), Color(0xFFA8B4E0),
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

  TextStyle _bodyStyle(Color fg, {bool bold = false, bool noUnderline = false}) =>
      TextStyle(
        fontSize: _fontSize,
        height: _lineHeight,
        letterSpacing: _letterSpacing,
        fontWeight: bold
            ? FontWeight.w700
            : _fontWeightToW(_fontWeight),
        color: fg,
        decoration: _underlineStyle == 0 || noUnderline
            ? TextDecoration.none
            : TextDecoration.underline,
        decorationColor:
            (_underlineColor ?? fg).withValues(alpha: _underlineAlpha),
        decorationStyle: _underlineStyle == 1
            ? TextDecorationStyle.dashed
            : _underlineStyle == 2
                ? TextDecorationStyle.dotted
                : _underlineStyle == 4
                    ? TextDecorationStyle.wavy
                    : TextDecorationStyle.solid,
        decorationThickness: _underlineWidth,
      );

  /// 页眉 + 页脚（信息栏）占掉的高度 —— 分页度量要把它从可用高度里减掉 ✓。
  /// 信息栏关闭（`statusItems` 为空）时两者都不渲染 ⇒ 返回 0 ✓。
  ///
  /// ⚠️ 状态文字没有显式 `height`，行高随字体（约 1.17~1.3 倍字号）——
  ///   这里按 **1.3** 估：宁可多留一点（页底略空），也不能少留（会把末行裁掉 ✗）。
  double _headerFooterHeight() {
    if (_rs.statusItems.isEmpty) return 0;
    final line = AppTheme.fontCaption * 1.3;
    final header = _headerPadTop + 6 + line + 4;
    final footer = 4 + line + _footerPadBottom + 6;
    return header + footer;
  }

  /// 一页的内容（含页眉 / 页脚信息栏）
  Widget _pageContent(Color fg, BookPage page) {
    // ✅ 每页铺**不透明底色**（+ 页缘软投影，见下）——
    //    原来每一页都是透明的 ✗ ⇒ 前后两页的文字叠在**同一块背景**上，
    //    用户实测："左右滑动是切片的形式"、"感觉重叠" ✗
    //    铺底后滑动时看到的是"两张纸在平移" ✓
    // ⚠️ 自定义背景图时不铺（否则会把图片盖掉 ✗）
    // 有**任何图片背景**（自选图 / 内置壁纸）时不铺页底色 ✓（否则会把图盖住 ✗）
    final imgBg =
        (_customBgPath != null && File(_customBgPath!).existsSync()) ||
            _bgImageAsset != null;
    final body = imgBg
        ? _pageBody(fg, page)
        : ColoredBox(
            color: _customBgColor ?? _bgs[_bgIndex][0],
            child: _pageBody(fg, page),
          );
    // 页缘投影：只在"两页并排平移"的模式（左右 / 无动画）画 —— 给两页之间
    // 一个可见的软边界；覆盖 / 仿真各有自己的投影，不重复画 ✓
    if (imgBg ||
        (_rs.pageMode != PageMode.slide &&
            _rs.pageMode != PageMode.none)) {
      return body;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
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

  /// 一页的**内容本体**（页眉 / 正文 / 页脚）。
  /// 由 [_pageContent] 包上底色（+ 页缘投影）后使用 ✓。
  Widget _pageBody(Color fg, BookPage page) {
    final items = _rs.statusItems;
    final progress = _pages.isEmpty
        ? 0.0
        : (_pageIndex.clamp(0, _pages.length - 1) + 1) / _pages.length;
    return GestureDetector(
      onTapUp: (d) => _handleTap(d.localPosition, _viewport),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 页眉 ────────────────────────────────────────────
          if (items.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  _headerPadH, _headerPadTop + 6, _headerPadH, 4),
              child: Row(
                children: [
                  if (items.contains('时间'))
                    _statusText(TimeOfDay.now().format(context), fg),
                  if (items.contains('书名'))
                    Expanded(
                      child: Text(widget.bookName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _statusStyle(fg)),
                    ),
                  const Spacer(),
                  if (items.contains('进度'))
                    _statusText('${(progress * 100).round()}%', fg),
                ],
              ),
            ),
          // ── 正文 ────────────────────────────────────────────
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 0),
              child: ListView.builder(
                physics: const NeverScrollableScrollPhysics(),
                // ✅ 左右 / 上下边距在这里**真正生效** —— 与 `_paginate` 的可用区域一致 ✓
                //   （原来写死 `(0, 2, 0, 2)` ✗ ⇒「排版」里的边距滑块调了没反应 ✗）
                padding: EdgeInsets.fromLTRB(
                    _padLeft, _padTop + 2, _padRight, _padTop + 2),
                itemCount: page.entries.length,
                itemBuilder: (c, i) {
                  final e = page.entries[i];
                  final b = e.block;
                  if (b is HeadingBlock) {
                    // 隐藏重复标题：章首标题与章节名相同时不再显示（IMG_8495）
                    final headingText = e.partialText ?? b.text;
                    if (_hideRepeatTitle &&
                        headingText.trim() ==
                            widget.chapters[_index].name.trim()) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Text(
                        headingText,
                        textAlign: _titleAlign == 1
                            ? TextAlign.center
                            : TextAlign.left,
                        style: TextStyle(
                          fontSize: _fontSize + 3,
                          fontWeight: FontWeight.w700,
                          color: fg,
                          height: 1.5,
                        ),
                      ),
                    );
                  }
                  if (b is ParagraphBlock) {
                    // 分页后可能是半段（partialText），直接用它的文本渲染；
                    // 🔴 段落下标用**分页器带下来的全书块下标**直接换算 ✓
                    // 本页 `blocks = [章标题, ...段落]` ⇒ 段落下标 = blockIndex - 1 ✓。
                    // 原实现 `_paragraphs.indexOf(b.text)` 会命中**第一个同文本段** ✗：
                    // 正文里重复段（空行、"……"、重复短句）的第 2 处及之后，
                    // 书签/批注都会落到第 1 处 ✗（与笔记定位同源的错位 ✓）。
                    final pi = e.blockIndex >= 0
                        ? e.blockIndex - 1
                        : _paragraphIndexOf(b);
                    // ✅ 首行缩进已在**分页块**里加过（见 `_paginate`）⇒ 这里直接用 ✓
                    //   （原来度量用原文、渲染再加 2 个全角空格 ✗ ⇒ 渲染比量出来的多占 36px 宽、
                    //    多折行 ⇒ 页面底部溢出被裁，看着就是"文字被切片" ✗）
                    final paraText = e.partialText ?? b.text;
                    // 满行底线（信纸）：每行拉满整行宽，用段落底边线实现（IMG_8497/8498）
                    Widget body = Text(
                      paraText,
                      style: _bodyStyle(
                          fg,
                          bold: _focusBold && pi == 0,
                          noUnderline: _underlineFull),
                    );
                    if (_underlineFull) {
                      body = Container(
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: (_underlineColor ?? fg)
                                  .withValues(alpha: _underlineAlpha),
                              width: _underlineWidth,
                            ),
                          ),
                        ),
                        child: body,
                      );
                    }
                    return Padding(
                      padding:
                          EdgeInsets.only(bottom: _fontSize * _paraSpacing),
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
          if (items.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  _footerPadH, 4, _footerPadH, _footerPadBottom + 6),
              child: Row(
                children: [
                  if (items.contains('章节'))
                    Expanded(
                      child: Text(widget.chapters[_index].name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _statusStyle(fg)),
                    ),
                  const Spacer(),
                  if (items.contains('电量')) _batteryText(fg),
                  if (items.contains('页码'))
                    _statusText('${_pageIndex + 1}/${_pages.length}', fg),
                ],
              ),
            ),
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
        final noPager = _rs.pageMode == PageMode.curl ||
            _rs.pageMode == PageMode.cover ||
            !_pageCtrl.hasClients;
        if (noPager) {
          setState(() => _pageIndex = _pageIndex + 1);
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
        final noPager = _rs.pageMode == PageMode.curl ||
            _rs.pageMode == PageMode.cover ||
            !_pageCtrl.hasClients;
        if (noPager) {
          setState(() => _pageIndex = _pageIndex - 1);
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
      fontSize: AppTheme.fontCaption, color: fg.withValues(alpha: 0.5));

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
  Widget _batteryText(Color fg) {
    return FutureBuilder<int?>(
      future: _tts.batteryLevel(),
      builder: (c, snap) => _statusText(
          snap.data == null ? '--%' : '${snap.data}%', fg),
    );
  }

  /// 点击分区处理（截图里的「点击区域」设置）
  void _handleTap(Offset pos, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    // 3×3 分区，下标 = row*3 + col
    final col = (pos.dx / (size.width / 3)).floor().clamp(0, 2);
    final row = (pos.dy / (size.height / 3)).floor().clamp(0, 2);
    var zone = row * 3 + col;
    // 单手模式：左右都是下一页（覆盖分区设置）
    final zones = _rs.tapZones.isEmpty
        ? ReadingSettings.defaultZones()
        : _rs.tapZones;
    var action = _rs.oneHand
        ? (zone == 4 ? TapAction.menu : TapAction.next)
        : (zones[zone] ?? TapAction.menu);
    // ✅ 接上「翻页反转」开关（原来只存不读 ✗ —— 面板里拨了毫无效果）：
    //    左点下一页、右点上一页 = 把「上一页 / 下一页」两个动作对调 ✓
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
        setState(() => _showBar = !_showBar);
      case TapAction.none:
        break;
    }
  }

  /// 顶栏日夜切换：浅色背景 ↔ 夜间背景（记住切走前的浅色索引）
  void _toggleDayNight() {
    setState(() {
      if (_customBgColor != null || _customBgPath != null) {
        // 自定义背景（色/图）时：清除并进入夜间，浅色索引记回默认白
        _customBgColor = null;
        _customBgPath = null;
        _dayBgIndex = 0;
        _bgIndex = 5;
      } else if (_bgIndex == 5) {
        _bgIndex = _dayBgIndex;
      } else {
        _dayBgIndex = _bgIndex;
        _bgIndex = 5;
      }
      _scheduleSavePrefs();
    });
  }

  /// 顶栏亮度：底部滑杆调系统屏幕亮度（screen_brightness）
  Future<void> _showBrightnessSheet() async {
    final fg = _fg;
    final bgTop = _bgTop;
    double current = 1.0;
    try {
      current = await ScreenBrightness().current;
    } catch (_) {}
    if (current < 0.05) current = 1.0; // 系统"自动亮度"返回 0 时按 1 展示
    final v = current.clamp(0.1, 1.0);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          var value = v;
          return Container(
            decoration: BoxDecoration(
              color: bgTop,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(18)),
            ),
            padding: EdgeInsets.only(
                top: 14,
                bottom: MediaQuery.of(context).padding.bottom + 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.brightness_6_rounded, size: 18, color: fg),
                    const SizedBox(width: 8),
                    Text('亮度',
                        style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            fontWeight: FontWeight.w700,
                            color: fg)),
                  ],
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      Icon(Icons.brightness_low_rounded,
                          size: 18, color: fg.withValues(alpha: 0.5)),
                      Expanded(
                        child: Slider(
                          value: value,
                          min: 0.1,
                          max: 1.0,
                          activeColor: fg,
                          inactiveColor: fg.withValues(alpha: 0.2),
                          onChanged: (nv) {
                            setSheet(() => value = nv);
                            ScreenBrightness().setScreenBrightness(nv);
                          },
                        ),
                      ),
                      Icon(Icons.brightness_high_rounded,
                          size: 18, color: fg.withValues(alpha: 0.5)),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _topBar(Color fg) {
    return Positioned(
      // ✅ 改成**悬浮卡片**（与底部功能栏同款：四周留白 + 四角圆 + 向下投影 ✓）——
      //    原来是 top:0 通栏贴边（`color:` 纯色背景 ✓），与底部悬浮卡风格不统一 ✗。
      top: 8,
      left: 12,
      right: 12,
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
            _topIcon(Icons.arrow_back_rounded, '返回',
                () => Navigator.pop(context), fg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.bookName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w600,
                          color: fg)),
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
                          color: fg.withValues(alpha: 0.6))),
                ],
              ),
            ),
            // 顶栏只留：搜索 / 刷新 / 书签
            //（朗读 / 亮度 / 白夜 / 编辑 已挪到右侧竖向悬浮栏 —— 用户要求，顶栏放 8 个太挤）
            _topIcon(Icons.search_rounded, '搜索全书', _showBookSearch, fg),
            _topIcon(Icons.refresh_rounded, '刷新本章',
                () => _loadChapter(_index), fg),
            _topIcon(
              _bookmarks.isEmpty
                  ? Icons.bookmark_border_rounded
                  : Icons.bookmark_rounded,
              _bookmarks.isEmpty
                  ? '加书签'
                  : '本书已有 ${_bookmarks.length} 个书签',
              () => _showAddBookmark(0),
              fg,
            ),
          ],
        ),
      ),
    );
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
  Widget _sideDock(Color fg) {
    final ink = _bgIndex == 5 && _customBgColor == null;
    return Positioned(
      right: 12,
      top: 0,
      bottom: 0,
      child: Center(
        child: Container(
          width: 46,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: _bgTop.withValues(alpha: 0.97),
            borderRadius: BorderRadius.circular(23),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.16),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dockButton(Icons.record_voice_over_outlined, '朗读',
                  () => _showTtsSheet(), fg),
              const SizedBox(height: 10),
              _dockButton(Icons.brightness_6_rounded, '亮度',
                  _showBrightnessSheet, fg),
              const SizedBox(height: 10),
              _dockButton(
                  ink ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                  ink ? '切换白天' : '切换夜间',
                  _toggleDayNight,
                  fg),
              const SizedBox(height: 10),
              // 对齐 Cmbok：书源书籍的阅读器「编辑」= 编辑该书源
              // （划线与笔记入口在底部宫格「笔记」里，不冲突）
              _dockButton(Icons.edit_outlined, '书源编辑', () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        BookSourceEditorPage(source: widget.source),
                  ),
                );
              }, fg),
              const SizedBox(height: 10),
              // 番茄钟从底部宫格挪到这里（宫格让位给「夜间模式」，对齐 Cmbok 截图）
              _dockButton(Icons.timer_outlined, '番茄钟',
                  () => setState(() => _showPomodoro = !_showPomodoro), fg),
            ],
          ),
        ),
      ),
    );
  }

  /// 竖条里的圆形按钮。
  Widget _dockButton(
      IconData icon, String tooltip, VoidCallback onTap, Color fg) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: fg.withValues(alpha: 0.08),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 20, color: fg.withValues(alpha: 0.9)),
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
      final rateLabel =
          '${rate.toStringAsFixed(1).replaceAll('.0', '')}×';
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
                    color: fg.withValues(alpha: 0.7)),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '上一句',
              onPressed: () => _tts.jumpTo(i - 1),
              icon: Icon(Icons.skip_previous_rounded,
                  size: 22, color: fg.withValues(alpha: 0.85)),
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
              icon: Icon(Icons.stop_rounded, size: 22, color: fg.withValues(alpha: 0.85)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '下一句',
              onPressed: () => _tts.jumpTo(i + 1),
              icon: Icon(Icons.skip_next_rounded,
                  size: 22, color: fg.withValues(alpha: 0.85)),
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
              child: Text(rateLabel,
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      color: fg)),
            ),
            // 更多 → 朗读面板
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '更多',
              onPressed: () => _showTtsSheet(),
              icon: Icon(Icons.more_horiz_rounded, size: 22, color: fg.withValues(alpha: 0.85)),
            ),
            // 全屏听书（参考图 IMG_8509）
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '全屏听书',
              onPressed: _openFullTtsPlayer,
              icon: Icon(Icons.fullscreen_rounded, size: 20, color: fg.withValues(alpha: 0.85)),
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
          coverUrl: widget.coverUrl ?? widget.source.raw['coverUrl']?.toString(),
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
                icon: Icon(Icons.chevron_left_rounded,
                    size: 24, color: fg.withValues(alpha: 0.85)),
              ),
              if (pageMode)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text('${_pageIndex + 1}',
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: FontWeight.w600,
                          color: fg.withValues(alpha: 0.85))),
                ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 7),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: fg.withValues(alpha: 0.75),
                    inactiveTrackColor: fg.withValues(alpha: 0.18),
                    thumbColor: fg.withValues(alpha: 0.85),
                  ),
                  child: pageMode
                      ? Slider(
                          value: (_pageIndex + 1)
                              .toDouble()
                              .clamp(1.0, _pages.length.toDouble()),
                          min: 1,
                          max: _pages.length.toDouble().clamp(1.0, 1e9),
                          onChanged: (v) {
                            final i = v.round() - 1;
                            if (i != _pageIndex) {
                              if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(i);
                            }
                          },
                        )
                      : Slider(
                          value: (_index + 1).toDouble().clamp(
                              1.0, widget.chapters.length.toDouble()),
                          min: 1,
                          max: widget.chapters.length.toDouble().clamp(1.0, 1e9),
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
                  child: Text('${_pages.length}',
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: FontWeight.w600,
                          color: fg.withValues(alpha: 0.85))),
                ),
              IconButton(
                onPressed: pageMode ? _nextPageOrChapter : () => _go(1),
                icon: Icon(Icons.chevron_right_rounded,
                    size: 24, color: fg.withValues(alpha: 0.85)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          // ── 8 宫格（Cmbok 截图第一行：夜间模式 / 朗读 / AI / 图片模式）──
          Row(
            children: [
              _navItem(Icons.dark_mode_outlined, '夜间模式',
                  _toggleDayNight, fg),
              _navItem(Icons.record_voice_over_outlined, '朗读',
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
                                coverUrl: widget.coverUrl ??
                                    widget.source.raw['coverUrl']?.toString(),
                                chapterNames: [
                                  for (final c in widget.chapters) c.name
                                ],
                                onSelectChapter: (ci) {
                                  if (ci != _index) {
                                    setState(() => _index = ci);
                                    _loadChapter(ci);
                                    _saveProgress();
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                      if (mounted) _startTts();
                                    });
                                  }
                                },
                              ),
                            ),
                          );
                        }
                      : () => _showTtsSheet(),
                  fg),
              _navItem(Icons.auto_awesome_rounded, 'AI',
                  _showAiSummary, fg),
              _navItem(Icons.image_outlined, '图片模式',
                  _showImageMode, fg),
            ],
          ),
          const SizedBox(height: 8),
          // ── 第二行（Cmbok 截图第二行：笔记 / 排版 / 设置 / 目录）──
          Row(
            children: [
              _navItem(Icons.edit_note_rounded, '笔记',
                  () => _showToc(initialTab: 2), fg),
              _navItem(Icons.text_fields_rounded, '排版',
                  _showLayoutSheet, fg),
              _navItem(Icons.settings_outlined, '设置',
                  () => setState(() => _showSettingsPanel = true), fg),
              _navItem(Icons.menu_book_rounded, '目录', _showToc, fg),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  /// 宫格里的一个项（图标 + 文字）
  Widget _navItem(
      IconData icon, String label, VoidCallback onTap, Color fg) {
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
              Text(label,
                  style: TextStyle(
                      fontSize: AppTheme.fontFootnote, color: fg.withValues(alpha: 0.88))),
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
      debugPrint('[BsrReader] _pageIndex 越界夹取: $i -> $cl (共 ${_pages.length} 页)');
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
        _pageIndex = 0;
      }
      _pagesChapter = chapter;
    });
    final blocks = <BookBlock>[
      // 章标题当 heading 块，保证它自己起一页
      BookBlock.heading(widget.chapters[_index].name, 1),
      // ✅ 首行缩进**一并交给分页度量**（渲染侧不再重复加 ✓）
      //   否则渲染比量出来的多占宽、多折行 ⇒ 页面底部溢出被裁 ✗
      ..._paragraphs.map((p) => BookBlock.paragraph(
          _indent > 0 ? '\u3000' * _indent.round() + p : p)),
    ];
    // 🔴 分页的"可用区域"必须与**实际渲染**一致 ✗（原来两处对不上 ✓）：
    //   · 横向：渲染侧给正文 ListView 加了 `_padLeft/_padRight`（本轮补上 ✓）
    //   · 纵向：渲染侧上 / 下还有**页眉 + 页脚**占位 ✓
    //     原来 `viewportHeight` 直接用整块高度 ✗ ⇒ 量出来的页比真正能放文本的
    //     区域高约一个页眉 + 页脚 ⇒ 每页最后一行被裁 ✗
    final typo = BookTypography(
      fontSize: _fontSize,
      lineHeight: _lineHeight,
      padding: (_padLeft + _padRight) / 2,
      verticalPadding: _padTop,
      fontFamily: null,
    );
    final textAreaH =
        (_viewport.height - _headerFooterHeight()).clamp(1.0, _viewport.height);
    try {
      final pg = BookPaginator(
        blocks: blocks,
        viewportWidth: _viewport.width,
        viewportHeight: textAreaH,
        typo: typo,
        chapterStarts: const {0},
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
        _pageIndex = anchor == null ? 0 : _pageIndexForAnchor(anchor, out);
        _pagesChapter = chapter;
        _paginating = false;
      });
      _pageAnchor = null;
    } catch (_) {
      // 分页失败就退回整章滚动 —— 能读比"分页正确"重要
      if (mounted && gen == _paginateGen) {
        setState(() {
          _pages = const [];
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
                  final to = (at + query.length + 20).clamp(0, paras[pi].length);
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
            padding:
                EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Container(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.85),
              decoration: BoxDecoration(
                color: _bgTop,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(22)),
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
                            icon: Icon(Icons.arrow_back_rounded,
                                size: 22, color: _fg),
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
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: _fg.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(17),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.search_rounded,
                                      size: 16, color: _fgMuted),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: TextField(
                                      controller: ctrl,
                                      autofocus: true,
                                      onChanged: run,
                                      style: TextStyle(
                                          fontSize: AppTheme.fontFootnote,
                                          color: _fg),
                                      decoration: InputDecoration(
                                        hintText: '搜索全书内容',
                                        hintStyle: TextStyle(
                                            fontSize: AppTheme.fontFootnote,
                                            color: _fgMuted),
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
                          style:
                              TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted),
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
                                      color: _fgMuted),
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
                                        fontSize: AppTheme.fontBody, color: _fg),
                                  ),
                                  subtitle: r.para < 0
                                      ? null
                                      : Text('…${r.snippet}…',
                                          style: TextStyle(
                                              fontSize: AppTheme.fontFootnote, color: _fgMuted)),
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
                BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.82),
            decoration: BoxDecoration(
              color: _bgTop,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(22)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── 标题行：排版 + 独立排版开关 ────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Row(
                      children: [
                        Text('排版',
                            style: TextStyle(
                                fontSize: AppTheme.fontTitle3,
                                fontWeight: FontWeight.w700,
                                color: _fg)),
                        const Spacer(),
                        Text('独立排版',
                            style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted)),
                        const SizedBox(width: 4),
                        // ✅ 已接线（不再是假控件 ✓）：拨动即写 / 删 `BsrIndependentLayout`
                        //   的本书记录（`enable/disable(_indepKey, _layoutSnapshot())` ✓），
                        //   下次进这本书时 `_restorePrefs` 会把覆盖项读回来 ✓。
                        //   ℹ️ 排版行、朗读面板、阅读设置面板三处共用同一个 `_independent` ✓。
                        Switch(
                            value: _independent,
                            onChanged: (v) async {
                              setState(() => _independent = v);
                              if (v) {
                                await BsrIndependentLayout.instance
                                    .enable(_indepKey, _layoutSnapshot());
                              } else {
                                await BsrIndependentLayout.instance
                                    .disable(_indepKey);
                              }
                              _scheduleSavePrefs();
                              if (mounted) setState(() {});
                            }),
                      ],
                    ),
                  ),
                  // ── 5 个 tab ──────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (var i = 0; i < _layoutTabs.length; i++)
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setSheet(() => tab = i),
                              child: Container(
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 3),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 9),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: tab == i
                                      ? _fg.withValues(alpha: 0.85)
                                      : _fg.withValues(alpha: 0.06),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  _layoutTabs[i],
                                  style: TextStyle(
                                    fontSize: AppTheme.fontBody,
                                    fontWeight: tab == i
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                    color: tab == i
                                        ? _bgTop
                                        : _fg,
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
                          if (tab == 0) ..._layoutPresetTab(ctx, setSheet),
                          if (tab == 1) ..._layoutThemeTab(upd),
                          if (tab == 2) ..._layoutTextTab(updLayout),
                          if (tab == 3) ..._layoutMarginTab(updLayout),
                          if (tab == 4) ..._layoutUnderlineTab(upd),
                        ],
                      ),
                    ),
                  ),
                  // ── 底部按钮：取消 · 存预设 · 阅读 · 确认 ──────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text('取消',
                              style: TextStyle(fontSize: AppTheme.fontBody, color: _fg)),
                        ),
                        TextButton(
                          onPressed: () => _showSavePresetDialog(ctrl),
                          child: Text('存预设',
                              style: TextStyle(fontSize: AppTheme.fontBody, color: _fg)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text('阅读',
                              style: TextStyle(fontSize: AppTheme.fontBody, color: _fg)),
                        ),
                        const Spacer(),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: FilledButton.styleFrom(
                            backgroundColor: _fg.withValues(alpha: 0.9),
                            foregroundColor: _bgTop,
                          ),
                          child: const Text('确认'),
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

  static const _layoutTabs = ['预设', '主题', '文字', '边距', '底线'];

  /// 「预设」tab：暂无预设 → 提示"调好排版后点「存预设」"
  List<Widget> _layoutPresetTab(BuildContext ctx, StateSetter setSheet) {
    final presets = _savedPresets;
    if (presets.isEmpty) {
      return [
        const SizedBox(height: 30),
        Center(
          child: Text('暂无预设，调好排版后点「存预设」',
              style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fgMuted)),
        ),
        const SizedBox(height: 30),
      ];
    }
    return [
      for (final name in presets)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(name, style: TextStyle(fontSize: AppTheme.fontBody, color: _fg)),
          trailing: IconButton(
            icon: Icon(Icons.delete_outline, size: 20, color: _fgMuted),
            onPressed: () => setSheet(() => _savedPresets.remove(name)),
          ),
          onTap: () => _applyPreset(name),
        ),
    ];
  }

  /// 「背景图」里的一张小卡片（asset = null ⇒ 「无」= 不用壁纸）。
  Widget _bgImageChip(String? asset, void Function(VoidCallback) upd) {
    final selected = _bgImageAsset == asset;
    return GestureDetector(
      onTap: () => upd(() => _bgImageAsset = asset),
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
            ? Text('无',
                style: TextStyle(fontSize: AppTheme.fontCaption, color: _fg))
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
                  Text(bgNames[i],
                      style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg)),
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
                Text('自定义',
                    style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg)),
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
              onTap: () => upd(() => _fgOverride = fgColors[i]),
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
                  Text(fgNames[i],
                      style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg)),
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
              if (picked != null) upd(() => _fgOverride = picked);
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
                Text('自定义',
                    style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg)),
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
            onTap: () => upd(() => _customBgColor = null),
            child: Container(
              margin: const EdgeInsets.only(right: 10),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: _customBgColor == null
                    ? _fg.withValues(alpha: 0.85)
                    : _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('无',
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: _customBgColor == null ? _bgTop : _fg)),
            ),
          ),
          // 内置：16 款内置背景（参考图 IMG_8502「共16款，点击即用」）
          GestureDetector(
            onTap: () => _showBuiltinBgPanel(upd),
            child: Container(
              margin: const EdgeInsets.only(right: 10),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('内置',
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead, color: _fg)),
            ),
          ),
          // 选择图片：走系统图库（ImagePicker 由系统文件选择实现）
          GestureDetector(
            onTap: () => _showImageBgPicker(upd),
            child: Container(
              margin: const EdgeInsets.only(right: 10),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('选择图片',
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead, color: _fg)),
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
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
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
                  Text('内置背景',
                      style: TextStyle(
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w700,
                          color: _fg)),
                  const SizedBox(height: 4),
                  Text('共16款，点击即用',
                      style: TextStyle(
                          fontSize: AppTheme.fontFootnote, color: _fgMuted)),
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
                              Text(e.$1,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: AppTheme.fontFootnote,
                                      color: _fg)),
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
        _customBgColor = null; // 图片背景优先于颜色
      });
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

  /// 「文字」tab：字号/字重/段间距/字间距/行距/字体/标题对齐/隐藏重复标题
  List<Widget> _layoutTextTab(void Function(VoidCallback) upd) {
    return [
      _layoutSlider('字号', _fontSize, 12, 30, '${_fontSize.round()}',
          (v) => upd(() => _fontSize = v)),
      _layoutSlider('字重', _fontWeight, 300, 900, '${_fontWeight.round()}',
          (v) => upd(() => _fontWeight = v)),
      _layoutSlider('段间距', _paraSpacing, 0, 3, '${_paraSpacing.toStringAsFixed(1)}x',
          (v) => upd(() => _paraSpacing = v)),
      _layoutSlider('字间距', _letterSpacing, 0, 5, _letterSpacing.toStringAsFixed(1),
          (v) => upd(() => _letterSpacing = v)),
      _layoutSlider('行距', _lineHeight, 1.2, 2.6, _lineHeight.toStringAsFixed(1),
          (v) => upd(() => _lineHeight = v)),
      const SizedBox(height: 6),
      _layoutLabel('字体'),
      Row(
        children: [
          for (final n in ['跟随模式', '系统默认'])
            Container(
              margin: const EdgeInsets.only(right: 10),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: n == '跟随模式'
                    ? _fg.withValues(alpha: 0.85)
                    : _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(n,
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: n == '跟随模式' ? _bgTop : _fg)),
            ),
        ],
      ),
      const SizedBox(height: 14),
      _layoutLabel('标题对齐'),
      Row(
        children: [
          for (final n in ['靠左', '居中'])
            Container(
              margin: const EdgeInsets.only(right: 10),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              decoration: BoxDecoration(
                color: _titleAlign == (n == '靠左' ? 0 : 1)
                    ? _fg.withValues(alpha: 0.85)
                    : _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(n,
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: _titleAlign == (n == '靠左' ? 0 : 1)
                          ? _bgTop
                          : _fg)),
            ),
        ],
      ),
      const SizedBox(height: 6),
      _layoutToggleRow('专注加粗', '长段开头加粗描述', _focusBold,
          (v) => upd(() => _focusBold = v)),
      const SizedBox(height: 12),
      _layoutLabel('标题样式'),
      Row(
        children: [
          for (final n in ['朴素'])
            Container(
              margin: const EdgeInsets.only(right: 10),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              decoration: BoxDecoration(
                color: _titleStyle == 0
                    ? _fg.withValues(alpha: 0.85)
                    : _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(n,
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: _titleStyle == 0 ? _bgTop : _fg)),
            ),
        ],
      ),
      const SizedBox(height: 6),
      _layoutToggleRow(
          '隐藏重复标题', '章首正文与章名相同时不再显示一遍（默认开）',
          _hideRepeatTitle, (v) => upd(() => _hideRepeatTitle = v)),
      const SizedBox(height: 14),
      _layoutLabel('首行缩进'),
      _layoutSlider('缩进', _indent, 0, 4, '${_indent.round()}',
          (v) => upd(() => _indent = v)),
    ];
  }

  /// 排版面板里的开关行（标题 + 说明 + Switch）
  Widget _layoutToggleRow(String title, String desc, bool value,
      ValueChanged<bool> onChanged) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: _fg)),
              const SizedBox(height: 3),
              Text(desc,
                  style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted)),
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
      _layoutSlider('左边距', _padLeft, 0, 60, '${_padLeft.round()}',
          (v) => upd(() => _padLeft = v)),
      _layoutSlider('右边距', _padRight, 0, 60, '${_padRight.round()}',
          (v) => upd(() => _padRight = v)),
      _layoutSlider('上边距', _padTop, 0, 60, '${_padTop.round()}',
          (v) => upd(() => _padTop = v)),
      _layoutSlider('下边距', _padBottom, 0, 60, '${_padBottom.round()}',
          (v) => upd(() => _padBottom = v)),
      const SizedBox(height: 10),
      _layoutLabel('页眉（负值移进状态栏区域）'),
      _layoutSlider('左右边距', _headerPadH, 0, 40, '${_headerPadH.round()}',
          (v) => upd(() => _headerPadH = v)),
      _layoutSlider('上边距', _headerPadTop, -20, 40, '${_headerPadTop.round()}',
          (v) => upd(() => _headerPadTop = v)),
      const SizedBox(height: 10),
      _layoutLabel('页脚'),
      _layoutSlider('左右边距', _footerPadH, 0, 40, '${_footerPadH.round()}',
          (v) => upd(() => _footerPadH = v)),
      _layoutSlider('下边距', _footerPadBottom, -20, 40, '${_footerPadBottom.round()}',
          (v) => upd(() => _footerPadBottom = v)),
      const SizedBox(height: 8),
      Text('页眉/页脚需要正文分页器配合才显示，当前阅读器是整章滚动。',
          style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted)),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: _underlineStyle == i
                      ? _fg.withValues(alpha: 0.85)
                      : _fg.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(styles[i],
                    style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        color: _underlineStyle == i
                            ? _bgTop
                            : _fg)),
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
              onTap: () => upd(() => _underlineColor =
                  n == '跟随文字' ? null : _underlineColors[n]),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: (_underlineColor == (n == '跟随文字' ? null : _underlineColors[n]))
                      ? _fg.withValues(alpha: 0.85)
                      : _fg.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(n,
                    style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: (_underlineColor == (n == '跟随文字' ? null : _underlineColors[n]))
                            ? _bgTop
                            : _fg)),
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
              child: Text('自定义',
                  style: TextStyle(
                      fontSize: AppTheme.fontFootnote, color: _fg)),
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      _layoutSlider('透明度', _underlineAlpha * 100, 0, 100,
          '${(_underlineAlpha * 100).round()}%',
          (v) => upd(() => _underlineAlpha = v / 100)),
      _layoutSlider('粗细', _underlineWidth, 0.5, 4, _underlineWidth.toStringAsFixed(1),
          (v) => upd(() => _underlineWidth = v)),
      _layoutSlider('下间隔', _underlineGap, 0, 10, _underlineGap.toStringAsFixed(1),
          (v) => upd(() => _underlineGap = v)),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('满行底线',
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: FontWeight.w600,
                        color: _fg)),
                const SizedBox(height: 3),
                Text('开 = 每行拉满整行宽（信纸）；关 = 跟随文字宽',
                    style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted)),
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
        child: Text(s,
            style:
                TextStyle(fontSize: AppTheme.fontBody, fontWeight: FontWeight.w600, color: _fg)),
      );

  /// 当前页首段下标（按住下滑书签的锚点 ✓）：blocks = [章标题, ...段落] ⇒
  /// 段落下标 = blockIndex - 1（见本文件 :1787 同款换算 ✓）。空页 / 漫画回退 0。
  int _currentPageAnchorParagraph() {
    if (_images.isNotEmpty || _pages.isEmpty) return 0;
    final p = _pages[_safePageIndex()];
    if (p.entries.isEmpty) return 0;
    final e = p.entries.first;
    final bi = e.blockIndex >= 0 ? e.blockIndex : p.firstBlockIndex;
    return bi > 0 ? bi - 1 : 0;
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
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('添加书签',
                      style: TextStyle(
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w700,
                          color: _fg)),
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
                            style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg),
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
                  style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted),
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
    }
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
            Text(label,
                style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fg)),
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
        title: Text('写批注',
            style: TextStyle(fontSize: AppTheme.fontTitle3, color: _fg)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text.length > 60 ? '${text.substring(0, 60)}…' : text,
              style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted),
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
                hintStyle:
                    TextStyle(fontSize: AppTheme.fontSubhead, color: _fgMuted),
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
            child: Text('取消',
                style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fgMuted)),
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
      _underlineStyle = (m['underlineStyle'] as num?)?.toInt() ?? _underlineStyle;
      _underlineAlpha = (m['underlineAlpha'] as num?)?.toDouble() ?? _underlineAlpha;
      _underlineWidth = (m['underlineWidth'] as num?)?.toDouble() ?? _underlineWidth;
      _underlineGap = (m['underlineGap'] as num?)?.toDouble() ?? _underlineGap;
      _underlineFull = m['underlineFull'] as bool? ?? _underlineFull;
      _fontWeight = (m['fontWeight'] as num?)?.toDouble() ?? _fontWeight;
      _letterSpacing = (m['letterSpacing'] as num?)?.toDouble() ?? _letterSpacing;
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
      _applyPresetMap(
          Map<String, dynamic>.from(jsonDecode(raw) as Map));
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
        title: Text('保存排版预设',
            style: TextStyle(fontSize: AppTheme.fontTitle3, color: _fg)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '预设名',
            labelStyle: TextStyle(fontSize: AppTheme.fontSubhead, color: _fgMuted),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text('取消', style: TextStyle(color: _fgMuted))),
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
      await p.setString(
          'reading.preset.$name', jsonEncode(_presetSnapshot()));
    } catch (_) {}
    setState(() {
      if (!_savedPresets.contains(name)) _savedPresets.add(name);
    });
    await _savePrefs();
    _toast('已保存预设「$name」');
  }

  /// 排版面板里的一行"标签 + 滑块 + 减 + 数值 + 加"
  Widget _layoutSlider(String label, double value, double min, double max,
      String display, ValueChanged<double> onChanged) {
    final step = (max - min) / 20;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text(label, style: TextStyle(fontSize: AppTheme.fontBody, color: _fg)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => onChanged((value - step).clamp(min, max)),
            icon: Icon(Icons.remove, size: 17, color: _fgMuted),
          ),
          SizedBox(
            width: 46,
            child: Text(display,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                    color: _fg)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => onChanged((value + step).clamp(min, max)),
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
                BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
            decoration: BoxDecoration(
              color: _bgTop,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(22)),
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
                        Text('朗读',
                            style: TextStyle(
                                fontSize: AppTheme.fontTitle3,
                                fontWeight: FontWeight.w700,
                                color: _fg)),
                        const Spacer(),
                        Text('独立设置',
                            style: TextStyle(
                                fontSize: AppTheme.fontSubhead, color: _fgMuted)),
                        const SizedBox(width: 4),
                        // ✅ 与排版行的「独立排版」同源（同一个 `_independent` ✓），已接线：
                        //   拨动即写 / 删 `BsrIndependentLayout` 的本书记录 ✓。
                        Switch(
                            value: _independent,
                            onChanged: (v) async {
                              setState(() => _independent = v);
                              if (v) {
                                await BsrIndependentLayout.instance
                                    .enable(_indepKey, _layoutSnapshot());
                              } else {
                                await BsrIndependentLayout.instance
                                    .disable(_indepKey);
                              }
                              _scheduleSavePrefs();
                              if (mounted) setState(() {});
                            }),
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
                            fontSize: AppTheme.fontSubhead, height: 1.5, color: _fgMuted),
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
                          onPressed: () => _tts.jumpTo(
                              _tts.currentIndex.value - 1),
                          icon: Icon(Icons.skip_previous_rounded,
                              size: 30, color: _fgMuted),
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
                          onPressed: () => _tts.jumpTo(
                              _tts.currentIndex.value + 1),
                          icon: Icon(Icons.skip_next_rounded,
                              size: 30, color: _fgMuted),
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
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 3),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 9),
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
                                    color: tab == i
                                        ? _bgTop
                                        : _fg,
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
                          child: Text('停止朗读',
                              style:
                                  TextStyle(fontSize: AppTheme.fontBody, color: _fg)),
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

  static const _ttsTabs = ['声音', '跟读', '定时', '高级'];

  /// 开始朗读本章
  Future<void> _startTts() async {
    final text = _paragraphs.join('\n');
    if (text.trim().isEmpty) {
      _toast('这一章没有可朗读的正文');
      return;
    }
    // 念完自动进下一章（长按连续听书）
    _tts.onFinished = () {
      if (!mounted) return;
      _go(1);
      // 下一章加载后自动续读
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tts.isSpeaking.value == false) _startTts();
      });
    };
    // TtsService 自己切段（splitSegments 会按标点再切过长段）
    await _tts.speak(text);
    if (mounted) setState(() {});
  }

  List<Widget> _ttsVoiceTab(void Function(VoidCallback) upd) {
    return [
      // ── 语速 / 音调 / 音量（参考图 IMG_8489 的 − 值 + 样式）──
      Obx(() => _ttsStepper('语速', '${_tts.rate.value.toStringAsFixed(2)}x',
          onMinus: () {
            upd(() {});
            _tts.setRate((_tts.rate.value - 0.05).clamp(0.5, 2.0));
          },
          onPlus: () {
            upd(() {});
            _tts.setRate((_tts.rate.value + 0.05).clamp(0.5, 2.0));
          })),
      Obx(() => _ttsStepper('音调', _tts.pitch.value.toStringAsFixed(2),
          onMinus: () {
            upd(() {});
            _tts.setPitch((_tts.pitch.value - 0.05).clamp(0.5, 2.0));
          },
          onPlus: () {
            upd(() {});
            _tts.setPitch((_tts.pitch.value + 0.05).clamp(0.5, 2.0));
          })),
      _ttsStepper('音量', '$_ttsVolume%', onMinus: () {
        upd(() => _ttsVolume = (_ttsVolume - 5).clamp(0, 100));
      }, onPlus: () {
        upd(() => _ttsVolume = (_ttsVolume + 5).clamp(0, 100));
      }),
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
                  Text('音色',
                      style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w600,
                          color: _fg)),
                  const SizedBox(height: 2),
                  Text(_ttsFollowSystem ? '系统朗读 · 跟随系统' : '系统朗读',
                      style: TextStyle(
                          fontSize: AppTheme.fontFootnote, color: _fgMuted)),
                ],
              ),
              const Spacer(),
              Text('1个', style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg)),
              Icon(Icons.chevron_right_rounded, size: 18, color: _fgMuted),
            ],
          ),
        ),
      ),
      Divider(color: _fg.withValues(alpha: 0.10)),
      // ── 朗读引擎（参考图 IMG_8489：更换 / 试听）──
      InkWell(
        onTap: () async {
          Navigator.pop(context);
          await Navigator.push(context,
              MaterialPageRoute(builder: (_) => const TtsEnginePage()));
          if (mounted) setState(() {});
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Icon(Icons.record_voice_over_rounded,
                  size: 20, color: _fg),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('朗读引擎',
                      style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w600,
                          color: _fg)),
                  const SizedBox(height: 2),
                  Text('系统朗读 · 跟随系统',
                      style:
                          TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted)),
                ],
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => _ttsSpeakSample(),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: _fg.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text('试听',
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: FontWeight.w600,
                          color: _fg)),
                ),
              ),
              const SizedBox(width: 8),
              Text('更换', style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg)),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: _fgMuted),
            ],
          ),
        ),
      ),
      Divider(color: _fg.withValues(alpha: 0.10)),
      Text(
        '音量由系统控制，此处仅记录偏好。'
        '语速/音调改完立刻对下一句生效。',
        style: TextStyle(fontSize: AppTheme.fontFootnote, height: 1.7, color: _fgMuted),
      ),
    ];
  }

  /// 朗读面板里的「− 值 +」步进行（参考图 IMG_8489）
  Widget _ttsStepper(String label, String display,
      {required VoidCallback onMinus, required VoidCallback onPlus}) {
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
            child: Text(label,
                style: TextStyle(fontSize: AppTheme.fontBody, color: _fg)),
          ),
          const Spacer(),
          btn(Icons.remove_rounded, onMinus),
          Container(
            width: 76,
            alignment: Alignment.center,
            child: Text(display,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                    color: _fg)),
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
                maxHeight: MediaQuery.of(ctx).size.height * 0.55),
            decoration: BoxDecoration(
              color: _bgTop,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(22)),
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
                        Text('音色（共 1 个）',
                            style: TextStyle(
                                fontSize: AppTheme.fontTitle3,
                                fontWeight: FontWeight.w700,
                                color: _fg)),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => Navigator.pop(ctx),
                          child: Icon(Icons.expand_more_rounded,
                              size: 26, color: _fgMuted),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                    child: Text('音色跟随系统设置 · 文字转语音；换引擎在朗读引擎设置里',
                        style: TextStyle(
                            fontSize: AppTheme.fontFootnote,
                            height: 1.5,
                            color: _fgMuted)),
                  ),
                  const SizedBox(height: 4),
                  // 系统朗读
                  InkWell(
                    onTap: () => upd(() => _ttsFollowSystem = false),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      child: Row(
                        children: [
                          Icon(Icons.record_voice_over_rounded,
                              size: 20, color: _fg),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text('系统朗读',
                                style: TextStyle(
                                    fontSize: AppTheme.fontBody,
                                    fontWeight: FontWeight.w600,
                                    color: _fg)),
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
                      endIndent: 20),
                  // 跟随系统
                  InkWell(
                    onTap: () => upd(() => _ttsFollowSystem = true),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      child: Row(
                        children: [
                          Icon(Icons.settings_suggest_rounded,
                              size: 20, color: _fg),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('跟随系统',
                                    style: TextStyle(
                                        fontSize: AppTheme.fontBody,
                                        fontWeight: FontWeight.w600,
                                        color: _fg)),
                                Text('用系统当前默认音色',
                                    style: TextStyle(
                                        fontSize: AppTheme.fontFootnote,
                                        color: _fgMuted)),
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

  List<Widget> _ttsFollowTab(void Function(VoidCallback) upd) {
    const styles = ['◆', '✎', 'U', '···', '—', '=', '≈'];
    const colors = [
      Color(0xFFF5C842), Color(0xFF8FD48F), Color(0xFF7EC8F0),
      Color(0xFFF07E9E), Color(0xFFC88FE8), Color(0xFFA8B4E0),
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
                  child: Text(['关', '当前句', '当前段'][i],
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          color: _ttsHighlight == i
                              ? _bgTop
                              : _fg)),
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
      _ttsLabel('样式：EasyVoice 只有「音色 / 语速 / 音调」✓ —— '
          '音色请到「朗读引擎」页选源并拉取 ✓（本格无"风格/情感"参数 ✗）'),
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
                child: Text(styles[i],
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        color: _fg.withValues(alpha: 0.35))),
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
                  child: Text(n,
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          color: n == '本章' ? _fg : _bgTop)),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Text('跟读高亮会在正文里给正在念的句子加底色，方便对照着听。',
          style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted)),
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
                    horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: _ttsTimer == m
                      ? _fg.withValues(alpha: 0.85)
                      : _fg.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(m == 0 ? '关' : '$m 分钟',
                    style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        color: _ttsTimer == m
                            ? _bgTop
                            : _fg)),
              ),
            ),
          GestureDetector(
            onTap: () => upd(() => _ttsTimer = -1),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: _ttsTimer == -1
                    ? _fg.withValues(alpha: 0.85)
                    : _fg.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('读完本章',
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: _ttsTimer == -1
                          ? _bgTop
                          : _fg)),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Text('定时到点为暂停，按播放键即接着读。',
          style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted)),
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
      _ttsSwitch('点朗读进播放页', '开启后点底栏「朗读」直接进沉浸式播放页'
          '（封面+当前句大字）；关闭时也可从播放条上的唱片键进入', _ttsDirectPlayer,
          onChanged: (v) => setState(() {
                _ttsDirectPlayer = v;
                _scheduleSavePrefs();
              })),
      _ttsSwitch('自动定位阅读位置', '朗读时自动翻到正在读的那一页；'
          '关闭后由播放条上的定位键手动跳', _ttsAutoLocate,
          onChanged: (v) => setState(() {
                _ttsAutoLocate = v;
                _scheduleSavePrefs();
              })),
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
        child: Text(s,
            style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w600,
                color: _fg)),
      );

  /// 朗读面板里的一个开关行 ✓。
  ///
  /// ✅ **本轮新增 `onChanged`** ✓ —— 此前它把开关的 `onChanged` **写死为 `null`** ✗，
  ///   于是「高级」页里凡是走它的开关都**永远显示关闭、而且永远点不动** ✗✗
  ///   （`_ttsAdvancedTab` 上方的注释自己也写着"这两个开关是**纯装饰**"✗）。
  ///   ⇒ 现在把回调传进来，它就能变成**真设置** ✓（落盘 ✓ + 被 TTS 逻辑读取 ✓）。
  /// ℹ️ 用**可选参数** ✓：暂时没传 `onChanged` 的调用点行为完全不变（仍不可点 ✓），
  ///   既不会引入编译问题 ✓，也不会误伤害别处"有意禁用"的开关 ⛔（如独立排版/独立设置 ✓）。
  Widget _ttsSwitch(String title, String sub, bool value,
      {ValueChanged<bool>? onChanged}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: FontWeight.w600,
                        color: _fg)),
                const SizedBox(height: 3),
                Text(sub,
                    style: TextStyle(
                        fontSize: AppTheme.fontFootnote, height: 1.5, color: _fgMuted)),
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

    /// 笔记面板  /// 阅读悬浮球（截图里右下角那个球）。
  ///
  /// 操作（截图里阅读器的标准交互）：
  ///   单击 = 下一页 · 双击 = 开菜单 · 拖动 = 移动位置
  /// 移动后的位置记在 _ballOffset，重进阅读器还在原处。
  Widget _readingBall(Color fg) {
    return Positioned(
      right: 12 + _ballOffset.dx,
      bottom: 90 + _ballOffset.dy,
      child: GestureDetector(
        onTap: _nextPageOrChapter,
        onDoubleTap: () => setState(() => _showBar = true),
        onPanUpdate: (d) => setState(() {
          _ballOffset = Offset(
            (_ballOffset.dx - d.delta.dx).clamp(-220.0, 0.0),
            (_ballOffset.dy - d.delta.dy).clamp(-300.0, 200.0),
          );
        }),
        // ⚡ 防抖 ✓：拖动悬浮球时**每次松手**都触发这里 ✗（最热的一处 ✓）——
        //   改用 `_scheduleSavePrefs()` 合并 300ms 内的多次拖动 ✓；
        //   离开页面时 `dispose` 会**兜底落盘** ✓（否则"拖完立刻退出"会丢位置 ✗）
        onPanEnd: (_) => _scheduleSavePrefs(),
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: fg.withValues(alpha: 0.14),
            shape: BoxShape.circle,
            border: Border.all(color: fg.withValues(alpha: 0.10)),
          ),
          child: Icon(Icons.auto_stories_rounded,
              size: 22, color: fg.withValues(alpha: 0.55)),
        ),
      ),
    );
  }

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
                    Text('AI',
                        style: TextStyle(
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.w700,
                            color: _fg)),
                    const Spacer(),
                    IconButton(
                      tooltip: 'AI 接口配置',
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showAiConfig();
                      },
                      icon: Icon(Icons.settings_outlined,
                          size: 20, color: _fgMuted),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: Icon(Icons.close_rounded,
                          size: 20, color: _fgMuted),
                    ),
                  ],
                ),
              ),
              for (final a in ['总结本章', '解释这段', '生成书评', '问答'])
                ListTile(
                  title: Text(a,
                      style: TextStyle(fontSize: AppTheme.fontHeadline, color: _fg)),
                  trailing: Icon(Icons.chevron_right_rounded,
                      size: 20, color: _fgMuted),
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
                      fontSize: AppTheme.fontFootnote, height: 1.7, color: _fgMuted),
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
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom + 10),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AI 接口配置',
                    style: TextStyle(
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w700,
                        color: fg)),
                const SizedBox(height: 4),
                Text(
                  'OpenAI 兼容对话接口，Key 只存在本机。默认填 DeepSeek，'
                  '可改成通义/智谱/Moonshot/本地 vLLM 的地址。',
                  style: TextStyle(fontSize: AppTheme.fontFootnote, height: 1.6, color: _fgMuted),
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
                        borderSide: BorderSide(color: _fgMuted.withValues(alpha: 0.3))),
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
                        borderSide: BorderSide(color: _fgMuted.withValues(alpha: 0.3))),
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
                        borderSide: BorderSide(color: _fgMuted.withValues(alpha: 0.3))),
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
                          final savedModel =
                              modelCtrl.text.trim().isEmpty ? 'deepseek-chat' : modelCtrl.text.trim();
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
                      child: Text('测试连接',
                          style: TextStyle(fontSize: 13, color: JellyTheme.primary)),
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
    final body =
        chapterText.length > 8000 ? chapterText.substring(0, 8000) : chapterText;
    if (body.trim().isEmpty) {
      _toast('本章没有可用的正文内容');
      return;
    }
    final String system;
    final String user;
    switch (action) {
      case '总结本章':
        system = '你是小说阅读助手。用简体中文给出本章的简洁总结'
            '（人物/事件/伏笔要点，200 字以内）。';
        user = '《${widget.bookName}》本章内容：\n$body';
      case '解释这段':
        system = '你是小说阅读助手，用简体中文通俗解释文中的关键剧情'
            '与难懂之处，300 字以内。';
        user = '《${widget.bookName}》本章内容：\n$body';
      case '生成书评':
        system = '你是资深书评人，用简体中文写一段 150 字左右的短书评'
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
    final body =
        chapterText.length > 8000 ? chapterText.substring(0, 8000) : chapterText;
    _showAiLoading(
      '问答',
      () => ai.chat(
        system: '你是小说阅读助手，基于给出的本章内容用简体中文回答读者问题。'
            '内容无关时如实说明。',
        user: '《${widget.bookName}》本章内容：\n$body\n\n读者问题：$question',
      ),
    );
  }

  /// 调 AI 并展示结果（loading → 结果 sheet / 错误 toast）
  Future<void> _showAiLoading(String title, Future<String> Function() task) async {
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
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
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
                    Text(title,
                        style: TextStyle(
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.w700,
                            color: fg)),
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
                      icon: Icon(Icons.close_rounded,
                          size: 20, color: _fgMuted),
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
                    style: TextStyle(
                        fontSize: 14, height: 1.7, color: fg),
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
      for (final m in RegExp(r'https?://[^\s"''<>]+\.(?:jpg|jpeg|png|gif|webp)',
              caseSensitive: false)
          .allMatches(p)) {
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
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
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
                    Text('图片模式',
                        style: TextStyle(
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.w700,
                            color: _fg)),
                    const SizedBox(width: 8),
                    Text('${urls.length} 张',
                        style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fgMuted)),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: Icon(Icons.close_rounded,
                          size: 20, color: _fgMuted),
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
                                fontSize: AppTheme.fontSubhead, height: 1.7, color: _fgMuted),
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
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: _fg.withValues(alpha: 0.07),
                                child: Icon(Icons.broken_image_outlined,
                                    size: 22, color: _fgMuted),
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
                child: Image.network(url, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: MediaQuery.of(ctx).padding.top + 8,
              right: 12,
              child: IconButton(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close_rounded,
                    size: 26, color: Colors.white),
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
          widget.source, url);
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
  Widget _settingsPanel(Color fg) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        decoration: BoxDecoration(
          color: _bgTop,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题：阅读设置 + 独立设置
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 16, 4),
                child: Row(
                  children: [
                    Text('阅读设置',
                        style: TextStyle(
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w700,
                            color: _fg)),
                    const Spacer(),
                    Text('独立设置',
                        style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fgMuted)),
                    const SizedBox(width: 4),
                    // ✅ 三处「独立设置 / 独立排版」共用同一个 `_independent` ✓，均已接线：
                    //   拨动即写 / 删 `BsrIndependentLayout` 的本书记录，`_restorePrefs` 读回 ✓。
                    Switch(
                        value: _independent,
                        onChanged: (v) async {
                          setState(() => _independent = v);
                          if (v) {
                            await BsrIndependentLayout.instance
                                .enable(_indepKey, _layoutSnapshot());
                          } else {
                            await BsrIndependentLayout.instance
                                .disable(_indepKey);
                          }
                          _scheduleSavePrefs();
                          if (mounted) setState(() {});
                        }),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  children: [
                    // ── 阅读模式（5 种）────────────────────────
                    // 阅读模式：标签在左、5 个按钮在右（同一行，截图如此）
                    _setRowRight(
                      '阅读模式',
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final m in PageMode.values)
                            _chip(m.label, _rs.pageMode == m, () {
                              setState(() => _rs = _rs.copyWith(pageMode: m));
                              _scheduleSavePrefs();
                              // 模式变了要重新分页（上下模式不分页）
                              _paginate();
                            }, compact: true),
                        ],
                      ),
                    ),
                    _setSwitch('翻页反转', '左点下一页、右点上一页', _rs.flipReverse,
                        (v) {
                      setState(() => _rs = _rs.copyWith(flipReverse: v));
                      _scheduleSavePrefs();
                    }),
                    _setSwitch('单手模式', '屏幕左右点击都是下一页', _rs.oneHand,
                        (v) {
                      setState(() => _rs = _rs.copyWith(oneHand: v));
                      _scheduleSavePrefs();
                    }),
                    // 点击区域：进入 3×3 编辑页（截图 IMG_8117）
                    InkWell(
                      onTap: _showTapZoneEditor,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            Text('点击区域',
                                style:
                                    TextStyle(fontSize: AppTheme.fontHeadline, color: _fg)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text('自定义各区域触发上一页/菜单/下一页',
                                  style: TextStyle(
                                      fontSize: AppTheme.fontSubhead, color: _fgMuted)),
                            ),
                            Icon(Icons.grid_view_rounded,
                                size: 20, color: _fgMuted),
                          ],
                        ),
                      ),
                    ),
                    _setSwitch('双页模式', '横屏左右并排（上下模式除外）', _rs.dualPage,
                        (v) {
                      setState(() => _rs = _rs.copyWith(dualPage: v));
                      _scheduleSavePrefs();
                    }),
                    // ── 信息栏（6 项逐项开关）──────────────────
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 6),
                      child: Row(
                        children: [
                          Text('信息栏',
                              style: TextStyle(fontSize: AppTheme.fontHeadline, color: _fg)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text('页眉页脚显示的信息，可逐项开关',
                                style: TextStyle(
                                    fontSize: AppTheme.fontSubhead, color: _fgMuted)),
                          ),
                        ],
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final k in ['时间', '章节', '电量', '书名', '页码', '进度'])
                          _chip(k, _rs.statusItems.contains(k), () {
                            final next = Set<String>.of(_rs.statusItems);
                            if (!next.remove(k)) next.add(k);
                            setState(() =>
                                _rs = _rs.copyWith(statusItems: next));
                            _scheduleSavePrefs();
                          }),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _setSwitch('音量键翻页', '按音量上/下键翻页（会接管音量键）',
                        _rs.volumeKeys, (v) {
                      setState(() => _rs = _rs.copyWith(volumeKeys: v));
                      _scheduleSavePrefs();
                    }),
                    // ── 屏幕休眠（标签左 + 3 个按钮同一行）────────
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
                  ],
                ),
              ),
              // 底部：取消 · 确认
              //（原来这里还有个「排版」按钮 ✗ —— 与底部功能栏里的「排版」重复了，
              //  用户实测："功能面板里面的设置里面还有一个排版？" ⇒ 去掉 ✓）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () =>
                          setState(() => _showSettingsPanel = false),
                      child: Text('取消',
                          style: TextStyle(fontSize: AppTheme.fontBody, color: _fg)),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () =>
                          setState(() => _showSettingsPanel = false),
                      style: FilledButton.styleFrom(
                        backgroundColor: _fg.withValues(alpha: 0.9),
                        foregroundColor: _bgTop,
                      ),
                      child: const Text('确认'),
                    ),
                  ],
                ),
              ),
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
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(label,
                style: TextStyle(fontSize: AppTheme.fontHeadline, color: _fg)),
          ),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: child),
          ),
        ],
      ),
    );
  }
  Widget _setSwitch(
      String label, String sub, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(fontSize: AppTheme.fontHeadline, color: _fg)),
                const SizedBox(height: 2),
                Text(sub,
                    style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fgMuted)),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap,
      {bool compact = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: compact ? 11 : 16, vertical: compact ? 7 : 9),
        decoration: BoxDecoration(
          color: on
              ? _fg.withValues(alpha: 0.85)
              : _fg.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: compact ? 13 : 13.5,
            fontWeight: on ? FontWeight.w600 : FontWeight.normal,
            color: on ? _bgTop : _fg,
          ),
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
        _rs.tapZones.isEmpty ? ReadingSettings.defaultZones() : _rs.tapZones);
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
                                    final a = await showModalBottomSheet<
                                        TapAction>(
                                      context: ctx,
                                      backgroundColor: Colors.transparent,
                                      builder: (c) => Container(
                                        decoration: BoxDecoration(
                                          color: _bgTop,
                                          borderRadius:
                                              const BorderRadius.vertical(
                                                  top: Radius.circular(22)),
                                        ),
                                        child: SafeArea(
                                          top: false,
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              for (final a
                                                  in TapAction.values)
                                                ListTile(
                                                  title: Text(a.label,
                                                      style: TextStyle(
                                                          fontSize: AppTheme.fontHeadline,
                                                          color: _fg)),
                                                  trailing: zones[z] == a
                                                      ? Icon(Icons.check_rounded,
                                                          size: 20,
                                                          color: _fg)
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
                                          color:
                                              Colors.white.withValues(alpha: 0.5),
                                          width: 1),
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
                                              blurRadius: 4),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '点击屏幕上的区域，在弹层中选择该区域的动作',
                          style: TextStyle(fontSize: AppTheme.fontBody, color: Colors.white),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close_rounded,
                            size: 20, color: Colors.white),
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
                      setState(() =>
                          _rs = _rs.copyWith(tapZones: Map.of(zones)));
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
        child: Text(label,
            style: const TextStyle(fontSize: AppTheme.fontHeadline, color: Colors.white)),
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
    final tocCtrl = ScrollController();
    var showDragTip = false;
    var dragTipName = '';
    var dragTipY = 0.0;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
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
          // 右缘拖动 → 按比例滚动章节列表（只滚动不跳转 ✓），并记录提示章节名
          void dragTocTo(double localY, double stripH) {
            if (!tocCtrl.hasClients || chapters.isEmpty) return;
            final m = tocCtrl.position.maxScrollExtent;
            if (m <= 0) return;
            final ratio = (localY / stripH).clamp(0.0, 1.0);
            tocCtrl.jumpTo(ratio * m);
            final idx = (ratio * (chapters.length - 1)).round();
            dragTipName = widget.chapters[chapters[idx]].name;
            dragTipY = localY;
          }
          return Container(
            constraints:
                BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.9),
            decoration: BoxDecoration(
              color: _bgTop,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(22)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final e in [
                        ('目录', '${widget.chapters.length} 章'),
                        ('书签', '${_bookmarks.length} 条'),
                        ('笔记',
                            '${ReaderNotesService.instance.forBook(widget.source.id, widget.bookName).length} 条'),
                      ])
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setSheet(
                                () => tab = tabNames.indexOf(e.$1)),
                            child: Column(
                              children: [
                                Text(e.$1,
                                    style: TextStyle(
                                      fontSize: AppTheme.fontHeadline,
                                      fontWeight: tab == tabNames.indexOf(e.$1)
                                          ? FontWeight.w700
                                          : FontWeight.normal,
                                      color: tab == tabNames.indexOf(e.$1)
                                          ? _fg
                                          : _fgMuted,
                                    )),
                                const SizedBox(height: 2),
                                Text(e.$2,
                                    style: TextStyle(
                                        fontSize: AppTheme.fontFootnote, color: _fgMuted)),
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
                        icon: Icon(Icons.close_rounded,
                            size: 22, color: _fgMuted),
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
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: _fg.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(17),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.search_rounded,
                                      size: 16, color: _fgMuted),
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
                                          color: _fg),
                                      decoration: InputDecoration(
                                        hintText: '搜索章节',
                                        hintStyle: TextStyle(
                                            fontSize: AppTheme.fontFootnote,
                                            color: _fgMuted),
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
                          IconButton(
                            tooltip: asc ? '正序' : '倒序',
                            onPressed: () => setSheet(() => asc = !asc),
                            icon: Icon(
                                asc
                                    ? Icons.arrow_upward_rounded
                                    : Icons.arrow_downward_rounded,
                                size: 20,
                                color: _fg),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: Stack(
                        children: [
                          ListView.builder(
                            controller: tocCtrl,
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
                                      horizontal: 20, vertical: 14),
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
                          // 右缘快速拖动定位条（Cmbok 同款）：按住上下拖动 →
                          // 列表按比例滚动，浮现章节标题提示；搜索状态隐藏 ✓
                          if (kwToc.isEmpty)
                            Positioned(
                              right: 6,
                              top: 40,
                              bottom: 40,
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
                                          () => dragTocTo(d.localPosition.dy, h));
                                    },
                                    onVerticalDragEnd: (_) {
                                      Future.delayed(
                                          const Duration(milliseconds: 700),
                                          () {
                                        if (ctx.mounted) {
                                          setSheet(() => showDragTip = false);
                                        }
                                      });
                                    },
                                    child: Stack(
                                      children: [
                                        Container(
                                          width: 26,
                                          decoration: BoxDecoration(
                                            color: _fg.withValues(alpha: 0.07),
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          alignment: Alignment.center,
                                          child: Icon(
                                            Icons.unfold_more_rounded,
                                            size: 18,
                                            color: _fgMuted,
                                          ),
                                        ),
                                        // 拖动指示块（按滚动比例定位）
                                        if (tocCtrl.hasClients &&
                                            tocCtrl.position.maxScrollExtent >
                                                0)
                                          Positioned(
                                            top: (tocCtrl.offset /
                                                    tocCtrl.position
                                                        .maxScrollExtent *
                                                    (h - 34))
                                                .clamp(0.0, h - 34),
                                            left: 3,
                                            child: Container(
                                              width: 20,
                                              height: 34,
                                              decoration: BoxDecoration(
                                                color: _fg
                                                    .withValues(alpha: 0.35),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          // 拖动时浮现的章节标题提示（只读 ✓）
                          if (showDragTip && dragTipName.isNotEmpty)
                            Positioned(
                              right: 40,
                              top: (40 + dragTipY - 20)
                                  .clamp(0.0, double.infinity),
                              child: Container(
                                constraints: BoxConstraints(
                                    maxWidth:
                                        MediaQuery.of(ctx).size.width * 0.62),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
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
                                      color: _bgTop),
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
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              decoration: BoxDecoration(
                                color: _fg.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(17),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.search_rounded,
                                      size: 16, color: _fgMuted),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: TextField(
                                      controller: ctrlBm,
                                      style: TextStyle(
                                          fontSize: AppTheme.fontFootnote,
                                          color: _fg),
                                      decoration: InputDecoration(
                                        hintText: '搜索书签',
                                        hintStyle: TextStyle(
                                            fontSize: AppTheme.fontFootnote,
                                            color: _fgMuted),
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
                            tooltip: asc ? '正序' : '倒序',
                            onPressed: () => setSheet(() => asc = !asc),
                            icon: Icon(
                                asc
                                    ? Icons.arrow_upward_rounded
                                    : Icons.arrow_downward_rounded,
                                size: 20,
                                color: _fg),
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
                                  horizontal: 12, vertical: 5),
                              decoration: BoxDecoration(
                                color: filterColor == null
                                    ? _fg.withValues(alpha: 0.85)
                                    : _fg.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text('全部',
                                  style: TextStyle(
                                      fontSize: AppTheme.fontFootnote,
                                      fontWeight: FontWeight.w600,
                                      color: filterColor == null ? _bgTop : _fg)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          for (final c in _bookmarkColors)
                            GestureDetector(
                              onTap: () => setSheet(() => filterColor =
                                  filterColor == c ? null : c),
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
                                    color: _fgMuted),
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
                                    fontSize: AppTheme.fontBody, color: _fg),
                              ),
                              trailing: IconButton(
                                icon: Icon(Icons.delete_outline,
                                    size: 18, color: _fgMuted),
                                onPressed: () => setSheet(() {
                                  setState(() =>
                                      _bookmarks.remove(e.key));
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
                            Icon(Icons.search_rounded,
                                size: 16, color: _fgMuted),
                            const SizedBox(width: 6),
                            Expanded(
                              child: TextField(
                                controller: ctrlNote,
                                style: TextStyle(
                                    fontSize: AppTheme.fontFootnote,
                                    color: _fg),
                                decoration: InputDecoration(
                                  hintText: '搜索摘录或批注',
                                  hintStyle: TextStyle(
                                      fontSize: AppTheme.fontFootnote,
                                      color: _fgMuted),
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
                                  horizontal: 12, vertical: 5),
                              decoration: BoxDecoration(
                                color: filterColor == null
                                    ? _fg.withValues(alpha: 0.85)
                                    : _fg.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text('全部',
                                  style: TextStyle(
                                      fontSize: AppTheme.fontFootnote,
                                      fontWeight: FontWeight.w600,
                                      color: filterColor == null ? _bgTop : _fg)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          for (final c in _bookmarkColors)
                            GestureDetector(
                              onTap: () => setSheet(() => filterColor =
                                  filterColor == c ? null : c),
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
                        final all = ReaderNotesService.instance
                            .forBook(widget.source.id, widget.bookName);
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
                                all.isEmpty
                                    ? '还没有划线，长按正文试试'
                                    : '没有匹配的笔记',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: AppTheme.fontSubhead,
                                    height: 1.7,
                                    color: _fgMuted),
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
                                      color: Color(n.color), width: 3),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
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
                                              color: _fgMuted),
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
                                        child: Icon(Icons.close_rounded,
                                            size: 16, color: _fgMuted),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(n.text,
                                      style: TextStyle(
                                          fontSize: AppTheme.fontSubhead,
                                          color: _fg,
                                          height: 1.5),
                                      maxLines: 4,
                                      overflow: TextOverflow.ellipsis),
                                  if (n.hasNote) ...[
                                    const SizedBox(height: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: Color(n.color)
                                            .withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text('批注：${n.note}',
                                          style: TextStyle(
                                              fontSize: AppTheme.fontFootnote,
                                              color: _fg,
                                              height: 1.4)),
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
                                        child: Text('跳到本章 →',
                                            style: TextStyle(
                                                fontSize: AppTheme.fontFootnote,
                                                color: JellyTheme.primary)),
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
              ),
            ),
          );
        },
      ),
    );
    tocCtrl.dispose();
  }

  /// 段落 → 所在页下标（书签跳转用）
  int? _pageOfParagraph(int pi) {
    if (pi >= _paragraphs.length) return null;
    final text = _paragraphs[pi];
    for (var i = 0; i < _pages.length; i++) {
      for (final e in _pages[i].entries) {
        final b = e.block;
        if (b is ParagraphBlock && b.text == text) return i;
      }
    }
    return null;
  }

}
