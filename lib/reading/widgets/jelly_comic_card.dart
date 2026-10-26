import 'package:flutter/material.dart';
import 'package:tvbox/reading/models/comic.dart';
import 'package:tvbox/reading/services/settings_service.dart';
import 'package:tvbox/reading/source/source_manager.dart';
import 'package:tvbox/reading/theme/jelly_theme.dart';
import 'package:tvbox/reading/widgets/jelly_favorite_button.dart';
import 'package:tvbox/reading/widgets/jelly_score_badge.dart';
import 'package:tvbox/reading/widgets/source_cover_image.dart';
import 'package:tvbox/common/theme.dart';

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

  /// 更新角标：待看新章节数（>0 显示右上角红底 +N；null/0 不显示）。
  /// 由 ShelfUpdateService（书架/收藏检查更新）计算后传入。
  final int? updateCount;

  const JellyComicCard({
    super.key,
    required this.comic,
    required this.onTap,
    this.onLongPress,
    this.heroTag,
    this.showSourceBadge = false,
    this.compact = false,
    this.updateCount,
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

    return ListenableBuilder(
      listenable: SettingsService(),
      builder: (context, _) {
        // 封面圆角跟随「显示设置」，改完返回即生效
        final radius = SettingsService().coverRadiusPx;
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
        //   所以最外层是**无装饰**的 Column；卡片底色/阴影/圆角**只包封面**，
        //   书名等一律落在卡片**外面**（原来整块 Column 一起进卡片 ✗）
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 卡片本体 = 只有封面
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
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
                borderRadius: BorderRadius.circular(radius),
                // 封面（果冻风渐变遮罩）
                child: AspectRatio(
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
                        errorBuilder: (context, url, error) => ColoredBox(
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
                    // 右上角：更新角标（红底白字 +N，与左上源徽标错开）
                    if ((widget.updateCount ?? 0) > 0)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE5484D).withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '+${widget.updateCount}',
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
            ),
            // 信息区（在卡片外面）
              if (widget.compact)
                // 紧凑模式：仅名称（参考图样式，无收藏/热度/作者胶囊）
                // ✅ 名称栏固定 36 高 + 文字均匀填满 + 标题单行省略：
                //   同一行卡片高度统一、不留底部空白（用户 2026-10-06 反馈
                //   "名称栏太高、底下文字不满"）
                Padding(
                  // ✅ 2026-10-10 用户："封面和名称间距大了"：上边距 6->4、
                  //    名称区 36->30（单行文字垂直富余同步收小）
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                  child: SizedBox(
                    height: 30,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      // spaceEvenly：单标题时垂直居中；有章节时上下均匀分布
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Text(
                          widget.comic.title,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: AppTheme.fontFootnote,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? Colors.white
                                : JellyTheme.textPrimaryLight,
                          ),
                          // 单行省略：名称高度统一的关键（2 行会让同一行卡片参差）
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if ((widget.comic.totalChapters ?? 0) > 0)
                          Text(
                            '共 ${widget.comic.totalChapters} 章',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: AppTheme.fontFootnote - 1,
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.55)
                                  : JellyTheme.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
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
                            // ✅ ① **标题居中** ✓（非紧凑分支 ✓ —— 与 `compact` 那处同款改法 ✓）
                            //   包一层 `SizedBox(width: double.infinity)` 才能让 `textAlign` 生效 ✓；
                            //   ⚠️ 外层 Column 的 `crossAxisAlignment` **保持 start** ✗ →
                            //     下面的**作者 / 热度**仍左对齐 ✓（与截图一致 ✓）
                            SizedBox(
                              width: double.infinity,
                              child: Text(
                                widget.comic.title,
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
        );
      },
    );
  }
}
