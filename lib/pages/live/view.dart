import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart'
    show VideoController, Video, AdaptiveVideoControls;

import '../../common/theme.dart';
import '../../models/live_models.dart';
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
  bool _showGroupChannels = false;
  int _activeGroupIndex = 0;

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
                // 顶部：返回 + LIVE + 右上（公告/投屏/全屏）—— 对齐参考图
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
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppTheme.backgroundTertiary,
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
                            const SizedBox(width: 6),
                            const _LiveDot(),
                          ],
                        ),
                      ),
                      const Spacer(),
                      _TopIcon(
                        icon: Icons.campaign,
                        onTap: () => _showAnnouncements(context),
                      ),
                      _TopIcon(
                        icon: Icons.cast,
                        onTap: () => ScaffoldMessenger.of(context)
                            .showSnackBar(
                                const SnackBar(content: Text('暂不支持投屏'))),
                      ),
                      _TopIcon(
                        icon: _fullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        onTap: _toggleFullscreen,
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
                        // 小窗（PiP）右下 —— 全屏已移到顶部，这里只留小窗
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
                            child: GestureDetector(
                              onTap: () => _togglePip(),
                              child: Icon(Icons.picture_in_picture_alt,
                                  color: AppTheme.textPrimary, size: 20),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // 下拉行：左=直播源选择（参考图 IMG_7748）、右=公告（IMG_7749）
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
                              Icon(Icons.live_tv,
                                  color: AppTheme.accentColor, size: 15),
                              const SizedBox(width: 6),
                              Text(
                                _currentSourceName(c),
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
                      const Spacer(),
                      GestureDetector(
                        onTap: () => _showAnnouncements(context),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppTheme.backgroundTertiary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.campaign,
                                  color: AppTheme.textSecondary, size: 15),
                              const SizedBox(width: 6),
                              Text('公告',
                                  style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 13)),
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
                // 列表区：先"分类（分组）列表"（参考图 IMG_7749），点分类进频道
                Expanded(
                  child: groups.isEmpty
                      ? _EmptyLive(onReload: () => _pickSource(context, c))
                      : _showGroupChannels
                          ? _buildChannelList(c, channels)
                          : _buildGroupList(c),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _pickSource(BuildContext context, LiveController c) async {
    final srcs = LiveService.instance.sources;
    if (srcs.isEmpty) {
      // 没有任何源：引导导入 m3u/txt
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
    // 多源列表（参考图 IMG_7748：绿色播放图标 + 名称 + 刚刚更新/未下载）
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('直播源',
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 15)),
            ),
            for (var i = 0; i < srcs.length; i++)
              ListTile(
                leading: Icon(Icons.play_circle_fill,
                    color: srcs[i].loaded
                        ? AppTheme.accentColor
                        : Colors.white24,
                    size: 22),
                title: Text(srcs[i].name,
                    style: TextStyle(color: AppTheme.textSecondary)),
                subtitle: Text(srcs[i].loaded ? '刚刚更新' : '未下载',
                    style: TextStyle(
                        color: srcs[i].loaded
                            ? AppTheme.accentColor.withValues(alpha: 0.8)
                            : AppTheme.textTertiary,
                        fontSize: 11)),
                trailing: srcs[i].loaded
                    ? const Icon(Icons.check, color: AppTheme.accentColor)
                    : null,
                onTap: () async {
                  Navigator.pop(ctx);
                  if (!srcs[i].loaded) {
                    await LiveService.instance.loadSource(i);
                  }
                  if (context.mounted) setState(() => _showGroupChannels = false);
                },
              ),
          ],
        ),
      ),
    );
  }

  String _currentSourceName(LiveController c) {
    final srcs = LiveService.instance.sources;
    if (srcs.isEmpty) {
      return c.groups.isEmpty ? '播放源' : c.groups[c.selectedGroup].name;
    }
    for (var i = 0; i < srcs.length; i++) {
      if (srcs[i].loaded) return srcs[i].name;
    }
    return srcs.first.name;
  }

  void _showAnnouncements(BuildContext context) {
    final list = LiveService.instance.announcements;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (ctx) => SafeArea(
        child: list.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text('暂无公告',
                    style: TextStyle(color: AppTheme.textTertiary, fontSize: 13)),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('公告',
                        style: TextStyle(
                            color: AppTheme.textPrimary, fontSize: 15)),
                  ),
                  for (final item in list)
                    ListTile(
                      dense: true,
                      leading: Icon(Icons.tv,
                          color: AppTheme.textSecondary, size: 20),
                      title: Text(item,
                          style: TextStyle(
                              color: AppTheme.textSecondary, fontSize: 13)),
                    ),
                ],
              ),
      ),
    );
  }

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      if (Platform.isIOS) {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      if (Platform.isIOS) {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Widget _buildGroupList(LiveController c) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: c.groups.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: AppTheme.borderLight),
      itemBuilder: (_, i) {
        final g = c.groups[i];
        final selected = c.selectedGroup == i;
        return ListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          leading: Icon(Icons.live_tv,
              color: selected ? AppTheme.accentColor : Colors.white24,
              size: 22),
          title: Text(g.name,
              style: TextStyle(
                color: selected ? AppTheme.accentColor : Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              )),
          subtitle: Text('${g.channels.length} 个频道',
              style: TextStyle(color: AppTheme.textTertiary, fontSize: 11)),
          trailing:
              Icon(Icons.chevron_right, color: AppTheme.textTertiary, size: 18),
          onTap: () {
            c.selectGroup(i);
            setState(() {
              _activeGroupIndex = i;
              _showGroupChannels = true;
            });
          },
        );
      },
    );
  }

  Widget _buildChannelList(LiveController c, List<LiveChannel> channels) {
    return Column(
      children: [
        // 返回分类
        InkWell(
          onTap: () => setState(() => _showGroupChannels = false),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.arrow_back_ios_new,
                    color: AppTheme.textSecondary, size: 14),
                const SizedBox(width: 6),
                Text(
                  _activeGroupIndex >= 0 && _activeGroupIndex < c.groups.length
                      ? c.groups[_activeGroupIndex].name
                      : '分类',
                  style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: AppTheme.borderLight),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            itemCount: channels.length,
            separatorBuilder: (_, __) =>
                Divider(height: 1, color: AppTheme.borderLight),
            itemBuilder: (_, i) {
              final ch = channels[i];
              final selected = c.selectedChannelIndex.value == i;
              return ListTile(
                dense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                title: Text(ch.name,
                    style: TextStyle(
                      color: selected ? AppTheme.accentColor : Colors.white,
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    )),
                subtitle: Text(ch.urls.isNotEmpty ? '可播放' : '未下载',
                    style:
                        TextStyle(color: AppTheme.textTertiary, fontSize: 11)),
                trailing: Icon(Icons.live_tv,
                    color: selected ? AppTheme.accentColor : Colors.white24,
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

class _TopIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _TopIcon({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: AppTheme.backgroundTertiary,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: AppTheme.textSecondary, size: 18),
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
