import 'package:get/get.dart';

import '../../models/live_models.dart';
import '../../services/live_service.dart';

/// 直播页控制器
class LiveController extends GetxController {
  final service = LiveService.instance;

  final searchKeyword = ''.obs;
  final selectedChannelIndex = 0.obs;

  List<LiveGroup> get groups => service.groups;
  int get selectedGroup => service.selectedGroup.value;

  List<LiveChannel> get channels {
    final list = service.currentChannels;
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
