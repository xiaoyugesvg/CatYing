import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../services/book_service.dart';
import '../settings/sub/book_source_settings_page.dart';
import 'manga_reader_page.dart';
import 'reader_page.dart';

/// 在线搜书 —— 在已导入的「阅读 3.0」书源里搜书名。
///
/// 链路：搜到书 → 点进去拿目录 → 打开阅读器（小说）/ 漫画阅读器。
class BookSearchPage extends StatefulWidget {
  const BookSearchPage({super.key, this.initialKeyword});

  final String? initialKeyword;

  @override
  State<BookSearchPage> createState() => _BookSearchPageState();
}

class _BookSearchPageState extends State<BookSearchPage> {
  final _ctrl = TextEditingController();
  final svc = BookService.instance;

  @override
  void initState() {
    super.initState();
    final k = widget.initialKeyword;
    if (k != null && k.isNotEmpty) {
      _ctrl.text = k;
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 透明背景：让 ContentView 的全局壁纸层透出（与首页/史藏/音乐页统一）。
      // AppBar 仍用主题色，跟着浅色/深色外观走。
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text('搜书',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: '书源管理',
            icon: Icon(Icons.extension, color: AppTheme.accentColor, size: 21),
            onPressed: () => Get.to(() => const BookSourceSettingsPage()),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          // 搜索进度
          Obx(() {
            if (!svc.isSearching.value) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.spacingLG, 0, AppTheme.spacingLG, 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.8, color: AppTheme.accentColor),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '正在搜索 ${svc.searchDone.value}/${svc.searchTotal.value} 个源…',
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption),
                  ),
                ],
              ),
            );
          }),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, 0, AppTheme.spacingLG, AppTheme.spacingSM),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(21),
                border: Border.all(color: AppTheme.glassBorder, width: 0.8),
              ),
              child: Row(
                children: [
                  Icon(Icons.search, size: 17, color: AppTheme.textTertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      autofocus: widget.initialKeyword == null,
                      cursorColor: AppTheme.accentColor,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontSubhead + 1),
                      decoration: InputDecoration(
                        hintText: '输入书名',
                        hintStyle: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontSubhead + 1),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onSubmitted: (_) => _run(),
                    ),
                  ),
                  if (_ctrl.text.isNotEmpty)
                    GestureDetector(
                      onTap: () => setState(() => _ctrl.clear()),
                      child: Icon(Icons.cancel,
                          size: 16, color: AppTheme.textTertiary),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _run,
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.accentColor,
                borderRadius: BorderRadius.circular(21),
              ),
              child: const Text('搜索',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return Obx(() {
      // 没有书源 → 引导导入
      if (!svc.configured) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(Icons.menu_book_outlined,
                      size: 30, color: AppTheme.accentColor),
                ),
                const SizedBox(height: 16),
                Text('还没有可用的书源',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead + 2,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  '导入「阅读 3.0」格式的书源 JSON 后即可搜书。\n'
                  'App 本身不内置任何书源。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                      height: 1.5),
                ),
                const SizedBox(height: 18),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Get.to(() => const BookSourceSettingsPage()),
                  child: Container(
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppTheme.accentColor,
                      borderRadius: BorderRadius.circular(21),
                    ),
                    child: const Text('去导入书源',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        );
      }

      final list = svc.results;
      if (list.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search,
                    size: 38,
                    color: AppTheme.textTertiary.withValues(alpha: 0.5)),
                const SizedBox(height: 12),
                Text(
                  svc.isSearching.value
                      ? '正在搜索…'
                      : (svc.lastError.value.isNotEmpty
                          ? svc.lastError.value
                          : '输入书名开始搜索'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: svc.lastError.value.isNotEmpty
                          ? Colors.redAccent
                          : AppTheme.textSecondary,
                      fontSize: AppTheme.fontSubhead,
                      height: 1.5),
                ),
                if (svc.lastError.value.isEmpty &&
                    !svc.isSearching.value) ...[
                  const SizedBox(height: 6),
                  Text('会在 ${svc.enabledSources.length} 个书源里同时查找',
                      style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption)),
                ],
              ],
            ),
          ),
        );
      }

      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.spacingLG, 0, AppTheme.spacingLG, 24),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (c, i) => _bookRow(list[i]),
      );
    });
  }

  Widget _bookRow(BookItem b) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openBook(b),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面 3:4
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 54,
                height: 72,
                child: b.coverUrl.isEmpty
                    ? _coverPh()
                    : CachedNetworkImage(
                        imageUrl: b.coverUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => _coverPh(),
                        errorWidget: (_, __, ___) => _coverPh(),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(b.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontSubhead + 1,
                          fontWeight: FontWeight.w600,
                          height: 1.25)),
                  if (b.author.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(b.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontCaption)),
                  ],
                  if (b.intro.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(b.intro,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontCaption,
                            height: 1.35)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 来源标签
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.accentColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                b.source?.name ?? '未知',
                style: TextStyle(
                    color: AppTheme.accentColor,
                    fontSize: 9,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _coverPh() => ColoredBox(
        color: AppTheme.backgroundTertiary,
        child: Icon(Icons.menu_book_outlined,
            size: 20, color: AppTheme.textTertiary),
      );

  Future<void> _run() async {
    final k = _ctrl.text.trim();
    if (k.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入书名')));
      return;
    }
    FocusScope.of(context).unfocus();
    await svc.search(k);
  }

  /// 点一本书：拿详情 → 拿目录 → 进阅读器
  Future<void> _openBook(BookItem b) async {
    final src = b.source;
    if (src == null) return;
    final messenger = ScaffoldMessenger.of(context);

    // 加载提示（目录可能要几秒）
    messenger.showSnackBar(SnackBar(
      content: Text('正在加载《${b.name}》…'),
      duration: const Duration(seconds: 12),
    ));

    final info = await svc.bookInfo(src, b.bookUrl);
    if (!mounted) return;
    messenger.hideCurrentSnackBar();

    final tocUrl = info.tocUrl.isNotEmpty ? info.tocUrl : b.bookUrl;
    final t = await svc.toc(src, tocUrl);
    if (!mounted) return;

    if (t.chapters.isEmpty) {
      messenger.showSnackBar(SnackBar(
        content: Text(t.error.isNotEmpty ? t.error : '没有拿到章节目录'),
        backgroundColor: Colors.redAccent,
      ));
      return;
    }

    // ── 漫画源：走漫画阅读器（图片流），不是文本阅读器 ──────────
    // 之前把图片 URL 用 \n join 后当**文本**丢给 BookReaderPage，
    // 结果屏幕上是一串 URL —— 漫画必须用 MangaReaderPage。
    if (src.isComic) {
      await _openComic(src, b, t.chapters, messenger);
      return;
    }

    // 进阅读器：内容按需加载（点开才拉正文，避免一次拉一堆）
    Get.to(() => BookReaderPage(
          title: b.name,
          chapters: t.chapters
              .map((c) => (name: c.name, url: c.url))
              .toList(),
          loadContent: (i) async {
            if (i < 0 || i >= t.chapters.length) return '';
            final r = await svc.chapterContent(src, t.chapters[i].url);
            if (r.content == null) return '（加载失败：${r.error}）';
            return r.content!.content;
          },
        ));
  }

  /// 打开漫画：先把第一话拉出来当初始内容，之后翻话在阅读器内拉。
  Future<void> _openComic(
    BookSource src,
    BookItem b,
    List<BookChapter> chapters,
    ScaffoldMessengerState messenger,
  ) async {
    final first = chapters.isNotEmpty ? chapters.first : null;
    if (first == null) {
      messenger.showSnackBar(const SnackBar(content: Text('没有可读的章节')));
      return;
    }

    messenger.showSnackBar(SnackBar(
      content: Text('正在加载第 1 话…'),
      duration: const Duration(seconds: 20),
    ));
    final r = await svc.chapterContent(src, first.url);
    if (!mounted) return;
    messenger.hideCurrentSnackBar();

    if (r.content == null || !r.content!.isImages) {
      messenger.showSnackBar(SnackBar(
        content: Text(r.error.isNotEmpty
            ? r.error
            : '这一话没有取到图片（该源可能需要浏览器内核）'),
        backgroundColor: Colors.redAccent,
        duration: const Duration(seconds: 6),
      ));
      return;
    }

    final images = r.content!.images;
    final index = 0.obs;

    // 用一个可变的 index 承载"当前第几话"，翻话时重新拉图
    Get.to(() => _ComicHost(
          title: b.name,
          chapters: chapters,
          src: src,
          initialImages: images,
          initialIndex: index.value,
        ));
  }
}

/// 漫画阅读的宿主：负责"翻话时重新拉图"，再把结果交给 MangaReaderPage。
///
/// 为什么不直接在 MangaReaderPage 里拉：那样阅读器就得知道 BookService 和
/// BookSource，耦合太紧。这里做一层薄适配，阅读器保持纯展示。
class _ComicHost extends StatefulWidget {
  const _ComicHost({
    required this.title,
    required this.chapters,
    required this.src,
    required this.initialImages,
    required this.initialIndex,
  });

  final String title;
  final List<BookChapter> chapters;
  final BookSource src;
  final List<String> initialImages;
  final int initialIndex;

  @override
  State<_ComicHost> createState() => _ComicHostState();
}

class _ComicHostState extends State<_ComicHost> {
  late int _index = widget.initialIndex;
  late List<String> _images = widget.initialImages;
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        MangaReaderPage(
          title: widget.title,
          chapterName: widget.chapters[_index].name,
          images: _images,
          onPrevChapter: _index > 0 ? () => _go(_index - 1) : null,
          onNextChapter:
              _index < widget.chapters.length - 1 ? () => _go(_index + 1) : null,
        ),
        if (_loading)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.5),
              child: Center(
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: AppTheme.accentColor),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _go(int target) async {
    if (target < 0 || target >= widget.chapters.length) return;
    setState(() => _loading = true);
    final r =
        await BookService.instance.chapterContent(widget.src, widget.chapters[target].url);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r.content != null && r.content!.isImages) {
        _index = target;
        _images = r.content!.images;
      }
    });
    if (r.content == null || !r.content!.isImages) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(r.error.isNotEmpty ? r.error : '这一话没有取到图片'),
        backgroundColor: Colors.redAccent,
      ));
    }
  }
}
