import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/book_source.dart';
import '../models/bookshelf.dart';
import '../services/book_source_service.dart';
import '../services/book_source_download_service.dart';
import '../services/browse_history_service.dart';
// 收藏服务：本文件原来导入的是**从未被使用**的 bookshelf_service ✗
//（analyze 一直在报 unused_import ✓）—— 那正是"收藏接线写到一半"留下的痕迹 ✓。
// 真正需要的是收藏服务（见下方 `_toggleFavorite` ✓）
import '../services/book_favorites_service.dart';
// `Book.fromJson`（收藏用 ✓）—— 上面换成收藏服务后，这个模型也必须一起导入 ✓
import '../models/book.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_bookshelf_dialog.dart';
import '../widgets/theme_background_animation.dart';
import 'book_source_reader_page.dart';
import 'book_source_switch_page.dart';
import '../../common/theme.dart';

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
  bool _descExpanded = false;
  bool _showAllChapters = false; // 目录列表默认只显示前 8 章（参考图 IMG_8481）

  /// 详情接口补到的字段（封面/简介/作者），优先于搜索结果里的
  Map<String, dynamic> _info = const {};

  @override
  void initState() {
    super.initState();
    // ✅ 进详情即记浏览历史（足迹页 Book tab 可见）✓ —— 与漫画/图书搜索页
    //   进详情 `recordComic/recordBook` 的口径一致 ✓；服务本身去重置顶 ✓
    BrowseHistoryService().recordBook(Book.fromJson({
      'id': 'book-${widget.result.bookUrl}',
      'hash': '',
      'title': widget.result.name,
      'author': widget.result.author,
      'cover': widget.result.coverUrl,
      'sourceId': widget.result.source.id,
      'sourceName': widget.result.source.name,
      'bookUrl': widget.result.bookUrl,
    }));
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
      // ✅ 与图书 / 漫画详情页统一：透明 AppBar（标题=书名）+ 主题动态背景
      //（原来是不透明 AppBar 直接盖住背景 ✗，标题还写死「书籍详情」✗）
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(_name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: AppTheme.fontHeadline, color: _titleColor)),
        actions: [
          IconButton(
            tooltip: '换源',
            icon: Icon(Icons.swap_horiz_rounded, color: _titleColor),
            onPressed: _chapters.isEmpty ? null : _changeSource,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const RepaintBoundary(child: ThemeBackgroundAnimation()),
          Column(
            children: [
              _header(),
              const Divider(height: 1),
              Expanded(child: _tocArea()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final intro = _intro.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 左封面 + 右信息 ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 封面挪到左侧（与漫画详情页一致）
              _coverBox(),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: AppTheme.fontTitle2,
                            fontWeight: FontWeight.w700,
                            color: _titleColor)),
                    if (_author.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('$_author 著',
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: JellyTheme.textSecondary)),
                    ],
                    const SizedBox(height: 6),
                    Text('来源：${_result.source.name}',
                        style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            color: JellyTheme.textSecondary)),
                    if (_wordCountText.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(_wordCountText,
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: JellyTheme.textSecondary)),
                    ],
                    if (_chapters.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: JellyTheme.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text('最新章节',
                                style: TextStyle(
                                    fontSize: AppTheme.fontCaption,
                                    color: JellyTheme.primary,
                                    fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _chapters.last.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: AppTheme.fontSubhead,
                                  color: _titleColor,
                                  fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

            ],
          ),
          // ── 四按钮：收藏 / 加入书架 / 阅读 / 下载 ──
          const SizedBox(height: 14),
          Row(
            children: [
              _actionCapsule(Icons.favorite_border_rounded, '收藏', _toggleFavorite),
              const SizedBox(width: 8),
              _actionCapsule(Icons.library_add_rounded, '加入书架', _addToBookshelf),
              const SizedBox(width: 8),
              // ✅ 「阅读」→「在线阅读」并用主色突出（与图书详情页的在线阅读入口一致）
              _actionCapsule(Icons.play_arrow_rounded, '在线阅读',
                  _chapters.isEmpty ? null : () => _openReader(0),
                  highlight: true),
              const SizedBox(width: 8),
              _actionCapsule(Icons.download_for_offline_rounded, '下载',
                  _chapters.isEmpty ? null : _downloadBook),
            ],
          ),
          // ── 简介板块 ──
          if (intro.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('简介',
                style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w700,
                    color: _titleColor)),
            const SizedBox(height: 6),
            Text(
              intro,
              maxLines: _descExpanded ? null : 4,
              overflow: _descExpanded ? null : TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  height: 1.55,
                  color: JellyTheme.textSecondary),
            ),
            if (intro.length > 90 || intro.contains('\n'))
              GestureDetector(
                onTap: () => setState(() => _descExpanded = !_descExpanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    _descExpanded ? '收起' : '展开全部',
                    style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        color: JellyTheme.primary,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// 封面（110×147，圆角 12）—— 与漫画详情页封面同尺寸。
  /// 原来封面在信息行的**右侧**、只有 84×112 ✗；抽成方法是为了挪到左侧 ✓。
  Widget _coverBox() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 110,
        height: 147,
        child: _cover.isEmpty
            ? Container(
                color: JellyTheme.primary.withValues(alpha: 0.1),
                child: Icon(Icons.menu_book_rounded,
                    size: 40, color: JellyTheme.primary),
              )
            : CachedNetworkImage(
                imageUrl: _cover,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Container(
                  color: JellyTheme.primary.withValues(alpha: 0.1),
                  child: Icon(Icons.menu_book_rounded,
                      size: 40, color: JellyTheme.primary),
                ),
              ),
      ),
    );
  }

  String get _wordCountText {
    final raw = (_info['wordCount'] ?? '').toString();
    if (raw.isEmpty) return '';
    final n = int.tryParse(raw.replaceAll(RegExp(r'\D'), '')) ?? 0;
    if (n <= 0) return '${raw}字';
    if (n >= 10000) {
      return '${(n / 10000).toStringAsFixed(n % 10000 == 0 ? 0 : 1)}万字';
    }
    return '$n字';
  }

  /// 四按钮之一（参考图 IMG_8481 深灰胶囊）。
  /// [highlight] = true 用主色实心（如「在线阅读」），与图书详情页的入口一致。
  Widget _actionCapsule(IconData icon, String label, VoidCallback? onTap,
      {bool highlight = false}) {
    final fg = highlight ? Colors.white : _titleColor.withValues(alpha: 0.85);
    return Expanded(
      child: Material(
        color: highlight
            ? JellyTheme.primary
            : (_isDark
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.black.withValues(alpha: 0.06)),
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 4),
                Text(label,
                    style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: fg,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _toggleFavorite() {
    // 🔴 原来是**假按钮** ✗：只 `setState(() {})` + 弹「已收藏《书名》」✓，
    // **什么都没写进收藏** ✓，也没有任何状态跟随 ✓ —— 用户以为收藏了、其实没有 ✓。
    // 现在接**真正的**收藏服务 ✓，并让按钮状态跟随实际是否已收藏 ✓
    //（`id` 与"加入书架"用的完全一致 ✓，见下面 :348 附近的 meta ✓）
    final id = 'book-${_result.bookUrl}';
    final svc = BookFavoritesService();
    // ✅ 完整快照：封面 / 源 id / 源名 / 书内 URL 一起存 ✓ ——
    //   收藏页 / 历史页 / 书架点开这本书时据此回到**书源详情页**继续阅读 ✓
    //   （之前只存 id/title/author，点开落到 zlib 详情页 → "收藏了看不了" ✗✓）
    svc.toggle(Book.fromJson({
      'id': id,
      'hash': '',
      'title': _name,
      'author': _author,
      'cover': _cover,
      'sourceId': _result.source.id,
      'sourceName': _result.source.name,
      'bookUrl': _result.bookUrl,
    }));
    setState(() {});
    _toast(svc.isFavorite(id) ? '已收藏《$_name》' : '已取消收藏《$_name》');
  }

  Future<void> _addToBookshelf() async {
    final result = await showBookshelfDialog(
      context,
      itemId: 'book-${_result.bookUrl}',
      type: BookshelfItemType.book,
      title: '加入书架',
      meta: jsonEncode({
        // 书架按 Book 结构解析（id/title/author/cover），
        // 否则书架里书名/封面为空；sourceId/sourceName/bookUrl 为自定义字段（解析忽略）。
        'id': 'book-${_result.bookUrl}',
        'hash': '',
        'title': _name,
        'author': _author,
        'cover': _cover,
        'sourceId': _result.source.id,
        'sourceName': _result.source.name,
        'bookUrl': _result.bookUrl,
      }),
    );
    if (result != null && mounted) {
      _toast(result.isEmpty ? '已从所有书架移除' : '已加入 ${result.length} 个书架');
    }
  }

  /// 下载全书：选择范围后逐章抓正文写入本地 TXT（带进度，可取消）
  Future<void> _downloadBook() async {
    final total = _chapters.length;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('下载全书',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w700,
                      color: _titleColor)),
              const SizedBox(height: 6),
              Text('共 $total 章，保存为本地 TXT，可离线阅读',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: JellyTheme.textSecondary)),
              const SizedBox(height: 14),
              for (final (n, label) in [
                (100, '前 100 章'),
                (200, '前 200 章'),
                (total, '全部（$total 章）'),
              ]) ...[
                if (n <= total) ...[
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: JellyTheme.primary,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => Navigator.pop(ctx, n),
                    child: Text(label,
                        style: const TextStyle(
                            fontSize: AppTheme.fontBody,
                            color: Colors.white)),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
              TextButton(
                onPressed: () => Navigator.pop(ctx, 0),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || picked <= 0 || !mounted) return;

    final count = picked.clamp(1, total);
    var done = 0;
    var cancel = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: _isDark ? JellyTheme.cardDark : Colors.white,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('正在下载《$_name》',
                  style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: _titleColor)),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: count == 0 ? 0 : done / count,
                color: JellyTheme.primary,
                backgroundColor: Colors.white12,
                minHeight: 6,
              ),
              const SizedBox(height: 8),
              Text('$done / $count 章',
                  style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: JellyTheme.textSecondary)),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () {
                  cancel = true;
                  Navigator.pop(ctx);
                },
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );

    final dir = await _bookDownloadDir(_name);
    if (dir == null) {
      if (mounted) _toast('无法创建下载目录');
      return;
    }
    // 🔴 失败计数（原来只有 `done`，而它对失败的章也 +1 ✗，见下面 catch 处 ✓）
    var failedCount = 0;
    for (var i = 0; i < count; i++) {
      if (cancel || !mounted) break;
      try {
        final ch = _chapters[i];
        final r = await BookSourceService.instance
            .content(_result.source, ch.url);
        if (r.ok) {
          final file = File('${dir.path}/${_safeFileName(ch.name)}.txt');
          await file.writeAsString(
              '${ch.name}\n\n${r.content}',
              flush: true);
        } else {
          // 🔴 `r.ok == false`（服务端返回失败/限流/源站报错）时**既不写文件、
          // 也不算失败** ✗ —— 原来这里**没有 else** ✓ → 这类章同样被 `done++`
          // 计入"已下载" ✓，与上面 catch 路径是同一个病 ✓。
          // 现在一并计入 `failedCount` ✓，提示里会如实说明失败章数 ✓
          failedCount++;
          debugPrint('[BookSourceDetail] 章节返回失败（第 ${i + 1} 章，'
              '未写入文件）');
        }
      } catch (e) {
        // 🔴 原来是 `catch (_) {}` ✗ —— **失败被完全吞掉** ✓，而紧跟的 `done++`
        // 是**无条件**执行的 ✗ → **下载失败的章也被算成"已下载"** ✓；
        // 最坏情况：全书 50 章全部失败，提示仍写「下载完成：50 / 50 章」✓
        //（而 `dir` 里一个 txt 都没有 ✓）。这里改为**记录并计数** ✓，
        // 提示文案据此如实说明 ✓（`r.ok == false` 的情况也算失败 ✓）
        failedCount++;
        debugPrint('[BookSourceDetail] 章节下载失败（第 ${i + 1} 章）: $e');
      }
      done++;
    }
    if (!mounted) return;
    if (cancel) {
      _toast('已取消，已下载 $done 章');
    } else {
      // ✅ 失败章数**如实报出来** ✓（原来无论失败多少都只说"下载完成 N/N"✗）
      _toast(failedCount == 0
          ? '下载完成：$done / $count 章，保存于 ${dir.path}'
          : '下载完成：$done / $count 章（其中 $failedCount 章失败），'
              '保存于 ${dir.path}');
      // ✅ 写入书源下载索引（下载记录页「书源下载」区块可见）✓
      await BookSourceDownloadService.instance.add(
        BookSourceDownloadRecord(
          sourceId: _result.source.id,
          sourceName: _result.source.name,
          bookUrl: _result.bookUrl,
          title: _name,
          author: _author,
          cover: _cover,
          chapterCount: done,
          dir: dir.path,
          time: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
  }

  Future<Directory?> _bookDownloadDir(String name) async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/书源下载/$name');
      await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  String _safeFileName(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

  Widget _tocArea() {
    if (_loadingToc) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: JellyTheme.primary),
            const SizedBox(height: 14),
            Text('正在获取目录...',
                style: TextStyle(fontSize: AppTheme.fontSubhead, color: JellyTheme.textSecondary)),
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
                      TextStyle(fontSize: AppTheme.fontSubhead, color: JellyTheme.textSecondary)),
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
    final visibleCount = _showAllChapters
        ? _chapters.length
        : _chapters.length.clamp(0, 8);
    final hasMore = _chapters.length > 8;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 90),
      children: [
        // ── 章节目录 · 共N章 ──
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              Text('章节目录',
                  style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.bold,
                      color: _titleColor)),
              const SizedBox(width: 8),
              Text('共 ${_chapters.length} 章',
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: JellyTheme.textSecondary)),
            ],
          ),
        ),
        ...List.generate(visibleCount, (i) {
          final ch = _chapters[i];
          return ListTile(
            dense: true,
            title: Text(ch.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppTheme.fontBody, color: _titleColor)),
            onTap: () => _openReader(i),
          );
        }),
        if (hasMore)
          Center(
            child: TextButton.icon(
              onPressed: () =>
                  setState(() => _showAllChapters = !_showAllChapters),
              icon: Icon(
                _showAllChapters
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 18,
              ),
              label: Text(_showAllChapters
                  ? '收起'
                  : '显示全部（共 ${_chapters.length} 章）'),
            ),
          ),
      ],
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
          // ✅ 把封面**传下去** ✓ —— 修掉"全屏听书页永远是占位图" ✗：
          //   阅读器原来只读 `source.raw['coverUrl']` ✓，而那个键**从不被写入**
          //   （内置 Legado 源顶层没有 ✓、config 源的封面在 search_cover_dom 里 ✓）。
          //   详情页手里就有封面 ✓（`BookSourceResult.coverUrl` ✓）→ 直接传 ✓
          coverUrl: _result.coverUrl,
        ),
      ),
    );
  }

  /// 换源：进入换源页，用书名去其它已启用源再搜一次（IMG_8482/8483）。
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

    final picked = await Navigator.push<BookSourceResult>(
      context,
      MaterialPageRoute(
        builder: (_) => BookSourceSwitchPage(
          bookName: name,
          author: _author,
          sources: others,
          currentSource: _result.source,
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

// ⚠️ **这个文件级 `unawaited` 不能删** ✗ —— 我曾按"dart:async 已经有它"的推断
// 删过一次 ✓，结果全仓立刻 **error=2** ✗：
//   `book_source_search_page.dart:259 / :291` 用了 `unawaited(...)` ✓，
//   而它**没有**引入 `dart:async` 的版本 ✗ —— 它是靠 **import 本文件**
//   （页面间 import ✓）**传递**拿到这个函数的 ✓✓。
// 教训 ✓：判断"某函数是不是 dart:async 的"**不能只看调用点** ✗，
//   要看那个调用点所在文件**到底 import 了什么** ✓ —— 否则会删掉别人的依赖 ✓。
/// 显式忽略 future（用于"关掉对话框"这种不需要结果的地方）
void unawaited(Future<void> f) {
  f.catchError((_) {});
}
