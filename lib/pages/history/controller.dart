import 'dart:async';

import 'package:get/get.dart';
import 'package:tvbox/models/movie.dart';
import 'package:tvbox/models/cache_store.dart';
import 'package:tvbox/router/app_pages.dart';
import 'package:tvbox/webhome/webhtv_playback_sync_service.dart';

/// 历史记录控制器
class HistoryController extends GetxController {
  static const pageSize = 50;
  final shown = 50.obs;

  void showMore() {
    shown.value += pageSize;
    update();
  }

  List<VodRecord> get historyList => CacheStore.instance.records.toList();

  /// 点击历史记录 → 跳到详情页，让 detail 自己去读 playNote + VodPlaybackState 续播
  void openHistory(VodRecord item) {
    final video = Video(
      id: item.vodId,
      name: item.vodName,
      pic: item.vodPic,
      sourceKey: item.sourceKey,
    );
    Get.toNamed(AppPages.detail, arguments: video);
  }

  void deleteItem(VodRecord item) {
    CacheStore.instance.removeRecord(item.vodId, item.sourceKey);
    // ── Webhtv 观影记录同步：删除事件上报 + 落本地墓碑（阻止旧进度复活）
    unawaited(WebhtvPlaybackSyncService.instance.reportDeleted(
      siteKey: item.sourceKey,
      vodId: item.vodId,
      scope: 'item',
    ));
  }

  Future<void> clearAll() async {
    await CacheStore.instance.clearHistory();
    // 清空 = 当前接口范围内的全量删除
    unawaited(
        WebhtvPlaybackSyncService.instance.reportDeleted(siteKey: '', vodId: '', scope: 'all'));
  }
}
