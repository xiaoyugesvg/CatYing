import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../widgets/app_toast.dart';
import 'rex_models.dart';
import 'rex_service.dart';

/// 「REX 市场」——把 `.rex` 集合当成小程序市场来浏览。
///
/// 和以前「粘地址 → 后台串行加载几十个模块、界面无反馈」不同，这里分两步：
///   1. 拉集合 JSON（秒回），把里面的模块**列出来**给用户挑；
///   2. 只加载勾选的模块（4 路并发 + 进度条 + 单项超时）。
///
/// 这样坏模块不会拖死整批，也不会出现「点了导入什么反应都没有」。
///
/// ⚠️ 不内置任何集合地址（用户 2026-10-23：「不要内置」）——
///    地址一律由用户粘贴，避免内置源失效后变成甩不掉的死链。
class RexMarketPage extends StatefulWidget {
  const RexMarketPage({super.key});

  @override
  State<RexMarketPage> createState() => _RexMarketPageState();
}

/// 列表排序方式
enum _SortBy { origin, name, author, notAdded }

class _RexMarketPageState extends State<RexMarketPage> {
  final _service = RexService.instance;
  final _urlCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _scroll = ScrollController();

  RexCollection? _collection;
  final Set<String> _selected = {};

  bool _loading = false;
  String? _error;

  bool _importing = false;
  int _done = 0;
  int _total = 0;
  String _current = '';

  String _keyword = '';

  /// 视图：true = 网格两列，false = 列表
  bool _grid = false;
  _SortBy _sortBy = _SortBy.origin;

  @override
  void initState() {
    super.initState();
    _service.load();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _searchCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;
  Color get _line => _isDark
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.06);
  Color get _tile => _isDark
      ? Colors.white.withValues(alpha: 0.05)
      : Colors.black.withValues(alpha: 0.025);

  /// 文字 / 图标用的强调色。
  ///
  /// `accentColor` 取调色板 primary（默认「水墨书香」是 #3A3A3A 墨灰），
  /// 压在暗底上几乎不可见 ⇒ 前景统一用 accentOnSurface（暗色下是浅色）。
  Color get _accent => AppTheme.accentOnSurface;

  List<RexCollectionItem> get _shown {
    final all = _collection?.items ?? const <RexCollectionItem>[];
    Iterable<RexCollectionItem> it = all;
    if (_keyword.isNotEmpty) {
      final k = _keyword.toLowerCase();
      it = it.where((e) =>
          e.title.toLowerCase().contains(k) ||
          e.author.toLowerCase().contains(k) ||
          e.id.toLowerCase().contains(k));
    }
    final list = it.toList();
    switch (_sortBy) {
      case _SortBy.origin:
        break; // 保持集合文件里的原顺序
      case _SortBy.name:
        list.sort((a, b) => a.title.compareTo(b.title));
        break;
      case _SortBy.author:
        list.sort((a, b) => a.author.compareTo(b.author));
        break;
      case _SortBy.notAdded:
        // 没添加过的排前面，已添加的沉底
        list.sort((a, b) {
          final aa = _service.hasUrl(a.url) ? 1 : 0;
          final bb = _service.hasUrl(b.url) ? 1 : 0;
          return aa - bb;
        });
        break;
    }
    return list;
  }

  int get _importedCount => (_collection?.items ?? const <RexCollectionItem>[])
      .where((e) => _service.hasUrl(e.url))
      .length;

  // ── 拉取集合 ─────────────────────────────────────────────────

  Future<void> _fetch([String? raw]) async {
    final input = (raw ?? _urlCtrl.text).trim();
    if (input.isEmpty) {
      AppToast.show('先粘贴 .rex 集合地址', '');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _collection = null;
      _selected.clear();
      _keyword = '';
      _searchCtrl.clear();
    });
    try {
      final col = await _service.fetchCollection(input);
      if (!mounted) return;
      setState(() {
        _collection = col;
        _urlCtrl.text = col.url;
        // 默认只勾「还没导入过」的，避免重复添加
        for (final it in col.items) {
          if (!_service.hasUrl(it.url)) _selected.add(it.url);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── 导入 ─────────────────────────────────────────────────────

  Future<void> _import() async {
    final col = _collection;
    if (col == null) return;
    final items = col.items.where((e) => _selected.contains(e.url)).toList();
    if (items.isEmpty) {
      AppToast.show('先勾选要导入的模块', '');
      return;
    }
    setState(() {
      _importing = true;
      _done = 0;
      _total = items.length;
      _current = '';
    });
    RexImportResult res;
    try {
      res = await _service.importSelected(
        items,
        onProgress: (done, total, current) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
            _current = current;
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      AppToast.show('导入失败：$e', '');
      return;
    }
    if (!mounted) return;
    setState(() {
      _importing = false;
      // 已导入的取消勾选，方便继续挑剩下的
      for (final m in res.imported) {
        _selected.remove(m.url);
      }
    });
    if (res.errors.isEmpty) {
      AppToast.show('已导入 ${res.imported.length} 个模块', '');
    } else {
      AppToast.show(
        '成功 ${res.imported.length} 个，失败 ${res.errors.length} 个',
        res.errors.first,
      );
      _showFailures(res.errors);
    }
  }

  void _showFailures(List<String> errors) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final dark = Theme.of(ctx).brightness == Brightness.dark;
        final fg = dark ? Colors.white : AppTheme.textPrimary;
        return Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.6),
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF1C1C1E) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: _sub.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text('${errors.length} 个模块没导入成功',
                    style: TextStyle(
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w700,
                        color: fg)),
                const SizedBox(height: 4),
                Text('多半是站点失效或模块本身报错，不影响已导入的模块。',
                    style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: AppTheme.textTertiary,
                        height: 1.5)),
                const SizedBox(height: 10),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: errors.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 12, color: _line),
                    itemBuilder: (_, i) => Text(
                      errors[i],
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: _sub,
                          height: 1.45),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accentColor,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('知道了'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── UI ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('REX 市场',
            style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
                color: _fg)),
        actions: [
          IconButton(
            tooltip: '只导入单个模块',
            icon: Icon(Icons.link_rounded, color: _fg),
            onPressed: _importing ? null : _singleImport,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _sourceCard(),
          if (_loading) ...[
            const SizedBox(height: 28),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 12),
            Center(
              child: Text('正在读取集合…',
                  style:
                      TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            _errorCard(),
          ],
          if (_collection != null) ...[
            const SizedBox(height: 14),
            _collectionHeader(),
            const SizedBox(height: 10),
            _toolbar(),
            const SizedBox(height: 6),
            ..._list(),
          ],
        ],
      ),
      bottomNavigationBar: _collection == null ? null : _bottomBar(),
    );
  }

  Widget _sourceCard() => Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        decoration: BoxDecoration(
          color: _tile,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          border: Border.all(color: _line, width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.storefront_rounded,
                    size: 17, color: _accent),
                const SizedBox(width: 7),
                Text('订阅集合地址',
                    style: TextStyle(
                        color: _fg,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            Text('支持 .rex 集合（一次列出全部模块）或单个模块地址。',
                style: TextStyle(
                    color: _sub,
                    fontSize: AppTheme.fontCaption,
                    height: 1.5)),
            const SizedBox(height: 10),
            TextField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              maxLines: 3,
              minLines: 1,
              style: TextStyle(color: _fg, fontSize: AppTheme.fontSubhead),
              decoration: InputDecoration(
                hintText: 'https://…/api/collections/xxx.rex',
                hintStyle: TextStyle(color: _sub, fontSize: AppTheme.fontSubhead),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                  borderSide: BorderSide(color: _line, width: 0.8),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                  borderSide: BorderSide(color: _line, width: 0.8),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accentColor,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 42),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMD)),
                ),
                onPressed: _loading || _importing ? null : () => _fetch(),
                icon: _loading
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.travel_explore_rounded, size: 18),
                label: Text(_loading ? '读取中…' : '获取模块列表'),
              ),
            ),
          ],
        ),
      );

  Widget _errorCard() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.redAccent.withValues(alpha: _isDark ? 0.12 : 0.07),
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
          border:
              Border.all(color: Colors.redAccent.withValues(alpha: 0.25), width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 16, color: Colors.redAccent),
                const SizedBox(width: 6),
                Text('读取失败',
                    style: TextStyle(
                        color: Colors.redAccent,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 6),
            Text(_error!,
                style: TextStyle(
                    color: _sub, fontSize: AppTheme.fontCaption, height: 1.5)),
          ],
        ),
      );

  Widget _collectionHeader() {
    final col = _collection!;
    final imported = _importedCount;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _accent.withValues(alpha: _isDark ? 0.22 : 0.13),
            _accent.withValues(alpha: _isDark ? 0.06 : 0.03),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
        border: Border.all(
            color: _accent.withValues(alpha: 0.22), width: 0.8),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 46,
              height: 46,
              child: col.icon.isEmpty
                  ? _iconFallback()
                  : CachedNetworkImage(
                      imageUrl: col.icon,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _iconFallback(),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(col.title.isEmpty ? '未命名集合' : col.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: _fg,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(
                  '${col.items.length} 个模块 · 已添加 $imported',
                  style:
                      TextStyle(color: _sub, fontSize: AppTheme.fontCaption),
                ),
                if (col.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(col.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: _sub.withValues(alpha: 0.85),
                          fontSize: AppTheme.fontCaption)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconFallback() => Container(
        color: _accent.withValues(alpha: 0.16),
        alignment: Alignment.center,
        child: Icon(Icons.extension_rounded,
            size: 22, color: _accent),
      );

  Widget _toolbar() {
    final shown = _shown;
    final allSelected = shown.isNotEmpty &&
        shown.every((e) => _selected.contains(e.url));
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 36,
            child: TextField(
              controller: _searchCtrl,
              style: TextStyle(color: _fg, fontSize: AppTheme.fontSubhead),
              decoration: InputDecoration(
                hintText: '搜索模块名 / 作者',
                hintStyle:
                    TextStyle(color: _sub, fontSize: AppTheme.fontSubhead),
                prefixIcon: Icon(Icons.search_rounded, size: 17, color: _sub),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
                filled: true,
                fillColor: _tile,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (v) => setState(() => _keyword = v.trim()),
            ),
          ),
        ),
        const SizedBox(width: 4),
        // 排序
        PopupMenuButton<_SortBy>(
          tooltip: '排序',
          padding: EdgeInsets.zero,
          icon: Icon(Icons.sort_rounded, size: 19, color: _fg),
          initialValue: _sortBy,
          onSelected: (v) => setState(() => _sortBy = v),
          itemBuilder: (_) => [
            _sortItem(_SortBy.origin, '默认顺序'),
            _sortItem(_SortBy.name, '按名称'),
            _sortItem(_SortBy.author, '按作者'),
            _sortItem(_SortBy.notAdded, '未添加优先'),
          ],
        ),
        // 视图切换
        IconButton(
          tooltip: _grid ? '切换为列表' : '切换为网格',
          visualDensity: VisualDensity.compact,
          icon: Icon(
            _grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
            size: 19,
            color: _fg,
          ),
          onPressed: () => setState(() => _grid = !_grid),
        ),
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          onPressed: shown.isEmpty
              ? null
              : () {
                  setState(() {
                    if (allSelected) {
                      for (final e in shown) {
                        _selected.remove(e.url);
                      }
                    } else {
                      for (final e in shown) {
                        _selected.add(e.url);
                      }
                    }
                  });
                },
          child: Text(allSelected ? '取消全选' : '全选',
              style: TextStyle(fontSize: AppTheme.fontCaption)),
        ),
      ],
    );
  }

  PopupMenuItem<_SortBy> _sortItem(_SortBy v, String label) =>
      PopupMenuItem<_SortBy>(
        value: v,
        child: Row(
          children: [
            Icon(
              _sortBy == v
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              size: 16,
              color: _sortBy == v ? _accent : _sub,
            ),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
      );

  List<Widget> _list() {
    final shown = _shown;
    if (shown.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 30),
          child: Center(
            child: Text('没有匹配的模块',
                style: TextStyle(color: _sub, fontSize: AppTheme.fontFootnote)),
          ),
        ),
      ];
    }
    if (_grid) {
      return [
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 8),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 2.6,
          ),
          itemCount: shown.length,
          itemBuilder: (_, i) => _gridCell(shown[i]),
        ),
      ];
    }
    return [for (final it in shown) _itemTile(it)];
  }

  /// 网格视图下的紧凑卡片：勾选框 + 标题 + 作者
  Widget _gridCell(RexCollectionItem it) {
    final on = _selected.contains(it.url);
    final added = _service.hasUrl(it.url);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _importing
          ? null
          : () => setState(() {
                if (on) {
                  _selected.remove(it.url);
                } else {
                  _selected.add(it.url);
                }
              }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
        decoration: BoxDecoration(
          color: on
              ? _accent.withValues(alpha: _isDark ? 0.14 : 0.08)
              : _tile,
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
          border: Border.all(
              color: on
                  ? _accent.withValues(alpha: 0.42)
                  : Colors.transparent,
              width: 0.9),
        ),
        child: Row(
          children: [
            _CheckBox(on: on),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    it.title.isEmpty ? '(未命名)' : it.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: _fg,
                        fontSize: AppTheme.fontFootnote,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (added) '已添加',
                      if (it.version.isNotEmpty) 'v${it.version}',
                      if (it.author.isNotEmpty) it.author,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: added ? _accent : _sub,
                        fontSize: AppTheme.fontCaption),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemTile(RexCollectionItem it) {
    final on = _selected.contains(it.url);
    final added = _service.hasUrl(it.url);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _importing
          ? null
          : () => setState(() {
                if (on) {
                  _selected.remove(it.url);
                } else {
                  _selected.add(it.url);
                }
              }),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        decoration: BoxDecoration(
          color: on
              ? _accent.withValues(alpha: _isDark ? 0.14 : 0.08)
              : _tile,
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
          border: Border.all(
              color: on
                  ? _accent.withValues(alpha: 0.42)
                  : Colors.transparent,
              width: 0.9),
        ),
        child: Row(
          children: [
            _CheckBox(on: on),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          it.title.isEmpty ? '(未命名)' : it.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: _fg,
                              fontSize: AppTheme.fontSubhead,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (it.version.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _pill('v${it.version}'),
                      ],
                      if (added) ...[
                        const SizedBox(width: 6),
                        _pill('已添加', accent: true),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (it.author.isNotEmpty) it.author,
                      if (it.description.isNotEmpty) it.description,
                    ].join(' · ').ifEmpty('来自 ${Uri.tryParse(it.url)?.host ?? ''}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(color: _sub, fontSize: AppTheme.fontCaption),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(String text, {bool accent = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(
          color: accent
              ? _accent.withValues(alpha: 0.16)
              : (_isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.05)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: accent ? _accent : _sub,
            fontSize: 9.5,
            fontWeight: accent ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      );

  Widget _bottomBar() {
    final col = _collection!;
    final picked = col.items.where((e) => _selected.contains(e.url)).length;
    return Container(
      decoration: BoxDecoration(
        color: _isDark
            ? const Color(0xFF141416).withValues(alpha: 0.96)
            : Colors.white.withValues(alpha: 0.96),
        border: Border(top: BorderSide(color: _line, width: 0.8)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: _importing
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '正在解析 $_done / $_total',
                            style: TextStyle(
                                color: _fg,
                                fontSize: AppTheme.fontSubhead,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text('$_done',
                            style: TextStyle(
                                color: _accent,
                                fontSize: AppTheme.fontCaption)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: _total == 0 ? null : _done / _total,
                        minHeight: 5,
                        backgroundColor: _isDark ? Colors.white12 : Colors.black12,
                        valueColor: AlwaysStoppedAnimation(_accent),
                      ),
                    ),
                    const SizedBox(height: 5),
                    SizedBox(
                      width: double.infinity,
                      child: Text(
                        _current.isEmpty ? '准备中…' : _current,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: _sub, fontSize: AppTheme.fontCaption),
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('已选 $picked 个',
                              style: TextStyle(
                                  color: _fg,
                                  fontSize: AppTheme.fontSubhead,
                                  fontWeight: FontWeight.w600)),
                          Text('未选中的不会加载',
                              style: TextStyle(
                                  color: _sub,
                                  fontSize: AppTheme.fontCaption)),
                        ],
                      ),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.accentColor,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusMD)),
                      ),
                      onPressed: picked == 0 ? null : _import,
                      child: Text(picked == 0 ? '选择模块' : '导入 $picked 个'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> _singleImport() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加单个模块'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                hintText: 'https://…/api/modules/<id>/raw',
              ),
            ),
            const SizedBox(height: 10),
            Text('填模块 raw 地址（返回 JS 的那个）。',
                style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    color: AppTheme.textTertiary)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('添加')),
        ],
      ),
    );
    final input = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || input.isEmpty || !mounted) return;
    try {
      final col = await _service.fetchCollection(input);
      final res = await _service.importSelected(col.items);
      if (!mounted) return;
      if (res.imported.isEmpty) {
        AppToast.show('添加失败', res.errors.isEmpty ? '' : res.errors.first);
      } else {
        AppToast.show('已添加「${res.imported.first.title}」', '');
        setState(() {});
      }
    } catch (e) {
      if (mounted) AppToast.show('$e', '');
    }
  }
}

class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      width: 21,
      height: 21,
      decoration: BoxDecoration(
        color: on ? AppTheme.accentOnSurface : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: on
              ? AppTheme.accentOnSurface
              : (Theme.of(context).brightness == Brightness.dark
                  ? Colors.white30
                  : Colors.black26),
          width: 1.4,
        ),
      ),
      child: on
          ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
          : null,
    );
  }
}

extension _EmptyExt on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
