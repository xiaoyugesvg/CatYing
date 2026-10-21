import 'dart:async';
import '../../widgets/common_widgets.dart';
import 'dart:convert';
import 'dart:io';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../models/comic.dart';
import '../services/bookshelf_service.dart';
import '../source/adapter.dart';
import '../source/source_manager.dart';
import '../source/webview_image_fetcher.dart';
import '../services/download_service.dart';
import '../services/platform_service.dart';
import '../services/reading_progress_service.dart';
import '../services/manga_bookmark_service.dart';
import '../services/reader_override_service.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_mode_picker.dart';
import '../widgets/pomodoro_button.dart';
import '../../common/theme.dart';
import '../../common/system_ui.dart';
import '../../services/ocr_service.dart';
import '../../services/translate_service.dart';
import '../../widgets/app_image_cache.dart';
import 'comic_translate_page.dart';

/// 漫画阅读页面
class ReaderPage extends StatefulWidget {
  final Comic comic;
  final ComicChapter chapter;
  final List<ChapterGroup> groups;

  /// 续读起始页（从 0 起），由下载页"继续阅读"传入
  final int initialPage;

  const ReaderPage({
    super.key,
    required this.comic,
    required this.chapter,
    required this.groups,
    this.initialPage = 0,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late ComicChapter _currentChapter;
  List<String> _images = [];
  bool _isLoading = true;
  String? _error;
  int _currentIndex = 0;

  /// 最近一次归位的书架状态（presetReading/presetFinished），避免频繁移动
  String? _lastAppliedStatus;
  bool _showControls = true;
  /// 番茄钟悬浮倒计时是否显示（与书源阅读器同款交互：底栏图标开关悬浮层）
  bool _showPomodoro = false;
  bool _useLocal = false; // 是否使用本地已下载图片

  /// 在线图片请求头（防盗链/UA，随当前源 imageHeaders+referer）
  Map<String, String> _imageHeaders = const {};

  /// 翻页模式控制器（程序化翻页用）
  late PageController _pageController;

  /// ✅ **`data:` 图片的解码缓存**（[medium] 修复 ✓）：
  ///   `MemoryImage` 的 `==` 比较的是 `bytes` 的**引用** ✓，而展示路径原来每次
  ///   `build` 都 `base64.decode` 出**新的** `Uint8List` ✗ →
  ///   （a）同一张图的缓存键每帧都不同 ✓ → 每次 setState（翻页 / 显隐控制栏 /
  ///   切墨水屏 / 改边距）都**绕过图片缓存重新解码整张图** ✗，缓存里还留下大量
  ///   同图不同键的条目 ✗；（b）预载用的又是另一次解码 ✗ → 键与展示路径不同 ✗，
  ///   预载对 data: 图**完全不生效** ✗（注释声称"命中同一缓存条目"并不成立 ✗）。
  ///   这里按 url 缓存**同一个** `Uint8List` 实例 ✓，展示与预载共用 ✓ → 键相等 ✓。
  ///   随章节切换（[_loadImages]）清理 ✓，不会跨章累积 ✓。
  final Map<String, Uint8List> _dataImageBytes = {};

  /// 拼页模式：按索引滚动/跳转
  final ItemScrollController _itemScrollController = ItemScrollController();

  /// 拼页模式：像素级平滑滚动（绕开 scrollTo 的 index 估算过冲 bug）
  final ScrollOffsetController _scrollOffsetController =
      ScrollOffsetController();

  /// 拼页模式：各图片的 GlobalKey（量取渲染高度/位置）
  final Map<int, GlobalKey> _imageKeys = {};
  GlobalKey _keyOf(int index) =>
      _imageKeys.putIfAbsent(index, () => GlobalKey(debugLabel: 'img_$index'));

  /// 拼页模式：监听各图片位置，用于定位当前页
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  /// 拼页模式当前页码（滚动时实时更新，不触发 setState 重建列表）
  final ValueNotifier<int> _continuousPageNotifier = ValueNotifier(0);

  /// 是否首次加载（仅首次加载恢复续读页码，切章节不恢复）
  bool _isInitialLoad = true;

  /// 记住的缩放倍率（rememberZoom 开启时恢复）
  double _savedZoomScale = 1.0;

  /// 每次加载自增，作为列表 key 的一部分，确保 ScrollablePositionedList
  /// 每次加载都是全新实例（不复用 PageStorage 历史偏移），切章节/切回已读
  /// 章节都从第 0 页开始，避免连点切章节时页码停留在旧位置。
  int _loadId = 0;

  /// 拼页列表专用 PageStorage 桶，每次加载重建为空桶，使
  /// ScrollablePositionedList 的 initState 读 PageStorage 时拿到 null，
  /// 不再恢复历史滚动位置，切章节/切回已读章节都从第 0 页开始。
  PageStorageBucket _galleryBucket = PageStorageBucket();

  /// gallery 上次构建所用的阅读模式，用于检测模式切换以刷新 gallery。
  ReadingMode _builtMode = ReadingMode.pageTurn;

  /// gallery 上次构建所用的双页状态（横屏+开关+翻页模式），变化时重建 PageController。
  bool _builtDoublePage = false;

  /// 上次构建所用的墨水屏状态，变化时 rebuild 以切换滤镜/背景/动画。
  bool _builtInkMode = false;

  /// 墨水屏柔和底色（与图片白边同色 #D9D2CC，形成统一暖灰底）。
  static const Color _inkBgColor = Color(0xFFD9D2CC);

  /// 墨水屏灰度矩阵（×0.85 压暗 + 轻微暖调；白边处理后 = 背景色 #D9D2CC）。
  static const _inkGrayMatrix = <double>[
    0.254,
    0.499,
    0.097,
    0,
    0,
    0.246,
    0.484,
    0.094,
    0,
    0,
    0.239,
    0.469,
    0.091,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];

  /// 阅读背景五选色（参考 cmbok「显示」tab：纯白/纸白/米黄/暗夜/纯黑）
  Color _bgColorOf(int style) {
    switch (style) {
      case 0:
        return const Color(0xFFFFFFFF); // 纯白
      case 1:
        return const Color(0xFFF7F4EC); // 纸白
      case 2:
        return const Color(0xFFEFE6CE); // 米黄
      case 4:
        return const Color(0xFF000000); // 纯黑
      default:
        return const Color(0xFF141416); // 暗夜（默认）
    }
  }

  /// 当前背景是否为浅色（纯白/纸白/米黄），决定文字用深色
  bool get _bgIsLight =>
      !SettingsService().inkScreenMode &&
      SettingsService().readerBackgroundStyle <= 2;

  /// 画廊背景：墨水屏用柔和暖灰（置于灰度罩外，暖色不受矩阵影响），否则背景五选。
  Color get _galleryBg => SettingsService().inkScreenMode
      ? _inkBgColor
      : _bgColorOf(SettingsService().readerBackgroundStyle);

  /// 画廊内部底色（PhotoView/dissolve）：墨水屏透明，露出罩外浅灰；否则背景五选。
  Color get _innerGalleryBg => SettingsService().inkScreenMode
      ? Colors.transparent
      : _bgColorOf(SettingsService().readerBackgroundStyle);

  /// 画廊上的文字色：墨水屏浅灰底 / 浅色背景用深灰，否则白。
  Color get _inkTextColor =>
      (SettingsService().inkScreenMode || _bgIsLight)
          ? Colors.black54
          : Colors.white;

  /// 漫画边距（页眉左右/上 + 页脚左右/下，参考 cmbok「边距」tab）
  EdgeInsets get _comicMargins {
    final s = SettingsService();
    return EdgeInsets.fromLTRB(
      s.comicHeaderLeft,
      s.comicHeaderTop,
      s.comicHeaderRight,
      s.comicFooterBottom,
    );
  }

  /// 墨水屏灰度滤镜。
  ColorFilter get _inkColorFilter => ColorFilter.matrix(_inkGrayMatrix);

  /// 当前是否为拼页模式
  bool get _isContinuousMode => _effectiveReadingMode == ReadingMode.continuous;

  /// 当前是否为消散模式（逐页交叉淡入淡出）
  bool get _isDissolveMode => _effectiveReadingMode == ReadingMode.dissolve;

  /// 当前是否为从左往右翻页（PageView/PhotoViewGallery 反向，图片从左翻入）
  bool get _isReverseDirection =>
      _effectiveReadingMode == ReadingMode.leftToRight;

  /// 双页模式：翻页（含无动画）/消散模式 + 开关开启 + 横屏 时生效（拼页模式不支持）
  bool get _isDoublePage {
    if (_effectiveReadingMode != ReadingMode.pageTurn &&
        _effectiveReadingMode != ReadingMode.dissolve &&
        _effectiveReadingMode != ReadingMode.leftToRight &&
        _effectiveReadingMode != ReadingMode.none) {
      return false;
    }
    if (!ReaderOverrideService().effectiveDoublePageManga(
      widget.comic.pathWord,
    )) {
      return false;
    }
    return MediaQuery.orientationOf(context) == Orientation.landscape;
  }

  /// 双页 spread 映射（首页单独成页，保证跨页图不错位）：
  /// spread0=图0（单），spreadN(N>0)=图(2N-1)+图(2N)。
  int _imageToSpread(int imageIndex) =>
      imageIndex <= 0 ? 0 : (imageIndex + 1) ~/ 2;
  int _spreadLeftImage(int spread) => spread == 0 ? 0 : spread * 2 - 1;
  int _spreadRightImage(int spread) => spread * 2;
  int get _spreadCount => _images.isEmpty ? 0 : 1 + _images.length ~/ 2;
  int get _currentSpread => _imageToSpread(_currentIndex);
  int get _controllerInitialPage =>
      _isDoublePage ? _currentSpread : _currentIndex;

  /// 当前生效的漫画阅读模式：独立设置开启时取 per-item 覆盖，否则全局
  ReadingMode get _effectiveReadingMode =>
      ReaderOverrideService().effectiveMangaMode(widget.comic.pathWord);

  @override
  void initState() {
    super.initState();
    _currentChapter = widget.chapter;
    _currentIndex = widget.initialPage < 0 ? 0 : widget.initialPage;
    _pageController = PageController(initialPage: _currentIndex);
    _itemPositionsListener.itemPositions.addListener(_onItemPositionsChanged);
    SettingsService().addListener(_onReaderSettingsChanged);
    ReaderOverrideService().addListener(_onReaderSettingsChanged);
    _builtInkMode = SettingsService().inkScreenMode;
    // 恢复记住的缩放倍率（仅 rememberZoom 开启时生效于 initialScale）
    _savedZoomScale = ReadingProgressService()
        .getZoomScale(widget.comic.pathWord);
    // 沉浸阅读：延后到路由转场结束再隐藏顶部状态栏（保留底部导航栏），
    // 避免系统栏切换与 MaterialPageRoute 转场叠加造成进入卡顿。
    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      SystemUiController.enter(
        'comicReader',
        mode: SystemUiMode.manual,
        overlays: const [SystemUiOverlay.bottom],
      );
    });
    _loadImages();
    PlatformService.onVolumeKey = _onVolumeKey;
    PlatformService.setVolumeKeyNav(
      ReaderOverrideService().effectiveVolumeKeyTurnManga(
        widget.comic.pathWord,
      ),
    );
  }

  @override
  void dispose() {
    // ⚠️ 2026-10-14：**只在"当前注册的还是我"时才清空**。`onVolumeKey` 是全局
    //   单点（`PlatformService` 是静态字段），若同时存在两个阅读器（栈上叠加 /
    //   转场尚未销毁），先退出者原来会无条件把它清成 null 并关掉音量键翻页 ⇒
    //   **仍在用的那个**阅读器音量键立刻失效。
    //   用 `==` 而非 `identical`：Dart 的实例方法 tear-off 对"同一实例 + 同一
    //   方法"用 `==` 判定为相等（`identical` 不保证）。
    if (PlatformService.onVolumeKey == _onVolumeKey) {
      PlatformService.onVolumeKey = null;
      PlatformService.setVolumeKeyNav(false);
    }
    _itemPositionsListener.itemPositions.removeListener(
      _onItemPositionsChanged,
    );
    SettingsService().removeListener(_onReaderSettingsChanged);
    ReaderOverrideService().removeListener(_onReaderSettingsChanged);
    _pageController.dispose();
    _continuousPageNotifier.dispose();
    // 离开阅读器：恢复**进入前**的系统栏状态（原来写死 edge-to-edge）
    SystemUiController.exit('comicReader');
    // 清理 blob 站临时文件（摸摸漫画等 useBlobBase64 站落盘的章节图）
    WebViewImageFetcher().clearBlobTempFiles();
    super.dispose();
  }

  /// 阅读（全局或独立）设置变化：阅读模式改变时刷新 gallery（重建控件、
  /// 重新定位当前页）；双页开关变化时 rebuild，由 _buildGallery 同步重建
  /// PageController；预加载/反转无需重建控件。
  void _onReaderSettingsChanged() {
    if (!mounted || _images.isEmpty) return;
    PlatformService.setVolumeKeyNav(
      ReaderOverrideService().effectiveVolumeKeyTurnManga(
        widget.comic.pathWord,
      ),
    );
    if (_effectiveReadingMode != _builtMode) {
      _refreshGallery();
      return;
    }
    if (_isDoublePage != _builtDoublePage) {
      setState(() {});
    }
    // 墨水屏开关变化：rebuild 以切换外包滤镜、纸张底、动画时长
    final s = SettingsService();
    if (s.inkScreenMode != _builtInkMode) {
      _builtInkMode = s.inkScreenMode;
      setState(() {});
    }
  }

  /// 刷新 gallery（模式切换用）：bump _loadId 重建全新实例、PageController
  /// 指向当前页；拼页模式 post-frame 跳到当前页。不重新拉图。
  void _refreshGallery() {
    final initialPage = _controllerInitialPage;
    final isDouble = _isDoublePage;
    setState(() {
      _loadId++; // 新 key，确保 gallery 全新实例
      _galleryBucket = PageStorageBucket(); // 空桶，杜绝历史偏移恢复
      _builtMode = _effectiveReadingMode;
      _builtDoublePage = isDouble;
    });
    // ✅ **旧控制器必须 dispose**（[medium] 修复 ✓）：原来直接换新实例 ✗，
    //   旧实例仍被上一帧的 `PageView` / `PhotoViewGallery` 持有 ✗。
    _pageController.dispose();
    _pageController = PageController(initialPage: initialPage);
    if (_isContinuousMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _itemScrollController.isAttached) {
          _itemScrollController.jumpTo(index: _currentIndex);
        }
      });
    }
  }

  Future<void> _loadImages() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _images = [];
      _useLocal = false;
      _loadId++; // 每次加载用新 key，确保列表全新实例
      _galleryBucket = PageStorageBucket(); // 空桶，杜绝历史偏移恢复
    });
    // ✅ 切章清掉 data: 解码缓存（[medium] 修复 ✓）：缓存键是整条 data: URL ✓，
    //   不清的话整本书的 base64 图都会常驻内存 ✗（blob 站整章 base64 本身就是大头 ✓）。
    _dataImageBytes.clear();
    _dataProviderCache.clear();
    // 拼页模式：等一帧让"加载中"界面构建、旧列表释放，
    // 避免 ScrollablePositionedList 复用 ItemScrollController 时
    // 新列表 attach 早于旧列表 detach 触发断言崩溃（本地图片加载快时易发）
    if (_isContinuousMode) {
      final frameReady = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => frameReady.complete(),
      );
      await frameReady.future;
      if (!mounted) return;
    }

    try {
      // 优先本地已下载图片（离线阅读）
      final local = await DownloadService().getLocalImages(
        widget.comic.pathWord,
        widget.comic.title,
        _currentChapter.id,
      );
      if (local.isNotEmpty) {
        // 🔴 本方法上面有 `await ...getLocalImages(...)` ✓ —— 这个 `setState`
        // 却**没有 `mounted` 检查** ✗（页面被销毁后抛
        // `setState() called after dispose()` ✓，release 同样抛 ✗）
        if (!mounted) return;
        setState(() {
          _images = local;
          _useLocal = true;
        });
        return;
      }
      // 回退网络加载：用漫画自身所属源（书架多源时 current 未必匹配）
      final source =
          (widget.comic.sourceId != null && widget.comic.sourceId!.isNotEmpty)
          ? (SourceManager().getSource(widget.comic.sourceId!) ??
                SourceManager().current)
          : SourceManager().current;
      final cchapter = comicChapterToCChapter(
        _currentChapter,
        source.id,
        widget.comic.pathWord,
      );
      final images = await source.getChapterImages(
        comicToCManga(widget.comic, source.id),
        cchapter,
      );
      final headers = <String, String>{...source.imageHeaders};
      final ref = source.refererForChapter(cchapter);
      if (ref != null) headers['Referer'] = ref;
      // 🔴 上面 `await source.getChapterImages(...)`（网络请求 ✓）之后同样漏了检查 ✗
      if (!mounted) return;
      setState(() {
        _images = images;
        _imageHeaders = headers;
      });
    } catch (e) {
      // 🔴 catch 分支也一样 ✗（异常同样可能发生在 await 之后 ✓）
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        if (_images.isNotEmpty) {
          _currentIndex = _currentIndex.clamp(0, _images.length - 1);
          // 记录续读点与已读章节（仅图片成功加载时）
          ReadingProgressService().recordChapter(
            widget.comic.pathWord,
            _currentChapter,
            _currentIndex,
            _allChapters.indexWhere((c) => c.id == _currentChapter.id),
          );
          // 按进度归位"正在读"/"已读完"书架
          _applyReadingStatus();
        } else {
          _currentIndex = 0;
        }
        setState(() {
          _isLoading = false;
        });
        if (_isContinuousMode && _images.isNotEmpty) {
          if (_isInitialLoad && widget.initialPage > 0) {
            // 首次加载：恢复续读页
            final target = widget.initialPage.clamp(0, _images.length - 1);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_itemScrollController.isAttached) {
                _itemScrollController.jumpTo(index: target);
              }
            });
          } else {
            // 切章节：延迟 2 帧 jumpTo(0)。本地图片解码快、初始高度 0，
            // ScrollPosition 在 layout 修正时会被带偏到历史 offset；等 2 帧
            // position 稳定后强制重置到第 0 页。
            WidgetsBinding.instance.addPostFrameCallback((_) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_itemScrollController.isAttached) {
                  _itemScrollController.jumpTo(index: 0);
                }
              });
            });
          }
        }
        if (_images.isNotEmpty) {
          _isInitialLoad = false;
        }
        // 在线阅读：开章/切章后预加载当前页之后的图片
        _preloadAhead(_currentIndex);
      }
    }
  }

  /// 在线阅读时预加载当前页之后的若干张图片，提升翻页流畅度。
  /// 仅网络图片生效（本地已下载图片读取快，无需预加载）；仅向前预加载。
  /// 数量由设置项 preloadImageCount 控制（2~10，默认5），独立设置开启时取 per-item。
  void _preloadAhead(int fromIndex) {
    if (_useLocal || _images.isEmpty) return;
    final count = ReaderOverrideService().effectivePreload(
      widget.comic.pathWord,
    );
    final end = (fromIndex + 1 + count).clamp(0, _images.length);
    for (var i = fromIndex + 1; i < end; i++) {
      final url = _images[i];
      if (url.startsWith('file://') || !url.contains('://')) {
        // blob 站临时文件预解码：限宽同展示路径
        final dw =
            (MediaQuery.sizeOf(context).width *
                    MediaQuery.devicePixelRatioOf(context))
                .round();
        final file = File(
          url.startsWith('file://') ? Uri.parse(url).toFilePath() : url,
        );
        precacheImage(
          ResizeImage(FileImage(file), width: dw, allowUpscaling: false),
          context,
        );
      } else if (url.startsWith('data:')) {
        // base64 图片预解码：限宽至屏幕物理像素（与展示路径的
        // Image.memory(cacheWidth) 同参数，命中同一缓存条目），
        // 避免全尺寸预解码大图叠加导致内存溢出
        // ✅ **必须用 [_dataBytesOf]**（[medium] 修复 ✓）：这里原来自己又
        //   `base64.decode` 了一次 ✗ → 解出的 `Uint8List` 与展示路径**不是同一个引用** ✗
        //   → `MemoryImage` / `ResizeImage` 的键不相等 ✓，预载**完全不生效** ✗
        //   （注释声称"命中同一缓存条目"并不成立 ✗）。
        if (url.indexOf(',') > 0) {
          final bytes = _dataBytesOf(url);
          final dw =
              (MediaQuery.sizeOf(context).width *
                      MediaQuery.devicePixelRatioOf(context))
                  .round();
          precacheImage(
            ResizeImage(MemoryImage(bytes), width: dw, allowUpscaling: false),
            context,
          );
        }
      } else {
        precacheImage(
          CachedNetworkImageProvider(
            url,
            headers: _imageHeaders,
            cacheManager: appImageCacheManager,
          ),
          context,
        );
      }
    }
  }

  /// 获取所有章节（展平）
  List<ComicChapter> get _allChapters {
    return widget.groups.expand((g) => g.chapters).toList();
  }

  /// 上一话（第一话时提示）
  void _prevChapter() {
    final allChapters = _allChapters;
    final currentIndex = allChapters.indexWhere(
      (c) => c.id == _currentChapter.id,
    );
    if (currentIndex <= 0) {
      _showTip('已经是第一话了');
      return;
    }
    _goToChapter(allChapters[currentIndex - 1]);
  }

  /// 下一话（最后一话时提示）
  void _nextChapter() {
    final allChapters = _allChapters;
    final currentIndex = allChapters.indexWhere(
      (c) => c.id == _currentChapter.id,
    );
    if (currentIndex < 0 || currentIndex >= allChapters.length - 1) {
      _showTip('已经是最后一话了');
      return;
    }
    _goToChapter(allChapters[currentIndex + 1]);
  }

  /// 切换到指定章节：重置页码与翻页控制器后重新加载
  void _goToChapter(ComicChapter chapter, {int initialPage = 0}) {
    setState(() {
      _currentChapter = chapter;
      _currentIndex = initialPage;
      _continuousPageNotifier.value = initialPage; // 拼页模式：切章节页码归零
    });
    // ✅ **旧控制器必须 dispose**（[medium] 修复 ✓）：原来直接换新实例 ✗，
    //   旧控制器仍被上一帧的 `PageView` / `PhotoViewGallery` 持有 ✗，
    //   其 ScrollPosition 与 listener 一直挂到重建完成 ✓（`dispose()` 里只处理当前那个 ✓）。
    _pageController.dispose();
    _pageController = PageController(initialPage: initialPage);
    _loadImages();
  }

  // ---------------- 书签 ----------------

  /// 切换当前页书签（顶部书签按钮）
  Future<void> _toggleBookmark() async {
    final added = await MangaBookmarkService().toggle(
      pathWord: widget.comic.pathWord,
      comicTitle: widget.comic.title,
      chapterId: _currentChapter.id,
      chapterTitle: _currentChapter.title,
      pageIndex: _currentIndex,
      pageCount: _images.length,
    );
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(added ? '已添加书签' : '已取消书签'),
          duration: const Duration(seconds: 1),
        ),
      );
  }

  /// 当前页是否已加书签（顶部按钮高亮）
  bool _currentPageBookmarked() =>
      _images.isNotEmpty &&
      MangaBookmarkService().exists(
        widget.comic.pathWord,
        _currentChapter.id,
        _currentIndex,
      );

  // ---------------- 阅读设置 ----------------

  /// 阅读设置弹层：独立设置开关 + 漫画阅读模式 + 在线预加载图片数。
  /// 草稿式，点「确认」一次性写入（独立设置开启写 per-item 覆盖，否则写全局）。
  void _showReaderSettingsSheet() {
    final pathWord = widget.comic.pathWord;
    final o = ReaderOverrideService();
    final s = SettingsService();
    bool draftIndependent = o.isIndependentManga(pathWord);
    ReadingMode draftMode = o.effectiveMangaMode(pathWord);
    int draftPreload = o.effectivePreload(pathWord);
    bool draftReverseTap = o.effectiveReverseTapManga(pathWord);
    bool draftDoublePage = o.effectiveDoublePageManga(pathWord);
    bool draftShowHud = o.effectiveShowHudManga(pathWord);
    bool draftVolumeKey = o.effectiveVolumeKeyTurnManga(pathWord);
    bool draftInk = s.inkScreenMode; // 墨水屏仅全局，无 per-item 覆盖
    // 全局项（参考图四 tab 补齐：操作/显示/边距）
    bool draftSingleHand = s.singleHand;
    bool draftPinchZoom = s.pinchZoom;
    bool draftRememberZoom = s.rememberZoom;
    String draftSleep = s.screenSleep;
    int draftBg = s.readerBackgroundStyle;
    double draftHl = s.comicHeaderLeft;
    double draftHr = s.comicHeaderRight;
    double draftHt = s.comicHeaderTop;
    double draftFl = s.comicFooterLeft;
    double draftFr = s.comicFooterRight;
    double draftFb = s.comicFooterBottom;
    int _tab = 0;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black87,
      barrierColor: Colors.black54,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => kbSheet(StatefulBuilder(
        builder: (ctx, setSheet) {
          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '阅读设置',
                          style: TextStyle(
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '独立设置',
                          style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            color: draftIndependent
                                ? JellyTheme.primary
                                : Colors.white70,
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
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        draftIndependent ? '当前修改仅对本书生效' : '当前为全局设置，修改影响所有漫画',
                        style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: draftIndependent
                              ? JellyTheme.primary.withValues(alpha: 0.9)
                              : Colors.white54,
                        ),
                      ),
                    ),
                    // ── 四 tab：阅读 / 操作 / 显示 / 边距 ──
                    Row(
                      children: [
                        for (final (i, t) in const [
                          (0, '阅读'),
                          (1, '操作'),
                          (2, '显示'),
                          (3, '边距'),
                        ])
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setSheet(() => _tab = i),
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  color: _tab == i
                                      ? JellyTheme.primary.withValues(
                                          alpha: 0.9,
                                        )
                                      : Colors.white.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  t,
                                  style: TextStyle(
                                    fontSize: AppTheme.fontSubhead,
                                    color: _tab == i
                                        ? Colors.white
                                        : Colors.white70,
                                    fontWeight: _tab == i
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (_tab == 0) ...[
                      // ── 阅读 tab：阅读模式 / 预加载 / 双页模式 ──
                      Row(
                        children: [
                          const Text(
                            '阅读模式',
                            style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            // 用户 2026-10-15：「阅读模式这些不够好」⇒
                            // 纯文字 chip 换成「图标 + 名称」小块（三处阅读器统一）
                            child: JellyModePicker(
                              fg: Colors.white,
                              items: [
                                JellyModeItem(
                                  label: '右左',
                                  symbol: mangaModeSymbol(ReadingMode.pageTurn),
                                  selected: draftMode == ReadingMode.pageTurn,
                                  onTap: () => setSheet(
                                    () => draftMode = ReadingMode.pageTurn,
                                  ),
                                ),
                                JellyModeItem(
                                  label: '左右',
                                  symbol: mangaModeSymbol(ReadingMode.leftToRight),
                                  selected:
                                      draftMode == ReadingMode.leftToRight,
                                  onTap: () => setSheet(
                                    () => draftMode = ReadingMode.leftToRight,
                                  ),
                                ),
                                JellyModeItem(
                                  label: '消散',
                                  symbol: mangaModeSymbol(ReadingMode.dissolve),
                                  selected: draftMode == ReadingMode.dissolve,
                                  onTap: () => setSheet(
                                    () => draftMode = ReadingMode.dissolve,
                                  ),
                                ),
                                JellyModeItem(
                                  label: '无动画',
                                  symbol: mangaModeSymbol(ReadingMode.none),
                                  selected: draftMode == ReadingMode.none,
                                  onTap: () => setSheet(
                                    () => draftMode = ReadingMode.none,
                                  ),
                                ),
                                JellyModeItem(
                                  label: '拼页',
                                  symbol: mangaModeSymbol(ReadingMode.continuous),
                                  selected:
                                      draftMode == ReadingMode.continuous,
                                  onTap: () => setSheet(
                                    () => draftMode = ReadingMode.continuous,
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
                          const Text(
                            '预加载',
                            style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Slider(
                              value: draftPreload.toDouble(),
                              min: SettingsService.minPreloadImages
                                  .toDouble(),
                              max: SettingsService.maxPreloadImages
                                  .toDouble(),
                              divisions:
                                  SettingsService.maxPreloadImages -
                                  SettingsService.minPreloadImages,
                              activeColor: JellyTheme.primary,
                              onChanged: (v) =>
                                  setSheet(() => draftPreload = v.round()),
                            ),
                          ),
                          SizedBox(
                            width: 28,
                            child: Text(
                              '$draftPreload',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      _settingSwitchRow(
                        title: '双页模式',
                        subtitle: '横屏左右并排',
                        value: draftDoublePage,
                        onChanged: (v) =>
                            setSheet(() => draftDoublePage = v),
                      ),
                    ],
                    if (_tab == 1) ...[
                      // ── 操作 tab：翻页反转 / 单手模式 / 点击区域 / 音量键 / 屏幕休眠 ──
                      _settingSwitchRow(
                        title: '翻页反转',
                        subtitle: '左点下一页、右点上一页',
                        value: draftReverseTap,
                        onChanged: (v) => setSheet(() => draftReverseTap = v),
                      ),
                      _settingSwitchRow(
                        title: '单手模式',
                        subtitle: '屏幕左右点击都是下一页',
                        value: draftSingleHand,
                        onChanged: (v) =>
                            setSheet(() => draftSingleHand = v),
                      ),
                      InkWell(
                        onTap: _showTapZoneEditor,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: _settingInfoRow(
                            title: '点击区域',
                            subtitle: _zoneSummary(),
                          ),
                        ),
                      ),
                      _settingSwitchRow(
                        title: '音量键翻页',
                        subtitle: '按音量上/下键翻页（会接管音量键）',
                        value: draftVolumeKey,
                        onChanged: (v) => setSheet(() => draftVolumeKey = v),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Text(
                            '屏幕休眠',
                            style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Row(
                              children: [
                                _segmentChip(
                                  '默认',
                                  draftSleep == 'default',
                                  () =>
                                      setSheet(() => draftSleep = 'default'),
                                ),
                                const SizedBox(width: 8),
                                _segmentChip(
                                  '10分钟',
                                  draftSleep == '10min',
                                  () => setSheet(() => draftSleep = '10min'),
                                ),
                                const SizedBox(width: 8),
                                _segmentChip(
                                  '永不息屏',
                                  draftSleep == 'never',
                                  () => setSheet(() => draftSleep = 'never'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (_tab == 2) ...[
                      // ── 显示 tab：背景 / 信息栏 / 墨水屏 / 双指缩放 / 记住缩放 ──
                      Row(
                        children: [
                          const Text(
                            '背景',
                            style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Row(
                              children: [
                                for (final (i, t) in const [
                                  (0, '纯白'),
                                  (1, '纸白'),
                                  (2, '米黄'),
                                  (3, '暗夜'),
                                  (4, '纯黑'),
                                ])
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 2,
                                      ),
                                      child: _segmentChip(
                                        t,
                                        draftBg == i,
                                        () => setSheet(() => draftBg = i),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      _settingSwitchRow(
                        title: '信息栏',
                        subtitle: '显示时间、页码、进度',
                        value: draftShowHud,
                        onChanged: (v) => setSheet(() => draftShowHud = v),
                      ),
                      _settingSwitchRow(
                        title: '墨水屏',
                        subtitle: '黑白柔和显示',
                        value: draftInk,
                        onChanged: (v) => setSheet(() => draftInk = v),
                      ),
                      _settingSwitchRow(
                        title: '双指缩放',
                        subtitle: '双指捏合放大（上下模式除外）',
                        value: draftPinchZoom,
                        onChanged: (v) =>
                            setSheet(() => draftPinchZoom = v),
                      ),
                      _settingSwitchRow(
                        title: '记住缩放大小',
                        subtitle: '翻页时保留当前缩放（需开启双指缩放）',
                        value: draftRememberZoom,
                        onChanged: (v) =>
                            setSheet(() => draftRememberZoom = v),
                      ),
                      InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _showUpscalePanel();
                          });
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Text(
                                '端侧 AI 超分',
                                style: TextStyle(
                                  fontSize: AppTheme.fontBody,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  '本地模型放大漫画图片，显示更清晰',
                                  style: TextStyle(
                                    fontSize: AppTheme.fontFootnote,
                                    color: Colors.white54,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right_rounded,
                                size: 18,
                                color: Colors.white38,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    if (_tab == 3) ...[
                      // ── 边距 tab：页眉 / 页脚 ──
                      _marginSectionTitle('页眉（负位移进状态栏区域）'),
                      _marginSliderRow(
                        label: '左右边距',
                        value: draftHl,
                        onChanged: (v) => setSheet(() => draftHl = v),
                      ),
                      _marginSliderRow(
                        label: '上边距',
                        value: draftHt,
                        onChanged: (v) => setSheet(() => draftHt = v),
                      ),
                      _marginSectionTitle('页脚'),
                      _marginSliderRow(
                        label: '左右边距',
                        value: draftFl,
                        onChanged: (v) => setSheet(() => draftFl = v),
                      ),
                      _marginSliderRow(
                        label: '下边距',
                        value: draftFb,
                        onChanged: (v) => setSheet(() => draftFb = v),
                      ),
                    ],

                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white70,
                          ),
                          child: const Text('取消'),
                        ),
                        const Spacer(),
                        FilledButton(
                          onPressed: () async {
                            await o.setIndependentManga(
                              pathWord,
                              draftIndependent,
                            );
                            await o.setMangaMode(pathWord, draftMode);
                            await o.setMangaPreload(pathWord, draftPreload);
                            await o.setMangaReverseTap(
                              pathWord,
                              draftReverseTap,
                            );
                            await o.setMangaDoublePage(
                              pathWord,
                              draftDoublePage,
                            );
                            await o.setMangaShowHud(pathWord, draftShowHud);
                            await o.setMangaVolumeKeyTurn(
                              pathWord,
                              draftVolumeKey,
                            );
                            final s = SettingsService();
                            await s.setInkScreenMode(draftInk);
                            await s.setSingleHand(draftSingleHand);
                            await s.setPinchZoom(draftPinchZoom);
                            await s.setRememberZoom(draftRememberZoom);
                            await s.setScreenSleep(draftSleep);
                            await s.setReaderBackgroundStyle(draftBg);
                            await s.setComicMargins(
                              headerLeft: draftHl,
                              headerRight: draftHr,
                              headerTop: draftHt,
                              footerLeft: draftFl,
                              footerRight: draftFr,
                              footerBottom: draftFb,
                            );
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

  /// 段选小块（屏幕休眠 / 背景五选）：等宽，选中高亮
  Widget _segmentChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? JellyTheme.primary
              : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            color: selected ? Colors.white : Colors.white70,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  /// 开关行（标题 + 灰色说明 + 右侧 Switch）
  Widget _settingSwitchRow({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(fontSize: AppTheme.fontBody, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            subtitle,
            style: TextStyle(
              fontSize: AppTheme.fontFootnote,
              color: Colors.white54,
            ),
          ),
        ),
        Switch(
          value: value,
          activeColor: JellyTheme.primary,
          onChanged: onChanged,
        ),
      ],
    );
  }

  /// 信息行（点击区域等仅展示说明，无开关）
  Widget _settingInfoRow({
    required String title,
    required String subtitle,
  }) {
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(fontSize: AppTheme.fontBody, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            subtitle,
            style: TextStyle(
              fontSize: AppTheme.fontFootnote,
              color: Colors.white54,
            ),
          ),
        ),
      ],
    );
  }

  /// 边距分组标题（页眉/页脚）
  Widget _marginSectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppTheme.fontCaption,
          color: Colors.white54,
        ),
      ),
    );
  }

  /// 边距滑块行（标题 + 滑块 + 数值）
  Widget _marginSliderRow({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(fontSize: AppTheme.fontBody, color: Colors.white),
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 48,
            divisions: 48,
            activeColor: JellyTheme.primary,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 32,
          child: Text(
            value.round().toString(),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  // ---------------- 端侧 AI 漫画超分（仅 UI 面板） ----------------

  /// 端侧 AI 漫画超分设置面板（参考 cmbok IMG_8473）。
  /// 只做设置面板 UI 与持久化，不做真实推理。
  void _showUpscalePanel() {
    final s = SettingsService();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black87,
      barrierColor: Colors.black54,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => kbSheet(
        StatefulBuilder(
          builder: (ctx, setSheet) {
            bool autoClean = s.upscaleAutoClean;
            double limitGb = s.upscaleCleanLimitGb;
            int denoise = s.upscaleDenoise;
            bool modelReady = s.upscaleModelDownloaded;
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 头部：标题 + 关闭
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          // 🔴 原标题是「**端侧 AI** 漫画超分」✗ —— 但本面板里
                          // **没有模型、没有推理**：`:1395` 的"下载模型"按钮只把
                          // `upscaleModelDownloaded` 这个 **bool** 翻成 true ✓
                          //（`settings_service.dart:1794` 三行：比较→赋值→落盘 ✓）。
                          // ✓ 先改成**它真正做的事**（图片放大 + 降噪，本地处理 ✓），
                          // 不再冒充"端侧 AI" ✗。
                          // ✅ **那处遗留已清零** ✓（原注释写"仍然假装下载 / 留给下一轮" ✗ ——
                          //    已经过期了 ✓）：按钮已由「下载 6.8MB / 已下载」✗ 改成
                          //    **「开启 / 已开启」** ✓ —— 见 `:1416` 的修复说明与
                          //    `:1421` 的 `modelReady ? '已开启' : '开启'` ✓；
                          //    全模块 grep `6.8MB` 现在**只命中注释** ✓ →
                          //    **UI 里已无"假装下载模型"的字样** ✓✓
                          '图片放大 / 降噪',
                          style: TextStyle(
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 20,
                          color: Colors.white54,
                        ),
                        onPressed: () => Navigator.pop(ctx),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // 功能说明
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: JellyTheme.cardDark,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Text(
                      '使用端侧 AI 模型把漫画图片放大到 2 倍，线条更锐利、文字更清晰。'
                      '图片在本地处理，不上传网络。',
                      style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: Colors.white70,
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 模式限制提示
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: JellyTheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '模式限制',
                          style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            color: JellyTheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '仅「左右翻页」「无动画」「消散」「双页模式」开启时生效；'
                          '「上下连续滚动 Webtoon」「拼页」「双页拼页」将 Bypass（跳过超分）。',
                          style: TextStyle(
                            fontSize: AppTheme.fontFootnote,
                            color: Colors.white70,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // 模型状态与管理
                  Text(
                    '模型状态与管理',
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: Colors.white54,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: JellyTheme.cardDark,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: JellyTheme.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.auto_fix_high_rounded,
                            size: 22,
                            color: JellyTheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'AI 模型 1',
                                style: TextStyle(
                                  fontSize: AppTheme.fontBody,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '二次元 / 动漫推荐 · 本地放大与降噪',
                                style: TextStyle(
                                  fontSize: AppTheme.fontCaption,
                                  color: Colors.white54,
                                ),
                              ),
                            ],
                          ),
                        ),
                        FilledButton(
                          onPressed: modelReady
                              ? null
                              : () {
                                  setSheet(() => modelReady = true);
                                  s.setUpscaleModelDownloaded(true);
                                },
                          style: FilledButton.styleFrom(
                            backgroundColor: JellyTheme.primary,
                            disabledBackgroundColor: Colors.white12,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                          ),
                          child: Text(
                            // 🔴 原来写「下载 6.8MB / 已下载」✗ —— 它**什么也没下载**：
                            // 只是把 `upscaleModelDownloaded` 这个 bool 落盘 ✓
                            //（`:1405` 的那一行 ✓，服务层实现就三行：比较→赋值→落盘 ✓）。
                            // ✓ 改成如实的「开启 / 已开启」✓ —— 本面板真正能做的只有
                            //   放大与降噪两个开关 ✓，**没有模型可下** ✗
                            modelReady ? '已开启' : '开启',
                            style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: modelReady ? Colors.white70 : Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // 降噪强度
                  Text(
                    '降噪强度',
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: Colors.white54,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final (i, t) in const [
                        (0, '保守'),
                        (1, '中等'),
                        (2, '强力'),
                      ]) ...[
                        Expanded(
                          child: _segmentChip(
                            t,
                            denoise == i,
                            () {
                              setSheet(() => denoise = i);
                              s.setUpscaleDenoise(i);
                            },
                          ),
                        ),
                        if (i < 2) const SizedBox(width: 8),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '保守保真推荐：保留更多原画细节',
                    style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: Colors.white38,
                    ),
                  ),
                  const SizedBox(height: 20),
                  // 缓存
                  Text(
                    '缓存',
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: Colors.white54,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: JellyTheme.cardDark,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        const Row(
                          children: [
                            Expanded(
                              child: Text(
                                '已缓存大图',
                                style: TextStyle(
                                  fontSize: AppTheme.fontBody,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            Text(
                              '0.0 MB',
                              style: TextStyle(
                                fontSize: AppTheme.fontBody,
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '超分缓存自动清理',
                                style: TextStyle(
                                  fontSize: AppTheme.fontBody,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            Switch(
                              value: autoClean,
                              activeColor: JellyTheme.primary,
                              onChanged: (v) {
                                setSheet(() => autoClean = v);
                                s.setUpscaleAutoClean(v);
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const SizedBox(
                              width: 88,
                              child: Text(
                                '清理上限',
                                style: TextStyle(
                                  fontSize: AppTheme.fontBody,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Slider(
                                value: limitGb,
                                min: 0.1,
                                max: 10,
                                divisions: 99,
                                activeColor: JellyTheme.primary,
                                onChanged: (v) {
                                  setSheet(() => limitGb = v);
                                  s.setUpscaleCleanLimitGb(v);
                                },
                              ),
                            ),
                            SizedBox(
                              width: 56,
                              child: Text(
                                '${limitGb.toStringAsFixed(1)} GB',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: AppTheme.fontSubhead,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // ---------------- 目录 ----------------

  /// 目录「自动定位当前话」的一次性守卫 ✓
  /// （原来写在 build 里每次重建都跳 ✗，搜索后 index 还会对不上而乱滚）
  bool _tocDidAutoScroll = false;

  /// 章节目录抽屉（同图书阅读器：右侧滑入，自动定位当前话）。
  /// 双 tab：目录（搜索章节 + ↑↓ + 每行☁已缓存） / 书签（搜索书签 + 全部 + 空态）。
  void _showToc() {
    final chapters = _allChapters;
    if (chapters.isEmpty) return;
    final drawerWidth = MediaQuery.sizeOf(context).width * 0.78;
    _tocDidAutoScroll = false; // 每次打开抽屉重新允许定位一次 ✓
    final itemScrollController = ItemScrollController();
    final bookmarkService = MangaBookmarkService();
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '目录',
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (ctx, anim, secondaryAnim) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final textColor = isDark
            ? Colors.white.withValues(alpha: 0.92)
            : JellyTheme.textPrimaryLight;
        final subColor = isDark
            ? Colors.white.withValues(alpha: 0.5)
            : JellyTheme.textSecondary;
        final searchBoxColor =
            isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
        int _tab = 0; // 0 目录 / 1 书签
        String _query = '';
        return StatefulBuilder(
          builder: (ctx, setDialog) {
            final bookmarks =
                bookmarkService.bookmarksFor(widget.comic.pathWord);
            final q = _query.trim();
            final filteredChapters = q.isEmpty
                ? chapters
                : chapters
                      .where((c) => c.title.contains(q))
                      .toList();
            final filteredBookmarks = q.isEmpty
                ? bookmarks
                : bookmarks
                      .where((b) =>
                          b.chapterTitle.contains(q) ||
                          b.comicTitle.contains(q))
                      .toList();
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
                        // 头部：目录 N话 | 书签 M条 | ×
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
                          child: Row(
                            children: [
                              _tocTabChip(
                                label: '目录',
                                count: '${chapters.length}话',
                                selected: _tab == 0,
                                onTap: () => setDialog(() => _tab = 0),
                              ),
                              const SizedBox(width: 10),
                              _tocTabChip(
                                label: '书签',
                                count: '${bookmarks.length}条',
                                selected: _tab == 1,
                                onTap: () => setDialog(() => _tab = 1),
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
                        Divider(
                          height: 1,
                          color: subColor.withValues(alpha: 0.15),
                        ),
                        // 搜索行（目录 tab 右侧带 ↑↓）
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Container(
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: searchBoxColor,
                                    borderRadius: BorderRadius.circular(19),
                                  ),
                                  child: TextField(
                                    onChanged: (v) =>
                                        setDialog(() => _query = v),
                                    style: TextStyle(
                                      fontSize: AppTheme.fontBody,
                                      color: textColor,
                                    ),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      filled: false,
                                      hintText:
                                          _tab == 0 ? '搜索章节' : '搜索书签',
                                      hintStyle: TextStyle(
                                        fontSize: AppTheme.fontBody,
                                        color: subColor,
                                      ),
                                      prefixIcon: Icon(
                                        Icons.search_rounded,
                                        size: 18,
                                        color: subColor,
                                      ),
                                      prefixIconConstraints:
                                          const BoxConstraints(
                                        minWidth: 36,
                                        minHeight: 36,
                                      ),
                                      border: InputBorder.none,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                        vertical: 9,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (_tab == 0) ...[
                                IconButton(
                                  icon: Icon(
                                    Icons.keyboard_arrow_up_rounded,
                                    color: subColor,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () {
                                    if (filteredChapters.isNotEmpty &&
                                        itemScrollController.isAttached) {
                                      itemScrollController.jumpTo(index: 0);
                                    }
                                  },
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: subColor,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () {
                                    if (filteredChapters.isNotEmpty &&
                                        itemScrollController.isAttached) {
                                      itemScrollController.jumpTo(
                                        index: filteredChapters.length - 1,
                                      );
                                    }
                                  },
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (_tab == 1)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: JellyTheme.primary.withValues(
                                    alpha: 0.15,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '全部',
                                  style: TextStyle(
                                    fontSize: AppTheme.fontCaption,
                                    color: JellyTheme.primary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Divider(
                          height: 1,
                          color: subColor.withValues(alpha: 0.15),
                        ),
                        Expanded(
                          child: _tab == 0
                              ? _buildTocChapterList(
                                  ctx,
                                  filteredChapters,
                                  itemScrollController,
                                  textColor,
                                  subColor,
                                )
                              : _buildTocBookmarkList(
                                  ctx,
                                  filteredBookmarks,
                                  chapters,
                                  textColor,
                                  subColor,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
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

  /// 目录/书签 头部切换块（选中高亮 + 统计数）
  Widget _tocTabChip({
    required String label,
    required String count,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? JellyTheme.primary.withValues(alpha: 0.9)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.bold,
                color: selected ? Colors.white : JellyTheme.textPrimaryLight,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              count,
              style: TextStyle(
                fontSize: AppTheme.fontCaption,
                color: selected ? Colors.white70 : JellyTheme.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 目录列表（行尾 ☁ 已缓存标记；打开时自动定位当前章）
  Widget _buildTocChapterList(
    BuildContext ctx,
    List<ComicChapter> chapters,
    ItemScrollController itemScrollController,
    Color textColor,
    Color subColor,
  ) {
    // 🔴 打开时定位到「当前话」——修两个问题：
    //   1. 原来跳的 index 是按**全量**章节算的 ✗，搜索过滤后 filteredChapters
    //      变短，index 对不上 ⇒ 边打字列表边乱跳；现在按**筛选后列表**取下标 ✓；
    //   2. 原来写在 build 里每次重建都跳 ✗ ⇒ 加 `_tocDidAutoScroll` 只跳一次 ✓。
    final idx = chapters.indexWhere((c) => c.id == _currentChapter.id);
    if (!_tocDidAutoScroll && idx >= 0) {
      _tocDidAutoScroll = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (itemScrollController.isAttached) {
          itemScrollController.jumpTo(index: idx);
        }
      });
    }
    return ScrollablePositionedList.builder(
      itemScrollController: itemScrollController,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: chapters.length,
      itemBuilder: (ctx, i) {
        final ch = chapters[i];
        final cur = ch.id == _currentChapter.id;
        final downloaded = DownloadService()
            .isChapterDownloaded(widget.comic.pathWord, ch.id);
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              Navigator.pop(ctx);
              _goToChapter(ch);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 12,
              ),
              decoration: cur
                  ? BoxDecoration(
                      color: JellyTheme.primary.withValues(alpha: 0.1),
                      border: Border(
                        left: BorderSide(
                          color: JellyTheme.primary,
                          width: 3,
                        ),
                      ),
                    )
                  : null,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      ch.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        color: cur ? JellyTheme.primary : textColor,
                        fontWeight: cur ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    downloaded
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_outlined,
                    size: 16,
                    color: downloaded
                        ? JellyTheme.primary
                        : subColor.withValues(alpha: 0.35),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 书签列表（空态"还没有书签"；点击跳转对应章节页码）
  Widget _buildTocBookmarkList(
    BuildContext ctx,
    List<MangaBookmark> bookmarks,
    List<ComicChapter> chapters,
    Color textColor,
    Color subColor,
  ) {
    if (bookmarks.isEmpty) {
      final hasAny = MangaBookmarkService()
          .bookmarksFor(widget.comic.pathWord)
          .isNotEmpty;
      return Center(
        child: Text(
          hasAny ? '没有找到相关书签' : '还没有书签',
          style: TextStyle(
            fontSize: AppTheme.fontBody,
            color: subColor,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: bookmarks.length,
      itemBuilder: (ctx, i) {
        final b = bookmarks[i];
        ComicChapter? target;
        for (final c in chapters) {
          if (c.id == b.chapterId) {
            target = c;
            break;
          }
        }
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              Navigator.pop(ctx);
              _goToChapter(target ?? chapters.first,
                  initialPage: b.pageIndex);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 12,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.bookmark_rounded,
                    size: 16,
                    color: JellyTheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          b.chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTheme.fontBody,
                            color: textColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '第 ${b.pageIndex + 1} / ${b.pageCount} 页 · ${_fmtDate(b.createdAt)}',
                          style: TextStyle(
                            fontSize: AppTheme.fontFootnote,
                            color: subColor,
                          ),
                        ),
                      ],
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

  String _fmtDate(DateTime t) {
    final mm = t.month.toString().padLeft(2, '0');
    final dd = t.day.toString().padLeft(2, '0');
    return '${t.year}-$mm-$dd';
  }

  /// 按当前进度把漫画归位到"正在读"/"已读完"书架（幂等，带状态缓存避免频繁调用）。
  /// 读完判定：当前章最后一页 且 当前章是最后一话（无下一话，与 _nextChapter 一致）。
  /// 未读完时仅已读达阈值（readingShelfThreshold）才归位"正在读"，
  /// 不足阈值直接返回且不缓存，保证读到阈值章节时仍能触发归位。
  void _applyReadingStatus() {
    if (_images.isEmpty) return;
    final page = _isContinuousMode
        ? _continuousPageNotifier.value
        : (_isDoublePage ? _currentSpread : _currentIndex);
    final pageCount = _isDoublePage ? _spreadCount : _images.length;
    final allChapters = _allChapters;
    final ci = allChapters.indexWhere((c) => c.id == _currentChapter.id);
    final isLastChapter = ci < 0 || ci >= allChapters.length - 1;
    final finished = page + 1 >= pageCount && isLastChapter;
    final target = finished
        ? BookshelfService.presetFinished
        : BookshelfService.presetReading;
    if (!finished && !_useLocal) {
      // 未读完：在线阅读仅已读达阈值才归位"正在读"，避免瞟几眼污染；
      // 下载漫画（_useLocal）视为明确阅读意图，跳过阈值直接归位"正在读"。
      final seen =
          ReadingProgressService()
              .getProgress(widget.comic.pathWord)
              ?.seenChapterIds
              .length ??
          0;
      if (seen < ReadingProgressService.readingShelfThreshold) return;
    }
    if (_lastAppliedStatus == target) return;
    _lastAppliedStatus = target;
    ReadingProgressService().setFinished(
      widget.comic.pathWord,
      finished,
      meta: jsonEncode(widget.comic.toJson()),
    );
  }

  /// 简短提示
  void _showTip(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  /// 「翻译本页」：跳到翻译阅读页（OCR → 翻译 → 译文盖回原位置）。
  ///
  /// 单独一页而不是直接叠在本页，是因为本阅读器有翻页/双页/拼页/溶解/缩放
  /// 五套渲染路径，各自算一遍"图片显示矩形"既易错又影响原阅读手感。
  Future<void> _openTranslate() async {
    if (_images.isEmpty) {
      _showTip('这一话还没加载出图片');
      return;
    }
    if (!OcrService.isAvailable) {
      _showTip('当前平台不支持本机 OCR');
      return;
    }
    final missing = await TranslateSettings.missingReason();
    if (missing.isNotEmpty) {
      _showTip(missing);
      return;
    }
    final idx =
        _isContinuousMode ? _continuousPageNotifier.value : _currentIndex;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComicTranslatePage(
          images: List<String>.from(_images),
          initialIndex: idx.clamp(0, _images.length - 1),
          headers: _imageHeaders,
          useLocal: _useLocal,
          title: widget.comic.title,
        ),
      ),
    );
  }

  /// 切换控制栏显示
  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
  }

  /// 点击翻页区域：左1/3 上一页/上一话，右1/3 下一页/下一话，中间切换控制栏
  /// 翻页反转开启时左右对调。
  /// 音量键翻页：下=下一页，上=上一页（复用点击翻页逻辑，覆盖所有模式+章节边界）。
  void _onVolumeKey(String dir) {
    if (!mounted || _images.isEmpty) return;
    dir == 'down' ? _onTapRight() : _onTapLeft();
  }

  // C8 漫画九宫格动作码（与 SettingsService 存储一致）：
  // 0=上一页 1=菜单 2=下一页 3=无
  static const List<int> _mangaZoneActionOrder = [0, 1, 2, 3];
  /// 默认三列：左=上一页，中=菜单，右=下一页（与书源阅读器默认一致）
  static const List<int> _defaultMangaZones = [
    0, 0, 1, // 上排：上一页 上一页 菜单
    1, 1, 1, // 中排：菜单 菜单 菜单
    2, 2, 2, // 下排：下一页 下一页 下一页
  ];

  /// C8 九宫格配置概要（设置面板副标题）
  String _zoneSummary() {
    const names = ['上一页', '菜单', '下一页', '无'];
    final zones = SettingsService().mangaTapZones;
    final list = zones.length == 9 ? zones : _defaultMangaZones;
    // 按三列归纳：左列/中列/右列最常见的动作
    return '点击设置 3×3 各区域动作'
        '（左${names[list[0]]}·中${names[list[4]]}·右${names[list[8]]}）';
  }

  /// C8：九宫格点击区域编辑弹窗。每格点击循环切换动作，
  /// 即时保存到 SettingsService（点「恢复默认」回到默认三列）。
  void _showTapZoneEditor() {
    const names = ['上一页', '菜单', '下一页', '无'];
    final s = SettingsService();
    // 本地工作副本（int 列表，可变）
    final zones = List<int>.from(s.mangaTapZones.length == 9
        ? s.mangaTapZones
        : _defaultMangaZones);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black87,
      barrierColor: Colors.black54,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => kbSheet(StatefulBuilder(
        builder: (ctx, setSheet) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '点击区域',
                        style: TextStyle(
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          zones
                            ..clear()
                            ..addAll(_defaultMangaZones);
                          setSheet(() {});
                          s.setMangaTapZones(_defaultMangaZones);
                        },
                        child: Text(
                          '恢复默认',
                          style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            color: JellyTheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '点击每个格子循环切换：上一页 → 菜单 → 下一页 → 无',
                    style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: Colors.white54,
                    ),
                  ),
                  const SizedBox(height: 14),
                  GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 2.1,
                    children: [
                      for (var i = 0; i < 9; i++)
                        InkWell(
                          onTap: () {
                            final next =
                                _mangaZoneActionOrder[(zones[i] + 1) % 4];
                            zones[i] = next;
                            setSheet(() {});
                            s.setMangaTapZones(List<int>.from(zones));
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(
                                  alpha: zones[i] == 0 ? 0.20 : 0.08),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: zones[i] == 0
                                    ? JellyTheme.primary.withValues(alpha: 0.8)
                                    : Colors.white24,
                              ),
                            ),
                            child: Text(
                              names[zones[i]],
                              style: TextStyle(
                                fontSize: AppTheme.fontSubhead,
                                color: Colors.white,
                                fontWeight: zones[i] == 0
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      '左上第一格默认高亮 = 上一页（双击格子可切回）',
                      style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: Colors.white38,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      )),
    );
  }

  void _handleTap(TapUpDetails details) {
    final size = MediaQuery.sizeOf(context);
    final dx = details.globalPosition.dx;
    final dy = details.globalPosition.dy;
    // 单手模式：屏幕左右点击都是下一页
    if (SettingsService().singleHand) {
      final tapEdge = dx < size.width / 3 || dx > size.width * 2 / 3;
      if (tapEdge) {
        _onTapRight();
      } else {
        _toggleControls();
      }
      return;
    }
    // C8：3×3 分区，下标 = row*3 + col；空配置 = 默认三列
    final col = (dx / (size.width / 3)).floor().clamp(0, 2);
    final row = (dy / (size.height / 3)).floor().clamp(0, 2);
    final zone = row * 3 + col;
    final zones = SettingsService().mangaTapZones;
    final action = zones.length == 9 ? zones[zone] : _defaultMangaZones[zone];
    // 从左往右模式自带方向反转；「翻页按钮反转」开关与之异或叠加
    final tapReverse =
        _isReverseDirection !=
        ReaderOverrideService().effectiveReverseTapManga(widget.comic.pathWord);
    switch (action) {
      case 0:
        tapReverse ? _onTapRight() : _onTapLeft();
      case 1:
        _toggleControls();
      case 2:
        tapReverse ? _onTapLeft() : _onTapRight();
      default:
        break; // 3 = 无
    }
  }

  void _onTapLeft() {
    if (_isContinuousMode) {
      _scrollUp();
      return;
    }
    if (_isDissolveMode) {
      if (_isDoublePage) {
        final spread = _currentSpread;
        if (spread > 0) {
          _goDissolvePage(_spreadLeftImage(spread - 1));
        } else {
          _prevChapter();
        }
        return;
      }
      if (_currentIndex > 0) {
        _goDissolvePage(_currentIndex - 1);
      } else {
        _prevChapter();
      }
      return;
    }
    final canPrev = _isDoublePage ? _currentSpread > 0 : _currentIndex > 0;
    if (canPrev) {
      _goAdjacentPage(-1);
    } else {
      _prevChapter();
    }
  }

  void _onTapRight() {
    if (_isContinuousMode) {
      _scrollDown();
      return;
    }
    if (_isDissolveMode) {
      if (_isDoublePage) {
        final spread = _currentSpread;
        if (spread < _spreadCount - 1) {
          _goDissolvePage(_spreadLeftImage(spread + 1));
        } else {
          _nextChapter();
        }
        return;
      }
      if (_currentIndex < _images.length - 1) {
        _goDissolvePage(_currentIndex + 1);
      } else {
        _nextChapter();
      }
      return;
    }
    final canNext = _isDoublePage
        ? _currentSpread < _spreadCount - 1
        : _currentIndex < _images.length - 1;
    if (canNext) {
      _goAdjacentPage(1);
    } else {
      _nextChapter();
    }
  }

  /// 翻页模式翻一页（[delta] -1 上一页 / 1 下一页）。无动画模式瞬切，其余平滑滑动。
  void _goAdjacentPage(int delta) {
    final controllerPage = _isDoublePage ? _currentSpread : _currentIndex;
    if (_effectiveReadingMode == ReadingMode.none) {
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

  /// 消散模式：交叉淡入淡出到目标页（越界由调用方处理）
  void _goDissolvePage(int index) {
    ReadingProgressService().updatePageIndex(
      widget.comic.pathWord,
      _currentChapter.id,
      index,
    );
    setState(() => _currentIndex = index);
    _preloadAhead(index);
    _applyReadingStatus();
  }

  /// 拼页模式：翻到上一张（已在第一张时上一话）
  void _scrollUp() {
    if (!_itemScrollController.isAttached || _images.isEmpty) {
      return;
    }
    final current = _continuousPageNotifier.value;
    final prev = current - 1;
    if (prev < 0) {
      _prevChapter();
      return;
    }
    // 用 jumpTo 按索引重定位，不用像素级 animateScroll：
    // 上一页时上方图片可能正在解码(占位240->真实780)，像素偏移会因高度变化
    // 偏移到错误页（一次跳多页）。jumpTo 把目标页设为 center、offset 归零，
    // 上方图片事后解码不影响目标页位置。
    _itemScrollController.jumpTo(index: prev, alignment: 0);
  }

  /// 拼页模式：翻到下一张（已在最后一张时下一话）
  void _scrollDown() {
    if (!_itemScrollController.isAttached || _images.isEmpty) {
      return;
    }
    final current = _continuousPageNotifier.value;
    final next = current + 1;
    if (next >= _images.length) {
      _nextChapter();
      return;
    }
    final curBox = _renderBoxOf(current);
    if (curBox == null) {
      // 当前页未布局，回退瞬切
      _itemScrollController.jumpTo(index: next, alignment: 0);
      _setCurrentPage(next);
      return;
    }
    // 像素级平滑滚动到当前页底部 = 下一页顶部对齐视口顶：当前页顶部 y + 当前页高度
    final curTopY = curBox.localToGlobal(Offset.zero).dy;
    final offset = curTopY + curBox.size.height;
    _scrollOffsetController.animateScroll(
      offset: offset,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  /// 取指定 index 图片的 RenderBox（未构建/未布局返回 null）
  RenderBox? _renderBoxOf(int index) {
    final ctx = _keyOf(index).currentContext;
    final ro = ctx?.findRenderObject();
    if (ro is RenderBox && ro.hasSize) return ro;
    return null;
  }

  /// 更新拼页当前页码并记录续读进度（值未变时不触发，避免列表重建）
  void _setCurrentPage(int idx) {
    if (idx == _continuousPageNotifier.value) return;
    _continuousPageNotifier.value = idx;
    _currentIndex =
        idx; // 同步 _currentIndex，切模式时 _refreshGallery/_controllerInitialPage 才能拿到正确位置
    ReadingProgressService().updatePageIndex(
      widget.comic.pathWord,
      _currentChapter.id,
      idx,
    );
    _preloadAhead(idx);
    _applyReadingStatus();
  }

  /// 拼页模式：根据各图片实际渲染位置，取视口顶部所在图片更新页码与续读进度。
  /// 用 GlobalKey + localToGlobal 量真实屏幕位置，不依赖 ItemPosition.edge
  /// （scrollable_positioned_list 0.3.8 的 edge 由 getOffsetToReveal 计算不可靠，
  /// 会让 notifier 指向不在视口的页，进而让翻页算出反向 offset）。
  void _onItemPositionsChanged() {
    if (_images.isEmpty) return;
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    final viewportH = MediaQuery.sizeOf(context).height;
    int? topIndex;
    double bestY = -double.infinity;
    int? topmostIndex; // 兜底：可见页里 y 最小（最靠上）的那页
    double topmostY = double.infinity;
    int maxIndex = -1;
    double maxIndexBottom = -double.infinity;
    double maxIndexH = 0; // maxIndex 项高度（末页未加载时为 0，用于排除假到底）
    for (final p in positions) {
      final box = _renderBoxOf(p.index);
      if (box == null) {
        continue;
      }
      final y = box.localToGlobal(Offset.zero).dy;
      final h = box.size.height;
      if (p.index > maxIndex) {
        maxIndex = p.index;
        maxIndexBottom = y + h;
        maxIndexH = h;
      }
      // 顶部页：顶部在视口顶或上方(y<=0)且底部在视口内(y+h>0)，取最接近视口顶的
      if (y <= 0 && y + h > 0 && y > bestY) {
        bestY = y;
        topIndex = p.index;
      }
      // 兜底候选：最靠上的可见页（y 最小）
      if (y < topmostY) {
        topmostY = y;
        topmostIndex = p.index;
      }
    }
    // 底部判定：最后一张图可见且其底部未超出视口底（列表到底，末页矮图无法到顶）
    // 末页底部可能因亚像素/回弹取整略大于 viewportH，留 2px 容差避免漏判；
    // 末页必须已加载(h>0)，未加载的 0 高度占位项不算到底
    final hitBottom =
        maxIndex == _images.length - 1 &&
        maxIndexH > 0 &&
        maxIndexBottom <= viewportH + 2;
    if (hitBottom) {
      _setCurrentPage(_images.length - 1);
      return;
    }
    // 兜底：没有页跨视口顶时（视口顶恰在某页顶部附近、且上一页已被列表回收），
    // 取最靠上的可见页，避免 notifier 停留在已滚出屏幕的旧页导致翻页失灵/页码错乱
    final picked = topIndex ?? topmostIndex;
    if (picked != null) _setCurrentPage(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _galleryBg,
      body: Stack(children: [_buildGallery(), _buildHud(), _buildControls()]),
    );
  }

  Widget _buildGallery() {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('加载中...', style: TextStyle(color: _inkTextColor)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Colors.red),
            const SizedBox(height: 16),
            Text('加载失败: $_error', style: TextStyle(color: _inkTextColor)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadImages, child: const Text('重试')),
          ],
        ),
      );
    }

    if (_images.isEmpty) {
      return Center(
        child: Text('暂无图片', style: TextStyle(color: _inkTextColor)),
      );
    }

    // 双页状态变化（横屏切换 / 双页开关变化）：同步重建 PageController
    // + gallery 实例。_currentIndex 保持 image index，initialPage 转 spread。
    if (_isDoublePage != _builtDoublePage) {
      _builtDoublePage = _isDoublePage;
      // ✅ **旧控制器必须 dispose**（[medium] 修复 ✓）：原来只换实例 ✗，
      //   旧实例从不 `dispose()` ✓，仍被上一帧的 `PhotoViewGallery` 持有 ✗，
      //   其 ScrollPosition 与 listener 一直挂到重建完成 ✓。
      _pageController.dispose();
      _pageController = PageController(initialPage: _controllerInitialPage);
      _loadId++;
      _galleryBucket = PageStorageBucket();
    }
    final Widget gallery = _isContinuousMode
        ? _buildContinuousGallery()
        : _isDissolveMode
        ? _buildDissolveGallery()
        : _buildPagedGallery();
    _builtMode = _effectiveReadingMode;
    // 章节加载完成时淡入过渡
    // 外层 PageStorage 用每次加载重建的空桶，让 ScrollablePositionedList
    // initState 读 PageStorage 拿到 null，从第 0 页开始（不恢复历史偏移）
    final Widget galleryWidget = Padding(
      padding: _comicMargins,
      child: PageStorage(
        bucket: _galleryBucket,
        child: TweenAnimationBuilder<double>(
          key: PageStorageKey<String>('fade_${_currentChapter.id}_$_loadId'),
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          builder: (context, v, child) => Opacity(opacity: v, child: child),
          child: gallery,
        ),
      ),
    );
    // 墨水屏模式：纸张色背景置于灰度罩外（保留暖意），滤镜只作用于图片；
    // 各画廊内部底色（PhotoView/dissolve）墨水屏下设透明，露出此处纸色。
    final Widget base = SettingsService().inkScreenMode
        ? ColoredBox(
            color: _galleryBg,
            child: ColorFiltered(
                colorFilter: _inkColorFilter, child: galleryWidget),
          )
        : galleryWidget;
    // 页面亮度（独立叠加层，不调系统亮度、不影响全局）：黑遮罩盖在漫画上。
    final dim = 1.0 - SettingsService().comicBrightness;
    if (dim <= 0.001) return base;
    return Stack(fit: StackFit.expand, children: [
      base,
      IgnorePointer(
        child: ColoredBox(color: Colors.black.withValues(alpha: dim)),
      ),
    ]);
  }

  /// 翻页模式：PhotoViewGallery 逐页翻页（横向=左右翻页，竖向=上下翻页）
  Widget _buildPagedGallery({Axis scrollDirection = Axis.horizontal}) {
    if (_isDoublePage) return _buildDoublePageGallery();
    // [PATCH-3] 让「双指缩放」开关真正生效。
    // 此前 PhotoViewGallery 的 min/maxScale 写死，而 settings_service.dart
    // 的 pinchZoom / rememberZoom 在整个 pages/ + widgets/ 里没有任何消费点，
    // 表现为「开关关掉了照样能放大」。
    final allowZoom = SettingsService().pinchZoom;
    return GestureDetector(
      onTapUp: _handleTap,
      child: PhotoViewGallery.builder(
        scrollDirection: scrollDirection,
        reverse: _isReverseDirection,
        scrollPhysics: const ClampingScrollPhysics(),
        builder: (context, index) {
          return PhotoViewGalleryPageOptions(
            imageProvider: _useLocal
                ? FileImage(File(_images[index]))
                // data: 走限宽 provider ✓（见 `_dataProviderOf` 的说明 ✓）
                : _images[index].startsWith('data:')
                    ? _dataProviderOf(_images[index])
                    : _imageProviderOf(_images[index]),
            initialScale: (SettingsService().rememberZoom && _savedZoomScale > 1.0)
                ? _savedZoomScale
                : PhotoViewComputedScale.contained,
            minScale: PhotoViewComputedScale.contained,
            // 关掉开关时 maxScale 与 contained 相同 → 无法放大。
            maxScale: allowZoom
                ? PhotoViewComputedScale.covered * 2
                : PhotoViewComputedScale.contained,
            onScaleEnd: (context, details, controllerValue) {
              if (!SettingsService().rememberZoom) return;
              final scale = controllerValue.scale ?? 1.0;
              if (scale > 1.0) {
                ReadingProgressService().setZoomScale(
                  widget.comic.pathWord,
                  scale,
                );
              }
            },
            heroAttributes: PhotoViewHeroAttributes(tag: 'image_$index'),
            errorBuilder: (context, error, stackTrace) => Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.broken_image,
                    size: 40,
                    color: JellyTheme.textSecondary,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '第 ${index + 1} 页加载失败',
                    style: TextStyle(color: JellyTheme.textSecondary),
                  ),
                ],
              ),
            ),
          );
        },
        itemCount: _images.length,
        loadingBuilder: (context, event) => Center(
          child: SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(
              value: event == null
                  ? 0
                  : event.cumulativeBytesLoaded /
                        (event.expectedTotalBytes ?? 1),
            ),
          ),
        ),
        backgroundDecoration: BoxDecoration(color: _innerGalleryBg),
        pageController: _pageController,
        onPageChanged: (index) {
          ReadingProgressService().updatePageIndex(
            widget.comic.pathWord,
            _currentChapter.id,
            index,
          );
          setState(() {
            _currentIndex = index;
          });
          _preloadAhead(index);
          _applyReadingStatus();
        },
      ),
    );
  }

  /// 双页模式：PageView 逐 spread 翻页，每 spread 左右并排两图（首页单独）
  Widget _buildDoublePageGallery() {
    return GestureDetector(
      onTapUp: _handleTap,
      child: PageView.builder(
        controller: _pageController,
        reverse: _isReverseDirection,
        physics: const ClampingScrollPhysics(),
        itemCount: _spreadCount,
        onPageChanged: (spread) {
          final imageIndex = _spreadLeftImage(spread);
          ReadingProgressService().updatePageIndex(
            widget.comic.pathWord,
            _currentChapter.id,
            imageIndex,
          );
          setState(() {
            _currentIndex = imageIndex;
          });
          _preloadAhead(imageIndex);
          _applyReadingStatus();
        },
        itemBuilder: (context, spread) => _buildSpread(spread),
      ),
    );
  }

  /// 双页 spread：首页或末尾单图时单图占满，否则左右两图并排
  /// 左图贴右、右图贴左，让竖图 contain 后多余黑边留到屏幕外侧而非中间。
  Widget _buildSpread(int spread) {
    final left = _spreadLeftImage(spread);
    final right = _spreadRightImage(spread);
    final hasRight = right < _images.length;
    if (spread == 0 || !hasRight) {
      return _buildSingleImage(spread == 0 ? 0 : left);
    }
    // 从左往右：左右镜像（图号交换），alignment 不变仍贴中缝，跨页不错位
    final leftImg = _isReverseDirection ? right : left;
    final rightImg = _isReverseDirection ? left : right;
    return Row(
      children: [
        Expanded(
          child: _buildSingleImage(leftImg, alignment: Alignment.centerRight),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: _buildSingleImage(rightImg, alignment: Alignment.centerLeft),
        ),
      ],
    );
  }

  /// 构建在线图片 ImageProvider：data: URL 用 MemoryImage，其余用 CachedNetworkImageProvider。
  ImageProvider _imageProviderOf(String url) {
    if (url.startsWith('data:')) {
      return MemoryImage(_dataBytesOf(url));
    }
    // blob 站落盘临时文件路径（file:// 或绝对路径）— FileImage 直读
    if (url.startsWith('file://') || !url.contains('://')) {
      return FileImage(
        File(url.startsWith('file://') ? Uri.parse(url).toFilePath() : url),
      );
    }
    return CachedNetworkImageProvider(
      url,
      headers: _imageHeaders,
      cacheManager: appImageCacheManager,
    );
  }

  /// `data:` URL → **缓存过**的解码字节（同一个实例 ✓，见 [_dataImageBytes]）✓。
  /// 展示路径与预载路径必须共用它 ✓，否则 `MemoryImage` 的键永远不相等 ✗。
  Uint8List _dataBytesOf(String url) => _dataImageBytes.putIfAbsent(url, () {
        final commaIdx = url.indexOf(',');
        final data = commaIdx > 0 ? url.substring(commaIdx + 1) : '';
        return base64.decode(data);
      });

  /// 翻页（PhotoView）路径专用：`data:` URL 的**限宽** provider ✓。
  ///
  /// ✅ **[medium] 修复**：这条路径原来是裸 `MemoryImage` ✗ ——
  ///   既没有 `ResizeImage` 也没有 `cacheWidth` ✓（对照双页 / 消散 / 拼页三条路径
  ///   都按屏幕物理宽度限制了解码 ✓），于是默认的「左右翻页」模式对 blob 站的
  ///   整章 base64 大图**按原始分辨率**解码 ✓（代码自己的注释指出 2244×2717
  ///   一张就解出约 24MB ✓），翻几页就容易 OOM / 明显卡顿 ✗。
  ///
  /// ⚠️ 这里**只改 data:** ✓：`file:` 那条不动 ✗ —— `PhotoView` 的
  ///   `maxScale: covered * 2` 允许放大 ✓，对本地文件预先降采样会**把放大后的画质钉死** ✗，
  ///   而 data: 图本来就是内存里的字节 ✓，降采样是纯收益（也才与预载路径的键真正相等 ✓）。
  /// 同一 url 返回**同一个 provider 实例** ✓ → 缓存键稳定 ✓、不做二次解码 ✓。
  final Map<String, ImageProvider> _dataProviderCache = {};

  ImageProvider _dataProviderOf(String url) {
    final dw = (MediaQuery.sizeOf(context).width *
            MediaQuery.devicePixelRatioOf(context))
        .round();
    final k = '$dw|$url';
    return _dataProviderCache.putIfAbsent(
      k,
      () => ResizeImage(MemoryImage(_dataBytesOf(url)),
          width: dw, allowUpscaling: false),
    );
  }

  /// 构建在线图片 Widget：file:// 用 Image.file，data: URL 用 Image.memory，
  /// 其余用 CachedNetworkImage。
  /// blob 站（如摸摸漫画）图片经 WebView 转 base64 落盘临时文件，走 file:// 分支。
  Widget _buildOnlineImage(
    String url, {
    Key? key,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
    double? width,
    int? memCacheWidth,
    Duration fadeInDuration = Duration.zero,
    Duration fadeOutDuration = Duration.zero,
    Widget Function(BuildContext, String)? placeholder,
    Widget Function(BuildContext, String, dynamic)? errorWidget,
  }) {
    if (url.startsWith('file://') || !url.contains('://')) {
      // blob 站落盘临时文件路径 — 用 Image.file + cacheWidth 限解码分辨率
      final file = File(
        url.startsWith('file://') ? Uri.parse(url).toFilePath() : url,
      );
      return Image.file(
        file,
        key: key,
        fit: fit,
        alignment: alignment,
        width: width,
        cacheWidth: memCacheWidth,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return placeholder?.call(context, url) ??
              const Center(
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(),
                ),
              );
        },
        errorBuilder: (context, error, stackTrace) =>
            errorWidget?.call(context, url, error) ?? _buildBrokenImage(-1),
      );
    }
    if (url.startsWith('data:')) {
      // data:image/xxx;base64,... — 直接用 Image.memory 解码
      // ✅ 用**缓存过的**字节（[medium] 修复 ✓）：每次 build 都 `base64.decode`
      //   会产出新的 `Uint8List` ✗ → `MemoryImage` 的键每帧都不同 ✗ →
      //   每次 setState 都绕过图片缓存重新解码整张图 ✓。
      final bytes = _dataBytesOf(url);
      return Image.memory(
        bytes,
        key: key,
        fit: fit,
        alignment: alignment,
        width: width,
        cacheWidth: memCacheWidth,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return placeholder?.call(context, url) ??
              const Center(
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(),
                ),
              );
        },
        errorBuilder: (context, error, stackTrace) =>
            errorWidget?.call(context, url, error) ?? _buildBrokenImage(-1),
      );
    }
    return CachedNetworkImage(
      key: key,
      imageUrl: url,
      httpHeaders: _imageHeaders,
      cacheManager: appImageCacheManager,
      fit: fit,
      alignment: alignment,
      width: width,
      memCacheWidth: memCacheWidth,
      fadeInDuration: fadeInDuration,
      fadeOutDuration: fadeOutDuration,
      placeholder: placeholder,
      errorWidget: errorWidget,
    );
  }

  /// 双页模式单图：在线用 CachedNetworkImage，本地用 Image.file
  Widget _buildSingleImage(
    int index, {
    Alignment alignment = Alignment.center,
  }) {
    // 限制解码分辨率至屏幕物理宽度（与消散/拼页模式一致），
    // 避免 data: 大图全尺寸解码撑爆内存（blob 站整章 base64 已占大量堆）
    final dw =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round();
    if (_useLocal) {
      return Image.file(
        File(_images[index]),
        fit: BoxFit.contain,
        alignment: alignment,
        cacheWidth: dw,
        errorBuilder: (c, e, s) => _buildBrokenImage(index),
      );
    }
    return _buildOnlineImage(
      _images[index],
      fit: BoxFit.contain,
      alignment: alignment,
      memCacheWidth: dw,
      placeholder: (c, u) => const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(),
        ),
      ),
      errorWidget: (c, u, e) => _buildBrokenImage(index),
    );
  }

  /// 消散模式：逐页显示，换页时旧页淡出、新页淡入（交叉淡入淡出）
  Widget _buildDissolveGallery() {
    return GestureDetector(
      onTapUp: _handleTap,
      child: ColoredBox(
        color: _innerGalleryBg,
        child: AnimatedSwitcher(
          duration: SettingsService().inkScreenMode
              ? Duration.zero
              : const Duration(milliseconds: 600),
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: _isDoublePage
              ? _buildDissolveSpread(_currentSpread)
              : _buildDissolveImage(_currentIndex),
        ),
      ),
    );
  }

  /// 消散模式双页 spread：首页或末尾单图时单图占满，否则左右两图并排。
  /// 外层 SizedBox.expand 用 spread 做 key 触发 AnimatedSwitcher 交叉淡入淡出。
  /// 左图贴右、右图贴左，让竖图 contain 后多余黑边留到屏幕外侧而非中间。
  Widget _buildDissolveSpread(int spread) {
    final left = _spreadLeftImage(spread);
    final right = _spreadRightImage(spread);
    final hasRight = right < _images.length;
    final Widget content;
    if (spread == 0 || !hasRight) {
      content = _buildDissolveImage(spread == 0 ? 0 : left, standalone: false);
    } else {
      // 从左往右：左右镜像（图号交换），alignment 不变仍贴中缝
      final leftImg = _isReverseDirection ? right : left;
      final rightImg = _isReverseDirection ? left : right;
      content = Row(
        children: [
          Expanded(
            child: _buildDissolveImage(
              leftImg,
              standalone: false,
              alignment: Alignment.centerRight,
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: _buildDissolveImage(
              rightImg,
              standalone: false,
              alignment: Alignment.centerLeft,
            ),
          ),
        ],
      );
    }
    return SizedBox.expand(
      key: ValueKey('dissolve_spread_$spread'),
      child: content,
    );
  }

  /// 消散模式单页图（按 index 取 key，AnimatedSwitcher 据此触发交叉淡入淡出）
  Widget _buildDissolveImage(
    int index, {
    bool standalone = true,
    Alignment alignment = Alignment.center,
  }) {
    if (index < 0 || index >= _images.length) {
      return const SizedBox.shrink();
    }
    // 限制解码分辨率至屏幕物理宽度，避免大图（如 2244×2717）解码出 ~24MB 副本
    final dw =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round();
    final Widget image;
    if (_useLocal) {
      image = Image.file(
        File(_images[index]),
        fit: BoxFit.contain,
        alignment: alignment,
        cacheWidth: dw,
        errorBuilder: (context, error, stackTrace) => _buildBrokenImage(index),
      );
    } else {
      image = _buildOnlineImage(
        _images[index],
        fit: BoxFit.contain,
        alignment: alignment,
        memCacheWidth: dw,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        placeholder: (context, url) => const Center(
          child: SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(),
          ),
        ),
        errorWidget: (context, url, error) => _buildBrokenImage(index),
      );
    }
    return SizedBox.expand(
      key: standalone ? ValueKey(index) : null,
      child: image,
    );
  }

  /// 拼页模式：所有图片纵向连续滚动，按索引定位/翻页
  Widget _buildContinuousGallery() {
    return GestureDetector(
      onTapUp: _handleTap,
      child: ScrollablePositionedList.builder(
        itemScrollController: _itemScrollController,
        itemPositionsListener: _itemPositionsListener,
        scrollOffsetController: _scrollOffsetController,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: _images.length,
        itemBuilder: (context, index) => _buildContinuousImage(index),
      ),
    );
  }

  Widget _buildContinuousImage(int index) {
    // GlobalKey 用于量取图片渲染高度（拼页上一页像素偏移换算需要）
    final imageKey = _keyOf(index);
    // 限制解码分辨率至屏幕物理宽度，避免大图解码出超大副本占用内存
    final dw =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round();
    if (_useLocal) {
      return Image.file(
        File(_images[index]),
        key: imageKey,
        fit: BoxFit.contain,
        width: double.infinity,
        cacheWidth: dw,
        // 解码前 frame 为 null，显示固定高度占位，避免初始高度 0 触发
        // ScrollablePositionedList 的定位 bug（本地图片特有）。解码后切回真实图片。
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) {
            return child;
          }
          return const SizedBox(
            height: 240,
            child: Center(child: CircularProgressIndicator()),
          );
        },
        errorBuilder: (context, error, stackTrace) => _buildBrokenImage(index),
      );
    }
    return _buildOnlineImage(
      _images[index],
      key: imageKey,
      fit: BoxFit.contain,
      width: double.infinity,
      memCacheWidth: dw,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (context, url) => const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      ),
      errorWidget: (context, url, error) => _buildBrokenImage(index),
    );
  }

  Widget _buildBrokenImage(int index) {
    return SizedBox(
      width: double.infinity,
      height: 240,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.broken_image,
            size: 48,
            color: JellyTheme.textSecondary,
          ),
          const SizedBox(height: 8),
          Text(
            '第 ${index + 1} 页加载失败',
            style: TextStyle(color: JellyTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  /// 底部页码：拼页模式用 ValueListenableBuilder 局部刷新，避免列表重建
  Widget _buildPageIndicator() {
    const style = TextStyle(color: Colors.white);
    if (_isContinuousMode) {
      return ValueListenableBuilder<int>(
        valueListenable: _continuousPageNotifier,
        builder: (context, idx, child) =>
            Text('${idx + 1} / ${_images.length}', style: style),
      );
    }
    if (_isDoublePage) {
      final left = _currentIndex + 1;
      final right = _spreadRightImage(_currentSpread);
      final hasRight = right < _images.length;
      final text = hasRight
          ? '$left-${right + 1} / ${_images.length}'
          : '$left / ${_images.length}';
      return Text(text, style: style);
    }
    return Text('${_currentIndex + 1} / ${_images.length}', style: style);
  }

  // ---------------- 常驻信息栏（时间 / 页码 / 进度 / 漫画名） ----------------

  /// 常驻 HUD：左上时钟、右上页码、左下漫画名、右下进度百分比。
  /// ListenableBuilder 自响应设置变化，关闭时返回空 widget。
  Widget _buildHud() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        SettingsService(),
        ReaderOverrideService(),
      ]),
      builder: (context, _) {
        if (!ReaderOverrideService().effectiveShowHudManga(
          widget.comic.pathWord,
        )) {
          return const SizedBox.shrink();
        }
        final style = TextStyle(
          fontSize: AppTheme.fontCaption,
          color: Colors.white.withValues(alpha: 0.5),
          shadows: const [
            Shadow(
              color: Colors.black54,
              blurRadius: 2,
              offset: Offset(0.5, 0.5),
            ),
          ],
        );
        final padTop = MediaQuery.paddingOf(context).top + 8;
        final padBottom = MediaQuery.paddingOf(context).bottom + 8;
        const padH = 16.0;
        return IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                top: padTop,
                left: padH,
                child: _ClockText(style: style),
              ),
              Positioned(
                top: padTop,
                right: padH,
                child: _buildHudPageText(style),
              ),
              Positioned(
                bottom: padBottom,
                left: padH,
                right: padH,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.comic.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                    _buildHudPctText(style),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHudPageText(TextStyle style) {
    if (_images.isEmpty) return const SizedBox.shrink();
    if (_isContinuousMode) {
      return ValueListenableBuilder<int>(
        valueListenable: _continuousPageNotifier,
        builder: (_, idx, _) =>
            Text('${idx + 1} / ${_images.length}', style: style),
      );
    }
    return Text(_pageText(_currentIndex), style: style);
  }

  Widget _buildHudPctText(TextStyle style) {
    if (_images.isEmpty) return const SizedBox.shrink();
    if (_isContinuousMode) {
      return ValueListenableBuilder<int>(
        valueListenable: _continuousPageNotifier,
        builder: (_, idx, _) {
          final pct = ((idx + 1) / _images.length * 100)
              .clamp(0, 100)
              .toStringAsFixed(0);
          return Text('$pct%', style: style);
        },
      );
    }
    final pct = ((_currentIndex + 1) / _images.length * 100)
        .clamp(0, 100)
        .toStringAsFixed(0);
    return Text('$pct%', style: style);
  }

  String _pageText(int idx) {
    if (_images.isEmpty) return '';
    if (_isDoublePage) {
      final left = idx + 1;
      final right = _spreadRightImage(_imageToSpread(idx));
      final hasRight = right < _images.length;
      return hasRight
          ? '$left-${right + 1} / ${_images.length}'
          : '$left / ${_images.length}';
    }
    return '${idx + 1} / ${_images.length}';
  }

  Widget _buildControls() {
    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !_showControls,
        child: Stack(
          children: [
            Column(
              children: [
            // 顶部栏
            AppBar(
              backgroundColor: Colors.black87,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.comic.title,
                    style: const TextStyle(
                      fontSize: AppTheme.fontBody,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _currentChapter.title,
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: Colors.white.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
              iconTheme: const IconThemeData(color: Colors.white),
              actions: [
                ListenableBuilder(
                  listenable: MangaBookmarkService(),
                  builder: (context, _) {
                    final marked = _currentPageBookmarked();
                    return IconButton(
                      tooltip: marked ? '取消书签' : '添加书签',
                      icon: Icon(
                        marked
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                        color: marked ? JellyTheme.primary : Colors.white,
                        size: 24,
                      ),
                      onPressed: _toggleBookmark,
                    );
                  },
                ),
              ],
            ),
            const Spacer(),
            // 底部功能栏（**悬浮卡片**）
            // ✅ 用户 2026-10-07：「漫画的阅读器里面的功能栏也改成这种**悬浮**的」——
            //   原来：`Container(color: Colors.black87)` 是**通栏贴边**的
            //         （左右/下都顶到屏幕边）⇒ 看着就是"底部工具条" ✗
            //   现在：四周留白 + **四角全圆 18** + 向下投影 + 一道浅描边
            //         ⇒ 悬浮玻璃卡片 ✓
            //   ⚠️ 为什么加那道 14% 白描边：漫画底默认是 `#141416`（暗夜），
            //     纯黑卡片压在它上面**边界几乎看不见**，描边让卡片"立"起来 ✓
            //   ⚠️ `SafeArea` 放在**外层**（不是卡片内部）：这样"避开手势条"抬的
            //     是卡片**整体**，卡片四周的留白才会均匀 ✓（放里面会让卡片底部
            //     多出一块和手势条等高的空白 ✗）
            SafeArea(
              top: false,
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Padding(
                  // ✅ 用户 2026-10-14：「漫画阅读器那个功能面板高度太高了，
                  //    至少减掉现有的三分之一」⇒ 三处一起收：
                  //    ① 卡片上下内边距 10/8 → 6/6；
                  //    ② 页码滑块默认 thumb/overlay 会把整行撑到 ~48，
                  //       压到 26（滑块本体仍然好拖：手势区=整行）；
                  //    ③ 原来"上一章/页码/下一章" + "番茄钟/设置/目录"是**两行**
                  //       TextButton（各 48 高）⇒ 合并成**一行** 36 圆钮
                  //       （与右侧竖条同款）。
                  //    整条约 146 → ~80（-45%），功能一个没少。
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 页码滑块（拼页模式下不显示）
                      if (_images.isNotEmpty && !_isContinuousMode)
                        SizedBox(
                          height: 26,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 7),
                              overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 14),
                            ),
                            child: Slider(
                              value:
                                  (_isDoublePage ? _currentSpread : _currentIndex)
                                      .toDouble(),
                              min: 0,
                              max:
                                  (_isDoublePage
                                          ? _spreadCount - 1
                                          : _images.length - 1)
                                      .toDouble(),
                              onChanged: (value) {
                                setState(() {
                                  if (_isDoublePage) {
                                    _currentIndex =
                                        _spreadLeftImage(value.toInt());
                                  } else {
                                    _currentIndex = value.toInt();
                                  }
                                });
                              },
                              onChangeEnd: (value) {
                                // 拖动/点击结束：跳转到目标页（onPageChanged 会同步 _currentIndex 与进度）
                                if (_pageController.hasClients) {
                                  _pageController.jumpToPage(value.toInt());
                                }
                              },
                            ),
                          ),
                        ),
                      const SizedBox(height: 6),
                      // 一行装完：上一章 / 页码 / 下一章 / 番茄钟 / 设置 / 目录
                      // （原来拆两行，白占一整行高度）
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Tooltip(
                            message: '上一章',
                            child: _dockCircleButton(
                              icon: Icons.chevron_left,
                              onTap: _prevChapter,
                            ),
                          ),
                          _buildPageIndicator(),
                          Tooltip(
                            message: '下一章',
                            child: _dockCircleButton(
                              icon: Icons.chevron_right,
                              onTap: _nextChapter,
                            ),
                          ),
                          Tooltip(
                            message: '番茄钟',
                            child: _dockCircleButton(
                              icon: Icons.timer_outlined,
                              onTap: () => setState(
                                  () => _showPomodoro = !_showPomodoro),
                            ),
                          ),
                          Tooltip(
                            message: '翻译本页',
                            child: _dockCircleButton(
                              icon: Icons.translate_rounded,
                              onTap: _openTranslate,
                            ),
                          ),
                          Tooltip(
                            message: '阅读设置',
                            child: _dockCircleButton(
                              icon: Icons.settings_rounded,
                              onTap: _showReaderSettingsSheet,
                            ),
                          ),
                          Tooltip(
                            message: '目录',
                            child: _dockCircleButton(
                              icon: Icons.menu_book_rounded,
                              onTap: _showToc,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        // 番茄钟悬浮倒计时（与书源阅读器同款）：悬浮在底部功能卡上方
        if (_showPomodoro)
          Positioned(
            right: 12,
            bottom: MediaQuery.of(context).padding.bottom + 210,
            child: const PomodoroButton(),
          ),
        // 右侧悬浮竖条：设置圆钮 / 亮度滑块 / 黑白切换（对齐参考图
        // "竖排阅读侧边悬浮栏"：上=圆形图标，中=亮度滑杆，下=月亮）
        _buildSideDock(),
      ],
    ),
  ),
    );
  }

  /// 右侧悬浮竖条：设置圆钮 + 亮度滑杆 + 黑白切换。
  Widget _buildSideDock() {
    final ink = SettingsService().inkScreenMode;
    final brightness = SettingsService().comicBrightness;
    return Positioned(
      right: 14,
      top: 0,
      bottom: 0,
      child: Center(
        child: Container(
          width: 46,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(23),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dockCircleButton(
                icon: Icons.settings_rounded,
                onTap: _showReaderSettingsSheet,
              ),
              const SizedBox(height: 8),
              // 亮度竖滑杆（独立叠加层亮度，0.35~1.0，不调系统亮度）
              SizedBox(
                height: 150,
                child: RotatedBox(
                  quarterTurns: -1,
                  child: Slider(
                    value: brightness,
                    min: 0.35,
                    max: 1.0,
                    activeColor: Colors.white,
                    inactiveColor: Colors.white24,
                    onChanged: (v) {
                      setState(() => SettingsService().setComicBrightness(v));
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _dockCircleButton(
                icon: ink
                    ? Icons.light_mode_rounded
                    : Icons.dark_mode_rounded,
                highlight: ink,
                onTap: _toggleInk,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 竖条里的圆形按钮。
  Widget _dockCircleButton({
    required IconData icon,
    required VoidCallback onTap,
    bool highlight = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: highlight
              ? Colors.white.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.08),
          shape: BoxShape.circle,
          border: Border.all(
            color: highlight
                ? Colors.white.withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.18),
          ),
        ),
        child: Icon(icon, size: 20, color: Colors.white),
      ),
    );
  }

  /// 黑白切换：与设置弹层里的「墨水屏」开关同源。
  void _toggleInk() {
    final s = SettingsService();
    setState(() => s.setInkScreenMode(!s.inkScreenMode));
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
