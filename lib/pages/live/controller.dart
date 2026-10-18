import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/live_models.dart';
import '../../services/live_service.dart';

/// 直播页控制器
class LiveController extends GetxController {
  final service = LiveService.instance;

  final searchKeyword = ''.obs;
  final selectedChannelIndex = 0.obs;

  /// 频道列表视图：0=列表 1=卡片 2=两列 3=三列 4=四列
  final channelView = 0.obs;

  /// 直播源弹窗视图：0=列表 1=两列 2=三列
  final sourceView = 0.obs;

  /// 分组弹窗视图：0=列表 1=两列 2=三列
  final groupView = 0.obs;

  static const _kChannelViewKey = 'live_channel_view';
  static const _kSourceViewKey = 'live_source_view';
  static const _kGroupViewKey = 'live_group_view';

  @override
  void onInit() {
    super.onInit();
    loadFavorites();
    _loadViewModes();
    // 恢复统一由 LiveService.onInit 完成（live_lives 优先 / live_url 自动加载），
    // 这里只监听变化刷新 UI，避免双重恢复互相覆盖导致直播页空白
    ever(service.sources, (_) => update());
    ever(service.groups, (_) => update());
    ever(service.selectedSourceIndex, (_) => update());
    ever(service.selectedGroup, (_) => update());
    ever(service.groups, (_) {
      // 源切换后收藏/真实分组变化，钳制下标
      final n = groups.length;
      if (n > 0 && selectedGroupIndex.value >= n) {
        selectedGroupIndex.value = 0;
      }
      update();
    });
  }

  /// 直播源列表
  List<LiveSource> get sources => service.sources;

  /// 当前选中的直播源索引
  int get selectedSourceIndex => service.selectedSourceIndex.value;

  /// 当前选中的直播源名称
  String get currentSourceName {
    final list = service.sources;
    if (list.isEmpty) return '选择源'; // 空列表防 clamp(0,-1) 异常导致白屏
    final i = selectedSourceIndex.clamp(0, list.length - 1);
    return list[i].name;
  }

  /// 收藏置顶分组名
  static const favGroupName = '我的收藏';

  /// 分组列表：收藏置顶 + 过滤已屏蔽
  List<LiveGroup> get groups {
    final favs = favoriteChannels;
    final all = service.groups;
    final blocked = service.blockedGroups;
    final real = blocked.isEmpty
        ? all
        : all.where((g) => !blocked.contains(g.name)).toList();
    return [
      if (favs.isNotEmpty) LiveGroup(name: favGroupName, channels: favs),
      ...real,
    ];
  }

  /// 已收藏频道
  List<LiveChannel> get favoriteChannels {
    final keys = favoriteKeys.toSet();
    return _allChannels.where((c) => keys.contains(favKey(c))).toList();
  }

  /// 当前选中的分组索引
  /// 本控制器分组列表（含「我的收藏」）的选中下标
  final selectedGroupIndex = 0.obs;

  /// 兼容旧字段名
  int get selectedGroup => selectedGroupIndex.value;

  /// 当前选中的分组名称
  String get currentGroupName {
    final list = groups;
    if (list.isEmpty) return '选择分组'; // 空列表防 clamp(0,-1) 异常导致白屏
    final i = selectedGroupIndex.value.clamp(0, list.length - 1);
    return list[i].name;
  }

  /// 收藏频道 key：`group|name`
  final favoriteKeys = <String>[].obs;
  final showOnlyFavorites = false.obs;

  static String favKey(LiveChannel c) => '${c.group}|${c.name}';

  bool isFavorite(LiveChannel c) => favoriteKeys.contains(favKey(c));

  Future<void> loadFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      favoriteKeys.value =
          prefs.getStringList('live_favorites') ?? const [];
    } catch (_) {}
  }

  Future<void> toggleFavorite(LiveChannel c) async {
    final k = favKey(c);
    if (favoriteKeys.contains(k)) {
      favoriteKeys.remove(k);
    } else {
      favoriteKeys.add(k);
    }
    favoriteKeys.refresh();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('live_favorites', favoriteKeys.toList());
    } catch (_) {}
    update();
  }

  // ── 视图模式（列表 / 卡片 / 网格 2·3·4 列）──────────────────

  Future<void> _loadViewModes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      channelView.value = (prefs.getInt(_kChannelViewKey) ?? 0).clamp(0, 4);
      sourceView.value = (prefs.getInt(_kSourceViewKey) ?? 0).clamp(0, 2);
      groupView.value = (prefs.getInt(_kGroupViewKey) ?? 0).clamp(0, 2);
    } catch (_) {}
  }

  Future<void> setChannelView(int v) async {
    channelView.value = v.clamp(0, 4);
    update();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kChannelViewKey, channelView.value);
    } catch (_) {}
  }

  Future<void> setSourceView(int v) async {
    sourceView.value = v.clamp(0, 2);
    update();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSourceViewKey, sourceView.value);
    } catch (_) {}
  }

  Future<void> setGroupView(int v) async {
    groupView.value = v.clamp(0, 2);
    update();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kGroupViewKey, groupView.value);
    } catch (_) {}
  }

  /// 全部分组的频道（跨组搜索用）
  List<LiveChannel> get _allChannels {
    final out = <LiveChannel>[];
    for (final g in service.groups) {
      out.addAll(g.channels);
    }
    return out;
  }

  /// 当前列表：有关键词时跨分组搜索；可选只看收藏
  List<LiveChannel> get channels {
    final kw = searchKeyword.value.trim();
    final blocked = service.blockedGroups;
    Iterable<LiveChannel> list;
    if (kw.isNotEmpty) {
      // 跨分组搜索：不必先切到正确分组
      list = _allChannels;
    } else if (showOnlyFavorites.value) {
      list = _allChannels.where((c) => isFavorite(c));
    } else {
      // 用 controller.groups（含收藏置顶），否则选中「我的收藏」会读错源
      final gs = groups;
      if (gs.isEmpty) {
        list = const <LiveChannel>[];
      } else {
        final i = selectedGroupIndex.value.clamp(0, gs.length - 1);
        list = gs[i].channels;
      }
    }
    var out = list.toList();
    if (blocked.isNotEmpty) {
      out = out.where((c) => !blocked.contains(c.group)).toList();
    }
    if (kw.isNotEmpty) {
      out = out.where((c) => c.name.contains(kw)).toList();
    }
    return out;
  }

  /// 切换直播源
  Future<void> selectSource(int index) async {
    await service.loadSource(index);
    selectedChannelIndex.value = 0;
    update();
  }

  /// 切换分组
  void selectGroup(int index) {
    // 用 controller.groups 下标（含收藏置顶），避免与 service.groups 错位
    selectedGroupIndex.value = index;
    // 同步 service：收藏组(0)对应真实分组 0，其余下标-1
    final hasFav = groups.isNotEmpty && groups.first.name == favGroupName;
    final real = hasFav ? index - 1 : index;
    if (real >= 0) {
      service.selectedGroup.value = real;
    }
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

  /// 追加一个新直播源（可带名称；多源模式直接追加）
  Future<void> addSource(String url, {String? name}) =>
      service.addSource(url, name: name);
}
