import 'package:flutter/material.dart';
import '../models/comic.dart';
import '../source/source_manager.dart';
import '../theme/jelly_theme.dart';
import 'jelly_favorite_button.dart';
import 'jelly_score_badge.dart';
import 'source_cover_image.dart';
import '../../common/theme.dart';

/// 果冻风漫画卡片
class JellyComicCard extends StatefulWidget {
  final Comic comic;
  final VoidCallback onTap;

  /// 长按回调（用于父级进入多选模式；为空则不启用长按）
  final VoidCallback? onLongPress;

  /// 封面 Hero 动画 tag（与详情页一致；为空则不启用共享元素过渡）
  final String? heroTag;

  /// 是否显示漫画源角标（收藏页 true，搜索页默认 false）
  final bool showSourceBadge;

  /// 紧凑模式（搜索/推荐卡片，对齐参考图：仅封面+名称，
  /// 去掉收藏按钮、热度徽标与作者胶囊——名称位置不加收藏）
  final bool compact;

  const JellyComicCard({
    super.key,
    required this.comic,
    required this.onTap,
    this.onLongPress,
    this.heroTag,
    this.showSourceBadge = false,
    this.compact = false,
  });

  @override
  State<JellyComicCard> createState() => _JellyComicCardState();
}

class _JellyComicCardState extends State<JellyComicCard>
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
      end: 0.95,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) {
    setState(() => _isPressed = true);
    _controller.forward();
  }

  void _onTapUp(TapUpDetails details) {
    setState(() => _isPressed = false);
    _controller.reverse();
    widget.onTap();
  }

  void _onTapCancel() {
    setState(() => _isPressed = false);
    _controller.reverse();
  }

  /// 封面图按需包裹 Hero（heroTag 为空则不启用共享元素过渡）
  Widget _maybeHero(Widget child) {
    final tag = widget.heroTag;
    return tag == null ? child : Hero(tag: tag, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 漫画源角标名（仅收藏页显示；无 sourceId 或源已移除则不显示）
    final sourceName = !widget.showSourceBadge || widget.comic.sourceId == null
        ? null
        : SourceManager().getSource(widget.comic.sourceId!)?.name;

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
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: AnimatedContainer(
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
              child: child,
            ),
          );
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 封面（果冻风渐变遮罩）
              AspectRatio(
                aspectRatio: 3 / 4,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _maybeHero(
                      SourceCoverImage(
                        url: widget.comic.cover,
                        httpHeaders: coverHeaders(widget.comic.sourceId),
                        fit: BoxFit.cover,
                        memCacheWidth: 300,
                        placeholder: (context, url) => ColoredBox(
                          color: isDark
                              ? JellyTheme.cardDark
                              : JellyTheme.cardLight,
                          child: Center(
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: JellyTheme.primary,
                            ),
                          ),
                        ),
                        errorWidget: (context, url, error) => ColoredBox(
                          color: isDark
                              ? JellyTheme.cardDark
                              : JellyTheme.cardLight,
                          child: Icon(
                            Icons.broken_image,
                            size: 40,
                            color: JellyTheme.textSecondary,
                          ),
                        ),
                      ),
                    ),
                    // 底部渐变遮罩
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: 60,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.7),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // 左上角：漫画源徽标
                    if (sourceName != null)
                      Positioned(
                        top: 4,
                        left: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: (isDark ? Colors.black : JellyTheme.primary)
                                .withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            sourceName,
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
              // 信息区
              if (widget.compact)
                // 紧凑模式：仅名称（参考图样式，无收藏/热度/作者胶囊）
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                  child: Text(
                    widget.comic.title,
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              else
                Padding(
                padding: const EdgeInsets.all(12.0),
                child: SizedBox(
                  height: 50, // 固定信息区高度，保证卡片高度一致
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 漫画名 + 作者（左侧）
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 标题
                            Text(
                              widget.comic.title,
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
                            const SizedBox(height: 6),
                            // 作者
                            if (widget.comic.author != null &&
                                widget.comic.author!.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: JellyTheme.primary.withValues(
                                    alpha: 0.15,
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  widget.comic.author!,
                                  style: TextStyle(
                                    fontSize: AppTheme.fontCaption,
                                    color: JellyTheme.primary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      ),
                      // 热度 + 收藏（右侧，收藏在热度下方）
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (comicHasScore(widget.comic))
                            JellyScoreBadge(
                              comic: widget.comic,
                              isDark: isDark,
                            ),
                          if (comicHasScore(widget.comic))
                            const SizedBox(height: 6),
                          JellyFavoriteButton(comic: widget.comic, size: 18),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
