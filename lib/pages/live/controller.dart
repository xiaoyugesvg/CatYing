import 'package:get/get.dart';

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
    // 恢复统一由 LiveService.onInit 完成（live_lives 优先 / live_url 自动加载），
    // 这里只监听变化刷新 UI，避免双重恢复互相覆盖导致直播页空白
    ever(service.sources, (_) => update());
    ever(service.groups, (_) => update());
    ever(service.selectedSourceIndex, (_) => update());
    ever(service.selectedGroup, (_) => update());
  }

  /// 直播源列表
  List<LiveSource> get sources => service.sources;

  /// 当前选中的直播源索引
  int get selectedSourceIndex => service.selectedSourceIndex.value;

  /// 当前选中的直播源名称
  String get currentSourceName {
    final list = service.sources;
    final i = selectedSourceIndex.clamp(0, list.length - 1);
    return list.isEmpty ? '选择源' : list[i].name;
  }

  /// 分组列表（过滤已屏蔽）
  List<LiveGroup> get groups {
    final all = service.groups;
    final blocked = service.blockedGroups;
    if (blocked.isEmpty) return all;
    return all.where((g) => !blocked.contains(g.name)).toList();
  }

  /// 当前选中的分组索引
  int get selectedGroup => service.selectedGroup.value;

  /// 当前选中的分组名称
  String get currentGroupName {
    final list = groups;
    final i = selectedGroup.clamp(0, list.length - 1);
    return list.isEmpty ? '选择分组' : list[i].name;
  }

  /// 当前分组的频道列表
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

  /// 切换直播源
  Future<void> selectSource(int index) async {
    await service.loadSource(index);
    selectedChannelIndex.value = 0;
    update();
  }

  /// 切换分组
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
