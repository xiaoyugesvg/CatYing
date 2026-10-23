import 'package:get/get.dart';

import '../../models/movie.dart';

/// 从「短剧」进入详情页的入口标记。
///
/// 为什么不用 `arguments: {'video': v, 'from': 'drama'}`：
///   `/detail` 在「TMDB 媒体库模式」下会换成另一个页面，而它（以及详情页）
///   都只认 `Get.arguments is Video`。改参数结构要同时改两处，容易漏。
///
/// 这里用一个**一次性标记**：跳转前置位，详情页 initState 读走并清空。
/// 单线程顺序执行，不存在被别的跳转"截胡"的问题。
class DramaEntry {
  DramaEntry._();

  static bool _pending = false;

  /// 详情页 initState 调用：取出并清空标记
  static bool consumePending() {
    final v = _pending;
    _pending = false;
    return v;
  }

  /// 从短剧打开详情（进入后自动切竖屏刷剧模式）
  static void openDetail(Video v) {
    _pending = true;
    Get.toNamed('/detail', arguments: v);
  }
}
