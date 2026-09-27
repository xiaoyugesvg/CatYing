import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/live_models.dart';
import '../../services/live_service.dart';

/// 直播页控制器
class LiveController extends GetxController {
  final service = LiveService.instance;

  final searchKeyword = ''.obs;
  final selectedChannelIndex = 0.obs;

  @override
  void onInit() {
    super.onInit();
    _restorePersisted();
  }

  /// 重启后自动恢复上次添加的直播源（保存过 m3u URL 且当前无任何配置时）
  Future<void> _restorePersisted() async {
    if (service.sources.isNotEmpty || service.channels.isNotEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final url = (prefs.getString('live_url') ?? '').trim();
      if (url.isNotEmpty) {
        await service.loadFromUrl(url);
        update();
      }
    } catch (_) {}
  }

  List<LiveGroup> get groups {
    final all = service.groups;
    final blocked = service.blockedGroups;
    if (blocked.isEmpty) return all;
    return all.where((g) => !blocked.contains(g.name)).toList();
  }

  int get selectedGroup => service.selectedGroup.value;

  List<LiveChannel> get channels {
    var list = service.currentChannels;
    final blocked = service.blockedGroups;
    if (blocked.isNotEmpty) {
      list = list.where((c) => !blocked.contains(c.group)).toList();
    }
    final kw = searchKeyword.value.trim();
    if (kw.isEmpty) return list;
    return list.where((c) => c.name.contains(kw)).toList();
  }

  void selectGroup(int index) {
    service.selectedGroup.value = index;
    selectedChannelIndex.value = 0;
    update();
  }

  void selectChannel(int index) {
    selectedChannelIndex.value = index;
    update();
  }

  LiveChannel? get currentChannel {
    final list = channels;
    if (list.isEmpty) return null;
    final i = selectedChannelIndex.value.clamp(0, list.length - 1);
    return list[i];
  }

  Future<void> reloadFromUrl(String url) => service.loadFromUrl(url);
}
