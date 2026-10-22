import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../models/movie.dart';
import '../services/player_prefs.dart';
import '../widgets/app_toast.dart';
import '../widgets/vod_card.dart';
import 'rex_detail_page.dart';
import 'rex_manage_page.dart';
import 'rex_market_page.dart';
import 'rex_models.dart';
import 'rex_service.dart';

/// 「REX」首页 —— 视觉与交互对齐影视首页：
///   模块（源）横排 chips → 模块分类 chips → 海报网格（VodCard）
///
/// 底栏里的「REX」tab **默认关闭**，在「设置 → 主页页面」里打开。
/// 导入 / 启停 / 排序 / 改地址 / 删除统一放在「REX 订阅管理」页。
class RexHomePage extends StatefulWidget {
  const RexHomePage({super.key});

  @override
  State<RexHomePage> createState() => _RexHomePageState();
}

class _RexHomePageState extends State<RexHomePage> {
  final _service = RexService.instance;
  final _scroll = ScrollController();

  String? _selectedUrl;
  RexFunction? _fn;
  final List<RexItem> _items = [];
  int _nextPage = 1;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  String _keyword = '';

  /// 请求代次：切模块/切分类/搜索时递增，旧请求回来直接丢弃
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _service.revision.addListener(_onServiceChanged);
    _service.load().then((_) {
      if (!mounted) return;
      _ensureSelection();
      _reload();
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _service.revision.removeListener(_onServiceChanged);
    _scroll.dispose();
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;

  List<RexModule> get _modules => _service.browsableModules;

  RexModule? get _module {
    final list = _modules;
    if (list.isEmpty) return null;
    for (final m in list) {
      if (m.url == _selectedUrl) return m;
    }
    return list.first;
  }

  void _ensureSelection() {
    final list = _modules;
    if (list.isEmpty) {
      _selectedUrl = null;
      _fn = null;
      return;
    }
    // 当前选中的模块被停用/删除 → 回到第一个
    if (!list.any((m) => m.url == _selectedUrl)) {
      _selectedUrl = list.first.url;
      _fn = list.first.listFunctions.isEmpty
          ? null
          : list.first.listFunctions.first;
      _keyword = '';
    }
  }

  void _onServiceChanged() {
    if (!mounted) return;
    final beforeUrl = _selectedUrl;
    _ensureSelection();
    if (beforeUrl != _selectedUrl) {
      setState(() => _items.clear());
      _reload();
    } else {
      setState(() {});
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading || _loadingMore || !_hasMore) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      _fetch(more: true);
    }
  }

  Future<void> _reload() async {
    final m = _module;
    if (m == null) return;
    _seq++;
    _nextPage = 1;
    _hasMore = true;
    setState(() {
      _items.clear();
      _error = null;
      _loadingMore = false;
    });
    await _fetch(seq: _seq);
  }

  Future<void> _fetch({bool more = false, int? seq}) async {
    final m = _module;
    if (m == null) return;
    // 翻页要防重入；重新加载（more=false）允许打断上一次请求，
    // 旧请求靠 _seq 丢弃结果 —— 否则快速切分类会卡在"永远加载中"
    if (more && (_loading || _loadingMore)) return;
    if (_keyword.isEmpty && _fn == null) return;
    final token = seq ?? _seq;
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
          ? await _service.list(m, _fn!, page: _nextPage)
          : await _service.search(m, _keyword, page: _nextPage);
      if (!mounted || token != _seq) return;
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
      if (mounted && token == _seq) setState(() => _error = '$e');
    } finally {
      if (mounted && token == _seq) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  void _selectModule(RexModule m) {
    if (m.url == _selectedUrl) return;
    setState(() {
      _selectedUrl = m.url;
      _fn = m.listFunctions.isEmpty ? null : m.listFunctions.first;
      _keyword = '';
      _items.clear();
    });
    _reload();
  }

  void _selectFunction(RexFunction f) {
    if (identical(f, _fn)) return;
    setState(() {
      _fn = f;
      _keyword = '';
      _items.clear();
    });
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text('REX',
            style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
                color: _fg)),
        actions: [
          if (_module?.canSearch == true)
            IconButton(
              tooltip: '搜索',
              icon: Icon(Icons.search, color: _fg),
              onPressed: _showSearch,
            ),
          IconButton(
            tooltip: 'REX 订阅管理',
            icon: Icon(Icons.tune_rounded, color: _fg),
            onPressed: _openManage,
          ),
          IconButton(
            tooltip: 'REX 市场',
            icon: Icon(Icons.storefront_rounded, color: _fg),
            onPressed: _openMarket,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _modules.isEmpty ? _empty() : _content(),
    );
  }

  Widget _content() {
    final m = _module!;
    final fns = m.listFunctions;
    final cols = PlayerPrefs.instance.gridColumns.value.clamp(2, 4);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = (constraints.maxWidth -
                32 -
                AppTheme.cardSpacing * (cols - 1)) /
            cols;
        const posterRatio = 0.72;
        const textArea = 30.0;
        final ratio = cardWidth / (cardWidth * posterRatio + textArea);
        return RefreshIndicator(
          color: AppTheme.accentColor,
          onRefresh: _reload,
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (_modules.length > 1)
                SliverToBoxAdapter(child: _moduleChips()),
              if (fns.isNotEmpty)
                SliverToBoxAdapter(child: _functionChips(fns)),
              if (_keyword.isNotEmpty)
                SliverToBoxAdapter(child: _searchHint()),
              if (_error != null && _items.isEmpty)
                SliverFillRemaining(hasScrollBody: false, child: _errorView())
              else if (_loading && _items.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_items.isEmpty)
                SliverFillRemaining(
                    hasScrollBody: false, child: _emptyItems())
              else
                _grid(cols, ratio),
              if (_loadingMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 110, top: 8),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _moduleChips() {
    final list = _modules;
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final m = list[i];
          final active = m.url == _module?.url;
          return GestureDetector(
            onTap: () => _selectModule(m),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
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
              child: Row(
                children: [
                  Icon(Icons.extension_rounded,
                      size: 13,
                      color: active ? AppTheme.accentColor : _sub),
                  const SizedBox(width: 5),
                  Text(
                    m.title,
                    style: TextStyle(
                        color: active ? AppTheme.accentColor : _sub,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.w400),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _functionChips(List<RexFunction> fns) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: fns.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final f = fns[i];
          final active = identical(f, _fn);
          return GestureDetector(
            onTap: () => _selectFunction(f),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: active
                    ? AppTheme.accentColor.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: active
                        ? AppTheme.accentColor.withValues(alpha: 0.4)
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

  Widget _searchHint() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
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

  Widget _grid(int cols, double ratio) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 120),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          childAspectRatio: ratio,
          crossAxisSpacing: AppTheme.cardSpacing,
          mainAxisSpacing: AppTheme.cardSpacing,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) {
            final item = _items[i];
            return VodCard(
              video: _toVideo(item),
              posterHeightRatio: 0.72,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                settings: const RouteSettings(name: 'rex:detail'),
                builder: (_) => RexDetailPage(module: _module!, item: item),
              )),
            );
          },
          childCount: _items.length,
        ),
      ),
    );
  }

  Video _toVideo(RexItem it) => Video(
        id: it.id.isEmpty ? it.link : it.id,
        name: it.title,
        pic: it.cover,
        note: it.description.length > 30
            ? it.description.substring(0, 30)
            : it.description,
        sourceKey: 'rex',
      );

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(36, 0, 36, 80),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.extension_outlined,
                  size: 38, color: _sub.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              Text(
                  _service.modules.isEmpty ? '还没有 REX 模块' : '没有可浏览的模块',
                  style: TextStyle(
                      color: _fg,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                _service.modules.isEmpty
                    ? '去「REX 市场」挑一个合集：\n'
                        '· 先列出里面的模块，勾选后再加载\n'
                        '· 也可以只加单个模块地址'
                    : '去「REX 订阅」把要用的模块打开。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: _sub, fontSize: AppTheme.fontFootnote, height: 1.7),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accentColor,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 42),
                ),
                onPressed:
                    _service.modules.isEmpty ? _openMarket : _openManage,
                icon: Icon(
                    _service.modules.isEmpty
                        ? Icons.storefront_rounded
                        : Icons.tune_rounded,
                    size: 18),
                label: Text(
                    _service.modules.isEmpty ? '打开 REX 市场' : '打开订阅管理'),
              ),
            ],
          ),
        ),
      );

  Widget _emptyItems() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            _fn == null ? '这个模块没有分类，试试搜索' : '没有内容',
            style: TextStyle(color: _sub, fontSize: AppTheme.fontFootnote),
          ),
        ),
      );

  Widget _errorView() => Center(
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
              OutlinedButton(onPressed: _reload, child: const Text('重试')),
            ],
          ),
        ),
      );

  Future<void> _openMarket() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'rex:market'),
      builder: (_) => const RexMarketPage(),
    ));
    if (!mounted) return;
    _ensureSelection();
    setState(() {});
    _reload();
  }

  Future<void> _openManage() async {
    await Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: 'rex:manage'),
      builder: (_) => const RexManagePage(),
    ));
    if (!mounted) return;
    _ensureSelection();
    setState(() {});
  }

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
    if (ok != true || kw.isEmpty || !mounted) return;
    setState(() => _keyword = kw);
    await _reload();
    if (mounted && _items.isEmpty && _error == null) {
      AppToast.show('没有搜到结果', '');
    }
  }
}
