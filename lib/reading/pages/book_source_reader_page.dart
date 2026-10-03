import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import '../models/book_content.dart';
import '../models/reading_settings.dart';
import '../services/book_paginator.dart';
import '../services/book_source_service.dart';
import '../services/reader_notes_service.dart';
import '../services/tts_service.dart';
import '../widgets/book_page_curl.dart';
import '../widgets/pomodoro_button.dart';
import 'tts_engine_page.dart';
import '../../common/theme.dart';
import '../theme/jelly_theme.dart';
import '../../widgets/app_image_cache.dart';

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
  });

  final BookSource source;
  final String bookName;
  final String author;
  final List<BookSourceChapter> chapters;
  final int initialIndex;

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
  /// 阅读底色索引（见 [_bgs]：0 白 / 1 米黄 / 2 护眼绿 / 3 夜间）。
  ///
  /// ⚠️ 默认值**按全局明暗取**：全局是深色就默认"夜间"，浅色就默认"白"。
  /// 原来写死 `0`（白），于是"暗色模式对书源阅读器完全无效"。
  /// 用户在「主题」tab 里显式选过的值会由 `_restorePrefs()` 覆盖回来
  ///（`reading.bgIndex`），所以这里只影响**没选过**的用户。
  int _bgIndex = AppBrightness.isLight.value ? 0 : 3;
  bool _showBar = true;

  // ── 排版（截图 IMG_8092~8095 全文可调）───────────────────────
  //
  // ⚠️ 我上一版说"段落间距/字间距/字重/边距需要渲染层改造"是**错的**。
  // Flutter 的 TextStyle 原生支持：
  //   letterSpacing  → 字间距
  //   fontWeight     → 字重
  //   height         → 行距
  // 段落间距/边距用 Padding 即可。所以这些**都能真调**。
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
  int _underlineStyle = 0;    // 0无 1短虚线 2长虚线 3实线 4波浪
  double _underlineAlpha = 0.35;
  double _underlineWidth = 1.2;
  double _underlineGap = 3.0;
  bool _underlineFull = false; // 满行底线
  /// 自定义字色（null = 跟随主题）
  Color? _fgOverride;
  /// 已保存的排版预设名
  final List<String> _savedPresets = [];

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
  /// 当前页下标（分页模式下用，与 _index 章节下标区分）
  int _pageIndex = 0;
  /// 分页进行中
  bool _paginating = false;
  /// 分页用的视口尺寸（LayoutBuilder 给出）
  Size _viewport = Size.zero;

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
  /// 番茄钟浮层是否显示
  bool _showPomodoro = false;

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
  /// 本章书签：段落下标 → 颜色
  final Map<int, Color> _bookmarks = {};
  /// 「不再提示」—— 下次直接用上次选的颜色
  bool _bookmarkNoAsk = false;
  int _bookmarkLastColor = 0;

  /// 当前背景下的前景色（正文/图标用）。
  /// 「主题」tab 选了自定义字色就以它为准。
  Color get _fg => _fgOverride ?? _bgs[_bgIndex][1];
  /// 当前背景下的次要前景色（说明文字用）
  Color get _fgMuted => _fg.withValues(alpha: 0.6);

  static const _bgs = <List<Color>>[
    [Color(0xFFFFFFFF), Color(0xFF1A1A1A)], // 白
    [Color(0xFFF5EFE0), Color(0xFF3A3226)], // 米黄
    [Color(0xFFC7E0C0), Color(0xFF23301F)], // 护眼绿
    [Color(0xFF2B2B2B), Color(0xFFB8B8B8)], // 夜间
  ];

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

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    // ⚠️ 必须恢复息屏：否则用户离开阅读器后屏幕永远不灭（严重耗电）
    if (_awakeRequested) _tts.allowSleep();
    _sleepTimer?.cancel();
    _pageCtrl.dispose();
    super.dispose();
  }

  // ── 偏好与进度 ──────────────────────────────────────────────

  String get _progressKey =>
      'bsr.progress.${widget.source.id}.${widget.bookName}';

  Future<void> _restorePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      final fs = p.getDouble('reading.fontSize');
      final lh = p.getDouble('reading.lineHeight');
      final bg = p.getInt('reading.bgIndex');
      // 阅读设置（截图 IMG_71a10）
      final rsRaw = p.getString('reading.settings');
      // 只在用户**没有从详情页指定章节**时才恢复进度，
      // 否则点"第 5 章"却被跳到上次读到的地方就很怪。
      final savedIdx = p.getInt(_progressKey);
      if (!mounted) return;
      setState(() {
        if (fs != null && fs >= 12 && fs <= 30) _fontSize = fs;
        if (lh != null && lh >= 1.2 && lh <= 3.0) _lineHeight = lh;
        if (bg != null && bg >= 0 && bg < _bgs.length) _bgIndex = bg;
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
      await p.setDouble('reading.fontSize', _fontSize);
      await p.setDouble('reading.lineHeight', _lineHeight);
      await p.setInt('reading.bgIndex', _bgIndex);
      await p.setString('reading.settings', jsonEncode(_rs.toJson()));
    } catch (_) {}
  }

  Future<void> _saveProgress() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_progressKey, _index);
    } catch (_) {}
  }

  // ── 章节加载 ────────────────────────────────────────────────

  Future<void> _loadChapter(int i, {bool prefetchOnly = false}) async {
    if (i < 0 || i >= widget.chapters.length) return;

    // 命中缓存：直接切换
    if (_cache.containsKey(i)) {
      if (!prefetchOnly) {
        setState(() {
          _paragraphs = _cache[i]!;
          _loading = false;
          _error = null;
        });
      }
      _prefetch(i + 1);
      return;
    }

    if (!prefetchOnly) {
      setState(() {
        _loading = true;
        _error = null;
        _paragraphs = const [];
      });
    }

    final ch = widget.chapters[i];
    try {
      final r = await BookSourceService.instance.content(widget.source, ch.url);
      if (!mounted) return;
      if (!r.ok) {
        if (!prefetchOnly) {
          setState(() {
            _loading = false;
            _error = r.error ?? '正文获取失败';
          });
        }
        return;
      }
      // 漫画源：正文是图片列表，不是文字
      if (r.images.isNotEmpty) {
        _cache[i] = const []; // 文本缓存置空，避免上一本的文字残留
        if (!prefetchOnly) {
          setState(() {
            _images = r.images;
            _paragraphs = const [];
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
          _images = const []; // 切回文字章节要把漫画图清掉
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
    return Scaffold(
      backgroundColor: bg[0],
      body: GestureDetector(
        // 点屏幕中间切换菜单栏；点左/右 1/3 翻章
        onTapUp: (d) {
          final w = MediaQuery.of(context).size.width;
          final x = d.globalPosition.dx;
          if (_showBar) {
            setState(() => _showBar = false);
            return;
          }
          if (x < w * 0.3) {
            _go(-1);
          } else if (x > w * 0.7) {
            _go(1);
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
                  _bottomNav(bg[1]),
                ],
              ),
              if (_showBar) _topBar(bg[1]),
              if (_showBar) _settingsPanel(bg[1]),
              // 番茄钟浮层（复用 2.0.3 原有的 PomodoroButton）
              if (_showPomodoro)
                Positioned(
                  right: 12,
                  bottom: 180,
                  child: const PomodoroButton(),
                ),
              // 阅读悬浮球（截图里右下角那个球：单击翻页/双击菜单/拖动移动）
              if (!_showBar) _readingBall(bg[1]),
            ],
          ),
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
          return BookPageCurl(
            page: _pageContent(fg, _pages[_pageIndex]),
            nextPage: _pageIndex + 1 < _pages.length
                ? _pageContent(fg, _pages[_pageIndex + 1])
                : null,
            prevPage: _pageIndex > 0
                ? _pageContent(fg, _pages[_pageIndex - 1])
                : null,
            background: Container(color: _bgs[_bgIndex][0]),
            canNext: _pageIndex + 1 < _pages.length,
            canPrev: _pageIndex > 0,
            onTurnNext: () {
              if (_pageIndex + 1 < _pages.length) {
                setState(() => _pageIndex++);
              } else {
                _go(1);
              }
            },
            onTurnPrev: () {
              if (_pageIndex > 0) {
                setState(() => _pageIndex--);
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

        // 其余模式（左右 / 覆盖 / 无动画）走 PageView
        return Stack(
          children: [
            PageView.builder(
              controller: _pageCtrl,
              physics: _rs.pageMode == PageMode.none
                  // 无动画：直接切换（拖动仍然可用，只是没有滑动惯性）
                  ? const ClampingScrollPhysics()
                  // 覆盖：新页从侧面盖上来（Clamping 更"贴"，
                  // 视觉上是覆盖而非平移）
                  : _rs.pageMode == PageMode.cover
                      ? const ClampingScrollPhysics()
                      : const PageScrollPhysics(),
              itemCount: _pages.length,
              onPageChanged: (i) {
                setState(() => _pageIndex = i);
                _saveProgress();
              },
              itemBuilder: (context, i) => _pageContent(fg, _pages[i]),
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
      // 点屏幕中间的 1/3 显隐工具栏；左右 1/3 翻章
      onTapUp: (d) {
        final w = MediaQuery.of(context).size.width;
        final x = d.localPosition.dx;
        if (x < w / 3) {
          _prevPageOrChapter();
        } else if (x > w * 2 / 3) {
          _nextPageOrChapter();
        } else {
          setState(() => _showBar = !_showBar);
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
                    foregroundColor: _bgs[_bgIndex][0],
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
        child: child,
      );
    });
  }

  TextStyle _bodyStyle(Color fg) => TextStyle(
        fontSize: _fontSize,
        height: _lineHeight,
        letterSpacing: _letterSpacing,
        fontWeight: _fontWeightToW(_fontWeight),
        color: fg,
        decoration: _underlineStyle == 0
            ? TextDecoration.none
            : TextDecoration.underline,
        decorationColor: fg.withValues(alpha: _underlineAlpha),
        decorationStyle: _underlineStyle == 1
            ? TextDecorationStyle.dashed
            : _underlineStyle == 2
                ? TextDecorationStyle.dotted
                : _underlineStyle == 4
                    ? TextDecorationStyle.wavy
                    : TextDecorationStyle.solid,
        decorationThickness: _underlineWidth,
      );

  /// 一页的内容（含页眉 / 页脚信息栏）
  Widget _pageContent(Color fg, BookPage page) {
    final items = _rs.statusItems;
    final progress = _pages.isEmpty
        ? 0.0
        : (_pageIndex + 1) / _pages.length;
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
                padding: EdgeInsets.fromLTRB(0, 2, 0, 2),
                itemCount: page.entries.length,
                itemBuilder: (c, i) {
                  final e = page.entries[i];
                  final b = e.block;
                  if (b is HeadingBlock) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Text(
                        e.partialText ?? b.text,
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
                    // 段落下标用来关联书签，取第一个包含该块的段落
                    final pi = _paragraphIndexOf(b);
                    return Padding(
                      padding:
                          EdgeInsets.only(bottom: _fontSize * _paraSpacing),
                      child: GestureDetector(
                        onLongPress: () => _onParagraphLongPress(pi),
                        child: _wrapWithHighlight(
                          pi,
                          Text(
                            _indent > 0
                                ? '\u3000' * _indent.round() +
                                    (e.partialText ?? b.text)
                                : (e.partialText ?? b.text),
                            style: _bodyStyle(fg),
                          ),
                        ),
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
        _pageCtrl.nextPage(
          duration: _rs.pageMode == PageMode.none
              ? Duration.zero
              : const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        );
        return;
      }
    }
    _go(1);
  }

  /// 上一页；已在首页则回上一章
  void _prevPageOrChapter() {
    if (_rs.pageMode.paginates && _pages.isNotEmpty) {
      if (_pageIndex > 0) {
        _pageCtrl.previousPage(
          duration: _rs.pageMode == PageMode.none
              ? Duration.zero
              : const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        );
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
    final action = _rs.oneHand
        ? (zone == 4 ? TapAction.menu : TapAction.next)
        : (zones[zone] ?? TapAction.menu);
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


  Widget _topBar(Color fg) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: _bgs[_bgIndex][0].withValues(alpha: 0.96),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.arrow_back_rounded, color: fg),
              onPressed: () => Navigator.pop(context),
            ),
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
            // 三个图标：搜索 / 刷新 / 书签（截图 IMG_8110）
            IconButton(
              tooltip: '搜索全书',
              icon: Icon(Icons.search_rounded, size: 22, color: fg),
              onPressed: _showBookSearch,
            ),
            IconButton(
              tooltip: '刷新本章',
              icon: Icon(Icons.refresh_rounded, size: 22, color: fg),
              onPressed: () => _loadChapter(_index),
            ),
            IconButton(
              tooltip: _bookmarks.isEmpty
                  ? '加书签'
                  : '本书已有 ${_bookmarks.length} 个书签',
              icon: Icon(
                _bookmarks.isEmpty
                    ? Icons.bookmark_border_rounded
                    : Icons.bookmark_rounded,
                size: 22,
                color: fg,
              ),
              onPressed: () => _showAddBookmark(0),
            ),
          ],
        ),
      ),
    );
  }

  /// 底部菜单（按截图 IMG_8079/8076）：
  ///   上一章 [进度滑块] 下一章
  ///   朗读 / AI / 图片模式 / 笔记
  ///   排版 / 设置 / 目录 / 番茄钟
  ///
  /// 说明：
  ///   · 「目录」「设置」接已有实现（_showToc / _settingsPanel）
  ///   · 「排版」「朗读」「笔记」等是新页面/新面板，各自在对应方法里实现；
  ///     未实现的**不留空按钮** —— 点了要给明确反馈（见 _todoFeature）
  Widget _bottomNav(Color fg) {
    final bgTop = _bgs[_bgIndex][0];
    return Container(
      decoration: BoxDecoration(
        color: bgTop.withValues(alpha: 0.97),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── 进度条：上一章 / 滑块 / 下一章 ─────────────────────
          Row(
            children: [
              IconButton(
                onPressed: () => _go(-1),
                icon: Icon(Icons.chevron_left_rounded,
                    size: 24, color: fg.withValues(alpha: 0.85)),
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
                  child: Slider(
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
              IconButton(
                onPressed: () => _go(1),
                icon: Icon(Icons.chevron_right_rounded,
                    size: 24, color: fg.withValues(alpha: 0.85)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          // ── 8 宫格 ────────────────────────────────────────────
          Row(
            children: [
              _navItem(Icons.record_voice_over_outlined, '朗读',
                  () => _showTtsSheet(), fg),
              _navItem(Icons.auto_awesome_rounded, 'AI',
                  _showAiSummary, fg),
              _navItem(Icons.image_outlined, '图片模式',
                  _showImageMode, fg),
              _navItem(Icons.edit_note_rounded, '笔记',
                  () => _showNotesSheet(), fg),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _navItem(Icons.text_fields_rounded, '排版',
                  _showLayoutSheet, fg),
              _navItem(Icons.settings_outlined, '设置',
                  () => setState(() => _showBar = true), fg),
              _navItem(Icons.menu_book_rounded, '目录', _showToc, fg),
              // 番茄钟直接复用 2.0.3 原有的 PomodoroButton（两个阅读器都在用它）
              _navItem(Icons.timer_outlined, '番茄钟',
                  () => setState(() => _showPomodoro = !_showPomodoro), fg),
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
  void _paginate() {
    if (_viewport.width <= 0 || _viewport.height <= 0) return;
    if (!_rs.pageMode.paginates) {
      // 上下模式是滚动的，不需要分页
      if (_pages.isNotEmpty) setState(() => _pages = const []);
      return;
    }
    setState(() => _paginating = true);
    final blocks = <BookBlock>[
      // 章标题当 heading 块，保证它自己起一页
      BookBlock.heading(widget.chapters[_index].name, 1),
      ..._paragraphs.map(BookBlock.paragraph),
    ];
    final typo = BookTypography(
      fontSize: _fontSize,
      lineHeight: _lineHeight,
      padding: _padLeft,
      verticalPadding: _padTop,
      fontFamily: null,
    );
    try {
      final pg = BookPaginator(
        blocks: blocks,
        viewportWidth: _viewport.width,
        viewportHeight: _viewport.height,
        typo: typo,
        chapterStarts: const {0},
      );
      final out = <BookPage>[];
      // 增量分页，每批让出一次事件循环，避免同步度量冻结界面
      // stepInto 把已完成的页**追加进传入的列表**，签名是
      // stepInto(List<BookPage> out, {int chunk = 12})
      while (!pg.finished) {
        pg.stepInto(out, chunk: 60);
      }
      if (!mounted) return;
      setState(() {
        _pages = out;
        _pageIndex = 0;
        _paginating = false;
      });
    } catch (_) {
      // 分页失败就退回整章滚动 —— 能读比"分页正确"重要
      if (mounted) setState(() { _pages = const []; _paginating = false; });
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
                color: _bgs[_bgIndex][0],
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
                              height: 40,
                              decoration: BoxDecoration(
                                color: _fg.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: TextField(
                                controller: ctrl,
                                autofocus: true,
                                onChanged: run,
                                style: TextStyle(
                                    fontSize: AppTheme.fontBody, color: _fg),
                                decoration: InputDecoration(
                                  isDense: true,
                                  filled: false,
                                  hintText: '搜索全书内容',
                                  hintStyle: TextStyle(
                                      fontSize: AppTheme.fontBody, color: _fgMuted),
                                  prefixIcon: Icon(Icons.search_rounded,
                                      size: 19, color: _fgMuted),
                                  prefixIconConstraints:
                                      const BoxConstraints(
                                          minWidth: 38, minHeight: 38),
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                      vertical: 10),
                                ),
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
            _savePrefs();
          }

          return Container(
            constraints:
                BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.82),
            decoration: BoxDecoration(
              color: _bgs[_bgIndex][0],
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
                        Switch(value: false, onChanged: null),
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
                                        ? _bgs[_bgIndex][0]
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
                          if (tab == 2) ..._layoutTextTab(upd),
                          if (tab == 3) ..._layoutMarginTab(upd),
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
                            foregroundColor: _bgs[_bgIndex][0],
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

  /// 「主题」tab：背景 + 字色 + 图片（截图 IMG_8090）
  List<Widget> _layoutThemeTab(void Function(VoidCallback) upd) {
    const bgNames = ['默认', '护眼', '牛皮纸', '米黄', '竹'];
    const fgNames = ['自动', '墨黑', '深灰', '赭棕', '靛青'];
    const fgColors = [
      null,
      Color(0xFF1A1A1A),
      Color(0xFF4A4A4A),
      Color(0xFF8B5A2B),
      Color(0xFF1F3A5F),
    ];
    return [
      _layoutLabel('背景'),
      Wrap(
        spacing: 14,
        runSpacing: 10,
        children: [
          for (var i = 0; i < _bgs.length; i++)
            GestureDetector(
              onTap: () => upd(() => _bgIndex = i),
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
                        color: i == _bgIndex ? _fg : _fg.withValues(alpha: 0.25),
                        width: i == _bgIndex ? 2.5 : 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(bgNames[i % bgNames.length],
                      style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg)),
                ],
              ),
            ),
        ],
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
        ],
      ),
      const SizedBox(height: 14),
      _layoutLabel('图片'),
      Row(
        children: [
          for (final n in ['无', '内置', '选择图片'])
            Container(
              margin: const EdgeInsets.only(right: 10),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: n == '无'
                    ? _fg.withValues(alpha: 0.85)
                    : _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(n,
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: n == '无' ? _bgs[_bgIndex][0] : _fg)),
            ),
        ],
      ),
      const SizedBox(height: 10),
      Text('阅读背景图片需要图片选择器组件，还没接。',
          style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted)),
    ];
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
                      color: n == '跟随模式' ? _bgs[_bgIndex][0] : _fg)),
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
                color: n == '靠左'
                    ? _fg.withValues(alpha: 0.85)
                    : _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(n,
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: n == '靠左' ? _bgs[_bgIndex][0] : _fg)),
            ),
        ],
      ),
      const SizedBox(height: 14),
      _layoutLabel('首行缩进'),
      _layoutSlider('缩进', _indent, 0, 4, '${_indent.round()}',
          (v) => upd(() => _indent = v)),
    ];
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
                            ? _bgs[_bgIndex][0]
                            : _fg)),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      _layoutLabel('颜色'),
      Row(
        children: [
          for (final n in ['跟随文字', '墨黑', '深灰', '赭棕', '靛青'])
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: n == '跟随文字'
                    ? _fg.withValues(alpha: 0.85)
                    : _fg.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(n,
                  style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: n == '跟随文字' ? _bgs[_bgIndex][0] : _fg)),
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
      if (_underlineFull)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('满行底线需要自定义绘制（每行拉满），还没做。',
              style: TextStyle(fontSize: AppTheme.fontFootnote, color: _fgMuted)),
        ),
    ];
  }

  Widget _layoutLabel(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 2),
        child: Text(s,
            style:
                TextStyle(fontSize: AppTheme.fontBody, fontWeight: FontWeight.w600, color: _fg)),
      );

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
            color: _bgs[_bgIndex][0],
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
          color: _bgs[_bgIndex][0],
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
        backgroundColor: _bgs[_bgIndex][0],
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
  Future<void> _applyPreset(String name) async {
    _toast('已应用预设「$name」');
  }

  /// 「存预设」对话框（截图 IMG_8096）
  Future<void> _showSavePresetDialog(TextEditingController ctrl) async {
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _bgs[_bgIndex][0],
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
              foregroundColor: _bgs[_bgIndex][0],
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() => _savedPresets.add(name));
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
            _savePrefs();
          }

          return Container(
            constraints:
                BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
            decoration: BoxDecoration(
              color: _bgs[_bgIndex][0],
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
                        Switch(value: false, onChanged: null),
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
                              color: _bgs[_bgIndex][0],
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
                                        ? _bgs[_bgIndex][0]
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
                            foregroundColor: _bgs[_bgIndex][0],
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
      Obx(() => _ttsSlider('语速', _tts.rate.value, 0.1, 1.0,
          '${_tts.rate.value.toStringAsFixed(2)}x', (v) {
        upd(() {});
        _tts.setRate(v);
      })),
      Obx(() => _ttsSlider('音调', _tts.pitch.value, 0.5, 2.0,
          _tts.pitch.value.toStringAsFixed(2), (v) {
        upd(() {});
        _tts.setPitch(v);
      })),
      const SizedBox(height: 6),
      Divider(color: _fg.withValues(alpha: 0.10)),
      // 朗读引擎入口
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
              Text('更换', style: TextStyle(fontSize: AppTheme.fontSubhead, color: _fg)),
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: _fgMuted),
            ],
          ),
        ),
      ),
      Divider(color: _fg.withValues(alpha: 0.10)),
      Text(
        '音量用系统音量键调整（AVSpeechSynthesizer 的音量由系统控制）。'
        '语速/音调改完立刻对下一句生效。',
        style: TextStyle(fontSize: AppTheme.fontFootnote, height: 1.7, color: _fgMuted),
      ),
    ];
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
                              ? _bgs[_bgIndex][0]
                              : _fg)),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      _ttsLabel('样式'),
      Row(
        children: [
          for (var i = 0; i < styles.length; i++)
            GestureDetector(
              onTap: () => upd(() {}),
              child: Container(
                width: 36,
                height: 36,
                margin: const EdgeInsets.only(right: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: i == 0
                      ? _fg.withValues(alpha: 0.10)
                      : _fg.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: i == 0
                      ? Border.all(color: _fg.withValues(alpha: 0.4))
                      : null,
                ),
                child: Text(styles[i],
                    style: TextStyle(fontSize: AppTheme.fontBody, color: _fg)),
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
      _ttsLabel('范围'),
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
                          color: n == '本章' ? _fg : _bgs[_bgIndex][0])),
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
                            ? _bgs[_bgIndex][0]
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
                          ? _bgs[_bgIndex][0]
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
      _ttsSwitch('点朗读进播放页', '开启后点底栏「朗读」直接进沉浸式播放页'
          '（封面+当前句大字）；关闭时也可从播放条上的唱片键进入', false),
      _ttsSwitch('自动定位阅读位置', '朗读时自动翻到正在读的那一页；'
          '关闭后由播放条上的定位键手动跳', false),
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

  /// 朗读面板的一行滑杆
  Widget _ttsSlider(String label, double value, double min, double max,
      String display, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child:
                Text(label, style: TextStyle(fontSize: AppTheme.fontBody, color: _fg)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(display,
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                    color: _fg)),
          ),
        ],
      ),
    );
  }

  Widget _ttsLabel(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(s,
            style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w600,
                color: _fg)),
      );

  Widget _ttsSwitch(String title, String sub, bool value) {
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
          Switch(value: value, onChanged: null),
        ],
      ),
    );
  }

  /// TtsService 切出来的段落（供面板显示"正在念的那句"）
  List<String> get _ttsSegments {
    // TtsService 内部持有 _segments，这里用它切同一份文本以保持下标一致
    return TtsService.splitSegments(_paragraphs.join('\n'));
  }

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
        onPanEnd: (_) => _savePrefs(),
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

  /// AI 面板。
  ///
  /// ⚠️ **没有 AI 服务就做不了摘要**。这里不假装有：
  /// 把可用的动作列出来，点「总结本章」时如果没配 API 就如实说。
  /// 若要真接，需要：① 一个 API Key 的输入界面 ② 一个 chat 接口调用。
  void _showAiSummary() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _bgs[_bgIndex][0],
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
                    _toast('AI 功能需要 API Key —— 还没做配置界面');
                  },
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Text(
                  'AI 需要接入一个对话接口（自己的 API Key）。'
                  '这一步还没做 —— 所以这里点了不会有结果，不假装能总结。',
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

  /// 图片模式：把本章的图片单独列出来看/保存。
  ///
  /// 书源正文里的图片是 `<img src>` 标签，`_splitParagraphs` 会把它们
  /// 当普通文本留下。这里把图片 URL 抽出来。
  void _showImageMode() {
    final urls = <String>[];
    for (final p in _paragraphs) {
      for (final m in RegExp(r'https?://[^\s"''<>]+\.(?:jpg|jpeg|png|gif|webp)',
              caseSensitive: false)
          .allMatches(p)) {
        urls.add(m.group(0)!);
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
          color: _bgs[_bgIndex][0],
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

  /// 笔记面板：本书划线/批注列表，点击跳转到对应章节。
  void _showNotesSheet() {
    final notes = ReaderNotesService.instance
        .forBook(widget.source.id, widget.bookName);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.72,
        ),
        decoration: BoxDecoration(
          color: _bgs[_bgIndex][0],
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('笔记',
                        style: TextStyle(
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.w700,
                            color: _fg)),
                    const Spacer(),
                    if (notes.isNotEmpty)
                      TextButton(
                        onPressed: () async {
                          await ReaderNotesService.instance
                              .clearBook(widget.source.id, widget.bookName);
                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            setState(() {});
                            _toast('已清空本书笔记');
                          }
                        },
                        child: Text('清空',
                            style: TextStyle(
                                fontSize: AppTheme.fontFootnote,
                                color: JellyTheme.error)),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                if (notes.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 30),
                    child: Center(
                      child: Text(
                        '还没有划线笔记\n在正文里长按段落即可划线、写批注',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            color: _fgMuted,
                            height: 1.6),
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: notes.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final n = notes[i];
                        final isCur = n.chapterIndex == _index;
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
                                      '${isCur ? '（当前）' : ''}',
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
                              if (!isCur)
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
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
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
          color: _bgs[_bgIndex][0],
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
                    Switch(value: false, onChanged: null),
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
                              _savePrefs();
                              // 模式变了要重新分页（上下模式不分页）
                              _paginate();
                            }, compact: true),
                        ],
                      ),
                    ),
                    _setSwitch('翻页反转', '左点下一页、右点上一页', _rs.flipReverse,
                        (v) {
                      setState(() => _rs = _rs.copyWith(flipReverse: v));
                      _savePrefs();
                    }),
                    _setSwitch('单手模式', '屏幕左右点击都是下一页', _rs.oneHand,
                        (v) {
                      setState(() => _rs = _rs.copyWith(oneHand: v));
                      _savePrefs();
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
                      _savePrefs();
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
                            _savePrefs();
                          }),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _setSwitch('音量键翻页', '按音量上/下键翻页（会接管音量键）',
                        _rs.volumeKeys, (v) {
                      setState(() => _rs = _rs.copyWith(volumeKeys: v));
                      _savePrefs();
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
                              _savePrefs();
                              _applySleepMode();
                            }, compact: true),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 底部：取消 · 排版 · 确认
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _showBar = false),
                      child: Text('取消',
                          style: TextStyle(fontSize: AppTheme.fontBody, color: _fg)),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _showLayoutSheet,
                      child: Text('排版',
                          style: TextStyle(fontSize: AppTheme.fontBody, color: _fg)),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: () => setState(() => _showBar = false),
                      style: FilledButton.styleFrom(
                        backgroundColor: _fg.withValues(alpha: 0.9),
                        foregroundColor: _bgs[_bgIndex][0],
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
            color: on ? _bgs[_bgIndex][0] : _fg,
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
                                          color: _bgs[_bgIndex][0],
                                          borderRadius:
                                              const BorderRadius.vertical(
                                                  top: Radius.circular(20)),
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
                      _savePrefs();
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
  Future<void> _showToc() async {
    var tab = 0;
    final ctrl = TextEditingController();
    var kw = '';
    var asc = true;
    const tabNames = ['目录', '书签', '笔记'];

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final chapters = <int>[
            for (var i = 0; i < widget.chapters.length; i++)
              if (kw.isEmpty || widget.chapters[i].name.contains(kw)) i,
          ];
          if (!asc) {
            final rev = chapters.reversed.toList();
            chapters
              ..clear()
              ..addAll(rev);
          }
          return Container(
            constraints:
                BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.9),
            decoration: BoxDecoration(
              color: _bgs[_bgIndex][0],
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
                        ('笔记', '0 条'),
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
                              height: 38,
                              decoration: BoxDecoration(
                                color: _fg.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: TextField(
                                controller: ctrl,
                                onChanged: (v) =>
                                    setSheet(() => kw = v.trim()),
                                style: TextStyle(fontSize: AppTheme.fontBody, color: _fg),
                                decoration: InputDecoration(
                                  isDense: true,
                                  filled: false,
                                  hintText: '搜索章节',
                                  hintStyle: TextStyle(
                                      fontSize: AppTheme.fontBody, color: _fgMuted),
                                  prefixIcon: Icon(Icons.search_rounded,
                                      size: 18, color: _fgMuted),
                                  prefixIconConstraints:
                                      const BoxConstraints(
                                          minWidth: 36, minHeight: 36),
                                  border: InputBorder.none,
                                  contentPadding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                ),
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
                          Positioned(
                            right: 6,
                            top: 40,
                            bottom: 40,
                            child: Container(
                              width: 26,
                              decoration: BoxDecoration(
                                color: _fg.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  Icon(Icons.keyboard_arrow_up_rounded,
                                      size: 18, color: _fgMuted),
                                  Icon(Icons.keyboard_arrow_down_rounded,
                                      size: 18, color: _fgMuted),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else if (tab == 1) ...[
                    Flexible(
                      child: _bookmarks.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(40),
                                child: Text(
                                  '还没有书签。\n\n长按正文段落即可加书签。',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: AppTheme.fontSubhead,
                                      height: 1.7,
                                      color: _fgMuted),
                                ),
                              ),
                            )
                          : ListView(
                              shrinkWrap: true,
                              children: [
                                for (final e in _bookmarks.entries)
                                  ListTile(
                                    leading: Container(
                                      width: 14,
                                      height: 14,
                                      decoration: BoxDecoration(
                                        color: e.value,
                                        borderRadius:
                                            BorderRadius.circular(10),
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
                                        _savePrefs();
                                      }),
                                    ),
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      final p = _pageOfParagraph(e.key);
                                      if (p != null &&
                                          _pageCtrl.hasClients) {
                                        _pageCtrl.jumpToPage(p);
                                      }
                                    },
                                  ),
                              ],
                            ),
                    ),
                  ] else ...[
                    Flexible(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(40),
                          child: Text(
                            '还没有划线或批注\n\n'
                            '在正文里长按选中文字即可划线、写批注',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: AppTheme.fontSubhead, height: 1.7, color: _fgMuted),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
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
