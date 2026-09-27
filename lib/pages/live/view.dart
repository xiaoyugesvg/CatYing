import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' show VideoController, Video, AdaptiveVideoControls;

import '../../common/theme.dart';
import '../../services/live_service.dart';
import 'controller.dart';

/// 直播页：左分组 + 右频道列表 + 上方播放器
class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  final _controller = Get.put(LiveController());
  Player? _player;
  VideoController? _videoController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (LiveService.instance.channels.isEmpty) {
        // 若配置里已有 lives 可在进页前 loadFromLivesJson
      }
    });
  }

  @override
  void dispose() {
    _player?.dispose();
    _player = null;
    _videoController = null;
    super.dispose();
  }

  void _playChannel(String url) {
    if (url.isEmpty) return;
    _player?.dispose();
    _player = Player(
      configuration: const PlayerConfiguration(title: '猫影直播'),
    );
    _videoController = VideoController(_player!);
    _player!.open(Media(url));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.chevron_left, color: Colors.white, size: 28),
          onPressed: () => Get.back(),
        ),
        title: const Text('直播', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: GetBuilder<LiveController>(
        builder: (c) {
          final groups = c.groups;
          if (LiveService.instance.isLoading.value) {
            return const Center(child: CircularProgressIndicator());
          }
          if (groups.isEmpty) {
            return _EmptyLive(onReload: () async {
              // 无数据时提示配置 lives 或 m3u URL
              final url = await _askUrl(context);
              if (url != null && url.isNotEmpty) {
                await c.reloadFromUrl(url);
              }
            });
          }
          final channels = c.channels;
          final current = c.currentChannel;
          return Column(
            children: [
              // 播放区
              SizedBox(
                height: 220,
                child: Container(
                  color: Colors.black,
                  child: _videoController != null && current != null
                      ? Video(
                          controller: _videoController!,
                          controls: AdaptiveVideoControls,
                        )
                      : const Center(
                          child: Text('选择频道开始播放',
                              style: TextStyle(color: Colors.white54)),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              // 搜索
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextField(
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: '搜索频道...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    prefixIcon:
                        const Icon(Icons.search, color: Colors.white38, size: 18),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (v) {
                    c.searchKeyword.value = v;
                    c.update();
                  },
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Row(
                  children: [
                    // 分组
                    SizedBox(
                      width: 100,
                      child: ListView.builder(
                        itemCount: groups.length,
                        itemBuilder: (_, i) {
                          final selected = c.selectedGroup == i;
                          return GestureDetector(
                            onTap: () => c.selectGroup(i),
                            child: Container(
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              decoration: BoxDecoration(
                                color: selected
                                    ? AppTheme.accentColor
                                        .withValues(alpha: 0.16)
                                    : Colors.transparent,
                                border: Border(
                                  left: BorderSide(
                                    color: selected
                                        ? AppTheme.accentColor
                                        : Colors.transparent,
                                    width: 3,
                                  ),
                                ),
                              ),
                              child: Text(
                                groups[i].name,
                                maxLines: 2,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: selected
                                      ? AppTheme.accentColor
                                      : Colors.white70,
                                  fontSize: 12,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    VerticalDivider(color: Colors.white.withValues(alpha: 0.08)),
                    // 频道
                    Expanded(
                      child: ListView.builder(
                        itemCount: channels.length,
                        itemBuilder: (_, i) {
                          final ch = channels[i];
                          final selected = c.selectedChannelIndex.value == i;
                          return ListTile(
                            dense: true,
                            selected: selected,
                            selectedTileColor:
                                AppTheme.accentColor.withValues(alpha: 0.12),
                            leading: const Icon(Icons.live_tv,
                                color: Colors.white54, size: 18),
                            title: Text(
                              ch.name,
                              style: TextStyle(
                                color: selected
                                    ? AppTheme.accentColor
                                    : Colors.white,
                                fontSize: 13,
                              ),
                            ),
                            onTap: () {
                              c.selectChannel(i);
                              _playChannel(ch.playUrl);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<String?> _askUrl(BuildContext context) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text('加载直播源',
            style: TextStyle(color: Colors.white, fontSize: 15)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'm3u / txt 地址',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('加载'),
          ),
        ],
      ),
    );
  }
}

class _EmptyLive extends StatelessWidget {
  final VoidCallback onReload;
  const _EmptyLive({required this.onReload});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.live_tv, color: Colors.white24, size: 48),
          const SizedBox(height: 12),
          const Text('暂无直播频道',
              style: TextStyle(color: Colors.white54, fontSize: 14)),
          const SizedBox(height: 6),
          const Text('在订阅 JSON 的 lives 里配置，或手动导入 m3u',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: onReload,
            child: const Text('导入直播源',
                style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }
}
