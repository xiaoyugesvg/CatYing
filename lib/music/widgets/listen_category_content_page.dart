import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../models/models.dart';
import '../services/music_api.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import 'listen_view_toggle.dart';
import 'music_components.dart';

/// 听书分类内容页（公共）。
///
/// 博看 / 喜雅 / 一五三个源的"分类 → 专辑列表"共用一个实现：
/// 顶部搜索框（本地过滤名称/作者）+ 视图切换（列表 / 宫格 2~5 列）+ 分页加载。
///
/// [loader] 返回第 [page] 页的专辑列表（page 从 1 起）；
/// [onOpenAlbum] 点击专辑卡时跳对应专辑单集页；
/// [sourceLabel] 网格卡副标题里的来源名（博看 / 喜雅 / 一五）。
class ListenCategoryContentPage extends StatefulWidget {
  const ListenCategoryContentPage({
    super.key,
    required this.title,
    required this.loader,
    required this.onOpenAlbum,
    this.sourceLabel = '听书',
  });

  final String title;
  final Future<MusicListResult<Song>> Function(int page) loader;
  final void Function(BuildContext context, Song song) onOpenAlbum;
  final String sourceLabel;

  @override
  State<ListenCategoryContentPage> createState() =>
      _ListenCategoryContentPageState();
}

class _ListenCategoryContentPageState extends State<ListenCategoryContentPage> {
  final _items = <Song>[];
  bool _loading = true;
  bool _loadingMore = false;
  String _error = '';
  int _page = 1;
  bool _hasMore = true;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loadingMore || !_hasMore) return;
    setState(() {
      if (_items.isEmpty) _loading = true;
      _loadingMore = true;
    });
    final r = await widget.loader(_page);
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

  List<Song> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _items;
    return _items
        .where((s) =>
            s.name.toLowerCase().contains(q) ||
            s.artists.toLowerCase().contains(q))
        .toList();
  }

  /// 子页面底部预留：迷你播放条(56) + 底间隙(8) + Home 指示条安全区。
  /// 播放条是全局悬浮层，列表底部留出这段才不会被它压住。
  double get _bottomReserve {
    final pad = MediaQuery.paddingOf(context).bottom;
    return 56 + 8 + pad;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MusicTheme.background,
      appBar: AppBar(
        title:
            Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: const [ListenViewToggle()],
      ),
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
                    _searchBar(),
                    Expanded(
                      child: ValueListenableBuilder<int>(
                        valueListenable: SettingsStore.instance.listenGrid,
                        builder: (_, grid, __) {
                          final visible = _visible;
                          if (visible.isEmpty) {
                            return Center(
                              child: Text(
                                _query.trim().isEmpty
                                    ? '这个分类暂时没有内容'
                                    : '没有匹配「${_query.trim()}」的专辑',
                                style: TextStyle(
                                    color: MusicTheme.secondary,
                                    fontSize: AppTheme.fontBody),
                              ),
                            );
                          }
                          if (grid == 0) {
                            return _listView(visible);
                          }
                          return _gridView(visible, grid);
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

  /// 顶部搜索框（本地过滤当前已加载列表）。
  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: MusicTheme.fill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: MusicTheme.secondary.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 17, color: MusicTheme.secondary),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                style: TextStyle(
                    color: MusicTheme.label, fontSize: AppTheme.fontSubhead),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: '搜索专辑 / 作者',
                  hintStyle: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontSubhead),
                ),
              ),
            ),
            if (_query.isNotEmpty)
              GestureDetector(
                onTap: () {
                  _searchCtrl.clear();
                  setState(() => _query = '');
                },
                child: Icon(Icons.close_rounded,
                    size: 16, color: MusicTheme.secondary),
              ),
          ],
        ),
      ),
    );
  }

  Widget _listView(List<Song> visible) {
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(0, 4, 0, _bottomReserve),
      itemCount: visible.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final a = visible[i];
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CoverImage(url: a.coverUrl, size: 42, cornerRadius: 8),
          ),
          title: Text(a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: MusicTheme.label)),
          subtitle: Text(
            a.artists.trim().isEmpty ? '${widget.sourceLabel} · 主播' : a.artists,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: MusicTheme.secondary, fontSize: AppTheme.fontCaption),
          ),
          trailing:
              Icon(Icons.chevron_right_rounded, color: MusicTheme.secondary),
          onTap: () => widget.onOpenAlbum(context, a),
        );
      },
    );
  }

  Widget _gridView(List<Song> visible, int grid) {
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(16, 10, 16, _bottomReserve),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: grid,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        mainAxisExtent: () {
          final w =
              (MediaQuery.sizeOf(context).width - 16 * 2 - 12 * (grid - 1)) /
                  grid;
          final ts = MediaQuery.textScalerOf(context);
          return w +
              6 +
              ts.scale(12) * 1.25 * 2 +
              2 +
              ts.scale(11) * 1.35 +
              8;
        }(),
      ),
      itemCount: visible.length,
      itemBuilder: (_, i) {
        final a = visible[i];
        return _AlbumGridCard(
          song: a,
          sourceLabel: widget.sourceLabel,
          onTap: () => widget.onOpenAlbum(context, a),
        );
      },
    );
  }
}

/// 专辑网格卡：1:1 封面 + 两行标题 + 「来源 · 作者」。
class _AlbumGridCard extends StatelessWidget {
  const _AlbumGridCard({
    required this.song,
    required this.sourceLabel,
    required this.onTap,
  });

  final Song song;
  final String sourceLabel;
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
            '$sourceLabel · ${artist.isEmpty ? '主播' : artist}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: MusicTheme.secondary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
