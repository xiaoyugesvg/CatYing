import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../common/api_config.dart';
import '../../models/video_item.dart';
import '../../services/history_service.dart';
import '../../services/player_service.dart';
import '../../services/video_service.dart';
import '../../services/vod_service.dart';
import '../../widgets/glass.dart';
import '../../widgets/video_player.dart';
import '../../widgets/video_player_pip.dart';
import '../../widgets/live_av_player.dart';
import '../../widgets/loading.dart';
import '../../widgets/network_image.dart';
import '../../widgets/source_switch_sheet.dart';
import 'controller.dart';
import 'widgets/episode_list_view.dart';
import 'widgets/intro_card.dart';
import 'widgets/action_bar.dart';
import 'widgets/play_sources_panel.dart';
import 'widgets/live_tab.dart';
import 'widgets/info_section.dart';

class DetailPage extends GetView<DetailController> {
  const DetailPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 修复：GetX 全局 controller 与多 tab 复用时强刷重建导致的"进详情像重启"
    // （页面闪白 / 状态丢失）。不再使用 force: true 强制重建。
    final _controller = Get.put(DetailController(), tag: 'detail');
    controller.onInit();

    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: Obx(() {
        final loading = controller.isLoading.value;
        if (loading && controller.video == null) {
          return const Center(
            child: AppLoading(),
          );
        }
        return _DetailBody(controller: controller);
      }),
    );
  }
}

class _DetailBody extends StatelessWidget {
  final DetailController controller;
  const _DetailBody({required this.controller});

  @override
  Widget build(BuildContext context) {
    final video = controller.video!;
    final isLive = controller.isLive;
    final isAudio = controller.isAudio;
    return Stack(
      children: [
        // 主内容滚动区 - 顶部空出底部悬浮导航栏的高度
        Positioned.fill(
          bottom: 0,
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              // 上滑到接近底部时自动加载下一集（仅点播）
              if (!isLive && !isAudio && controller.episodes.length > 1) {
                if (notification.metrics.pixels >=
                    notification.metrics.maxScrollExtent - 240) {
                  final next = controller.selectedIndex.value + 1;
                  if (next < controller.episodes.length) {
                    controller.selectEpisode(next);
                  }
                }
              }
              return false;
            },
            child: SingleChildScrollView(
              controller: controller.scrollController,
              padding: EdgeInsets.only(
                bottom: controller.bottomNavReserve +
                    MediaQuery.of(context).padding.bottom +
                    12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ========== 播放器区域 ==========
                  _buildPlayerSection(context),
                  // ========== 信息区 ==========
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isLive) ...[
                          LiveTab(controller: controller),
                          const SizedBox(height: 12),
                          InfoSection(controller: controller),
                        ] else ...[
                          ActionBar(controller: controller),
                          const SizedBox(height: 6),
                          IntroCard(controller: controller),
                          const SizedBox(height: 10),
                          if (controller.sources.isNotEmpty) ...[
                            PlaySourcesPanel(controller: controller),
                            const SizedBox(height: 10),
                          ],
                          if (controller.episodes.isNotEmpty) ...[
                            EpisodeListView(controller: controller),
                            const SizedBox(height: 8),
                          ],
                          InfoSection(controller: controller),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // ========== 底部悬浮导航栏（透明无框，不遮挡内容） ==========
        Align(
          alignment: Alignment.bottomCenter,
          child: GlassPanel(
            // 彻底去掉玻璃面板的"框/背景"：完全透明，图标文字直接浮于内容上方
            tint: Colors.transparent,
            borderColor: Colors.transparent,
            borderWidth: 0,
            borderRadius: 0,
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).padding.bottom + 6,
              top: 8,
              left: 12,
              right: 12,
            ),
            child: _buildBottomNav(context),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // 播放器区域
  // ============================================================

  Widget _buildPlayerSection(BuildContext context) {
    final isLive = controller.isLive;
    final isAudio = controller.isAudio;
    final mediaPadding = MediaQuery.of(context).padding;
    final navReserve = controller.bottomNavReserve;

    if (isAudio) {
      // 音频：独立音频播放页（听书/听剧），无视频画面
      return AudioPlayerSection(controller: controller);
    }

    if (isLive) {
      // 直播：iOS 用原生 AVPlayer 内核（LiveAVPlayer），其他平台用 MPV
      final liveUrl = controller.currentPlayUrl ?? controller.url;
      final hasLive = liveUrl.isNotEmpty;
      return Column(
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Stack(
              children: [
                if (hasLive)
                  Obx(() {
                    final u = controller.currentPlayUrl ?? controller.url;
                    if (u.isEmpty) return const SizedBox.shrink();
                    if (Platform.isIOS) {
                      return LiveAVPlayer(
                        key: ValueKey('live-av-$u'),
                        url: u,
                        headers: controller.currentHeaders,
                        onError: () {
                          controller.onLivePlayError();
                        },
                        autoPlay: true,
                      );
                    }
                    return VideoPlayerWidget(
                      key: ValueKey('live-mpv-$u'),
                      url: u,
                      headers: controller.currentHeaders,
                      videoTitle: controller.video?.vodName ?? '',
                      showAudioModeButton: false,
                      autoPlay: true,
                    );
                  })
                else
                  const Center(
                    child: Text(
                      '暂无直播地址',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      );
    }

    // 点播
    final url = controller.currentPlayUrl ?? controller.url;
    final episodeName = controller.selectedEpisodeName;
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (url.isNotEmpty)
                Obx(() {
                  final u = controller.currentPlayUrl ?? controller.url;
                  if (u.isEmpty) return const SizedBox.shrink();
                  final isFullScreen = controller.isFullScreen.value;
                  return VideoPlayerWidget(
                    key: ValueKey('detail-player-$u-$isFullScreen'),
                    player: controller.player,
                    controller: controller.videoController,
                    url: u,
                    headers: controller.currentHeaders,
                    resumeSeconds: controller.resumeSeconds,
                    videoTitle: controller.video?.vodName ?? '',
                    currentEpisodeName: episodeName,
                    episodeNames: controller.episodeNames,
                    selectedEpisodeIndex: controller.selectedIndex.value,
                    canPlayNext:
                        controller.selectedIndex.value <
                            controller.episodes.length - 1,
                    canPlayPrevious: controller.selectedIndex.value > 0,
                    showAudioModeButton: true,
                    // 详情页默认 cover 铺满：16:9 视频填满 4:3 黑框，
                    // 画面与黑框完全一致，不再上下留黑边
                    initialVideoFit: VideoFitType.cover,
                    skipIntroSeconds: controller.skipIntroSeconds,
                    skipOutroSeconds: controller.skipOutroSeconds,
                    onPlaying: () {},
                    onPositionChanged: controller.onPositionChanged,
                    onEnded: controller.onVideoEnded,
                    onError: controller.onVideoError,
                    onFullScreenChanged: (v) {
                      controller.isFullScreen.value = v;
                    },
                    onPlayNext: controller.playNext,
                    onPlayPrevious: controller.playPrevious,
                    onSelectEpisode: controller.selectEpisode,
                    onBack: () {
                      Get.back();
                    },
                    onSetSkipIntro: controller.setSkipIntro,
                    onSetSkipOutro: controller.setSkipOutro,
                  );
                })
              else
                const Center(
                  child: Text(
                    '加载中…',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  // ============================================================
  // 底部悬浮导航栏
  // ============================================================

  Widget _buildBottomNav(BuildContext context) {
    final navItems = controller.navItems;
    return Row(
      children: navItems.map((item) {
        final selected = controller.currentTab.value == item.id;
        final icon = selected ? item.selectedIcon : item.icon;
        final label = item.label;
        return Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              controller.onNavTap(item.id);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  color: selected
                      ? AppTheme.accentColor
                      : Colors.white.withValues(alpha: 0.7),
                  size: 22,
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    color: selected
                        ? AppTheme.accentColor
                        : Colors.white.withValues(alpha: 0.7),
                    fontSize: 10,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}