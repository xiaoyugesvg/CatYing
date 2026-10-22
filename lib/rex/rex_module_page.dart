import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../widgets/app_toast.dart';
import 'rex_detail_page.dart';
import 'rex_models.dart';
import 'rex_service.dart';

/// 一个 REX 模块的列表页：按 WidgetMetadata 里的分类 chip 切换。
///
/// 翻页规则：模块约定 `params.page`（从 1 开始）。返回空列表即认为到底，
/// 不做固定页数推断 —— 不同模块每页条数差别很大。
class RexModulePage extends StatefulWidget {
  const RexModulePage({super.key, required this.module});

  final RexModule module;

  @override
  State<RexModulePage> createState() => _RexModulePageState();
}

class _RexModulePageState extends State<RexModulePage> {
  final _service = RexService.instance;
  final _scroll = ScrollController();

  RexFunction? _fn;
  final List<RexItem> _items = [];
  int _nextPage = 1;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    final fns = widget.module.listFunctions;
    _fn = fns.isEmpty ? null : fns.first;
    _scroll.addListener(_onScroll);
    if (_fn != null) _reload();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore || _loading || !_hasMore) return;
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 400) {
      _fetch(more: true);
    }
  }

  Future<void> _reload() async {
    _nextPage = 1;
    _hasMore = true;
    setState(() {
      _items.clear();
      _error = null;
    });
    await _fetch();
  }

  Future<void> _fetch({bool more = false}) async {
    final fn = _fn;
    if (fn == null && _keyword.isEmpty) return;
    if (_loading || _loadingMore) return;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
      }
      _error = null;
    });
    try {
      final list = _keyword.isEmpty
          ? await _service.list(widget.module, fn!, page: _nextPage)
          : await _service.search(widget.module, _keyword, page: _nextPage);
      if (!mounted) return;
      setState(() {
        if (!more) _items.clear();
        final seen = _items.map((e) => '${e.link}|${e.title}').toSet();
        for (final e in list) {
          if (seen.add('${e.link}|${e.title}')) _items.add(e);
        }
        _hasMore = list.isNotEmpty;
        _nextPage++;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(widget.module.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
                color: _fg)),
        actions: [
          if (widget.module.canSearch)
            IconButton(
              tooltip: '搜索',
              icon: Icon(Icons.search, color: _fg),
              onPressed: _showSearch,
            ),
          IconButton(
            tooltip: '刷新',
            icon: Icon(Icons.refresh_rounded, color: _fg),
            onPressed: _loading ? null : _reload,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (widget.module.listFunctions.isNotEmpty) _chips(),
          if (_keyword.isNotEmpty) _searchBar(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _chips() {
    final fns = widget.module.listFunctions;
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        itemCount: fns.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final f = fns[i];
          final active = identical(f, _fn);
          return GestureDetector(
            onTap: () {
              if (active) return;
              setState(() {
                _fn = f;
                _keyword = '';
              });
              _reload();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding:
                  const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              decoration: BoxDecoration(
                color: active
                    ? AppTheme.accentColor.withValues(alpha: 0.16)
                    : (_isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.black.withValues(alpha: 0.04)),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                    color: active
                        ? AppTheme.accentColor.withValues(alpha: 0.45)
                        : Colors.transparent,
                    width: 0.8),
              ),
              child: Text(
                f.title.isEmpty ? f.functionName : f.title,
                style: TextStyle(
                    color: active ? AppTheme.accentColor : _sub,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight:
                        active ? FontWeight.w600 : FontWeight.w400),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _searchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
        child: Row(
          children: [
            Icon(Icons.search, size: 14, color: _sub),
            const SizedBox(width: 6),
            Expanded(
              child: Text('搜索：$_keyword',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
            ),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: () {
                setState(() => _keyword = '');
                _reload();
              },
              child: Text('清除',
                  style: TextStyle(fontSize: AppTheme.fontCaption)),
            ),
          ],
        ),
      );

  Widget _body() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: AppTheme.fontFootnote,
                      height: 1.5)),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: _reload,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          _fn == null ? '这个模块没有配置分类，试试搜索' : '没有内容',
          style: TextStyle(color: _sub, fontSize: AppTheme.fontFootnote),
        ),
      );
    }
    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.52,
        crossAxisSpacing: 8,
        mainAxisSpacing: 10,
      ),
      itemCount: _items.length + (_loadingMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _items.length) {
          return const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return _itemCard(_items[i]);
      },
    );
  }

  Widget _itemCard(RexItem item) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        settings: const RouteSettings(name: 'rex:detail'),
        builder: (_) => RexDetailPage(module: widget.module, item: item),
      )),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: SizedBox(
                width: double.infinity,
                child: item.cover.isEmpty
                    ? _coverPlaceholder()
                    : CachedNetworkImage(
                        imageUrl: item.cover,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _coverPlaceholder(),
                        placeholder: (_, __) => _coverPlaceholder(),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: _fg,
                  fontSize: AppTheme.fontCaption,
                  height: 1.3,
                  fontWeight: FontWeight.w500)),
          if (item.description.isNotEmpty)
            Text(item.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _sub, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _coverPlaceholder() => Container(
        color: _isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06),
        alignment: Alignment.center,
        child: Icon(Icons.movie_outlined, size: 20, color: _sub),
      );

  Future<void> _showSearch() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('搜索'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入关键词'),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('搜索')),
        ],
      ),
    );
    final kw = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || kw.isEmpty) return;
    setState(() => _keyword = kw);
    await _reload();
    if (mounted && _items.isEmpty && _error == null) {
      AppToast.show('没有搜到结果', '');
    }
  }
}
