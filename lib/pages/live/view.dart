import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart'
    show VideoController, Video, AdaptiveVideoControls;

import '../../common/theme.dart';
import '../../services/live_service.dart';
import '../../widgets/video_player_pip.dart';
import 'controller.dart';

/// 直播主界面（对照参考图）
/// 上：视频区 + LIVE 角标 + 小窗/全屏
/// 下：播放源下拉 + 频道列表（TV 图标 + 状态）
class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  final _controller = Get.put(LiveController());
  Player? _player;
  VideoController? _videoController;
  bool _fullscreen = false;

  @override
  void dispose() {
    _player?.dispose();
    _player = null;
    _videoController = null;
    super.dispose();
  }

  void _playChannel(String url) {
    if (url.isEmpty) return;
    // 复用同一 Player，切台只 open 新地址，避免黑屏/闪断
    _player ??= Player(
      configuration: const PlayerConfiguration(title: '猫影直播'),
    );
    _videoController ??= VideoController(_player!);
    _player!.open(Media(url));
    setState(() {});
  }

  Future<void> _togglePip() async {
    final ch = _controller.currentChannel;
    final url = ch?.playUrl ?? '';
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择频道')),
      );
      return;
    }
    try {
      final supported = await VideoPlayerPip.instance.isIosPipSupported();
      if (!supported) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前设备不支持系统小窗（需真机 iOS）')),
        );
        return;
      }
      final pos = _player?.state.position ?? Duration.zero;
      if (_player?.state.playing == true) {
        _player?.pause();
      }
      final ok = await VideoPlayerPip.instance.enterIos(
        url: url,
        headers: null,
        position: pos,
        onStarted: () {
          try {
            _player?.pause();
          } catch (_) {}
        },
        onStopped: () {
          try {
            _player?.play();
          } catch (_) {}
        },
      );
      if (!ok) {
        try {
          _player?.play();
        } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('小窗启动失败')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('小窗失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: GetBuilder<LiveController>(
        builder: (c) {
          final groups = c.groups;
          final channels = c.channels;
          final current = c.currentChannel;
          return SafeArea(
            child: Column(
              children: [
                // 顶部：返回
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Get.back(),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppTheme.backgroundTertiary,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.arrow_back_ios_new,
                              color: AppTheme.textSecondary, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // 视频区
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Container(
                    color: Colors.black,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_videoController != null && current != null)
                          Video(
                            controller: _videoController!,
                            controls: AdaptiveVideoControls,
                          )
                        else
                          Center(
                            child: Icon(Icons.live_tv,
                                color: AppTheme.textTertiary, size: 56),
                          ),
                        // LIVE 角标
                        Positioned(
                          left: 12,
                          bottom: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('LIVE',
                                    style: TextStyle(
                                        color: AppTheme.textPrimary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1)),
                                SizedBox(width: 6),
                                _LiveDot(),
                              ],
                            ),
                          ),
                        ),
                        // 小窗 / 全屏
                        Positioned(
                          right: 12,
                          bottom: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                GestureDetector(
                                  onTap: () => _togglePip(),
                                  child: Icon(
                                      Icons.picture_in_picture_alt,
                                      color: AppTheme.textPrimary,
                                      size: 20),
                                ),
                                const SizedBox(width: 14),
                                GestureDetector(
                                  onTap: () {
                                    setState(() => _fullscreen = !_fullscreen);
                                  },
                                  child: Icon(
                                    _fullscreen
                                        ? Icons.fullscreen_exit
                                        : Icons.fullscreen,
                                    color: AppTheme.textPrimary,
                                    size: 22,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // 播放源下拉
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => _pickSource(context, c),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppTheme.backgroundTertiary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                groups.isEmpty
                                    ? '播放源'
                                    : groups[c.selectedGroup].name,
                                style: TextStyle(
                                    color: AppTheme.textSecondary, fontSize: 13),
                              ),
                              const SizedBox(width: 4),
                              Icon(Icons.keyboard_arrow_down,
                                  color: AppTheme.textTertiary, size: 16),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // 加载错误提示
                Obx(() {
                  final err = LiveService.instance.error.value;
                  if (err == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      err,
                      style: TextStyle(
                          color: Colors.redAccent.withValues(alpha: 0.9),
                          fontSize: 12),
                    ),
                  );
                }),
                // 频道列表
                Expanded(
                  child: groups.isEmpty
                      ? _EmptyLive(onReload: () => _pickSource(context, c))
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                          itemCount: channels.length,
                          separatorBuilder: (_, __) => Divider(
                              height: 1, color: AppTheme.borderLight),
                          itemBuilder: (_, i) {
                            final ch = channels[i];
                            final selected =
                                c.selectedChannelIndex.value == i;
                            return ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              title: Text(
                                ch.name,
                                style: TextStyle(
                                  color: selected
                                      ? AppTheme.accentColor
                                      : Colors.white,
                                  fontSize: 15,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                              subtitle: Text(
                                ch.urls.isNotEmpty ? '可播放' : '未下载',
                                style: TextStyle(
                                    color: AppTheme.textTertiary, fontSize: 11),
                              ),
                              trailing: Icon(Icons.live_tv,
                                  color: selected
                                      ? AppTheme.accentColor
                                      : Colors.white24,
                                  size: 22),
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
          );
        },
      ),
    );
  }

  Future<void> _pickSource(BuildContext context, LiveController c) async {
    final groups = c.groups;
    if (groups.isEmpty) {
      final url = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final ctrl = TextEditingController();
          return AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            title: Text('导入直播源',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 15)),
            content: TextField(
              controller: ctrl,
              style: TextStyle(color: AppTheme.textPrimary),
              decoration: InputDecoration(
                hintText: 'm3u / txt 地址',
                hintStyle: TextStyle(color: AppTheme.textTertiary),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                  child: const Text('加载')),
            ],
          );
        },
      );
      if (url != null && url.isNotEmpty) {
        await c.reloadFromUrl(url);
      }
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('播放源',
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 15)),
            ),
            for (var i = 0; i < groups.length; i++)
              ListTile(
                title: Text(groups[i].name,
                    style: TextStyle(color: AppTheme.textSecondary)),
                subtitle: Text('${groups[i].channels.length} 个频道',
                    style: TextStyle(
                        color: AppTheme.textTertiary, fontSize: 11)),
                trailing: c.selectedGroup == i
                    ? const Icon(Icons.check, color: AppTheme.accentColor)
                    : null,
                onTap: () {
                  c.selectGroup(i);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _LiveDot extends StatefulWidget {
  const _LiveDot();
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: Colors.redAccent,
          shape: BoxShape.circle,
        ),
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
          Icon(Icons.live_tv, color: AppTheme.textTertiary, size: 48),
          const SizedBox(height: 12),
          Text('暂无直播频道',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
          const SizedBox(height: 6),
          Text('在订阅 JSON 的 lives 配置，或导入 m3u',
              style: TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
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
