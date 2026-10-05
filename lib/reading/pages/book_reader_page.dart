import 'dart:async';
import '../../widgets/common_widgets.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/book_content.dart';
import '../models/bookshelf.dart';
import '../services/book_download_service.dart';
import '../services/book_font_service.dart';
import '../services/book_paginator.dart';
import '../services/book_page_cache_service.dart';
import '../services/reader_notes_service.dart';
import '../services/book_parser.dart';
import '../utils/file_browser.dart';
import '../services/gbk_txt_parser.dart';
import '../services/book_reading_progress_service.dart';
import '../services/reader_override_service.dart';
import '../services/bookshelf_service.dart';
import '../services/platform_service.dart';
import '../services/settings_service.dart';
import '../services/tts_service.dart';
import '../services/reading_time_service.dart';
import '../theme/jelly_theme.dart';
import '../widgets/book_page_cover.dart';
import '../widgets/book_page_curl.dart';
import '../widgets/pomodoro_button.dart';
import 'book_prefetch_page.dart';
import 'notes_and_journey_page.dart';
import '../../common/theme.dart';
import '../../common/system_ui.dart';

// ── 顶栏「日夜切换」的本地覆盖（0=跟随全局，1=强制浅色，2=强制夜间）──
// ✗ 原来放在静态类 `_ReaderDarkOverride.value` 里：static 属于整个进程而非
//   某一本书，于是「在 A 书点夜间 → 打开 B 书也是夜间」**跨书污染** ✗；
//   而且它初始 0、点过之后就再也回不到 0 → 「跟随全局暗色」被永久绕过 ✗。
// ✓ 现在改成 `_BookReaderPageState._darkOverride` **实例字段**：随页面
//   createState / dispose 走完生命周期，换一本书自然重新从 0（跟随全局）开始 ✓。
//   对应的 `_readerIsDark` 也从文件级 getter 改为 State 的实例 getter，
//   0 档真的去读全局唯一明暗真源 `AppBrightness.isLight`，不再硬写 1/0 ✓。

/// 顶栏全书搜索的命中条目
class _SearchHit {
  final int chapterIndex;
  final String chapterTitle;
  final String preview;
  final int blockIndex;
  const _SearchHit({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.preview,
    required this.blockIndex,
  });
}

/// 图书阅读页：EPUB / MOBI / TXT / PDF app 内排版阅读；
/// 其余格式由 [open] 路由到外部应用。
/// 固定 TextPainter 度量分页翻页（不再支持连续滚动，不受阅读模式设置控制）。
class BookReaderPage extends StatefulWidget {
  final BookDownloadTask task;
  final BookPrefetchedData? prefetched;

  const BookReaderPage({super.key, required this.task, this.prefetched});

  /// 统一入口：epub/txt/mobi/azw/azw3 进排版阅读器，pdf 进 PDF 渲染页，
  /// 其余格式调系统外部应用打开。
  static Future<void> open(BuildContext context, BookDownloadTask task) async {
    final ext = (task.extension ?? 'epub').toLowerCase();
    if (ext == 'epub' ||
        ext == 'txt' ||
        ext == 'mobi' ||
        ext == 'azw' ||
        ext == 'azw3' ||
        ext == 'pdf') {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => BookPrefetchPage(task: task)),
      );
      return;
    }
    if (task.localPath == null || !await File(task.localPath!).exists()) {
      if (!context.mounted) return;
      _toast(context, '文件不存在，请重新下载');
      return;
    }
    final ok = await PlatformService.openFile(task.localPath!, _mimeOf(ext));
    if (!ok) {
      if (!context.mounted) return;
      _toast(context, '未找到可打开此格式的应用');
    }
  }

  static void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  static String _mimeOf(String ext) {
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'mobi':
      case 'azw':
      case 'azw3':
        return 'application/x-mobipocket-ebook';
      case 'cbz':
        return 'application/vnd.comicbook+zip';
      case 'cbr':
        return 'application/vnd.comicbook-rar';
      case 'fb2':
        return 'application/x-fictionbook+xml';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'rtf':
        return 'application/rtf';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  @override
  State<BookReaderPage> createState() => _BookReaderPageState();
}

/// 过渡页预计算好的分页结果，传给阅读器避免重复解析 / 分页。
class BookPrefetchedData {
  final BookContent content;
  final List<BookPage> pages;
  final Map<String, double> ratios;
  final Map<String, int> naturalWidths;
  final String key;
  final String fingerprint;

  /// 未完成分页时的分页器实例；阅读器后台继续 stepInto 追加剩余页。
  /// null = 已分页完毕。
  final BookPaginator? paginator;

  const BookPrefetchedData({
    required this.content,
    required this.pages,
    required this.ratios,
    required this.naturalWidths,
    required this.key,
    required this.fingerprint,
    this.paginator,
  });
}

class _BookReaderPageState extends State<BookReaderPage> {
  /// 顶栏「日夜切换」的本地覆盖：0=跟随全局，1=强制浅色，2=强制夜间。
  /// 必须是**实例**字段：原来的 static 会跨书残留（见文件顶部说明 ✗）。
  int _darkOverride = 0;

  /// 图书阅读器明暗：**跟随全局外观**，顶栏日夜按钮可临时覆盖。
  ///
  /// ── 原来写死 `false`（永远浅色），后果是"暗色模式对图书阅读完全无效" ──
  ///
  /// 当初写死浅色的理由是"仿真翻页为固定纸张图背景，全局暗色下文字翻白配浅纸
  /// 看不清"。但实际 `widgets/book_page_curl.dart` 的**翻页背纸本来就按
  /// `Theme.of(context).brightness` 分了深浅两套**
  ///（`:367-368` 的 `0xFF1E1E22` / `0xFFFBF6EC`）——
  /// 也就是说写死浅色反而制造了"深色背纸 + 浅色正文"的错配。
  /// 跟随全局之后，正文底色与翻页背纸同向，才是自洽的。
  ///
  /// ✗ 原来它还是文件级 getter、读 `_ReaderDarkOverride` 的 static 值：
  ///   那个 static 一旦被点过就再也回不到 0，「跟随全局」形同虚设 ✗。
  /// ✓ 现在是 State 的**实例** getter：0 档真的落到全局唯一明暗真源
  ///   `!AppBrightness.isLight.value` 上，不硬写 1/0 ✓。
  bool get _readerIsDark {
    if (_darkOverride == 1) return false;
    if (_darkOverride == 2) return true;
    return !AppBrightness.isLight.value;
  }

  BookContent? _content;
  bool _loading = true;
  String? _error;

  bool _showControls = false;
  // 上次已归位的状态书架，避免翻页重复调 BookshelfService
  String? _lastAppliedStatus;

  // 单击翻页判定：记录按下位置与时间，区分单击 / 长按选字 / 拖动翻页
  Offset? _tapDownPos;
  DateTime? _tapDownTime;

  // 排版参数（与 SettingsService 同步）
  late BookTypography _typo;

  // 翻页模式
  late PageController _pageController;
  List<BookPage> _pages = const [];
  int _currentPage = 0;
  // 常驻 HUD（页码/进度）监听此 notifier，翻页时局部刷新，不重建 PageView
  final ValueNotifier<int> _currentPageNotifier = ValueNotifier(0);
  bool _paginating = false;
  int _paginateDone = 0;
  int _paginateTotal = 0;
  final Map<String, double> _imageRatios = {};
  // imageKey -> 图片自然像素宽度（行内小图标判定用，与 _imageRatios 同源填充）
  final Map<String, int> _imageNaturalWidths = {};
  String _paginateKey = '';
  String _contentFingerprint = '';

  // 流式分页：过渡页分到"够读"就进阅读器，剩余的在此后台继续。
  // 非 null 表示后台分页进行中；旋屏 / 参数变更 / dispose 会置 null 取消。
  BookPaginator? _ongoingPaginator;

  // 后台分页时续读定位：进入时续读 block 尚未分到页，待后台分页覆盖后自动跳转。
  // 仅在用户未手动翻页时跳一次，避免打扰已开始阅读的用户。
  int? _pendingResumeBlock;
  bool _userPaged = false;
  // 后台分页进度（底部细进度条用）
  int _bgPaginateDone = 0;
  int _bgPaginateTotal = 0;

  // 懒分页：flatBlocks 总块数与已排覆盖到的 block 数，用于估算总页数/百分比。
  // 大书（如十几万段的 TXT）不全量预排，只排当前页前方一个窗口，读到边界再补。
  int _totalBlockCount = 0;
  int _paginatedBlockCount = 0;
  // 是否正在向前补排（仅此时显示底部进度条；停在窗口边界时为 false）。
  bool _paginatingAhead = false;
  // 懒分页窗口：当前页前方至少保留的页数；距末页 ≤ margin 时触发补排。
  static const int _kWindowAheadPages = 80;
  static const int _kWindowMarginPages = 12;

  // 图片模式：全图书走图库（PhotoView 画廊 / 消散），跳过文本分页。
  // _currentPageNotifier 在图片模式下存当前图序号，复用 HUD。
  List<int> _imageBlockIndices = const []; // flatBlocks 中 ImageBlock 的索引
  bool _isImageMode = false;
  int _currentImageIndex = 0;
  PageController? _imagePageController;

  List<BookBlock> get _blocks => _content?.flatBlocks ?? [];
  List<int> get _chapterStarts => _content?.chapterStarts ?? [];

  /// 懒分页下的显示总页数：已排完（_ongoingPaginator 已置空）用 _pages.length，
  /// 否则按 已排页数 × 总块数 / 已排块数 估算，随补排推进收敛到真实值。
  int get _displayTotalPages {
    if (_ongoingPaginator == null || _pages.isEmpty) return _pages.length;
    if (_paginatedBlockCount <= 0 || _totalBlockCount <= 0) {
      return _pages.length;
    }
    return (_pages.length * _totalBlockCount / _paginatedBlockCount).round();
  }

  @override
  void initState() {
    super.initState();
    _typo = _typoFromSettings();
    final pf = widget.prefetched;
    if (pf != null) {
      // 过渡页已解析 + 分页 + 缓存命中参数，直接复用，跳过 _load / _paginate
      _content = pf.content;
      _pages = pf.pages;
      _imageRatios.addAll(pf.ratios);
      _imageNaturalWidths.addAll(pf.naturalWidths);
      _paginateKey = pf.key;
      _contentFingerprint = pf.fingerprint;
      _log(
        'reader进入 prefetched pages=${pf.pages.length} paginator=${pf.paginator != null} key=$_paginateKey',
      );
      _loading = false;
      _setupImageMode();
      // 续读位置：原由 _paginate 末尾跳转，此处直接按进度定位首页。
      // 大书续读靠后、过渡页未分到时：先定位到已分页末页，记下待定位 block，
      // 后台分页覆盖后续读块后自动跳转（仅一次，且仅当用户未手动翻页）。
      final flat = _content!.flatBlocks;
      final p = BookReadingProgressService().getProgress(widget.task.bookId);
      // 🔴 `clamp(0, -1)` 会**真抛 `ArgumentError`** ✗ —— Dart 的 `num.clamp` 在
      // `lowerLimit > upperLimit` 时**抛异常**（release 同样抛 ✓，不是 assert ✓，
      // 已在 SDK 的 `_internal/vm/lib/integers.dart` 核实过 ✓）。
      // 当 `flat.length == 0`（空书 / 正文为空 / 解析出 0 段落 ✓）时
      // `upperLimit = -1` ✗ → **阅读器一打开就崩** ✓。
      // 空的时候直接取 0 ✓（此时 `_pages` 也必为空 ✓，下面不会越界 ✓）
      final startBlock = (p == null || flat.isEmpty)
          ? 0
          : p.blockIndex.clamp(0, flat.length - 1);
      final target = BookPaginator.pageIndexOf(_pages, startBlock);
      if (_pages.isNotEmpty && startBlock > _pages.last.firstBlockIndex) {
        _pendingResumeBlock = startBlock;
      }
      _currentPage = target;
      // 双页模式（翻页/仿真）下把 _currentPage 对齐到 spread 左页：
      // 仿真模式直接按 _currentSpread 渲染，需对齐使 indicator/HUD 显示正确；
      // 翻页模式 PageController initialPage 改为目标 spread，进入即续读而非总停在第0页。
      if (_isDoublePageNow && !_isImageMode) {
        _currentPage = _spreadLeftPage(_pageToSpread(target));
      }
      // 图片模式下 notifier 已由 _setupImageMode 置为当前图序号，勿覆盖
      if (!_isImageMode) _currentPageNotifier.value = _currentPage;
      _pageController = PageController(
        initialPage: _isDoublePageNow ? _pageToSpread(target) : _currentPage,
      );
      // 过渡页可能只分了一部分就进来：后台继续补齐剩余页
      final pg = pf.paginator;
      _totalBlockCount = flat.length;
      if (pg != null && !pg.finished) {
        _ongoingPaginator = pg;
        _paginatedBlockCount = pg.currentBlockIndex;
        _bgPaginateTotal = pg.blockCount;
        _bgPaginateDone = pg.currentBlockIndex;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _continuePagination(),
        );
      } else {
        _paginatedBlockCount = flat.length; // 已排完
      }
    } else {
      _pageController = PageController();
      _load();
    }
    SettingsService().addListener(_onSettingsChanged);
    ReaderOverrideService().addListener(_onSettingsChanged);
    // 沉浸阅读：延后到路由转场动画结束再隐藏顶部状态栏（保留底部导航栏），
    // 避免系统栏切换与 MaterialPageRoute 转场叠加造成进入卡顿。
    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      SystemUiController.enter(
        'bookReader',
        mode: SystemUiMode.manual,
        overlays: const [SystemUiOverlay.bottom],
      );
    });
    PlatformService.onVolumeKey = _onVolumeKey;
    PlatformService.setVolumeKeyNav(
      ReaderOverrideService().effectiveVolumeKeyTurnBook(widget.task.bookId),
    );
  }

  /// ✅ **阅读时长：本次会话开始的时刻** ✓（`ReadingTimeService` 接线 ✓ —— 为「阅读计划 /
  ///   阅读热力图」提供真实数据 ✓；此前这两处**完全没有时长数据** ✗）。
  ///   图书阅读器**没有**漫画那边的防抖保存汇聚点 ✗，所以这里就取"**进入 → 销毁**"整段 ✓，
  ///   在 [dispose] 里一次性交上去 ✓（`addSession` 内部有 1 秒下限 ✓ 与单次 2 小时上限 ✓，
  ///   后者正好兜住"忘记退出阅读器"把一天刷爆 ✗✓）。
  ///   ℹ️ 放在 `dispose()` 正上方是为了**同一个文件里相邻声明与使用** ✓，便于审阅 ✓。
  DateTime _sessionStamp = DateTime.now();

  @override
  void dispose() {
    // 退出阅读器必须停掉朗读，否则会在别的页面继续念
    _tts.stop();
    _tts.onFinished = null;
    // ✅ 记录本次阅读时长 ✓（按天累计 → 供「阅读计划 / 阅读热力图」✓）
    ReadingTimeService.instance.addSession(DateTime.now().difference(_sessionStamp));
    PlatformService.onVolumeKey = null;
    PlatformService.setVolumeKeyNav(false);
    // 后台续分页未完：捕获 partial 状态 fire-and-forget 写缓存，下次断点续分页，
    // 不再从头重排。pages 的 block 皆来自 content.flatBlocks（主线程分页 / read
    // 主线程重建），identity 与 flatBlocks 一致，write idx 命中。
    final pg = _ongoingPaginator;
    if (pg != null &&
        !pg.finished &&
        _content != null &&
        _paginateKey.isNotEmpty) {
      final pages = List<BookPage>.of(_pages);
      final ratios = Map<String, double>.of(_imageRatios);
      final naturalWidths = Map<String, int>.of(_imageNaturalWidths);
      final flat = _content!.flatBlocks;
      final key = _paginateKey;
      final bookId = widget.task.bookId;
      final snap = pg.snapshot;
      _log(
        '写分页缓存(partial,dispose) key=$key pages=${pages.length} resume=${snap.blockIndex}',
      );
      // 不 await：dispose 不可阻塞；引用已捕获，widget 销毁后仍有效
      BookPageCacheService.instance.write(
        bookId: bookId,
        key: key,
        pages: pages,
        ratios: ratios,
        naturalWidths: naturalWidths,
        flatBlocks: flat,
        partial: true,
        resumeBlockIndex: snap.blockIndex,
        cur: snap.cur,
        curFirst: snap.curFirst,
        remaining: snap.remaining,
      );
    }
    _ongoingPaginator = null; // 取消后台流式分页（循环见 null 即退出）
    SettingsService().removeListener(_onSettingsChanged);
    ReaderOverrideService().removeListener(_onSettingsChanged);
    _pageController.dispose();
    _imagePageController?.dispose();
    _currentPageNotifier.dispose();
    // 离开阅读器：恢复**进入前**的系统栏状态（原来写死 edge-to-edge）
    SystemUiController.exit('bookReader');
    // 进度在翻页时已按节流策略通知书架重排（后台静默），退出时不额外 notify，
    // 避免书架变可见时重建造成的"列表刷新"观感。
    super.dispose();
  }

  BookTypography _typoFromSettings([TextScaler? scaler, TextStyle? inherited]) {
    final bookId = widget.task.bookId;
    final o = ReaderOverrideService();
    final mode = o.effectiveBookMode(bookId);
    return BookTypography(
      fontSize: o.effectiveBookFontSize(bookId),
      lineHeight: o.effectiveBookLineHeight(bookId),
      padding: o.effectiveBookHorizontalPadding(bookId),
      verticalPadding: o.effectiveBookVerticalPadding(bookId),
      // 字体族：用户字体偏好优先（含 'system' 哨兵），其次由模式派生。
      // 仿真 → inkReadingKai，普通翻页 → null（系统默认）。
      fontFamily: ReaderOverrideService.resolveFontFamily(
        o.effectiveBookFontFamily(bookId),
        mode,
      ),
      // 祖先 DefaultTextStyle.style：渲染端 SelectableText/Text 会 merge 它，
      // 度量须同步 merge，否则 letterSpacing/fontWeight 等残留字段致 meas<col。
      inheritedStyle: inherited ?? const TextStyle(),
      // 系统字体缩放：渲染由 SelectableText 自动应用，度量须传入同一 TextScaler
      // 对象，否则度量与渲染缩放不一致（留白或溢出，见 BookTypography.textScaler）。
      textScaler: scaler ?? TextScaler.noScaling,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // initState 无 context，scaler/inherited 先默认；此处拿到 MediaQuery 后校正。
    // 用系统 TextScaler 原对象（非 scale(1.0) 重建），保证度量与渲染缩放一致。
    // inheritedStyle 取渲染端 defaultTextStyle（Scaffold 内 Material 注入的
    // theme.textTheme.bodyMedium），度量 merge 它以消除 letterSpacing 等残留字段
    // 差异（meas<col）。此处 context 在 Scaffold 外，DefaultTextStyle.of 可能不同源，
    // 故直接取 textTheme.bodyMedium 与渲染端对齐。
    final scaler = MediaQuery.textScalerOf(context);
    final inherited =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    if (_typo.textScaler.scale(1.0) != scaler.scale(1.0) ||
        _typo.inheritedStyle != inherited) {
      _typo = _typoFromSettings(scaler, inherited);
    }
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    PlatformService.setVolumeKeyNav(
      ReaderOverrideService().effectiveVolumeKeyTurnBook(widget.task.bookId),
    );
    final newTypo = _typoFromSettings(_typo.textScaler, _typo.inheritedStyle);
    if (newTypo.fontSize != _typo.fontSize ||
        newTypo.lineHeight != _typo.lineHeight ||
        newTypo.padding != _typo.padding ||
        newTypo.verticalPadding != _typo.verticalPadding ||
        newTypo.fontFamily != _typo.fontFamily) {
      _typo = newTypo;
    }
    setState(() {});
    // 仿真切回翻页模式后 PageView 重建，需把控制器同步到当前页
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isImageMode) {
        final c = _imagePageController;
        if (c != null && c.hasClients) c.jumpToPage(_currentImageIndex);
        return;
      }
      final mode = ReaderOverrideService().effectiveBookMode(
        widget.task.bookId,
      );
      // 仿真/覆盖无 PageView，_pageController 未挂载；其余（左右/上下/无动画）
      // 切轴或重建后需把控制器同步到当前页
      if (mode != BookReadingMode.simulation &&
          mode != BookReadingMode.cover &&
          _pageController.hasClients) {
        _pageController.jumpToPage(
          _isDoublePage ? _currentSpread : _currentPage,
        );
      }
    });
  }

  Future<void> _load() async {
    final task = widget.task;
    final path = task.localPath;
    if (path == null || !await File(path).exists()) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '文件不存在，请重新下载';
        });
      }
      return;
    }
    try {
      final ext = (task.extension ?? 'epub').toLowerCase();
      // 解析 + 图片宽高比合并到同一 isolate，省 images 一次跨 isolate 深拷贝
      BookContent content;
      if (ext == 'txt') {
        // 后台常驻 isolate 解码（GBK 表仅初始化一次，不阻塞主线程）
        final txtFile = File(path);
        final bytes = await txtFile.readAsBytes();
        final title = txtFile.uri.pathSegments.isNotEmpty
            ? txtFile.uri.pathSegments.last
            : '未命名';
        content = await GbkTxtParser.instance.parse(bytes, title);
      } else if (ext == 'mobi' || ext == 'azw' || ext == 'azw3') {
        final r = await compute(BookParser.parseMobiWithRatios, File(path));
        content = r.content;
        _imageRatios.addAll(r.ratios);
        _imageNaturalWidths.addAll(r.naturalWidths);
      } else {
        final r = await compute(BookParser.parseEpubWithRatios, File(path));
        content = r.content;
        _imageRatios.addAll(r.ratios);
        _imageNaturalWidths.addAll(r.naturalWidths);
      }
      if (!mounted) return;
      setState(() {
        _content = content;
        _loading = false;
      });
      _contentFingerprint = BookPageCacheService.contentFingerprint(content);
      _setupImageMode();
      _restoreProgress();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  void _restoreProgress() {
    // 翻页模式：续读位置在 _paginate 末尾按 preserveBlockIndex 跳转
  }

  /// 双页模式：仅翻页/仿真模式 + 开关开启 + 横屏 + 非图片模式 时生效（用 build context）
  bool get _isDoublePage {
    if (_isImageMode) return false;
    final mode = ReaderOverrideService().effectiveBookMode(widget.task.bookId);
    // 上下翻页为纵向阅读，不支持双页并排；其余模式（左右/仿真/覆盖/无动画）均可
    if (mode == BookReadingMode.vertical) {
      return false;
    }
    if (!ReaderOverrideService().effectiveDoublePageBook(widget.task.bookId)) {
      return false;
    }
    return MediaQuery.orientationOf(context) == Orientation.landscape;
  }

  /// 双页状态（非 build 上下文用，如 initState）：用 platformDispatcher 算横屏
  bool get _isDoublePageNow {
    if (_isImageMode) return false;
    final mode = ReaderOverrideService().effectiveBookMode(widget.task.bookId);
    if (mode == BookReadingMode.vertical) {
      return false;
    }
    if (!ReaderOverrideService().effectiveDoublePageBook(widget.task.bookId)) {
      return false;
    }
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return false;
    final s = views.first.physicalSize;
    return s.width > s.height;
  }

  /// 双页 spread 映射（首页单独成页）：spread0=页0，spreadN(N>0)=页(2N-1)+页(2N)
  int _pageToSpread(int pageIndex) => pageIndex <= 0 ? 0 : (pageIndex + 1) ~/ 2;
  int _spreadLeftPage(int spread) => spread == 0 ? 0 : spread * 2 - 1;
  int _spreadRightPage(int spread) => spread * 2;
  int get _spreadCount => _pages.isEmpty ? 0 : 1 + _pages.length ~/ 2;
  int get _currentSpread => _pageToSpread(_currentPage);

  /// 分页器 viewportWidth：双页时传等效宽度使 _contentWidth = 半屏文字宽
  double _paginateViewportWidth(double vpW) {
    if (!_isDoublePage) return vpW;
    return (vpW - 2 + _typo.padding * 2) / 2; // gap=2
  }

  /// 渲染 contentWidth：双页时每页半屏文字宽（与分页度量一致）
  double _renderContentWidth(double vpW) {
    final w = vpW - _typo.padding * 2;
    if (!_isDoublePage) return w;
    return (w - 2) / 2; // gap=2
  }

  /// 分页缓存键：视口尺寸 + 排版参数 + bookId + 内容指纹 + 双页状态。_buildPaged
  /// 与 _paginate 及过渡页 / 缓存服务共用同一格式（[BookPageCacheService.keyOf]），
  /// 确保判等一致，避免字号变化或内容更新后用过期分页渲染导致底部溢出。
  String _paginateKeyOf(double vpW, double vpH) => BookPageCacheService.keyOf(
    vpW: vpW,
    vpH: vpH,
    typo: _typo,
    bookId: widget.task.bookId,
    fingerprint: _contentFingerprint,
    doublePage: _isDoublePage,
  );

  /// pageTurn 模式：按当前视口与排版参数分页（章间让出 UI 线程，显示进度）。
  /// [preserveBlockIndex] 为重排前所在 block，重排后跳到包含它的页。
  void _log(String msg) {
    if (kDebugMode) print('[BookReader] $msg');
  }

  /// 懒分页：向前补排一个窗口（当前页前方约 [_kWindowAheadPages] 页）即停，
  /// 不再一口气排全本。读到距末页 ≤ [_kWindowMarginPages] 时由翻页再次触发。
  /// 旋屏 / 参数变更 / dispose 会置 _ongoingPaginator=null，循环即退出。
  Future<void> _continuePagination() async {
    final paginator = _ongoingPaginator;
    if (paginator == null || _paginatingAhead) return;
    _paginatingAhead = true;
    if (mounted) setState(() {}); // 显示底部进度条
    // 大书自适应 chunk：按总块数估算使总帧数约 400，避免十万级 block 的书
    // 走 12/帧导致上万帧 setState 抖动卡死；小书（≤4800 块）仍用 12，行为不变。
    final chunk = (paginator.blockCount ~/ 400).clamp(12, 300);
    try {
      while (!paginator.finished && _ongoingPaginator == paginator && mounted) {
        paginator.stepInto(_pages, chunk: chunk);
        _paginatedBlockCount = paginator.currentBlockIndex;
        _bgPaginateDone = paginator.currentBlockIndex;
        if (!mounted || _ongoingPaginator != paginator) return;
        // 续读定位：后台分页已覆盖续读 block 且用户未手动翻页 -> 跳转一次
        final pending = _pendingResumeBlock;
        if (pending != null &&
            !_userPaged &&
            paginator.currentBlockIndex > pending) {
          _pendingResumeBlock = null;
          final newTarget = BookPaginator.pageIndexOf(_pages, pending);
          if (newTarget != _currentPage) {
            _currentPage = newTarget;
            _currentPageNotifier.value = newTarget;
            if (_pageController.hasClients) {
              _pageController.jumpToPage(
                _isDoublePage ? _pageToSpread(newTarget) : newTarget,
              );
            }
          }
        }
        // 窗口已满足（前方留够页数）-> 暂停，等用户读到边界再补
        if (_pages.length - _currentPage >= _kWindowAheadPages) break;
        setState(() {});
        SchedulerBinding.instance.scheduleFrame();
        await SchedulerBinding.instance.endOfFrame;
      }
    } finally {
      _paginatingAhead = false;
      // 排到全书末页：落全量缓存并释放分页器
      if (paginator.finished && _ongoingPaginator == paginator) {
        _ongoingPaginator = null;
        if (mounted) setState(() {}); // 清除底部进度条
        await _writeFullCache(paginator);
      } else if (mounted) {
        setState(() {}); // 暂停于窗口边界：隐藏底部进度条
      }
    }
  }

  /// 目录远跳：目标 block 不在已排窗口内时，向前补排到覆盖目标再跳。
  Future<void> _extendToBlock(int blockIndex) async {
    final paginator = _ongoingPaginator;
    if (paginator == null || _paginatingAhead) {
      // 已排完或正忙：直接按当前已排位置跳（pageIndexOf 兜底末页）
      _goChapterJump(blockIndex);
      return;
    }
    _paginatingAhead = true;
    if (mounted) setState(() {}); // 显示底部进度条
    final chunk = (paginator.blockCount ~/ 400).clamp(12, 300);
    try {
      while (!paginator.finished &&
          _ongoingPaginator == paginator &&
          mounted &&
          paginator.currentBlockIndex <= blockIndex) {
        paginator.stepInto(_pages, chunk: chunk);
        _paginatedBlockCount = paginator.currentBlockIndex;
        _bgPaginateDone = paginator.currentBlockIndex;
        setState(() {});
        SchedulerBinding.instance.scheduleFrame();
        await SchedulerBinding.instance.endOfFrame;
      }
    } finally {
      _paginatingAhead = false;
      if (paginator.finished && _ongoingPaginator == paginator) {
        _ongoingPaginator = null;
        await _writeFullCache(paginator);
      }
      if (mounted) {
        _goChapterJump(blockIndex);
        // 补到目标后再向前留一个窗口（未排完时）
        if (_ongoingPaginator == paginator) _continuePagination();
      }
    }
  }

  /// 目录跳转的纯定位逻辑（不含补排）。
  void _goChapterJump(int blockIndex) {
    final page = BookPaginator.pageIndexOf(_pages, blockIndex);
    final mode = ReaderOverrideService().effectiveBookMode(widget.task.bookId);
    if (mode == BookReadingMode.simulation || mode == BookReadingMode.cover) {
      _turnTo(page);
    } else {
      _currentPage = _pages.isEmpty ? 0 : page.clamp(0, _pages.length - 1);
      _currentPageNotifier.value = _currentPage;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(
          _isDoublePage ? _pageToSpread(_currentPage) : _currentPage,
        );
      }
    }
    setState(() => _showControls = false);
  }

  Future<void> _writeFullCache(BookPaginator paginator) async {
    await BookPageCacheService.instance.write(
      bookId: widget.task.bookId,
      key: _paginateKey,
      pages: _pages,
      ratios: _imageRatios,
      naturalWidths: _imageNaturalWidths,
      flatBlocks: paginator.blocks,
    );
    _log('写分页缓存(全书完成) key=$_paginateKey pages=${_pages.length}');
  }

  /// 调参 / 旋屏重排：首批分到当前阅读位置即显示，剩余页后台增量补齐
  /// （[_continuePagination]），避免全本排完才能读。复用后台流式分页机制。
  Future<void> _repaginateBackground({
    required double vpW,
    required double vpH,
    required int preserveBlockIndex,
  }) async {
    final content = _content;
    if (content == null) return;
    final key = _paginateKeyOf(vpW, vpH);
    if (key == _paginateKey && _pages.isNotEmpty) return;
    _ongoingPaginator = null; // 取消旧后台分页
    _paginatingAhead = false;
    _pendingResumeBlock = null; // 调参重排定位由首批直接完成，无需续读跳转
    _paginateKey = key;
    final typo = _typo;
    final allBlocks = content.flatBlocks;
    final starts = content.chapterStarts;
    final totalChapters = starts.length;
    final paginator = BookPaginator(
      blocks: allBlocks,
      viewportWidth: _paginateViewportWidth(vpW),
      viewportHeight: vpH,
      typo: typo,
      imageAspectRatios: _imageRatios,
      imageNaturalWidths: _imageNaturalWidths,
      chapterStarts: starts.toSet(),
    );
    // 大书自适应 chunk（同 _continuePagination），首批到当前阅读位置即显示
    final chunk = (paginator.blockCount ~/ 400).clamp(12, 300);
    setState(() {
      _paginating = true;
      _paginateDone = 0;
      _paginateTotal = totalChapters;
    });
    final pages = <BookPage>[];
    // 🔴 `clamp(0, -1)` 会**真抛 `ArgumentError`** ✗ —— `num.clamp` 在
    // `lowerLimit > upperLimit` 时抛异常（release 同样抛 ✓，不是 assert ✓，
    // 已在 SDK 的 `_internal/vm/lib/integers.dart` 核实 ✓）。
    // 当 `allBlocks` 为空（空书 / 正文解析出 0 段落 ✓）时上界 = -1 ✗ →
    // **一进入分页就崩** ✓（与今天修的另一处 `flat.length` 同源同因 ✓）。
    // 空时取 0 ✓；此时 `paginator` 也没有可分的内容 ✓，
    // 下面 while 由 `!paginator.finished` 兜住 ✓
    final preserve = allBlocks.isEmpty
        ? 0
        : preserveBlockIndex.clamp(0, allBlocks.length - 1);
    var chapterDone = 0;
    // 首批：增量分到覆盖当前阅读位置（preserve），每批让出 UI
    while (!paginator.finished && paginator.currentBlockIndex <= preserve) {
      paginator.stepInto(pages, chunk: chunk);
      final bi = paginator.currentBlockIndex;
      while (chapterDone < totalChapters && starts[chapterDone] < bi) {
        chapterDone++;
      }
      if (mounted) setState(() => _paginateDone = chapterDone);
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    if (!mounted) return;
    final target = BookPaginator.pageIndexOf(pages, preserve);
    setState(() {
      _pages = pages;
      _paginating = false;
      _currentPage = target;
      _ongoingPaginator = paginator;
      _totalBlockCount = allBlocks.length;
      _paginatedBlockCount = paginator.currentBlockIndex;
      _bgPaginateTotal = paginator.blockCount;
      _bgPaginateDone = paginator.currentBlockIndex;
    });
    _currentPageNotifier.value = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        _pageController.jumpToPage(
          _isDoublePage ? _pageToSpread(target) : target,
        );
      }
    });
    _log('重排首批 ${pages.length} 页 -> 定位 block $preserve 页 $target，后台补齐剩余');
    // 后台增量补齐剩余页（底部进度条，不打扰阅读）
    _continuePagination();
  }

  void _onPointerDown(PointerDownEvent e) {
    _tapDownPos = e.position;
    _tapDownTime = DateTime.now();
  }

  void _onPointerUp(PointerUpEvent e) {
    // 控件栏显示时，点击交给控件层处理（按钮 / 中间空白关闭），不翻页
    if (_showControls) return;
    final pos = _tapDownPos;
    final t = _tapDownTime;
    _tapDownPos = null;
    _tapDownTime = null;
    if (pos == null || t == null) return;
    final dist = (e.position - pos).distance;
    final dt = DateTime.now().difference(t).inMilliseconds;
    // 长按选字（>350ms）或拖动翻页（位移大）交给下层，仅短按单击才翻页
    if (dist > 18 || dt > 350) return;
    final w = MediaQuery.sizeOf(context).width;
    final dx = e.position.dx;
    final reverse = ReaderOverrideService().effectiveReverseTapBook(
      widget.task.bookId,
    );
    final tapLeft = dx < w / 3;
    final tapRight = dx > w * 2 / 3;
    if (tapLeft) {
      reverse ? _onTapRight() : _onTapLeft();
    } else if (tapRight) {
      reverse ? _onTapLeft() : _onTapRight();
    } else {
      _toggleControls();
    }
  }

  void _toggleControls() => setState(() => _showControls = !_showControls);

  void _onTapLeft() {
    final canPrev = _isDoublePage ? _currentSpread > 0 : _currentPage > 0;
    if (canPrev) {
      _goAdjacentPage(-1);
    }
  }

  void _onTapRight() {
    final canNext = _isDoublePage
        ? _currentSpread < _spreadCount - 1
        : _currentPage < _pages.length - 1;
    if (canNext) {
      _goAdjacentPage(1);
    }
  }

  /// 翻一页（[delta] -1 上一页 / 1 下一页）。无动画模式瞬切，其余平滑滑动。
  void _goAdjacentPage(int delta) {
    final controllerPage = _isDoublePage ? _currentSpread : _currentPage;
    if (ReaderOverrideService().effectiveBookMode(widget.task.bookId) ==
        BookReadingMode.none) {
      _pageController.jumpToPage(controllerPage + delta);
      return;
    }
    delta < 0
        ? _pageController.previousPage(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          )
        : _pageController.nextPage(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          );
  }

  /// 音量键翻页：下=下一页，上=上一页。按当前模式分发到对应翻页方法。
  void _onVolumeKey(String dir) {
    if (!mounted) return;
    final next = dir == 'down';
    if (_isImageMode) {
      next ? _imageNext() : _imagePrev();
      return;
    }
    final mode = ReaderOverrideService().effectiveBookMode(widget.task.bookId);
    if (mode == BookReadingMode.simulation || mode == BookReadingMode.cover) {
      final spread = _currentSpread;
      _turnTo(
        _isDoublePage
            ? _spreadLeftPage(spread + (next ? 1 : -1))
            : _currentPage + (next ? 1 : -1),
      );
      return;
    }
    next ? _onTapRight() : _onTapLeft();
  }

  void _goChapter(int chapterIndex) {
    if (chapterIndex < 0 || chapterIndex >= _chapterStarts.length) return;
    final blockIndex = _chapterStarts[chapterIndex];
    if (_isImageMode) {
      final imgIdx = _imageIndexOfBlock(blockIndex, clamp: true);
      if (imgIdx >= 0) _imageGoto(imgIdx);
      setState(() => _showControls = false);
      return;
    }
    // 懒分页：目标 block 超出已排窗口时，先向前补排到目标再跳（目录远跳）
    if (_ongoingPaginator != null && blockIndex > _paginatedBlockCount) {
      _extendToBlock(blockIndex);
      return;
    }
    final page = BookPaginator.pageIndexOf(_pages, blockIndex);
    final spread = _pageToSpread(page);
    // 仿真模式无 PageView，_pageController 未挂载，直接切 _currentPage；
    // pageTurn 模式经 PageView 滚动（onPageChanged 会同步 _currentPage 与进度）。
    final mode = ReaderOverrideService().effectiveBookMode(widget.task.bookId);
    if (mode == BookReadingMode.simulation || mode == BookReadingMode.cover) {
      _turnTo(page);
    } else if (_pageController.hasClients) {
      _pageController.jumpToPage(_isDoublePage ? spread : page);
    }
    setState(() => _showControls = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = _readerIsDark;
    final bgColor = isDark
        ? JellyTheme.backgroundDark
        : JellyTheme.backgroundLight;
    final textColor = isDark
        ? Colors.white.withValues(alpha: 0.92)
        : JellyTheme.textPrimaryLight;
    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          _buildBody(isDark, textColor, bgColor),
          _buildHud(isDark),
          _buildControls(isDark, textColor),
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark, Color textColor, Color bgColor) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 40, color: JellyTheme.error),
              const SizedBox(height: 16),
              Text(
                '打开失败：$_error',
                textAlign: TextAlign.center,
                style: TextStyle(color: textColor),
              ),
              const SizedBox(height: 16),
              if (widget.task.localPath != null)
                TextButton.icon(
                  onPressed: () async {
                    final ok = await PlatformService.openFile(
                      widget.task.localPath!,
                      BookReaderPage._mimeOf(
                        (widget.task.extension ?? 'epub').toLowerCase(),
                      ),
                    );
                    if (!ok && mounted) {
                      BookReaderPage._toast(context, '未找到可打开此格式的应用');
                    }
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('用其他应用打开'),
                ),
            ],
          ),
        ),
      );
    }
    if (_content == null || _blocks.isEmpty) {
      return Center(
        child: Text('暂无内容', style: TextStyle(color: textColor)),
      );
    }
    if (_isImageMode && _imageBlockIndices.isNotEmpty) {
      return _buildImageGallery();
    }
    return _buildPaged(textColor, bgColor);
  }

  // ---------------- pageTurn 模式 ----------------

  Widget _buildPaged(Color textColor, Color bgColor) {
    // 仿真模式让背景图铺满全屏（含刘海/状态栏区）：SafeArea 仅吃 top/bottom，
    // 不吃 left/right，左右安全区改由 _buildPageView 的 padding 加 safeLeft/
    // safeRight 避开刘海；分页/渲染用扣安全区后的等效宽度，度量与原一致。
    final simMode =
        ReaderOverrideService().effectiveBookMode(widget.task.bookId) ==
        BookReadingMode.simulation;
    return SafeArea(
      top: false,
      bottom: false,
      left: !simMode,
      right: !simMode,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final vpW = constraints.maxWidth;
          final vpH = constraints.maxHeight;
          final safeTop = MediaQuery.paddingOf(context).top;
          final safeBottom = MediaQuery.paddingOf(context).bottom;
          // 仿真模式 SafeArea 不再吃左右安全区，需手动扣除以保持文字宽度一致
          final safeLeft = simMode ? MediaQuery.paddingOf(context).left : 0.0;
          final safeRight = simMode ? MediaQuery.paddingOf(context).right : 0.0;
          final effW = vpW - safeLeft - safeRight;
          final textVpH = vpH - safeTop - safeBottom;
          // 视口或排版参数变化 -> 重新分页（保留当前 block）
          final key = _paginateKeyOf(effW, textVpH);
          final needRepaginate = key != _paginateKey;
          if (needRepaginate && !_paginating) {
            // 视口 / 参数变化：后台重排，首批到当前页即显示，剩余增量补齐
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final preserve = _pages.isEmpty
                  ? (BookReadingProgressService()
                            .getProgress(widget.task.bookId)
                            ?.blockIndex ??
                        0)
                  : _pages[_currentPage.clamp(0, _pages.length - 1)]
                        .firstBlockIndex;
              _repaginateBackground(
                vpW: effW,
                vpH: textVpH,
                preserveBlockIndex: preserve,
              );
            });
          }
          // 待重排时旧分页已按旧字号度量，直接显示占位，避免用新字号渲染溢出底部
          if (_paginating || _pages.isEmpty || needRepaginate) {
            return _buildPaginatingView(textColor);
          }
          final contentWidth = _renderContentWidth(effW);
          // 正文就绪后淡入，消除 loading -> 排版 -> 正文 的硬切（参照漫画阅读器）
          // key 绑定分页参数：重排（视口/字号变化）时 key 变化重新淡入，
          // 稳定时保持 1.0 不重跑
          return Stack(
            fit: StackFit.expand,
            children: [
              TweenAnimationBuilder<double>(
                key: ValueKey('fade_$_paginateKey'),
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                builder: (context, v, child) =>
                    Opacity(opacity: v, child: child),
                child: _buildReaderContent(
                  textColor,
                  contentWidth,
                  safeTop,
                  safeBottom,
                  safeLeft,
                  safeRight,
                ),
              ),
              // 懒分页正在向前补排：底部细进度条，不打扰阅读（停在窗口边界时不显示）
              if (_paginatingAhead)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: safeBottom,
                  child: LinearProgressIndicator(
                    value: _bgPaginateTotal > 0
                        ? _bgPaginateDone / _bgPaginateTotal
                        : null,
                    minHeight: 2,
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      textColor.withValues(alpha: 0.5),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildReaderContent(
    Color textColor,
    double contentWidth,
    double safeTop,
    double safeBottom,
    double safeLeft,
    double safeRight,
  ) {
    final mode = ReaderOverrideService().effectiveBookMode(widget.task.bookId);
    if (mode == BookReadingMode.simulation) {
      return _buildSimulation(
        textColor,
        contentWidth,
        safeTop,
        safeBottom,
        safeLeft,
        safeRight,
      );
    }
    if (mode == BookReadingMode.cover) {
      return _buildCover(
        textColor,
        contentWidth,
        safeTop,
        safeBottom,
        safeLeft,
        safeRight,
      );
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      child: PageView.builder(
        controller: _pageController,
        // 上下模式纵向翻页，其余（左右/无动画）横向
        scrollDirection: mode == BookReadingMode.vertical
            ? Axis.vertical
            : Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        itemCount: _isDoublePage ? _spreadCount : _pages.length,
        onPageChanged: (i) {
          final page = _isDoublePage ? _spreadLeftPage(i) : i;
          _currentPage = page;
          _currentPageNotifier.value = page;
          _userPaged = true; // 用户手动翻页，取消后台续读自动跳转
          BookReadingProgressService().recordBlock(
            widget.task.bookId,
            _pages[page].firstBlockIndex,
            page,
            _displayTotalPages,
          );
          _applyReadingStatus();
          // 懒分页：靠近已排窗口末尾时向前补排一个窗口
          if (_ongoingPaginator != null &&
              !_paginatingAhead &&
              _pages.length - page <= _kWindowMarginPages) {
            _continuePagination();
          }
        },
        itemBuilder: (context, index) => _isDoublePage
            ? _buildDoublePageSpread(
                index,
                textColor,
                contentWidth,
                safeTop,
                safeBottom,
                safeLeft,
                safeRight,
              )
            : _buildPageView(
                index,
                textColor,
                contentWidth,
                safeTop,
                safeBottom,
                safeLeft,
                safeRight,
              ),
      ),
    );
  }

  /// 双页 spread：首页或末尾单页时单页占满，否则左右两页并排
  Widget _buildDoublePageSpread(
    int spread,
    Color textColor,
    double contentWidth,
    double safeTop,
    double safeBottom,
    double safeLeft,
    double safeRight,
  ) {
    final left = _spreadLeftPage(spread);
    final right = _spreadRightPage(spread);
    final hasRight = right < _pages.length;
    if (spread == 0 || !hasRight) {
      return _buildPageView(
        spread == 0 ? 0 : left,
        textColor,
        contentWidth,
        safeTop,
        safeBottom,
        spread == 0 ? safeLeft : 0,
        spread == 0 ? safeRight : 0,
      );
    }
    return Row(
      children: [
        Expanded(
          child: _buildPageView(
            left,
            textColor,
            contentWidth,
            safeTop,
            safeBottom,
            safeLeft,
            0,
          ),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: _buildPageView(
            right,
            textColor,
            contentWidth,
            safeTop,
            safeBottom,
            0,
            safeRight,
          ),
        ),
      ],
    );
  }

  Widget _buildSimulation(
    Color textColor,
    double contentWidth,
    double safeTop,
    double safeBottom,
    double safeLeft,
    double safeRight,
  ) {
    // 双页模式：以 spread 为单位卷曲翻页（左右两页一起卷起/落下）
    if (_isDoublePage) {
      final spread = _currentSpread;
      return BookPageCurl(
        page: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              'assets/images/reader_backgroud.jpg',
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
            ),
            _buildDoublePageSpread(
              spread,
              textColor,
              contentWidth,
              safeTop,
              safeBottom,
              safeLeft,
              safeRight,
            ),
          ],
        ),
        nextPage: spread < _spreadCount - 1
            ? _buildDoublePageSpread(
                spread + 1,
                textColor,
                contentWidth,
                safeTop,
                safeBottom,
                safeLeft,
                safeRight,
              )
            : null,
        prevPage: spread > 0
            ? _buildDoublePageSpread(
                spread - 1,
                textColor,
                contentWidth,
                safeTop,
                safeBottom,
                safeLeft,
                safeRight,
              )
            : null,
        background: Image.asset(
          'assets/images/reader_backgroud.jpg',
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
        ),
        canNext: spread < _spreadCount - 1,
        canPrev: spread > 0,
        onTurnNext: () => _turnTo(_spreadLeftPage(spread + 1)),
        onTurnPrev: () => _turnTo(_spreadLeftPage(spread - 1)),
        onTapCenter: _toggleControls,
      );
    }
    return BookPageCurl(
      // 翻起页自带背景图底：栅格化出"背景图+文字"的不透明页，卷曲时文字附在
      // 背景图纸面上；nextPage/prevPage 保持透明，翻页时露出底层背景图。
      page: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/images/reader_backgroud.jpg',
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          ),
          _buildPageView(
            _currentPage,
            textColor,
            contentWidth,
            safeTop,
            safeBottom,
            safeLeft,
            safeRight,
          ),
        ],
      ),
      nextPage: _currentPage < _pages.length - 1
          ? _buildPageView(
              _currentPage + 1,
              textColor,
              contentWidth,
              safeTop,
              safeBottom,
              safeLeft,
              safeRight,
            )
          : null,
      prevPage: _currentPage > 0
          ? _buildPageView(
              _currentPage - 1,
              textColor,
              contentWidth,
              safeTop,
              safeBottom,
              safeLeft,
              safeRight,
            )
          : null,
      background: Image.asset(
        'assets/images/reader_backgroud.jpg',
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
      ),
      canNext: _currentPage < _pages.length - 1,
      canPrev: _currentPage > 0,
      onTurnNext: () => _turnTo(_currentPage + 1),
      onTurnPrev: () => _turnTo(_currentPage - 1),
      onTapCenter: _toggleControls,
    );
  }

  /// 覆盖模式：新页从边缘滑入覆盖当前页（无背景图，用 pageTurn 式正常布局）。
  Widget _buildCover(
    Color textColor,
    double contentWidth,
    double safeTop,
    double safeBottom,
    double safeLeft,
    double safeRight,
  ) {
    // 滑入页需自带不透明底色，否则覆盖时与当前页文字重叠
    final bgColor = _readerIsDark
        ? JellyTheme.backgroundDark
        : JellyTheme.backgroundLight;
    // 双页模式：以 spread 为单位覆盖翻页
    if (_isDoublePage) {
      final spread = _currentSpread;
      return BookPageCover(
        backgroundColor: bgColor,
        page: _buildDoublePageSpread(
          spread,
          textColor,
          contentWidth,
          safeTop,
          safeBottom,
          safeLeft,
          safeRight,
        ),
        nextPage: spread < _spreadCount - 1
            ? _buildDoublePageSpread(
                spread + 1,
                textColor,
                contentWidth,
                safeTop,
                safeBottom,
                safeLeft,
                safeRight,
              )
            : null,
        prevPage: spread > 0
            ? _buildDoublePageSpread(
                spread - 1,
                textColor,
                contentWidth,
                safeTop,
                safeBottom,
                safeLeft,
                safeRight,
              )
            : null,
        canNext: spread < _spreadCount - 1,
        canPrev: spread > 0,
        onTurnNext: () => _turnTo(_spreadLeftPage(spread + 1)),
        onTurnPrev: () => _turnTo(_spreadLeftPage(spread - 1)),
        onTapCenter: _toggleControls,
      );
    }
    return BookPageCover(
      backgroundColor: bgColor,
      page: _buildPageView(
        _currentPage,
        textColor,
        contentWidth,
        safeTop,
        safeBottom,
        safeLeft,
        safeRight,
      ),
      nextPage: _currentPage < _pages.length - 1
          ? _buildPageView(
              _currentPage + 1,
              textColor,
              contentWidth,
              safeTop,
              safeBottom,
              safeLeft,
              safeRight,
            )
          : null,
      prevPage: _currentPage > 0
          ? _buildPageView(
              _currentPage - 1,
              textColor,
              contentWidth,
              safeTop,
              safeBottom,
              safeLeft,
              safeRight,
            )
          : null,
      canNext: _currentPage < _pages.length - 1,
      canPrev: _currentPage > 0,
      onTurnNext: () => _turnTo(_currentPage + 1),
      onTurnPrev: () => _turnTo(_currentPage - 1),
      onTapCenter: _toggleControls,
    );
  }

  Widget _buildPageView(
    int index,
    Color textColor,
    double contentWidth,
    double safeTop,
    double safeBottom,
    double safeLeft,
    double safeRight,
  ) {
    final entries = _pages[index].entries;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        safeLeft + _typo.padding,
        safeTop + _typo.verticalPadding,
        safeRight + _typo.padding,
        safeBottom + _typo.verticalPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            _buildEntry(entries[i], textColor, contentWidth),
            if (i < entries.length - 1) SizedBox(height: _typo.blockSpacing),
          ],
        ],
      ),
    );
  }

  void _turnTo(int index) {
    if (index < 0 || index >= _pages.length) return;
    // 双页模式：_currentPage 始终对齐到 spread 左页，保证 _currentSpread/翻页计算稳定
    if (_isDoublePage) {
      index = _spreadLeftPage(_pageToSpread(index));
    }
    _userPaged = true; // 仿真翻页也算用户操作，取消后台续读自动跳转
    setState(() => _currentPage = index);
    _currentPageNotifier.value = index;
    BookReadingProgressService().recordBlock(
      widget.task.bookId,
      _pages[index].firstBlockIndex,
      index,
      _displayTotalPages,
    );
    _applyReadingStatus();
    // 懒分页（仿真/封面模式不经 onPageChanged）：靠近已排窗口末尾时补排
    if (_ongoingPaginator != null &&
        !_paginatingAhead &&
        _pages.length - index <= _kWindowMarginPages) {
      _continuePagination();
    }
  }

  /// 按当前进度把书归位到"正在读"/"已读完"书架（幂等，带状态缓存避免频繁调用）。
  void _applyReadingStatus() {
    if (_isImageMode) {
      if (_imageBlockIndices.isEmpty) return;
      final finished = _currentImageIndex + 1 >= _imageBlockIndices.length;
      final target = finished
          ? BookshelfService.presetFinished
          : BookshelfService.presetReading;
      if (_lastAppliedStatus == target) return;
      _lastAppliedStatus = target;
      final t = widget.task;
      BookshelfService().moveBetweenStatusShelves(
        bookId: t.bookId,
        type: BookshelfItemType.book,
        toShelf: target,
        meta: jsonEncode(
          Book(
            id: t.bookId,
            hash: t.hash,
            title: t.title,
            author: t.author,
            cover: t.cover,
            extension: t.extension,
          ).toJson(),
        ),
      );
      return;
    }
    if (_pages.isEmpty) return;
    final finished = _isDoublePage
        ? _currentSpread + 1 >= _spreadCount
        : _currentPage + 1 >= _pages.length;
    final target = finished
        ? BookshelfService.presetFinished
        : BookshelfService.presetReading;
    if (_lastAppliedStatus == target) return;
    _lastAppliedStatus = target;
    final t = widget.task;
    BookshelfService().moveBetweenStatusShelves(
      bookId: t.bookId,
      type: BookshelfItemType.book,
      toShelf: target,
      meta: jsonEncode(
        Book(
          id: t.bookId,
          hash: t.hash,
          title: t.title,
          author: t.author,
          cover: t.cover,
          extension: t.extension,
        ).toJson(),
      ),
    );
  }

  // ---------------- 图片模式 ----------------

  /// 统计图片块并判定是否自动进入图片模式。
  /// 启发式（用户指定）：图片数 >= 10 且 有效图片占比 >= 90%。
  /// 占比分母剔除短文本块（trim 后长度 <= 20，如 "Page-N" 导航标签），
  /// 让夹带页码标签的绘本仍能识别为图片书。仅统计已预载字节的图片，
  /// PDF 等懒加载场景（images 为空、走 imageLoader）不进图片模式。
  void _setupImageMode() {
    final content = _content;
    final blocks = content?.flatBlocks ?? const [];
    _imageBlockIndices = const [];
    if (blocks.isEmpty || content == null) return;
    final indices = <int>[];
    // PDF 等懒加载场景：images 初始为空，每页都是 ImageBlock，直接计为图片页。
    final lazy = content.imageLoader != null;
    var imageCount = 0;
    var shortTextCount = 0;
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      if (b is ImageBlock) {
        if (lazy || content.images[b.imageKey] != null) {
          imageCount++;
          indices.add(i);
        }
      } else if (b is ParagraphBlock) {
        if (b.text.trim().length <= 20) shortTextCount++;
      } else if (b is HeadingBlock) {
        if (b.text.trim().length <= 20) shortTextCount++;
      }
    }
    _imageBlockIndices = indices;
    if (lazy) {
      // PDF：每页即图，默认进图片模式（消散/画廊按需光栅化 + 预载相邻页）。
      _isImageMode = imageCount > 0;
    } else if (imageCount >= 10) {
      final effectiveTotal = blocks.length - shortTextCount;
      if (effectiveTotal > 0 && imageCount / effectiveTotal >= 0.9) {
        _isImageMode = true;
      }
    }
    if (_isImageMode && _imageBlockIndices.isNotEmpty) {
      // 续读定位：按保存的 blockIndex 找最近图片
      final p = BookReadingProgressService().getProgress(widget.task.bookId);
      final startBlock = p == null
          ? 0
          : p.blockIndex.clamp(0, blocks.length - 1);
      _currentImageIndex = _imageIndexOfBlock(
        startBlock,
        clamp: true,
      ).clamp(0, _imageBlockIndices.length - 1);
      _imagePageController = PageController(initialPage: _currentImageIndex);
      _currentPageNotifier.value = _currentImageIndex;
      if (lazy) {
        // 首屏预载相邻页（post-frame，待 context 就绪）
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _preloadAdjacentImages(_currentImageIndex),
        );
      }
    }
  }

  /// 找 blockIndex 对应的图片序号：精确命中或首个 > blockIndex 的图片；
  /// [clamp]=true 时若后面没有图片则回退到最后一张（续读 / 跳章定位用）。
  int _imageIndexOfBlock(int blockIndex, {bool clamp = false}) {
    final indices = _imageBlockIndices;
    if (indices.isEmpty) return -1;
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] == blockIndex) return i;
      if (indices[i] > blockIndex) return i;
    }
    return clamp ? indices.length - 1 : -1;
  }

  Uint8List? _imageBytesAt(int index) {
    if (index < 0 || index >= _imageBlockIndices.length) return null;
    final block = _blocks[_imageBlockIndices[index]];
    if (block is! ImageBlock) return null;
    return _content?.images[block.imageKey];
  }

  /// PDF 光栅化目标宽（物理像素）：屏宽 × dpr，clamp 上限控内存。
  /// 消散 / 画廊 / 预载共用同一值，保证 ImageProvider 缓存键一致。
  double get _pdfTargetWidth {
    final w = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return (w * dpr).clamp(800.0, 2400.0);
  }

  /// 预载相邻页（PDF 懒加载）：把 index±1 经 precacheImage 提前光栅化+解码
  /// 进 Flutter 图片缓存，翻页时 Image 命中缓存首帧即出，消散交叉淡入无空白闪烁。
  void _preloadAdjacentImages(int index) {
    final loader = _content?.imageLoader;
    if (loader == null || _imageBlockIndices.isEmpty || !mounted) return;
    final w = _pdfTargetWidth;
    for (final delta in const [1, -1]) {
      final i = index + delta;
      if (i < 0 || i >= _imageBlockIndices.length) continue;
      final block = _blocks[_imageBlockIndices[i]];
      if (block is! ImageBlock) continue;
      precacheImage(_PdfPageImageProvider(block.imageKey, w, loader), context);
    }
  }

  /// 图片 / 文本模式互切。切回文本时按当前图片 block 定位到对应文本页；
  /// 切到图片时按当前页首 block 定位到最近图片。
  void _toggleImageMode() {
    if (_imageBlockIndices.isEmpty) return;
    final wasImageMode = _isImageMode;
    setState(() {
      _isImageMode = !_isImageMode;
      _showControls = false;
      if (wasImageMode) {
        final imgIdx = _currentImageIndex.clamp(
          0,
          _imageBlockIndices.length - 1,
        );
        final blockIndex = _imageBlockIndices[imgIdx];
        final page = BookPaginator.pageIndexOf(_pages, blockIndex);
        _currentPage = _pages.isEmpty ? 0 : page.clamp(0, _pages.length - 1);
        _currentPageNotifier.value = _currentPage;
        _imagePageController?.dispose();
        _imagePageController = null;
        final mode = ReaderOverrideService().effectiveBookMode(
          widget.task.bookId,
        );
        if (mode != BookReadingMode.simulation &&
            mode != BookReadingMode.cover) {
          // pageTurn 模式 PageView 在图片模式期间未挂载，重建控制器以 initialPage 定位
          _pageController.dispose();
          _pageController = PageController(initialPage: _currentPage);
        }
      } else {
        final startBlock = _pages.isEmpty
            ? 0
            : _pages[_currentPage.clamp(0, _pages.length - 1)].firstBlockIndex;
        _currentImageIndex = _imageIndexOfBlock(
          startBlock,
          clamp: true,
        ).clamp(0, _imageBlockIndices.length - 1);
        _imagePageController = PageController(initialPage: _currentImageIndex);
        _currentPageNotifier.value = _currentImageIndex;
      }
    });
    _applyReadingStatus();
  }

  void _handleImageTap(TapUpDetails details) {
    if (_showControls) {
      _toggleControls();
      return;
    }
    final w = MediaQuery.sizeOf(context).width;
    final dx = details.globalPosition.dx;
    if (dx < w / 3) {
      _imagePrev();
    } else if (dx > w * 2 / 3) {
      _imageNext();
    } else {
      _toggleControls();
    }
  }

  void _imageGoto(int index) {
    if (index < 0 || index >= _imageBlockIndices.length) return;
    setState(() {
      _currentImageIndex = index;
      _currentPageNotifier.value = index;
    });
    final c = _imagePageController;
    if (c != null && c.hasClients) c.jumpToPage(index);
    _recordImageProgress();
    _applyReadingStatus();
    _preloadAdjacentImages(index);
  }

  void _imageNext() {
    final c = _imagePageController;
    if (c == null || !c.hasClients) {
      _imageGoto(_currentImageIndex + 1); // 控制器未挂载（如刚切模式）回退瞬切
      return;
    }
    if (_currentImageIndex < _imageBlockIndices.length - 1) {
      c.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
    // 到末页停住：图片模式为全书图片，无「下一话」可切。
  }

  void _imagePrev() {
    final c = _imagePageController;
    if (c == null || !c.hasClients) {
      _imageGoto(_currentImageIndex - 1);
      return;
    }
    if (_currentImageIndex > 0) {
      c.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _recordImageProgress() {
    if (_imageBlockIndices.isEmpty) return;
    final idx = _currentImageIndex.clamp(0, _imageBlockIndices.length - 1);
    BookReadingProgressService().recordBlock(
      widget.task.bookId,
      _imageBlockIndices[idx],
      idx,
      _imageBlockIndices.length,
    );
  }

  Widget _buildImageGallery() {
    // 图片模式统一用消散（交叉淡入淡出），不跟随图书阅读器的翻页模式设置
    return _buildImageDissolve();
  }

  Widget _buildImageDissolve() {
    return GestureDetector(
      onTapUp: _handleImageTap,
      child: ColoredBox(
        color: Colors.black,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: _buildImageDissolvePage(_currentImageIndex),
        ),
      ),
    );
  }

  Widget _buildImageDissolvePage(int index) {
    if (index < 0 || index >= _imageBlockIndices.length) {
      return const SizedBox.shrink();
    }
    final isDark = _readerIsDark;
    final loader = _content?.imageLoader;
    if (loader != null) {
      // PDF 懒加载：经 ImageProvider 走 Flutter 图片缓存；夜间反色（同文本模式）
      final block = _blocks[_imageBlockIndices[index]];
      if (block is! ImageBlock) return const SizedBox.shrink();
      return SizedBox.expand(
        key: ValueKey(index),
        child: Image(
          image: _PdfPageImageProvider(block.imageKey, _pdfTargetWidth, loader),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          color: isDark ? Colors.white : null,
          colorBlendMode: isDark ? BlendMode.difference : null,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return const Center(child: CircularProgressIndicator());
          },
        ),
      );
    }
    final bytes = _imageBytesAt(index);
    if (bytes == null) {
      return SizedBox.expand(
        key: ValueKey(index),
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    return SizedBox.expand(
      key: ValueKey(index),
      child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
    );
  }

  Widget _buildPaginatingView(Color textColor) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            _paginateTotal > 0
                ? '排版中 $_paginateDone/$_paginateTotal 章'
                : '排版中...',
            style: TextStyle(color: textColor),
          ),
        ],
      ),
    );
  }

  // ---------------- 块渲染（两模式共用） ----------------

  Widget _buildEntry(PageEntry entry, Color textColor, double contentWidth) {
    final block = entry.block;
    if (block is ParagraphBlock) {
      final text = entry.partialText ?? block.text;
      return SelectableText(
        text,
        style: _typo.paragraphStyle().copyWith(color: textColor),
        strutStyle: _typo.paragraphStrut,
        textHeightBehavior: _typo.textHeightBehavior,
        // ✅ **本地图书：选中文字即可「划线」**（本会话第 3 轮 ✓ —— 此前顶栏「笔记」只能看 ✓）
        //   为什么用 `contextMenuBuilder` 而不是长按 ✗：长按已被**选字**占用 ✓（内层优先 ✓），
        //   硬套要么不触发 ✗、要么把选字弄坏 ✗✗ —— 走**系统选中菜单**才是正路 ✓。
        //   · 段号 = `entry.blockIndex` ✓✓（第 2 轮已保证**可信**：长段落分块也带同一段号 ✓）
        //   · 章号/章名 = 由 `chapterStarts` **反查** ✓（`BookContent` 现成提供 ✓）
        //   · 存储复用 `ReaderNotesService` ✓ ⇒ 与**书源阅读器**同一份笔记 ✓（笔记页能看到 ✓）
        //   ⚠️ 如实边界 ✓：· 标题块走 `Text` ✗ 不可选 ⇒ 标题划不了 ✓
        //              · 模型只有段号+文字 ✗（无段内起止偏移 ✓）⇒ 回显是"本段含该文字"级 ✓
        contextMenuBuilder: (ctx, editable) {
          final sel = editable.textEditingValue.selection;
          final picked = sel.isValid && !sel.isCollapsed
              ? sel.textInside(editable.textEditingValue.text)
              : '';
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: editable.contextMenuAnchors,
            buttonItems: [
              ...editable.contextMenuButtonItems,
              if (picked.trim().isNotEmpty)
                ContextMenuButtonItem(
                  label: '划线',
                  onPressed: () {
                    final cs = _content?.chapterStarts;
                    var ci = 0;
                    if (cs != null && entry.blockIndex >= 0) {
                      for (var i = 0; i < cs.length; i++) {
                        if (cs[i] <= entry.blockIndex) ci = i;
                      }
                    }
                    final cname =
                        (_content != null && ci < _content!.chapters.length)
                            ? _content!.chapters[ci].title
                            : '';
                    ReaderNotesService.instance.toggleHighlight(
                      sourceId: 'local',
                      sourceName: '本地图书',
                      bookName: widget.task.title,
                      chapterIndex: ci,
                      chapterName: cname,
                      paragraphIndex: entry.blockIndex,
                      text: picked.trim(),
                    );
                    editable.hideToolbar();
                  },
                ),
            ],
          );
        },
      );
    }
    if (block is HeadingBlock) {
      final text = entry.partialText ?? block.text;
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          text,
          style: _typo.headingStyle(block.level).copyWith(color: textColor),
          strutStyle: _typo.headingStrut(block.level),
          textHeightBehavior: _typo.textHeightBehavior,
        ),
      );
    }
    if (block is ImageBlock) {
      final bytes = _content?.images[block.imageKey];
      if (bytes == null) {
        // PDF 等懒加载场景：images 未预载，按需经 imageLoader 光栅化
        final loader = _content?.imageLoader;
        if (loader != null) {
          return Flexible(
            child: _PdfPageImage(
              imageKey: block.imageKey,
              contentWidth: contentWidth,
              // 日夜覆盖现在是页面实例状态，子 widget 读不到，必须显式传下去 ✓
              isDark: _readerIsDark,
              loader: loader,
              onLoaded: (k, b) => _content?.images[k] = b,
            ),
          );
        }
        return const SizedBox.shrink();
      }
      final isDark = _readerIsDark;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      // 行内标注图标（注脚标记等，CSS 常约束 ~0.8em）：按字号显示，不占满宽。
      // 判据：自然像素宽度小且接近正方形——出版方为 retina 给的位图常 100~256px，
      // 但 intended 显示仅 1em 量级；无 width 属性时按像素显示会被放大约 10 倍。
      final naturalW = _imageNaturalWidths[block.imageKey];
      final ar = _imageRatios[block.imageKey] ?? block.aspectRatio ?? 1.5;
      final isInlineIcon =
          naturalW != null && naturalW <= 256 && ar >= 0.7 && ar <= 1.4;
      if (isInlineIcon) {
        final iconSize = _typo.fontSize * 0.8;
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Image.memory(
            bytes,
            width: iconSize,
            height: iconSize,
            cacheWidth: (iconSize * dpr).round(),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            color: isDark ? Colors.white : null,
            colorBlendMode: isDark ? BlendMode.difference : null,
          ),
        );
      }
      return Flexible(
        child: Image.memory(
          bytes,
          width: contentWidth,
          cacheWidth: (contentWidth * dpr).round(),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          color: isDark ? Colors.white : null,
          colorBlendMode: isDark ? BlendMode.difference : null,
        ),
      );
    }
    if (block is DividerBlock) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Divider(height: 1),
      );
    }
    return const SizedBox.shrink();
  }

  // ---------------- 常驻 HUD（时间 / 页码 / 进度） ----------------

  Widget _buildHud(bool isDark) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        SettingsService(),
        ReaderOverrideService(),
      ]),
      builder: (context, _) {
        if (!ReaderOverrideService().effectiveShowHudBook(widget.task.bookId)) {
          return const SizedBox.shrink();
        }
        return _buildHudContent(isDark);
      },
    );
  }

  Widget _buildHudContent(bool isDark) {
    final color = (isDark ? Colors.white : Colors.black).withValues(
      alpha: 0.45,
    );
    final style = TextStyle(fontSize: AppTheme.fontCaption, color: color);
    final hPad = _typo.padding; // 左右边距
    final vPad = _typo.verticalPadding; // 上下边距
    // HUD 上下跟随垂直边距，并比正文留 20px 间距，避免压到首行/末行。
    // vPad < 20 时（上下边距调小）-20 会进入安全区：顶部状态栏已隐藏、本就有
    // 空区，clamp≥0 贴安全区即可；底部手势导航条是半透明浮层会向上盖住一段，
    // clamp≥8 让 HUD 抬高避开手势条。
    final hudInsetTop = (vPad - 20).clamp(0.0, vPad);
    final hudInsetBottom = (vPad - 20).clamp(8.0, vPad);
    final top = MediaQuery.paddingOf(context).top + hudInsetTop;
    final bottom = MediaQuery.paddingOf(context).bottom + hudInsetBottom;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: top,
            left: hPad,
            child: _ClockText(style: style),
          ),
          Positioned(
            top: top,
            right: hPad,
            child: ValueListenableBuilder<int>(
              valueListenable: _currentPageNotifier,
              builder: (_, p, _) {
                final total = _isImageMode
                    ? _imageBlockIndices.length
                    : _displayTotalPages;
                return Text(total > 0 ? '${p + 1}/$total' : '', style: style);
              },
            ),
          ),
          Positioned(
            bottom: bottom,
            left: hPad,
            right: hPad,
            child: Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _currentPageNotifier,
                    builder: (_, _, _) {
                      return Text(
                        _currentChapterTitle(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      );
                    },
                  ),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: _currentPageNotifier,
                  builder: (_, p, _) {
                    final total = _isImageMode
                        ? _imageBlockIndices.length
                        : _displayTotalPages;
                    if (total <= 0) return const SizedBox.shrink();
                    final pct = ((p + 1) / total * 100)
                        .clamp(0, 100)
                        .toStringAsFixed(0);
                    return Text('$pct%', style: style);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 控制层 ----------------

  Widget _buildControls(bool isDark, Color textColor) {
    final barColor = isDark
        ? Colors.black.withValues(alpha: 0.55)
        : Colors.white.withValues(alpha: 0.92);
    final iconColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !_showControls,
        child: Column(
          children: [
            // 顶部栏
            Container(
              color: barColor,
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.arrow_back_rounded, color: iconColor),
                      onPressed: () => Navigator.maybePop(context),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              fontWeight: FontWeight.w600,
                              color: iconColor,
                            ),
                          ),
                          if (_content != null)
                            Text(
                              _currentChapterTitle(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: AppTheme.fontCaption, color: iconColor),
                            ),
                        ],
                      ),
                    ),
                    // 功能图标：搜索 / 刷新 / 书签 / 朗读 / 亮度 / 日夜 / 编辑
                    IconButton(
                      tooltip: '搜索本书',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.search_rounded, size: 20, color: iconColor),
                      onPressed: _showBookSearch,
                    ),
                    IconButton(
                      tooltip: '刷新本章',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.refresh_rounded, size: 20, color: iconColor),
                      onPressed: _refreshCurrentChapter,
                    ),
                    IconButton(
                      tooltip: '书签',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.bookmark_border_rounded, size: 20, color: iconColor),
                      // 🔴 原来接的是 `_showBookmarks`（**只开面板、不添加**）✗，
                      // 而真正"加书签"的 `_toggleBookmark`（:2674 附近）**全仓库无任何
                      // 调用点** ✓ → 于是：点书签图标 → 空态面板 → 面板文案让你
                      // "点击顶部书签图标收藏当前页" → 又回到空态面板 ✗✗
                      // **用户永远无法添加书签** ✓（analyze 也一直报
                      // "The declaration '_toggleBookmark' isn't referenced" ✓）。
                      // `_toggleBookmark` 内部已自带"有书签则开面板"的分支 ✓，
                      // 所以直接接它即可，与空态文案的行为一致 ✓
                      onPressed: _toggleBookmark,
                    ),
                    IconButton(
                      tooltip: '朗读',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.record_voice_over_outlined, size: 20, color: iconColor),
                      onPressed: _toggleTts,
                    ),
                    IconButton(
                      tooltip: '亮度',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.brightness_6_rounded, size: 20, color: iconColor),
                      onPressed: _showBrightnessSheet,
                    ),
                    IconButton(
                      // ✗ 原来读 static `_ReaderDarkOverride.value`（跨书残留）；
                      // ✓ 现在读本阅读页实例的 `_darkOverride` ✓
                      tooltip: _darkOverride == 2 ? '切换白天' : '切换夜间',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        _darkOverride == 2
                            ? Icons.light_mode_outlined
                            : Icons.dark_mode_outlined,
                        size: 20,
                        color: iconColor,
                      ),
                      onPressed: _toggleDayNight,
                    ),
                    IconButton(
                      tooltip: '编辑（划线与笔记）',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.edit_outlined, size: 20, color: iconColor),
                      onPressed: _showEditPlaceholder,
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                child: const SizedBox.expand(),
              ),
            ),
            // 底部栏
            Container(
              color: barColor,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: _chapterStarts.isNotEmpty
                              ? () => _goChapter(_currentChapterIndex() - 1)
                              : null,
                          child: Icon(Icons.chevron_left, color: iconColor),
                        ),
                        Text(
                          _indicatorText(),
                          style: TextStyle(fontSize: AppTheme.fontFootnote, color: iconColor),
                        ),
                        TextButton(
                          onPressed: _chapterStarts.isNotEmpty
                              ? () => _goChapter(_currentChapterIndex() + 1)
                              : null,
                          child: Icon(Icons.chevron_right, color: iconColor),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // 左组：图片/文本 + 排版
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // PDF（懒加载）强制进图片模式，故切换按钮对 PDF 始终可用；
                            // 其余格式沿用 >=10 启发式（仅图片书显示）。
                            if (_imageBlockIndices.length >= 10 ||
                                _content?.imageLoader != null)
                              TextButton(
                                onPressed: _toggleImageMode,
                                child: Icon(
                                  _isImageMode
                                      ? Icons.article_rounded
                                      : Icons.image_rounded,
                                  color: iconColor,
                                ),
                              ),
                            if (!_isImageMode)
                              TextButton(
                                onPressed: _showTypoSheet,
                                child: Icon(
                                  Icons.text_fields_rounded,
                                  color: iconColor,
                                ),
                              ),
                            // 听书：cmbok 原版没有，按需求补的。
                            // 走原生 tts_engine（系统 AVSpeechSynthesizer），零插件。
                            if (!_isImageMode)
                              TextButton(
                                onPressed: _toggleTts,
                                child: Icon(
                                  _tts.isSpeaking.value
                                      ? Icons.pause_circle_outline_rounded
                                      : (_tts.isPaused.value
                                          ? Icons.play_circle_outline_rounded
                                          : Icons.headphones_rounded),
                                  color: _tts.isSpeaking.value
                                      ? JellyTheme.accent
                                      : iconColor,
                                ),
                              ),
                          ],
                        ),
                        // 中间：番茄钟
                        const PomodoroButton(),
                        // 右组：设置 + 目录
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              onPressed: _showReaderSettingsSheet,
                              child: Icon(
                                Icons.settings_rounded,
                                color: iconColor,
                              ),
                            ),
                            TextButton(
                              onPressed: _showToc,
                              child: Icon(
                                Icons.menu_book_rounded,
                                color: iconColor,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _currentChapterIndex() {
    if (_isImageMode) {
      if (_imageBlockIndices.isEmpty) return 0;
      final idx = _currentImageIndex.clamp(0, _imageBlockIndices.length - 1);
      return _chapterIndexForBlock(_imageBlockIndices[idx]);
    }
    if (_pages.isEmpty) return 0;
    final idx = _currentPage.clamp(0, _pages.length - 1);
    return _chapterIndexForBlock(_pages[idx].firstBlockIndex);
  }

  int _chapterIndexForBlock(int blockIndex) {
    final starts = _chapterStarts;
    if (starts.isEmpty) return 0;
    var ans = 0;
    for (var i = 0; i < starts.length; i++) {
      if (starts[i] <= blockIndex) {
        ans = i;
      } else {
        break;
      }
    }
    return ans;
  }

  String _currentChapterTitle() {
    final ci = _currentChapterIndex();
    final chapters = _content?.chapters ?? const [];
    if (ci < chapters.length) return chapters[ci].title;
    return '';
  }

  // ============================================================
  // 听书（TTS）
  // ============================================================
  //
  // cmbok 本身没有朗读功能，这里是按需求补的。
  // 引擎走 iOS 原生 `tts_engine` channel（系统 AVSpeechSynthesizer），
  // **不引任何插件** —— 见 `reading/services/tts_service.dart` 的说明。

  final _tts = TtsService.instance;

  /// 把当前章的所有文本块拼成朗读文本
  String _currentChapterText() {
    final ci = _currentChapterIndex();
    final chapters = _content?.chapters ?? const [];
    if (ci < 0 || ci >= chapters.length) return '';
    final buf = StringBuffer();
    for (final b in chapters[ci].blocks) {
      if (b is ParagraphBlock) {
        buf.writeln(b.text);
      } else if (b is HeadingBlock) {
        buf.writeln(b.text);
      }
    }
    return buf.toString();
  }

  /// 点听书按钮：正在念就暂停/继续，没在念就从当前章开头念
  Future<void> _toggleTts() async {
    // 🔴 下面两处 `await`（暂停 / 继续朗读 ✓）之后的 `setState` 都**没有**
    // `mounted` 检查 ✗ → 页面在这段窗口里被销毁就抛
    // `setState() called after dispose()` ✓。
    // 这个场景**真会被触发** ✓：暂停/继续之间用户按返回键离开阅读器 ✓
    //（不是理论情况 ✗）。两处一起补 ✓
    if (_tts.isSpeaking.value) {
      await _tts.pause();
      if (!mounted) return;
      setState(() {});
      return;
    }
    if (_tts.isPaused.value) {
      await _tts.resume();
      if (!mounted) return;
      setState(() {});
      return;
    }

    final text = _currentChapterText();
    if (text.trim().isEmpty) {
      BookReaderPage._toast(context, '这一章没有可朗读的内容');
      return;
    }

    // 念完本章 → 自动跳下一章接着念
    _tts.onFinished = () {
      if (!mounted) return;
      final next = _currentChapterIndex() + 1;
      if (next < _chapterStarts.length) {
        _goChapter(next);
        // 等切章完成再取文本
        Future.delayed(const Duration(milliseconds: 400), () {
          if (!mounted) return;
          final t = _currentChapterText();
          if (t.trim().isNotEmpty) _tts.speak(t);
        });
      }
    };

    await _tts.speak(text);
    setState(() {});
  }

  String _indicatorText() {
    if (_isImageMode) {
      if (_imageBlockIndices.isEmpty) return '';
      return '${_currentImageIndex + 1}/${_imageBlockIndices.length} 图';
    }
    if (_pages.isEmpty) return '';
    if (_isDoublePage) {
      final left = _currentPage + 1;
      final right = _spreadRightPage(_currentSpread);
      final hasRight = right < _pages.length;
      return hasRight
          ? '$left-${right + 1}/${_pages.length} 页'
          : '$left/${_pages.length} 页';
    }
    return '${_currentPage + 1}/${_pages.length} 页';
  }

  // ---------------- 顶栏功能（搜索 / 刷新 / 书签 / 亮度 / 日夜 / 编辑） ----------------

  /// 顶栏搜索：全书全文搜索（本地书已全部解析，直接遍历章节文本块）
  Future<void> _showBookSearch() async {
    final content = _content;
    if (content == null || _pages.isEmpty) {
      BookReaderPage._toast(context, '内容尚未加载完成');
      return;
    }
    final dark = _readerIsDark;
    final fg = dark ? Colors.white : JellyTheme.textPrimaryLight;
    final bgTop = dark
        ? Colors.black.withValues(alpha: 0.96)
        : Colors.white.withValues(alpha: 0.98);
    final controller = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          List<_SearchHit> hits = const [];
          bool searched = false;
          String keyword = '';
          return Container(
            height: MediaQuery.of(context).size.height * 0.72,
            decoration: BoxDecoration(
              color: bgTop,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            ),
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 8),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      Icon(Icons.search_rounded, size: 20, color: fg),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: controller,
                          autofocus: true,
                          style: TextStyle(color: fg),
                          decoration: InputDecoration(
                            hintText: '输入关键词搜索全书',
                            hintStyle: TextStyle(color: fg.withValues(alpha: 0.4)),
                            isDense: true,
                            border: InputBorder.none,
                          ),
                          textInputAction: TextInputAction.search,
                          onSubmitted: (v) {
                            keyword = v.trim();
                            if (keyword.isEmpty) return;
                            hits = _searchFullBook(keyword);
                            searched = true;
                            setSheet(() {});
                          },
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.close_rounded, size: 18, color: fg.withValues(alpha: 0.6)),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: fg.withValues(alpha: 0.1)),
                if (!searched)
                  Expanded(
                    child: Center(
                      child: Text(
                        '输入关键词，回车搜索全书',
                        style: TextStyle(fontSize: 13, color: fg.withValues(alpha: 0.5)),
                      ),
                    ),
                  )
                else if (hits.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text('没有找到「$keyword」相关内容',
                          style: TextStyle(fontSize: 13, color: fg.withValues(alpha: 0.5))),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: hits.length,
                      itemBuilder: (context, i) {
                        final h = hits[i];
                        return InkWell(
                          onTap: () {
                            Navigator.pop(context);
                            _jumpToSearchHit(h.blockIndex);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  h.chapterTitle.isEmpty ? '第 ${h.chapterIndex + 1} 章' : h.chapterTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: JellyTheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  h.preview,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13, color: fg.withValues(alpha: 0.85)),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    hits.isEmpty ? '' : '共 ${hits.length} 处匹配',
                    style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.5)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 遍历全部章节文本块找关键词（忽略大小写，最多 300 条）。
  /// 全局 blockIndex = 章节起始块索引 + 章内序号（章节标题块占 1）。
  List<_SearchHit> _searchFullBook(String keyword) {
    final content = _content;
    if (content == null) return const [];
    final lower = keyword.toLowerCase();
    final starts = content.chapterStarts;
    final out = <_SearchHit>[];
    for (var ci = 0; ci < content.chapters.length; ci++) {
      final ch = content.chapters[ci];
      final base = starts[ci];
      final headOffset = ch.title.isNotEmpty ? 1 : 0;
      for (var j = 0; j < ch.blocks.length; j++) {
        final b = ch.blocks[j];
        final text = (b is ParagraphBlock)
            ? b.text
            : (b is HeadingBlock ? b.text : '');
        if (text.isEmpty || !text.toLowerCase().contains(lower)) continue;
        // 摘录关键词前后片段
        final idx = text.toLowerCase().indexOf(lower);
        final start = (idx - 12).clamp(0, text.length);
        final end = (idx + keyword.length + 24).clamp(0, text.length);
        var preview = text.substring(start, end).replaceAll('\n', ' ');
        if (start > 0) preview = '…$preview';
        if (end < text.length) preview = '$preview…';
        out.add(_SearchHit(
          chapterIndex: ci,
          chapterTitle: ch.title,
          preview: preview,
          blockIndex: base + headOffset + j,
        ));
        if (out.length >= 300) return out;
      }
    }
    return out;
  }

  /// 搜索命中跳转：窗口内直接定位，窗口外先补排（补排完成内部会定位）
  void _jumpToSearchHit(int blockIndex) {
    setState(() => _showControls = false);
    if (_ongoingPaginator != null && blockIndex > _paginatedBlockCount) {
      _extendToBlock(blockIndex);
      return;
    }
    _goChapterJump(blockIndex);
  }

  /// 顶栏刷新：清掉分页缓存重排当前章
  void _refreshCurrentChapter() {
    final ci = _currentChapterIndex();
    // 清掉全部分页缓存（缓存 key 由屏宽/屏高决定，参数没变会命中缓存，
    // 必须清缓存才真正重排）
    BookPageCacheService.instance.clear();
    setState(() {});
    _goChapter(ci);
    BookReaderPage._toast(context, '已重新排版');
  }

  // ---- 本地书签（轻量 prefs：taskId -> [{chapterTitle, chapterIndex, blockIndex}]） ----
  static const _bookmarkPrefsKey = 'book_reader_bookmarks_v1';

  Future<Map<String, List<Map<String, dynamic>>>> _loadAllBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_bookmarkPrefsKey);
      if (raw == null || raw.isEmpty) return {};
      final dec = jsonDecode(raw) as Map<String, dynamic>;
      return dec.map((k, v) => MapEntry(
            k,
            (v as List).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
          ));
    } catch (_) {
      return {};
    }
  }

  Future<void> _persistBookmarks(Map<String, List<Map<String, dynamic>>> all) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_bookmarkPrefsKey, jsonEncode(all));
    } catch (_) {}
  }

  /// 书签面板：列出本书书签可跳转，长按删除，空态引导加书签
  Future<void> _showBookmarks() async {
    final dark = _readerIsDark;
    final fg = dark ? Colors.white : JellyTheme.textPrimaryLight;
    final bgTop = dark
        ? Colors.black.withValues(alpha: 0.96)
        : Colors.white.withValues(alpha: 0.98);
    final all = await _loadAllBookmarks();
    final bookId = widget.task.bookId;
    final list = List<Map<String, dynamic>>.from(all[bookId] ?? const []);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          return Container(
            decoration: BoxDecoration(
              color: bgTop,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            ),
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
                  child: Row(
                    children: [
                      Icon(Icons.bookmark_rounded, size: 18, color: fg),
                      const SizedBox(width: 8),
                      Text('书签（${list.length}）',
                          style: TextStyle(fontSize: AppTheme.fontSubhead, fontWeight: FontWeight.w700, color: fg)),
                      const Spacer(),
                      if (list.isNotEmpty)
                        TextButton(
                          onPressed: () async {
                            all[bookId] = [];
                            await _persistBookmarks(all);
                            setSheet(() => list.clear());
                            BookReaderPage._toast(context, '已清除全部书签');
                          },
                          child: Text('清除全部',
                              style: TextStyle(fontSize: 13, color: JellyTheme.primary)),
                        ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.close_rounded, size: 18, color: fg.withValues(alpha: 0.6)),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: fg.withValues(alpha: 0.1)),
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      children: [
                        Icon(Icons.bookmark_border_rounded, size: 40, color: fg.withValues(alpha: 0.3)),
                        const SizedBox(height: 10),
                        Text('还没有书签，点击顶部书签图标收藏当前页',
                            style: TextStyle(fontSize: 13, color: fg.withValues(alpha: 0.5))),
                      ],
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final b = list[i];
                        return ListTile(
                          dense: true,
                          leading: Icon(Icons.bookmark_rounded, size: 18, color: JellyTheme.primary),
                          title: Text(
                            (b['chapterTitle'] as String?)?.isNotEmpty == true
                                ? b['chapterTitle'] as String
                                // 🔴 Dart 里 `??` 的优先级**低于** `+` ✓，所以原来写的
                            // `?.toInt() ?? 0 + 1` 实际等价于 `?.toInt() ?? (0 + 1)`
                            // → 只有"字段缺失"才得 1 ✗，而**真正的章号 0**（第一项 ✓，
                            // 0-based ✓）会原样显示 → **"第 0 章"** ✓
                            //（缺字段时又变成"第 1 章" ✓，两种都错 ✗）。
                            // 加括号才是本意：**(章号 或 0) + 1** → 1-based 显示 ✓
                            : '第 ${((b['chapterIndex'] as num?)?.toInt() ?? 0) + 1} 章',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, color: fg),
                          ),
                          trailing: IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: Icon(Icons.delete_outline_rounded, size: 18, color: fg.withValues(alpha: 0.5)),
                            onPressed: () async {
                              list.removeAt(i);
                              all[bookId] = list;
                              await _persistBookmarks(all);
                              setSheet(() {});
                            },
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            final block = (b['blockIndex'] as num?)?.toInt();
                            if (block != null) _jumpToSearchHit(block);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 顶栏书签图标：有书签面板可点；无书签时点击=收藏当前页并提示
  Future<void> _toggleBookmark() async {
    final all = await _loadAllBookmarks();
    final bookId = widget.task.bookId;
    final list = List<Map<String, dynamic>>.from(all[bookId] ?? const []);
    if (list.isNotEmpty) {
      _showBookmarks();
      return;
    }
    final ci = _currentChapterIndex();
    final chapters = _content?.chapters ?? const [];
    final title = ci < chapters.length ? chapters[ci].title : '';
    final blockIndex = _currentBlockIndexForPage(_currentPage);
    all[bookId] = [
      ...list,
      {'chapterTitle': title, 'chapterIndex': ci, 'blockIndex': blockIndex},
    ];
    await _persistBookmarks(all);
    setState(() {});
    BookReaderPage._toast(context, '已添加书签：${title.isEmpty ? '第 ${ci + 1} 章' : title}');
    _showBookmarks();
  }

  int _currentBlockIndexForPage(int page) {
    if (page < 0 || page >= _pages.length) return 0;
    return _pages[page].firstBlockIndex;
  }

  /// 顶栏日夜切换：夜间 ↔ 白天（首次点击进入夜间，再点切回白天）
  /// ✗ 原来写的是 static `_ReaderDarkOverride.value`：一旦点过就永久留在
  ///   1/2，换书也带着走，「跟随全局暗色」再也不会生效 ✗。
  /// ✓ 现在改的是本页实例字段 `_darkOverride`：页面销毁即归零，
  ///   下次进阅读器/换一本书重新回到 0=跟随全局 ✓。
  void _toggleDayNight() {
    setState(() {
      _darkOverride = _darkOverride == 2 ? 1 : 2;
    });
  }

  /// 顶栏亮度：底部滑杆调系统屏幕亮度（screen_brightness）
  Future<void> _showBrightnessSheet() async {
    final dark = _readerIsDark;
    final fg = dark ? Colors.white : JellyTheme.textPrimaryLight;
    final bgTop = dark
        ? Colors.black.withValues(alpha: 0.96)
        : Colors.white.withValues(alpha: 0.98);
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
              borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            ),
            padding: EdgeInsets.only(top: 14, bottom: MediaQuery.of(context).padding.bottom + 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.brightness_6_rounded, size: 18, color: fg),
                    const SizedBox(width: 8),
                    Text('亮度',
                        style: TextStyle(fontSize: AppTheme.fontSubhead, fontWeight: FontWeight.w700, color: fg)),
                  ],
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      Icon(Icons.brightness_low_rounded, size: 18, color: fg.withValues(alpha: 0.5)),
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
                      Icon(Icons.brightness_high_rounded, size: 18, color: fg.withValues(alpha: 0.5)),
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

  /// 顶栏编辑（划线与笔记）—— **本轮接上真页面** ✓✓（不再是一句占位 toast ✗）
  ///
  /// ✅ 原来这里只弹「划线编辑待接入（本地图书）」✗；而**笔记页面本来就有** ✓
  ///   （`BookNotesPage` ✓ —— 本轮把它从私有 `_BookNotesPage` 改成公开 ✓，
  ///    5 处引用一次改全 ✓，所以这里能直接复用 ✓）。
  /// ⚠️ **如实说明** ✓（不夸大 ✗）：本地图书**正文里长按选中 → 划线/批注**仍**需要单独开发** ✗
  ///   （本页正文是分页渲染的文本块 / PDF 图片 ✓，要另做一套"文字选择 + 块内偏移映射" ✓）。
  ///   但**查看与管理已有笔记**现在是真的 ✓✓ —— 包括在**书源阅读器**里划的线 ✓（同一个
  ///   `ReaderNotesService` ✓ 同一份存储 ✓）。
  void _showEditPlaceholder() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const BookNotesPage()),
    );
  }

  // ---------------- 目录 ----------------

  void _showToc() {
    final chapters = _content?.chapters ?? const [];
    if (chapters.isEmpty) return;
    final drawerWidth = MediaQuery.sizeOf(context).width * 0.75;
    final currentIndex = _currentChapterIndex();
    final itemScrollController = ItemScrollController();
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '目录',
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (ctx, anim, secondaryAnim) {
        final isDark = _readerIsDark;
        final textColor = isDark
            ? Colors.white.withValues(alpha: 0.92)
            : JellyTheme.textPrimaryLight;
        final subColor = isDark
            ? Colors.white.withValues(alpha: 0.5)
            : JellyTheme.textSecondary;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (itemScrollController.isAttached) {
            itemScrollController.jumpTo(index: currentIndex);
          }
        });
        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: drawerWidth,
              height: double.infinity,
              decoration: BoxDecoration(
                color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  bottomLeft: Radius.circular(20),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 30,
                    offset: const Offset(-4, 0),
                  ),
                ],
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 8, 12),
                      child: Row(
                        children: [
                          const Text(
                            '目录',
                            style: TextStyle(
                              fontSize: AppTheme.fontTitle3,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: JellyTheme.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${chapters.length} 章',
                              style: TextStyle(
                                fontSize: AppTheme.fontCaption,
                                color: JellyTheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: Icon(
                              Icons.close_rounded,
                              size: 20,
                              color: subColor,
                            ),
                            onPressed: () => Navigator.pop(ctx),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: subColor.withValues(alpha: 0.15)),
                    Expanded(
                      child: ScrollablePositionedList.builder(
                        itemScrollController: itemScrollController,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: chapters.length,
                        itemBuilder: (ctx, i) {
                          final cur = i == currentIndex;
                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () {
                                Navigator.pop(ctx);
                                _goChapter(i);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 12,
                                ),
                                decoration: cur
                                    ? BoxDecoration(
                                        color: JellyTheme.primary.withValues(
                                          alpha: 0.1,
                                        ),
                                        border: Border(
                                          left: BorderSide(
                                            color: JellyTheme.primary,
                                            width: 3,
                                          ),
                                        ),
                                      )
                                    : null,
                                child: Text(
                                  chapters[i].title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppTheme.fontBody,
                                    color: cur ? JellyTheme.primary : textColor,
                                    fontWeight: cur
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
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
        );
      },
      transitionBuilder: (ctx, anim, secondaryAnim, child) {
        final offset = Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic));
        return SlideTransition(position: offset, child: child);
      },
    );
  }

  // ---------------- 阅读设置 ----------------

  /// 阅读设置弹层：独立设置开关 + 图书阅读模式。
  /// 草稿式，点「确认」一次性写入（独立设置开启写 per-item 覆盖，否则写全局）。
  /// 排版（字号/行距/边距）由单独的「排版」按钮负责，不在本弹层内。
  void _showReaderSettingsSheet() {
    final o = ReaderOverrideService();
    final bookId = widget.task.bookId;
    bool draftIndependent = o.isIndependentBook(bookId);
    BookReadingMode draftMode = o.effectiveBookMode(bookId);
    bool draftReverseTap = o.effectiveReverseTapBook(bookId);
    bool draftDoublePage = o.effectiveDoublePageBook(bookId);
    bool draftShowHud = o.effectiveShowHudBook(bookId);
    bool draftVolumeKey = o.effectiveVolumeKeyTurnBook(bookId);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => kbSheet(StatefulBuilder(
        builder: (ctx, setSheet) {
          final isDark = Theme.of(ctx).brightness == Brightness.dark;
          final textColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          '阅读设置',
                          style: TextStyle(
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '独立设置',
                          style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            color: draftIndependent
                                ? JellyTheme.primary
                                : (isDark
                                      ? Colors.white70
                                      : JellyTheme.textSecondary),
                          ),
                        ),
                        Switch(
                          value: draftIndependent,
                          activeColor: JellyTheme.primary,
                          onChanged: (v) =>
                              setSheet(() => draftIndependent = v),
                        ),
                      ],
                    ),
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: JellyTheme.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        draftIndependent
                            ? '本书使用独立设置（阅读模式与排版）'
                            : '当前为全局设置，修改影响所有图书',
                        style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: draftIndependent
                              ? JellyTheme.primary
                              : (isDark
                                    ? Colors.white54
                                    : JellyTheme.textSecondary),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Text(
                          '阅读模式',
                          style: TextStyle(fontSize: AppTheme.fontBody, color: textColor),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Row(
                            children: [
                              _bookModeChip(
                                '左右',
                                draftMode == BookReadingMode.pageTurn,
                                isDark,
                                () => setSheet(
                                  () => draftMode = BookReadingMode.pageTurn,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _bookModeChip(
                                '上下',
                                draftMode == BookReadingMode.vertical,
                                isDark,
                                () => setSheet(
                                  () => draftMode = BookReadingMode.vertical,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _bookModeChip(
                                '仿真',
                                draftMode == BookReadingMode.simulation,
                                isDark,
                                () => setSheet(
                                  () => draftMode = BookReadingMode.simulation,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _bookModeChip(
                                '覆盖',
                                draftMode == BookReadingMode.cover,
                                isDark,
                                () => setSheet(
                                  () => draftMode = BookReadingMode.cover,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _bookModeChip(
                                '无动画',
                                draftMode == BookReadingMode.none,
                                isDark,
                                () => setSheet(
                                  () => draftMode = BookReadingMode.none,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          '翻页反转',
                          style: TextStyle(fontSize: AppTheme.fontBody, color: textColor),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '左点下一页、右点上一页',
                            style: TextStyle(
                              fontSize: AppTheme.fontFootnote,
                              color: isDark
                                  ? Colors.white54
                                  : JellyTheme.textSecondary,
                            ),
                          ),
                        ),
                        Switch(
                          value: draftReverseTap,
                          activeColor: JellyTheme.primary,
                          onChanged: (v) => setSheet(() => draftReverseTap = v),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Text(
                          '双页模式',
                          style: TextStyle(fontSize: AppTheme.fontBody, color: textColor),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '横屏左右并排（上下模式除外）',
                            style: TextStyle(
                              fontSize: AppTheme.fontFootnote,
                              color: isDark
                                  ? Colors.white54
                                  : JellyTheme.textSecondary,
                            ),
                          ),
                        ),
                        Switch(
                          value: draftDoublePage,
                          activeColor: JellyTheme.primary,
                          onChanged: (v) => setSheet(() => draftDoublePage = v),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Text(
                          '信息栏',
                          style: TextStyle(fontSize: AppTheme.fontBody, color: textColor),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '显示时间、页码、进度',
                            style: TextStyle(
                              fontSize: AppTheme.fontFootnote,
                              color: isDark
                                  ? Colors.white54
                                  : JellyTheme.textSecondary,
                            ),
                          ),
                        ),
                        Switch(
                          value: draftShowHud,
                          activeColor: JellyTheme.primary,
                          onChanged: (v) => setSheet(() => draftShowHud = v),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Text(
                          '音量键翻页',
                          style: TextStyle(fontSize: AppTheme.fontBody, color: textColor),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '按音量上/下键翻页（会接管音量键）',
                            style: TextStyle(
                              fontSize: AppTheme.fontFootnote,
                              color: isDark
                                  ? Colors.white54
                                  : JellyTheme.textSecondary,
                            ),
                          ),
                        ),
                        Switch(
                          value: draftVolumeKey,
                          activeColor: JellyTheme.primary,
                          onChanged: (v) => setSheet(() => draftVolumeKey = v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('取消'),
                        ),
                        const Spacer(),
                        FilledButton(
                          onPressed: () async {
                            await o.setIndependentBook(
                              bookId,
                              draftIndependent,
                            );
                            o.setBookMode(bookId, draftMode);
                            o.setBookReverseTap(bookId, draftReverseTap);
                            o.setBookDoublePage(bookId, draftDoublePage);
                            o.setBookShowHud(bookId, draftShowHud);
                            o.setBookVolumeKeyTurn(bookId, draftVolumeKey);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                          child: const Text('确认'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      )),
    );
  }

  Widget _bookModeChip(
    String label,
    bool selected,
    bool isDark,
    VoidCallback onTap,
  ) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? JellyTheme.primary
                : (isDark
                      ? Colors.white.withValues(alpha: 0.12)
                      : Colors.black.withValues(alpha: 0.05)),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: AppTheme.fontSubhead,
              color: selected
                  ? Colors.white
                  : (isDark ? Colors.white70 : JellyTheme.textPrimaryLight),
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- 排版设置 ----------------

  void _showTypoSheet() {
    final o = ReaderOverrideService();
    final bookId = widget.task.bookId;
    // 草稿：滑块只改草稿，点「确认」才写入（独立设置开启写 per-item，否则写全局）
    double draftFontSize = o.effectiveBookFontSize(bookId);
    double draftLineHeight = o.effectiveBookLineHeight(bookId);
    double draftHPadding = o.effectiveBookHorizontalPadding(bookId);
    double draftVPadding = o.effectiveBookVerticalPadding(bookId);
    // UI 内部用 auto 哨兵统一表示 null（= 跟随阅读模式），输出时还原成 null
    final rawFont = o.effectiveBookFontFamily(bookId);
    String draftFontFamily = (rawFont == null || rawFont.isEmpty)
        ? BookFontService.autoFamily
        : rawFont;
    final fontService = BookFontService();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => kbSheet(StatefulBuilder(
        builder: (ctx, setSheet) {
          final isDark = _readerIsDark;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _typoSlider(
                      label: '字号',
                      value: draftFontSize,
                      min: SettingsService.minBookFontSize,
                      max: SettingsService.maxBookFontSize,
                      divisions:
                          ((SettingsService.maxBookFontSize -
                                      SettingsService.minBookFontSize) *
                                  2)
                              .round(),
                      display: draftFontSize.toStringAsFixed(0),
                      onChanged: (v) {
                        setSheet(() => draftFontSize = v);
                      },
                      isDark: isDark,
                    ),
                    _typoSlider(
                      label: '行距',
                      value: draftLineHeight,
                      min: SettingsService.minBookLineHeight,
                      max: SettingsService.maxBookLineHeight,
                      divisions:
                          ((SettingsService.maxBookLineHeight -
                                      SettingsService.minBookLineHeight) *
                                  10)
                              .round(),
                      display: draftLineHeight.toStringAsFixed(1),
                      onChanged: (v) {
                        setSheet(() => draftLineHeight = v);
                      },
                      isDark: isDark,
                    ),
                    _typoSlider(
                      label: '左右边距',
                      value: draftHPadding,
                      min: SettingsService.minBookHorizontalPadding,
                      max: SettingsService.maxBookHorizontalPadding,
                      divisions:
                          (SettingsService.maxBookHorizontalPadding -
                                  SettingsService.minBookHorizontalPadding)
                              .round(),
                      display: draftHPadding.toStringAsFixed(0),
                      onChanged: (v) {
                        setSheet(() => draftHPadding = v);
                      },
                      isDark: isDark,
                    ),
                    _typoSlider(
                      label: '上下边距',
                      value: draftVPadding,
                      min: SettingsService.minBookVerticalPadding,
                      max: SettingsService.maxBookVerticalPadding,
                      divisions:
                          (SettingsService.maxBookVerticalPadding -
                                  SettingsService.minBookVerticalPadding)
                              .round(),
                      display: draftVPadding.toStringAsFixed(0),
                      onChanged: (v) {
                        setSheet(() => draftVPadding = v);
                      },
                      isDark: isDark,
                    ),
                    _typoFontRow(
                      draftFamily: draftFontFamily,
                      fontService: fontService,
                      onSelect: (v) => setSheet(() => draftFontFamily = v),
                      onImport: () async {
                        // ⚠️ 原版 `importFont()` 内部弹 `file_picker`（原生插件）。
                        // 本项目硬约束"不新增原生插件"，所以改成先用**纯 Dart
                        // 文件浏览器**选文件，再把路径交给字体服务导入。
                        final paths = await pickLocalFiles(
                          ctx,
                          allowedExtensions: const {'ttf', 'otf', 'ttc'},
                          allowMultiple: false,
                        );
                        if (paths == null || paths.isEmpty) return;
                        final family =
                            await fontService.importFont(paths.first);
                        if (family != null) {
                          setSheet(() => draftFontFamily = family);
                        }
                      },
                      isDark: isDark,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('取消'),
                        ),
                        const Spacer(),
                        FilledButton(
                          onPressed: () {
                            o.setBookFontSize(bookId, draftFontSize);
                            o.setBookLineHeight(bookId, draftLineHeight);
                            o.setBookHorizontalPadding(bookId, draftHPadding);
                            o.setBookVerticalPadding(bookId, draftVPadding);
                            o.setBookFontFamily(
                              bookId,
                              draftFontFamily == BookFontService.autoFamily
                                  ? null
                                  : draftFontFamily,
                            );
                            Navigator.pop(ctx);
                          },
                          child: const Text('确认'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      )),
    );
  }

  /// 排版弹层中的字体选择行：内置(跟随模式/系统/水墨楷体) + 用户字体 + 「+」导入。
  Widget _typoFontRow({
    required String draftFamily,
    required BookFontService fontService,
    required ValueChanged<String> onSelect,
    required Future<void> Function() onImport,
    required bool isDark,
  }) {
    final entries = <(String label, String family)>[
      ('跟随模式', BookFontService.autoFamily),
      ('系统默认', BookFontService.systemFamily),
      ('水墨楷体', 'inkReadingKai'),
      for (final f in fontService.userFamilies) (f, f),
    ];
    // 同步可能缺失：当前选择既不在内置列表也不在用户字体列表
    // （如字体文件被外部删除），追加一个标记项让用户能识别并改选。
    final known = entries.map((e) => e.$2).toSet();
    if (!known.contains(draftFamily)) {
      entries.add(('$draftFamily (未注册)', draftFamily));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '字体',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in entries)
                  _typoFontChip(
                    e.$1,
                    e.$2 == draftFamily,
                    isDark,
                    () => onSelect(e.$2),
                  ),
                _typoFontChip('＋', false, isDark, onImport, isAction: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _typoFontChip(
    String label,
    bool selected,
    bool isDark,
    VoidCallback onTap, {
    bool isAction = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? JellyTheme.primary
              : (isDark
                    ? Colors.white.withValues(alpha: 0.12)
                    : Colors.black.withValues(alpha: 0.05)),
          borderRadius: BorderRadius.circular(10),
          border: isAction && !selected
              ? Border.all(
                  color: isDark ? Colors.white24 : Colors.black12,
                  width: 1,
                )
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppTheme.fontFootnote,
            color: selected
                ? Colors.white
                : (isDark ? Colors.white70 : JellyTheme.textPrimaryLight),
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _typoSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
    required bool isDark,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              activeColor: JellyTheme.primary,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              display,
              textAlign: TextAlign.end,
              style: TextStyle(
                color: JellyTheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// PDF 单页懒加载图：images 未预载时，按需经 [BookContent.imageLoader] 光栅化，
/// 拿到字节后回调父级缓存进 [BookContent.images]，下次构建直接命中缓存分支。
class _PdfPageImage extends StatefulWidget {
  final String imageKey;
  final double contentWidth;

  /// 是否按夜间反相显示。日夜覆盖已是阅读页的**实例**状态
  /// （见 `_BookReaderPageState._darkOverride`），这个子 widget 拿不到，
  /// 只能由父级把 `_readerIsDark` 显式传下来 ✓（传 null 会退回全局或写死 ✗）。
  final bool isDark;
  final Future<Uint8List> Function(String, double) loader;
  final void Function(String imageKey, Uint8List bytes) onLoaded;

  const _PdfPageImage({
    required this.imageKey,
    required this.contentWidth,
    required this.isDark,
    required this.loader,
    required this.onLoaded,
  });

  @override
  State<_PdfPageImage> createState() => _PdfPageImageState();
}

class _PdfPageImageState extends State<_PdfPageImage> {
  Uint8List? _bytes;
  Object? _error;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loading && _bytes == null && _error == null) {
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    // 按设备像素光栅化，保证清晰；contentWidth 为逻辑像素
    final dpr = MediaQuery.devicePixelRatioOf(context);
    try {
      final b = await widget.loader(widget.imageKey, widget.contentWidth * dpr);
      if (!mounted) return;
      setState(() => _bytes = b);
      widget.onLoaded(widget.imageKey, b);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // ✗ 原来读文件级 `_readerIsDark`（背后是 static 覆盖值）；
    // ✓ 现在用父级传下来的本次阅读页实例值 ✓
    final isDark = widget.isDark;
    if (_bytes != null) {
      return Image.memory(
        _bytes!,
        width: widget.contentWidth,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        color: isDark ? Colors.white : null,
        colorBlendMode: isDark ? BlendMode.difference : null,
      );
    }
    if (_error != null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Icon(Icons.broken_image_outlined, size: 40)),
      );
    }
    return const SizedBox(
      height: 200,
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

class _ClockText extends StatefulWidget {
  final TextStyle style;
  const _ClockText({required this.style});

  @override
  State<_ClockText> createState() => _ClockTextState();
}

class _ClockTextState extends State<_ClockText> {
  Timer? _timer;
  String _time = '';

  @override
  void initState() {
    super.initState();
    _update();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _update());
  }

  void _update() {
    final now = DateTime.now();
    final t =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    if (t != _time) setState(() => _time = t);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(_time, style: widget.style);
}

/// PDF 懒加载图源：把 [BookContent.imageLoader] 的按需光栅化包装成
/// [ImageProvider]，复用 Flutter 图片缓存（key=imageKey+targetWidth），
/// 使 [precacheImage] 预载与 [Image.gaplessPlayback] 平滑出图成为可能。
/// 用于图片模式（消散 / PhotoView 画廊）渲染 PDF 每页；文本模式仍走 _PdfPageImage。
class _PdfPageImageProvider extends ImageProvider<_PdfPageImageProvider> {
  final String imageKey;
  final double targetWidth; // 物理像素
  final Future<Uint8List> Function(String, double) loader;

  const _PdfPageImageProvider(this.imageKey, this.targetWidth, this.loader);

  @override
  Future<_PdfPageImageProvider> obtainKey(ImageConfiguration _) async => this;

  @override
  ImageStreamCompleter loadImage(
    _PdfPageImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
    );
  }

  Future<ui.Codec> _loadAsync(
    _PdfPageImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await loader(key.imageKey, key.targetWidth);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is _PdfPageImageProvider &&
      other.imageKey == imageKey &&
      other.targetWidth == targetWidth;

  @override
  int get hashCode => Object.hash(imageKey, targetWidth);
}
