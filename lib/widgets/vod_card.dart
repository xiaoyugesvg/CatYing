import 'package:flutter/material.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import '../common/theme.dart';
import '../models/movie.dart';
import 'glass.dart';

/// 视频卡片：海报 + 右下「源|备注」半透明黑标 + 居中标题
class VodCard extends StatelessWidget {
  final Video video;
  final VoidCallback? onTap;

  /// 长按（收藏页=取消收藏 / 历史页=删除记录）。
  ///
  /// 接在这里而不是让调用方在外面再套一层 GestureDetector：
  /// 外层套手势会和内部抢手势竞技场，长按反馈会丢失。
  final VoidCallback? onLongPress;

  /// 角标文字覆盖。
  ///
  /// 首页/收藏用 [badgeText]（备注或评分）；历史页要显示「第01集 00:20」
  /// 这类播放入口信息，所以留一个覆盖口子，但角标**外观**始终是同一款
  /// [_BadgePill]，保证两处样式一致。
  final String? badgeOverride;

  /// 海报区高度 = 卡片宽度 × 本系数。
  ///
  /// 需要它是因为网格的 childAspectRatio 决定总高，图片靠 Expanded 只能
  /// 分到剩余空间。想调整"图片占多少"就得直接给图片定高。
  /// 收藏/历史用 0.66（横向更方正）；首页等其他场景可保持默认 0.72。
  final double posterHeightRatio;

  // ---- 「史藏」编辑模式覆盖层 ----
  // 两个都为 null 时完全不显示覆盖层，其他页面（首页等）不受影响。

  /// 是否处于编辑模式
  final bool editMode;

  /// 是否已选中（编辑模式下左上角显示勾选圈）
  final bool selected;

  /// 点左上角勾选圈 → 切换选中
  final VoidCallback? onToggleSelect;

  /// 点右上角 ✕ → 删除这一项
  final VoidCallback? onDelete;

  const VodCard({
    super.key,
    required this.video,
    this.onTap,
    this.onLongPress,
    this.badgeOverride,
    this.posterHeightRatio = 0.72,
    this.editMode = false,
    this.selected = false,
    this.onToggleSelect,
    this.onDelete,
  });

  /// 角标只显示备注/评分，**不带源名**（避免「奇优影院|奇优影院|7.0」）
  static String badgeText(Video video) {
    var note = video.note.trim();
    // 去掉备注里可能自带的「源名 |」前缀
    final sep = note.indexOf('|');
    if (sep > 0 && sep < note.length - 1) {
      final head = note.substring(0, sep).trim();
      final tail = note.substring(sep + 1).trim();
      // 前半段像站名（含中文且不含数字评分）时只留后半段
      if (head.isNotEmpty && tail.isNotEmpty && !RegExp(r'\d').hasMatch(head)) {
        note = tail;
      }
    }
    return note;
  }

  @override
  Widget build(BuildContext context) {
    // badgeOverride 优先（历史页显示集数/进度），否则用备注/评分
    final badge = (badgeOverride ?? badgeText(video)).trim();
    return GlassPress(
      // 网格卡片用稍小的值，Liquid Glass 的弹性手感更明显
      pressedScale: 0.955,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          border: Border.all(
            // 编辑模式下：选中项描边用强调色，未选中用普通玻璃描边
            color: (editMode && selected)
                ? AppTheme.accentColor
                : AppTheme.glassBorderSoft,
            width: (editMode && selected) ? 1.6 : 0.6,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 海报区：固定高度 = 卡片宽度 × [posterHeightRatio]
            //
            // 用 LayoutBuilder 拿宽度自己算高度，而不是靠 Expanded 分剩余空间：
            // 网格的 childAspectRatio 决定总高，Expanded 只能跟着分，
            // 想要"图片高、文字区薄"就必须把图片高度写死。
            LayoutBuilder(
              builder: (context, c) {
                final posterH = c.maxWidth * posterHeightRatio;
                return SizedBox(
                  height: posterH,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildPoster(),
                      // 底部极轻渐隐：让右下角角标在任何海报上都读得清，
                      // 同时给扁平海报一点纵深感（透明度很低，不喧宾夺主）
                      if (!(editMode && onToggleSelect != null))
                        IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.center,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.28),
                                ],
                              ),
                            ),
                          ),
                        ),
                      // 编辑模式：整图压暗一点，突出勾选/删除按钮
                      if (editMode && onToggleSelect != null)
                        IgnorePointer(
                          child: ColoredBox(
                            color: Colors.black.withValues(alpha: 0.28),
                          ),
                        ),
                      if (badge.isNotEmpty && !editMode)
                        Positioned(
                          right: 6,
                          bottom: 6,
                          child: _BadgePill(text: badge),
                        ),
                      // 编辑模式：左上角勾选圈 + 右上角 ✕ 删除
                      if (editMode) ...[
                        Positioned(
                          left: 5,
                          top: 5,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onToggleSelect,
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: selected
                                    ? AppTheme.accentColor
                                    : Colors.black.withValues(alpha: 0.45),
                                border: Border.all(
                                  color: selected
                                      ? AppTheme.accentColor
                                      : Colors.white.withValues(alpha: 0.85),
                                  width: 1.6,
                                ),
                              ),
                              child: selected
                                  ? const Icon(Icons.check,
                                      size: 13, color: Colors.white)
                                  : null,
                            ),
                          ),
                        ),
                        if (onDelete != null)
                          Positioned(
                            right: 5,
                            top: 5,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: onDelete,
                              child: Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.black.withValues(alpha: 0.55),
                                  border: Border.all(
                                    color:
                                        Colors.white.withValues(alpha: 0.85),
                                    width: 1.2,
                                  ),
                                ),
                                child: const Icon(Icons.close,
                                    size: 13, color: Colors.white),
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                );
              },
            ),
            // 标题：**只允许一行**，超长省略（不允许跨行）
            Padding(
              padding: const EdgeInsets.fromLTRB(5, 7, 5, 7),
              child: Text(
                video.name,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: FontWeight.w500,
                  // 中文标题加一点字距更透气，长标题也更易读
                  letterSpacing: 0.15,
                  height: 1.15,
                ),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPoster() {
    final picUrl = video.pic.trim();
    if (picUrl.isEmpty || !picUrl.startsWith('http')) {
      return ColoredBox(
        color: AppTheme.backgroundTertiary,
        child: Center(
          child: Icon(
            Icons.movie_outlined,
            color: AppTheme.textTertiary,
            size: 28,
          ),
        ),
      );
    }
    // 🔴 必须给解码尺寸：源站海报常常 1000px+，不设 memCacheWidth 会按原图
    //    整张解码（单张 4~6MB 位图），一屏十几张 ⇒ 滑动时解码 + GC 双抖，
    //    体感就是"列表卡顿"。按卡片实际像素宽（逻辑宽 × dpr）解码最省。
    return LayoutBuilder(
      builder: (context, box) {
        final dpr = MediaQuery.of(context).devicePixelRatio;
        final logicalW = box.maxWidth.isFinite ? box.maxWidth : 160.0;
        final targetW = (logicalW * dpr).round().clamp(120, 720);
        // 两层同图（解码只做一次，memCacheWidth 相同 ⇒ 共用缓存）：
        //   · 底层 cover + 压暗 = 填满卡片，没有黑边；
        //   · 前景 contain = **整张图完整显示**，不拉伸、不裁切。
        // 竖图（多数海报）两层重合看不出差别；横图会完整落在中间，
        // 两侧由压暗的同图铺底 —— 既不变形也不缺内容。
        Widget layer(BoxFit fit, {bool dim = false, bool isBack = false}) {
          return CachedNetworkImage(
            imageUrl: picUrl,
            fit: fit,
            memCacheWidth: targetW,
            maxWidthDiskCache: 720,
            fadeInDuration: Duration.zero,
            alignment: Alignment.center,
            color: dim ? Colors.black.withValues(alpha: 0.45) : null,
            colorBlendMode: dim ? BlendMode.darken : null,
            placeholder: (_, __) => ColoredBox(color: AppTheme.backgroundTertiary),
            errorWidget: (_, __, ___) => isBack
                ? const SizedBox.shrink()
                : ColoredBox(
                    color: AppTheme.backgroundTertiary,
                    child: Icon(Icons.broken_image_outlined,
                        color: AppTheme.textTertiary),
                  ),
          );
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            layer(BoxFit.cover, dim: true, isBack: true),
            layer(BoxFit.contain),
          ],
        );
      },
    );
  }
}

/// 半透明黑角标（跟外观：浅色更深一点以保可读）
class _BadgePill extends StatelessWidget {
  final String text;
  const _BadgePill({required this.text});

  @override
  Widget build(BuildContext context) {
    final bg = AppBrightness.isLight.value
        ? Colors.black.withValues(alpha: 0.62)
        : Colors.black.withValues(alpha: 0.55);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: AppTheme.fontCaption,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
