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
  bool _audioMode = false;
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
          final currentSourceName = c.currentSourceName;
          final currentGroupName = c.currentGroupName;
          final sources = c.sources;
          if (_fullscreen) {
            return _buildFullscreen(context, c, current);
          }
          return SafeArea(
            child: Column(
              children: [
                // 顶部导航：返回 + LIVE + 公告
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
                      // 公告（页面级功能，保留在外层顶栏）
                      _TopIcon(
                        icon: Icons.campaign,
                        onTap: () => _showAnnouncements(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // 视频播放区
                _buildVideoArea(c, current),
                // 加载错误提示
                Obx(() {
                  final err = LiveService.instance.error.value;
                  if (err == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Text(
                      err,
                      style: TextStyle(
                          color: Colors.redAccent.withValues(alpha: 0.9),
                          fontSize: 12),
                    ),
                  );
                }),
                const SizedBox(height: 8),
                // 双层选择器：直播源 + 分组
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      // 刷新按钮
                      GestureDetector(
                        onTap: _onRefreshSource,
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: AppTheme.backgroundTertiary,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.refresh,
                              color: AppTheme.textSecondary, size: 18),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 直播源选择（左下拉）
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _showSourcePicker(context, c),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 9),
                            decoration: BoxDecoration(
                              color: AppTheme.backgroundTertiary,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: AppTheme.accentColor.withValues(alpha: 0.3),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.rss_feed,
                                    color: AppTheme.accentColor, size: 16),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    currentSourceName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: AppTheme.accentColor,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Icon(Icons.arrow_drop_down,
                                    color: AppTheme.textSecondary, size: 18),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 分组选择（右下拉）
                      Expanded(
                        child: GestureDetector(
                          onTap: groups.isEmpty
                              ? null
                              : () => _showGroupPicker(context, c, groups),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 9),
                            decoration: BoxDecoration(
                              color: AppTheme.backgroundTertiary,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.playlist_play,
                                    color: AppTheme.textSecondary, size: 16),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    currentGroupName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                Icon(Icons.arrow_drop_down,
                                    color: AppTheme.textSecondary, size: 18),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                // 频道列表（占满宽度）
                Expanded(
                  child: groups.isEmpty
                      ? _EmptyLive(onReload: () => _pickSource(context, c))
                      : _buildChannelList(c, channels),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _pickSource(BuildContext context, LiveController c) async {
    // 导入/覆盖直播源（m3u/txt URL）——左栏底部 + 号进入
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
      if (mounted) c.selectGroup(0);
    }
  }

  void _toggleAudioMode() {
    setState(() => _audioMode = !_audioMode);
    // 进入听剧时保持播放（后台可续播由 UIBackgroundModes=audio 保证）
  }

  /// 全屏：只显示视频画面（横屏铺满），左上返回、右上频道名+退出全屏
  Widget _buildFullscreen(
      BuildContext context, LiveController c, LiveChannel? current) {
    final pad = MediaQuery.of(context).padding;
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_audioMode)
            _buildAudioModeOverlay(c, current)
          else if (_videoController != null && current != null)
            Video(
              controller: _videoController!,
              controls: AdaptiveVideoControls,
            )
          else
            Center(
              child: Icon(Icons.live_tv,
                  color: AppTheme.textTertiary, size: 56),
            ),
          // 左上：返回（对齐点播播放器顶栏）
          Positioned(
            top: 8 + pad.top,
            left: 8 + pad.left,
            child: GestureDetector(
              onTap: () {
                _toggleFullscreen();
                Get.back();
              },
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                child: const Icon(Icons.arrow_back_ios_new,
                    color: Colors.white, size: 20),
              ),
            ),
          ),
          // 右上：功能按钮（听剧/小窗/投屏/退出全屏）—— 与点播播放器顶栏对齐
          Positioned(
            top: 8 + pad.top,
            right: 8 + pad.right,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (current != null)
                  Container(
                    constraints: const BoxConstraints(maxWidth: 150),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    child: Text(
                      current.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontFamily: 'monospace'),
                    ),
                  ),
                _VideoTopIcon(
                  icon: _audioMode
                      ? Icons.headphones
                      : Icons.headphones_outlined,
                  onTap: _toggleAudioMode,
                ),
                _VideoTopIcon(
                  icon: Icons.picture_in_picture_alt,
                  onTap: _togglePip,
                ),
                _VideoTopIcon(
                  icon: Icons.cast,
                  onTap: () => ScaffoldMessenger.of(context)
                      .showSnackBar(
                          const SnackBar(content: Text('暂不支持投屏'))),
                ),
                _VideoTopIcon(
                  icon: Icons.fullscreen_exit,
                  onTap: _toggleFullscreen,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoArea(LiveController c, LiveChannel? current) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_audioMode)
              _buildAudioModeOverlay(c, current)
            else if (_videoController != null && current != null)
              Video(
                controller: _videoController!,
                controls: AdaptiveVideoControls,
              )
            else
              Center(
                child: Icon(Icons.live_tv,
                    color: AppTheme.textTertiary, size: 56),
              ),
            // 顶部渐变遮罩 + 功能按钮（与点播播放器顶栏风格一致）
            // 左上：LIVE 角标
            Positioned(
              top: 10,
              left: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('LIVE',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5)),
                    const SizedBox(width: 5),
                    const _LiveDot(size: 7),
                  ],
                ),
              ),
            ),
            // 右上：功能按钮（听剧/小窗/投屏/全屏）—— 与点播播放器顶栏对齐
            Positioned(
              top: 6,
              right: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _VideoTopIcon(
                    icon: _audioMode
                        ? Icons.headphones
                        : Icons.headphones_outlined,
                    onTap: _toggleAudioMode,
                    tooltip: '听剧模式',
                  ),
                  _VideoTopIcon(
                    icon: Icons.picture_in_picture_alt,
                    onTap: _togglePip,
                    tooltip: '小窗播放',
                  ),
                  _VideoTopIcon(
                    icon: Icons.cast,
                    onTap: () => ScaffoldMessenger.of(context)
                        .showSnackBar(
                            const SnackBar(content: Text('暂不支持投屏'))),
                    tooltip: '投屏',
                  ),
                  _VideoTopIcon(
                    icon: _fullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    onTap: _toggleFullscreen,
                    tooltip: _fullscreen ? '退出全屏' : '全屏',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioModeOverlay(LiveController c, LiveChannel? current) {
    final name = current?.name ?? '';
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.headphones, color: Colors.white70, size: 44),
            const SizedBox(height: 16),
            if (name.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(height: 6),
            Text(
              '听剧模式 · 后台可继续播放',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5), fontSize: 11),
            ),
            const SizedBox(height: 18),
            GestureDetector(
              onTap: _toggleAudioMode,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text('退出听剧模式',
                    style: TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 左栏：直播源列表（参考图：一侧是直播源）——绿点=已加载，灰点=未下载
  /// 刷新当前直播源
  void _onRefreshSource() {
    final c = _controller;
    if (c.sources.isEmpty) {
      _pickSource(context, c);
      return;
    }
    // 刷新当前选中的源
    final index = c.selectedSourceIndex;
    if (index >= 0 && index < c.sources.length) {
      c.selectSource(index);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('正在刷新直播源...'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  /// 显示直播源选择弹窗
  Future<void> _showSourcePicker(
      BuildContext context, LiveController c) async {
    final srcs = LiveService.instance.sources;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundTertiary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Text('选择直播源',
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _pickSource(context, c);
                      },
                      child: const Text('添加源'),
                    ),
                  ],
                ),
              ),
              // 源列表
              if (srcs.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('还没有直播源，点击右上角添加',
                      style: TextStyle(
                          color: AppTheme.textTertiary, fontSize: 13)),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: srcs.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: AppTheme.borderLight),
                    itemBuilder: (_, i) {
                      final src = srcs[i];
                      final isActive = c.selectedSourceIndex == i;
                      return ListTile(
                        dense: true,
                        leading: Icon(Icons.play_circle_fill,
                            color: isActive
                                ? AppTheme.accentColor
                                : AppTheme.textTertiary,
                            size: 22),
                        title: Text(src.name,
                            style: TextStyle(
                                color: isActive
                                    ? AppTheme.accentColor
                                    : AppTheme.textPrimary,
                                fontSize: 14)),
                        subtitle: Text(
                            isActive ? '当前播放' : '未下载',
                            style: TextStyle(
                                color: isActive
                                    ? AppTheme.accentColor
                                        .withValues(alpha: 0.7)
                                    : AppTheme.textTertiary,
                                fontSize: 11)),
                        trailing: isActive
                            ? Icon(Icons.check_circle,
                                color: AppTheme.accentColor, size: 20)
                            : null,
                        onTap: () async {
                          Navigator.pop(ctx);
                          await c.selectSource(i);
                        },
                      );
                    },
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 显示分组选择弹窗
  Future<void> _showGroupPicker(
      BuildContext context, LiveController c, List<LiveGroup> groups) async {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundTertiary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('选择分组',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: groups.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: AppTheme.borderLight),
                  itemBuilder: (_, i) {
                    final g = groups[i];
                    final selected = c.selectedGroup == i;
                    return ListTile(
                      dense: true,
                      leading: Icon(Icons.playlist_play,
                          color: selected
                              ? AppTheme.accentColor
                              : AppTheme.textTertiary,
                          size: 22),
                      title: Text(g.name,
                          style: TextStyle(
                              color: selected
                                  ? AppTheme.accentColor
                                  : AppTheme.textPrimary,
                              fontSize: 14)),
                      subtitle: Text('${g.channels.length} 个频道',
                          style: TextStyle(
                              color: AppTheme.textTertiary, fontSize: 11)),
                      trailing: selected
                          ? Icon(Icons.check_circle,
                              color: AppTheme.accentColor, size: 20)
                          : null,
                      onTap: () {
                        Navigator.pop(ctx);
                        c.selectGroup(i);
                        setState(() => _activeGroupIndex = i);
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
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
        ]);
      }
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Widget _buildChannelList(LiveController c, List<LiveChannel> channels) {
    if (channels.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tv_off,
                color: AppTheme.textTertiary, size: 48),
            const SizedBox(height: 12),
            Text('该分组暂无频道',
                style: TextStyle(
                    color: AppTheme.textSecondary, fontSize: 13)),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
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
          trailing: Icon(Icons.play_circle_fill,
              color: selected ? AppTheme.accentColor : Colors.white24,
              size: 22),
          onTap: () {
            c.selectChannel(i);
            _playChannel(ch.playUrl);
          },
        );
      },
    );
  }
}

class _LiveDot extends StatefulWidget {
  final double size;
  const _LiveDot({this.size = 8});
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
        width: widget.size,
        height: widget.size,
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

/// 视频画面上的顶栏功能按钮（半透明黑底 + 白色图标，与点播播放器风格一致）
class _VideoTopIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final double size;
  const _VideoTopIcon({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      preferBelow: false,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          child: Icon(icon, color: Colors.white, size: size),
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
