import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/music_api.dart';
import '../theme/music_theme.dart';
import '../../common/theme.dart';
import '../widgets/music_components.dart';
import 'ximalaya_album_page.dart';

/// 喜马拉雅的**分类浏览**（有声书 / 儿童 / 相声 / 历史…）。
///
/// 为什么要有分类入口：喜马拉雅的**搜索走第三方聚合站，不稳定**
///（实测出现过 TLS 断开），而分类/专辑走的是官方域名，稳定得多。
/// 所以"发现内容"这条主路径靠分类，搜索只当补充。
class XimalayaCategoryPage extends StatefulWidget {
  const XimalayaCategoryPage({super.key});

  @override
  State<XimalayaCategoryPage> createState() => _XimalayaCategoryPageState();
}

class _XimalayaCategoryPageState extends State<XimalayaCategoryPage> {
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
      final cats = await MusicApi.instance.ximalayaCategories();
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
      // push 出来的页面不在 `MusicRootView` 的音乐主题作用域内 ✗ →
      // 不显式指定会回落影视配色；与「我的歌单 / 喜马拉雅专辑」同做法 ✓
      backgroundColor: MusicTheme.background,
      appBar: AppBar(title: const Text('喜马拉雅')),
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
                      leading: Icon(Icons.graphic_eq_rounded,
                          color: MusicTheme.tint),
                      title: Text(c.name,
                          style: TextStyle(color: MusicTheme.label)),
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

/// 某分类下的专辑列表。
///
/// ⚠️ 只做**单页 + 手动"加载更多"**，不做无限滚动：喜马拉雅的单集动辄几千集，
/// 无脑翻页会让请求量失控（数据源那边一页 50 个专辑）。
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
        .ximalayaCategory(widget.categoryId, page: _page);
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
                    // 对齐 Beans 精选页：**2 列网格**（原来是竖排 ListTile）
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                        // 🔴 原来用固定比例 `childAspectRatio: 0.66` ✗ —— **两头堵**：
                        //   · 宽屏：格子高 = 宽/0.66 → 被拉得很高、底部大片留白 ✗
                        //   · 窄屏 + 系统大字号：内容（1:1 封面 + 2 行标题 + 副标题）
                        //     仍会超出格子高 → **溢出** ✗
                        // 改成"**按可用宽度算格子高**"：格宽 = (屏宽 - 内边距 - 间距)/列数，
                        // 高度 = 封面(等于格宽) + 文字区（随系统字号缩放）✓ → 两边都不畸形 ✓
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
                            // 6(间距) + 2 行标题 + 2(间距) + 1 行副标题 + 8(余量)
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
                                builder: (_) => XimalayaAlbumPage(
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

/// 专辑网格卡（对齐 Beans 精选页）：
/// **1:1 封面 + 两行标题 + 「平台 · 作者」**。
///
/// 封面走 `CoverImage`（带磁盘缓存 + 失败自动重试 + 占位），
/// 比原来的 `Image.network` 更省流量，也不会留空白格。
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
          // Beans 的副标题就是「平台 · 作者」两段式
          Text(
            '喜马拉雅 · ${artist.isEmpty ? '主播' : artist}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: MusicTheme.secondary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
