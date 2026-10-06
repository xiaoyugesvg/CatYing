import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/music_api.dart';
import '../theme/music_theme.dart';
import '../../common/theme.dart';
import '../widgets/music_components.dart';
import 'bookan_album_page.dart';

/// 博看听书的**分类浏览**（有声书：相声评书 / 国学经典 / 故事会…）。
///
/// 与喜马拉雅同形态（分类 → 专辑网格 → 专辑单集页），但数据源是
/// **纯 Dart 直连博看官方接口**（`MusicApi.bookan*`），不走 Node。
class BookanCategoryPage extends StatefulWidget {
  const BookanCategoryPage({super.key});

  @override
  State<BookanCategoryPage> createState() => _BookanCategoryPageState();
}

class _BookanCategoryPageState extends State<BookanCategoryPage> {
  bool _loading = true;
  String _error = '';
  List<({String id, String name})> _cats = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      // 博看分类是固定配置（官方实例的 11 个分类），本地直接返回
      final cats = MusicApi.bookanCategories;
      if (!mounted) return;
      setState(() {
        _loading = false;
        _cats = cats;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MusicTheme.background,
      appBar: AppBar(title: const Text('博看听书')),
      body: _loading
          ? Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                    strokeWidth: 2.4, color: MusicTheme.tint),
              ),
            )
          : _error.isNotEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error,
                          style: TextStyle(
                              color: MusicTheme.secondary,
                              fontSize: AppTheme.fontBody)),
                      const SizedBox(height: 14),
                      TextButton(
                          onPressed: _load,
                          child: Text('重试',
                              style: TextStyle(color: MusicTheme.tint))),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: _cats.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final c = _cats[i];
                    return ListTile(
                      leading: Icon(Icons.headphones_rounded,
                          color: MusicTheme.tint),
                      title: Text(c.name,
                          style: TextStyle(color: MusicTheme.label)),
                      trailing: Icon(Icons.chevron_right_rounded,
                          color: MusicTheme.secondary),
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => _AlbumListPage(
                            categoryId: c.id,
                            categoryName: c.name,
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

/// 某分类下的专辑列表（2 列网格 + 手动"加载更多"）。
class _AlbumListPage extends StatefulWidget {
  const _AlbumListPage({required this.categoryId, required this.categoryName});

  final String categoryId;
  final String categoryName;

  @override
  State<_AlbumListPage> createState() => _AlbumListPageState();
}

class _AlbumListPageState extends State<_AlbumListPage> {
  final _items = <Song>[];
  bool _loading = true;
  bool _loadingMore = false;
  String _error = '';
  int _page = 1;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loadingMore || !_hasMore) return;
    setState(() {
      if (_items.isEmpty) _loading = true;
      _loadingMore = true;
    });
    final r = await MusicApi.instance
        .bookanCategory(widget.categoryId, page: _page);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loadingMore = false;
      if (!r.ok) {
        _error = r.message;
        _hasMore = false;
        return;
      }
      if (r.list.isEmpty) {
        _hasMore = false;
        return;
      }
      _items.addAll(r.list);
      _page++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MusicTheme.background,
      appBar: AppBar(
          title: Text(widget.categoryName,
              maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _loading
          ? Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                    strokeWidth: 2.4, color: MusicTheme.tint),
              ),
            )
          : _error.isNotEmpty && _items.isEmpty
              ? Center(
                  child: Text(_error,
                      style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontBody)),
                )
              : Column(
                  children: [
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 12,
                          mainAxisExtent: () {
                            final w = (MediaQuery.sizeOf(context).width -
                                    16 * 2 -
                                    12) /
                                2;
                            final ts = MediaQuery.textScalerOf(context);
                            return w +
                                6 +
                                ts.scale(12) * 1.35 * 2 +
                                2 +
                                ts.scale(11) * 1.35 +
                                8;
                          }(),
                        ),
                        itemCount: _items.length,
                        itemBuilder: (_, i) {
                          final a = _items[i];
                          return _AlbumGridCard(
                            song: a,
                            onTap: () => Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) => BookanAlbumPage(
                                  albumId: '${a.id}',
                                  albumName: a.name,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (_hasMore)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _loadingMore
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: MusicTheme.tint),
                              )
                            : TextButton(
                                onPressed: _load,
                                child: Text('加载更多',
                                    style: TextStyle(color: MusicTheme.tint)),
                              ),
                      ),
                  ],
                ),
    );
  }
}

/// 专辑网格卡：1:1 封面 + 两行标题 + 「博看 · 作者」。
class _AlbumGridCard extends StatelessWidget {
  const _AlbumGridCard({required this.song, required this.onTap});

  final Song song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final artist = song.artists.trim();
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: LayoutBuilder(
              builder: (c, cons) => CoverImage(
                url: song.coverUrl,
                size: cons.maxWidth,
                cornerRadius: 10,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            song.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: MusicTheme.label,
                fontSize: AppTheme.fontFootnote,
                height: 1.25,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            '博看 · ${artist.isEmpty ? '主播' : artist}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: MusicTheme.secondary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
