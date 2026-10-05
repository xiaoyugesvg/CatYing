// 书源页（Nexhub 引擎接入）——参考漫画页（search_page）布局：
// 顶部源 tab（聚搜 + 各启用书源）+ 搜索胶囊 + 分类筛选 + 视图切换；
// 内容区为 3 列网格 / 列表。点书进入书源详情页（shuyuan_book_detail_page）。

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../novel_source/model/book_source.dart';
import '../novel_source/model/search_book.dart';
import '../novel_source/web_book/web_book.dart';
import '../services/shuyuan_source_store.dart';
import '../theme/jelly_theme.dart';
import 'shuyuan_book_detail_page.dart';
import 'shuyuan_source_repo_page.dart';

class ShuyuanPage extends StatefulWidget {
  const ShuyuanPage({super.key});

  @override
  State<ShuyuanPage> createState() => _ShuyuanPageState();
}

class _ShuyuanPageState extends State<ShuyuanPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _searchCtrl = TextEditingController();
  final WebBook _webBook = WebBook();
  late final TabController _tabController;

  bool _gridMode = true; // true=网格, false=列表
  bool _isLoading = false;
  String _keyword = '';
  bool _searching = false; // 当前是否为搜索结果（否则显示分类/发现）

  /// 每个源（含聚搜）的结果与分类。
  final Map<String, List<SearchBook>> _results = {};
  final Map<String, List<ExploreCategory>> _categories = {};
  final Map<String, String> _activeCategory = {}; // 源URL -> 分类名

  int get _tabCount => 1 + ShuyuanSourceStore.instance.sources.length;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabCount, vsync: this);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _tabController.dispose();
    super.dispose();
  }

  String _tabLabel(int index) {
    if (index == 0) return '聚搜';
    final src = ShuyuanSourceStore.instance.sources[index - 1];
    return src.bookSourceName;
  }

  XiaoshuoBookSource? _sourceForIndex(int index) {
    if (index == 0) return null;
    final src = ShuyuanSourceStore.instance.sources[index - 1];
    return src.toBookSource();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  /// 搜索：聚搜并发所有启用源；单源只搜当前源。
  Future<void> _search(String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return;
    setState(() {
      _keyword = k;
      _isLoading = true;
      _searching = true;
      _results.clear();
    });
    final sources = ShuyuanSourceStore.instance.toBookSources();
    if (_tabController.index == 0) {
      await Future.wait([
        for (final s in sources)
          _searchOne('aggregate', s, k).catchError((_) => <SearchBook>[]),
      ]);
    } else {
      final s = _sourceForIndex(_tabController.index);
      if (s != null) {
        await _searchOne(s.bookSourceUrl, s, k).catchError((_) {});
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _searchOne(String key, XiaoshuoBookSource s, String k) async {
    try {
      final list = await _webBook.searchBook(source: s, key: k);
      if (mounted) {
        setState(() {
          _results[key] = list;
          _categories[key] ??= _webBook.getExploreCategories(s);
        });
      }
    } catch (e) {
      if (mounted) {
        _results[key] = const [];
        _toast('${s.bookSourceName}: $e');
      }
    }
  }

  /// 单源浏览：当前 tab 加载该源发现页（分类或首页）。
  Future<void> _loadExplore(int index) async {
    final s = _sourceForIndex(index);
    if (s == null) return;
    if (_categories[s.bookSourceUrl] == null) {
      _categories[s.bookSourceUrl] = _webBook.getExploreCategories(s);
    }
    if (_results[s.bookSourceUrl] != null && !_searching) return;
    setState(() => _isLoading = true);
    try {
      final active = _activeCategory[s.bookSourceUrl];
      List<SearchBook> list;
      if (active != null && active.isNotEmpty) {
        final books = await _webBook.exploreCategory(
          source: s,
          categoryUrl: active,
        );
        list = [for (final b in books) _toSearchBook(b, s)];
      } else {
        final books = await _webBook.exploreBook(source: s);
        list = [for (final b in books) _toSearchBook(b, s)];
      }
      if (mounted) {
        setState(() {
          _results[s.bookSourceUrl] = list;
          _searching = false;
        });
      }
    } catch (e) {
      if (mounted) _toast('${s.bookSourceName}: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  SearchBook _toSearchBook(dynamic book, XiaoshuoBookSource s) {
    if (book is SearchBook) return book;
    // XiaoshuoBook -> SearchBook 兼容
    return SearchBook(
      bookUrl: book.bookUrl ?? '',
      name: book.name ?? '',
      author: book.author ?? '',
      coverUrl: book.coverUrl,
      kind: book.kind,
      lastChapter: book.lastChapter,
      bookSourceUrl: s.bookSourceUrl,
      bookSourceName: s.bookSourceName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源'),
        actions: [
          IconButton(
            tooltip: '书源仓库',
            icon: const Icon(Icons.storage_rounded, size: 22),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ShuyuanSourceRepoPage(),
                ),
              ).then((_) => setState(() {}));
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(isDark),
          _buildSourceTabs(isDark),
          Expanded(
            child: ListenableBuilder(
              listenable: ShuyuanSourceStore.instance,
              builder: (context, _) {
                return TabBarView(
                  controller: _tabController,
                  children: [
                    for (var i = 0; i < _tabCount; i++) _buildTabBody(i, isDark),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: isDark
                    ? JellyTheme.cardDark
                    : JellyTheme.cardLight,
                borderRadius: BorderRadius.circular(18),
              ),
              child: TextField(
                controller: _searchCtrl,
                textInputAction: TextInputAction.search,
                onSubmitted: _search,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: '搜索书籍',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: JellyTheme.textSecondary,
                  ),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: JellyTheme.textSecondary,
                  ),
                  suffixIcon: _searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() {});
                          },
                        ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: _gridMode ? '列表视图' : '网格视图',
            iconSize: 20,
            icon: Icon(
              _gridMode ? Icons.view_list_rounded : Icons.grid_view_rounded,
              color: JellyTheme.textSecondary,
            ),
            onPressed: () => setState(() => _gridMode = !_gridMode),
          ),
          PopupMenuButton<String>(
            tooltip: '分类',
            icon: Icon(
              Icons.filter_list_rounded,
              size: 20,
              color: JellyTheme.textSecondary,
            ),
            onSelected: (v) async {
              final idx = _tabController.index;
              final s = _sourceForIndex(idx);
              if (s == null) return;
              setState(() => _activeCategory[s.bookSourceUrl] = v);
              _searching = false;
              await _loadExplore(idx);
            },
            itemBuilder: (ctx) {
              final idx = _tabController.index;
              final s = _sourceForIndex(idx);
              final cats = s == null ? <ExploreCategory>[] : _categories[s.bookSourceUrl] ?? [];
              if (cats.isEmpty) {
                return const [
                  PopupMenuItem(
                    enabled: false,
                    child: Text('该源无分类'),
                  ),
                ];
              }
              return [
                for (final c in cats)
                  PopupMenuItem(
                    value: c.url,
                    child: Text(c.name),
                  ),
              ];
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSourceTabs(bool isDark) {
    return Container(
      height: 40,
      child: TabBar(
        controller: _tabController,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        indicatorColor: JellyTheme.primary,
        labelColor: JellyTheme.primary,
        unselectedLabelColor: JellyTheme.textSecondary,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 13),
        dividerColor: Colors.transparent,
        tabs: [
          for (var i = 0; i < _tabCount; i++)
            Tab(text: _tabLabel(i)),
        ],
      ),
    );
  }

  Widget _buildTabBody(int index, bool isDark) {
    if (index == 0) {
      return _buildAggregateBody(isDark);
    }
    final src = ShuyuanSourceStore.instance.sources[index - 1];
    if (!src.enabled) {
      return _buildEmpty('该源已停用', isDark);
    }
    final results = _results[src.bookSourceUrl] ?? [];
    if (results.isEmpty && !_isLoading && !_searching) {
      // 首次进入自动加载发现页
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadExplore(index);
      });
      return _buildLoading(isDark);
    }
    return _buildResults(results, isDark);
  }

  Widget _buildAggregateBody(bool isDark) {
    final results = _results['aggregate'] ?? [];
    if (_isLoading) return _buildLoading(isDark);
    if (results.isEmpty) {
      return _buildEmpty(
        _keyword.isEmpty ? '聚搜：输入关键词搜索全部书源' : '无结果',
        isDark,
      );
    }
    return _buildResults(results, isDark);
  }

  Widget _buildResults(List<SearchBook> results, bool isDark) {
    if (results.isEmpty) return _buildEmpty('暂无内容', isDark);
    if (_gridMode) {
      return GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 12,
          crossAxisSpacing: 8,
          childAspectRatio: 0.56,
        ),
        itemCount: results.length,
        itemBuilder: (ctx, i) => _buildGridCard(results[i], isDark),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) => _buildListTile(results[i], isDark),
    );
  }

  Widget _buildGridCard(SearchBook book, bool isDark) {
    return GestureDetector(
      onTap: () => _openBook(book),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: book.coverUrl == null || book.coverUrl!.isEmpty
                  ? _coverPlaceholder(book.name)
                  : CachedNetworkImage(
                      imageUrl: book.coverUrl!,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _coverPlaceholder(book.name),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            book.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.2,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          if (book.author.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              book.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: JellyTheme.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildListTile(SearchBook book, bool isDark) {
    return GestureDetector(
      onTap: () => _openBook(book),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 56,
                height: 74,
                child: book.coverUrl == null || book.coverUrl!.isEmpty
                    ? _coverPlaceholder(book.name)
                    : CachedNetworkImage(
                        imageUrl: book.coverUrl!,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) =>
                            _coverPlaceholder(book.name),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color:
                          isDark ? Colors.white : JellyTheme.textPrimaryLight,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [book.author, book.kind]
                        .where((e) => e != null && e.isNotEmpty)
                        .join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: JellyTheme.textSecondary,
                    ),
                  ),
                  if (book.lastChapter != null &&
                      book.lastChapter!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      book.lastChapter!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: JellyTheme.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: JellyTheme.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _coverPlaceholder(String name) {
    return Container(
      color: JellyTheme.primary.withValues(alpha: 0.12),
      alignment: Alignment.center,
      child: Text(
        name.isNotEmpty ? name[0] : '书',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: JellyTheme.primary,
        ),
      ),
    );
  }

  void _openBook(SearchBook book) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ShuyuanBookDetailPage(
          bookUrl: book.bookUrl,
          name: book.name,
          bookSourceUrl: book.bookSourceUrl,
        ),
      ),
    );
  }

  Widget _buildLoading(bool isDark) {
    return Center(
      child: CircularProgressIndicator(
        strokeWidth: 2.5,
        color: JellyTheme.primary,
      ),
    );
  }

  Widget _buildEmpty(String text, bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.auto_stories_outlined,
            size: 48,
            color: JellyTheme.textSecondary,
          ),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(fontSize: 13, color: JellyTheme.textSecondary),
          ),
        ],
      ),
    );
  }
}
