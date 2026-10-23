import 'package:get/get.dart';

import '../../models/movie.dart';
import 'drama_player_page.dart';

/// 从「短剧」打开播放的入口。
///
/// 2026-10-23：不再跳 `/detail`（那会先渲染一屏详情布局再切竖屏，
/// 用户看到的是「闪一下详情」），直接打开短剧专用播放页 ——
/// 该页面内部自己取剧集与播放地址，进去就是黑底封面，取到即播。
class DramaEntry {
  DramaEntry._();

  /// 返回 Future：调用方 await 之后可以刷新「继续观看」进度
  static Future<void> open(Video v) async {
    await Get.to(() => DramaPlayerPage(video: v));
  }
}
