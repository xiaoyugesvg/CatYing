part of '../book_source_reader_page.dart';

mixin _ReaderPart03 on _BookSourceReaderPageState {
@override
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

@override
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
          // 分页模式：每页一个 SelectionArea（换页即清空选择）。
          // 长按 → 系统文字选择手柄，松手出我们的浮动小工具条。
          child: Theme(
            data: Theme.of(context).copyWith(
              // 选区高亮/手柄用阅读器前景色（与纸面配色统一，不跟系统蓝）
              textSelectionTheme: TextSelectionThemeData(
                selectionColor: _fg.withValues(alpha: 0.22),
                selectionHandleColor: _fg,
                cursorColor: _fg,
              ),
            ),
            child: SelectionArea(
            key: _selKeyPage,
            onSelectionChanged: (c) => _selectedText = c?.plainText ?? '',
            contextMenuBuilder: _selectionMenu,
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
                    // 长按交给外层 SelectionArea（系统选择手柄 + 浮动工具条）；
                    // 原来这里挂的 onLongPress 会和选择手势抢，已移除
                    child: _wrapWithHighlight(pi, body),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            ),
          ),
            ),
        ),
        // ── 页脚 ────────────────────────────────────────────
        if (showFooter) _statusFooter(fg, chapter: pageChapter),
      ],
      ),
    );
  }

@override
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

@override
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

@override
  /// 段落文本 → 段落下标（书签按段落存，分页后要能找回来）
  int _paragraphIndexOf(ParagraphBlock b) {
    final i = _paragraphs.indexOf(b.text);
    return i < 0 ? 0 : i;
  }

@override
  TextStyle _statusStyle(Color fg) => TextStyle(
    // 用户 2026-10-21：信息栏字号可调（设置面板「信息栏字号」）
    fontSize: AppTheme.fontCaption * _rs.statusTextScale,
    color: fg.withValues(alpha: 0.5),
  );

@override
  Widget _statusText(String s, Color fg) => Padding(
    padding: const EdgeInsets.only(right: 10),
    child: Text(s, style: _statusStyle(fg)),
  );

@override
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

@override
  /// 下一帧清掉所有选区（SelectionArea 的双击选词是异步落的，
  /// 当场清会被它自己又选回来）
  void _clearSelectionSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final k in [_selKeyScroll, _selKeyPage]) {
        final s = k.currentState;
        if (s == null) continue;
        s.hideToolbar();
        s.clearSelection();
      }
      if (_selectedText.isNotEmpty) setState(() => _selectedText = '');
    });
  }

@override
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

@override
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
        now.difference(lastAt).inMilliseconds <= _BookSourceReaderPageState._tapWindowMs &&
        (e.position - lastPos).distance <= 60) {
      _lastTapAt = null;
      _lastTapPos = null;
      _tapTimer?.cancel();
      // 双击：呼出/收起功能面板（所有翻页模式一致）
      //
      // ⚠️ 这里**必须**清一次选区：SelectionArea 会把"双击"理解成选中一个词
      //   ⇒ 面板刚开出来就被选字工具条盖住，看着就是"闪显一下"（2026-10-25）。
      _menuSuppressUntil =
          DateTime.now().add(const Duration(milliseconds: 420));
      _clearSelectionSoon();
      _toggleBar();
      return;
    }
    _lastTapAt = now;
    _lastTapPos = e.position;
    _tapTimer?.cancel();
    _tapTimer = Timer(const Duration(milliseconds: _BookSourceReaderPageState._tapWindowMs), () {
      _lastTapAt = null;
      _lastTapPos = null;
      _handleSingleTap(e.position);
    });
  }

@override
  void _onPtrCancel(PointerCancelEvent e) {
    _ptrs.remove(e.pointer);
    if (_ptrs.isEmpty) {
      _twoFingerSeq = false;
      _firedTwoFinger = false;
    }
  }

@override
  /// 双击 / 双指的统一出口：开合功能面板（设置面板开着则先收设置面板）
  void _toggleBar() {
    if (!mounted) return;
    if (_showSettingsPanel) {
      _closeSettingsPanel();
      return;
    }
    setState(() => _showBar = !_showBar);
  }

@override
  /// 单击动作（延迟 [_BookSourceReaderPageState._tapWindowMs] 后执行）：面板开着 → 收起；否则按区域翻页/翻章。
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
    // 仿真 / 覆盖（仅文字模式）：左右翻页由翻页组件自己处理，
    // 这里只补**中间点击** = 开合面板。
    //
    // ⚠️ 组件的 `onTapCenter` 已经置空（见 `_contentArea`）：
    //   它按"每次抬手"判单击，双击会被当两次单击 → 开一次关一次 = 闪一下。
    //   走这里的话双击会被 [_onPtrUp] 吃掉第二击、取消定时器 ⇒ 只 toggle 一次。
    if (_rs.pageMode == PageMode.curl || _rs.pageMode == PageMode.cover) {
      final w = size.width;
      if (pos.dx > w / 3 && pos.dx < w * 2 / 3) _toggleBar();
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

@override
  /// 顶栏日夜切换：浅色背景 ↔ 夜间背景（记住切走前的浅色索引）
  ///
  /// 若在「阅读样式」里给白天 / 夜间各绑了一套样式，切换后自动套用那一套
  /// （先切明暗，再套用 —— `_applyReaderStyle` 按当前模式取对应配色）。
  ///
  /// [manual] 为真 = 用户自己点的 ⇒ 关闭「跟随系统」（之后系统翻昼夜不再抢）；
  /// 系统日夜回调 / 打开页面时的对齐都传 false，保持跟随。
  void _toggleDayNight({bool manual = true, bool silent = false}) {
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
      if (!silent) _toast('已切换到「${bound.name}」');
    }
    // 夜间标题 HTML 的高度通常与日间不同（headingFixedHeight），
    // 不重排会让已分好的页按旧高度渲染（标题页底部被裁/留白）
    _scheduleRepaginate();
    _precachePaper();
    _scheduleSavePrefs();
  }

@override
  /// **系统**深色模式变化（iOS 设置里切成深色/浅色）→ 阅读器跟着切。
  ///
  /// 只在「跟随系统」且偏好已恢复时生效；手动切过昼夜就不再被覆盖。
  /// ⚠️ 不再监听 `AppBrightness`：那是**影视模块**自己的明暗开关，
  ///   和阅读器「跟随系统」根本不是一回事（用户 2026-10-25）。
  void _syncSystemDayNight({bool silent = true}) {
    if (!mounted || !_prefsReady || !_followSystem) return;
    final wantNight =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    if (wantNight == (_bgIndex == 5)) return;
    _toggleDayNight(manual: false, silent: silent);
  }

@override
  void didChangePlatformBrightness() => _syncSystemDayNight();

@override
  /// 用户手动选了纸色 / 自定义底色 ⇒ 明暗由**阅读器自己的设置**定，
  /// 不再跟随系统（否则"我选的米黄纸，一开深色模式又变夜间"）。
  void _markManualDayNight() {
    if (!_followSystem) return;
    _followSystem = false;
    _styleStore.saveFollowSystem(false);
  }

@override
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

@override
  /// ⚠️ 原来这里有个 `_showBrightnessSheet()`（点右侧「亮度」按钮 → 底部弹层里拖滑杆）。
  /// 用户 2026-10-14：① 要"直接就有调整条"，不要按钮中转；
  ///   ② 那个弹层的滑杆**拖不动** —— `var value = v;` 写在 `StatefulBuilder`
  ///   的 builder 里，每次 rebuild 都被重置回初值 ⇒ 拇指一拖就弹回。
  /// ⇒ 已删除，改为竖条内联滑杆 [_dockBrightness]（值存在 State 字段，不会被重置）。

  Widget _topBarCard(Color fg) {
    return Padding(
      key: _topBarKey,
      // 悬浮卡片外观保留（四周留白 + 圆角 + 投影），但它是**布局内**的，
      // 占掉的高度由正文让出 ⇒ 永远不会压住文字 ✓
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      // 底色交给 `_barBackdrop`：有壁纸时裁壁纸在顶栏位置的那一块
      child: _barBackdrop(
        _topBarRect,
        radius: BorderRadius.circular(18),
        fallbackColor: _bgTop.withValues(alpha: 0.97),
        shadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
        child: Padding(
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
                        : _displayChapterName,
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
            // 顶栏只留：净化 / 搜索 / 刷新 / 书签
            //（朗读 / 亮度 / 白夜 / 编辑 已挪到右侧竖向悬浮栏 —— 用户要求，顶栏放 8 个太挤）
            //
            // 净化：按书开关，默认关；亮着的刷子才表示"这本书正在净化"
            _topIcon(
              _purifyOn
                  ? Icons.cleaning_services_rounded
                  : Icons.cleaning_services_outlined,
              _purifyOn ? '净化：已开启（本书）' : '净化：已关闭（本书）',
              () => _togglePurify(),
              fg,
            ),
            _topIcon(Icons.search_rounded, '搜索全书', _showBookSearch, fg),
            _topIcon(
              Icons.refresh_rounded,
              '刷新本章',
              // force：跳过磁盘缓存，拿源站最新正文
              () => _loadChapter(_index, force: true),
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
      ),
    );
  }

@override
  void _applyDockBrightness(double dy) {
    // dy 从轨道顶端往下量；亮度是「越往上越亮」
    final t = (1 - dy / _BookSourceReaderPageState._brightnessTrackH).clamp(0.0, 1.0);
    final v = (0.1 + t * 0.9).clamp(0.1, 1.0);
    if ((v - _dockBrightnessValue).abs() < 0.005) return;
    setState(() => _dockBrightnessValue = v);
    ScreenBrightness().setScreenBrightness(v);
  }

@override
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
            height: _BookSourceReaderPageState._brightnessTrackH,
            child: Center(
              // ⚠️ 必须给内层固定宽度，并用 Positioned 定位填充：
              //   之前 `Align` 作为 Stack 的非定位子项会**撑满父约束**（34 宽），
              //   而轨道只有 12 宽 ⇒ 填充被居中到 34 宽里、和轨道错开 ✗
              //   （用户截图里"背景和条没重合"就是这个）。
              child: SizedBox(
                width: _BookSourceReaderPageState._brightnessTrackW,
                height: _BookSourceReaderPageState._brightnessTrackH,
                child: Stack(
                  children: [
                    // 轨道底
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: fg.withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(
                            _BookSourceReaderPageState._brightnessTrackW / 2,
                          ),
                        ),
                      ),
                    ),
                    // 已填充部分（自底向上）
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: (_BookSourceReaderPageState._brightnessTrackH * t).clamp(
                        0.0,
                        _BookSourceReaderPageState._brightnessTrackH,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: fg.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(
                            _BookSourceReaderPageState._brightnessTrackW / 2,
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

@override
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

@override
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

@override
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

@override
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

@override
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
                  '${_displayChapterName}·${i + 1}/$n句',
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

@override
  /// 倍速档位：当前值就近取下一档（0.5→1→1.5→2→0.5 循环）
  double _nextTtsRate(double v) {
    const rates = [0.5, 1.0, 1.5, 2.0];
    for (final r in rates) {
      if (r > v + 1e-6) return r;
    }
    return rates.first;
  }

@override
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
          chapterName: _displayChapterName,
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

@override
  /// 底部菜单（按截图 IMG_8485/8487）：
  ///   上一页 [页码 1 ─── 6] 下一页      （分页模式下是**本章页**进度）
  ///   AI / 朗读 / 图片模式 / 笔记
  ///   排版 / 设置 / 目录 / 番茄钟
  Widget _bottomNav(Color fg) {
    final bgTop = _bgTop;
    // 文字分页模式：进度条显示本章页码（IMG_8487「< 1 ●──── 6 >」）
    final pageMode =
        _rs.pageMode.paginates && _pages.isNotEmpty && _images.isEmpty;
    // ✅ 用户 2026-10-07：「书源的功能栏改成这种**悬浮**的」——
    //   原来：整条**贴边**（`BorderRadius.vertical(top:…)` 只有上两角是圆角，
    //         左右/下都顶到屏幕边）⇒ 看着就是"底部工具条" ✗
    //   现在：四周留白 + **四角全圆** + 向下投影 ⇒ 一张**悬浮卡片** ✓
    //   ⚠️ 用留白（而不是改成 `Positioned` 覆盖）：本页这个功能栏是
    //     **常驻**的（不随 `_showBar` 一起收起），若改成覆盖式，
    //     正文最后几行会被**永久压在面板下面** ✗ —— 留白式同样有悬浮观感，
    //     又不吃正文 ✓
    //
    // 底色交给 `_barBackdrop`：有壁纸时裁壁纸在面板位置的那一块，
    // 没有壁纸才用 `bgTop` 纯色（用户 2026-10-25 要求）。
    return Padding(
      key: _bottomBarKey,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: _barBackdrop(
        _bottomBarRect,
        radius: BorderRadius.circular(18),
        fallbackColor: bgTop.withValues(alpha: 0.97),
        shadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 20,
            // 投影朝**下**（原来朝上 `Offset(0, -4)`，因为贴边只能往上打影）
            offset: const Offset(0, 6),
          ),
        ],
        child: Padding(
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
                              chapterName: _displayChapterName,
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
        ),
      ),
    );
  }

@override
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

@override
  /// 数值字重（300~900）转 Flutter 的 FontWeight。
  ///
  /// 截图里「字重」是个 400 这样的数字，而 FontWeight 只有
  /// w100~w900 九个枚举 —— 所以要就近映射。
  FontWeight _fontWeightToW(double v) {
    final i = ((v / 100).round() * 100).clamp(100, 900);
    return FontWeight.values[(i ~/ 100) - 1];
  }

@override
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

@override
  /// **当前页的锚点**（重排定位用 ✓）：本页第一个 entry 的「块下标 + 块内字符偏移」✓。
  /// 返回 `null` 表示拿不到锚点（不需要恢复位置 ✓）。
  (int, int)? _currentPageAnchor() {
    if (_pages.isEmpty) return null;
    final p = _pages[_safePageIndex()];
    if (p.entries.isEmpty) return null;
    final e = p.entries.first;
    return (e.blockIndex >= 0 ? e.blockIndex : p.firstBlockIndex, 0);
  }

@override
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

@override
  /// 当前是否走「内容级无缝翻页」：把下一章的页直接拼到 `_pages` 末尾。
  ///
  /// **所有分页模式**（左右 / 无动画 / 仿真 / 覆盖 / 双页横屏）都开启：
  /// 拼进来之后 `canNext` 依然成立，翻页组件的"翻不过去"就自然失效了。
  /// 上下滚动模式不分页，走另一套（[_scrollChapters] 连排多章）。
  bool get _seamlessPaging => _rs.pageMode.paginates;

@override
  /// 朗读推进 → **把正在念的那一段翻进视野**（用户 2026-10-29：「为啥朗读的时候
  /// 不跟随翻页呢」）。
  ///
  /// 为什么不靠跟读高亮那个 widget 自己滚：
  ///   分页模式下每页是独立渲染的，「正在念的那一段」在**别的页**时，它的 widget
  ///   根本没被构建 —— `Scrollable.ensureVisible` 无处可滚，表现就是"朗读在走、
  ///   页面不动"。所以这里直接按段落下标算出页号，把 PageView 翻过去。
  ///
  /// 只在**分页模式**生效：滚动模式由 `_wrapWithHighlight` 的 ensureVisible 负责
  /// （那边能拿到段内 context，滚动更平滑，不会整章重排）。
  void _followTtsSegment() {
    if (!_ttsAutoLocate) return;
    if (!_rs.pageMode.paginates) return;
    if (!_tts.isSpeaking.value && !_tts.isPaused.value) return;
    if (_pages.isEmpty) return;
    final pi = _ttsParagraph;
    if (pi == null) return;
    // 段落 → 全书块下标（与 `_pageBody` 里 `e.blockIndex - _blockOffset` 互逆）
    final want = _blockOffset + pi;
    // 无缝拼接后 `_pages` 里可能混着下一章的页 ⇒ 只在当前章的页范围里找
    final (start, end) = _chapterPageRange(_index);
    final target = BookPaginator.pageOfBlockInRange(
      _pages,
      want,
      from: start,
      to: end,
    );
    if (target == null || target == _pageIndex) return;
    if (_pageCtrl.hasClients) {
      _pageCtrl.jumpToPage(target);
    } else {
      // 仿真 / 覆盖模式没有挂载 PageView
      _setPageIndex(target);
    }
  }

@override
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

@override
  /// 当前**章内**页码（1 起）与本章总页数 —— 页眉页码、进度、滑块都用它，
  /// 这样拼了下一章之后也不会显示成 "12/58"（58 里含下一章的页）。
  int get _localPageNo {
    final (start, end) = _chapterPageRange(_index);
    final n = _pageIndex - start + 1;
    return n.clamp(1, (end - start).clamp(1, 1 << 30));
  }

@override
  int get _localPageCount {
    final (start, end) = _chapterPageRange(_index);
    return (end - start).clamp(1, 1 << 30);
  }

// ── 标题样式（章标题版式）──────────────────────────────────

  @override
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

@override
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

@override
  String _titleHeightSignature() {
    final w = _dualPageActive ? _viewport.width / 2 : _viewport.width;
    return '${_fontSize}|${_titleScale}|${_titleGap}|${_padLeft}|${_padRight}'
        '|${w.toStringAsFixed(1)}|$_dualPageActive|${_fontFamily ?? ''}'
        '|${_titleFontSize?.toStringAsFixed(1) ?? '-'}'
        '|${MediaQuery.textScalerOf(context).scale(1.0).toStringAsFixed(3)}'
        '|${_chapterTitleSource.hashCode}';
  }

@override
  double? _titleHeightFor(int chapter) {
    final sig = _titleHeightSignature();
    if (sig != _titleHeightKey) {
      _titleHeightKey = sig;
      _titleHeightCache.clear();
    }
    if (_titleHeightCache.containsKey(chapter)) {
      return _titleHeightCache[chapter];
    }
    final doc = _titleDoc(chapter);
    if (doc == null) {
      _titleHeightCache[chapter] = null;
      return null;
    }
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
    final result = (h + _titleGap).clamp(0.0, _textAreaHeight * 0.55);
    _titleHeightCache[chapter] = result;
    return result;
  }

@override
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

@override
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

@override
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

@override
  /// 实际可排文字的高度（扣掉页眉 + 页脚）
  double get _textAreaHeight =>
      (_viewport.height - _headerFooterHeight()).clamp(1.0, _viewport.height);

@override
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
    if (_pages.length >= _BookSourceReaderPageState._kSeamlessPageCap) return;
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

@override
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

@override
  /// 是不是已经翻到"最后一张可显示的页 / spread"
  bool get _atLastDisplayedPage {
    if (_pages.isEmpty) return true;
    if (!_dualPageActive) return _pageIndex >= _pages.length - 1;
    // 双页 spread：[0], (1,2), (3,4)… ⇒ 末页若是偶数下标，它属于 (L-1, L)
    final l = _pages.length - 1;
    final lastSpreadFirst = l == 0 ? 0 : (l.isEven ? l - 1 : l);
    return _pageIndex >= lastSpreadFirst;
  }

@override
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

@override
  void _edgeTurn(int delta) {
    final now = DateTime.now();
    final last = _lastEdgeTurnAt;
    if (last != null && now.difference(last) < const Duration(milliseconds: 700)) {
      return;
    }
    _lastEdgeTurnAt = now;
    _go(delta);
  }

@override
  /// 双页横屏是否生效（页码 / 切片 / spread 语义与单页不同）
  bool get _dualPageActive =>
      _rs.dualPage &&
      MediaQuery.of(context).orientation == Orientation.landscape;

@override
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

@override
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

  @override
  /// 换章 / 目录跳转：滚动章链回到"只有这一章"（滚动视图随之重建、回到章首）
  void _resetScrollChain(int chapter) {
    _scrollChapters = [chapter];
    _scrollKeys.clear();
    _scrollConv.clear();
    _scrollEpoch++;
  }

@override
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

@override
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

@override
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

@override
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

@override
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

@override
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

@override
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

@override
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

@override
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
}
