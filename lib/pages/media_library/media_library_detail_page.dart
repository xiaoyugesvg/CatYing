import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../models/movie.dart';
import '../../models/vod_info.dart';
import '../../pages/detail/controller.dart';
import '../../services/tmdb_service.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/common_widgets.dart';
import 'media_library_player_page.dart';

/// 媒体库详情页（独立模块 `lib/pages/media_library/`）
///
/// 由 TMDB 刮削数据驱动：头图 backdrop + 大标题 + 元数据行 + 双按钮 +
/// 剧集缩略图横条 + 导演/演职员 + 简介 + 类似作品。
/// - 数据加载/选集/播放地址解析复用 `DetailController`（Spider 源地址解析一致）；
/// - 外观与主题系统统一：背景/文字/边框全部走 `AppTheme`（跟随明暗 + 调色板），
///   浅色=宣纸米白、深色=墨夜，强调色跟随 `AppTheme.accentColor`；
/// - 独立文件，修改本模块不影响默认详情页 `detail/view.dart`。
///
/// 进入方式（二选一）：
/// 1. 路由 `/detail`（设置 → TMDB 管理 → 媒体库模式 开启）→ `Get.arguments` 为 Video，
///    内部自动 loadDetail + TMDB 刮削；
/// 2. 传入 [initialInfo]（类似作品点击）→ 直接用 TMDB 数据展示并 enrich。
class MediaLibraryDetailPage extends StatefulWidget {
  final VodInfo? initialInfo;

  const MediaLibraryDetailPage({super.key, this.initialInfo});

  @override
  State<MediaLibraryDetailPage> createState() => _MediaLibraryDetailPageState();
}

class _MediaLibraryDetailPageState extends State<MediaLibraryDetailPage> {
  /// 与默认详情页一致：每次进入强制重建 controller，避免残留上一部视频状态
  static DetailController _rebuildController() {
    if (Get.isRegistered<DetailController>()) {
      Get.delete<DetailController>();
    }
    return Get.put(DetailController());
  }

  final _controller = _rebuildController();
  final _scrollController = ScrollController();

  /// 当前选中的集（剧集横条高亮；默认源当前集）
  int _selectedIndex = 0;

  VodInfo? get _info => _controller.vodInfo.value;

  @override
  void initState() {
    super.initState();
    _selectedIndex = _controller.selectedEpisodeIndex.value;
    if (widget.initialInfo != null) {
      // 类似作品路径：直接用 TMDB 数据展示（无 Spider 源）
      _controller.vodInfo.value = widget.initialInfo!;
      _enrichFromTmdb();
    } else {
      _loadDetailIfNeeded();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // ============================================================
  // 数据
  // ============================================================

  void _loadDetailIfNeeded() {
    final video = Get.arguments;
    if (video == null || video is! Video) return;
    _controller.loadDetail(video).then((_) {
      if (!mounted) return;
      if (_controller.currentEpisodes.isNotEmpty) {
        _controller.selectEpisode(_controller.selectedEpisodeIndex.value);
      }
      setState(() => _selectedIndex = _controller.selectedEpisodeIndex.value);
      _enrichFromTmdb();
    });
  }

  /// 媒体库模式强制 TMDB 刮削（不受「自动刮削」开关限制——媒体库本身就是刮削模式）
  Future<void> _enrichFromTmdb() async {
    final tmdb = TmdbService.instance;
    final info = _info;
    if (!tmdb.configured || info == null) return;
    final ok = await tmdb.enrich(info);
    if (ok && mounted) setState(() {});
  }

  // ============================================================
  // 播放
  // ============================================================

  void _playAt(int index) {
    final info = _info;
    if (info == null) return;
    final eps = info.currentEpisodes;
    if (eps.isEmpty) {
      AppToast.message('暂无播放源');
      return;
    }
    final target = index.clamp(0, eps.length - 1);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MediaLibraryPlayerPage(
          controller: _controller,
          info: info,
          startIndex: target,
          headers: _controller.playHeaders.isEmpty
              ? null
              : Map<String, String>.of(_controller.playHeaders),
        ),
      ),
    );
  }

  void _playCurrent() => _playAt(_selectedIndex);

  // ============================================================
  // Build
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final bg = AppTheme.backgroundPrimary;
    return Obx(() {
      final info = _info;
      // 加载中（无详情且无错误提示）
      if (_controller.isLoading.value && info == null) {
        return Scaffold(
          backgroundColor: bg,
          body: const Center(
            child: CircularProgressIndicator(color: Colors.white70),
          ),
        );
      }
      // 错误且无详情
      if (_controller.errorMessage.value != null && info == null) {
        return Scaffold(
          backgroundColor: bg,
          body: AppError(
            message: _controller.errorMessage.value!,
            onRetry: () {
              final video = Get.arguments;
              if (video != null && video is Video) {
                _controller.loadDetail(video);
              }
            },
          ),
        );
      }
      if (info == null) {
        return Scaffold(backgroundColor: bg);
      }

      final title = info.tmdbName.isNotEmpty ? info.tmdbName : info.name;
      final eps = info.currentEpisodes;

      return Scaffold(
        backgroundColor: bg,
        body: Stack(
          children: [
            ListView(
              controller: _scrollController,
              padding: EdgeInsets.zero,
              children: [
                _buildHero(info, title),
                _buildMetaButtons(info),
                if (eps.isNotEmpty) _buildEpisodes(info, eps),
                if (info.director.isNotEmpty) _buildDirector(info),
                if (info.castList.isNotEmpty) _buildCast(info),
                if (info.des.isNotEmpty) _buildOverview(info),
                if (info.similarList.isNotEmpty) _buildSimilar(info),
                const SizedBox(height: 24),
                Center(
                  child: Text(
                    '数据来源：TMDB',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontFootnote,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ],
        ),
      );
    });
  }

  // ---------- 头图区 ----------

  Widget _buildHero(VodInfo info, String title) {
    final backdrop =
        info.backdrop.isNotEmpty ? info.backdrop : (info.pic.isNotEmpty ? info.pic : '');
    final metaParts = <String>[
      if (info.year.isNotEmpty) info.year,
      if (info.rating > 0) '${info.rating.toStringAsFixed(1)}★',
      if (info.episodeCount > 0) '${info.episodeCount} ep',
      if (info.tmdbStatus.isNotEmpty) info.tmdbStatus,
    ];
    final genreLine = info.typeName.replaceAll(' / ', ' |');
    // 渐变遮罩用页面底色（浅色=宣纸、深色=墨夜），跟随主题明暗
    final bg = AppTheme.backgroundPrimary;

    return SizedBox(
      height: 400,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 背景图（backdrop 优先，无则海报）
          if (backdrop.isNotEmpty)
            CachedNetworkImage(
              imageUrl: backdrop,
              fit: BoxFit.cover,
              placeholder: (_, __) =>
                  ColoredBox(color: AppTheme.backgroundSecondary),
              errorWidget: (_, __, ___) =>
                  ColoredBox(color: AppTheme.backgroundSecondary),
            )
          else
            ColoredBox(color: AppTheme.backgroundSecondary),
          // 顶部操作栏：返回
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    _circleIconButton(
                      Icons.arrow_back,
                      onTap: () => Get.back(),
                    ),
                    const Spacer(),
                  ],
                ),
              ),
            ),
          ),
          // 底部渐变遮罩（透明 → 底色 0.75 → 底色 0.95）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: 230,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    bg.withValues(alpha: 0.75),
                    bg.withValues(alpha: 0.95),
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
            ),
          ),
          // 标题区
          Positioned(
            left: 16,
            right: 16,
            bottom: 28,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (info.tmdbOriginalName.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    info.tmdbOriginalName,
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (metaParts.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    metaParts.join(' · '),
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (genreLine.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    genreLine,
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 元数据 + 双按钮 ----------

  Widget _buildMetaButtons(VodInfo info) {
    final hasSource = info.currentEpisodes.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: _actionButton(
              label: hasSource ? '立即播放' : '暂无播放源',
              filled: true,
              enabled: hasSource,
              onTap: _playCurrent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _actionButton(
              label: '选集',
              filled: false,
              enabled: hasSource,
              onTap: () {
                if (!hasSource) return;
                final eps = info.currentEpisodes;
                if (eps.isEmpty) return;
                // 滚动到剧集区（头图 400 + 按钮区高度）
                _scrollController.animateTo(
                  400 + 96,
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOut,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required String label,
    required bool filled,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final accent = AppTheme.accentColor;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: filled ? accent : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          border: filled ? null : Border.all(color: accent, width: 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.play_arrow_rounded,
              size: 20,
              color: enabled
                  ? (filled ? Colors.white : accent)
                  : AppTheme.textTertiary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: enabled
                    ? (filled ? Colors.white : accent)
                    : AppTheme.textTertiary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 剧集区 ----------

  Widget _buildEpisodes(VodInfo info, List<Episode> eps) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Text(
            '剧集  ${eps.length}集',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          height: 112,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: eps.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) => _episodeCard(info, eps, i),
          ),
        ),
      ],
    );
  }

  Widget _episodeCard(VodInfo info, List<Episode> eps, int i) {
    final ep = eps[i];
    final still = info.episodeStills[i + 1] ?? '';
    final epTitle = info.episodeTitles[i + 1] ?? ep.name;
    final selected = i == _selectedIndex;
    final accent = AppTheme.accentColor;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() => _selectedIndex = i);
        _playAt(i);
      },
      child: Container(
        width: 140,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: selected ? Border.all(color: accent, width: 1.5) : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (still.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: still,
                  fit: BoxFit.cover,
                  placeholder: (_, __) =>
                      ColoredBox(color: AppTheme.backgroundSecondary),
                  errorWidget: (_, __, ___) =>
                      ColoredBox(color: AppTheme.backgroundSecondary),
                )
              else
                ColoredBox(color: AppTheme.backgroundSecondary),
              // 底部渐变 + 集号 + 标题
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(7, 18, 7, 6),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        AppTheme.textPrimary.withValues(alpha: 0.85),
                      ],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: selected ? accent : Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${i + 1}',
                          style: TextStyle(
                            color: selected
                                ? Colors.white
                                : AppTheme.textPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        epTitle,
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 导演 ----------

  Widget _buildDirector(VodInfo info) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        '导演: ${info.director}',
        style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
      ),
    );
  }

  // ---------- 演职员 ----------

  Widget _buildCast(VodInfo info) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Text(
            '演职员',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          height: 118,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: info.castList.length,
            separatorBuilder: (_, __) => const SizedBox(width: 16),
            itemBuilder: (_, i) {
              final m = info.castList[i];
              return SizedBox(
                width: 72,
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 32,
                      backgroundColor: AppTheme.backgroundSecondary,
                      foregroundImage: m.hasPhoto
                          ? CachedNetworkImageProvider(m.avatarUrl)
                          : null,
                      child: m.hasPhoto
                          ? null
                          : Icon(
                              Icons.person_outline,
                              color: AppTheme.textTertiary,
                            ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      m.name,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (m.character.isNotEmpty) ...[
                      Text(
                        m.character,
                        style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------- 简介 ----------

  Widget _buildOverview(VodInfo info) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '简介',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            info.des,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 类似作品 ----------

  Widget _buildSimilar(VodInfo info) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Text(
            '类似作品',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          height: 210,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: info.similarList.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, i) => _similarCard(info.similarList[i]),
          ),
        ),
      ],
    );
  }

  Widget _similarCard(VodSimilarItem item) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // 用 TMDB 数据构造新媒体库详情（无 Spider 源 → 只展示 + 刮削）
        final info = VodInfo(
          id: 'tmdb-${item.id}',
          name: item.title,
          pic: item.posterUrl,
          year: item.year,
          tmdbName: item.title,
        );
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MediaLibraryDetailPage(initialInfo: info),
          ),
        );
      },
      child: SizedBox(
        width: 110,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 110,
                height: 155,
                child: item.posterUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: item.posterUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            ColoredBox(color: AppTheme.backgroundSecondary),
                        errorWidget: (_, __, ___) =>
                            ColoredBox(color: AppTheme.backgroundSecondary),
                      )
                    : ColoredBox(color: AppTheme.backgroundSecondary),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (item.hasRating)
              Text(
                '${item.voteAverage.toStringAsFixed(1)}★',
                style: TextStyle(
                  color: AppTheme.accentColor,
                  fontSize: 11,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---------- 通用 ----------

  Widget _circleIconButton(IconData icon, {VoidCallback? onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppTheme.backgroundSecondary.withValues(alpha: 0.8),
          shape: BoxShape.circle,
          border: Border.all(color: AppTheme.borderLight, width: 0.6),
        ),
        child: Icon(icon, color: AppTheme.textPrimary, size: 20),
      ),
    );
  }
}
