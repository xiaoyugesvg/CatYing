import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/reading/models/book_source.dart';
import 'package:tvbox/reading/models/bookshelf.dart';
import 'package:tvbox/reading/utils/html_text.dart';
import 'package:tvbox/reading/services/book_source_service.dart';
import 'package:tvbox/reading/services/chapter_alignment.dart';
import 'package:tvbox/reading/services/book_source_download_service.dart';
import 'package:tvbox/reading/services/browse_history_service.dart';
// 收藏服务：本文件原来导入的是**从未被使用**的 bookshelf_service ✗
//（analyze 一直在报 unused_import ✓）—— 那正是"收藏接线写到一半"留下的痕迹 ✓。
// 真正需要的是收藏服务（见下方 `_toggleFavorite` ✓）
import 'package:tvbox/reading/services/book_favorites_service.dart';
import 'package:tvbox/reading/services/bookshelf_service.dart';
// `Book.fromJson`（收藏用 ✓）—— 上面换成收藏服务后，这个模型也必须一起导入 ✓
import 'package:tvbox/reading/models/book.dart';
import 'package:tvbox/reading/theme/jelly_theme.dart';
import 'package:tvbox/reading/widgets/jelly_bookshelf_dialog.dart';
import 'package:tvbox/reading/widgets/theme_background_animation.dart';
import 'package:tvbox/reading/pages/book_source_reader_page.dart';
import 'package:tvbox/reading/pages/book_source_switch_page.dart';
import 'package:tvbox/common/theme.dart';

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
  bool _descending = false; // 章节目录排序：false=正序（第1章在前），true=倒序（最新在前）
  bool _isFavorite = false; // 是否已收藏（AppBar 胶囊 / 动作行图标据此切换）

  /// 详情接口补到的字段（封面/简介/作者），优先于搜索结果里的
  Map<String, dynamic> _info = const {};

  /// 详情页数据（详情 + 目录）**本次拉取成功的时间**。
  /// 书源规则大多不提供 `updateTime`（实测 20 个内置源里 0 个声明
  /// `ruleBookInfo.updateTime`）⇒ 头部「更新时间」用源站时间，取不到时
  /// 回退到这个真实拉取时间（不是编造：就是本页数据的更新时间）。
  DateTime? _infoLoadedAt;

  @override
  void initState() {
    super.initState();
    // ✅ 进详情即记浏览历史（足迹页 Book tab 可见）✓ —— 与漫画/图书搜索页
    //   进详情 `recordComic/recordBook` 的口径一致 ✓；服务本身去重置顶 ✓
    BrowseHistoryService().recordBook(
      Book.fromJson({
        'id': 'book-${widget.result.bookUrl}',
        'hash': '',
        'title': widget.result.name,
        'author': widget.result.author,
        'cover': widget.result.coverUrl,
        'sourceId': widget.result.source.id,
        'sourceName': widget.result.source.name,
        'bookUrl': widget.result.bookUrl,
      }),
    );
    // 进页先查一次收藏状态（收藏服务在 main.dart 启动时已 init）
    _isFavorite = BookFavoritesService().isFavorite(
      'book-${widget.result.bookUrl}',
    );
    _load();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _titleColor => _isDark ? Colors.white : JellyTheme.textPrimaryLight;

  /// 卡片底色（简介 / 目录两项共用）
  Color get _cardColor => _isDark ? JellyTheme.cardDark : JellyTheme.cardLight;

  /// 极淡的细分隔线（头部与目录行共用，深/浅都"刚好看得见"）
  Color get _hairline => _isDark
      ? Colors.white.withValues(alpha: 0.06)
      : Colors.black.withValues(alpha: 0.05);

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// 拉详情 + 目录。
  ///
  /// `force=true`（重试按钮 / 下拉刷新）→ **跳过 5 分钟缓存**重新请求：
  /// 否则站点抽风返回一次空目录后，重试拿的还是缓存里的空结果，
  /// 看起来就是「点了没反应」（用户 2026-10-21 反馈）。
  Future<void> _load({bool force = false}) async {
    setState(() {
      _loadingToc = true;
      _error = null;
    });
    final r = _result;
    try {
      // 1) 详情：补全封面/简介/作者，并拿到 tocUrl
      final info = await BookSourceService.instance.bookInfoChecked(
        r.source,
        r.bookUrl,
        force: force,
      ).then((v) => v.info);
      if (!mounted) return;
      if (info != null) _info = info;
      _infoLoadedAt = DateTime.now();

      // 2) 目录：详情里带的 tocUrl 优先（有些站详情页和目录页不同）
      final tocUrl = (_info['tocUrl'] ?? '').toString().trim();
      final t = await BookSourceService.instance.toc(
        r.source,
        tocUrl.isEmpty ? r.bookUrl : tocUrl,
        force: force,
      );
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

  // 详情接口返回的 Map 里这几个键恒存在但值可能是空字符串，
  // 直接用 ?? 不会回退（空串非 null）→ 需手动判空回退到搜索结果带过来的初值，
  // 否则加载完目录后封面/书名/作者/简介会"消失"。
  //
  // 回退值与源站值**都过一遍 [stripHtmlText]** —— 搜索阶段拿到的名字同样可能带
  // `<br>`（清洗逻辑已提到 `utils/html_text.dart`，与搜索结果共用一份）。
  String _pick(String key, String fallback, {bool singleLine = false}) {
    final v = _info[key]?.toString().trim();
    final s = (v != null && v.isNotEmpty) ? v : fallback;
    return stripHtmlText(s, singleLine: singleLine);
  }

  // 详情接口的原始字段同样要清掉站名 / 导航词 / 装饰符号（用户 2026-10-18）。
  String get _name => cleanSourceTitle(
    _pick('name', _result.name, singleLine: true),
  );
  String get _author => cleanSourceTitle(
    _pick('author', _result.author, singleLine: true),
  );
  String get _cover => _pick('coverUrl', _result.coverUrl);
  String get _intro => cleanIntroText(_pick('intro', _result.intro));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _isDark
          ? JellyTheme.backgroundDark
          : JellyTheme.backgroundLight,
      // ✅ 透明 AppBar + 主题动态背景；标题居中：默认「书籍详情」，
      //   已收藏时居中显示可点的收藏胶囊（点=取消收藏）
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: _isFavorite
            ? _favPill()
            : Text(
                '书籍详情',
                style: TextStyle(
                  fontSize: AppTheme.fontTitle3,
                  color: _titleColor,
                ),
              ),
        actions: [
          // 用户 2026-10-22：右上角两个按钮 —— 刷新（强制越过缓存）+ 换源
          IconButton(
            tooltip: '刷新',
            icon: Icon(Icons.refresh_rounded, color: _titleColor),
            onPressed: _loadingToc ? null : () => _load(force: true),
          ),
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
          // ⚠️ 用户 2026-10-15：「简介点『展开全部』后整体滑不动、滑不到下面，
          //   也够不着『收起』」——
          //   原来是 `Column(头部, Expanded(目录))`：**头部不参与滚动**，
          //   简介一展开就把头部撑得比屏幕还高 ⇒ Column 溢出、目录区被挤成
          //   0 高，下半页根本滚不到 ✗。
          //   ⇒ 改成**整页一个滚动视图**：头部与目录都进 slivers，
          //     谁长都能滚，`收起` 自然也够得着 ✓。
          RefreshIndicator(
            color: JellyTheme.primary,
            // 下拉 = 强制刷新：跳过 5 分钟缓存重新拉详情+目录
            onRefresh: () => _load(force: true),
            child: CustomScrollView(
              // 内容不足一屏（目录失败/为空）时也要能下拉
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _header()),
                ..._tocSlivers(),
              ],
            ),
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
          // ── 左侧文字信息 + 右侧封面 ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle2,
                        fontWeight: FontWeight.w700,
                        color: _titleColor,
                      ),
                    ),
                    if (_author.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            Icons.person_outline_rounded,
                            size: 14,
                            color: JellyTheme.textSecondary,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '$_author 著',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppTheme.fontSubhead,
                                color: JellyTheme.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.schedule_rounded,
                          size: 14,
                          color: JellyTheme.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            '来源：${_result.source.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: JellyTheme.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_metaChips.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: _metaChips.map(_metaChip).toList(),
                      ),
                    ],
                    // ── 最新章节 / 更新时间并入信息列 ──
                    // 用户 2026-10-13：「最新章节不要单独一行，要放在（来源下方）
                    // 这个位置，还有更新时间也要有」⇒ 原来是「分隔线 + 最新章节
                    // 标签 + 可点章节行」独占一段，现在收进信息列与「来源」同款。
                    // 点「最新章节」仍可直接跳到最后一章（保留原来的跳转能力）。
                    if (_latestChapterName.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _metaLine(
                        Icons.auto_stories_outlined,
                        '最新章节：',
                        _latestChapterName,
                        onTap: _chapters.isEmpty
                            ? null
                            : () => _openReader(_chapters.length - 1),
                      ),
                    ],
                    if (_updateTimeText.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _metaLine(
                        Icons.update_rounded,
                        '更新时间：',
                        _updateTimeText,
                      ),
                    ],
                    if (_wordCountText.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        _wordCountText,
                        style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          color: JellyTheme.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _coverBox(),
            ],
          ),
          // ── 动作行：收藏 / 书架 / 阅读 / 下载（圆角卡 + 竖细分隔线，对齐参考图）──
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: _cardColor,
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                _actionItem(
                  _isFavorite ? Icons.favorite : Icons.favorite_border_rounded,
                  _isFavorite ? '已收藏' : '收藏',
                  _toggleFavorite,
                  color: _isFavorite ? Colors.pinkAccent : null,
                ),
                _actionDivider(),
                // 书架：跟真实"是否已加入书架"联动（蓝紫色，与漫画详情页一致）
                ListenableBuilder(
                  listenable: BookshelfService(),
                  builder: (context, _) {
                    final inShelf = BookshelfService()
                        .getBookshelvesForItem(
                          'book-${_result.bookUrl}',
                          BookshelfItemType.book,
                        )
                        .isNotEmpty;
                    return _actionItem(
                      inShelf
                          ? Icons.library_books_rounded
                          : Icons.library_add_rounded,
                      inShelf ? '已加书架' : '加入书架',
                      _addToBookshelf,
                      color: inShelf ? const Color(0xFF7C8CFF) : null,
                    );
                  },
                ),
                _actionDivider(),
                _actionItem(
                  Icons.menu_book_rounded,
                  '阅读',
                  _chapters.isEmpty ? null : () => _openReader(0),
                ),
                _actionDivider(),
                _actionItem(
                  Icons.download_for_offline_rounded,
                  '下载',
                  _chapters.isEmpty ? null : _downloadBook,
                ),
              ],
            ),
          ),
          // ── 简介 ──
          if (intro.isNotEmpty) ...[
            const SizedBox(height: 18),
            _introSection(intro),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// AppBar 居中收藏胶囊（已收藏时显示）：粉色实心爱心 + 「已收藏」+ ×，
  /// 点它（或 ×）= 取消收藏（走 _toggleFavorite）。
  Widget _favPill() {
    return GestureDetector(
      onTap: _toggleFavorite,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.pinkAccent.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.favorite, size: 15, color: Colors.pinkAccent),
            SizedBox(width: 5),
            Text(
              '已收藏',
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                color: Colors.pinkAccent,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: 5),
            Icon(Icons.close_rounded, size: 14, color: Colors.pinkAccent),
          ],
        ),
      ),
    );
  }

  /// 最新章节名：优先用详情页 `ruleBookInfo.lastChapter` 的结果，
  /// 取不到再回退到已拉取的目录最后一章（都是真实数据，不编造）。
  String get _latestChapterName {
    // 章节名也可能被源站塞进 HTML 片段 → 同样过一遍清洗（单行）
    final fromInfo = stripHtmlText(
      (_info['lastChapter'] ?? '').toString().trim(),
      singleLine: true,
    );
    if (fromInfo.isNotEmpty) return fromInfo;
    if (_chapters.isNotEmpty) {
      return stripHtmlText(_chapters.last.name, singleLine: true);
    }
    return '';
  }

  /// 更新时间：优先用源站规则给的 `updateTime`（引擎透传），
  /// 没有就回退到本次详情/目录的拉取时间（见 [_infoLoadedAt] 注释）。
  String get _updateTimeText {
    final src = _infoFirst(['updateTime', 'updatedAt', 'lastUpdate']);
    if (src.isNotEmpty) return src;
    final at = _infoLoadedAt;
    if (at == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return sameDay
        ? '今天 ${two(at.hour)}:${two(at.minute)}'
        : '${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
  }

  /// 小元信息胶囊文字（分数 / 连载状态 / 分类 / 更新时间）。
  /// 优先取 [_info] 里的键，取不到该项就整体不显示（绝不编造）。
  List<String> get _metaChips {
    final chips = <String>[];
    final score = _infoFirst(['score', 'rating']);
    if (score.isNotEmpty) chips.add(score);
    final status = _infoFirst(['status', 'serialStatus']);
    if (status.isNotEmpty) chips.add(status);
    final category = _infoFirst(['category', 'categoryName']);
    if (category.isNotEmpty) {
      chips.add(category);
    } else if (_result.kind.trim().isNotEmpty) {
      // 分类缺失时回退到搜索结果里的 kind（真实数据，非编造）
      chips.add(_result.kind.trim());
    }
    final updated = _infoFirst(['updateTime', 'updatedAt', 'lastUpdate']);
    if (updated.isNotEmpty) chips.add(updated);
    return chips;
  }

  /// 按顺序取 [_info] 中第一个非空的键值
  String _infoFirst(List<String> keys) {
    for (final k in keys) {
      final v = _info[k]?.toString().trim();
      // 单行字段（更新时间 / 分数 / 状态 / 分类）→ 一样要剥 HTML
      if (v != null && v.isNotEmpty) return stripHtmlText(v, singleLine: true);
    }
    return '';
  }

  Widget _metaChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _isDark
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppTheme.fontCaption,
          color: JellyTheme.textSecondary,
        ),
      ),
    );
  }

  /// 头部信息列里的一行元信息（图标 + 「标签：值」），与「来源」行同款；
  /// 用于把「最新章节 / 更新时间」并进信息列（不再单独占一行）。
  Widget _metaLine(
    IconData icon,
    String label,
    String value, {
    VoidCallback? onTap,
  }) {
    final row = Row(
      children: [
        Icon(icon, size: 14, color: JellyTheme.textSecondary),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            '$label$value',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppTheme.fontSubhead,
              color: JellyTheme.textSecondary,
            ),
          ),
        ),
      ],
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: row,
    );
  }

  /// 动作行里的竖细分隔线（居中、不顶满高度，对齐参考图）
  Widget _actionDivider() {
    return Container(
      width: 1,
      height: 26,
      color: _isDark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.black.withValues(alpha: 0.08),
    );
  }

  /// 动作行之一：图标在上、文字在下，垂直居中，等宽（无胶囊底色）。
  Widget _actionItem(
    IconData icon,
    String label,
    VoidCallback? onTap, {
    Color? color,
  }) {
    final enabled = onTap != null;
    final c = enabled
        ? (color ?? _titleColor).withValues(alpha: 0.9)
        : JellyTheme.textSecondary.withValues(alpha: 0.4);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: c),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: c,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 简介区块：区块标题 + 圆角卡片（内容简介 / 展开收起）
  ///
  /// ⚠️ 用户 2026-10-15：「更新时间放在内容简介前面」——
  ///   原来卡片里第一块就是「🕐 更新时间」，视觉上成了**简介内容的一部分** ✗；
  ///   而页头信息列里本来就有一行「更新时间：」（见 [_header]，
  ///   取的是 `updateTime/updatedAt/lastUpdate` + 拉取时间兜底，覆盖面更大）。
  ///   ⇒ 卡片里这份**删掉**（它本来就是重复的），"更新时间"从此只出现在
  ///     简介**前面**的那一行 ✓。
  Widget _introSection(String intro) {
    final long = intro.length > 90 || intro.contains('\n');
    final subtitleStyle = TextStyle(
      fontSize: AppTheme.fontSubhead,
      fontWeight: FontWeight.w600,
      color: _titleColor.withValues(alpha: 0.72),
    );
    final valueStyle = TextStyle(
      fontSize: AppTheme.fontFootnote,
      height: 1.55,
      color: JellyTheme.textSecondary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.article_outlined,
              size: 16,
              color: JellyTheme.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              '简介',
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w700,
                color: _titleColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _cardColor,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('▤ 内容简介：', style: subtitleStyle),
              const SizedBox(height: 4),
              Text(
                intro,
                maxLines: _descExpanded ? null : 4,
                overflow: _descExpanded ? null : TextOverflow.ellipsis,
                style: valueStyle,
              ),
              if (long)
                Align(
                  alignment: Alignment.centerRight,
                  child: GestureDetector(
                    onTap: () => setState(() => _descExpanded = !_descExpanded),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _descExpanded ? '收起' : '展开全部',
                        style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          color: JellyTheme.primary,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                          decorationColor: JellyTheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 目录卡片头部的小图标按钮（刷新 / 排序）
  Widget _tocIcon(IconData icon, String tooltip, VoidCallback onTap) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      iconSize: 20,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(),
      visualDensity: VisualDensity.compact,
      color: _titleColor.withValues(alpha: 0.8),
      icon: Icon(icon),
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
                child: Icon(
                  Icons.menu_book_rounded,
                  size: 40,
                  color: JellyTheme.primary,
                ),
              )
            : CachedNetworkImage(
                imageUrl: _cover,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: JellyTheme.primary.withValues(alpha: 0.1),
                  child: Icon(
                    Icons.menu_book_rounded,
                    size: 40,
                    color: JellyTheme.primary,
                  ),
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
    svc.toggle(
      Book.fromJson({
        'id': id,
        'hash': '',
        'title': _name,
        'author': _author,
        'cover': _cover,
        'sourceId': _result.source.id,
        'sourceName': _result.source.name,
        'bookUrl': _result.bookUrl,
      }),
    );
    setState(() {
      _isFavorite = svc.isFavorite(id);
    });
    _toast(_isFavorite ? '已收藏《$_name》' : '已取消收藏《$_name》');
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
              Text(
                '下载全书',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w700,
                  color: _titleColor,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '共 $total 章，保存为本地 TXT，可离线阅读',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  color: JellyTheme.textSecondary,
                ),
              ),
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
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: AppTheme.fontBody,
                        color: Colors.white,
                      ),
                    ),
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
              Text(
                '正在下载《$_name》',
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  fontWeight: FontWeight.w600,
                  color: _titleColor,
                ),
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: count == 0 ? 0 : done / count,
                color: JellyTheme.primary,
                backgroundColor: Colors.white12,
                minHeight: 6,
              ),
              const SizedBox(height: 8),
              Text(
                '$done / $count 章',
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  color: JellyTheme.textSecondary,
                ),
              ),
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
        final r = await BookSourceService.instance.content(
          _result.source,
          ch.url,
        );
        if (r.ok) {
          final file = File('${dir.path}/${_safeFileName(ch.name)}.txt');
          await file.writeAsString('${ch.name}\n\n${r.content}', flush: true);
        } else {
          // 🔴 `r.ok == false`（服务端返回失败/限流/源站报错）时**既不写文件、
          // 也不算失败** ✗ —— 原来这里**没有 else** ✓ → 这类章同样被 `done++`
          // 计入"已下载" ✓，与上面 catch 路径是同一个病 ✓。
          // 现在一并计入 `failedCount` ✓，提示里会如实说明失败章数 ✓
          failedCount++;
          debugPrint(
            '[BookSourceDetail] 章节返回失败（第 ${i + 1} 章，'
            '未写入文件）',
          );
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
      _toast(
        failedCount == 0
            ? '下载完成：$done / $count 章，保存于 ${dir.path}'
            : '下载完成：$done / $count 章（其中 $failedCount 章失败），'
                  '保存于 ${dir.path}',
      );
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

  /// 目录区（slivers 形态，见 build 里的说明）。
  List<Widget> _tocSlivers() {
    if (_loadingToc) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: JellyTheme.primary),
                const SizedBox(height: 14),
                Text(
                  '正在获取目录...',
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    if (_error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    size: 48,
                    color: Colors.orangeAccent,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: JellyTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: () => _load(force: true),
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
          ),
        ),
      ];
    }
    final visibleCount = _showAllChapters
        ? _chapters.length
        : _chapters.length.clamp(0, 8);
    final hasMore = _chapters.length > 8;
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        sliver: SliverToBoxAdapter(
          child: Container(
            decoration: BoxDecoration(
              color: _cardColor,
              borderRadius: BorderRadius.circular(14),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                // ── 头部行：章节目录 + 共N章 + 刷新/排序 ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                  child: Row(
                    children: [
                      Text(
                        '章节目录',
                        style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w700,
                          color: _titleColor,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: JellyTheme.textSecondary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '共 ${_chapters.length} 章',
                        style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: JellyTheme.textSecondary,
                        ),
                      ),
                      const Spacer(),
                      _tocIcon(Icons.refresh_rounded, '刷新', () => _load(force: true)),
                      _tocIcon(
                        Icons.swap_vert_rounded,
                        _descending ? '倒序' : '正序',
                        () => setState(() => _descending = !_descending),
                      ),
                    ],
                  ),
                ),
                // ── 章节列表（行间一条极淡的细分隔线）──
                ...List.generate(visibleCount, (i) {
                  // 倒序时把显示序号映射回 _chapters 的真实下标，保证点哪章开哪章
                  final real = _descending ? _chapters.length - 1 - i : i;
                  final ch = _chapters[real];
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (i != 0)
                        Divider(height: 1, thickness: 1, color: _hairline),
                      InkWell(
                        onTap: () => _openReader(real),
                        child: SizedBox(
                          width: double.infinity,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            child: Text(
                              ch.name,
                              // 章节名**左对齐**（与阅读器里的目录弹层一致 ✓）：
                              // 原来这里居中，和阅读器目录两处观感不一致
                              //（用户 2026-10-13：「书源目录不是说这个不居中吗？」）
                              textAlign: TextAlign.start,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppTheme.fontBody,
                                color: _titleColor,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }),
                if (hasMore)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Center(
                      child: TextButton.icon(
                        onPressed: () => setState(
                          () => _showAllChapters = !_showAllChapters,
                        ),
                        icon: Icon(
                          _showAllChapters
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 18,
                        ),
                        label: Text(
                          _showAllChapters
                              ? '收起'
                              : '显示全部（共 ${_chapters.length} 章）',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  void _openReader(int index) {
    Navigator.push(
      context,
      // CupertinoPageRoute ⇒ 带 iOS 左边缘右滑返回（详见书架页同处注释）
      CupertinoPageRoute(
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
    // 漫画源不参与小说换源（用户 2026-10-18：书源 / 漫画源分开）
    final others = store.enabled
        .where((s) => s.id != _result.source.id && !s.isComicSource)
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

    // 换源前先记住旧目录与旧进度：换到新源后按「章节标题 + 序号比例」对齐，
    // 否则读者换源后会被打回第 1 章。
    final oldSourceId = _result.source.id;
    final oldTitles = _chapters.map((e) => e.name).toList(growable: false);
    final oldProgress = await _readSavedChapter(oldSourceId, name);

    setState(() {
      _current = picked;
      _info = const {};
      _chapters = const [];
    });
    await _load();
    if (!mounted) return;

    // 对齐并写进「新源」的进度键：阅读器 initialIndex=0 时会自动恢复到该章。
    if (oldProgress != null &&
        oldProgress > 0 &&
        oldProgress < oldTitles.length &&
        _chapters.isNotEmpty) {
      final a = ChapterAlignment.align(
        oldTitles: oldTitles,
        oldIndex: oldProgress,
        newTitles: _chapters.map((e) => e.name).toList(growable: false),
      );
      if (a != null && a.index > 0 && a.index < _chapters.length) {
        try {
          final p = await SharedPreferences.getInstance();
          await p.setInt(
            ChapterAlignment.progressKey(picked.source.id, _name),
            a.index,
          );
        } catch (_) {
          /* 写进度失败不影响换源本身 */
        }
        _toast(
          a.matchedByTitle
              ? '已换源并对齐到第 ${a.index + 1} 章'
              : '已换源，按原进度定位到第 ${a.index + 1} 章',
        );
      }
    }
  }

  /// 读旧源保存的章节下标。
  ///
  /// 书名可能因源站差异略有不同（带「（精校版）」等后缀），所以把
  /// 搜索结果名 / 当前详情名都试一遍，命中即用。
  Future<int?> _readSavedChapter(String sourceId, String bookName) async {
    try {
      final p = await SharedPreferences.getInstance();
      final names = <String>{bookName, _result.name, _name};
      for (final n in names) {
        if (n.isEmpty) continue;
        final v = p.getInt(ChapterAlignment.progressKey(sourceId, n));
        if (v != null) return v;
      }
    } catch (_) {
      /* ignore */
    }
    return null;
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
