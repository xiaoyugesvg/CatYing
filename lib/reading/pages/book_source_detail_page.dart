import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/book_source.dart';
import '../services/book_source_service.dart';
import '../theme/jelly_theme.dart';
import 'book_source_reader_page.dart';

/// 书源详情页 —— 书籍信息 + 目录。
///
/// ── 为什么详情和目录放一页 ────────────────────────────────────
/// 网络小说只有"目录"这一个有意义的次级信息，没有出版社/页数那种元数据。
/// 拆成两页会让用户多点一次才能开始看，收益为零。
///
/// ── 换源入口 ──────────────────────────────────────────────────
/// 右上角「换源」：用书名去其它已启用书源再搜一次，
/// 用来解决"这个源正文乱码/缺章"的常见问题（V2.0.7 的换源功能）。
class BookSourceDetailPage extends StatefulWidget {
  const BookSourceDetailPage({super.key, required this.result});

  final BookSourceResult result;

  @override
  State<BookSourceDetailPage> createState() => _BookSourceDetailPageState();
}

class _BookSourceDetailPageState extends State<BookSourceDetailPage> {
  final store = BookSourceStore.instance;

  BookSourceResult get _result => _current ?? widget.result;
  BookSourceResult? _current;

  bool _loadingToc = true;
  String? _error;
  List<BookSourceChapter> _chapters = const [];

  /// 详情接口补到的字段（封面/简介/作者），优先于搜索结果里的
  Map<String, dynamic> _info = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _titleColor =>
      _isDark ? Colors.white : JellyTheme.textPrimaryLight;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  Future<void> _load() async {
    setState(() {
      _loadingToc = true;
      _error = null;
    });
    final r = _result;
    try {
      // 1) 详情：补全封面/简介/作者，并拿到 tocUrl
      final info = await BookSourceService.instance.bookInfo(r.source, r.bookUrl);
      if (!mounted) return;
      if (info != null) _info = info;

      // 2) 目录：详情里带的 tocUrl 优先（有些站详情页和目录页不同）
      final tocUrl = (_info['tocUrl'] ?? '').toString().trim();
      final t = await BookSourceService.instance
          .toc(r.source, tocUrl.isEmpty ? r.bookUrl : tocUrl);
      if (!mounted) return;
      if (!t.ok) {
        setState(() {
          _loadingToc = false;
          _error = t.error ?? '目录获取失败';
        });
        return;
      }
      setState(() {
        _chapters = t.list;
        _loadingToc = false;
        _error = t.list.isEmpty ? '这个源没有返回任何章节' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingToc = false;
        _error = '加载失败：$e';
      });
    }
  }

  String get _name => (_info['name'] ?? _result.name).toString();
  String get _author => (_info['author'] ?? _result.author).toString();
  String get _cover => (_info['coverUrl'] ?? _result.coverUrl).toString();
  String get _intro => (_info['intro'] ?? _result.intro).toString();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          _isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        title: Text('书籍详情',
            style: TextStyle(fontSize: 18, color: _titleColor)),
        actions: [
          IconButton(
            tooltip: '换源',
            icon: Icon(Icons.swap_horiz_rounded, color: _titleColor),
            onPressed: _chapters.isEmpty ? null : _changeSource,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _header(),
          const Divider(height: 1),
          Expanded(child: _tocArea()),
        ],
      ),
      floatingActionButton: _chapters.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openReader(0),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('开始阅读'),
            ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 84,
              height: 112,
              child: _cover.isEmpty
                  ? Container(
                      color: JellyTheme.primary.withValues(alpha: 0.1),
                      child: Icon(Icons.menu_book_rounded,
                          size: 30, color: JellyTheme.primary),
                    )
                  : CachedNetworkImage(
                      imageUrl: _cover,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        color: JellyTheme.primary.withValues(alpha: 0.1),
                        child: Icon(Icons.menu_book_rounded,
                            size: 30, color: JellyTheme.primary),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: _titleColor)),
                const SizedBox(height: 4),
                Text(
                  [
                    if (_author.isNotEmpty) _author,
                    if (_chapters.isNotEmpty) '${_chapters.length} 章',
                  ].join(' · '),
                  style:
                      TextStyle(fontSize: 12.5, color: JellyTheme.textSecondary),
                ),
                const SizedBox(height: 6),
                // 来源标签：明确告诉用户"这本书是从哪个源来的"
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: JellyTheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(_result.source.name,
                      style: TextStyle(
                          fontSize: 11, color: JellyTheme.primary)),
                ),
                if (_intro.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    _intro,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: JellyTheme.textSecondary),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tocArea() {
    if (_loadingToc) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: JellyTheme.primary),
            const SizedBox(height: 14),
            Text('正在获取目录...',
                style: TextStyle(fontSize: 13, color: JellyTheme.textSecondary)),
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
              const Icon(Icons.error_outline_rounded,
                  size: 48, color: Colors.orangeAccent),
              const SizedBox(height: 14),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 13, color: JellyTheme.textSecondary)),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
              TextButton.icon(
                onPressed: _changeSource,
                icon: const Icon(Icons.swap_horiz_rounded),
                label: const Text('换个书源'),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 90),
      itemCount: _chapters.length,
      itemBuilder: (c, i) {
        final ch = _chapters[i];
        return ListTile(
          dense: true,
          title: Text(ch.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: _titleColor)),
          onTap: () => _openReader(i),
        );
      },
    );
  }

  void _openReader(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookSourceReaderPage(
          source: _result.source,
          bookName: _name,
          author: _author,
          chapters: _chapters,
          initialIndex: index,
        ),
      ),
    );
  }

  /// 换源：用书名去其它已启用源再搜一次，选中的结果替换当前源。
  Future<void> _changeSource() async {
    final name = _name;
    if (name.isEmpty) return;

    // 排除当前源（换源的意义就是换到别的源）
    final others = store.enabled
        .where((s) => s.id != _result.source.id)
        .toList();
    if (others.isEmpty) {
      _toast('没有其它已启用的书源可换');
      return;
    }

    final loading = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 14),
                Text('正在其它书源中查找...'),
              ],
            ),
          ),
        ),
      ),
    );

    List<BookSourceResult> found = const [];
    try {
      final r = await BookSourceService.instance.searchAll(others, name);
      found = r.results
          .where((e) => e.sameBookAs(_result))
          .toList();
    } finally {
      if (mounted) Navigator.pop(context); // 关 loading
      // loading 的 future 要吞掉，否则未 await 报错
      unawaited(loading);
    }

    if (!mounted) return;
    if (found.isEmpty) {
      _toast('其它书源里没找到《$name》');
      return;
    }

    final picked = await showModalBottomSheet<BookSourceResult>(
      context: context,
      backgroundColor: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            Text('换源（找到 ${found.length} 个）',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: _titleColor)),
            const SizedBox(height: 6),
            Text('换源可解决正文乱码 / 缺章',
                style:
                    TextStyle(fontSize: 12, color: JellyTheme.textSecondary)),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: found
                    .map((r) => ListTile(
                          title: Text(r.source.name,
                              style:
                                  TextStyle(fontSize: 14, color: _titleColor)),
                          subtitle: Text(r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: JellyTheme.textSecondary)),
                          onTap: () => Navigator.pop(ctx, r),
                        ))
                    .toList(),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );

    if (picked == null || !mounted) return;
    setState(() {
      _current = picked;
      _info = const {};
      _chapters = const [];
    });
    await _load();
  }
}

/// 显式忽略 future（用于"关掉对话框"这种不需要结果的地方）
void unawaited(Future<void> f) {
  f.catchError((_) {});
}
