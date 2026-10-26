import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/reading/models/reader_title_style.dart';
import 'package:tvbox/reading/services/reader_style_store.dart';
import 'package:tvbox/reading/services/title_html_parser.dart';

/// 「章标题样式」库：内置模板 + 我的 HTML + 管理（应用/复制/编辑/删除）。
///
/// 两个入口：
///   · 阅读器 → 排版 → 标题样式 → 管理（[onApply] 非空：应用后立即重排）
///   · 我的 → 阅读样式 → 标题样式（standalone：只写 prefs，作为下次阅读的默认）
class ReaderTitleStylesPage extends StatefulWidget {
  const ReaderTitleStylesPage({
    super.key,
    required this.mine,
    required this.current,
    required this.currentHtml,
    required this.background,
    required this.foreground,
    this.onApply,
    this.onChanged,
    this.standalone = false,
  });

  final List<TitleStylePreset> mine;
  final ReaderTitleStyle current;
  final String currentHtml;
  final Color background;
  final Color foreground;

  /// 应用：内置给 (style, '')；我的给 (custom, html)
  final void Function(ReaderTitleStyle style, String html)? onApply;
  final void Function(List<TitleStylePreset>)? onChanged;
  final bool standalone;

  @override
  State<ReaderTitleStylesPage> createState() => _ReaderTitleStylesPageState();
}

class _ReaderTitleStylesPageState extends State<ReaderTitleStylesPage> {
  late List<TitleStylePreset> _mine = List.of(widget.mine);
  late ReaderTitleStyle _current = widget.current;

  final _store = ReaderStyleStore();

  Color get _fg => widget.foreground;
  Color get _bg => widget.background;

  /// 用户 2026-10-25：标题样式只留跟两套阅读样式配套的这两个（+ 默认）
  static const _builtin = <ReaderTitleStyle>[
    ReaderTitleStyle.none,
    ReaderTitleStyle.weRead,
    ReaderTitleStyle.qingLan,
  ];

  String _htmlOf(ReaderTitleStyle s) =>
      s == ReaderTitleStyle.none ? '' : s.html;

  Future<void> _setMine(List<TitleStylePreset> list) async {
    setState(() => _mine = List.of(list));
    await _store.saveTitleStyles(_mine);
    widget.onChanged?.call(List.of(_mine));
  }

  Future<void> _apply(ReaderTitleStyle style, String html) async {
    if (widget.onApply != null) {
      widget.onApply!(style, html);
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final p = await SharedPreferences.getInstance();
    await p.setString('reading.chapterTitleStyle', style.id);
    await p.setString('reading.chapterTitleHtml', html);
    if (!mounted) return;
    setState(() => _current = style);
    _toast('已设为默认标题样式');
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text, style: TextStyle(fontSize: 13, color: _fg)),
        backgroundColor: _fg.withValues(alpha: 0.14),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1500),
      ),
    );
  }

  Future<void> _newOne() async {
    final html = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _HtmlEditPage(
          title: '新建标题样式',
          initial: ReaderTitleStyle.starterTemplate,
          background: _bg,
          foreground: _fg,
        ),
      ),
    );
    if (html == null || !mounted) return;
    await _addFromHtml(html, '我的标题样式 ${_mine.length + 1}');
  }

  Future<void> _editHtml(TitleStylePreset preset) async {
    final html = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _HtmlEditPage(
          title: '编辑「${preset.name}」',
          initial: preset.html,
          background: _bg,
          foreground: _fg,
        ),
      ),
    );
    if (html == null || !mounted) return;
    final list = List.of(_mine);
    final idx = list.indexWhere((e) => e.id == preset.id);
    if (idx >= 0) {
      list[idx] = TitleStylePreset(id: preset.id, name: preset.name, html: html);
    } else {
      list.add(TitleStylePreset(id: preset.id, name: preset.name, html: html));
    }
    await _setMine(list);
  }

  Future<void> _addFromHtml(String html, String name) async {
    final preset = TitleStylePreset(
      id: 'title:${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      html: html,
    );
    await _setMine([..._mine, preset]);
    _toast('已保存「$name」');
  }

  /// 内置 → 复制成我的（含编辑）
  Future<void> _copyBuiltin(ReaderTitleStyle s, {bool edit = false}) async {
    final preset = TitleStylePreset(
      id: 'title:${DateTime.now().millisecondsSinceEpoch}',
      name: '${s.label} 副本',
      html: s.html,
    );
    await _setMine([..._mine, preset]);
    if (edit) await _editHtml(preset);
  }

  Future<void> _rename(TitleStylePreset p) async {
    final ctrl = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _bg,
        title: Text('重命名', style: TextStyle(fontSize: 16, color: _fg)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: _fg),
          decoration: InputDecoration(
            filled: true,
            fillColor: _fg.withValues(alpha: 0.06),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text('取消', style: TextStyle(color: _fg.withValues(alpha: 0.6))),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            style: FilledButton.styleFrom(
              backgroundColor: _fg,
              foregroundColor: _bg,
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final list = List.of(_mine);
    final idx = list.indexWhere((e) => e.id == p.id);
    if (idx >= 0) {
      list[idx] = TitleStylePreset(id: p.id, name: name, html: p.html);
      await _setMine(list);
    }
  }

  Future<void> _delete(TitleStylePreset p) async {
    await _setMine(_mine.where((e) => e.id != p.id).toList());
    _toast('已删除「${p.name}」');
  }

  Future<void> _showBuiltinActions(ReaderTitleStyle s) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  s.label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _fg,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.check_circle_outline, color: _fg),
              title: Text('应用', style: TextStyle(color: _fg)),
              onTap: () {
                Navigator.pop(c);
                _apply(s, _htmlOf(s));
              },
            ),
            if (s != ReaderTitleStyle.none) ...[
              ListTile(
                leading: Icon(Icons.copy_rounded, color: _fg),
                title: Text('复制成我的样式', style: TextStyle(color: _fg)),
                onTap: () {
                  Navigator.pop(c);
                  _copyBuiltin(s);
                },
              ),
              ListTile(
                leading: Icon(Icons.edit_outlined, color: _fg),
                title: Text('复制并编辑 HTML', style: TextStyle(color: _fg)),
                onTap: () {
                  Navigator.pop(c);
                  _copyBuiltin(s, edit: true);
                },
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _showMineActions(TitleStylePreset p) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  p.name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _fg,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.check_circle_outline, color: _fg),
              title: Text('应用', style: TextStyle(color: _fg)),
              onTap: () {
                Navigator.pop(c);
                _apply(ReaderTitleStyle.custom, p.html);
              },
            ),
            ListTile(
              leading: Icon(Icons.edit_outlined, color: _fg),
              title: Text('编辑 HTML', style: TextStyle(color: _fg)),
              onTap: () {
                Navigator.pop(c);
                _editHtml(p);
              },
            ),
            ListTile(
              leading: Icon(Icons.drive_file_rename_outline, color: _fg),
              title: Text('重命名', style: TextStyle(color: _fg)),
              onTap: () {
                Navigator.pop(c);
                _rename(p);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: _fg.withValues(alpha: 0.8),
              ),
              title: Text('删除', style: TextStyle(color: _fg)),
              onTap: () {
                Navigator.pop(c);
                _delete(p);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: _fg,
        title: Text(
          '标题样式',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: _fg),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          _label('内置模板 ${_builtin.length} 套 · 长按管理'),
          // 固定一行两个：按可用宽度算卡片宽度，居中、比原来大一圈
          // （用户 2026-10-25：原来 Wrap + 固定 150 宽，右边留一大块空，很乱）
          LayoutBuilder(
            builder: (context, c) {
              const gap = 14.0;
              final w = ((c.maxWidth - gap) / 2).clamp(120.0, 260.0);
              return Wrap(
                spacing: gap,
                runSpacing: 18,
                alignment: WrapAlignment.center,
                children: [
                  for (final s in _builtin)
                    _card(
                      width: w,
                      name: s.label,
                      html: _htmlOf(s),
                      selected: s == _current && widget.currentHtml.isEmpty,
                      onTap: () => _apply(s, _htmlOf(s)),
                      onMore: s == ReaderTitleStyle.none
                          ? null
                          : () => _showBuiltinActions(s),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          _label('我的标题样式 ${_mine.length} 套'),
          if (_mine.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '还没有。可以从上面的内置模板「复制成我的样式」，或直接新建一段 HTML。',
                style: TextStyle(fontSize: 12, color: _fg.withValues(alpha: 0.45)),
              ),
            )
          else
            for (final p in _mine)
              _row(
                p,
                selected: _current == ReaderTitleStyle.custom &&
                    widget.currentHtml == p.html,
                onTap: () => _apply(ReaderTitleStyle.custom, p.html),
                onMore: () => _showMineActions(p),
              ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _newOne,
              icon: Icon(Icons.add_rounded, size: 18, color: _fg),
              label: Text(
                '新建标题样式（粘贴 HTML）',
                style: TextStyle(color: _fg, fontSize: 14),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: _fg.withValues(alpha: 0.22)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 10),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: _fg.withValues(alpha: 0.55),
        letterSpacing: 0.3,
      ),
    ),
  );

  Widget _card({
    required double width,
    required String name,
    required String html,
    required bool selected,
    required VoidCallback onTap,
    VoidCallback? onMore,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onMore,
      child: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  height: 104,
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _fg.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected ? _fg : _fg.withValues(alpha: 0.16),
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: _preview(html),
                ),
                if (selected)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Icon(
                      Icons.check_circle_rounded,
                      size: 15,
                      color: _fg,
                      shadows: const [
                        Shadow(color: Colors.black45, blurRadius: 4),
                      ],
                    ),
                  ),
                if (onMore != null)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: GestureDetector(
                      onTap: onMore,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: _fg.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.more_horiz_rounded,
                          size: 13,
                          color: _fg.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: _fg.withValues(alpha: selected ? 1 : 0.72),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    TitleStylePreset p, {
    required bool selected,
    required VoidCallback onTap,
    required VoidCallback onMore,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: _fg.withValues(alpha: selected ? 0.10 : 0.05),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          onLongPress: onMore,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                SizedBox(width: 84, height: 52, child: _preview(p.html)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    p.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: _fg,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    size: 18,
                    color: _fg.withValues(alpha: 0.7),
                  ),
                  onPressed: onMore,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 离线渲染一小段标题（不联网；图片资源缺失时退化成文字）
  Widget _preview(String html) {
    if (html.trim().isEmpty) {
      return Center(
        child: Text(
          '默认标题',
          style: TextStyle(fontSize: 12, color: _fg.withValues(alpha: 0.55)),
        ),
      );
    }
    final doc = TitleHtml.compile(
      html,
      chapterNumber: '',
      chapterName: '第三章 临时讲课',
    );
    if (doc.isEmpty) {
      return Center(
        child: Text(
          '（空模板）',
          style: TextStyle(fontSize: 12, color: _fg.withValues(alpha: 0.45)),
        ),
      );
    }
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        // 居中放大：原来 topLeft 靠左上，卡片右侧一大块空白
        alignment: Alignment.center,
        child: SizedBox(
          width: 300,
          child: TitleHtml.build(
            doc,
            // 与阅读器一致：HTML 标题的 em 基准是**正文字号**（内置样式多为
            // 19/20）。原来预览用 16，看起来比真机小一号，"预览挺好、进去太大"。
            baseFontSize: 19,
            fallbackColor: _fg,
          ),
        ),
      ),
    );
  }
}

/// 一个极简的 HTML 编辑页（多行、等宽字体、保存/取消）。
class _HtmlEditPage extends StatefulWidget {
  const _HtmlEditPage({
    required this.title,
    required this.initial,
    required this.background,
    required this.foreground,
  });

  final String title;
  final String initial;
  final Color background;
  final Color foreground;

  @override
  State<_HtmlEditPage> createState() => _HtmlEditPageState();
}

class _HtmlEditPageState extends State<_HtmlEditPage> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.foreground;
    return Scaffold(
      backgroundColor: widget.background,
      appBar: AppBar(
        backgroundColor: widget.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: fg,
        title: Text(
          widget.title,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: fg),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_ctrl.text),
            child: Text('保存', style: TextStyle(color: fg, fontSize: 15)),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 20),
        child: TextField(
          controller: _ctrl,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: TextStyle(
            color: fg,
            fontSize: 12.5,
            height: 1.6,
            fontFamily: 'monospace',
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: fg.withValues(alpha: 0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            hintText: '粘贴源阅读的标题 HTML（可以用 asset:assets/images/... 引本地图）',
            hintStyle: TextStyle(color: fg.withValues(alpha: 0.3), fontSize: 12),
          ),
        ),
      ),
    );
  }
}
