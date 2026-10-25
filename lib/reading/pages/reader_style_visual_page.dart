import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/reader_bg_assets.dart';
import '../models/reader_style.dart';
import '../models/reader_title_style.dart';
import '../services/reader_font_service.dart';
import '../services/reader_style_store.dart';
import '../services/title_html_parser.dart';
import 'reader_style_edit_page.dart';
import 'reader_title_styles_page.dart';

/// 可点击的区域
enum _Zone { header, title, body, footer, margin, background }

/// 「阅读样式」可视化编辑器（全屏预览 + 点哪调哪）。
///
/// 设计（用户 2026-10-25）：
///   · 预览**全屏**，按真实字号/行高/边距渲染，所见即所得；
///   · 点某一块 → 屏幕中间弹**小浮层**（宽 85%、最高 45%），内容多了内部滚动；
///   · 标题不再是独立入口：它只是本页的一个区域，与整体样式同一份数据；
///   · 右上角保留「完整表单」入口（复用旧的 [ReaderStyleEditPage]），不丢功能。
class ReaderStyleVisualPage extends StatefulWidget {
  const ReaderStyleVisualPage({
    super.key,
    required this.style,
    required this.background,
    required this.foreground,
    this.title = '编辑样式',
  });

  final ReaderStyle style;
  final Color background;
  final Color foreground;
  final String title;

  @override
  State<ReaderStyleVisualPage> createState() => _ReaderStyleVisualPageState();
}

class _ReaderStyleVisualPageState extends State<ReaderStyleVisualPage> {
  /// 可变草稿：直接改 JSON，保存时再 fromJson，避免几十个字段来回复制
  late Map<String, dynamic> _j;
  late bool _night;
  _Zone? _active;

  /// 拖动页缘时的数值提示（拖动中显示，松手消失）
  String? _dragHint;

  /// 预览用的字体族（跟随样式里的 fontId，异步取）
  String? _previewFamily;

  final _store = ReaderStyleStore();

  /// 底色预设（与完整表单一致）
  static const _bgPresets = <int>[
    0xFFFFFFFF,
    0xFFFAF8F3,
    0xFFF5EFE0,
    0xFFEBD9BB,
    0xFFDDC090,
    0xFFC2D8AA,
    0xFFABCEE0,
    0xFFDBB8E2,
    0xFFD6D5D6,
    0xFFEEEEEE,
    0xFF1F232B,
    0xFF292D37,
    0xFF000000,
  ];

  @override
  void initState() {
    super.initState();
    _j = Map<String, dynamic>.from(widget.style.toJson());
    // 默认预览当前 App 明暗（编辑器外壳是深色/浅色跟着走）
    _night = widget.background.computeLuminance() < 0.4;
    _loadFamily();
  }

  /// 取当前样式的字体族（预览要立刻看得到效果）
  Future<void> _loadFamily() async {
    try {
      await ReaderFontService.instance.load();
      final fam = await ReaderFontService.instance.familyOf(
        _j['fontId'] as String?,
      );
      if (mounted) setState(() => _previewFamily = fam);
    } catch (_) {}
  }

  // ── 草稿读取 ────────────────────────────────────────────────
  double _d(String k, double def) => (_j[k] as num?)?.toDouble() ?? def;
  int _i(String k, int def) => (_j[k] as num?)?.toInt() ?? def;
  String _s(String k, String def) => (_j[k] as String?) ?? def;

  Color get _paper {
    final v = _night ? (_j['bgColorNight'] as num?) : (_j['bgColor'] as num?);
    if (v != null) return Color(v.toInt());
    return _night ? const Color(0xFF1F232B) : const Color(0xFFFAF8F3);
  }

  Color get _ink {
    final v = _night ? (_j['fgColorNight'] as num?) : (_j['fgColor'] as num?);
    if (v != null) return Color(v.toInt());
    return _night ? const Color(0xFFC8C8C8) : const Color(0xFF2B2B2B);
  }

  String? get _wallpaper =>
      _night ? (_j['bgImageAssetNight'] as String?) : (_j['bgImageAsset'] as String?);

  /// 章节标题 HTML（当前日夜）
  String get _titleSrc {
    final id = _s('chapterTitleStyle', '');
    final style = ReaderTitleStyle.fromId(id);
    if (style == ReaderTitleStyle.none) return '';
    if (style == ReaderTitleStyle.custom) {
      final custom = _night
          ? _s('chapterTitleHtmlNight', '')
          : _s('chapterTitleHtml', '');
      return custom.isNotEmpty ? custom : _s('chapterTitleHtml', '');
    }
    final night = style.nightHtml;
    return (_night && night.isNotEmpty) ? night : style.html;
  }

  double get _titleScale => _d('titleScale', 1.0);
  double get _titleGap => _d('titleGap', 0);

  Future<void> _save() async {
    Navigator.of(context).pop(ReaderStyle.fromJson(_j));
  }

  /// 进「完整表单」（复用旧页），回来合并结果
  Future<void> _openFullForm() async {
    final out = await Navigator.of(context).push<ReaderStyle>(
      MaterialPageRoute(
        builder: (_) => ReaderStyleEditPage(
          style: ReaderStyle.fromJson(_j),
          background: widget.background,
          foreground: widget.foreground,
          title: '完整表单',
        ),
      ),
    );
    if (out != null && mounted) {
      setState(() => _j = Map<String, dynamic>.from(out.toJson()));
    }
  }

  /// 当前字体显示名
  String get _fontLabel {
    final id = _j['fontId'] as String? ?? '';
    if (id.isEmpty) return '系统默认';
    final list = ReaderFontService.instance.fonts;
    final idx = list.indexWhere((f) => f.id == id);
    return idx >= 0 ? list[idx].name : '自定义';
  }

  /// 选字体（含导入）
  Future<void> _pickFont() async {
    final svc = ReaderFontService.instance;
    await svc.load();
    if (!mounted) return;
    const importTag = '__import_font__';
    final picked = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('选择字体'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, ''),
            child: const Text('系统默认'),
          ),
          for (final f in svc.fonts)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, f.id),
              child: Text(f.name),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, importTag),
            child: const Row(
              children: [
                Icon(Icons.add, size: 16),
                SizedBox(width: 6),
                Text('导入字体（ttf / otf / ttc）'),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    if (picked == importTag) {
      await _importFont();
      return;
    }
    setState(() => _j['fontId'] = picked);
    await _loadFamily();
  }

  Future<void> _importFont() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['ttf', 'otf', 'ttc'],
    );
    if (files.isEmpty) return;
    final picked = files.first;
    final base = picked.name.replaceAll(
      RegExp(r'\.(ttf|otf|ttc)$', caseSensitive: false),
      '',
    );
    try {
      final bytes = await picked.readAsBytes();
      final font = await ReaderFontService.instance.importBytes(
        bytes,
        name: base,
      );
      if (font == null || !mounted) return;
      setState(() => _j['fontId'] = font.id);
      await _loadFamily();
    } catch (_) {}
  }

  /// 换标题版式（在「标题」浮层里进入）
  Future<void> _pickTitleStyle() async {
    final titles = await _store.loadTitleStyles();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ReaderTitleStylesPage(
          mine: titles,
          current: ReaderTitleStyle.fromId(_s('chapterTitleStyle', '')),
          currentHtml: _s('chapterTitleHtml', ''),
          background: _paper,
          foreground: _ink,
          onApply: (style, html) {
            setState(() {
              _j['chapterTitleStyle'] = style.id;
              if (style == ReaderTitleStyle.custom) {
                _j['chapterTitleHtml'] = html;
              }
            });
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _paper,
      body: Stack(
        children: [
          // ① 全屏预览
          Positioned.fill(child: _buildPreview()),
          // ② 左右页缘：可拖动改边距（实时）
          _edgeDrag(left: true),
          _edgeDrag(left: false),
          // ③ 拖动数值提示
          if (_dragHint != null)
            Positioned(
              top: 64,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: _ink.withValues(alpha: 0.82),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _dragHint!,
                      style: TextStyle(fontSize: 11.5, color: _paper),
                    ),
                  ),
                ),
              ),
            ),
          // ④ 悬浮顶栏
          _topBar(),
          // ⑤ 底部区域切换
          _zoneBar(),
        ],
      ),
    );
  }

  /// 页缘竖线：按住左右拖动直接改边距（所见即所得）。
  ///
  /// 拖动时**实时读当前值**再叠加 delta（而不是用 build 时捕获的值），
  /// 否则连续拖动会因为重建而丢失增量。
  Widget _edgeDrag({required bool left}) {
    final key = left ? 'padLeft' : 'padRight';
    final v = _d(key, 22).clamp(0.0, 80.0).toDouble();
    final pos = (v - 14).clamp(0.0, 1000.0).toDouble();
    return Positioned(
      top: 0,
      bottom: 0,
      left: left ? pos : null,
      right: left ? null : pos,
      width: 28,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) {
          final cur = _d(key, 22).clamp(0.0, 80.0).toDouble();
          final next = (cur + (left ? d.delta.dx : -d.delta.dx))
              .clamp(0.0, 80.0)
              .toDouble();
          setState(() {
            _j[key] = next;
            _dragHint = '${left ? '左边距' : '右边距'} ${next.round()}';
          });
        },
        onHorizontalDragEnd: (_) => setState(() => _dragHint = null),
        onHorizontalDragCancel: () => setState(() => _dragHint = null),
        child: Center(
          child: Container(
            width: 3,
            decoration: BoxDecoration(
              color: _ink.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  // ── 预览（与阅读器同参渲染）────────────────────────────────
  Widget _buildPreview() {
    final fs = _d('fontSize', 19);
    final lh = _d('lineHeight', 1.6);
    final ls = _d('letterSpacing', 0.3);
    final fw = FontWeight.values[((_d('fontWeight', 400) ~/ 100) - 1).clamp(0, 8)];
    final indent = _d('indent', 2).round();
    const demo =
        '山色空蒙雨亦奇，水光潋滟晴方好。远处传来几声钟响，惊起了林间的宿鸟，扑簌簌掠过窗前。'
        '案上的茶还温着，摊开的书页被风掀起一角，露出昨日夹在里面的那枚枯叶。';
    final text = List.filled(indent, '\u3000').join() + demo;

    final dim = _night ? _d('nightDim', 0.45).clamp(0.0, 0.8) : 0.0;
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _paper,
              image: _wallpaper == null
                  ? null
                  : DecorationImage(
                      image: AssetImage(_wallpaper!),
                      fit: BoxFit.cover,
                    ),
            ),
          ),
        ),
        // 夜间压暗：只压背景层，不压文字（与阅读器 _nightDim 一致）
        if (dim > 0.01)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: dim),
              ),
            ),
          ),
        Positioned.fill(
          child: Padding(
        padding: EdgeInsets.fromLTRB(
          _d('padLeft', 22).clamp(0, 80),
          _d('padTop', 18).clamp(0, 120),
          _d('padRight', 22).clamp(0, 80),
          _d('padBottom', 28).clamp(0, 120),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 页眉
            _tap(_Zone.header, child: _headerRow()),
            SizedBox(height: _d('headerPadTop', 6).clamp(0, 80) * 0.5),
            // 章节标题
            _tap(_Zone.title, child: _titleBlock()),
            SizedBox(height: _titleGap),
            // 正文
            Expanded(
              child: _tap(
                _Zone.body,
                child: ClipRect(
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: fs,
                      height: lh,
                      letterSpacing: ls,
                      fontWeight: fw,
                      fontFamily: _previewFamily,
                      color: _ink,
                    ),
                  ),
                ),
              ),
            ),
            // 页脚
            _tap(_Zone.footer, child: _footerRow()),
          ],
        ),
          ),
        ),
      ],
    );
  }

  Widget _headerRow() {
    final c = _ink.withValues(alpha: 0.55);
    final scale = _d('statusTextScale', 1.0).clamp(0.6, 2.0);
    final s = TextStyle(fontSize: 10 * scale, color: c);
    return Row(
      children: [
        Expanded(
          child: Text(
            _s('headerL', '') .isEmpty ? '風起於青萍之末' : _s('headerL', ''),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: s,
          ),
        ),
        Text(
          _s('headerR', '').isEmpty ? '12:30' : _s('headerR', ''),
          style: s,
        ),
      ],
    );
  }

  Widget _footerRow() {
    final c = _ink.withValues(alpha: 0.55);
    final scale = _d('statusTextScale', 1.0).clamp(0.6, 2.0);
    final s = TextStyle(fontSize: 10 * scale, color: c);
    return Row(
      children: [
        Expanded(
          child: Text(
            _s('footerL', '').isEmpty ? '第 1 页' : _s('footerL', ''),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: s,
          ),
        ),
        Text(
          _s('footerC', '').isEmpty ? '12%' : _s('footerC', ''),
          style: s,
        ),
        Expanded(
          child: Text(
            _s('footerR', ''),
            maxLines: 1,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: s,
          ),
        ),
      ],
    );
  }

  Widget _titleBlock() {
    final src = _titleSrc;
    if (src.trim().isEmpty) {
      final size = _d('titleFontSize', -1);
      final base = size > 0 ? size : _d('fontSize', 19) + 3;
      return Align(
        alignment: _i('titleAlign', 0) == 1
            ? Alignment.center
            : Alignment.centerLeft,
        child: Text(
          '第一章 风起于青萍之末',
          textAlign: _i('titleAlign', 0) == 1 ? TextAlign.center : TextAlign.left,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: base * _titleScale,
            height: 1.5,
            fontWeight: (_j['titleBold'] as bool? ?? true)
                ? FontWeight.w700
                : FontWeight.w400,
            color: _ink,
            letterSpacing: 0,
          ),
        ),
      );
    }
    final doc = TitleHtml.compile(
      src,
      chapterNumber: '1',
      chapterName: '第一章 风起于青萍之末',
    );
    if (doc.isEmpty) return const SizedBox.shrink();
    return ClipRect(
      child: OverflowBox(
        alignment: _i('titleAlign', 0) == 1
            ? Alignment.topCenter
            : Alignment.topLeft,
        minWidth: 0,
        maxHeight: double.infinity,
        child: TitleHtml.build(
          doc,
          baseFontSize: _d('fontSize', 19) * _titleScale,
          fallbackColor: _ink,
          pxScale: _titleScale,
        ),
      ),
    );
  }

  Widget _tap(_Zone z, {required Widget child}) {
    final on = _active == z;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openPanel(z),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: on
              ? Border.all(
                  color: _ink.withValues(alpha: 0.45),
                  width: 1,
                )
              : null,
        ),
        child: child,
      ),
    );
  }

  // ── 悬浮顶栏 / 底部区域条 ───────────────────────────────────
  Widget _topBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          child: Row(
            children: [
              _glassChip(
                icon: _night ? Icons.dark_mode : Icons.light_mode,
                label: _night ? '夜间' : '日间',
                onTap: () => setState(() => _night = !_night),
              ),
              const Spacer(),
              _glassChip(
                icon: Icons.tune,
                label: '完整表单',
                onTap: _openFullForm,
              ),
              const SizedBox(width: 6),
              _glassChip(
                icon: Icons.check,
                label: '保存',
                onTap: _save,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _glassChip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: _ink.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: _ink),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11.5, color: _ink)),
          ],
        ),
      ),
    );
  }

  Widget _zoneBar() {
    const zones = <(_Zone, String)>[
      (_Zone.margin, '边距'),
      (_Zone.header, '页眉'),
      (_Zone.title, '标题'),
      (_Zone.body, '正文'),
      (_Zone.footer, '页脚'),
      (_Zone.background, '背景'),
    ];
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          decoration: BoxDecoration(
            color: _ink.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              for (final z in zones)
                Expanded(
                  child: GestureDetector(
                    onTap: () => _openPanel(z.$1),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      decoration: BoxDecoration(
                        color: _active == z.$1
                            ? _ink.withValues(alpha: 0.16)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        z.$2,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11.5, color: _ink),
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

  // ── 中央悬浮参数卡 ─────────────────────────────────────────
  Future<void> _openPanel(_Zone z) async {
    setState(() => _active = z);
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.06),
      barrierDismissible: true,
      builder: (ctx) => _PanelHost(
        title: _zoneLabel(z),
        ink: _ink,
        paper: _paper,
        child: StatefulBuilder(
          builder: (c, setDlg) {
            void apply(VoidCallback fn) {
              fn();
              setDlg(() {});
              setState(() {}); // 让背后的全屏预览实时更新
            }
            return _zoneFields(z, apply);
          },
        ),
      ),
    );
    if (mounted) setState(() => _active = null);
  }

  String _zoneLabel(_Zone z) => switch (z) {
    _Zone.header => '页眉',
    _Zone.title => '章节标题',
    _Zone.body => '正文',
    _Zone.footer => '页脚',
    _Zone.margin => '边距',
    _Zone.background => '背景',
  };

  Widget _zoneFields(_Zone z, void Function(VoidCallback) apply) {
    switch (z) {
      case _Zone.header:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _textRow('左', 'headerL', apply),
            _textRow('中', 'headerC', apply),
            _textRow('右', 'headerR', apply),
            _slider('字号缩放', _d('statusTextScale', 1.0), 0.6, 2.0, apply,
                key: 'statusTextScale', fmt: (v) => '${(v * 100).round()}%'),
            _slider('上边距', _d('headerPadTop', 6), 0, 60, apply,
                key: 'headerPadTop'),
          ],
        );
      case _Zone.title:
        final style = ReaderTitleStyle.fromId(_s('chapterTitleStyle', ''));
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '版式：${style.label}',
                    style: TextStyle(fontSize: 12.5, color: _ink),
                  ),
                ),
                TextButton(
                  onPressed: _pickTitleStyle,
                  child: const Text('更换'),
                ),
              ],
            ),
            _slider('标题大小', _titleScale, 0.6, 1.6, apply,
                key: 'titleScale', fmt: (v) => '${(v * 100).round()}%', step: 0.05),
            _slider('标题间距', _titleGap, 0, 40, apply, key: 'titleGap', step: 2),
            _slider(
              '标题字号',
              _d('titleFontSize', 0),
              0,
              40,
              apply,
              key: 'titleFontSize',
              fmt: (v) => v <= 0 ? '跟随' : v.round().toString(),
            ),
            Row(
              children: [
                Text('对齐', style: TextStyle(fontSize: 12.5, color: _ink)),
                const SizedBox(width: 12),
                for (final n in ['靠左', '居中'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => apply(
                        () => _j['titleAlign'] = n == '靠左' ? 0 : 1,
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: _i('titleAlign', 0) == (n == '靠左' ? 0 : 1)
                              ? _ink.withValues(alpha: 0.85)
                              : _ink.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          n,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: _i('titleAlign', 0) == (n == '靠左' ? 0 : 1)
                                ? _paper
                                : _ink,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      case _Zone.body:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 字体（含导入）：改完预览立即换字体
            Row(
              children: [
                SizedBox(
                  width: 62,
                  child: Text(
                    '字体',
                    style: TextStyle(fontSize: 12, color: _ink),
                  ),
                ),
                Expanded(
                  child: Text(
                    _fontLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: _ink.withValues(alpha: 0.7),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _pickFont,
                  child: const Text('更换'),
                ),
              ],
            ),
            _slider('字号', _d('fontSize', 19), 12, 30, apply,
                key: 'fontSize'),
            _slider('行高', _d('lineHeight', 1.6), 1.05, 3.0, apply,
                key: 'lineHeight', step: 0.05, fmt: (v) => v.toStringAsFixed(2)),
            _slider('字距', _d('letterSpacing', 0.3), -2, 8, apply,
                key: 'letterSpacing', step: 0.1, fmt: (v) => v.toStringAsFixed(1)),
            _slider('段距', _d('paraSpacing', 0.5), 0, 2, apply,
                key: 'paraSpacing', step: 0.05, fmt: (v) => '${v.toStringAsFixed(2)}x'),
            _slider('首行缩进', _d('indent', 2), 0, 4, apply,
                key: 'indent', fmt: (v) => '${v.round()} 字'),
            _slider('字重', _d('fontWeight', 400), 300, 900, apply,
                key: 'fontWeight', step: 50, fmt: (v) => v.round().toString()),
          ],
        );
      case _Zone.footer:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _textRow('左', 'footerL', apply),
            _textRow('中', 'footerC', apply),
            _textRow('右', 'footerR', apply),
            _slider('下边距', _d('footerPadBottom', 6), 0, 60, apply,
                key: 'footerPadBottom'),
          ],
        );
      case _Zone.margin:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _slider('左', _d('padLeft', 22), 0, 80, apply, key: 'padLeft'),
            _slider('右', _d('padRight', 22), 0, 80, apply, key: 'padRight'),
            _slider('上', _d('padTop', 18), 0, 120, apply, key: 'padTop'),
            _slider('下', _d('padBottom', 28), 0, 120, apply, key: 'padBottom'),
          ],
        );
      case _Zone.background:
        final bgKey = _night ? 'bgColorNight' : 'bgColor';
        final wpKey = _night ? 'bgImageAssetNight' : 'bgImageAsset';
        final curBg = (_j[bgKey] as num?)?.toInt();
        final curWp = _j[wpKey] as String?;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 日/夜：直接切预览
            Row(
              children: [
                Text(
                  '预览',
                  style: TextStyle(fontSize: 12.5, color: _ink),
                ),
                const SizedBox(width: 12),
                for (final n in ['日间', '夜间'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => apply(() => _night = n == '夜间'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: _night == (n == '夜间')
                              ? _ink.withValues(alpha: 0.85)
                              : _ink.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          n,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: _night == (n == '夜间') ? _paper : _ink,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '底色（${_night ? '夜间' : '日间'}）',
              style: TextStyle(fontSize: 11.5, color: _ink.withValues(alpha: 0.65)),
            ),
            const SizedBox(height: 7),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                _swatch(
                  null,
                  curBg == null,
                  // 「不设底色」只清颜色，不动壁纸（壁纸在下面单独选）
                  () => apply(() => _j[bgKey] = null),
                ),
                for (final c in _bgPresets)
                  _swatch(
                    Color(c),
                    curBg == c,
                    () => apply(() => _j[bgKey] = c),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '壁纸',
              style: TextStyle(fontSize: 11.5, color: _ink.withValues(alpha: 0.65)),
            ),
            const SizedBox(height: 7),
            SizedBox(
              height: 58,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: ReaderBgAssets.picker.length + 1,
                separatorBuilder: (_, __) => const SizedBox(width: 7),
                itemBuilder: (c, i) {
                  if (i == 0) {
                    return _wallTile(null, curWp == null, () => apply(() {
                          _j[wpKey] = null;
                        }));
                  }
                  final asset = ReaderBgAssets.picker[i - 1];
                  return _wallTile(asset, curWp == asset, () => apply(() {
                        _j[wpKey] = asset;
                        // 日间选了成对壁纸 → 顺手补上夜间那张
                        if (!_night) {
                          final pair = ReaderBgAssets.pairOf(asset);
                          if (pair != null) _j['bgImageAssetNight'] = pair;
                        }
                      }));
                },
              ),
            ),
            const SizedBox(height: 12),
            _slider(
              '夜间压暗',
              _d('nightDim', 0.45),
              0,
              0.8,
              apply,
              key: 'nightDim',
              step: 0.05,
              fmt: (v) => '${(v * 100).round()}%',
            ),
          ],
        );
    }
  }

  Widget _swatch(Color? color, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: color ?? Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: selected ? _ink : _ink.withValues(alpha: 0.22),
            width: selected ? 2 : 1,
          ),
        ),
        child: color == null
            ? Icon(Icons.block, size: 12, color: _ink.withValues(alpha: 0.6))
            : null,
      ),
    );
  }

  Widget _wallTile(String? asset, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 58,
        decoration: BoxDecoration(
          color: _ink.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? _ink : _ink.withValues(alpha: 0.2),
            width: selected ? 2 : 1,
          ),
          image: asset == null
              ? null
              : DecorationImage(
                  image: AssetImage(asset),
                  fit: BoxFit.cover,
                ),
        ),
        child: asset == null
            ? Icon(Icons.block, size: 13, color: _ink.withValues(alpha: 0.6))
            : null,
      ),
    );
  }

  Widget _textRow(String label, String key, void Function(VoidCallback) apply) {
    // 用 TextFormField(initialValue) 而不是每次 new 一个 controller：
    // 滑杆/输入触发重建时，FormField 会保留自身 State ⇒ 光标不跳、字符不丢。
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(label, style: TextStyle(fontSize: 12, color: _ink)),
          ),
          Expanded(
            child: TextFormField(
              initialValue: _s(key, ''),
              style: TextStyle(fontSize: 12.5, color: _ink),
              decoration: InputDecoration(
                isDense: true,
                hintText: '留空则用默认',
                hintStyle: TextStyle(
                  fontSize: 12,
                  color: _ink.withValues(alpha: 0.35),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onChanged: (v) => apply(() => _j[key] = v),
            ),
          ),
        ],
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    void Function(VoidCallback) apply, {
    required String key,
    double? step,
    String Function(double)? fmt,
  }) {
    final v = value.clamp(min, max).toDouble();
    final st = step ?? 1.0;
    double snap(double x) => ((x / st).round() * st).clamp(min, max).toDouble();
    return Row(
      children: [
        SizedBox(
          width: 62,
          child: Text(label, style: TextStyle(fontSize: 12, color: _ink)),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: _ink,
              inactiveTrackColor: _ink.withValues(alpha: 0.18),
              thumbColor: _ink,
            ),
            child: Slider(
              value: v,
              min: min,
              max: max,
              divisions: ((max - min) / st).round().clamp(1, 400),
              onChanged: (x) => apply(() => _j[key] = snap(x)),
            ),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            (fmt ?? (x) => x.round().toString())(v),
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 11.5, color: _ink.withValues(alpha: 0.7)),
          ),
        ),
      ],
    );
  }
}

/// 中央小浮层：宽 85%、最高 45%，内容多了内部滚动。
class _PanelHost extends StatelessWidget {
  const _PanelHost({
    required this.title,
    required this.ink,
    required this.paper,
    required this.child,
  });

  final String title;
  final Color ink;
  final Color paper;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: size.width * 0.85,
          constraints: BoxConstraints(maxHeight: size.height * 0.45),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          decoration: BoxDecoration(
            color: paper.withValues(alpha: 0.97),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: ink.withValues(alpha: 0.12)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Icon(Icons.close, size: 18, color: ink),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Flexible(child: SingleChildScrollView(child: child)),
            ],
          ),
        ),
      ),
    );
  }
}
