import 'package:flutter/material.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import '../common/theme.dart';
import '../models/movie.dart';

/// 视频卡片组件 - 对应 Swift VodCardView
class VodCard extends StatelessWidget {
  final Video video;
  final VoidCallback? onTap;

  const VodCard({super.key, required this.video, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          // iOS 27 Liquid Glass 深色玻璃卡:
          // 半透明深色底 + 顶部镜面高光渐变 + 亮描边
          // 列表内高频卡片不开 blur (BackdropFilter), 保证滚动性能
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0x33FFFFFF), // white 20% 顶部高光
              Color(0x16181A1F), // 深色半透明
              Color(0x16181A1F),
            ],
            stops: [0.0, 0.25, 1.0],
          ),
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          border: Border.all(
            color: AppTheme.glassBorderSoft,
            width: 0.6,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 海报 + Note 徽章
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildPoster(),
                  if (video.note.isNotEmpty)
                    Positioned(
                      right: AppTheme.spacingXS,
                      bottom: AppTheme.spacingXS,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.accentColor.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          video.note,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // 名称 + 元数据
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spacingXS + 2,
                vertical: AppTheme.spacingXS + 2,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    video.name,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontFootnote,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_metaText.isNotEmpty)
                    Text(
                      _metaText,
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption - 1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _metaText {
    final parts = [video.type, video.year].where((s) => s.isNotEmpty).toList();
    return parts.join(' · ');
  }

  Widget _buildPoster() {
    final picUrl = video.pic.trim();
    if (picUrl.isEmpty || !picUrl.startsWith('http')) {
      return ColoredBox(
        color: AppTheme.backgroundTertiary,
        child: Center(
          child: Icon(Icons.movie, color: AppTheme.textTertiary, size: 24),
        ),
      );
    }

    var url = picUrl;
    if (url.startsWith('//')) url = 'https:$url';

    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      httpHeaders: {
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://${Uri.parse(url).host}/',
      },
      placeholder: (context, url) => ColoredBox(
        color: AppTheme.backgroundTertiary,
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppTheme.accentColor,
            ),
          ),
        ),
      ),
      errorBuilder: (context, url, error) => ColoredBox(
        color: AppTheme.backgroundTertiary,
        child: Center(
          child: Icon(Icons.movie, color: AppTheme.textTertiary, size: 24),
        ),
      ),
    );
  }
}
