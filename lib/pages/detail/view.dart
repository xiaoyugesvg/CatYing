import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../models/vod_info.dart';
import '../../models/video.dart';
import '../../models/cache_store.dart';
import '../../services/source_service.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/glass.dart';
import '../../services/player_fullscreen_controller.dart';
import '../../services/main_tab_controller.dart';
import 'controller.dart';
import 'episode_list.dart';

/// 视频详情页 - 对应 Swift DetailView
/// **2026-09-26 布局重组**：
/// - 进详情即渲染播放器区域（URL 未就绪时显示 16:9 加载占位，解析完自动出画面）
/// - 收藏按钮缩为 36px 小图标，前置在视频名称前
/// - 影片简介并入名称同一卡片，3 行收起 / 点击展开全文
/// - 底部悬浮导航栏改超浅玻璃底（沉浸式，与根底栏一致）
class DetailPage extends StatefulWidget {
  const DetailPage({super.key});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  /// 每次进入详情页强制重建 controller：
  /// Get.put 默认会复用已存在的同名实例，导致第二次进入时残留上次的
  /// vodInfo/isPlaying/playUrl，表现为"进详情页像重启/显示旧视频"。
  /// force: true 确保每次进入都是全新实例、重新加载当前视频。
  final _controller = Get.put(DetailController(), force: true);

  // 视频信息已载入后是否处于"播放中"（仅用于 UI 显示播放按钮的状态）
  bool _isPlaying = false;

  /// 简介展开状态（收起 3 行 / 展开全文）
  bool _isDescriptionExpanded = false;

  @override
  void initState() {
    super.initState();
    _loadDetailIfNeeded();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _loadDetailIfNeeded() {
    final video = Get.arguments;
    if (video != null && video is Video) {
      _controller.loadDetail(video).then((_) {
        // 有历史则恢复续播；无历史则直接自动播放当前选集第一集
        final restored = _restorePlaybackFromHistory();
        if (!restored && _controller.currentEpisodes.isNotEmpty) {
          _controller.selectEpisode(_controller.selectedEpisodeIndex.value);
        }
        _refreshCollectState();
      });
    }
  }

  /// 尝试从播放历史恢复续播位置；返回是否成功恢复
  bool _restorePlaybackFromHistory() {
    final video = Get.arguments as Video?;
    if (video == null) return false;
    final history = CacheStore.instance.getHistory(video.id);
    if (history == null) return false;
    final epIndex = _controller.currentEpisodes
        .indexWhere((ep) => ep.name == history.episodeName);
    if (epIndex >= 0) {
      _controller.selectEpisode(epIndex);
      return true;
    }
    return false;
  }

  void _refreshCollectState() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final info = _controller.vodInfo.value;
    final isFullscreen = PlayerFullscreenController.instance.isFullscreen.value;

    return Obx(() {
      final fullscreen = PlayerFullscreenController.instance.isFullscreen.value;

      // 沉浸式全屏：纯黑背景 + 播放器铺满（无 AppBar / 无信息区）
      if (fullscreen) {
        return Scaffold(
          backgroundColor: Colors.black,
          body: _buildPlayerArea(),
        );
      }

      return Stack(
        children: [
          // 背景层：让详情页背景与首页/全局背景一致（对应 Swift DetailBackgroundView）
          Positioned.fill(
            child: BackgroundService.instance.buildBackground(overlayAlpha: 0.3),
          ),
          Scaffold(
            backgroundColor: Colors.transparent,
            extendBodyBehindAppBar: true,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration: BoxDecoration(
                    color: AppTheme.glassTintDeep,
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(20),
                    ),
                  ),
                ),
              ),
              title: Text(
                info?.name ?? '详情',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontTitle3,
                  fontWeight: FontWeight.bold,
                ),
              ),
              centerTitle: true,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: AppTheme.textPrimary, size: 20),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            body: Stack(
              children: [
                Padding(
                  padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + kToolbarHeight),
                  child: _buildBody(),
                ),
                // 详情页底部悬浮导航栏 - 对应 Swift floatingNavBar
                // 与根底栏一致：沉浸式超浅玻璃底，可切回其他 tab
                Positioned(
                  left: 32,
                  right: 32,
                  bottom: MediaQuery.of(context).padding.bottom + 8,
                  child: _buildFloatingNavBar(),
                ),
              ],
            ),
          ),
        ],
      );
    });
  }

  Widget _buildBody() {
    final info = _controller.vodInfo.value;
    if (_controller.isLoading.value && info == null) {
      return const Center(child: CircularProgressIndicator(color: AppTheme.accentColor));
    }
    if (info == null) {
      return const Center(
        child: Text(
          '视频信息加载失败',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      );
    }

    // 正常模式：视频 + 视频信息 + 选集
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. 播放器 - 对应 Swift PlayerView
          // **进详情即显示播放界面**：不依赖 isPlaying，只要 vodInfo 就绪
          // 就渲染播放器容器；URL 未就绪时 _buildPlayerArea 内部显示
          // 16:9 加载占位，解析完成后自动出画面（不再"先进文字后出视频"）
          _buildPlayerArea(),

          // 2. 视频信息 - 对应 Swift videoInfoSection (AppCard)
          _buildVideoInfo(),

          // 3. 选集播放 - 对应 Swift episodeSection
          if (_controller.currentEpisodes.isNotEmpty)
            _buildEpisodeList(),

          // 底部间距 - 对应 Swift .padding(.bottom, 80)
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  /// 播放器区域 - 16:9 容器，URL 未就绪时显示加载占位
  Widget _buildPlayerArea() {
    final url = _controller.playUrl.value;
    final isFullscreen = PlayerFullscreenController.instance.isFullscreen.value;

    if (url == null || url.isEmpty) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: const CircularProgressIndicator(
            color: AppTheme.accentColor,
          ),
        ),
      );
    }

    return VideoPlayerWidget(
      key: ValueKey(url),
      url: url,
      headers: _controller.playHeaders.value,
      title: _controller.vodInfo.value?.name ?? '',
      isPlaying: _controller.isPlaying.value,
      onPlayingChanged: (playing) {
        _controller.isPlaying.value = playing;
      },
      onFullScreenChanged: (fullscreen) {
        if (fullscreen) {
          PlayerFullscreenController.instance.enter();
        } else {
          PlayerFullscreenController.instance.exit();
        }
      },
      onPlayError: (msg) {
        _controller.errorMessage.value = msg;
      },
      // 听剧模式回调（音频模式覆盖层已由 VideoPlayerWidget 内部管理）
      onAudioModeChanged: (enabled) {
        _controller.audioMode.value = enabled;
      },
      // 画中画回调
      onPipChanged: (enabled) {},
    );
  }

  /// 视频信息区 - 对应 Swift videoInfoSection (AppCard)
  /// **布局重组（2026-09-26）**：
  /// - 收藏按钮缩小为纯图标，前置到视频名称前（不再是大按钮）
  /// - 影片简介并入名称同一卡片（不再独立卡片），过长收起点击展开
  Widget _buildVideoInfo() {
    final info = _controller.vodInfo.value;
    if (info == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingLG, AppTheme.spacingLG, 0),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 名称行：收藏小图标 + 片名（图标前置）
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildCollectIconButton(),
                const SizedBox(width: AppTheme.spacingSM),
                Expanded(
                  child: Text(
                    info.name,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontTitle2,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.spacingMD),

            // 元数据药丸 - 对应 Swift metadataFlow
            _buildMetadataFlow(info),
            const SizedBox(height: AppTheme.spacingMD),

            // 播放按钮 - 对应 Swift playButton（未播放时显示）
            _buildPlayButton(),

            // 影片简介 - 并入名称卡片（对应 Swift descriptionSection）
            if (info.des.isNotEmpty) ...[
              const SizedBox(height: AppTheme.spacingMD),
              _buildInlineDescription(info),
            ],
          ],
        ),
      ),
    );
  }

  /// 收藏按钮（小图标版）- 前置在视频名称前
  /// 点击切换收藏状态，图标随状态变化（实心=已收藏 / 空心=未收藏）
  Widget _buildCollectIconButton() {
    return Obx(() {
      final info = _controller.vodInfo.value;
      if (info == null) return const SizedBox.shrink();
      final isCollected =
          CacheStore.instance.isCollected(info.id, info.sourceKey);

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          if (isCollected) {
            await CacheStore.instance.removeCollect(info.id, info.sourceKey);
          } else {
            await CacheStore.instance.addCollect(info.toVideo());
          }
        },
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: isCollected
                ? AppTheme.accentColor.withValues(alpha: 0.14)
                : AppTheme.backgroundTertiary,
            shape: BoxShape.circle,
            border: Border.all(
              color: isCollected
                  ? AppTheme.accentColor.withValues(alpha: 0.4)
                  : AppTheme.borderLight,
              width: 0.8,
            ),
          ),
          child: Icon(
            isCollected ? Icons.favorite : Icons.favorite_border,
            size: 18,
            color: isCollected ? AppTheme.accentColor : AppTheme.textSecondary,
          ),
        ),
      );
    });
  }

  /// 影片简介（内联版）- 并入名称卡片，3 行收起 / 点击展开全文
  Widget _buildInlineDescription(VodInfo info) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedCrossFade(
          firstChild: Text(
            info.des,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontBody,
              height: 1.5,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          secondChild: Text(
            info.des,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontBody,
              height: 1.5,
            ),
          ),
          crossFadeState: _isDescriptionExpanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 250),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () =>
              setState(() => _isDescriptionExpanded = !_isDescriptionExpanded),
          child: Padding(
            padding: const EdgeInsets.only(top: AppTheme.spacingXS),
            child: Center(
              child: Text(
                _isDescriptionExpanded ? '收起' : '展开',
                style: const TextStyle(
                  color: AppTheme.accentColor,
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 元数据药丸 - 对应 Swift metadataFlow
  Widget _buildMetadataFlow(VodInfo info) {
    final chips = <Widget>[];

    void addChip(String label) {
      if (label.isEmpty) return;
      chips.add(Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderLight, width: 0.5),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontFootnote,
          ),
        ),
      ));
    }

    addChip(info.typeName);
    addChip(info.year);
    addChip(info.area);
    addChip(info.lang);

    if (chips.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: AppTheme.spacingSM,
      runSpacing: AppTheme.spacingSM,
      children: chips,
    );
  }

  /// 播放按钮 - 对应 Swift playButton
  Widget _buildPlayButton() {
    return Obx(() {
      final isPlaying = _controller.isPlaying.value;
      return GestureDetector(
        onTap: () {
          if (isPlaying) {
            _controller.pause();
          } else {
            _controller.resume();
          }
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingMD),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppTheme.accentColor, AppTheme.accentLightColor],
            ),
            borderRadius: BorderRadius.circular(AppTheme.radiusMD),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                size: 20,
                color: Colors.white,
              ),
              const SizedBox(width: AppTheme.spacingXS),
              Text(
                isPlaying ? '暂停' : '播放',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  /// 选集播放列表 - 对应 Swift episodeSection
  Widget _buildEpisodeList() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingLG, AppTheme.spacingLG, 0),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: '选集', icon: Icons.video_library_outlined),
            const SizedBox(height: AppTheme.spacingMD),
            EpisodeListView(
              episodeNames: _controller.currentEpisodes
                  .map((e) => e.name)
                  .toList(),
              selectedIndex: _controller.selectedEpisodeIndex.value,
              onEpisodeTap: (index) {
                _controller.selectEpisode(index);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 详情页底部悬浮导航栏 - 对应 Swift floatingNavBar
  /// 与根底栏一致：沉浸式超浅玻璃底（alpha≈2%），显示更多内容
  Widget _buildFloatingNavBar() {
    return Obx(() {
      if (PlayerFullscreenController.instance.isFullscreen.value) {
        return const SizedBox.shrink();
      }
      return GlassPanel(
        radius: 30,
        blur: true,
        // **沉浸式底栏**：与根底栏一致改用超浅玻璃底 (alpha≈2%)，
        // 只留模糊+描边+高光，背景几乎全透明，显示更多内容。
        tint: AppTheme.glassTintClear,
        borderColor: AppTheme.glassBorderSoft,
        borderWidth: 0.8,
        highlightStrength: 0.9,
        shadow: true,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _navItem(Icons.home_outlined, Icons.home, '首页', 0),
            _navItem(Icons.tv_outlined, Icons.tv, '直播', 1),
            _navItem(Icons.schedule_outlined, Icons.schedule, '历史', 2),
            _navItem(Icons.favorite_border, Icons.favorite, '收藏', 3),
            _navItem(Icons.settings_outlined, Icons.settings, '设置', 4),
          ],
        ),
      );
    });
  }

  Widget _navItem(IconData icon, IconData activeIcon, String label, int index) {
    return Obx(() {
      final selected = MainTabController.instance.selectedTab.value == index;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          MainTabController.instance.switchTab(index);
          Navigator.of(context).maybePop();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                selected ? activeIcon : icon,
                size: 20,
                color: selected ? AppTheme.accentColor : AppTheme.textSecondary,
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  color: selected ? AppTheme.accentColor : AppTheme.textSecondary,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}
