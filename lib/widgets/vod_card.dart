import 'package:flutter/material.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import '../common/theme.dart';
import '../models/movie.dart';

/// 视频卡片：海报 + 右下「源|备注」半透明黑标 + 居中标题
class VodCard extends StatelessWidget {
  final Video video;
  final VoidCallback? onTap;

  const VodCard({super.key, required this.video, this.onTap});

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
    final badge = badgeText(video);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          border: Border.all(
            color: AppTheme.glassBorderSoft,
            width: 0.6,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 海报 + 右下半透明黑标
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildPoster(),
                  if (badge.isNotEmpty)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: _BadgePill(text: badge),
                    ),
                ],
              ),
            ),
            // 标题居中
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
              child: Text(
                video.name,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 2,
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
    return CachedNetworkImage(
      imageUrl: picUrl,
      fit: BoxFit.cover,
      placeholder: (_, __) => ColoredBox(color: AppTheme.backgroundTertiary),
      errorWidget: (_, __, ___) => ColoredBox(
        color: AppTheme.backgroundTertiary,
        child: Icon(Icons.broken_image_outlined, color: AppTheme.textTertiary),
      ),
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
          fontSize: 10,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
