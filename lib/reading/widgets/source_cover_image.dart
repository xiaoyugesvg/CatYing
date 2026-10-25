// 统一封面图组件：本地路径（加密/base64 站由 ConfigMangaSource 落地后的
// 缓存文件）用 Image.file，data: URL 用 Image.memory，其余走
// CachedNetworkImage（带源防盗链头 httpHeaders）。

import 'dart:convert' show base64;
import 'dart:io' show File;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme/jelly_theme.dart';

class SourceCoverImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final int? memCacheWidth;
  final Map<String, String>? httpHeaders;
  final Widget Function(BuildContext, String)? placeholder;
  final Widget Function(BuildContext, String, Object)? errorWidget;

  const SourceCoverImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.memCacheWidth,
    this.httpHeaders,
    this.placeholder,
    this.errorWidget,
  });

  /// 自动降采样宽度：显示宽度 × 屏幕倍率（最多 3 倍），再夹到合理区间。
  int? _autoCacheWidth(BuildContext context) {
    final w = width;
    if (w == null || w <= 0) return null;
    final dpr = (MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0)
        .clamp(1.0, 3.0);
    return (w * dpr).round().clamp(48, 1600);
  }

  @override
  Widget build(BuildContext context) {
    // 降采样宽度：调用方没显式传时，按"显示宽度 × 屏幕倍率"自动算
    // （多解码的像素本来就看不见，只省内存，观感不变）。
    final cacheW = memCacheWidth ?? _autoCacheWidth(context);
    // 本地路径（绝对路径无 "://"，或 file://）：落地缓存封面走 Image.file
    if (url.startsWith('file://') || !url.contains('://')) {
      final file = File(
        url.startsWith('file://') ? Uri.parse(url).toFilePath() : url,
      );
      return Image.file(
        file,
        width: width,
        height: height,
        fit: fit,
        cacheWidth: cacheW,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return placeholder?.call(context, url) ??
              const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
        },
        errorBuilder: (context, error, stackTrace) =>
            errorWidget?.call(context, url, error) ??
            Icon(Icons.broken_image, size: 40, color: JellyTheme.textSecondary),
      );
    }
    if (url.startsWith('data:')) {
      final commaIdx = url.indexOf(',');
      final data = commaIdx > 0 ? url.substring(commaIdx + 1) : '';
      return Image.memory(
        base64.decode(data),
        width: width,
        height: height,
        fit: fit,
        cacheWidth: cacheW,
        errorBuilder: (context, error, stackTrace) =>
            errorWidget?.call(context, url, error) ??
            Icon(Icons.broken_image, size: 40, color: JellyTheme.textSecondary),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: httpHeaders,
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: cacheW,
      placeholder: placeholder,
      errorWidget: (context, url, error) =>
          errorWidget?.call(context, url, error) ??
          Icon(Icons.broken_image, size: 40, color: JellyTheme.textSecondary),
    );
  }
}
