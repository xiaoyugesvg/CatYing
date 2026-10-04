import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../theme/jelly_theme.dart';
import '../../widgets/app_page_loading.dart';
import '../../common/theme.dart';
import 'book_search_page.dart';

/// 豆瓣图书排行榜。
///
/// ── 数据来源（字段已实测确认）────────────────────────────────
/// `https://m.douban.com/rexxar/api/v2/subject_collection/{tag}/items`
///   `  ?start=0&count=20`
///
/// ⚠️ **必须带 Referer**，否则返回 **HTTP 400**：
///   `Referer: https://m.douban.com/book/chart/`
/// UA 也要伪装成手机 Safari（桌面 UA 同样被拒）。
///
/// 返回里我们用到这些键（都实测存在）：
///   · `cover`        封面图 URL —— **不是 `pic`**（`pic` 恒为 undefined，踩过）
///   · `card_subtitle` "作者 / 年份 / 出版社"
///   · `description`  一句话简介（新书才有，老书可能为空）
///   · `rating.value` 评分，`rating.count` 评价人数
///   · `rating.star_count` 星数（用于画星星）
///
/// ── 为什么不用 WebView ────────────────────────────────────────
/// 豆瓣排行榜页是重 JS 渲染的，WebView 打开慢、还带广告与"打开 App"横幅。
/// 走 JSON 接口能直接拿到 书名/封面/评分/作者，列表也更顺滑。
/// 豆瓣图床反爬头：无 Referer/手机 UA 会返回 HTTP 418（实测），
/// CachedNetworkImage 拉封面必须带上，否则全部走 errorWidget 占位图。
const _doubanImageHeaders = <String, String>{
  'User-Agent':
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
          'Mobile/15E148 Safari/604.1',
  'Referer': 'https://m.douban.com/',
};

class DoubanRankingPage extends StatefulWidget {
  const DoubanRankingPage({super.key});

  @override
  State<DoubanRankingPage> createState() => _DoubanRankingPageState();
}

/// 一个榜单
class _Board {
  const _Board(this.tag, this.label);
  final String tag;
  final String label;
}

/// 两个榜单（按用户截图：热门榜 / 图书250）
///
/// ── tag 都是实测过的，不是猜的 ────────────────────────────────
/// 实测结果（`start=0&count=3`）：
///   · `book_hot`     HTTP 200 → 例"未来简史"   ← 这才是**热门榜**
///   · `book_top250`  HTTP 200 → 例"红楼梦"     ← 图书250
///   · `book_fiction` HTTP 200 → 例"索拉里斯星"（虚构类，不是热门榜）
///
/// ⚠️ 我第一版误把 `book_fiction` 当"热门榜" —— 它其实是"虚构类"，
/// 内容与截图不符。**别的 tag 别乱加**：实测 `book_business`、
/// `book_new` 都是 **HTTP 404**，加了就是"点了报错"。
const _boards = <_Board>[
  _Board('book_hot', '热门榜'),
  _Board('book_top250', '图书250'),
];

class _DoubanRankingPageState extends State<DoubanRankingPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  late final Dio _dio;

  final Map<String, List<_Book>> _items = {};
  final Map<String, int> _start = {};
  final Map<String, bool> _loading = {};
  final Map<String, bool> _done = {};
  final Map<String, String> _error = {};
  final _scroll = <String, ScrollController>{};

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _boards.length, vsync: this);
    _tab.addListener(_onTabChanged);
    _dio = Dio(BaseOptions(
      // ⚠️ 缺这两行豆瓣直接 400（见类注释）
      headers: {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
                'Mobile/15E148 Safari/604.1',
        'Referer': 'https://m.douban.com/book/chart/',
      },
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 12),
    ));
    for (final b in _boards) {
      _start[b.tag] = 0;
      _loading[b.tag] = false;
      _done[b.tag] = false;
      _items[b.tag] = [];
      final c = ScrollController();
      c.addListener(() => _onScroll(b.tag, c));
      _scroll[b.tag] = c;
    }
    _load(_boards.first.tag);
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    for (final c in _scroll.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onTabChanged() {
    if (_tab.indexIsChanging) return;
    final tag = _boards[_tab.index].tag;
    if ((_items[tag] ?? []).isEmpty && _loading[tag] != true) {
      _load(tag);
    }
    if (mounted) setState(() {});
  }

  void _onScroll(String tag, ScrollController c) {
    if (!c.hasClients) return;
    if (c.position.pixels >= c.position.maxScrollExtent - 400) {
      _load(tag, more: true);
    }
  }

  Future<void> _load(String tag, {bool more = false}) async {
    if (_loading[tag] == true) return;
    if (more && _done[tag] == true) return;
    setState(() {
      _loading[tag] = true;
      if (!more) _error[tag] = '';
    });

    final start = more ? (_start[tag] ?? 0) : 0;
    try {
      final r = await _dio.get(
        'https://m.douban.com/rexxar/api/v2/subject_collection/$tag/items',
        queryParameters: {'start': start, 'count': 20},
      );
      final data = r.data;
      final raw = (data is Map) ? data['subject_collection_items'] : null;
      final list = <_Book>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is! Map) continue;
          final b = _Book.fromJson(e.cast<String, dynamic>(), start + list.length + 1);
          if (b.title.isNotEmpty) list.add(b);
        }
      }
      if (!mounted) return;
      setState(() {
        if (more) {
          (_items[tag] ??= []).addAll(list);
        } else {
          _items[tag] = list;
        }
        _start[tag] = start + list.length;
        // 返回不足一页就到底了（豆瓣没有 total 字段）
        if (list.length < 20) _done[tag] = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error[tag] = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading[tag] = false);
    }
  }

  /// 把 Dio 异常翻成人话。
  ///
  /// 直接 `$e` 会打出一大段 `DioException [connection error]: ...`，
  /// 用户看不懂也不知道该做什么。
  String _friendlyError(Object e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return '请求超时，请检查网络后重试';
        case DioExceptionType.connectionError:
          return '连不上豆瓣，可能需要代理或网络受限';
        case DioExceptionType.badResponse:
          final code = e.response?.statusCode;
          if (code == 400 || code == 403) {
            return '豆瓣拒绝了这次请求（HTTP $code），可能接口有变动';
          }
          return '豆瓣返回 HTTP $code';
        default:
          return '加载失败，请稍后重试';
      }
    }
    return '加载失败，请稍后重试';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        // 按截图：标题居中 + 右上角刷新圆按钮
        centerTitle: true,
        title: Text('豆瓣图书排行榜',
            style: TextStyle(
              fontSize: AppTheme.fontTitle3,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            )),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _circleIcon(
              isDark: isDark,
              icon: Icons.refresh_rounded,
              tooltip: '刷新',
              onTap: () => _load(_boards[_tab.index].tag),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── 榜单切换胶囊（截图里在标题下方居中）──────────────
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: AnimatedBuilder(
              animation: _tab.animation!,
              builder: (context, _) => _boardToggle(isDark),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [for (final b in _boards) _buildBoard(b, isDark)],
            ),
          ),
        ],
      ),
    );
  }

  /// 两个榜单的胶囊切换（选中=深色实底，未选中=浅灰）
  Widget _boardToggle(bool isDark) {
    final idx = _tab.animation!.value;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _boards.length; i++)
            GestureDetector(
              onTap: () => _tab.animateTo(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                decoration: BoxDecoration(
                  // 用"离选中项的距离"做插值，滑动时两段平滑过渡
                  color: (idx - i).abs() < 0.5
                      ? (isDark ? Colors.white : JellyTheme.primary)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _boards[i].label,
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: (idx - i).abs() < 0.5
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: (idx - i).abs() < 0.5
                        ? (isDark
                            ? JellyTheme.backgroundDark
                            : Colors.white)
                        : JellyTheme.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBoard(_Board b, bool isDark) {
    final items = _items[b.tag] ?? const <_Book>[];
    final err = _error[b.tag] ?? '';
    final loading = _loading[b.tag] == true;

    if (items.isEmpty && loading) {
      return AppPageLoading(color: JellyTheme.primary);
    }
    if (items.isEmpty && err.isNotEmpty) {
      return _emptyState(
        icon: Icons.cloud_off_rounded,
        title: '加载失败',
        subtitle: err,
        onRetry: () => _load(b.tag),
        isDark: isDark,
      );
    }
    if (items.isEmpty) {
      return _emptyState(
        icon: Icons.inbox_rounded,
        title: '暂无数据',
        subtitle: '这个榜单暂时没有返回内容，下拉可重试',
        onRetry: () => _load(b.tag),
        isDark: isDark,
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(b.tag),
      child: ListView.builder(
        controller: _scroll[b.tag],
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
        itemCount: items.length + 1,
        itemBuilder: (context, i) {
          if (i == items.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _done[b.tag] == true ? '已经到底了' : '',
                        style: TextStyle(
                            fontSize: AppTheme.fontFootnote, color: JellyTheme.textSecondary),
                      ),
              ),
            );
          }
          return InkWell(
            onTap: () => _confirmGoSearch(items[i].title),
            borderRadius: BorderRadius.circular(14),
            child: _bookRow(items[i], isDark),
          );
        },
      ),
    );
  }

  /// 一本书的卡片（按截图：名次徽标压在封面上 / 标题 / 作者行 / 简介 / 人数 / 星星+评分）
  /// 点击排行条目：弹「去找书？」确认框，确认后跳图书搜索页按书名搜索
  /// （参考目标界面 IMG_8394：白色圆角居中确认框，取消 / 去搜索）
  Future<void> _confirmGoSearch(String title) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Text(
          '去找书？\n跳转到图书搜索，按书名「$title」搜索',
          textAlign: TextAlign.center,
          style: const TextStyle(height: 1.5),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去搜索'),
          ),
        ],
      ),
    );
    if (go == true && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BookSearchPage(initialKeyword: title),
        ),
      );
    }
  }

  Widget _bookRow(_Book b, bool isDark) {
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面 + 左上角名次徽标
          SizedBox(
            width: 74,
            height: 108,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 74,
                    height: 108,
                    child: b.cover.isEmpty
                        ? _coverPlaceholder()
                        : CachedNetworkImage(
                            imageUrl: b.cover,
                            fit: BoxFit.cover,
                            memCacheWidth: 200,
                            httpHeaders: _doubanImageHeaders,
                            placeholder: (_, __) => Container(
                              color: JellyTheme.textSecondary
                                  .withValues(alpha: 0.10),
                            ),
                            errorWidget: (_, __, ___) =>
                                _coverPlaceholder(),
                          ),
                  ),
                ),
                // 「No.N」深色徽标压在封面左上角
                Positioned(
                  left: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 3),
                    decoration: const BoxDecoration(
                      color: Color(0xCC2A2A2C),
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(6),
                        bottomRight: Radius.circular(8),
                      ),
                    ),
                    child: Text(
                      'No.${b.rank}',
                      style: const TextStyle(
                        fontSize: AppTheme.fontCaption,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // 右侧信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        b.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                          color: label,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 星星 + 评分（截图右上角）
                    if (b.rating > 0)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.star_rounded,
                              size: 15, color: Color(0xFFF5A623)),
                          const SizedBox(width: 2),
                          Text(
                            b.rating.toStringAsFixed(1),
                            style: const TextStyle(
                              fontSize: AppTheme.fontBody,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFF5A623),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 5),
                if (b.subtitle.isNotEmpty)
                  Text(
                    b.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        height: 1.4,
                        color: JellyTheme.textSecondary),
                  ),
                if (b.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    b.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        height: 1.4,
                        color: JellyTheme.textSecondary),
                  ),
                ],
                const SizedBox(height: 5),
                Text(
                  b.ratingCount > 0 ? '${b.ratingCount}人评价' : '暂无评分',
                  style: TextStyle(
                      fontSize: AppTheme.fontFootnote, color: JellyTheme.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverPlaceholder() => Container(
        color: JellyTheme.textSecondary.withValues(alpha: 0.15),
        child: Icon(Icons.menu_book_rounded,
            size: 22, color: JellyTheme.textSecondary),
      );

  /// 右上角圆形图标按钮（浅灰圆 + 近黑图标）—— 与阅读各页同款
  Widget _circleIcon({
    required bool isDark,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    double size = 36,
  }) {
    return Material(
      color: isDark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.black.withValues(alpha: 0.05),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Icon(
                icon,
                size: 20,
                color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onRetry,
    required bool isDark,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: JellyTheme.textSecondary),
            const SizedBox(height: 16),
            Text(title,
                style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                )),
            const SizedBox(height: 8),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    height: 1.6,
                    color: JellyTheme.textSecondary)),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重新获取'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 排行榜里的一本书
class _Book {
  const _Book({
    required this.rank,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.cover,
    required this.rating,
    required this.ratingCount,
  });

  final int rank;
  final String title;

  /// 作者 · 出版社 · 年份（来自 `card_subtitle`）
  final String subtitle;
  final String description;
  final String cover;
  final double rating;
  final int ratingCount;

  /// 从豆瓣接口条目构造。
  ///
  /// ⚠️ 全部字段**容错取值**。踩过的两个坑：
  ///   1. 封面键是 **`cover`** —— 但它是**对象** `{"url": "...", "width":0,...}`
  ///      不是字符串（`toString()` 会得到 `{url: ...}` 导致全部占位图）。
  ///      老版本接口可能直接返回字符串，两者都兼容。
  ///   2. `rating` 有时整个是 null（新书无评分，另有 `null_rating_reason`）。
  ///      直接 `j['rating']['value']` 会抛 NoSuchMethodError。
  factory _Book.fromJson(Map<String, dynamic> j, int fallbackRank) {
    var rating = 0.0;
    var count = 0;
    final r = j['rating'];
    if (r is Map) {
      final v = r['value'];
      if (v is num) rating = v.toDouble();
      final c = r['count'];
      if (c is num) count = c.toInt();
    }

    return _Book(
      rank: fallbackRank,
      title: (j['title'] ?? '').toString(),
      // card_subtitle 形如 "刘慈欣 / 重庆出版社 / 2012-1"
      subtitle: (j['card_subtitle'] ?? '').toString().trim(),
      description: (j['description'] ?? '').toString().trim(),
      cover: _coverOf(j),
      rating: rating,
      ratingCount: count,
    );
  }

  /// 兼容 cover 字符串与对象两种形态。
  static String _coverOf(Map<String, dynamic> j) {
    final c = j['cover'];
    if (c is String) return c;
    if (c is Map) {
      final u = c['url'];
      if (u is String && u.isNotEmpty) return u;
    }
    return '';
  }
}
