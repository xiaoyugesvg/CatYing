part of '../book_source_reader_page.dart';

mixin _ReaderPart02 on _BookSourceReaderPageState {
@override
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
                                      '粘贴 legado 的 replaceRule JSON，\n'
                                      '或直接填 JSON 的 http(s) 链接，\n'
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
                          // 远程规则集：直接填 http(s) 链接（用户 2026-10-25 要的）
                          if (raw.startsWith('http://') ||
                              raw.startsWith('https://')) {
                            _toast('正在下载规则…');
                            try {
                              raw = await _fetchText(raw);
                            } catch (e) {
                              _toast('下载失败：$e');
                              return;
                            }
                          }
                          try {
                            final skipped = <String>[];
                            final parsed = parseLegadoReplaceRules(
                              jsonDecode(raw),
                              skipped: skipped,
                            );
                            if (parsed.isEmpty) {
                              _toast(skipped.isEmpty
                                  ? '没有解析到规则'
                                  : '解析到 ${skipped.length} 条，但都是 JS 脚本/仅标题规则，无法使用');
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
                            _toast(
                              '已导入 $added 条'
                              '${skipped.isEmpty ? '' : '，跳过 ${skipped.length} 条（@js 脚本/仅标题）'}',
                            );
                          } catch (e) {
                            _toast('导入失败：$e');
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

@override
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

@override
  /// A2 繁简转换：按 `_rs.convertMode` 把段落列表整体转换（原文缓存不变）。
  List<String> _applyConvert(List<String> paras) {
    final m = _rs.convertMode;
    if (m == ChineseConvertMode.none || paras.isEmpty) return paras;
    return paras.map((p) => convertChinese(p, m)).toList(growable: false);
  }

@override
  /// A2 设置面板的繁简模式文案
  String _convertLabel(ChineseConvertMode m) => switch (m) {
    ChineseConvertMode.none => '原文',
    ChineseConvertMode.traditionalToSimplified => '繁转简',
    ChineseConvertMode.simplifiedToTraditional => '简转繁',
  };

@override
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

@override
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
    // 前景用 [_fg]（含样式日/夜字色）。原来固定用 `_BookSourceReaderPageState._bgs[_bgIndex]`，
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
    // 顶栏 / 底栏的屏幕位置（用于裁壁纸对应区域当面板背景）—— 帧后量一次
    _scheduleBarRectMeasure();
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

@override
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
          // 🔴 修复：原来 `i+=2` 从 0 起步 ⇒ spread 是 [0],(2,3),(4,5)…
          //   ——下标 1 的页永远丢（双页下第 2 页看不见），且成对起点
          //   是偶数 ⇒ 与 `_appendNextChapter` 的补白页（奇数下标=左页）
          //   对齐逻辑互相矛盾，横屏双页会出现"左页空白/页缺失"。
          //   现在从 1 起步成对：[0],(1,2),(3,4)…，每一页都进 spread，
          //   奇数下标恒为左页，与补白页语义一致。
          final spreads = <List<int>>[[0]];
          for (var i = 1; i < _pages.length; i += 2) {
            spreads.add([i, if (i + 1 < _pages.length) i + 1]);
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
          // ⚠️ 不再包 `withPressDownBookmark`：长按现在用于**选字**，
          //   那个「按住下滑加书签」的 LongPress 手势会和 SelectionArea 抢，
          //   抢输时书签不生效、抢赢时选不了字。书签改从选区工具条/顶栏加。
          return BookPageCurl(
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
            // ⚠️ 中间点击**不能**再交给组件自己做（原来这里是 `_toggleBar`）：
            //   组件用自己的 Listener 逐次判定单击，双击 = 两次单击 = 开一次关一次，
            //   用户看到的就是「双击闪一下、面板根本不出现」（2026-10-25）。
            //   现在中间点击统一由外层 [_handleSingleTap] 处理（延迟 320ms，
            //   双击会取消这个定时器）⇒ 双击只 toggle 一次。
            onTapCenter: () {},
          );
        }

        // ✅ 覆盖翻页：复用图书阅读器的 `BookPageCover` —— 新页从侧边滑入**覆盖**，
        //    滑入页自带不透明底色 ⇒ 不会与当前页文字**重叠** ✓。
        //    原来「覆盖」只是把 PageView 换成 Clamping 物理 ✗ → 实际效果与「左右」
        //    一模一样（仍是整页平移），用户实测"翻页样式太丑、还重叠" ✗
        if (_rs.pageMode == PageMode.cover) {
          final pi = _safePageIndex();
          // 同上：长按留给选字，不再包「按住下滑加书签」
          return BookPageCover(
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
              // 中间点击交给外层 [_handleSingleTap]（原因见仿真分支注释）
              onTapCenter: () {},
            );
        }

        // 其余模式（左右 / 无动画）走 PageView
        return Stack(
          children: [
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

@override
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

@override
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
            errorBuilder: (c, u, e) => Container(
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

@override
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
        // 上下滚动：整章链一个 SelectionArea —— 可以跨段/跨章选文字，
        // 长按出系统选择手柄 + 我们的浮动小工具条（复制/书签/搜索/净化/更多）
        // 选区高亮/手柄颜色用**阅读器前景色**（原来跟随系统主题是蓝色，
        // 与米黄纸不搭 —— 用户 2026-10-25「长按后的颜色要统一阅读器」）
        child: Theme(
          data: Theme.of(context).copyWith(
            textSelectionTheme: TextSelectionThemeData(
              selectionColor: _fg.withValues(alpha: 0.22),
              selectionHandleColor: _fg,
              cursorColor: _fg,
            ),
          ),
          child: SelectionArea(
            key: _selKeyScroll,
            onSelectionChanged: (c) => _selectedText = c?.plainText ?? '',
            contextMenuBuilder: _selectionMenu,
            child: SingleChildScrollView(
              // 自动阅读（上下模式）要用它滚屏
              controller: _scrollReadCtrl,
              padding:
                  EdgeInsets.fromLTRB(_padLeft, _padTop, _padRight, _padBottom),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var k = 0; k < chain.length; k++)
                    _scrollChapterBlock(chain[k], fg, first: k == 0),
                ],
              ),
            ),
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

@override
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

@override
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

@override
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
                    errorBuilder: (_, __, ___) => Container(
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

@override
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
      // 长按由外层 SelectionArea 接管（系统选字手柄 + 浮动工具条）；
      // 这里只保留「有笔记的段落点一下看气泡」。
      child: GestureDetector(
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

@override
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

@override
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

@override
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

@override
@override
  /// 把一段正文包上跟读高亮（用 Obx 订阅 TtsService 的进度变化）
  ///
  /// ⚠️ 2026-10-29：**高亮和「自动定位」必须解耦**。
  ///   原来第一行是 `if (_ttsHighlight == 0) return child;` —— 用户把「跟读高亮」
  ///   设成「关」之后，连"朗读跟着翻页"一起失效了（他以为只是不要底色）。
  ///   现在：底色关掉就只不画底色，`_ttsAutoLocate` 打开时照样定位。
  ///   ⚠️ 定位**不能**顺手加 padding（会改动分页度量，页底会溢出）——
  ///   只包一层 Builder，视觉上一像素都不变。
  Widget _wrapWithHighlight(int pi, Widget child) {
    if (_ttsHighlight == 0 && !_ttsAutoLocate) return child;
    return Obx(() {
      // 不是"正在念的那一段"：原样返回，什么都不做
      //
      // ⚠️ 这里**故意不读** `segmentProgress` —— Obx 按"这一帧读了哪些 Rx"
      //   决定订阅谁。读在下面（只有当前段才走到）⇒ 只有当前段那一个 Obx
      //   会以 4Hz 重建，其余段落一点都不受影响。
      if (pi != _ttsParagraph) return child;
      final segP = _tts.segmentProgress.value;
      final d = _ttsHighlightDecoration(pi);
      // 没开高亮：不套装饰也不套 padding，只借 Builder 拿一个段内 context
      final Widget out = d == null
          ? child
          : Container(
              decoration: d,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: child,
            );
      if (!_ttsAutoLocate) return out;
      // ✅ **自动定位阅读位置**（滚动模式）：
      //   · 这个 `Obx` 在"朗读进度变化"时重建，走到这里说明 pi 就是"正在念的那一段"
      //   · ⚠️ 用 `Builder` 取一个**段内**的 `BuildContext` —— `Obx` 的 builder 不带 context
      //   · ⚠️ 放进 `addPostFrameCallback`：重建当帧**尚未布局**，滚动目标要等一帧才准确
      //   · ⚠️ 分页模式**不靠这里**：本段在别的页时这个 widget 根本没被构建，
      //     那种情况由 `_followTtsSegment` 直接把 PageView 翻到那一页。
      //
      // ⚠️ 2026-10-31：固定 `alignment: 0.35` 只对**一屏放得下**的段落有效。
      //   网文一段常常比视口还高（用户截图那种），段首被钉在 35% 处之后
      //   段内继续念，alignment 不变 ⇒ **画面一直不动**，直到念到下一段才跳。
      //   现在：段落比视口高时，把落点按段内进度从段首推向段尾。
      return Builder(
        builder: (ctx) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !ctx.mounted) return;
            if (_rs.pageMode.paginates) return;
            var align = 0.35;
            final ro = ctx.findRenderObject();
            final vp = Scrollable.maybeOf(ctx)?.position.viewportDimension;
            if (ro is RenderBox &&
                ro.hasSize &&
                vp != null &&
                vp > 0 &&
                ro.size.height > vp * 0.9) {
              // 长段：0.05 → 0.9 平滑推进，读到最后一行时正好把段尾带进视野
              align = (0.05 + segP * 0.85).clamp(0.05, 0.9);
            }
            Scrollable.ensureVisible(
              ctx,
              alignment: align,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
            );
          });
          return out;
        },
      );
    });
  }

@override
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

// 边框

  @override
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
    final factorW = w * _BookSourceReaderPageState._kBubbleWidthFactor;
    final contentW = w - _padLeft - _padRight;
    return (contentW > 0 && contentW < factorW) ? contentW : factorW;
  }

@override
  /// 气泡**文字区**宽度（= 最大宽 - 左右内衬 - 边框）→ 交给分页器度量
  double get _bubbleTextWidth =>
      _bubbleMaxWidth - (_BookSourceReaderPageState._kBubblePadH + _BookSourceReaderPageState._kBubbleBorder) * 2;

@override
  /// 每个气泡**额外占的高度**（上下内衬 + 上下边框）→ 交给分页器计入
  double get _bubbleExtraV => (_BookSourceReaderPageState._kBubblePadV + _BookSourceReaderPageState._kBubbleBorder) * 2;

@override
  /// 自定义气泡底色：没挑过色时用一个低调的浅底（跟随前景派生）
  Color get _customBubbleBg =>
      Color(_rs.bubbleBgColor ?? _fg.withValues(alpha: 0.08).toARGB32());

@override
  /// 自定义气泡文字色：没挑过色时跟随正文前景
  Color get _customBubbleText => Color(_rs.bubbleTextColor ?? _fg.toARGB32());

@override
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
          horizontal: _BookSourceReaderPageState._kBubblePadH,
          vertical: _BookSourceReaderPageState._kBubblePadV,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border, width: _BookSourceReaderPageState._kBubbleBorder),
        ),
        child: Text(
          text,
          style: _bodyStyle(textColor, noUnderline: true),
        ),
      ),
    );
  }

@override
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

@override
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

@override
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
                      for (final asset in _BookSourceReaderPageState._builtinBgImages)
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

@override
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

@override
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

@override
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

@override
  /// 某一页属于哪一章（无缝拼接后 `_pages` 里混有多章）
  int _chapterOfPage(int i) =>
      (i >= 0 && i < _pageChapterOf.length) ? _pageChapterOf[i] : _index;

@override
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
    // 每页独立成图层：翻页/滑动时只重绘这一页，不会牵连整棵页面树。
    // 双页模式传 paper:false（纸在 Row 外层），同样隔离。
    if (!paper) return RepaintBoundary(child: body);
    final content = Stack(
      fit: StackFit.expand,
      children: [_pagePaper(), body],
    );
    // 页缘投影：只在"两页并排平移"的模式（左右 / 无动画）+ 纯色纸时画 ——
    // 给两页之间一个可见软边界；壁纸纸面画阴影会像"两张一样的图拼在一起"。
    if (_hasImageBg ||
        (_rs.pageMode != PageMode.slide && _rs.pageMode != PageMode.none)) {
      return RepaintBoundary(child: content);
    }
    return RepaintBoundary(
      child: Stack(
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
      ),
    );
  }

// ── 页眉 / 页脚「格式串」（对齐源阅读的"编辑小组件"）───────────
  //
  // 变量：# 章节名 · c 章节序号 · C 总章数 · p 本章页码 · P 本章总页数
  //       % 进度百分比 · t 时间 · b 电量 · B 书名
  // 三个位置（左 / 中 / 右）各一条；为空则退回到「信息栏项目」开关的老逻辑。

  @override
  bool get _hasHeaderFormat =>
      _headerL.trim().isNotEmpty ||
      _headerC.trim().isNotEmpty ||
      _headerR.trim().isNotEmpty;

@override
  bool get _hasFooterFormat =>
      _footerL.trim().isNotEmpty ||
      _footerC.trim().isNotEmpty ||
      _footerR.trim().isNotEmpty;

@override
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

@override
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

@override
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

@override
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
}
