import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../models/book.dart';
import '../services/book_favorites_service.dart';
import '../services/book_reading_progress_service.dart';
import '../theme/jelly_theme.dart';
import '../../common/theme.dart';

/// 果冻风图书卡片（grid / list 两态）
/// 布局同漫画主卡片：封面 + 书名 + 作者 + 元信息 + 收藏按钮；点击进入详情页。
/// 无下载按钮（下载在详情页），无章节按钮。
class JellyBookCard extends StatefulWidget {
  final Book book;
  final bool isGrid;
  final VoidCallback? onTap;

  /// 长按回调（用于父级进入多选模式；为空则不启用长按）
  final VoidCallback? onLongPress;

  /// 封面 Hero 动画 tag（与详情页一致；为空则不启用共享元素过渡）
  final String? heroTag;

  /// 名称位置是否显示收藏按钮（搜索/推荐页 false，对齐参考图"名称位置不加收藏"；
  /// 收藏页/足迹页默认 true 保留）
  final bool showFavorite;

  const JellyBookCard({
    super.key,
    required this.book,
    required this.isGrid,
    this.onTap,
    this.onLongPress,
    this.heroTag,
    this.showFavorite = true,
  });

  @override
  State<JellyBookCard> createState() => _JellyBookCardState();
}

class _JellyBookCardState extends State<JellyBookCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: widget.isGrid ? 0.95 : 0.97,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails d) {
    setState(() => _isPressed = true);
    _controller.forward();
  }

  void _onTapUp(TapUpDetails d) {
    setState(() => _isPressed = false);
    _controller.reverse();
    widget.onTap?.call();
  }

  void _onTapCancel() {
    setState(() => _isPressed = false);
    _controller.reverse();
  }

  Widget _maybeHero(Widget child) {
    final tag = widget.heroTag;
    return tag == null ? child : Hero(tag: tag, child: child);
  }

  /// 次要元信息（年份 · 语言）；格式已在角标显示，文件大小单独高亮
  String get _secondaryMeta {
    final parts = <String>[];
    if (widget.book.year != null && widget.book.year!.isNotEmpty) {
      parts.add(widget.book.year!);
    }
    if (widget.book.language != null && widget.book.language!.isNotEmpty) {
      parts.add(widget.book.language!);
    }
    return parts.join(' · ');
  }

  /// 阅读百分比（0~1，与阅读器 HUD 同为页维度）；无进度记录或旧数据无页总数返回 null。
  double? get _readPercent {
    final p = BookReadingProgressService().getProgress(widget.book.id);
    if (p == null || p.pageTotal <= 0) return null;
    return ((p.pageIndex + 1) / p.pageTotal).clamp(0.0, 1.0);
  }

  /// 元信息行：文件大小优先（高亮主色加粗）+ 年份/语言（次要）
  Widget _buildMetaRow(bool isDark, {double fontSize = 11}) {
    final secondary = isDark ? Colors.white54 : JellyTheme.textSecondary;
    final secondaryText = _secondaryMeta;
    final size = widget.book.filesizeString;
    final hasSize = size != null && size.isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      // ✅ ② **靠右下** ✓ —— 原来是默认左对齐 ✗（截图里信息行贴在左边 ✓），
      //   按你要的改成**右下角** ✓。这里只改对齐 ✓，**内容一字未动** ✓
      //   （仍是"文件大小（主色加粗）+ 年份/语言"✓，顺序与样式都保持 ✓）。
      // ℹ️ 两处卡片布局都调它 ✓ → 一起生效，保持同族观感一致 ✓✓
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (hasSize)
          Text(
            size,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: JellyTheme.primary,
            ),
          ),
        if (hasSize && secondaryText.isNotEmpty) const SizedBox(width: 6),
        if (secondaryText.isNotEmpty)
          Flexible(
            child: Text(
              secondaryText,
              style: TextStyle(fontSize: fontSize, color: secondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  String get _extBadge =>
      (widget.book.extension != null && widget.book.extension!.isNotEmpty)
      ? widget.book.extension!.toUpperCase()
      : 'BOOK';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              setState(() => _isPressed = false);
              _controller.reverse();
              widget.onLongPress!();
            },
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) => Transform.scale(
          scale: _scaleAnimation.value,
          child: child,
        ),
        // ── 用户 2026-10-07：「名称不要纳入进卡片，只有封面才是卡片」──
        //   宫格：卡片外壳只包封面，书名/作者/收藏落在卡片**外面** ✓；
        //   列表：本来就是"一整行一张卡"，保持不变 ✓
        child: widget.isGrid
            ? _buildGrid(isDark)
            : _card(isDark, _buildList(isDark)),
      ),
    );
  }

  /// 卡片外壳（底色 + 阴影 + 圆角 + 裁剪）。宫格只包封面，列表包整行。
  Widget _card(bool isDark, Widget child) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        boxShadow: _isPressed
            ? [
                BoxShadow(
                  color: JellyTheme.primary.withValues(alpha: 0.2),
                  blurRadius: 10,
                  spreadRadius: 1,
                  offset: const Offset(0, 3),
                ),
              ]
            : [
                BoxShadow(
                  color: JellyTheme.primary.withValues(alpha: 0.15),
                  blurRadius: 15,
                  spreadRadius: 2,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: child,
      ),
    );
  }

  Widget _coverWidget(bool isDark, {double? width, double? height}) {
    final coverUrl = widget.book.cover ?? '';
    return coverUrl.isEmpty
        ? Container(
            color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
            width: width,
            height: height,
            child: Icon(
              Icons.menu_book_rounded,
              size: 32,
              color: JellyTheme.textSecondary,
            ),
          )
        : CachedNetworkImage(
            imageUrl: coverUrl,
            fit: BoxFit.cover,
            memCacheWidth: 300,
            width: width,
            height: height,
            placeholder: (c, u) => Container(
              color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
              width: width,
              height: height,
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: JellyTheme.primary,
                ),
              ),
            ),
            errorWidget: (c, u, e) => Container(
              color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
              width: width,
              height: height,
              child: Icon(
                Icons.menu_book_rounded,
                size: 32,
                color: JellyTheme.textSecondary,
              ),
            ),
          );
  }

  /// 收藏按钮（跟随 BookFavoritesService 状态切换）
  Widget _buildFavoriteButton() {
    return ListenableBuilder(
      listenable: BookFavoritesService(),
      builder: (context, _) {
        final fav = BookFavoritesService().isFavorite(widget.book.id);
        return IconButton(
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: Icon(
              fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              key: ValueKey(fav),
              color: fav ? JellyTheme.error : JellyTheme.primary,
              size: 20,
            ),
          ),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: () => BookFavoritesService().toggle(widget.book),
          tooltip: fav ? '取消收藏' : '收藏',
        );
      },
    );
  }

  Widget _buildGrid(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── 卡片本体 = 只有封面（名称等落在卡片外面，用户 2026-10-07）──
        _card(
          isDark,
          AspectRatio(
          aspectRatio: 3 / 4,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _maybeHero(_coverWidget(isDark)),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                // 黑渐变减薄（原 50/0.7 太厚，参考图只覆盖书名一行）
                height: 28,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.55),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: JellyTheme.primary.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _extBadge,
                    style: const TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        ),
        // 名称 / 元信息：放在卡片**外面**
        Padding(
          // ✅ 2026-10-10 用户："封面和名称间距大了"：上边距 8->5、
          //    名称区 50->44（标题+元信息的垂直富余同步收小）
          padding: const EdgeInsets.fromLTRB(10, 5, 4, 6),
          child: SizedBox(
            height: 44,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ✅ ① **书名居中** ✓ —— 原来走默认左对齐 ✗（截图 IMG_8595/8606 那种）
                      // 做法 ✓：只给**标题**包一层 `SizedBox(width: double.infinity)`
                      //   → 它就有了确定宽度 ✓ → `textAlign: center` 才真正生效 ✓✓
                      // ⚠️ **不要**改下面 Column 的 `crossAxisAlignment` ✗ ——
                      //   那会连 `_buildMetaRow`（作者等 ✓）一起居中 ✗，
                      //   而截图里作者行是**左对齐**的 ✓，要保持 ✓
                      SizedBox(
                        width: double.infinity,
                        child: Text(
                          // 兜底：数据侧 title 偶发空串时显示"未知书名"，
                          // 避免名称栏空白（用户 2026-10-06 反馈"书没有名称"）
                          widget.book.displayTitle.trim().isEmpty
                              ? '未知书名'
                              : widget.book.displayTitle,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? Colors.white
                                : JellyTheme.textPrimaryLight,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _buildMetaRow(isDark, fontSize: AppTheme.fontCaption),
                    ],
                  ),
                ),
                // 名称位置不加收藏（搜索/推荐页）：右侧留空让书名占满
                if (widget.showFavorite) _buildFavoriteButton(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildList(bool isDark) {
    final readPct = _readPercent;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _maybeHero(
          SizedBox(
            width: 84,
            height: 112,
            child: _coverWidget(isDark, width: 84, height: 112),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ✅ ① **书名居中**（第二处 ✓ —— 与上面那处同款改法 ✓）
                //   这里标题更大（fontHeadline + w700 ✓ = 详情/推荐位样式 ✓），
                //   同样包一层 `SizedBox(width: double.infinity)` 才能让 `textAlign` 生效 ✓
                //   ⚠️ 下面 Column 的 `crossAxisAlignment` **保持 start** ✗ ——
                //     让紧随其后的**作者行仍左对齐** ✓（与截图一致 ✓）
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    // 兜底同网格：title 偶发空串时显示"未知书名"
                    widget.book.title.trim().isEmpty
                        ? '未知书名'
                        : widget.book.title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 6),
                if (widget.book.author != null &&
                    widget.book.author!.isNotEmpty) ...[
                  Text(
                    widget.book.author!,
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: isDark ? Colors.white54 : JellyTheme.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                ],
                _buildMetaRow(isDark, fontSize: AppTheme.fontCaption),
                if (readPct != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '已读 ${(readPct * 100).toInt()}%',
                    style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: JellyTheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        // 右侧：格式标签 + 收藏按钮 垂直对齐（showFavorite=false 时只留标签）
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: JellyTheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _extBadge,
                  style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    color: JellyTheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (widget.showFavorite) ...[
                const SizedBox(height: 8),
                _buildFavoriteButton(),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 图书封面 Hero 动画 tag（区分来源页面，避免同书 tag 冲突）
String bookCoverHeroTag(String prefix, Book book) => '$prefix-book-${book.id}';
