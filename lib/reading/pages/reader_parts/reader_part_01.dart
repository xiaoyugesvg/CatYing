part of '../book_source_reader_page.dart';

mixin _ReaderPart01 on _BookSourceReaderPageState {
@override
  /// 关闭阅读设置面板。
  ///
  /// 用户 2026-10-21：面板里的选项**点了就生效**，不再需要「确认」——
  /// 所以底栏整个去掉了，这里只负责关闭（改动早已写入 `_rs` 并落盘）。
  void _closeSettingsPanel() {
    setState(() => _showSettingsPanel = false);
    _scheduleSavePrefs();
  }

@override
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

@override
  /// 标题的自动屏幕系数：窄屏缩小、宽屏不放大（0.82 ~ 1.0）。
  ///
  /// 以 400 逻辑像素为基准（iPhone 14/15 ≈ 390、Pro Max ≈ 430）。
  /// 只缩不放 —— 大屏本来就有空间，放大反而更容易顶到页眉。
  double get _autoTitleScale {
    final w = _viewport.width;
    if (w <= 0) return 1.0;
    return (w / 400).clamp(0.82, 1.0).toDouble();
  }

@override
  /// HTML 章节标题的基准字号（CSS 里 `1em` 的实际大小）。
  ///
  /// 取**正文字号**而不是样式的 `titleFontSize`：CSS 的 em 本来就是相对正文，
  /// 而 db 的 titleSize 语义是"默认标题字号"（常为 25~30），一旦拿它当 em 基准，
  /// 内置样式里 `2.6em` 就会被放大到离谱。再乘自动屏宽系数 + 手动缩放。
  double get _titleHtmlBase =>
      _fontSize * _autoTitleScale * _titleScale;

@override
  /// 默认（无 HTML）标题字号：保持「正文 +3」的既有观感，但同样吃手动缩放。
  double get _defaultTitleFontSize =>
      (_titleFontSize ?? _fontSize + 3) * _titleScale;

@override
  /// HTML 标题里**写死 px 的字号/内衬**的缩放系数。
  ///
  /// px 是绝对值，不像 em 那样跟着正文字号走 ⇒ 换手机尺寸后完全不变。
  /// 这里只乘屏幕自适应 + 用户手动缩放（不含「标题字号」设置，那是 em 的基准）。
  double get _titlePxScale => _autoTitleScale * _titleScale;

@override
  /// 是否生成章标题块。
  ///
  /// 默认隐藏（正文里已经有章名）；但选了自定义「标题样式」时必须画 ——
  /// 那套版式（仙鹤插画 / 药丸）本身就是靠标题块呈现的。
  bool get _showChapterTitle =>
      !_hideRepeatTitle || _chapterTitleSource.trim().isNotEmpty;

@override
  /// 分页块列表里「段落 pi」与「块下标」的偏移：
  /// 有章标题块时是 1，隐藏标题（`_hideRepeatTitle`）时不生成标题块 ⇒ 0。
  /// 两处（`_pageBody` / `_pageOfParagraph`）与 `_paginate` 必须用同一个偏移，
  /// 否则书签 / 划线会落到上一段。
  int get _blockOffset => _showChapterTitle ? 1 : 0;

@override
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

@override
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
    // 深底（夜间 / 深色壁纸 / 深色自选图）⇒ 一律浅字，
    // 否则会出现「深图 + 深字」几乎看不见（原来只看内置壁纸的 _bgImageDark）
    if (_paperIsDark) return const Color(0xFFE2E2E2);
    return _BookSourceReaderPageState._bgs[_bgIndex][1];
  }

@override
  /// 当前模式下真正生效的自选背景图（夜间优先夜图）
  String? get _activeFileBgPath =>
      _bgIndex == 5 ? (_customBgPathNight ?? _customBgPath) : _customBgPath;

@override
  /// 当前模式下真正生效的壁纸 asset（夜间优先夜版）
  String? get _activeBgAsset =>
      _bgIndex == 5 ? (_bgImageAssetNight ?? _bgImageAsset) : _bgImageAsset;

@override
  /// 当前模式是否有图片背景（自选图或内置壁纸，含夜间版）
  bool get _hasImageBg {
    final path = _activeFileBgPath;
    return (path != null && File(path).existsSync()) || _activeBgAsset != null;
  }

@override
  /// 屏幕顶部安全区（正文层现在是整屏，文字内衬要用它）
  double get _safeTop {
    final mq = MediaQuery.of(context);
    return mq.padding.top > 0 ? mq.padding.top : mq.viewPadding.top;
  }

@override
  /// 屏幕底部安全区（Home 指示条）
  double get _safeBottom {
    final mq = MediaQuery.of(context);
    return mq.padding.bottom > 0 ? mq.padding.bottom : mq.viewPadding.bottom;
  }

@override
  /// 当前纸面是否偏深（翻页纸背 / 番茄钟玻璃面板 / 状态栏图标用）
  bool get _paperIsDark =>
      _bgIndex == 5 ||
      // 有图片背景时看**图片实测亮度**（内置壁纸分析过 `_bgImageDark`，
      // 自选文件分析过 `_fileBgDark`）：日间选深色自选图也要换浅字/浅图标，
      // 不能因为"不是夜间"就一律当浅色纸。
      (_bgImageDark ?? _fileBgDark ?? false) ||
      (!_hasImageBg && _bgTop.computeLuminance() < 0.45);

@override
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

@override
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

@override
  /// 夜间模式：把壁纸压暗一层。
  ///
  /// 样式自带的壁纸都是日间纸色；夜间如果只把字换成浅色、底图不动，
  /// 就成了"浅底浅字"，正文几乎看不见（用户截图里的古风/泼墨就是这个问题）。
  ///
  /// [nightVersionInUse] 为真 = 这层图**本身就是夜间版**，不要再压暗
  /// （自选图片没有夜间版，切夜间时永远压暗）。
  Widget _nightDim(Widget child, {bool nightVersionInUse = false}) {
    if (_bgIndex != 5 || nightVersionInUse) return child;
    if (_nightDimOpacity <= 0.01) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        ColoredBox(
          color: Colors.black.withValues(alpha: _nightDimOpacity.clamp(0.0, 0.8)),
        ),
      ],
    );
  }

@override
  /// 当前背景下的次要前景色（说明文字用）
  Color get _fgMuted => _fg.withValues(alpha: 0.6);

@override
  /// 当前阅读背景色（自定义背景优先，参考图 IMG_8500）。
  ///
  /// ⚠️ **强制不透明**：自定义背景色可能是半透明的（取色器允许），
  /// 而页面背景层用的是 `_BookSourceReaderPageState._bgs[_bgIndex][0]`（不透明常量）——
  /// 于是只有面板/顶栏/底栏会透出正文（截图里那种发灰的重影字）✗。
  /// 这里把 alpha 拉满，RGB 不变 ✓。
  Color get _bgTop =>
      (_customBgColor ?? _BookSourceReaderPageState._bgs[_bgIndex][0]).withValues(alpha: 1.0);

@override
  /// 当前背景是否为深色（面板层次色用）
  ///
  /// ⚠️ 2026-10-25：原来只看纯色纸 `_bgTop` 的亮度 —— 夜里挂**深色壁纸**
  /// （泼墨/自定义深图）时纯色纸还是浅色 ⇒ 功能面板一片浅灰、和正文脱节
  /// （用户：「功能面板的和样式的有点不一样，不统一」）。改用 `_paperIsDark`
  /// （已包含夜间、壁纸实测亮度、自选图亮度）。
  bool get _isDarkBg => _paperIsDark;

@override
  /// 面板卡片底色：**刻意和阅读背景拉开一档**。
  ///
  /// 用户 2026-10-21：「弹窗没有层次感，背景和阅读页接上了」——
  /// 之前面板直接铺 `_bgTop`（= 阅读背景），加上没有遮罩，
  /// 看起来就像正文的延续 ✗。现在：
  ///   · 浅底 → 往白里提一档（纸色 → 近白卡片）
  ///   · 深底 → 往亮里提一档（炭灰 → 浮起的深灰卡片）
  /// 再配合「背后压一层黑色遮罩 + 向上投影」，层次就出来了 ✓
  Color get _sheetBg {
    // 深色壁纸 / 夜间：纯色纸可能是浅的（壁纸盖在上面）⇒ 面板用深底
    final base = _isDarkBg && _bgTop.computeLuminance() > 0.4
        ? const Color(0xFF20242A)
        : _bgTop;
    if (_isDarkBg) {
      return Color.alphaBlend(Colors.white.withValues(alpha: 0.09), base);
    }
    return Color.alphaBlend(Colors.white.withValues(alpha: 0.78), base);
  }

@override
  /// 用户手动改「信息栏」开关时，把样式自带的页眉/页脚格式串清掉。
  ///
  /// 为什么必须清：套用样式会把样式的 6 条格式串一起写进来，而渲染时
  /// **格式串优先**（`_statusHeader` 里的 `_hasHeaderFormat`）。
  /// 于是用户在设置里勾/关「信息栏」，页面上显示的还是样式那一套
  /// —— 用户 2026-10-25：「我打开了阅读设置里面的信息栏为啥还是阅读样式
  /// 的信息栏？」。清空后退回「信息栏项目」开关驱动：改什么就显示什么。
  void _clearHeaderFooterFormats() {
    if (_headerL.isEmpty &&
        _headerC.isEmpty &&
        _headerR.isEmpty &&
        _footerL.isEmpty &&
        _footerC.isEmpty &&
        _footerR.isEmpty) {
      return;
    }
    _headerL = '';
    _headerC = '';
    _headerR = '';
    _footerL = '';
    _footerC = '';
    _footerR = '';
    _scheduleSavePrefs();
  }

@override
  void _scheduleBarRectMeasure() {
    if (!_showBar) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Rect? rectOf(GlobalKey key) {
        final ro = key.currentContext?.findRenderObject();
        if (ro is! RenderBox || !ro.hasSize) return null;
        return ro.localToGlobal(Offset.zero) & ro.size;
      }

      final t = rectOf(_topBarKey);
      final b = rectOf(_bottomBarKey);
      if (t == _topBarRect && b == _bottomBarRect) return;
      setState(() {
        _topBarRect = t;
        _bottomBarRect = b;
      });
    });
  }

@override
  /// 全屏壁纸（没有壁纸 → null，面板退回纯色）
  Widget? _barBackdropImage() {
    final path = _activeFileBgPath;
    if (path != null && File(path).existsSync()) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }
    final asset = _activeBgAsset;
    if (asset != null) {
      return Image.asset(asset, fit: BoxFit.cover, gaplessPlayback: true);
    }
    return null;
  }

@override
  /// 面板底衬：有壁纸时，把壁纸**在面板位置上的那块**裁出来铺在面板里
  /// （用户 2026-10-25：「截取的就是背景图片在面板的位置作为面板的背景」）。
  ///
  /// 做法：`ClipRRect` 裁面板圆角 → 放一张**整屏大小**的壁纸，按
  /// `-rect.left / -rect.top` 平移到面板位置 → 再压一层纸色保证文字可读。
  /// 没有壁纸（纯色纸）就只铺 [fallbackColor]。
  Widget _barBackdrop(
    Rect? rect, {
    required Widget child,
    required BorderRadius radius,
    required Color fallbackColor,
    List<BoxShadow>? shadow,
  }) {
    final img = _barBackdropImage();
    final screen = MediaQuery.sizeOf(context);
    final veil = _paperIsDark
        ? Colors.black.withValues(alpha: 0.42)
        : _bgTop.withValues(alpha: 0.80);
    return Container(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: shadow),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            if (img != null && rect != null) ...[
              Positioned(
                left: -rect.left,
                top: -rect.top,
                width: screen.width,
                height: screen.height,
                child: img,
              ),
              Positioned.fill(child: ColoredBox(color: veil)),
            ] else
              Positioned.fill(child: ColoredBox(color: fallbackColor)),
            child,
          ],
        ),
      ),
    );
  }

@override
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

@override
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
    // 跟随系统日夜：只认**手机系统的深色模式**。
    // 原来监听的是影视侧的 `AppBrightness`（那是影视模块自己的明暗开关），
    // 导致阅读器被"影视侧的主题"牵着走（用户 2026-10-25 报的问题）。
    WidgetsBinding.instance.addObserver(this);
    _restorePrefs();
    _syncDockBrightness();
    _loadChapter(_index);
    // C7 护眼休息提醒：墙钟计时（后台恢复后自动补齐），30s 检查一次
    _eyeBreakStart = DateTime.now();
    _eyeTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkEyeBreak();
    });
  }

@override
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

@override
  /// 停自动阅读（触摸屏幕、切章、退出都会调；幂等）
  void _stopAutoRead() {
    final was = _autoReadOn;
    _autoReadTimer?.cancel();
    _autoReadTimer = null;
    if (_autoReadOn && mounted) setState(() => _autoReadOn = false);
    // 自动阅读期间强制亮屏；停掉后按用户的「屏幕休眠」设置还原
    if (was) _applySleepMode();
  }

@override
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

@override
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

@override
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

@override
  /// 清空章节缓存（保留当前章，避免正文闪空）
  void _clearChapterCache() {
    final cur = _cache[_index];
    setState(() {
      _cache.clear();
      if (cur != null) _cache[_index] = cur;
    });
    _toast('已清空章节缓存');
  }

@override
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

@override
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
    WidgetsBinding.instance.removeObserver(this);
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

  @override
  /// C7：连续阅读达到时长后弹休息提醒（不强退；可推迟/关闭）。
  void _checkEyeBreak() {
    if (!mounted) return;
    if (!_rs.eyeBreakEnabled || _eyeBreakShown) return;
    final elapsed = DateTime.now().difference(_eyeBreakStart);
    if (elapsed.inMinutes < _rs.eyeBreakMinutes) return;
    _eyeBreakShown = true;
    _showEyeBreakDialog();
  }

@override
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

@override
  String get _progressKey =>
      ChapterAlignment.progressKey(widget.source.id, widget.bookName);

@override
  /// 书签的存储键（**按章**存 ✓）：同一本书不同章各存各的，
  /// 避免"整本只存一份、重进时把上次那章的书签装到当前章"的串章。
  String _bookmarksKey(int chapter) => 'bsr.bookmarks.$_progressKey.$chapter';

@override
  /// 书签备注的存储键（同样按章存）
  String _bookmarkNotesKey(int chapter) =>
      'bsr.bookmarknotes.$_progressKey.$chapter';

@override
  /// 解析书签备注 JSON（`{段落下标: 备注}`）
  Map<int, String> _decodeNotes(String? raw) {
    final m = <int, String>{};
    if (raw == null || raw.isEmpty) return m;
    try {
      final d = jsonDecode(raw);
      if (d is Map) {
        d.forEach((k, v) {
          final idx = int.tryParse('$k');
          if (idx != null) m[idx] = '$v';
        });
      }
    } catch (_) {}
    return m;
  }

@override
  /// 书签的默认备注：章节名 + 该段正文前 30 字（Legado 同款）
  String _defaultBookmarkNote(int paraIndex) {
    final title = (widget.chapters.isEmpty ||
            _index < 0 ||
            _index >= widget.chapters.length)
        ? ''
        : widget.chapters[_index].name;
    final body = (paraIndex >= 0 && paraIndex < _paragraphs.length)
        ? _paragraphs[paraIndex]
        : '';
    final snippet = body.length > 30 ? '${body.substring(0, 30)}…' : body;
    if (title.isEmpty) return snippet;
    if (snippet.isEmpty) return title;
    return '$title\n$snippet';
  }

@override
  /// ✅ **「独立排版」的身份键**（本会话新增 ✓）—— 与**进度 / 书签 / 笔记**用**同一个身份** ✓
  /// （`source.id` + `bookName` ✓）⇒ 用户视角"同一本书"处处一致 ✓（不会出现"进度算一本、排版算另一本"✗）
  String get _indepKey => '${widget.source.id}.${widget.bookName}';

@override
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

@override
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
      // ⚠️ 只做**同步**查询：打开一本书不该卡在一个 10MB 的字体下载上。
      //   已下载过的字体启动时 `load()` 已注册，这里直接命中；
      //   没装过的（缓存被清过）后台补装完再重排，不影响正文先出来。
      final fontFamily = ReaderFontService.instance.familyOfSync(fontId);
      if (fontFamily == null &&
          fontId != null &&
          ReaderFontService.catalogById(fontId) != null) {
        unawaited(() async {
          final fam = await ReaderFontService.instance.familyOf(fontId);
          if (!mounted || fam == null) return;
          setState(() {
            _fontId = fontId;
            _fontFamily = fam;
          });
          _scheduleRepaginate();
        }());
      }
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
        if (bgV != null && bgV >= 0 && bgV < _BookSourceReaderPageState._bgs.length) _bgIndex = bgV;
        final dayBg =
            (ov?['dayBgIndex'] as num?)?.toInt() ??
            p.getInt('reading.dayBgIndex');
        if (dayBg != null && dayBg >= 0 && dayBg < _BookSourceReaderPageState._bgs.length) {
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
        // 书签备注（老存档没有这个键 ⇒ 空表，不影响颜色）
        _bookmarkNotes
          ..clear()
          ..addAll(_decodeNotes(p.getString(_bookmarkNotesKey(bmIdx))));
        // 本书净化开关：没存过 = 关（老用户升级后突然被净化会以为正文坏了）
        _purifyOn = p.getBool(_purifyKey) ?? false;
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
        final nd = num2('nightDim');
        if (nd != null && nd >= 0 && nd <= 0.8) _nightDimOpacity = nd;
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
      _syncSystemDayNight();
      _precachePaper();
    } catch (_) {
      // 偏好读不到就用默认值，不影响阅读
    }
  }

@override
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

@override
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
        await p.setDouble('reading.nightDim', _nightDimOpacity);
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
        // 备注跟着书签一起落盘（同一个"所属章节"窗口内）
        if (_bookmarkNotes.isEmpty) {
          await p.remove(_bookmarkNotesKey(_bookmarksChapter));
        } else {
          await p.setString(
            _bookmarkNotesKey(_bookmarksChapter),
            jsonEncode(_bookmarkNotes.map((k, v) => MapEntry('$k', v))),
          );
        }
      }
      await p.setBool('reading.hideRepeatTitle', _hideRepeatTitle);
      // 本书净化开关（默认关，按书单独记）
      await p.setBool(_purifyKey, _purifyOn);
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

@override
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

@override
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
      _bookmarkNotes.clear();
      _bookmarksChapter = -1;
    });
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_bookmarksKey(chapter));
    final notesRaw = prefs.getString(_bookmarkNotesKey(chapter));
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
      _bookmarkNotes
        ..clear()
        ..addAll(_decodeNotes(notesRaw));
      _bookmarksChapter = chapter;
    });
  }

@override
  /// 正文加载：先看**磁盘**缓存（10 分钟），命中就不再打网络。
  ///
  /// 内存里 `_cache` 只活一个进程，杀进程后再点开书架要重新抓正文
  /// （用户 2026-10-25：「点开那么慢，一点都不缓存吗」）。
  /// 只缓存**纯文字章**：带图的章图片 URL 会过期，缓存下来反而更糟。
  /// [force] = 刷新本章：先删缓存再抓。
  Future<
      ({
        bool ok,
        String? error,
        String content,
        List<String> images,
        Map<String, String> headers,
      })> _contentWithCache(String url, {bool force = false}) async {
    final key = '${widget.source.id}|$url';
    final cache = ChapterTextCache.instance;
    if (force) {
      await cache.remove(key);
    } else {
      final hit = await cache.get(key);
      if (hit != null) {
        return (
          ok: true,
          error: null,
          content: hit.$1,
          images: const <String>[],
          headers: hit.$2,
        );
      }
    }
    final r = await BookSourceService.instance.content(widget.source, url);
    if (r.ok && r.images.isEmpty && r.content.trim().isNotEmpty) {
      unawaited(cache.put(key, r.content, r.headers));
    }
    return r;
  }

@override
  Future<void> _loadChapter(int i,
      {bool prefetchOnly = false, bool force = false}) async {
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
      final r = await _contentWithCache(ch.url, force: force);
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

@override
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

@override
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

@override
  void _prefetch(int i) {
    if (i < 0 || i >= widget.chapters.length) return;
    // 🔴 **必须有窗口上限** ✗：原来只挡"越界 / 已缓存" ✓，于是每抓完一章又会
    // `_prefetch(i + 1)` ✓ → **打开一章 = 把整本几百章全抓一遍** ✓（几百次网络请求、
    // 几百次正文解析 ✓）；而缓存本身有上限（`_BookSourceReaderPageState._cacheLimit`，见下面 `_evictIfNeeded` ✓）
    // → 刚抓进来的很快又被淘汰 ✓，最后等于**白抓 + 白耗流量** ✓。
    // 只预取"当前章之后 2 章" ✓：保住"下一章秒开" ✓，同时让链式预取**到此为止** ✓
    //（`_index` 就是当前章 ✓，另见 `_loadChapter` 的 `i != _index` 与
    //  `_evictIfNeeded` 的 `(b - _index).abs()` ✓）
    if (i <= _index || i > _index + _rs.preloadChapters.clamp(1, 5)) return;
    if (_cache.containsKey(i)) return;
    // 不 await：后台跑，失败也不影响当前阅读
    _loadChapter(i, prefetchOnly: true);
  }

@override
  /// 缓存超限时丢掉离当前位置最远的章节
  void _evictIfNeeded() {
    if (_cache.length <= _BookSourceReaderPageState._cacheLimit) return;
    final keys = _cache.keys.toList()
      ..sort((a, b) => (b - _index).abs().compareTo((a - _index).abs()));
    while (_cache.length > _BookSourceReaderPageState._cacheLimit && keys.isNotEmpty) {
      _cache.remove(keys.removeAt(0));
    }
  }

@override
  /// 长按选中后的浮动工具条 —— 对齐 Legado：一排小图标，贴着选区弹，不铺满底部。
  ///
  /// 用 [TextSelectionToolbar] 是为了拿系统算好的锚点（选区上方/下方）。
  Widget _selectionMenu(BuildContext ctx, SelectableRegionState state) {
    // 双击呼面板时，SelectionArea 会把双击处的词选中并来要菜单 ——
    // 直接吞掉，否则面板刚出来就被"选字工具条"盖住（用户看到的就是"闪显一下"）。
    if (_menuSuppressUntil.isAfter(DateTime.now())) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        state.hideToolbar();
        state.clearSelection();
        if (_selectedText.isNotEmpty) setState(() => _selectedText = '');
      });
      return const SizedBox.shrink();
    }
    final anchors = state.contextMenuAnchors;
    void close() {
      state.hideToolbar();
      state.clearSelection();
    }

    Widget item(IconData icon, String label, VoidCallback onTap) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: _fg),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 11, color: _fg)),
            ],
          ),
        ),
      );
    }

    return TextSelectionToolbar(
      anchorAbove: anchors.primaryAnchor,
      anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
      // 底色跟**阅读器**走（原来用 Material 默认的 surface ⇒ 系统深色时
      // 阅读器是米黄纸、工具条却是黑块，用户 2026-10-25 要求统一）。
      // 用 `_sheetBg`（与阅读器各面板同一档），在纸面上有层次又同色系。
      toolbarBuilder: (context, child) => Material(
        color: _sheetBg,
        elevation: 4,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
      children: [
        item(Icons.copy_rounded, '复制', () {
          final t = _selectedText;
          close();
          if (t.trim().isEmpty) return;
          Clipboard.setData(ClipboardData(text: t));
          _toast('已复制');
        }),
        item(Icons.bookmark_add_outlined, '书签', () {
          final t = _selectedText;
          close();
          final pi = _paragraphIndexForSelection(t);
          _showAddBookmark(pi < 0 ? 0 : pi);
        }),
        item(Icons.search_rounded, '搜索', () {
          final t = _selectedText;
          close();
          if (t.trim().isEmpty) return;
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  BookSourceSearchPage(initialKeyword: _searchSeed(t)),
            ),
          );
        }),
        item(Icons.cleaning_services_outlined, '净化', () {
          final t = _selectedText;
          close();
          _addPurifyFromSelection(t);
        }),
        item(Icons.more_horiz_rounded, '更多', () {
          final t = _selectedText;
          close();
          _showSelectionTools(t);
        }),
      ],
    );
  }

@override
  /// 选区 → 段落下标（找不到返回 -1）
  int _paragraphIndexForSelection(String sel) {
    final s = sel.trim();
    if (s.isEmpty) return -1;
    for (var i = 0; i < _paragraphs.length; i++) {
      if (_paragraphs[i].contains(s)) return i;
    }
    return -1;
  }

@override
  /// 选区 → 打开「创建替换规则」面板（预填选中的文字）
  Future<void> _addPurifyFromSelection(String raw) async {
    final t = raw.trim();
    if (t.isEmpty) {
      _toast('先选中要净化的文字');
      return;
    }
    if (t.length > 200) {
      _toast('选中的文字太长（最多 200 字），净化会误伤');
      return;
    }
    await _showPurifyRuleEditor(seedPattern: t);
  }

@override
  /// 「创建替换规则」面板（对齐 Legado 的逐项编辑，用户 2026-10-25 要求）。
  ///
  /// 字段：名称 / 替换规则 / 替换为 / 范围 / 排除范围 /
  ///       用于标题 / 用于正文 / 使用正则表达式 / 组 / 可用
  Future<void> _showPurifyRuleEditor({
    String seedPattern = '',
    String seedName = '',
  }) async {
    final nameCtrl = TextEditingController(
      text: seedName.isEmpty ? (seedPattern.isEmpty ? '' : '选区净化') : seedName,
    );
    final patternCtrl = TextEditingController(text: seedPattern);
    final replaceCtrl = TextEditingController();
    final scopeCtrl = TextEditingController(text: widget.bookName);
    final excludeCtrl = TextEditingController();
    final groupCtrl = TextEditingController(text: '手动');

    // 选中文字默认按**纯文本**匹配（更安全）；自己写规则时默认开正则
    var isRegex = seedPattern.isEmpty;
    var useTitle = false;
    var useContent = true;
    var enabled = true;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          InputDecoration dec(String hint) => InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: _fgMuted, fontSize: 13),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            filled: true,
            fillColor: _fg.withValues(alpha: 0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          );
          Widget label(String s) => Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 6),
            child: Text(s,
                style: TextStyle(
                    fontSize: 12, color: _fgMuted, fontWeight: FontWeight.w600)),
          );
          Widget switchRow(String title, String sub, bool v, ValueChanged<bool> on) =>
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              style: TextStyle(fontSize: 13.5, color: _fg)),
                          if (sub.isNotEmpty)
                            Text(sub,
                                style: TextStyle(
                                    fontSize: 11, color: _fgMuted, height: 1.4)),
                        ],
                      ),
                    ),
                    Switch(value: v, onChanged: on),
                  ],
                ),
              );

          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.9,
            ),
            decoration: BoxDecoration(
              color: _bgTop,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 18,
                  right: 18,
                  bottom: 12 + MediaQuery.of(ctx).viewInsets.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 14, 0, 4),
                      child: Row(
                        children: [
                          Text('取消',
                              style: TextStyle(
                                  fontSize: 14,
                                  color: _fgMuted,
                                  fontWeight: FontWeight.w600)),
                          const Spacer(),
                          Text('创建替换规则',
                              style: TextStyle(
                                  fontSize: 15,
                                  color: _fg,
                                  fontWeight: FontWeight.w700)),
                          const Spacer(),
                          GestureDetector(
                            onTap: () {
                              if (patternCtrl.text.trim().isEmpty) {
                                _toast('替换规则不能为空');
                                return;
                              }
                              Navigator.pop(ctx, true);
                            },
                            child: Text('完成',
                                style: TextStyle(
                                    fontSize: 14,
                                    color: Theme.of(context).colorScheme.primary,
                                    fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          label('名称'),
                          TextField(
                            controller: nameCtrl,
                            style: TextStyle(fontSize: 14, color: _fg),
                            decoration: dec('给这条规则起个名字'),
                          ),
                          label('替换规则'),
                          TextField(
                            controller: patternCtrl,
                            minLines: 2,
                            maxLines: 5,
                            style: TextStyle(fontSize: 14, color: _fg),
                            decoration: dec('要删掉/替换的文字或正则'),
                          ),
                          label('替换为'),
                          TextField(
                            controller: replaceCtrl,
                            style: TextStyle(fontSize: 14, color: _fg),
                            decoration: dec('留空 = 直接删掉'),
                          ),
                          label('范围'),
                          TextField(
                            controller: scopeCtrl,
                            style: TextStyle(fontSize: 14, color: _fg),
                            decoration: dec('书名包含这个词才生效，留空 = 所有书'),
                          ),
                          label('排除范围'),
                          TextField(
                            controller: excludeCtrl,
                            style: TextStyle(fontSize: 14, color: _fg),
                            decoration: dec('书名包含这个词就跳过，留空 = 不排除'),
                          ),
                          const SizedBox(height: 6),
                          switchRow('用于标题', '作用于章节名', useTitle,
                              (v) => setSheet(() => useTitle = v)),
                          switchRow('用于正文', '作用于正文段落', useContent,
                              (v) => setSheet(() => useContent = v)),
                          switchRow('使用正则表达式', '关 = 按纯文本精确匹配（选中文字默认关）',
                              isRegex, (v) => setSheet(() => isRegex = v)),
                          label('组'),
                          TextField(
                            controller: groupCtrl,
                            style: TextStyle(fontSize: 14, color: _fg),
                            decoration: dec('规则分组，便于管理'),
                          ),
                          switchRow('可用', '关掉等于临时禁用这条规则', enabled,
                              (v) => setSheet(() => enabled = v)),
                          const SizedBox(height: 8),
                        ],
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

    final pattern = patternCtrl.text.trim();
    final replacement = replaceCtrl.text;
    final rule = PurifyRule(
      name: nameCtrl.text.trim().isEmpty ? '替换规则' : nameCtrl.text.trim(),
      group: groupCtrl.text.trim(),
      pattern: pattern,
      replacement: replacement,
      enabled: enabled,
      isRegex: isRegex,
      bookScope: scopeCtrl.text.trim(),
      excludeScope: excludeCtrl.text.trim(),
      applyToTitle: useTitle,
      applyToContent: useContent,
    );
    nameCtrl.dispose();
    patternCtrl.dispose();
    replaceCtrl.dispose();
    scopeCtrl.dispose();
    excludeCtrl.dispose();
    groupCtrl.dispose();
    if (ok != true || pattern.isEmpty) return;
    if (_rs.purifyRules.any((r) =>
        r.pattern == rule.pattern &&
        r.replacement == rule.replacement &&
        r.isRegex == rule.isRegex)) {
      _toast('这条规则已经有了');
      return;
    }
    setState(() {
      _rs = _rs.copyWith(purifyRules: [..._rs.purifyRules, rule]);
      // 刚加完规则却因为"本书净化没开"看不到效果，用户会以为白加了 ⇒ 顺手打开
      if (rule.applyToContent) _purifyOn = true;
      if (rule.applyToContent) {
        _paragraphs = _paragraphs
            .map((p) => applyPurifyRules(p, [rule], bookName: widget.bookName))
            .where((p) => p.trim().isNotEmpty)
            .toList();
      }
    });
    _scheduleSavePrefs();
    _invalidateTtsSegs();
    _cache.remove(_index); // 下次进本章按新规则重新净化
    _repaginateLayout();
    if (rule.applyToContent) {
      _toast('已保存并开启本书净化（共 ${_rs.purifyRules.length} 条）');
    } else {
      _toast('已保存规则（仅作用于标题，共 ${_rs.purifyRules.length} 条）');
    }
  }

@override
  /// 选区「更多」→ 分词与工具页（对齐 Legado 截图 IMG_9420）。
  ///
  /// 上面是词格（点词查词典），下面一排：净化 / 复制 / 词典 / 朗读 / 百科 / 分享。
  Future<void> _showSelectionTools(String sel) async {
    final text = sel.trim();
    if (text.isEmpty) {
      _toast('先选中文字');
      return;
    }
    final words = _segmentWords(text);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.75,
        ),
        decoration: BoxDecoration(
          color: _bgTop,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                child: Text('分词',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: _fg)),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final w in words)
                        GestureDetector(
                          onTap: () {
                            Navigator.pop(ctx);
                            _openWebPage(
                              'https://dict.youdao.com/result?word=${Uri.encodeComponent(w)}&lang=en',
                              '$w · 词典',
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: _fg.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(w,
                                style: TextStyle(fontSize: 14, color: _fg)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Divider(height: 1, color: _fg.withValues(alpha: 0.08)),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    // 标注：加书签 / 划线 / 划线+批注（长按段落那套菜单，
                    // 之前重构长按选字时丢了入口，这里补回到工具条里）
                    _toolBtn(Icons.edit_note_rounded, '标注', () {
                      Navigator.pop(ctx);
                      final pi = _paragraphIndexForSelection(text);
                      if (pi < 0) {
                        _toast('没定位到段落，换个短一点的选区试试');
                        return;
                      }
                      _onParagraphLongPress(pi);
                    }),
                    _toolBtn(Icons.cleaning_services_outlined, '净化', () {
                      Navigator.pop(ctx);
                      _addPurifyFromSelection(text);
                    }),
                    _toolBtn(Icons.copy_rounded, '复制', () {
                      Navigator.pop(ctx);
                      Clipboard.setData(ClipboardData(text: text));
                      _toast('已复制');
                    }),
                    _toolBtn(Icons.menu_book_outlined, '词典', () {
                      Navigator.pop(ctx);
                      _openWebPage(
                        'https://dict.youdao.com/result?word=${Uri.encodeComponent(text)}&lang=en',
                        '词典',
                      );
                    }),
                    _toolBtn(Icons.volume_up_outlined, '朗读', () {
                      Navigator.pop(ctx);
                      unawaited(_tts.speak(text));
                    }),
                    _toolBtn(Icons.public_rounded, '百科', () {
                      Navigator.pop(ctx);
                      _openWebPage(
                        'https://baike.baidu.com/item/${Uri.encodeComponent(text)}',
                        '百科',
                      );
                    }),
                    _toolBtn(Icons.ios_share_rounded, '分享', () async {
                      Navigator.pop(ctx);
                      await _shareText(text);
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

@override
  Widget _toolBtn(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: _fg),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 11, color: _fg)),
          ],
        ),
      ),
    );
  }

@override
  /// 极简分词：按标点/空白切段，纯中文长串再按 2 字一组。
  ///
  /// 没有引词典库（几 MB 起步，且离线词库维护成本高），
  /// 只为复刻 Legado 那种「词格」观感；点词查词典不受影响。
  List<String> _segmentWords(String text) {
    final parts = text
        .replaceAll(RegExp(r'[，。！？、；：“”‘’（）《》【】…—\-,.!?;:\s]+'), ' ')
        .split(' ')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    final out = <String>[];
    for (final p in parts) {
      if (p.length <= 4) {
        out.add(p);
        continue;
      }
      for (var i = 0; i < p.length; i += 2) {
        out.add(p.substring(i, i + 2 > p.length ? p.length : i + 2));
      }
    }
    return out;
  }

@override
  /// 内置浏览器打开（词典 / 百科）
  void _openWebPage(String url, String title) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OnlineReaderPage(url: url, title: title),
      ),
    );
  }

@override
  /// 分享选中的文字：写成临时 txt 走系统分享面板（项目已有的通道）
  Future<void> _shareText(String text) async {
    try {
      final f = File(
        '${Directory.systemTemp.path}/share_${DateTime.now().millisecondsSinceEpoch}.txt',
      );
      await f.writeAsString(text, flush: true);
      final ok = await FileExportService.shareFiles([f.path]);
      if (!ok) {
        Clipboard.setData(ClipboardData(text: text));
        _toast('没有分享面板，已复制到剪贴板');
      }
    } catch (_) {
      Clipboard.setData(ClipboardData(text: text));
      _toast('已复制到剪贴板');
    }
  }

@override
  /// C9：正文净化（正则/纯文本替换）。坏正则跳过，不打断阅读。
  ///
  /// 2026-10-25：改成**按书开关**（顶栏那枚清洁刷图标）——默认关，
  /// 关着就原样返回，规则再也不会在用户不知情时改正文。
  String _applyPurify(String raw) => _purifyOn
      ? applyPurifyRules(raw, _rs.purifyRules, bookName: widget.bookName)
      : raw;

@override
  /// 当前章节名（已按「用于标题」的规则净化）—— 顶栏 / 目录 / 听书面板统一用它
  String get _displayChapterName {
    if (widget.chapters.isEmpty || _index < 0 || _index >= widget.chapters.length) {
      return '';
    }
    final n = widget.chapters[_index].name;
    if (n.isEmpty || !_purifyOn) return n;
    return applyPurifyTitleRules(
      n,
      _rs.purifyRules,
      bookName: widget.bookName,
    );
  }

@override
  String get _purifyKey => 'bsr.purify.$_progressKey';

@override
  /// 顶栏净化开关：打开/关闭后本章要按新状态重排一遍
  Future<void> _togglePurify() async {
    setState(() => _purifyOn = !_purifyOn);
    _scheduleSavePrefs();
    _cache.remove(_index);
    _invalidateTtsSegs();
    await _loadChapter(_index);
    _toast(_purifyOn ? '本书已开启净化' : '本书已关闭净化');
  }

@override
  /// 拉一个远程文本（净化规则 JSON 这种小文件）。
  ///
  /// 用 dart:io 的 HttpClient 而不是 App 的 Dio：规则集是第三方静态文件，
  /// 不该被 API 配置/重试策略牵连；超时也自己定（15s 连接 / 30s 读完）。
  Future<String> _fetchText(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw 'HTTP ${res.statusCode}';
      }
      final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }
}
