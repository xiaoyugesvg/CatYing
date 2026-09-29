import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 图片磁盘缓存上限：约 500 张 / 14 天
class TVBoxCacheManager extends CacheManager with ImageCacheManager {
  static const key = 'tvboxImageCache';
  static final TVBoxCacheManager _instance = TVBoxCacheManager._();
  factory TVBoxCacheManager() => _instance;

  TVBoxCacheManager._()
      : super(Config(
          key,
          maxNrOfCacheObjects: 500,
          maxAgeCacheObject: const Duration(days: 14),
        ));
}
