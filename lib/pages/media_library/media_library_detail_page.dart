import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ImageStreamListener;
import 'package:get/get.dart';
import 'dart:ui' as ui;

import '../../common/theme.dart';
import '../../models/cache_store.dart';
import '../../models/movie.dart';
import '../../models/vod_info.dart';
import '../../pages/detail/controller.dart';
import '../detail/view.dart';
import '../../services/tmdb_service.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/common_widgets.dart';
import 'media_library_player_page.dart';
import 'tmdb_match_page.dart';

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

  /// 选集底部面板：线路/倒序/定位
  final _episodeListScroll = ScrollController();
  String _episodeSelectedFlag = '';
  bool _episodeDesc = false;

  /// 当前选中的集（剧集横条高亮；默认源当前集）
  int _selectedIndex = 0;

  /// 简介展开/收起
  bool _overviewExpanded = false;

  /// TMDB 刮削是否已尝试过（用于未命中提示）
  bool _tmdbAttempted = false;
  bool _tmdbOk = false;

  /// 收藏（头图右上角 ♥，仅主路径有 Video 时可用）
  Video? _video;
  bool _collected = false;

  /// 相关推荐（主演作品，横向卡片）
  List<Map<String, dynamic>> _personWorks = const [];
  bool _worksLoading = false;
  bool _worksTriggered = false;

  /// 竖版海报底边颜色（用于头图渐变：从 55% 屏高向下用图片底部色渐变，
  /// 与海报自然衔接，不再是"海报 + 纯黑"的硬切）
  Color? _posterEdgeColor;
  String? _posterEdgeUrl;

  VodInfo? get _info => _controller.vodInfo.value;

  @override
  void initState() {
    super.initState();
    _selectedIndex = _controller.selectedEpisodeIndex.value;
    // 收藏状态（主路径）
    final video = Get.arguments;
    if (video is Video) {
      _video = video;
      _collected =
          CacheStore.instance.isCollected(video.id, video.sourceKey);
      // 媒体库模式但 TMDB 未配置（没填 Key）：媒体库页无数据可刮，
      // 直接回退默认详情页，不展示空壳媒体库界面
      if (!TmdbService.instance.configured) {
        _fallbackToDefault(video);
        return;
      }
    }
    if (widget.initialInfo != null) {
      // 类似作品路径：直接用 TMDB 数据展示（无 Spider 源）
      _controller.vodInfo.value = widget.initialInfo!;
      _enrichFromTmdb();
    } else {
      _loadDetailIfNeeded();
    }
  }

  /// TMDB 刮削失败 → 一律回退默认详情页。
  /// 主路径（有 Video）回退到默认详情页；类似作品/相关推荐路径
  /// （无 Video，默认详情页没有数据可渲染）回退为返回上一页。
  void _fallbackToDefault(Video? video) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (video != null) {
        Get.off(() => DetailPage(), arguments: video);
      } else {
        Get.back();
      }
    });
  }

  @override
  void dispose() {
    _episodeListScroll.dispose();
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
  Future<void> _enrichFromTmdb({bool force = false}) async {
    final tmdb = TmdbService.instance;
    final info = _info;
    if (!tmdb.configured || info == null) return;
    // 重新刮削（手动触发）给即时反馈；自动进入时保持静默（页面本身在加载态）
    if (force) AppToast.show('正在刮削', '「${info.name}」…');
    var ok = await tmdb.enrich(info, forceNetwork: force);
    // 整名未命中 → 自动拆词兜底一次（媒体库要求数据必须来自 TMDB）：
    // 用 searchCandidates（自带 cleanTitle + 语言降级 + 拆词）取候选，
    // 候选标题与片名相关（互含/前缀匹配）才自动应用，避免错配。
    // 重新刮削（force）也走兜底：否则整名未命中就白刮一场，界面没变化。
    if (!ok) {
      final year = TmdbService.extractYear(info.note, info.year);
      final cands = await tmdb.searchCandidates(info.name, year);
      final clean = TmdbService.cleanTitle(info.name);
      for (final (type, item) in cands.take(8)) {
        final n = (item['title'] ?? item['name'] ?? '').toString();
        if (n.isEmpty || clean.isEmpty) continue;
        final a = n.contains(clean) || clean.contains(n);
        final prefix = clean.length >= 2 &&
            (n.startsWith(clean.substring(0, 2)) ||
                clean.startsWith(n.length >= 2 ? n.substring(0, 2) : n));
        if (a || prefix) {
          ok = await tmdb.applyCandidate(info, type, item);
          break;
        }
      }
    }
    if (!mounted) return;
    // 回退策略：
    // - 自动首次刮削失败（整名 + 拆词兜底都没命中）：留在媒体库页，
    //   显示「TMDB 未匹配到」提示条 + 重新刮削入口，不回退（用户可手动匹配 T）
    // - 手动重新刮削（force）也失败：回退默认详情页
    //   （有 Video 进默认详情页；类似作品/相关推荐路径无 Video 则返回上一页）
    if (!ok && force) {
      _fallbackToDefault(_video);
      return;
    }
    setState(() {
      _tmdbAttempted = true;
      _tmdbOk = ok;
    });
    if (force) {
      AppToast.show(
        ok ? 'TMDB 数据已更新' : '刮削失败',
        ok ? '✅' : (tmdb.lastEnrichError.value ?? '未知错误'),
      );
    }
    // 有主演 → 顺手拉「相关推荐」（主演作品）
    if (!_worksTriggered) {
      _worksTriggered = true;
      _loadPersonWorks();
    }
  }

  /// 拉主演作品列表（媒体库「相关推荐」区）
  Future<void> _loadPersonWorks() async {
    final info = _info;
    if (info == null || _worksLoading) return;
    final personId = info.castList.isNotEmpty ? info.castList.first.id : 0;
    if (personId <= 0) return;
    _worksLoading = true;
    final works = await TmdbService.instance.fetchPersonWorks(personId);
    if (!mounted) return;
    _worksLoading = false;
    if (works.isNotEmpty) {
      setState(() => _personWorks = works);
    }
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

  /// 「选集」：底部弹出播放列表菜单栏（源切换样式）
  /// 播放分组（线路）横条 + 播放列表（可滑动）+
  /// 正序/倒序切换 + 定位正在播放的集数。
  void _showEpisodeMenu() {
    final info = _info;
    if (info == null) return;
    final flags = info.playFlags;
    if (flags.isEmpty) return;
    _episodeSelectedFlag =
        flags.contains(_controller.selectedFlag.value)
            ? _controller.selectedFlag.value
            : flags.first;
    _episodeDesc = false;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _buildEpisodeSheet(info),
    );
  }

  Widget _buildEpisodeSheet(VodInfo info) {
    final screenH = MediaQuery.of(context).size.height;
    final accent = AppTheme.accentColor;
    final flags = info.playFlags;
    // 弹窗局部状态：线路下拉开关 + 搜索关键词
    var flagMenuOpen = false;
    var query = '';
    return Container(
      height: screenH * 0.66,
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: StatefulBuilder(
        builder: (ctx, setSheetState) {
          final eps =
              info.playUrlMap[_episodeSelectedFlag] ?? const <Episode>[];
          final ordered = _episodeDesc ? eps.reversed.toList() : eps;
          final current = _controller.selectedEpisodeIndex.value;
          // 搜索过滤索引（保留原顺序索引；供定位按钮与列表共用）
          // MapEntry: key=ordered 索引, value=剧集；关键词同时匹配集名与真实集号
          final indexed = ordered.asMap().entries.where((e) {
            final q = query.trim().toLowerCase();
            if (q.isEmpty) return true;
            if (e.value.name.toLowerCase().contains(q)) return true;
            final n = _parseEpisodeNumber(e.value.name);
            return n != null && '$n'.contains(query.trim());
          }).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 拖拽条
              Center(
                child: Container(
                  width: 34,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.borderMedium,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // 第一排：选集 + 线路名（点击下拉切换）+ 集数 + 排序 + 定位（去掉右上角关闭）
              Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
                    child: Row(
                      children: [
                        Text(
                          '选集',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 10),
                        // 线路名：多线路点击下拉切换；单线路固定显示「默认」
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: flags.length > 1
                              ? () => setSheetState(
                                  () => flagMenuOpen = !flagMenuOpen)
                              : null,
                          child: Container(
                            height: 28,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 10),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppTheme.backgroundTertiary,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 96),
                                  child: Text(
                                    flags.length > 1
                                        ? _episodeSelectedFlag
                                        : '默认',
                                    style: TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (flags.length > 1)
                                  Icon(
                                    flagMenuOpen
                                        ? Icons.arrow_drop_up
                                        : Icons.arrow_drop_down,
                                    size: 16,
                                    color: AppTheme.textSecondary,
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${eps.length}集',
                          style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: 12,
                          ),
                        ),
                        const Spacer(),
                        _sheetAction(
                          icon: _episodeDesc
                              ? Icons.arrow_downward
                              : Icons.arrow_upward,
                          label: _episodeDesc ? '倒序' : '正序',
                          active: _episodeDesc,
                          onTap: () => setSheetState(
                              () => _episodeDesc = !_episodeDesc),
                        ),
                        const SizedBox(width: 8),
                        _sheetAction(
                          icon: Icons.my_location,
                          label: '定位当前集',
                          active: false,
                          onTap: () {
                            setSheetState(() {});
                            WidgetsBinding.instance
                                .addPostFrameCallback((_) {
                              final qNow = query.trim();
                              var targetIdx = _episodeDesc
                                  ? (eps.length - 1 - current)
                                  : current;
                              if (qNow.isNotEmpty) {
                                final curOrdered = _episodeDesc
                                    ? (eps.length - 1 - current)
                                    : current;
                                final fi = indexed
                                    .indexWhere((e) => e.key == curOrdered);
                                targetIdx = fi < 0 ? 0 : fi;
                              }
                              if (_episodeListScroll.hasClients) {
                                _episodeListScroll.animateTo(
                                  targetIdx * 48.0,
                                  duration:
                                      const Duration(milliseconds: 260),
                                  curve: Curves.easeOut,
                                );
                              }
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                  // 线路下拉：≤4 项（每项 42 高），超出可滑动（无滚动条图标）
                  if (flagMenuOpen && flags.length > 1)
                    Positioned(
                      top: 46,
                      left: 16,
                      child: Container(
                        width: 200,
                        constraints: const BoxConstraints(maxHeight: 168),
                        decoration: BoxDecoration(
                          color: AppTheme.backgroundSecondary,
                          borderRadius: BorderRadius.circular(14),
                          border:
                              Border.all(color: AppTheme.borderLight),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black38,
                              blurRadius: 14,
                              offset: Offset(0, 5),
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          physics: const ClampingScrollPhysics(),
                          itemCount: flags.length,
                          itemBuilder: (_, i) => InkWell(
                            onTap: () {
                              _controller.selectFlag(flags[i]);
                              setSheetState(() {
                                _episodeSelectedFlag = flags[i];
                                flagMenuOpen = false;
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 9),
                              color: flags[i] == _episodeSelectedFlag
                                  ? AppTheme.accentColor
                                      .withValues(alpha: 0.15)
                                  : null,
                              child: Text(
                                flags[i],
                                style: TextStyle(
                                  color: flags[i] == _episodeSelectedFlag
                                      ? AppTheme.accentColor
                                      : AppTheme.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              // 第二排：搜索框（搜索剧集）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  onChanged: (v) => setSheetState(() => query = v),
                  style:
                      TextStyle(color: AppTheme.textPrimary, fontSize: 12),
                  decoration: InputDecoration(
                    hintText: '搜索剧集',
                    hintStyle: TextStyle(
                        color: AppTheme.textTertiary, fontSize: 12),
                    prefixIcon: Icon(Icons.search,
                        size: 15, color: AppTheme.textTertiary),
                    suffixIcon: query.isNotEmpty
                        ? GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () =>
                                setSheetState(() => query = ''),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Icon(Icons.close,
                                  size: 14,
                                  color: AppTheme.textTertiary),
                            ),
                          )
                        : null,
                    isDense: true,
                    filled: true,
                    fillColor: AppTheme.backgroundTertiary
                        .withValues(alpha: 0.45),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 9),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Divider(height: 1, color: AppTheme.borderLight),
              // 播放列表（可滑动；支持搜索过滤，过滤索引见 builder 顶层 indexed）
              Expanded(
                child: ListView.separated(
                  controller: _episodeListScroll,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: indexed.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: AppTheme.borderLight),
                  itemBuilder: (_, i) {
                    final orderedIdx = indexed[i].key;
                    final ep = indexed[i].value;
                    final realIndex = _episodeDesc
                        ? eps.length - 1 - orderedIdx
                        : orderedIdx;
                    final selected = realIndex == current;
                    return InkWell(
                      onTap: () {
                        _controller.selectEpisode(realIndex);
                        Navigator.pop(ctx);
                        setState(() => _selectedIndex = realIndex);
                        _playAt(realIndex);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 9,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 30,
                              height: 30,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: selected
                                    ? accent
                                    : AppTheme.backgroundTertiary,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Text(
                                '${realIndex + 1}',
                                style: TextStyle(
                                  color: selected
                                      ? Colors.white
                                      : AppTheme.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                ep.name,
                                style: TextStyle(
                                  color: selected
                                      ? AppTheme.textPrimary
                                      : AppTheme.textSecondary,
                                  fontSize: 13,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (selected)
                              Icon(
                                Icons.check_circle_rounded,
                                size: 17,
                                color: accent,
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 选集面板小操作按钮（正序/倒序、定位当前集）
  Widget _sheetAction({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.accentColor.withValues(alpha: 0.15)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? AppTheme.accentColor : AppTheme.borderLight,
            width: active ? 1 : 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: active ? AppTheme.accentColor : AppTheme.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: active
                    ? AppTheme.accentColor
                    : AppTheme.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

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

      // 媒体库刮削「假界面」：Spider 源详情已到，但 TMDB 数据（导演/演员/
      // 简介/剧照等）还在拉取 → 先显示媒体库风格骨架占位，isWorking 置 false
      // （enrich / applyCandidate 完成）时自动切换真实内容。
      // 类似作品路径（initialInfo 已有 TMDB 数据）不显示骨架。
      if (widget.initialInfo == null &&
          _video != null &&
          TmdbService.instance.isWorking.value) {
        return _buildScrapeSkeleton();
      }

      final title = info.tmdbName.isNotEmpty ? info.tmdbName : info.name;
      final eps = info.currentEpisodes;

      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // 全屏壁纸：视频封面（backdrop 优先）铺满整屏 + 顶部/底部渐变遮罩
            Positioned.fill(child: _buildWallpaper(info)),
            // 内容浮层：标题贴顶悬浮在封面上，内容可整体上滑、放手回弹
            ListView(
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                _buildHeroHeader(info, title),
                _buildMetaButtons(info),
                if (eps.isNotEmpty) _buildEpisodes(info, eps),
                if (info.director.isNotEmpty) _buildDirector(info),
                if (info.castList.isNotEmpty) _buildCast(info),
                if (info.des.isNotEmpty) _buildOverview(info),
                // TMDB 刮削未命中：导演/演员/简介全缺时给出原因 + 重新刮削
                if (_tmdbAttempted &&
                    !_tmdbOk &&
                    TmdbService.instance.configured)
                  _buildTmdbMiss(info),
                // 相关推荐（主演作品，横向卡片）；空则降级用 TMDB 类似作品
                if (_personWorks.isNotEmpty) _buildRelatedWorks(info),
                if (_personWorks.isEmpty && info.similarList.isNotEmpty)
                  _buildSimilar(info),
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
            // 顶部操作栏悬浮（返回 + 手动匹配 T + 收藏），不随内容滚动
            _buildTopBar(info),
          ],
        ),
      );
    });
  }

  // ---------- 头图壁纸（竖版海报贴顶铺满宽，55% 屏高处按海报底部色渐变） ----------

  /// 取图片底部平均色（海报底边颜色，做渐变用）。
  /// 失败返回黑色兜底；结果缓存到 [_posterEdgeColor]，同一海报只取一次。
  Future<Color> _edgeColorOf(String url) async {
    try {
      final prov = CachedNetworkImageProvider(url);
      final stream = prov.resolve(const ImageConfiguration());
      final completer = Completer<ui.Image>();
      late final ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          if (!completer.isCompleted) completer.complete(info.image);
          stream.removeListener(listener);
        },
        onError: (e, s) {
          if (!completer.isCompleted) completer.completeError(e);
          stream.removeListener(listener);
        },
      );
      stream.addListener(listener);
      final img = await completer.future.timeout(const Duration(seconds: 8));
      final w = img.width;
      final h = img.height;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      if (data == null || w == 0 || h == 0) return Colors.black;
      final bytes = data.buffer.asUint8List();
      // 采样最底部 6% 行、中间 50% 宽的像素平均色
      var r = 0, g = 0, b = 0, n = 0;
      final yStart = (h * 0.94).floor();
      final xStart = (w * 0.25).floor();
      final xEnd = (w * 0.75).floor();
      for (var y = yStart; y < h; y++) {
        for (var x = xStart; x < xEnd; x += 2) {
          final i = (y * w + x) * 4;
          if (i + 2 >= bytes.length) continue;
          r += bytes[i];
          g += bytes[i + 1];
          b += bytes[i + 2];
          n++;
        }
      }
      if (n == 0) return Colors.black;
      return Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
    } catch (_) {
      return Colors.black;
    }
  }

  Widget _buildWallpaper(VodInfo info) {
    // 竖版海报优先（用户要求：竖屏视频封面），无则回退横版 backdrop
    final poster = info.pic.isNotEmpty
        ? info.pic
        : (info.backdrop.isNotEmpty ? info.backdrop : '');
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    // 海报按 2:3 原比例铺满宽度：高 = 宽 × 1.5（完整显示、不裁切、贴顶）
    final posterH = screenW * 1.5;
    // 首次见到的海报 → 异步取底部色（取到后 setState 刷新渐变）
    if (poster.isNotEmpty && _posterEdgeUrl != poster) {
      _posterEdgeUrl = poster;
      _edgeColorOf(poster).then((c) {
        if (mounted && _posterEdgeUrl == poster) {
          setState(() => _posterEdgeColor = c);
        }
      });
    }
    final edge = _posterEdgeColor ?? Colors.black;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. 竖版海报：原图宽度铺满屏幕、完整不裁切、贴顶部
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: posterH,
          child: poster.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: poster,
                  fit: BoxFit.fill,
                  placeholder: (_, __) => ColoredBox(color: Colors.black),
                  errorWidget: (_, __, ___) => ColoredBox(color: Colors.black),
                )
              : ColoredBox(color: AppTheme.backgroundPrimary),
        ),
        // 2. 顶部轻遮罩：只保证状态栏 / 操作栏可读（上部保持干净）
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black54, Colors.transparent],
              stops: [0.0, 0.18],
            ),
          ),
        ),
        // 3. 从屏幕高度 55% 开始向下：用海报底部颜色做垂直渐变，
        //    与海报自然衔接，不再是"海报 + 纯黑"的硬切
        Positioned(
          left: 0,
          right: 0,
          top: screenH * 0.55,
          bottom: 0,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  edge.withValues(alpha: 0),
                  edge.withValues(alpha: 0.85),
                  edge,
                ],
                stops: const [0.0, 0.35, 1.0],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------- 贴顶标题区（悬浮在壁纸上，打开即见） ----------

  Widget _buildHeroHeader(VodInfo info, String title) {
    // 元数据行：年份 · 评分 · 时长 · 集数 · 状态 · 上映日期
    //（英文名/原名不进这一行 —— 参考图里它独立成主标题下方的小字副标题）
    final metaParts = <String>[
      if (info.year.isNotEmpty) info.year,
      if (info.rating > 0) '${info.rating.toStringAsFixed(1)}★',
      if (info.runtime > 0) '${info.runtime} 分钟',
      if (info.episodeCount > 0) '${info.episodeCount} ep',
      if (info.tmdbStatus.isNotEmpty) info.tmdbStatus,
      // 完整上映/播出日期（如 2026-01-15）
      if (info.releaseDate.isNotEmpty) info.releaseDate,
    ];
    final genreLine = info.typeName.replaceAll(' / ', ' |');
    final screenH = MediaQuery.of(context).size.height;
    // 壁纸场景固定白色系文字（背景是深色海报，不随主题明暗）
    return SafeArea(
      bottom: false,
      child: Padding(
        // 标题下移：海报贴顶占满宽度后（高≈屏高 69%），标题叠在海报下部
        // 渐变区（55% 屏高渐变起点略上方），白字有海报底部色渐变垫底
        padding: EdgeInsets.fromLTRB(16, screenH * 0.52, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.w700,
                height: 1.15,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            // 原名/别名独立一行小字（参考图：主标题下方始终有一行小字副标题）
            if (info.tmdbOriginalName.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                info.tmdbOriginalName,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (metaParts.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                metaParts.join(' · '),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
            if (genreLine.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                genreLine,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------- 顶部操作栏（悬浮，不随内容滚动） ----------

  /// 媒体库刮削「假界面」骨架：TMDB 数据拉取期间显示的占位界面，
  /// 布局与真实详情页一致（头图区 + 标题条 + 双按钮 + 集卡横条 + 演员 + 简介），
  /// 灰块配色贴合深色媒体库风格；顶部返回按钮可用，不会卡死在假界面。
  Widget _buildScrapeSkeleton() {
    final w = MediaQuery.of(context).size.width;
    const radius = BorderRadius.all(Radius.circular(6));
    final block = Color(0x14FFFFFF); // white10
    final blockDim = Color(0x0DFFFFFF); // white6
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 头图占位（16:9 全宽灰块 + 黑渐变延伸到底）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: w * 9 / 16,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x1FFFFFFF),
                    Color(0x0AFFFFFF),
                    Colors.black,
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
            ),
          ),
          // 内容骨架
          Positioned(
            top: w * 9 / 16 - 46,
            left: 0,
            right: 0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题条 + 副标题条
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    width: 220,
                    height: 24,
                    decoration: BoxDecoration(
                        color: block, borderRadius: radius),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    width: 140,
                    height: 12,
                    decoration: BoxDecoration(
                        color: blockDim, borderRadius: radius),
                  ),
                ),
                const SizedBox(height: 30),
                // 双按钮占位
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 48,
                          decoration: BoxDecoration(
                            color: block,
                            borderRadius:
                                const BorderRadius.all(Radius.circular(24)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          height: 48,
                          decoration: BoxDecoration(
                            color: blockDim,
                            borderRadius:
                                const BorderRadius.all(Radius.circular(24)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                // 剧集标题 + 集卡横条
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    width: 90,
                    height: 16,
                    decoration: BoxDecoration(
                        color: block, borderRadius: radius),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 106,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: 4,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 150,
                          height: 84,
                          decoration: BoxDecoration(
                            color: block,
                            borderRadius:
                                const BorderRadius.all(Radius.circular(10)),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          width: i.isEven ? 110 : 76,
                          height: 10,
                          decoration: BoxDecoration(
                              color: blockDim, borderRadius: radius),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 26),
                // 导演条
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    width: 180,
                    height: 12,
                    decoration: BoxDecoration(
                        color: blockDim, borderRadius: radius),
                  ),
                ),
                const SizedBox(height: 24),
                // 演员横排（圆占位 + 名字条）
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: List.generate(5, (_) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: Column(
                          children: [
                            Container(
                              width: 56,
                              height: 56,
                              decoration: const BoxDecoration(
                                color: Color(0x14FFFFFF),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              width: 44,
                              height: 9,
                              decoration: BoxDecoration(
                                  color: blockDim, borderRadius: radius),
                            ),
                          ],
                        ),
                      );
                    }),
                  ),
                ),
                const SizedBox(height: 24),
                // 简介块
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    width: double.infinity,
                    height: 56,
                    decoration: BoxDecoration(
                        color: blockDim, borderRadius: radius),
                  ),
                ),
              ],
            ),
          ),
          // 顶栏（返回可用，其余占位）
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  _circleIconButton(
                    Icons.arrow_back,
                    onTap: () => Get.back(),
                  ),
                  const Spacer(),
                  _circleIconButton(Icons.search, onTap: () {}),
                  const SizedBox(width: 10),
                  _circleIconButton(Icons.favorite_border, onTap: () {}),
                ],
              ),
            ),
          ),
          // 刮削提示
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '正在刮削 TMDB 数据…',
                      style: TextStyle(
                        color: AppTheme.accentColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(VodInfo info) {
    return Positioned(
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
              // 手动匹配 TMDB：搜索 → 点选候选 → 自动刮削回填
              //（T 字图标，背景与其它圆形按钮一致）
              _circleIconButton(
                Icons.search,
                onTap: _openTmdbMatch,
                label: 'T',
              ),
              const SizedBox(width: 10),
              // 收藏（仅主路径有 Video 时可用；空心/实心切换）
              if (_video != null)
                _circleIconButton(
                  _collected ? Icons.favorite : Icons.favorite_border,
                  onTap: _toggleCollect,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 收藏切换（addCollect / removeCollect）
  Future<void> _toggleCollect() async {
    final video = _video;
    if (video == null) return;
    final store = CacheStore.instance;
    if (_collected) {
      await store.removeCollect(video.id, video.sourceKey);
    } else {
      await store.addCollect(video);
    }
    if (mounted) setState(() => _collected = !_collected);
  }

  /// 手动匹配 TMDB：进入「匹配 TMDB」搜索页 → 点选候选 →
  /// 自动刮削填充本详情页数据，完成后返回并刷新。
  Future<void> _openTmdbMatch() async {
    final result = await Navigator.push<(String, Map<String, dynamic>)>(
      context,
      MaterialPageRoute(
        builder: (_) => TmdbMatchPage(initialKeyword: _info?.name ?? ''),
      ),
    );
    if (result == null || !mounted) return;
    final info = _info;
    if (info == null) return;
    final (type, item) = result;
    final name = (item['title'] ?? item['name'] ?? '').toString();
    // 刮削中反馈
    AppToast.show('正在刮削', '「$name」…');
    final ok = await TmdbService.instance.applyCandidate(info, type, item);
    if (!mounted) return;
    setState(() {
      _tmdbAttempted = true;
      _tmdbOk = ok;
      _personWorks = const <Map<String, dynamic>>[];
      _worksTriggered = false;
    });
    AppToast.show(
      ok ? 'TMDB 数据已更新' : '刮削失败',
      ok ? '✅' : (TmdbService.instance.lastEnrichError.value ?? '未知错误'),
    );
    if (ok) _loadPersonWorks();
  }

  // ---------- 元数据 + 双按钮 ----------

  Widget _buildMetaButtons(VodInfo info) {
    final hasSource = info.currentEpisodes.isNotEmpty;
    return Padding(
      // 按钮区：与参考图一致，紧贴标题元数据下方（约 52% 屏高）
      padding: const EdgeInsets.fromLTRB(16, 30, 16, 6),
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
          // 选集：底部弹出播放列表菜单栏（分组 + 正/倒序 + 定位）
          Expanded(
            child: _actionButton(
              label: '选集',
              filled: false,
              enabled: hasSource,
              onTap: () {
                if (hasSource) _showEpisodeMenu();
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
                  : Colors.white54,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: enabled
                    ? (filled ? Colors.white : accent)
                    : Colors.white54,
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
            // 集数优先用 TMDB 官方总集数（参考图 "47 ep"），源解析集数兜底
            '剧集  ${info.episodeCount > 0 ? info.episodeCount : eps.length}集',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          height: 128,
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

  /// 单集详情弹窗：点击选集卡弹出，显示该集封面 + 完整简介 + 评分/日期/时长，
  /// 底部「立即播放」进入播放（原「点击集卡即播」能力保留在弹窗里）。
  void _showEpisodeDetail(
      VodInfo info, int epNo, String epTitle, String still, int index) {
    final detail = info.episodeDetails[epNo];
    final overview = detail?.overview ?? '';
    final rating = detail?.rating ?? 0;
    final airDate = detail?.airDate ?? '';
    final runtime = detail?.runtime ?? 0;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final accent = AppTheme.accentColor;
        return Container(
          decoration: BoxDecoration(
            color: AppTheme.backgroundSecondary,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 拖拽条
                Center(
                  child: Container(
                    width: 34,
                    height: 4,
                    margin: const EdgeInsets.only(top: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.borderMedium,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // 标题 + 关闭
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '第$epNo集  $epTitle',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => Navigator.pop(ctx),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(
                            Icons.close,
                            size: 18,
                            color: AppTheme.textTertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 封面横幅（16:9）
                if (still.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: CachedNetworkImage(
                        imageUrl: still,
                        width: double.infinity,
                        height: 168,
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            ColoredBox(color: Colors.black26),
                        errorWidget: (_, __, ___) =>
                            ColoredBox(color: Colors.black26),
                      ),
                    ),
                  ),
                // 元数据行：评分 · 日期 · 时长
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(
                    children: [
                      if (rating > 0) ...[
                        Icon(Icons.star_rounded,
                            size: 13, color: Colors.amber.shade400),
                        const SizedBox(width: 2),
                        Text(
                          rating.toStringAsFixed(1),
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (airDate.isNotEmpty)
                        Text(
                          airDate,
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      if (runtime > 0) ...[
                        const SizedBox(width: 10),
                        Text(
                          '$runtime 分钟',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Divider(height: 1),
                ),
                // 完整简介
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: overview.isNotEmpty
                        ? Text(
                            overview,
                            style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 13,
                              height: 1.5,
                            ),
                          )
                        : Text(
                            '暂无简介',
                            style: TextStyle(
                              color: AppTheme.textTertiary,
                              fontSize: 13,
                            ),
                          ),
                  ),
                ),
                // 立即播放
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(23),
                        ),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        setState(() => _selectedIndex = index);
                        _playAt(index);
                      },
                      icon: const Icon(Icons.play_arrow_rounded, size: 22),
                      label: const Text(
                        '立即播放',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 选集卡（参考 TMDB 集卡样式）：
  /// 封面（still 剧照）上叠两行简介，封面下方放集号+集标题；
  /// 点击卡片弹出单集详情（完整简介）。
  Widget _episodeCard(VodInfo info, List<Episode> eps, int i) {
    final ep = eps[i];
    // 剧照键 = TMDB 真实集号；源的列表位置可能错位（非从第 1 集起/缺集/顺序不同），
    // 优先从集名解析真实集号（"第1集"/"01 命运"/"EP01"…），解析不到回退列表位置 i+1
    final epNo = _parseEpisodeNumber(ep.name) ?? (i + 1);
    final epDetail = info.episodeDetails[epNo];
    // 封面：剧照优先，回退 TMDB 背板/海报
    final still = info.episodeStills[epNo] ??
        (info.backdrop.isNotEmpty ? info.backdrop : info.pic) ??
        '';
    final epTitle = info.episodeTitles[epNo] ?? ep.name;
    final overview = epDetail?.overview ?? '';
    final rating = epDetail?.rating ?? 0;
    final runtime = epDetail?.runtime ?? 0;
    final selected = i == _selectedIndex;
    final accent = AppTheme.accentColor;

    return Container(
      width: 150,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: selected ? Border.all(color: accent, width: 1.5) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面 + 图上简介：点击弹单集详情（保留原弹窗）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                _showEpisodeDetail(info, epNo, epTitle, still, i),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 150,
                height: 84,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (still.isNotEmpty)
                      CachedNetworkImage(
                        imageUrl: still,
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            ColoredBox(color: Colors.black26),
                        errorWidget: (_, __, ___) =>
                            ColoredBox(color: Colors.black26),
                      )
                    else
                      ColoredBox(color: Colors.black26),
                    // 底部渐变 + 两行简介（最多两行，超出隐藏）
                    if (overview.isNotEmpty)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(7, 14, 7, 5),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.85),
                              ],
                            ),
                          ),
                          child: Text(
                            overview,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              height: 1.25,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    // 封面右下角：时长角标（如 46分钟）
                    if (runtime > 0)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '$runtime分钟',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
            // 封面下方：集号（中文序数「第一集/第二集…」）+ 集标题；
            // 点击此处直接跳转播放（不弹详情）
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _controller.selectEpisode(i);
                setState(() => _selectedIndex = i);
                _playAt(i);
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(3, 4, 3, 0),
                child: Text(
                  _epTitleDisplay(epTitle),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      );
  }

  // ---------- 导演 ----------

  /// 从集名解析真实集号："第1集"/"01 命运"/"EP01"/"第一集" → 1；
  /// 解析不到返回 null（调用方回退列表位置）。
  int? _parseEpisodeNumber(String name) {
    if (name.isEmpty) return null;
    // 中文数字："第一集"…"第十集"
    const cn = <String, int>{
      '零': 0, '一': 1, '二': 2, '三': 3, '四': 4,
      '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
    };
    final cnMatch = RegExp(r'第([一二三四五六七八九十]+)集').firstMatch(name);
    if (cnMatch != null) {
      final s = cnMatch.group(1)!;
      if (s == '十') return 10;
      if (s.length == 2 && s[0] == '十') {
        return 10 + (cn[s[1]] ?? 0);
      }
      if (s.length == 2 && s[1] == '十') {
        return (cn[s[0]] ?? 0) * 10;
      }
      return cn[s];
    }
    // 阿拉伯数字：01 / 1 / EP01 / 第1集（取第一个 1-3 位数字）
    final m = RegExp(r'(\d{1,3})').firstMatch(name);
    if (m != null) return int.tryParse(m.group(1)!);
    return null;
  }

  /// 阿拉伯数字 → 中文序数："第一集"…"第九十九集"
  String _chineseOrdinal(int n) {
    const cn = <String>[
      '零', '一', '二', '三', '四', '五', '六', '七', '八', '九',
    ];
    if (n <= 0) return '第$n集';
    if (n >= 100) return '第$n集';
    String s;
    if (n >= 10) {
      final tens = n ~/ 10;
      final ones = n % 10;
      s = (tens == 1 ? '十' : '${cn[tens]}十');
      if (ones > 0) s += cn[ones];
    } else {
      s = cn[n];
    }
    return '第${s}集';
  }

  /// 剧集名展示：名称前是纯数字（"1"/"01"/"1 xxx"）时转中文序数
  /// （"第一集 xxx"），已有"第X集"或非数字开头保持原名。
  String _epTitleDisplay(String title) {
    if (title.isEmpty) return title;
    final m = RegExp(r'^(\d{1,3})\s*[\s.、:：\-]?(.*)$').firstMatch(title);
    if (m == null) return title;
    final n = int.tryParse(m.group(1)!);
    if (n == null) return title;
    final rest = (m.group(2) ?? '').trim();
    if (rest.isEmpty) return _chineseOrdinal(n);
    return '${_chineseOrdinal(n)} ${rest}';
  }

  Widget _buildDirector(VodInfo info) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        '导演: ${info.director}',
        style: const TextStyle(color: Colors.white70, fontSize: 13),
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
            style: const TextStyle(
              color: Colors.white,
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
                      backgroundColor: Colors.black26,
                      foregroundImage: m.hasPhoto
                          ? CachedNetworkImageProvider(m.avatarUrl)
                          : null,
                      child: m.hasPhoto
                          ? null
                          : const Icon(
                              Icons.person_outline,
                              color: Colors.white54,
                            ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      m.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (m.character.isNotEmpty) ...[
                      Text(
                        m.character,
                        style: const TextStyle(
                          color: Colors.white54,
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
    final needFold = info.des.length > 90;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '简介',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            info.des,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.5,
            ),
            // 默认折叠 4 行，点「展开全部」看完整简介
            maxLines: (_overviewExpanded || !needFold) ? null : 4,
            overflow: (_overviewExpanded || !needFold)
                ? null
                : TextOverflow.ellipsis,
          ),
          if (needFold)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  setState(() => _overviewExpanded = !_overviewExpanded),
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _overviewExpanded ? '收起' : '展开全部',
                  style: TextStyle(
                    color: AppTheme.accentColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------- TMDB 刮削未命中提示 ----------

  Widget _buildTmdbMiss(VodInfo info) {
    final accent = AppTheme.accentColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 15, color: Colors.white54),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'TMDB 未匹配到「${info.name}」的详情数据，导演 / 演员 / 简介暂缺',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _enrichFromTmdb(force: true),
            child: Text(
              '重新刮削',
              style: TextStyle(
                color: accent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 相关推荐（主演作品） ----------

  Widget _buildRelatedWorks(VodInfo info) {
    final lead = info.castList.isNotEmpty ? info.castList.first.name : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Text(
            lead.isNotEmpty ? '$lead 的相关作品' : '相关推荐',
            style: const TextStyle(
              color: Colors.white,
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
            itemCount: _personWorks.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, i) => _relatedCard(_personWorks[i]),
          ),
        ),
      ],
    );
  }

  Widget _relatedCard(Map<String, dynamic> w) {
    final mediaType = (w['mediaType'] ?? 'movie').toString();
    final title = (w['title'] ?? '').toString();
    final year = (w['year'] ?? '').toString();
    final rating = (w['rating'] as num?)?.toDouble() ?? 0;
    final posterPath = (w['posterPath'] ?? '').toString();
    final id = (w['id'] as num?)?.toInt() ?? 0;
    final poster = posterPath.startsWith('http')
        ? posterPath
        : (posterPath.isNotEmpty
            ? 'https://image.tmdb.org/t/p/w342$posterPath'
            : '');
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // 用 TMDB 数据构造新媒体库详情（无 Spider 源 → 只展示 + 刮削）
        final info = VodInfo(
          id: 'tmdb-$mediaType-$id',
          name: title,
          pic: poster,
          year: year,
          typeName: mediaType == 'tv' ? '剧集' : '电影',
          tmdbName: title,
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
                child: poster.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: poster,
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
              title,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (year.isNotEmpty || rating > 0)
              Text(
                [if (year.isNotEmpty) year, if (rating > 0) '${rating.toStringAsFixed(1)}★']
                    .join(' · '),
                style: const TextStyle(color: Colors.white54, fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
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
            style: const TextStyle(
              color: Colors.white,
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
                        placeholder: (_, __) => ColoredBox(color: Colors.black26),
                        errorWidget: (_, __, ___) =>
                            ColoredBox(color: Colors.black26),
                      )
                    : ColoredBox(color: Colors.black26),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              style: const TextStyle(color: Colors.white, fontSize: 12),
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

  Widget _circleIconButton(IconData icon, {VoidCallback? onTap, String? label}) {
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
        child: label != null
            // 文字型圆形按钮（如「匹配 TMDB」的 T 字）
            ? Center(
                child: Text(
                  label,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              )
            : Icon(icon, color: AppTheme.textPrimary, size: 20),
      ),
    );
  }
}
