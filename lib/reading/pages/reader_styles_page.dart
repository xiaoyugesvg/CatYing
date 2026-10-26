import 'package:flutter/material.dart';

import 'package:tvbox/reading/models/reader_style.dart';
import 'package:tvbox/reading/services/reader_style_store.dart';
import 'package:tvbox/reading/pages/reader_style_visual_page.dart';

/// 「阅读样式」库：内置样式 + 我的样式 + 管理（复制/编辑/删除/排序）。
///
/// 两个入口共用：
///   · 阅读器 → 排版 → 样式 → 打开样式库（[onApply] 非空：点卡片直接套用并返回）
///   · 阅读模块「我的」→ 阅读样式（[onApply] 为空：点卡片只记成默认样式）
///
/// 编辑/复制/删除在本页完成并直接写 [ReaderStyleStore]，
/// 有阅读器时通过 [onChanged] 把最新的「我的样式」回传，避免两处状态不一致。
class ReaderStylesPage extends StatefulWidget {
  const ReaderStylesPage({
    super.key,
    required this.builtins,
    required this.mine,
    required this.activeId,
    required this.background,
    required this.foreground,
    this.night = false,
    this.onApply,
    this.onChanged,
    this.onSaveCurrent,
    this.standalone = false,
  });

  final List<ReaderStyle> builtins;
  final List<ReaderStyle> mine;
  final String? activeId;
  final Color background;
  final Color foreground;

  /// 当前是否夜间（卡片小样按对应那套配色预览，不再永远显示日间亮色）
  final bool night;

  /// 阅读器模式：选中后回调（由调用方套用并关闭页面）
  final void Function(ReaderStyle)? onApply;

  /// 「我的样式」变化（编辑/复制/删除/排序后）
  final void Function(List<ReaderStyle>)? onChanged;

  /// 阅读器模式：把当前阅读外观存成一条样式（返回最新列表）
  final Future<List<ReaderStyle>> Function()? onSaveCurrent;

  /// 独立模式（从「我的」进入）：点卡片 = 记为默认阅读样式
  final bool standalone;

  @override
  State<ReaderStylesPage> createState() => _ReaderStylesPageState();
}

class _ReaderStylesPageState extends State<ReaderStylesPage> {
  late List<ReaderStyle> _mine = List.of(widget.mine);
  late String? _activeId = widget.activeId;

  final _store = ReaderStyleStore();

  /// 日夜自动切换：白天 / 夜间各绑定的样式 id（null = 不自动套用）
  String? _dayStyleId;
  String? _nightStyleId;

  /// 阅读器日夜是否跟随系统 / 全局明暗
  bool _followSystem = true;

  @override
  void initState() {
    super.initState();
    _loadAutoStyles();
  }

  Future<void> _loadAutoStyles() async {
    final d = await _store.loadDayStyleId();
    final n = await _store.loadNightStyleId();
    final f = await _store.loadFollowSystem();
    if (!mounted) return;
    setState(() {
      _dayStyleId = d;
      _nightStyleId = n;
      _followSystem = f;
    });
  }

  Color get _fg => widget.foreground;
  Color get _bg => widget.background;

  Future<void> _setMine(List<ReaderStyle> list) async {
    setState(() => _mine = List.of(list));
    await _store.saveCustom(_mine);
    widget.onChanged?.call(List.of(_mine));
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text, style: TextStyle(fontSize: 13, color: _fg)),
        backgroundColor: _fg.withValues(alpha: 0.14),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1600),
      ),
    );
  }

  Future<void> _apply(ReaderStyle s) async {
    if (widget.onApply != null) {
      widget.onApply!(s);
      if (mounted) Navigator.of(context).pop();
      return;
    }
    await _store.saveActiveId(s.id);
    if (!mounted) return;
    setState(() => _activeId = s.id);
    _toast('已设为阅读默认样式：${s.name}');
  }

  /// 编辑：内置样式先复制一份（内置不可直接改）
  Future<void> _edit(ReaderStyle s, {required bool builtin}) async {
    final id = 'user:${DateTime.now().millisecondsSinceEpoch}';
    final base = builtin
        ? ReaderStyle.fromJson({
            ...s.toJson(),
            'id': id,
            'name': '${s.name} 副本',
            'builtin': false,
          })
        : s;
    final edited = await Navigator.of(context).push<ReaderStyle>(
      MaterialPageRoute(
        // 可视化编辑（全屏预览 + 点哪调哪）；完整表单从页内右上角进
        builder: (_) => ReaderStyleVisualPage(
          style: base,
          background: _bg,
          foreground: _fg,
          title: builtin ? '编辑（会复制成我的样式）' : '编辑样式',
        ),
      ),
    );
    if (edited == null || !mounted) return;
    final list = List.of(_mine);
    final idx = list.indexWhere((e) => e.id == edited.id);
    if (idx >= 0) {
      list[idx] = edited;
    } else {
      list.add(edited);
    }
    await _setMine(list);
    if (builtin) _toast('已复制并保存为「${edited.name}」');
  }

  /// 复制一份（不打开编辑器）
  Future<void> _duplicate(ReaderStyle s) async {
    final copy = ReaderStyle.fromJson({
      ...s.toJson(),
      'id': 'user:${DateTime.now().millisecondsSinceEpoch}',
      'name': '${s.name} 副本',
      'builtin': false,
    });
    await _setMine([..._mine, copy]);
    _toast('已复制「${s.name}」');
  }

  Future<void> _delete(ReaderStyle s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _bg,
        title: Text('删除样式', style: TextStyle(fontSize: 16, color: _fg)),
        content: Text(
          '确定删除「${s.name}」？',
          style: TextStyle(fontSize: 14, color: _fg.withValues(alpha: 0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('取消', style: TextStyle(color: _fg.withValues(alpha: 0.6))),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(
              backgroundColor: _fg,
              foregroundColor: _bg,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _setMine(_mine.where((e) => e.id != s.id).toList());
  }

  Future<void> _move(int index, int delta) async {
    final target = index + delta;
    if (target < 0 || target >= _mine.length) return;
    final list = List.of(_mine);
    final item = list.removeAt(index);
    list.insert(target, item);
    await _setMine(list);
  }

  Future<void> _saveCurrentAsCopy() async {
    if (widget.onSaveCurrent != null) {
      final list = await widget.onSaveCurrent!();
      if (!mounted) return;
      await _setMine(list);
      _toast('已保存当前外观');
      return;
    }
    // 独立模式下没有"当前阅读外观"，只能新建一套默认样式再编辑
    final base = ReaderStyle(
      id: 'user:${DateTime.now().millisecondsSinceEpoch}',
      name: '我的样式 ${_mine.length + 1}',
    );
    await _edit(base, builtin: true);
  }

  Future<void> _showActions(ReaderStyle s, {required bool builtin}) async {
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
                  s.name,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _fg),
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.check_circle_outline, color: _fg),
              title: Text('套用', style: TextStyle(color: _fg)),
              onTap: () {
                Navigator.pop(c);
                _apply(s);
              },
            ),
            ListTile(
              leading: Icon(Icons.edit_outlined, color: _fg),
              title: Text(
                builtin ? '编辑（复制成我的样式）' : '编辑',
                style: TextStyle(color: _fg),
              ),
              onTap: () {
                Navigator.pop(c);
                _edit(s, builtin: builtin);
              },
            ),
            ListTile(
              leading: Icon(Icons.copy_rounded, color: _fg),
              title: Text('复制一份', style: TextStyle(color: _fg)),
              onTap: () {
                Navigator.pop(c);
                _duplicate(s);
              },
            ),
            if (!builtin) ...[
              ListTile(
                enabled: _mine.indexWhere((e) => e.id == s.id) > 0,
                leading: Icon(Icons.arrow_upward_rounded, color: _fg),
                title: Text('上移', style: TextStyle(color: _fg)),
                onTap: () {
                  final i = _mine.indexWhere((e) => e.id == s.id);
                  Navigator.pop(c);
                  _move(i, -1);
                },
              ),
              ListTile(
                enabled: _mine.indexWhere((e) => e.id == s.id) >= 0 &&
                    _mine.indexWhere((e) => e.id == s.id) < _mine.length - 1,
                leading: Icon(Icons.arrow_downward_rounded, color: _fg),
                title: Text('下移', style: TextStyle(color: _fg)),
                onTap: () {
                  final i = _mine.indexWhere((e) => e.id == s.id);
                  Navigator.pop(c);
                  _move(i, 1);
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
                  _delete(s);
                },
              ),
            ],
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
          '阅读样式',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: _fg),
        ),
        // 「标题样式」不再单独开入口：它已经是每套样式里的一个区域，
        // 在样式编辑页点「标题」就能换版式（避免两处改、越改越乱）。
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          _label('日夜自动切换 · 切日夜时套用对应的样式'),
          _autoSwitchCard(),
          _label('内置样式 ${widget.builtins.length} 套 · 长按管理'),
          // 三列卡片：宽度按屏宽算，卡片本身带描边/投影，像一排小书
          Wrap(
            spacing: 10,
            runSpacing: 12,
            children: [
              for (final s in widget.builtins)
                _card(
                  s,
                  width: _cardWidth(context),
                  onTap: () => _apply(s),
                  onMore: () => _showActions(s, builtin: true),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _label('我的样式 ${_mine.length} 套 · 可编辑 / 排序'),
          if (_mine.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                widget.standalone
                    ? '还没有我的样式。点下方「新建一套样式」开始。'
                    : '还没有我的样式。在阅读器里调好外观后，点「把当前外观存为样式」。',
                style: TextStyle(fontSize: 12, color: _fg.withValues(alpha: 0.45)),
              ),
            )
          else
            // 用户 2026-10-25：「我导入的样式的可视化要和内置一样」
            //   ⇒ 不再用一行文字列表，改用和内置一样的**小书预览卡**
            //   （排序/编辑/删除收进长按菜单）。
            Wrap(
              spacing: 10,
              runSpacing: 12,
              children: [
                for (final s in _mine)
                  _card(
                    s,
                    width: _cardWidth(context),
                    onTap: () => _apply(s),
                    onMore: () => _showActions(s, builtin: false),
                  ),
              ],
            ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _saveCurrentAsCopy,
              icon: Icon(Icons.add_rounded, size: 18, color: _fg),
              label: Text(
                widget.standalone ? '新建一套样式' : '把当前外观存为样式',
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
        ],
      ),
    );
  }

  /// 日夜自动切换卡片：白天 / 夜间各绑一套样式
  Widget _autoSwitchCard() {
    return Container(
      decoration: BoxDecoration(
        color: _fg.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _fg.withValues(alpha: 0.08)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _autoRow(
            Icons.light_mode_rounded,
            '白天样式',
            _dayStyleId,
            () => _pickAutoStyle(night: false),
          ),
          Divider(height: 0.6, thickness: 0.6, color: _fg.withValues(alpha: 0.08)),
          _autoRow(
            Icons.dark_mode_rounded,
            '夜间样式',
            _nightStyleId,
            () => _pickAutoStyle(night: true),
          ),
          Divider(height: 0.6, thickness: 0.6, color: _fg.withValues(alpha: 0.08)),
          _followRow(),
        ],
      ),
    );
  }

  /// 「跟随系统」开关：开启后系统/全局明暗一变，阅读器跟着切（并套用绑定样式）
  Widget _followRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
      child: Row(
        children: [
          Icon(
            Icons.brightness_auto_rounded,
            size: 18,
            color: _fg.withValues(alpha: 0.75),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('跟随系统日夜', style: TextStyle(fontSize: 14, color: _fg)),
                Text(
                  '手动切过一次昼夜后会自动关闭',
                  style: TextStyle(
                    fontSize: 11,
                    color: _fg.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: _followSystem,
            activeThumbColor: _fg,
            onChanged: (v) async {
              setState(() => _followSystem = v);
              await _store.saveFollowSystem(v);
            },
          ),
        ],
      ),
    );
  }

  Widget _autoRow(
    IconData icon,
    String title,
    String? id,
    VoidCallback onTap,
  ) {
    final name = _styleName(id);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 18, color: _fg.withValues(alpha: 0.75)),
            const SizedBox(width: 10),
            Text(title, style: TextStyle(fontSize: 14, color: _fg)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name ?? '不自动切换',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 13,
                  color: _fg.withValues(alpha: name == null ? 0.4 : 0.65),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: _fg.withValues(alpha: 0.35),
            ),
          ],
        ),
      ),
    );
  }

  /// 样式 id → 名字（找不到 = 已被删除，按「不自动切换」显示）
  String? _styleName(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final s in [...widget.builtins, ..._mine]) {
      if (s.id == id) return s.name;
    }
    return null;
  }

  /// 选白天 / 夜间要套用的样式（空串 = 不自动切换）
  Future<void> _pickAutoStyle({required bool night}) async {
    final all = [...widget.builtins, ..._mine];
    final current = night ? _nightStyleId : _dayStyleId;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Text(
                night ? '夜间使用的样式' : '白天使用的样式',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: _fg,
                ),
              ),
            ),
            ListTile(
              leading: Icon(
                Icons.block_rounded,
                color: _fg.withValues(alpha: 0.55),
              ),
              title: Text('不自动切换', style: TextStyle(color: _fg)),
              trailing: current == null
                  ? Icon(Icons.check_rounded, size: 18, color: _fg)
                  : null,
              onTap: () => Navigator.pop(c, ''),
            ),
            for (final s in all)
              ListTile(
                leading: Icon(
                  Icons.palette_outlined,
                  color: _fg.withValues(alpha: 0.55),
                ),
                title: Text(s.name, style: TextStyle(color: _fg)),
                subtitle: s.builtin
                    ? Text(
                        '内置',
                        style: TextStyle(
                          fontSize: 11,
                          color: _fg.withValues(alpha: 0.45),
                        ),
                      )
                    : null,
                trailing: current == s.id
                    ? Icon(Icons.check_rounded, size: 18, color: _fg)
                    : null,
                onTap: () => Navigator.pop(c, s.id),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final id = picked.isEmpty ? null : picked;
    if (night) {
      await _store.saveNightStyleId(id);
    } else {
      await _store.saveDayStyleId(id);
    }
    if (!mounted) return;
    setState(() {
      if (night) {
        _nightStyleId = id;
      } else {
        _dayStyleId = id;
      }
    });
  }

  /// 三列卡片宽度：屏宽 - 页面左右内边距(32) - 两个列间距(10×2)，再三等分
  double _cardWidth(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return ((w - 32 - 20) / 3).clamp(88.0, 132.0);
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

  Widget _card(
    ReaderStyle s, {
    required VoidCallback onTap,
    VoidCallback? onMore,
    required double width,
  }) {
    final selected = _activeId == s.id;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onMore,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: width,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: _fg.withValues(alpha: selected ? 0.10 : 0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? _fg.withValues(alpha: 0.9)
                : _fg.withValues(alpha: 0.07),
            width: selected ? 1.6 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                _preview(s, selected: selected),
                if (selected)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: _fg,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.check_rounded, size: 12, color: _bg),
                    ),
                  ),
                if (onMore != null)
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: GestureDetector(
                      onTap: onMore,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: _bg,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _fg.withValues(alpha: 0.12),
                          ),
                        ),
                        child: Icon(
                          Icons.more_horiz_rounded,
                          size: 13,
                          color: _fg.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                s.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.25,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: _fg.withValues(alpha: selected ? 1 : 0.70),
                ),
              ),
            ),
            const SizedBox(height: 2),
          ],
        ),
      ),
    );
  }

  /// 迷你书页：样式自己的底色 / 壁纸 / 字色 / 行距 / 页眉页脚
  ///
  /// 按当前日夜取对应那套（[ReaderStylesPage.night]）：夜间打开时看到的是
  /// 夜间配色 + 夜间壁纸，而不是一排亮纸片。
  Widget _preview(ReaderStyle s, {required bool selected}) {
    final night = widget.night;
    final bgColor = night ? (s.bgColorNight ?? s.bgColor) : s.bgColor;
    final asset = night
        ? (s.bgImageAssetNight ?? s.bgImageAsset)
        : s.bgImageAsset;
    // 夜间没有夜版壁纸 ⇒ 与阅读器一样压暗，避免小样"夜里是亮纸"
    final dim = night && s.bgImageAssetNight == null;
    final bg = bgColor != null
        ? Color(bgColor)
        : (night ? const Color(0xFF2B2B2B) : const Color(0xFFFFFFFF));
    final dark = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
    final fgColor = night ? (s.fgColorNight ?? s.fgColor) : s.fgColor;
    final fg = fgColor != null
        ? Color(fgColor)
        : (dark ? const Color(0xFFE2E2E2) : const Color(0xFF1A1A1A));
    final gap = (s.lineHeight - 1).clamp(0.12, 1.0) * 4.5;
    final showHeader =
        s.headerL.isNotEmpty ||
        s.headerC.isNotEmpty ||
        s.headerR.isNotEmpty ||
        s.statusItems.contains('时间') ||
        s.statusItems.contains('书名');
    final showFooter =
        s.footerL.isNotEmpty ||
        s.footerC.isNotEmpty ||
        s.footerR.isNotEmpty ||
        s.statusItems.contains('页码') ||
        s.statusItems.contains('进度');
    return AspectRatio(
      // 小页比例接近单页纸张（宽:高 ≈ 0.70），比原来的横条更像"书"
      aspectRatio: 0.70,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: selected
                ? _fg.withValues(alpha: 0.25)
                : _fg.withValues(alpha: 0.10),
          ),
          image: asset == null
              ? null
              : DecorationImage(
                  image: AssetImage(asset),
                  fit: BoxFit.cover,
                  colorFilter: dim
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
              Row(
                children: [
                  _miniBar(18, 2, fg, 0.30),
                  const Spacer(),
                  _miniBar(12, 2, fg, 0.30),
                ],
              ),
              const SizedBox(height: 7),
            ],
            // 章节数（小字）+ 章节名（粗标题）：与真实版式的层次一致
            _miniBar(22, 2.5, fg, 0.45),
            const SizedBox(height: 4),
            _miniBar(38, 5, fg, 0.90, radius: 2),
            SizedBox(height: 7 + gap * 0.5),
            for (var i = 0; i < 5; i++) ...[
              _miniBar(i == 4 ? 30 : double.infinity, 2.6, fg, 0.55),
              SizedBox(height: 3 + gap),
            ],
            const Spacer(),
            if (showFooter)
              Row(
                children: [
                  _miniBar(14, 2, fg, 0.28),
                  const Spacer(),
                  _miniBar(10, 2, fg, 0.28),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// 迷你书页里的一条"文字行"
  Widget _miniBar(
    double width,
    double height,
    Color color,
    double alpha, {
    double radius = 1.5,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color.withValues(alpha: alpha),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
