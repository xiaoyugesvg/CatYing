part of '../book_source_reader_page.dart';

mixin _ReaderPart04 on _BookSourceReaderPageState {
@override
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

@override
  /// 跳转到指定章（进度条拖动用）
  void _jumpTo(int i) {
    if (i < 0 || i >= widget.chapters.length) return;
    setState(() {
      _index = i;
      _loading = true;
    });
    _loadChapter(i);
  }

@override
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
                        for (var i = 0; i < _BookSourceReaderPageState._layoutTabs.length; i++)
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
                                  _BookSourceReaderPageState._layoutTabs[i],
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

@override
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

@override
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

@override
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

@override
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

@override
  /// 列表里的小缩略图（比卡片小样简单，保证 44×54 不溢出）
  Widget _styleThumb(ReaderStyle s, {bool selected = false}) {
    final night = _bgIndex == 5;
    final bgc = night ? (s.bgColorNight ?? s.bgColor) : s.bgColor;
    final bg = bgc != null
        ? Color(bgc)
        : _BookSourceReaderPageState._bgs[(night ? 5 : s.bgIndex).clamp(0, _BookSourceReaderPageState._bgs.length - 1)][0];
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

@override
  /// 翻页模式 id → 中文名
  String _pageModeLabel(String id) {
    for (final m in PageMode.values) {
      if (m.name == id) return m.label;
    }
    return '左右';
  }

@override
  /// 样式小样：按样式自己的底色 / 壁纸 / 文字色 / 行距画一张"迷你书页"，
  /// 让用户在**点之前**就大致看出观感（不是纯色块）。
  ///
  /// 跟随阅读器当前日夜：夜间时预览样式的**夜间**配色与夜版壁纸。
  Widget _stylePreview(ReaderStyle s, {bool selected = false}) {
    final night = _bgIndex == 5;
    final bgc = night ? (s.bgColorNight ?? s.bgColor) : s.bgColor;
    final bg = bgc != null
        ? Color(bgc)
        : _BookSourceReaderPageState._bgs[(night ? 5 : s.bgIndex).clamp(0, _BookSourceReaderPageState._bgs.length - 1)][0];
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

@override
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

@override
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

@override
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
          for (var i = 0; i < _BookSourceReaderPageState._bgs.length; i++)
            GestureDetector(
              onTap: () => upd(() {
                _customBgColor = null;
                // 手选底色 ⇒ 不再跟随样式的日/夜配色
                _styleBgDay = null;
                _styleBgNight = null;
                _bgIndex = i;
                _markManualDayNight();
              }),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: _BookSourceReaderPageState._bgs[i][0],
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
              if (picked != null) {
                upd(() => _customBgColor = picked);
                _markManualDayNight();
              }
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
            for (final a in _BookSourceReaderPageState._builtinBgImages) _bgImageChip(a, upd),
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
          // 无：清掉内置背景（回到 _BookSourceReaderPageState._bgs 底色）
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

@override
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
                      itemCount: _BookSourceReaderPageState._builtinBgs.length,
                      itemBuilder: (c, i) {
                        final e = _BookSourceReaderPageState._builtinBgs[i];
                        final active = _customBgColor == e.$2;
                        return GestureDetector(
                          onTap: () {
                            setSheet(() {});
                            upd(() => _customBgColor = e.$2);
                            _markManualDayNight();
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

@override
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

@override
  /// 当前排版是否正好等于某个预设（用于高亮预设 chip）
  bool _isPreset(_TextPreset p) =>
      (_fontSize - p.size).abs() < 0.01 &&
      (_lineHeight - p.lineHeight).abs() < 0.01 &&
      (_letterSpacing - p.letterSpacing).abs() < 0.01 &&
      (_paraSpacing - p.paraSpacing).abs() < 0.01;

@override
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
                  // 字体库：系统自带（苹方/楷体/隶书…）+ 可下载（思源宋体/黑体…）
                  _chip(
                    '字体库',
                    false,
                    () async {
                      await _showFontLibrary();
                      upd(() {});
                    },
                    compact: true,
                  ),
                  // 已装的可下载字体（点一下直接用，长按删除的不在这里）
                  for (final f in ReaderFontService.instance.fonts
                      .where((e) => ReaderFontService.catalogById(e.id) == null))
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

@override
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

@override
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

@override
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
                    _underlineColor = n == '跟随文字' ? null : _BookSourceReaderPageState._underlineColors[n],
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color:
                      (_underlineColor ==
                          (n == '跟随文字' ? null : _BookSourceReaderPageState._underlineColors[n]))
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
                            (n == '跟随文字' ? null : _BookSourceReaderPageState._underlineColors[n]))
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

@override
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

@override
  /// 「添加书签」弹层（截图 IMG_8100 / 9417）：
  ///   标题「添加书签」+ 6 个颜色圆点 + 备注框 + 「不再提示」勾选框
  ///
  /// 备注默认填「章节名 + 正文片段」（Legado 同款），可以直接改成自己的话。
  /// 「不再提示」勾上后，下次加书签**不再弹这个框**，直接用上次的颜色。
  Future<void> _showAddBookmark(int paraIndex) async {
    if (_bookmarkNoAsk) {
      setState(() {
        _bookmarks[paraIndex] = _BookSourceReaderPageState._bookmarkColors[_bookmarkLastColor];
        _bookmarkNotes[paraIndex] = _defaultBookmarkNote(paraIndex);
      });
      _toast('已用${_bookmarkColorName(_bookmarkLastColor)}加书签');
      await _savePrefs();
      return;
    }
    final noteCtrl = TextEditingController(text: _defaultBookmarkNote(paraIndex));
    var noAsk = false;
    final picked = await showModalBottomSheet<(Color, String)>(
      context: context,
      isScrollControlled: true,
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
              padding: EdgeInsets.fromLTRB(
                20,
                18,
                20,
                18 + MediaQuery.of(ctx).viewInsets.bottom,
              ),
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
                  const SizedBox(height: 14),
                  // 备注（默认已填好，直接点完成也行）
                  TextField(
                    controller: noteCtrl,
                    minLines: 2,
                    maxLines: 4,
                    style: TextStyle(fontSize: 14, color: _fg),
                    decoration: InputDecoration(
                      hintText: '备注（可留空）',
                      hintStyle: TextStyle(fontSize: 13, color: _fgMuted),
                      filled: true,
                      fillColor: _fg.withValues(alpha: 0.05),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      for (var i = 0; i < _BookSourceReaderPageState._bookmarkColors.length; i++)
                        GestureDetector(
                          onTap: () => Navigator.pop(
                            ctx,
                            (_BookSourceReaderPageState._bookmarkColors[i], noteCtrl.text.trim()),
                          ),
                          child: Container(
                            width: 38,
                            height: 38,
                            margin: const EdgeInsets.only(right: 14),
                            decoration: BoxDecoration(
                              color: _BookSourceReaderPageState._bookmarkColors[i],
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _fg.withValues(alpha: 0.15),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
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
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final note = noteCtrl.text.trim();
    noteCtrl.dispose();
    if (picked == null) return;
    setState(() {
      _bookmarks[paraIndex] = picked.$1;
      if (note.isEmpty) {
        _bookmarkNotes.remove(paraIndex);
      } else {
        _bookmarkNotes[paraIndex] = note;
      }
      if (noAsk) {
        _bookmarkNoAsk = true;
        _bookmarkLastColor = _BookSourceReaderPageState._bookmarkColors.indexOf(picked.$1);
      }
    });
    await _savePrefs();
    _toast('已加书签');
  }

@override
  String _bookmarkColorName(int i) {
    const names = ['黄色', '绿色', '蓝色', '粉色', '紫色', '蓝紫'];
    return names[i % names.length];
  }
}
