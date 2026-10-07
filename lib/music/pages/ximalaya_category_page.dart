import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../services/music_api.dart';
import '../theme/music_theme.dart';
import '../widgets/listen_category_content_page.dart';
import 'ximalaya_album_page.dart';

/// 喜马拉雅的**分类浏览**（有声书 / 儿童 / 相声 / 历史…）。
///
/// 为什么要有分类入口：喜马拉雅的**搜索走第三方聚合站，不稳定**
///（实测出现过 TLS 断开），而分类/专辑走的是官方域名，稳定得多。
/// 所以"发现内容"这条主路径靠分类，搜索只当补充。
///
/// 分类以**宫格**展示（与发现页"全部分类"同款，不再是纯列表），
/// 点击分类直接进入该分类的**专辑内容页**（搜索 + 视图切换 + 分页）。
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
      appBar: AppBar(title: const Text('喜雅')),
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
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 12,
                    mainAxisExtent: () {
                      final ts = MediaQuery.textScalerOf(context);
                      final textH = ts.scale(AppTheme.fontBody) * 1.4;
                      return (36.0 + 12 * 2) > textH + 12 * 2
                          ? 36.0 + 12 * 2 + 4
                          : textH + 12 * 2 + 4;
                    }(),
                  ),
                  itemCount: _cats.length,
                  itemBuilder: (_, i) {
                    final c = _cats[i];
                    return _CategoryTile(
                      name: c.name,
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          settings: const RouteSettings(name: 'music:page'),
                          builder: (_) => ListenCategoryContentPage(
                            title: c.name,
                            sourceLabel: '喜雅',
                            loader: (page) => MusicApi.instance
                                .ximalayaCategory(c.id, page: page),
                            onOpenAlbum: (ctx, song) =>
                                Navigator.of(ctx).push<void>(
                              MaterialPageRoute(
                                settings:
                                    const RouteSettings(name: 'music:page'),
                                builder: (_) => XimalayaAlbumPage(
                                  albumId: '${song.id}',
                                  albumName: song.name,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

/// 分类宫格卡（图标 + 名称 + 箭头），与发现页"全部分类"同款。
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: MusicTheme.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: MusicTheme.label.withValues(alpha: 0.06),
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: MusicTheme.tint.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.graphic_eq_rounded,
                  color: MusicTheme.tint, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w500),
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: MusicTheme.secondary, size: 18),
          ],
        ),
      ),
    );
  }
}
