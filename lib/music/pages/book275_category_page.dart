import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../models/models.dart';
import '../services/music_api.dart';
import '../theme/music_theme.dart';
import '../widgets/listen_category_content_page.dart';
import 'book275_album_page.dart';

/// 275听书的**分类浏览**（最近上架 / 玄幻 / 修仙 …共 20 类）。
///
/// 分类以**宫格**展示（与发现页"全部分类"同款），点击分类直接进入
/// 该分类的**专辑内容页**（搜索 + 视图切换），不再"把分类再列表一次"。
/// 数据是**纯 Dart 直连 i275.com**：HTML 站 + PHPSESSID 会话。
class Book275CategoryPage extends StatefulWidget {
  const Book275CategoryPage({super.key});

  @override
  State<Book275CategoryPage> createState() => _Book275CategoryPageState();
}

class _Book275CategoryPageState extends State<Book275CategoryPage> {
  @override
  Widget build(BuildContext context) {
    final cats = MusicApi.book275Categories;
    return Scaffold(
      backgroundColor: MusicTheme.background,
      appBar: AppBar(title: const Text('七五听书')),
      body: GridView.builder(
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
        itemCount: cats.length,
        itemBuilder: (_, i) {
          final c = cats[i];
          return _CategoryTile(
            name: c.name,
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                settings: const RouteSettings(name: 'music:page'),
                builder: (_) => ListenCategoryContentPage(
                  title: c.name,
                  sourceLabel: '七五',
                  // 275 分类是"搜索词聚合"，一页即全部：第 2 页起返回空列表停分页
                  loader: (page) async {
                    if (page > 1) {
                      return const MusicListResult(ok: true, list: []);
                    }
                    return MusicApi.instance.book275Category(c.id, page: 1);
                  },
                  onOpenAlbum: (ctx, song) =>
                      Navigator.of(ctx).push<void>(
                    MaterialPageRoute(
                      settings: const RouteSettings(name: 'music:page'),
                      builder: (_) => Book275AlbumPage(
                        bookId: '${song.id}',
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
