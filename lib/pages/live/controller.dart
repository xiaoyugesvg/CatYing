import 'dart:async';
import 'dart:convert';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/live_models.dart';
import '../../services/api_config.dart';
import '../../services/network_manager.dart';

class LiveController extends GetxController {
  final channelGroups = <LiveChannelGroup>[].obs;
  final selectedGroupIndex = 0.obs;
  final selectedChannelIndex = 0.obs;
  final currentChannel = Rx<LiveChannelItem?>(null);
  final epgList = <Epginfo>[].obs;
  final isLoading = false.obs;
  final showChannelList = false.obs;

  /// 自定义直播源列表 [{name, url}]，本地持久化（SharedPreferences）
  /// 用户可在直播页自行添加 m3u / txt / json 直播源链接，
  /// 与订阅接口返回的 lives 合并展示。对应 tvbox-Swift / TVBox-tvs 的
  /// "自己添加直播源"能力。
  final customLiveSources = <Map<String, String>>[].obs;

  /// 自定义直播源持久化 key
  static const _customLiveSourcesKey = 'custom_live_sources';

  /// 直播页是否可见（由 ContentView tab 切换驱动）：
  /// 不可见时自动 pause 播放器，避免在 IndexedStack 中
  /// 切到其他 tab 后声音还在后台播放的问题。
  final isLivePageVisible = true.obs;

  /// 直播播放器（懒创建）：抽到 controller 持有，
  /// 便于在页面不可见时主动 pause / 切回时 resume，
  /// 而不必重建 VideoPlayerWidget。
  Player? _player;
  Player get player {
    _player ??= Player(configuration: const PlayerConfiguration(title: 'TVBox Live'));
    return _player!;
  }

  StreamSubscription? _channelGroupsSubscription;

  @override
  void onInit() {
    super.onInit();
    bindLiveChannelGroups();
    _loadCustomLiveSources();
  }

  @override
  void onClose() {
    _channelGroupsSubscription?.cancel();
    // 释放 player
    try {
      _player?.dispose();
    } catch (_) {}
    _player = null;
    super.onClose();
  }

  /// 暂停直播播放（不释放 player，保留播放位置）
  void pausePlayback() {
    try {
      _player?.pause();
    } catch (_) {}
  }

  /// 恢复直播播放
  void resumePlayback() {
    try {
      if (_player != null && currentChannel.value != null) {
        _player?.play();
      }
    } catch (_) {}
  }

  // ============================================================
  // 自定义直播源（本地持久化 + 合并加载）
  // ============================================================

  /// 从 SharedPreferences 读取自定义直播源
  Future<void> _loadCustomLiveSources() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_customLiveSourcesKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        final list = <Map<String, String>>[];
        for (final e in decoded) {
          if (e is Map) {
            final name = (e['name'] ?? '').toString().trim();
            final url = (e['url'] ?? '').toString().trim();
            if (url.isNotEmpty) {
              list.add({
                'name': name.isEmpty ? url : name,
                'url': url,
              });
            }
          }
        }
        customLiveSources.value = list;
      }
    } catch (_) {}
  }

  /// 持久化自定义直播源
  Future<void> _persistCustomLiveSources() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _customLiveSourcesKey,
        jsonEncode(customLiveSources.value),
      );
    } catch (_) {}
  }

  /// 添加自定义直播源（m3u / txt / json 链接），保存后立即加载合并
  Future<void> addCustomLiveSource({
    required String name,
    required String url,
  }) async {
    final normalizedUrl = ApiConfig.normalizeConfigUrl(url.trim());
    if (normalizedUrl.isEmpty) return;

    final trimmedName = name.trim();
    customLiveSources.add({
      'name': trimmedName.isEmpty ? normalizedUrl : trimmedName,
      'url': normalizedUrl,
    });
    await _persistCustomLiveSources();
    await loadChannels();
  }

  /// 删除自定义直播源，保存后重新加载合并
  Future<void> removeCustomLiveSource(int index) async {
    if (index < 0 || index >= customLiveSources.length) return;
    customLiveSources.removeAt(index);
    await _persistCustomLiveSources();
    await loadChannels();
  }

  /// 加载频道：订阅源（ApiConfig.liveChannelGroupList）+ 自定义源（本地）合并
  /// 订阅源由 ApiConfig 解析配置 lives 字段（name/type/url）后远程加载
  /// M3U / TXT / JSON 并分组；自定义源同样支持三种格式。
  Future<void> loadChannels() async {
    var groups = <LiveChannelGroup>[];
    // 1) 订阅源
    groups.addAll(ApiConfig.instance.liveChannelGroupList.toList());
    // 2) 自定义源：逐个远程拉取并解析，按分组名合并
    for (final source in customLiveSources.value) {
      final url = source['url'] ?? '';
      if (url.isEmpty) continue;
      try {
        final content = await NetworkManager.instance.getString(url);
        if (content.trim().isEmpty) continue;
        final parsed = ApiConfig.instance.parseLiveContent(content);
        groups = _mergeGroups(groups, parsed);
      } catch (e) {
        print('[LiveController] 自定义直播源加载失败: $url, error: $e');
      }
    }
    applyChannelGroups(groups);
  }

  /// 按分组名合并两组频道（保留 base 顺序，同名组合并频道）
  List<LiveChannelGroup> _mergeGroups(
    List<LiveChannelGroup> base,
    List<LiveChannelGroup> incoming,
  ) {
    final byName = <String, LiveChannelGroup>{};
    for (final g in base) {
      byName[g.groupName] = LiveChannelGroup(
        groupName: g.groupName,
        groupIndex: byName.length,
        channels: List.of(g.channels),
      );
    }
    for (final g in incoming) {
      final existing = byName[g.groupName];
      if (existing == null) {
        byName[g.groupName] = LiveChannelGroup(
          groupName: g.groupName,
          groupIndex: byName.length,
          channels: [],
        );
      }
      for (final ch in g.channels) {
        byName[g.groupName]!.channels.add(ch);
      }
    }
    final result = byName.values.toList()
      ..sort((a, b) => a.groupIndex.compareTo(b.groupIndex));
    // 重建 channelIndex
    for (var i = 0; i < result.length; i++) {
      for (var j = 0; j < result[i].channels.length; j++) {
        result[i].channels[j].channelIndex = j;
      }
    }
    return result;
  }

  void selectGroup(int index) {
    if (index < 0 || index >= channelGroups.length) return;
    selectedGroupIndex.value = index;
    selectedChannelIndex.value = 0;
    final channels = channelGroups[index].channels;
    if (channels.isNotEmpty) {
      selectChannel(channels.first);
    }
  }

  void selectChannel(LiveChannelItem channel) {
    currentChannel.value = channel;
    // 切换频道时主动 open media 到 player，避免 LivePage 还没 build 时
    // video_player 内部还是用上一个 url。
    final url = channel.currentUrl;
    if (url != null && url.isNotEmpty) {
      try {
        player.open(Media(url!));
      } catch (_) {}
    }
    _loadEPG(channel);
  }

  void previousChannel() {
    if (channelGroups.isEmpty) return;
    if (selectedChannelIndex.value > 0) {
      selectedChannelIndex.value--;
    } else if (selectedGroupIndex.value > 0) {
      selectedGroupIndex.value--;
      final group = channelGroups[selectedGroupIndex.value];
      selectedChannelIndex.value = group.channels.length - 1;
    }
    final channels = currentChannels;
    if (selectedChannelIndex.value < channels.length) {
      selectChannel(channels[selectedChannelIndex.value]);
    }
  }

  void nextChannel() {
    if (channelGroups.isEmpty) return;
    final group = channelGroups[selectedGroupIndex.value];
    if (selectedChannelIndex.value < group.channels.length - 1) {
      selectedChannelIndex.value++;
    } else if (selectedGroupIndex.value < channelGroups.length - 1) {
      selectedGroupIndex.value++;
      selectedChannelIndex.value = 0;
    }
    final channels = currentChannels;
    if (selectedChannelIndex.value < channels.length) {
      selectChannel(channels[selectedChannelIndex.value]);
    }
  }

  void switchSource() {
    currentChannel.value?.nextSource();
    // 触发 Obx 刷新 - 重新赋值
    currentChannel.refresh();
  }

  List<LiveChannelItem> get currentChannels {
    if (selectedGroupIndex.value < channelGroups.length) {
      return channelGroups[selectedGroupIndex.value].channels;
    }
    return [];
  }

  void _loadEPG(LiveChannelItem channel) {
    // 预留：后续可在此按频道名/频道 ID 请求远程 EPG。
    // 当前版本先清空，避免展示过期节目单。
    epgList.clear();
  }

  void bindLiveChannelGroups() {
    _channelGroupsSubscription?.cancel();
    _channelGroupsSubscription =
        ApiConfig.instance.liveChannelGroupList.listen((groups) {
      applyChannelGroups(groups);
    });
  }

  void applyChannelGroups(List<LiveChannelGroup> groups) {
    final previousChannelId = currentChannel.value?.id;
    channelGroups.value = groups;

    if (groups.isEmpty) {
      selectedGroupIndex.value = 0;
      selectedChannelIndex.value = 0;
      currentChannel.value = null;
      return;
    }

    if (previousChannelId != null) {
      final located = _locateChannel(
        channelId: previousChannelId,
        groups: groups,
      );
      if (located != null) {
        selectedGroupIndex.value = located.$1;
        selectedChannelIndex.value = located.$2;
        currentChannel.value = groups[located.$1].channels[located.$2];
        return;
      }
    }

    final clampedGroupIndex =
        selectedGroupIndex.value.clamp(0, groups.length - 1);
    selectedGroupIndex.value = clampedGroupIndex;

    final channels = groups[clampedGroupIndex].channels;
    if (channels.isEmpty) {
      selectedChannelIndex.value = 0;
      currentChannel.value = null;
      return;
    }

    final clampedChannelIndex =
        selectedChannelIndex.value.clamp(0, channels.length - 1);
    selectedChannelIndex.value = clampedChannelIndex;
    currentChannel.value = channels[clampedChannelIndex];
  }

  (int, int)? _locateChannel({
    required String channelId,
    required List<LiveChannelGroup> groups,
  }) {
    for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
      final group = groups[groupIndex];
      for (var channelIndex = 0;
          channelIndex < group.channels.length;
          channelIndex++) {
        if (group.channels[channelIndex].id == channelId) {
          return (groupIndex, channelIndex);
        }
      }
    }
    return null;
  }
}
