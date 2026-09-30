import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../widgets/common_widgets.dart';
import 'search_page.dart';

/// 书架页：本地书籍的入口。
///
/// 本轮只立骨架 —— 书架数据源（本地存储）还没接，[books] 先留空占位，
/// 页面结构、空态和网格样式先定下来，接服务时只需换掉数据来源。
class BookShelfPage extends StatefulWidget {
  const BookShelfPage({super.key});

  @override
  State<BookShelfPage> createState() => _BookShelfPageState();
}

class _BookShelfPageState extends State<BookShelfPage> {
  /// 占位数据源：后续接本地书架（Hive）后替换。
  ///
  /// 元素类型先留 dynamic —— 书籍字段（作者/来源/阅读进度）还没定，
  /// 现在造一个模型只会马上被推翻；等字段定了再收敛成强类型，
  /// 卡片里那套宽松取值也一起删掉。
  final List<dynamic> books = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 透明背景：让全局壁纸层透出（与首页/史藏统一）
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: books.isEmpty ? _buildEmpty() : _buildGrid()),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 顶栏
  // ============================================================

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppTheme.spacingXL,
          AppTheme.spacingLG, AppTheme.spacingMD, AppTheme.spacingSM),
      child: Row(
        children: [
          Text('书架',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontTitle2,
                  fontWeight: FontWeight.w700)),
          const Spacer(),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 空态的文案就是让人来这儿找书，按钮必须真能点到搜索页
            onTap: () => Get.to(() => const BookSearchPage()),
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.backgroundTertiary,
                borderRadius:
                    BorderRadius.circular(AppTheme.glassRadiusSmall),
                border:
                    Border.all(color: AppTheme.glassBorder, width: 0.8),
              ),
              child: Icon(Icons.search,
                  size: 19, color: AppTheme.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return const EmptyState(
      title: '书架还是空的',
      message: '去『搜索』里找一本书吧',
      icon: Icons.menu_book_outlined,
    );
  }

  // ============================================================
  // 网格
  // ============================================================

  Widget _buildGrid() {
    const columns = 3;
    const hPadding = AppTheme.spacingLG;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = (constraints.maxWidth -
                hPadding * 2 -
                AppTheme.spacingMD * (columns - 1)) /
            columns;
        // 卡片高 = 封面(3:4) + 书名一行 + 间距。
        // 余量给到 40：算少了 GridView 会直接报溢出（书名那行被裁），
        // 算多了只是卡片底部留一点空白，代价小得多。
        final cardHeight = cardWidth * 4 / 3 + 40;

        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(
              hPadding, AppTheme.spacingXS, hPadding, AppTheme.spacingXXL),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: AppTheme.spacingMD,
            mainAxisSpacing: AppTheme.spacingMD,
            childAspectRatio: cardWidth / cardHeight,
          ),
          itemCount: books.length,
          itemBuilder: (context, i) => _bookCard(books[i]),
        );
      },
    );
  }

  Widget _bookCard(dynamic book) {
    final item = _readBook(book);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
          child: AspectRatio(
            aspectRatio: 3 / 4,
            child: item.cover.isEmpty
                ? _coverPlaceholder()
                : CachedNetworkImage(
                    imageUrl: item.cover,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => _coverPlaceholder(),
                    errorWidget: (_, __, ___) =>
                        _coverPlaceholder(icon: Icons.broken_image_outlined),
                  ),
          ),
        ),
        const SizedBox(height: AppTheme.spacingSM),
        Text(
          item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: AppTheme.textPrimary, fontSize: AppTheme.fontSubhead),
        ),
      ],
    );
  }

  /// 宽松取字段：模型定下来之前按常见候选键取，取不到就给个空串
  ({String name, String cover}) _readBook(dynamic book) {
    if (book is Map) {
      final name = (book['name'] ?? book['title'] ?? '').toString().trim();
      final cover = (book['cover'] ?? book['coverUrl'] ?? book['pic'] ?? '')
          .toString()
          .trim();
      return (name: name.isEmpty ? '未命名' : name, cover: cover);
    }
    return (name: '未命名', cover: '');
  }

  Widget _coverPlaceholder({IconData icon = Icons.menu_book_outlined}) {
    return ColoredBox(
      color: AppTheme.backgroundTertiary,
      child: Center(child: Icon(icon, size: 22, color: AppTheme.textTertiary)),
    );
  }
}
