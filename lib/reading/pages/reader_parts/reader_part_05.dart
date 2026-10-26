part of '../book_source_reader_page.dart';

mixin _ReaderPart05 on _BookSourceReaderPageState {
@override
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
                // 第二行：对齐 Legado 的选中菜单（复制 / 搜索 / 朗读 / 翻译）
                //
                // 「翻译这段」原来单独占一行、还只有一个 Expanded ⇒ 会被拉成
                // 一整条超宽按钮，和上面三列完全不齐（看着像坏了）。并到这一行。
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
                        '朗读',
                        () => Navigator.pop(ctx, 'tts'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // 走 Google 免 Key 端点，见 TranslateService
                    Expanded(
                      child: _longPressAction(
                        Icons.translate_rounded,
                        '翻译',
                        () => Navigator.pop(ctx, 'translate'),
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
          chapterName: _displayChapterName,
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
          chapterName: _displayChapterName,
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
      case 'translate':
        await _translateParagraph(text);
    }
  }

@override
  /// 翻译整段（阅读器长按菜单 →「翻译这段」）
  ///
  /// 用 Google 免 Key 端点，不需要在 AI 里配 Key；翻完可一键复制。
  Future<void> _translateParagraph(String text) async {
    _toast('翻译中…');
    try {
      final zh = await TranslateService.instance.toZh(text);
      if (!mounted) return;
      if (zh.trim() == text.trim()) {
        _toast('这段已经是中文 / 无需翻译');
        return;
      }
      await showDialog(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: _bgTop,
          title: Text('译文',
              style: TextStyle(fontSize: 15, color: _fg)),
          content: SingleChildScrollView(
            child: Text(
              zh,
              style: TextStyle(fontSize: 14, height: 1.75, color: _fg),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: zh));
                if (c.mounted) Navigator.pop(c);
                _toast('译文已复制');
              },
              child: Text('复制', style: TextStyle(color: _fgMuted)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text('关闭', style: TextStyle(color: _fg)),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) _toast('翻译失败：$e');
    }
  }

@override
  /// 从段落里截一个"可搜索"的关键词（去掉空白/引号，最多 20 字）
  String _searchSeed(String t) {
    final cleaned = t
        .replaceAll(RegExp(r'[\s\u3000]+'), ' ')
        .replaceAll(RegExp(r'^[“”"「」『』\s]+|[“”"「」『』\s]+$'), '')
        .trim();
    if (cleaned.isEmpty) return t.trim();
    return cleaned.length <= 20 ? cleaned : cleaned.substring(0, 20);
  }

@override
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

@override
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

@override
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

@override
  /// 预设快照 → 恢复排版字段
  void _applyPresetMap(Map<String, dynamic> m) {
    setState(() {
      _fontSize = (m['fontSize'] as num?)?.toDouble() ?? _fontSize;
      _lineHeight = (m['lineHeight'] as num?)?.toDouble() ?? _lineHeight;
      final bg = m['bgIndex'] as int?;
      if (bg != null && bg >= 0 && bg < _BookSourceReaderPageState._bgs.length) _bgIndex = bg;
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

@override
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

@override
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

  @override
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

@override
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

@override
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

@override
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

@override
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

@override
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

@override
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

@override
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

@override
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

@override
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

@override
  /// 当前阅读外观 → [ReaderStyle] 快照（「保存当前为样式」用）
  ReaderStyle _styleSnapshot(String id, String name, {bool builtin = false}) {
    // 日夜底色要分开存：夜间保存时 `_customBgColor` 是**夜间**底色，
    // 直接当 bgColor 会把日间也存成深色（反之夜里没 bgColorNight ⇒ 浅底浅字）
    final dayBg = _bgIndex == 5
        ? (_styleBgDay ??
              _BookSourceReaderPageState._bgs[_dayBgIndex.clamp(0, _BookSourceReaderPageState._bgs.length - 1)][0].toARGB32())
        : _customBgColor?.toARGB32();
    final nightBg = _bgIndex == 5
        ? (_customBgColor?.toARGB32() ?? _BookSourceReaderPageState._bgs[5][0].toARGB32())
        : (_styleBgNight ?? _BookSourceReaderPageState._bgs[5][0].toARGB32());
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
      nightDim: _nightDimOpacity,
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

@override
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

@override
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
    // 刚把「跟随系统」打开 ⇒ 立刻按**系统**日夜对齐一次
    if (f) _syncSystemDayNight();
  }

@override
  /// 一键套用一套样式：配色 / 背景 / 排版 / 边距 / 信息栏 / 翻页动画一次改完。
  ///
  /// 改完必须**重排**（字号行距边距全变了，旧 `_pages` 是按旧度量切的），
  /// 但用防抖 —— 用户可能连着点好几张卡片对比效果。
  void _applyReaderStyle(ReaderStyle s) {
    // ⚠️ 2026-10-25：样式**不再改翻页方式 / 双页开关**。
    // 用户：「切换样式后，连翻页方式也变了？」——
    // 翻页方式（左右/上下/仿真/覆盖）和双页是**阅读偏好**，
    // 存在 `reading.settings` 里；样式只负责配色/排版/标题。
    // 否则套一个导入样式就把「左右」变成「覆盖」，还会因为
    // 章首没有上一页而出现"左滑没内容"。
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
          : s.bgIndex.clamp(0, _BookSourceReaderPageState._bgs.length - 1);
      _dayBgIndex = s.dayBgIndex.clamp(0, _BookSourceReaderPageState._bgs.length - 1);
      _customBgColor = custom == null ? null : Color(custom);
      _fgOverride = s.fgColor == null ? null : Color(s.fgColor!);
      _fgNightOverride = s.fgColorNight == null
          ? null
          : Color(s.fgColorNight!);
      _titleFontSize = s.titleFontSize;
      // 标题缩放/间距是样式的组成部分（样式库里可调、可导出）
      _titleScale = s.titleScale.clamp(0.6, 1.6);
      _titleGap = s.titleGap.clamp(0.0, 40.0);
      _nightDimOpacity = s.nightDim.clamp(0.0, 0.8);
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
        // pageMode / dualPage **刻意不套**（见方法开头说明）
        statusItems: s.statusItems.toSet(),
        hideStatusBar: s.hideStatusBar,
        statusTextScale: s.statusTextScale,
      );
      // 上下滚动模式不分页 ⇒ 和 `_paginate()` 的清理保持一致
      if (!_rs.pageMode.paginates) _pages = const [];
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

@override
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
    // 字体库字体不在包里：首次要下载（10MB 上下），先说一声，别让人以为卡死
    final needDownload = ReaderFontService.catalogById(id) != null &&
        !ReaderFontService.instance.isInstalled(id);
    if (needDownload) _toast('首次使用，正在下载字体…');
    unawaited(() async {
      final fam = await ReaderFontService.instance.familyOf(id);
      if (!mounted) return;
      setState(() {
        _fontId = fam == null ? null : id;
        _fontFamily = fam;
      });
      _scheduleRepaginate();
      if (needDownload) {
        _toast(fam == null ? '字体下载失败，已回落系统字体' : '字体已就绪');
      }
    }());
  }

@override
  /// 「字体库」弹层：系统自带（不用下载）+ 可下载字体（点一下就装）。
  ///
  /// 用户 2026-10-25：「系统分组（华文隶书、黑体、苹方…）和思源宋体/霞鹜文楷，
  /// 能不能点一下就装上？」——系统字体按 family 名直接引用，可下载的走
  /// `ReaderFontService.install`（下载 → 注册 → 落盘）。
  Future<void> _showFontLibrary() async {
    var busyId = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget sectionTitle(String t) => Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
            child: Text(t,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _fgMuted)),
          );
          Widget row({
            required String name,
            required String sub,
            required bool selected,
            required String trailing,
            required VoidCallback? onTap,
          }) =>
              InkWell(
                onTap: onTap,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name,
                                style: TextStyle(
                                    fontSize: 14,
                                    color: onTap == null ? _fgMuted : _fg,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w400)),
                            if (sub.isNotEmpty)
                              Text(sub,
                                  style: TextStyle(
                                      fontSize: 11,
                                      height: 1.4,
                                      color: _fgMuted)),
                          ],
                        ),
                      ),
                      if (trailing.isNotEmpty)
                        Text(trailing,
                            style: TextStyle(
                                fontSize: 12,
                                color: selected
                                    ? Theme.of(context).colorScheme.primary
                                    : _fgMuted)),
                    ],
                  ),
                ),
              );

          Future<void> pickSystem(String id) async {
            final fam = await ReaderFontService.instance.familyOf(id);
            if (!mounted || !ctx.mounted) return;
            Navigator.pop(ctx);
            if (fam == null) {
              _toast('这个系统字体不可用');
              return;
            }
            setState(() {
              _fontId = id;
              _fontFamily = fam;
            });
            _scheduleSavePrefs();
            _scheduleRepaginate();
          }

          Future<void> pickCatalog(String id) async {
            final installed = ReaderFontService.instance.isInstalled(id);
            setSheet(() => busyId = id);
            final fam = await ReaderFontService.instance.familyOf(id);
            if (!mounted) return;
            // 下载期间用户可能已经把弹层关掉了 —— 再 setSheet 会踩到已 dispose 的 State
            if (!ctx.mounted) return;
            setSheet(() => busyId = '');
            if (fam == null) {
              _toast('下载失败，换个网络再试');
              return;
            }
            Navigator.pop(ctx);
            setState(() {
              _fontId = id;
              _fontFamily = fam;
            });
            _scheduleSavePrefs();
            _scheduleRepaginate();
            _toast(installed ? '已切换字体' : '已安装并应用');
          }

          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.8,
            ),
            decoration: BoxDecoration(
              color: _bgTop,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 2),
                    child: Row(
                      children: [
                        Text('选择字体',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: _fg)),
                        const Spacer(),
                        Text('长按正文可随时改',
                            style:
                                TextStyle(fontSize: 11, color: _fgMuted)),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                      children: [
                        sectionTitle('系统自带（无需下载）'),
                        for (final f in ReaderFontService.systemFonts)
                          row(
                            name: f.name,
                            sub: f.family,
                            selected: _fontId == f.id,
                            trailing: _fontId == f.id ? '当前' : '',
                            onTap: () => pickSystem(f.id),
                          ),
                        sectionTitle('可下载字体（点一下安装）'),
                        for (final c in ReaderFontService.catalog)
                          row(
                            name: c.name,
                            sub: '${c.desc} · ${c.sizeMb.toStringAsFixed(1)}MB',
                            selected: _fontId == c.id,
                            trailing: busyId == c.id
                                ? '下载中…'
                                : (ReaderFontService.instance.isInstalled(c.id)
                                    ? (_fontId == c.id ? '当前' : '已安装')
                                    : '安装'),
                            onTap: busyId.isEmpty
                                ? () => pickCatalog(c.id)
                                : null,
                          ),
                        sectionTitle('本地导入'),
                        row(
                          name: '从文件导入字体',
                          sub: '支持 ttf / otf / ttc，导入后一直可用（长按字体行可删除）',
                          selected: false,
                          trailing: '选择文件',
                          onTap: () async {
                            // 先关掉弹层再拉系统文件选择器：两个模态叠在一起
                            // 在 iOS 上会互相抢焦点
                            Navigator.pop(ctx);
                            await _importFont();
                          },
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

@override
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

@override
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

@override
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

@override
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

@override
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

@override
  /// 在 [s] 的基础上改几项（用 JSON 往返，避免给 ReaderStyle 写一大堆 copyWith）
  ReaderStyle _patched(ReaderStyle s, Map<String, dynamic> patch) =>
      ReaderStyle.fromJson({...s.toJson(), ...patch});

@override
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

@override
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
                            for (var i = 0; i < _BookSourceReaderPageState._bgs.length; i++)
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
                                    color: _BookSourceReaderPageState._bgs[i][0],
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

@override
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
    // 导入的排版若自带标题 HTML ⇒ 同步存成一条「我的标题样式」，
    // 之后在「排版 → 标题样式」里能直接点（用户 2026-10-25：
    // 「标题样式不能新增我导入的吗？」）。按 HTML 去重，避免反复导入堆积。
    final html = style.chapterTitleHtml.trim();
    if (html.isNotEmpty) {
      final exists = _myTitleStyles.any((t) => t.html.trim() == html);
      if (!exists) {
        final preset = TitleStylePreset(
          id: 'title:${DateTime.now().millisecondsSinceEpoch}',
          name: '${style.name}·标题',
          html: html,
        );
        setState(() => _myTitleStyles = [..._myTitleStyles, preset]);
        await _styleStore.saveTitleStyles(_myTitleStyles);
      }
    }
  }

@override
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
}
