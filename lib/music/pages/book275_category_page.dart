import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/music_api.dart';
import '../theme/music_theme.dart';
import '../../common/theme.dart';
import '../widgets/music_components.dart';
import 'book275_album_page.dart';

/// 275听书的**分类浏览**（最近上架 / 玄幻 / 修仙 …共 20 类）。
///
/// 与博看同形态（分类 → 专辑网格 → 专辑单集页），但数据是
/// **纯 Dart 直连 i275.com**：HTML 站 + PHPSESSID 会话。
class Book275CategoryPage extends StatefulWidget {
  const Book275CategoryPage({super.key});

  @override
  State<Book275CategoryPage> createState() => _Book275CategoryPageState();
}

class _Book275CategoryPageState extends State<Book275CategoryPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MusicTheme.background,
      appBar: AppBar(title: const Text('275听书')),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: MusicApi.book275Categories.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final c = MusicApi.book275Categories[i];
          return ListTile(
            leading:
                Icon(Icons.headphones_rounded, color: MusicTheme.tint),
            title: Text(c.name, style: TextStyle(color: MusicTheme.label)),
            trailing: Icon(Icons.chevron_right_rounded,
                color: MusicTheme.secondary),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(settings: const RouteSettings(name: 'music:page'),
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
        .book275Category(widget.categoryId, page: 1);
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
        if (_items.isEmpty) _error = '这个分类暂时没有内容';
        return;
      }
      _items.addAll(r.list);
      // 275 分类是"搜索词聚合"，一页即全部
      _hasMore = false;
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
              : GridView.builder(
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
                        MaterialPageRoute(settings: const RouteSettings(name: 'music:page'),
                          builder: (_) => Book275AlbumPage(
                            bookId: '${a.id}',
                            albumName: a.name,
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

/// 专辑网格卡：1:1 封面 + 两行标题 + 「275 · 演播」。
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
            '275 · ${artist.isEmpty ? '主播' : artist}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: MusicTheme.secondary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
