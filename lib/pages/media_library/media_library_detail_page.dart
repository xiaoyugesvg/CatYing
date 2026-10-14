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
import '../../services/app_log.dart';
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

  /// 选集面板：列表 / 4 宫格视图切换
  bool _epGridMode = false;

  /// 选集面板：分页大小（每 50 集一页）
  static const int _epPageSize = 50;
  int _epPageIndex = 0;

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

  // ============================================================
  // 媒体库固定深色风格（"路线 1"：本页与全局明暗解耦）
  // ============================================================
  //
  // 为什么需要这一组常量：海报以下是"封面主色 → 主色压暗"的**不透明**渐变
  // （见 `_buildWallpaper`），底色恒为暗色。若文字仍用 `AppTheme.textPrimary`，
  // 浅色模式下就是"深字压暗底"→ 直接看不见。所以本页内容恒用浅色字/暗色卡。
  //
  // 唯一必须单独钉住的是**强调色**：`AppTheme.accentColor` 取的是调色板的
  // `primary`，默认「水墨书香」调色板下是 `#3A3A3A`（墨灰）—— 压在暗底上
  // 等于看不见；而调色板是**与明暗模式无关**的，所以不能靠切模式解决。
  // 这里恒用目标图里的蓝。想改回跟主题走，只改这一行即可。
  static const Color _libAccent = Color(0xFF3B82F6);
  static const Color _libText = Color(0xFFFFFFFF);
  static const Color _libCard = Color(0x14FFFFFF); // white8
  static const Color _libBorder = Color(0x1FFFFFFF); // white12

  /// 海报底部取色**未完成/失败**时的兜底底色。
  /// 不能用 `AppTheme.backgroundPrimary`：浅色模式下是宣纸米白，压暗后是脏灰，
  /// 而且首帧（取色未回来）与最终态会明显跳一下。用中性深色把跳变压到最小。
  static const Color _libGradBase = Color(0xFF14141A);

  /// 压暗：保色相/饱和度，只降明度（比 lerp 到黑更"本色"，不会越调越灰）。
  static Color _darken(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness * (1 - amount)).clamp(0.0, 1.0))
        .toColor();
  }

  /// 渐变压暗比例（可按真机观感微调）：中段 / 末尾。
  static const double _kGradDarkenMid = 0.45;
  static const double _kGradDarkenEnd = 0.82;

  // ============================================================
  // 集号来源：列表位置 → 真实集号（TMDB episode_number）
  // ============================================================
  //
  // 剧照 / 集标题 / 每集简介三张表的**键都是 TMDB `episode_number`**
  // （`TmdbService._applyEpisodeStills` 用 `e['episode_number']` 当 key）。
  // 而页面拿到的是**源**的剧集列表，两者不一定一一对应：
  //   · 源集名没带集号（本项目这部就是："沈家灭门，嘉兰入林府"）→ 只能靠顺序
  //   · 源顺序不同 / 缺集 / 倒序 / 不从第 1 集起 → 按位置取会**错位**
  // 所以这里做一次显式映射，并且**全页共用同一份**（卡片 / 选集列表 / 弹窗），
  // 避免三处各算一套、显示和剧照对不上。
  Map<int, int>? _epNoMap;
  String _epNoMapKey = '';

  /// 标题归一：去掉空白与常见装饰符号，便于"源集名 == TMDB 集标题"的比对。
  static String _normTitle(String s) => s
      .replaceAll(RegExp(r'[\s\u3000]+'), '')
      .replaceAll(RegExp(r'[「」【】\[\]（）()<>《》""'']'), '')
      .toLowerCase();

  /// 标题模糊匹配（互相包含且够长才认，避免短名误配）。
  static int? _fuzzyTitleNo(Map<String, int> titleToNo, String name) {
    final t = _normTitle(name);
    if (t.length < 4) return null;
    for (final e in titleToNo.entries) {
      if (e.key.length < 4) continue;
      if (e.key == t || e.key.contains(t) || t.contains(e.key)) return e.value;
    }
    return null;
  }

  /// 为整份列表算出「列表位置 → 真实集号」。优先级：
  /// ① 集名里带的集号（第X集 / EP01 / 01 xxx …）
  /// ② 集名与 TMDB 集标题**完全一致**（源直接用 TMDB 标题时最可信）
  /// ③ 标题模糊匹配
  /// ④ 与 TMDB 已知集号**按顺序对齐**（解决"源没带集号"的情况）
  /// ⑤ 位置兜底
  /// 同时保证**不出现重复集号**（重复会让两集显示同一张剧照）。
  Map<int, int> _episodeNoMap(VodInfo info, List<Episode> eps) {
    final key = '${info.name}|${eps.length}|'
        '${info.episodeTitles.length}|${info.episodeStills.length}';
    final cached = _epNoMap;
    if (cached != null && _epNoMapKey == key) return cached;

    // TMDB 已知集号（升序）：三张表的键合集
    final tmdbNos = <int>{
      ...info.episodeTitles.keys,
      ...info.episodeStills.keys,
      ...info.episodeDetails.keys,
    }.where((n) => n > 0).toList()
      ..sort();

    final titleToNo = <String, int>{};
    for (final e in info.episodeTitles.entries) {
      final t = _normTitle(e.value);
      if (t.length >= 2 && !titleToNo.containsKey(t)) titleToNo[t] = e.key;
    }

    final used = <int>{};
    final map = <int, int>{};
    int take(int want, int index) {
      if (want > 0 && !used.contains(want)) {
        used.add(want);
        return want;
      }
      // 想用的号被占用/无效 → 与 TMDB 集号按顺序对齐
      if (index < tmdbNos.length && !used.contains(tmdbNos[index])) {
        final n = tmdbNos[index];
        used.add(n);
        return n;
      }
      for (final n in tmdbNos) {
        if (!used.contains(n)) {
          used.add(n);
          return n;
        }
      }
      final n = want > 0 ? want : index + 1;
      used.add(n);
      return n;
    }

    for (var i = 0; i < eps.length; i++) {
      final name = eps[i].name;
      var no = _parseEpisodeNumber(name);
      if (no == null || (tmdbNos.isNotEmpty && !tmdbNos.contains(no))) {
        no = titleToNo[_normTitle(name)] ?? _fuzzyTitleNo(titleToNo, name);
      }
      map[i] = take(no ?? 0, i);
    }
    // ── 自诊断（每次列表/剧照表变化只记一条）──────────────────
    // 一条日志就能区分"剧照拿不到"的两类原因：
    //   · TMDB 剧照 0 张        → **取数侧**问题（缓存 / 代理路由 / 超时）
    //                             → 再看 TmdbService 的 `缓存补拉剧照…` 日志
    //   · 剧照 N 张但命中 0 集  → **键映射**问题（源集名与 TMDB 标题差异过大）
    final hit = map.values.where(info.episodeStills.containsKey).length;
    AppLog.instance.log('[MediaLibrary] 集号映射: 列表 ${eps.length} 集 / '
        'TMDB 剧照 ${info.episodeStills.length} 张 / '
        '集标题 ${info.episodeTitles.length} 条 → 剧照命中 $hit 集');
    _epNoMap = map;
    _epNoMapKey = key;
    return map;
  }

  /// 取某一列表位置的真实集号（拿不到就用位置兜底）。
  int _episodeNoAt(VodInfo info, List<Episode> eps, int index) {
    if (index < 0 || index >= eps.length) return index + 1;
    return _episodeNoMap(info, eps)[index] ?? (index + 1);
  }

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
    _epPageIndex = 0;
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
          // ⚠️ **整张弹窗再套一层 Stack**：线路下拉菜单改挂在这一层（见本方法末尾）✓
          //   根因 ✗：菜单原来是第一排那个**只有 ≈50 高**的局部 Stack 里的
          //   `Positioned(top:46)`；`clipBehavior: Clip.none` 只能让它**画**得出来 ✗，
          //   命中测试仍以父级 size 为界（`RenderBox.hitTest` → `size.contains(position)`）
          //   ⇒ 越出那 50px 的部分**永远点不到** ✓ —— 这就是"线路切换点击不了"的原因 ✓
          return Stack(
            children: [
              Column(
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
              // 第一排：选集 + 线路名（点击下拉切换）+ 集数 + 视图切换 + 排序 + 定位
              // ℹ️ 原来这里套了个 `Stack(clipBehavior: Clip.none)` 专门放线路下拉菜单，
              //    但那层只有 ≈50 高 ⇒ 菜单"画得出、点不到"✗；菜单已挪到整张弹窗的 Stack ✓
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
                          icon: _epGridMode
                              ? Icons.grid_view_rounded
                              : Icons.view_list_rounded,
                          label: _epGridMode ? '宫格' : '列表',
                          active: false,
                          onTap: () =>
                              setSheetState(() => _epGridMode = !_epGridMode),
                        ),
                        const SizedBox(width: 8),
                        _sheetAction(
                          icon: _episodeDesc
                              ? Icons.arrow_downward
                              : Icons.arrow_upward,
                          label: _episodeDesc ? '倒序' : '正序',
                          active: _episodeDesc,
                          onTap: () => setSheetState(() {
                                _episodeDesc = !_episodeDesc;
                                _epPageIndex = 0;
                              }),
                        ),
                        const SizedBox(width: 8),
                        _sheetAction(
                          icon: Icons.my_location,
                          label: '定位当前集',
                          active: false,
                          onTap: () {
                            final qNow = query.trim();
                            var targetInList = _episodeDesc
                                ? (eps.length - 1 - current)
                                : current;
                            if (qNow.isNotEmpty) {
                              final curOrdered = _episodeDesc
                                  ? (eps.length - 1 - current)
                                  : current;
                              final fi = indexed
                                  .indexWhere((e) => e.key == curOrdered);
                              targetInList = fi < 0 ? 0 : fi;
                            }
                            // 先切到目标所在页，再滚到具体位置
                            final page = targetInList ~/ _epPageSize;
                            setSheetState(() => _epPageIndex = page);
                            WidgetsBinding.instance
                                .addPostFrameCallback((_) {
                              if (!_episodeListScroll.hasClients) return;
                              final idxInPage =
                                  targetInList % _epPageSize;
                              final offset = _epGridMode
                                  ? (idxInPage ~/ 4) *
                                      80.0 // 宫格：每行约 80px
                                  : idxInPage *
                                      48.0; // 列表：每行约 48px
                              _episodeListScroll.animateTo(
                                offset,
                                duration:
                                    const Duration(milliseconds: 260),
                                curve: Curves.easeOut,
                              );
                            });
                          },
                        ),
                      ],
                    ),
                  ),
              // 第二排：搜索框（搜索剧集）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  onChanged: (v) => setSheetState(() {
                    query = v;
                    _epPageIndex = 0; // 搜索变化时回到第 1 页
                  }),
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
                                setSheetState(() {
                                  query = '';
                                  _epPageIndex = 0;
                                }),
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
              // 第三排：分页 tab（1-50 / 51-100 / …），集数多时才显示
              if (indexed.length > _epPageSize)
                _buildEpisodePagination(indexed.length, setSheetState),
              Divider(height: 1, color: AppTheme.borderLight),
              // 播放列表（支持搜索过滤 + 分页 + 列表/宫格切换）
              Expanded(
                child: () {
                  // 当前页数据
                  final total = indexed.length;
                  final pageCount = (total / _epPageSize).ceil();
                  final page = _epPageIndex.clamp(0, pageCount - 1);
                  final start = page * _epPageSize;
                  final end = (start + _epPageSize).clamp(0, total);
                  final pageItems = indexed.sublist(start, end);

                  if (_epGridMode) {
                    return GridView.builder(
                      controller: _episodeListScroll,
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 1.0,
                      ),
                      itemCount: pageItems.length,
                      itemBuilder: (_, i) {
                        final orderedIdx = pageItems[i].key;
                        final ep = pageItems[i].value;
                        final realIndex = _episodeDesc
                            ? eps.length - 1 - orderedIdx
                            : orderedIdx;
                        final selected = realIndex == current;
                        final epNo = _episodeNoAt(info, eps, realIndex);
                        return InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () {
                            _controller.selectEpisode(realIndex);
                            Navigator.pop(ctx);
                            setState(() => _selectedIndex = realIndex);
                            _playAt(realIndex);
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: selected
                                  ? accent.withValues(alpha: 0.18)
                                  : AppTheme.backgroundTertiary,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: selected
                                    ? accent
                                    : AppTheme.borderLight,
                                width: selected ? 1.2 : 0.5,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  '$epNo',
                                  style: TextStyle(
                                    color: selected
                                        ? accent
                                        : AppTheme.textPrimary,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4),
                                  child: Text(
                                    ep.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: selected
                                          ? AppTheme.textPrimary
                                          : AppTheme.textSecondary,
                                      fontSize: 10,
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

                  // 列表模式
                  return ListView.separated(
                    controller: _episodeListScroll,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: pageItems.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: AppTheme.borderLight),
                    itemBuilder: (_, i) {
                      final orderedIdx = pageItems[i].key;
                      final ep = pageItems[i].value;
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
                                  '${_episodeNoAt(info, eps, realIndex)}',
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
                                  _epTitleDisplay(
                                    ep.name,
                                    _episodeNoAt(info, eps, realIndex),
                                  ),
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
                  );
                }(),
              ),
                ],
              ),

              // ── 线路下拉菜单 ─────────────────────────────────────────
              // ⚠️ 必须挂在**整张弹窗**这一层 Stack 上 ✓
              //   放在第一排那个只有 ≈50 高的局部 Stack 里时，`Clip.none` 只让它
              //   "画得出来"✗ —— Flutter 的命中测试以父级 size 为界
              //   （`RenderBox.hitTest` → `size.contains(position)`）⇒
              //   越界的那 160 多像素**永远点不到** ✓（= "线路切换点击不了"的根因 ✓）
              // ℹ️ `top: 60` = 拖拽条(≈14) + 第一排上内边距(12) + 线路胶囊高(28) + 间距(6)，
              //    与原来"相对第一排 top:46"的视觉位置一致 ✓
              if (flagMenuOpen && flags.length > 1)
                Positioned(
                  top: 60,
                  left: 16,
                  // ≤4 项（每项 42 高），超出可滑动（无滚动条图标）
                  child: Container(
                    width: 200,
                    constraints: const BoxConstraints(maxHeight: 168),
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundSecondary,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppTheme.borderLight),
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
                            _epPageIndex = 0; // 切线路回到第 1 页
                            flagMenuOpen = false;
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9),
                          color: flags[i] == _episodeSelectedFlag
                              ? AppTheme.accentColor.withValues(alpha: 0.15)
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

  /// 选集面板：分页 tab 栏（1-50 / 51-100 / …）。
  ///
  /// 总集数 ≤ 50 时不显示（调用方控制）。
  /// 横滑 tab，当前页高亮；点击即切换并滚到顶部。
  Widget _buildEpisodePagination(int total, StateSetter setSheetState) {
    final pageCount = (total / _epPageSize).ceil();
    if (pageCount <= 1) return const SizedBox.shrink();
    final cur = _epPageIndex.clamp(0, pageCount - 1);
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: pageCount,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final from = i * _epPageSize + 1;
          final to = ((i + 1) * _epPageSize).clamp(0, total);
          final selected = i == cur;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setSheetState(() => _epPageIndex = i);
              // 切页后滚回顶部
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_episodeListScroll.hasClients) {
                  _episodeListScroll.jumpTo(0);
                }
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? AppTheme.accentColor.withValues(alpha: 0.18)
                    : AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected
                      ? AppTheme.accentColor
                      : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Text(
                '$from-$to',
                style: TextStyle(
                  color: selected
                      ? AppTheme.accentColor
                      : AppTheme.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        },
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

  /// 取图片主色调（下半 40% 区域平均色 —— 海报主体色，做渐变用）。
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
      // 采样下半 40% 区域（海报主体色，偏亮海报也取得到主色）
      var r = 0, g = 0, b = 0, n = 0;
      final yStart = (h * 0.55).floor();
      final yEnd = (h * 0.95).floor();
      for (var y = yStart; y < yEnd; y++) {
        for (var x = 0; x < w; x += 2) {
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
    // 取色失败/未完成兜底：用中性深色（**不能**用 AppTheme.backgroundPrimary ——
    // 浅色模式下是宣纸米白，压暗后是脏灰，且首帧与取色完成后会明显跳变）
    final edge = _posterEdgeColor ?? _libGradBase;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. 竖版海报：原图宽度铺满屏幕、完整不裁切、贴顶部；
        //    底部叠加一层「主色调渐入」过渡带，与下方渐变区无缝衔接
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: posterH,
          child: poster.isNotEmpty
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      imageUrl: poster,
                      fit: BoxFit.fill,
                      placeholder: (_, __) =>
                          ColoredBox(color: Colors.black),
                      errorWidget: (_, __, ___) =>
                          ColoredBox(color: Colors.black),
                    ),
                    // 海报底边过渡带：透明 → 主色调（高 70px，消掉硬分界）
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 70,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              edge.withValues(alpha: 0),
                              edge,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : ColoredBox(color: _libGradBase),
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
        // 3. 从海报底边正下方开始向下：**"封面主色 → 主色压暗"的真渐变**。
        //
        //    ⚠️ 原来这里是 `[edge, edge(alpha .9), edge]` —— 三个停靠点
        //    **用的是同一个颜色**，只有中间 10% alpha 差，视觉上就是
        //    **一块纯色**（用户实测："海报下面是一块平的灰绿"）。
        //    真渐变必须有**第二个颜色**，只调 alpha 是不够的。
        //
        //    现在：起点仍是 `edge` 且 alpha=1 → 与上面那条 70px 过渡带
        //    （结尾也是 `edge` alpha=1）**无缝衔接**，不会出现亮度突变黑线；
        //    然后向下压暗到 `_kGradDarkenEnd`，末尾接近深色。
        //
        //    全程**不透明**：半透明会把下层全局壁纸（浅色模式是米白）透上来，
        //    把主色的色相冲淡成灰 —— 这是原来发灰的另一个原因。
        Positioned(
          left: 0,
          right: 0,
          top: posterH.clamp(0.0, screenH),
          bottom: 0,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  edge,
                  _darken(edge, _kGradDarkenMid),
                  _darken(edge, _kGradDarkenEnd),
                ],
                stops: const [0.0, 0.30, 1.0],
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
    // 封面主色调偏亮（白/浅色海报）时，文字包一层淡灰底保证可读
    final lightEdge = _posterEdgeColor != null &&
        _posterEdgeColor!.computeLuminance() > 0.55;
    Widget lightWrap(Widget child) => lightEdge
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black38,
              borderRadius: BorderRadius.circular(8),
            ),
            child: child,
          )
        : child;
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
            lightWrap(
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
            ),
            // 原名/别名独立一行小字（参考图：主标题下方始终有一行小字副标题）
            if (info.tmdbOriginalName.isNotEmpty) ...[
              const SizedBox(height: 4),
              lightWrap(
                Text(
                  info.tmdbOriginalName,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (metaParts.isNotEmpty) ...[
              const SizedBox(height: 10),
              lightWrap(
                Text(
                  metaParts.join(' · '),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
            if (genreLine.isNotEmpty) ...[
              const SizedBox(height: 5),
              lightWrap(
                Text(
                  genreLine,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
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
                        color: _libAccent,
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
    final accent = _libAccent;
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
                          // 统一走中文序数（"第一集 沈家灭门…"）。`epTitle` 若自带
                          // "第X集"前缀，`_epTitleDisplay` 会原样返回，不会重复
                          _epTitleDisplay(epTitle, epNo),
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
                        // 封面/剧照统一拉伸显示、不裁切（与首页一致）
                        fit: BoxFit.fill,
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
    // 剧照键 = TMDB 真实集号。**必须用整份列表算出的映射**，不能只解析本集名字：
    //   · 源集名可能不带集号（本项目这部就是"沈家灭门，嘉兰入林府"）→ 靠顺序对齐
    //   · 源的顺序可能不同 / 缺集 / 不从第 1 集起 → 按位置取会**错位**
    //   · 集名与 TMDB 集标题一致时直接比对（最可信）
    // 详见 `_episodeNoMap`。
    final epNo = _episodeNoAt(info, eps, i);
    final epDetail = info.episodeDetails[epNo];
    // 封面：剧照优先（空串也视为无，继续回退背板/海报 —— 空串会挡住 ?? 回退）
    final stillRaw = info.episodeStills[epNo] ?? '';
    final still = stillRaw.isNotEmpty
        ? stillRaw
        : (info.backdrop.isNotEmpty ? info.backdrop : info.pic);
    final epTitle = info.episodeTitles[epNo] ?? ep.name;
    final runtime = epDetail?.runtime ?? 0;
    final selected = i == _selectedIndex;
    final accent = _libAccent;

    return Container(
      width: 150,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面（剧照 + 选中角标 + 时长角标）：点击弹单集详情（保留原弹窗）
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
                        fit: BoxFit.fill, // 同上：不裁切
                        placeholder: (_, __) =>
                            ColoredBox(color: Colors.black26),
                        errorWidget: (_, __, ___) =>
                            ColoredBox(color: Colors.black26),
                      )
                    else
                      ColoredBox(color: Colors.black26),
                    // 选中角标：左上角 accent 蓝底白字「▶」（替代纯描边，醒目不显黑）
                    if (selected)
                      Positioned(
                        top: 5,
                        left: 5,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 14,
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
            // 点击此处直接跳转播放（不弹详情）；电影无集号 → 标题居中
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
                  _epTitleDisplay(epTitle, epNo),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
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

  /// 从集名解析真实集号："第1集"/"第一集"/"第21集"/"第二十一集"/"01 命运"/
  /// "EP01"/"E01"/"1"/"名 - 03" → 1/2/21…；解析不到返回 null（调用方回退）。
  ///
  /// ⚠️ 原来只处理了 `十` / `十X` / `X十` 三种中文数字形态，**`X十Y` 会落到
  /// `cn['二十一']` → null**：于是"第二十一集 / 第三十五集 / 第四十七集"这类
  /// （21–29、31–39、41–49）**全部解析失败并静默回退成列表位置** —— 源顺序一旦
  /// 与 TMDB 不同，剧照就会错位。这里补齐到 99。
  int? _parseEpisodeNumber(String name) {
    if (name.isEmpty) return null;
    // 1) 中文数字：第…集 / 第…话 / 第…話
    final cnMatch =
        RegExp(r'第\s*([一二三四五六七八九十百零两]+)\s*[集话話]').firstMatch(name);
    if (cnMatch != null) {
      final n = _cnNumber(cnMatch.group(1)!);
      if (n != null && n > 0) return n;
    }
    // 2) 英文前缀：EP01 / E01 / EP.1 / EPISODE 1
    final ep = RegExp(r'\b(?:EP|E|EPISODE)\.?\s*(\d{1,3})\b', caseSensitive: false)
        .firstMatch(name);
    if (ep != null) {
      final n = int.tryParse(ep.group(1)!);
      if (n != null && n > 0) return n;
    }
    // 3) 开头的阿拉伯数字："01 命运" / "1" / "1-xxx" / "[01] xxx"
    final head =
        RegExp(r'^\s*[\[\(【]?\s*(\d{1,3})\s*[\]\)】]?\s*[\s.、:：\-]').firstMatch(name);
    if (head != null) {
      final n = int.tryParse(head.group(1)!);
      if (n != null && n > 0) return n;
    }
    // 4) 整名就是数字（含被括号包住）
    final only = RegExp(r'^\s*[\[\(【]?\s*(\d{1,3})\s*[\]\)】]?\s*$').firstMatch(name);
    if (only != null) {
      final n = int.tryParse(only.group(1)!);
      if (n != null && n > 0) return n;
    }
    // 5) 行尾数字："饼干 - 1"（只认行尾，避免吃掉"红色40号"里的 40）
    final tail =
        RegExp(r'[\s\-—.:：、,，]\s*[\[\(【]?\s*(\d{1,3})\s*[\]\)】]?\s*$').firstMatch(name);
    if (tail != null) {
      final n = int.tryParse(tail.group(1)!);
      if (n != null && n > 0) return n;
    }
    // 6) 兜底：名字里第一个 1–3 位数字（保持旧行为，避免"命运1"这类漏掉）
    final any = RegExp(r'(\d{1,3})').firstMatch(name);
    if (any != null) {
      final n = int.tryParse(any.group(1)!);
      if (n != null && n > 0) return n;
    }
    return null;
  }

  /// 中文数字 → int，支持 一~九十九（含 十 / 十一 / 二十 / 二十一 / 两 / 零）。
  static int? _cnNumber(String s) {
    const d = <String, int>{
      '零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
      '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
    };
    final t = s.trim();
    if (t.isEmpty) return null;
    if (t == '百') return 100;
    final i = t.indexOf('十');
    if (i < 0) return d[t]; // 一~九
    final tens = i == 0 ? 1 : (d[t.substring(0, i)] ?? -1);
    if (tens < 0) return null;
    final rest = t.substring(i + 1);
    if (rest.isEmpty) return tens * 10; // 十 / 二十 / 三十
    final ones = d[rest];
    if (ones == null) return null;
    return tens * 10 + ones; // 十一 / 二十一 / 四十七
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
  /// （"第一集 xxx"）；数字在末尾（"饼干 - 1"/"饼干-02"）也提取转前置；
  /// 已有"第X集"前缀保持原名；**纯剧名（TMDB 剧集标题无数字）用集号补
  /// "第一集"前缀**（如「第一集 沈家灭门，嘉兰入林府」）。
  String _epTitleDisplay(String title, int fallbackNo) {
    if (title.isEmpty) return title;
    // 0) 已带"第X集/第一集"前缀（中英文数字均算）→ 原样
    if (RegExp(r'^第\s*[一二三四五六七八九十\d]+\s*集').hasMatch(title)) {
      return title;
    }
    // 1) 开头数字："01 命运" / "1" / "1-xxx"
    final m = RegExp(r'^(\d{1,3})\s*[\s.、:：\-]?(.*)$').firstMatch(title);
    if (m != null) {
      final n = int.tryParse(m.group(1)!);
      if (n != null) {
        final rest = (m.group(2) ?? '').trim();
        if (rest.isEmpty) return _chineseOrdinal(n);
        return '${_chineseOrdinal(n)} ${rest}';
      }
    }
    // 2) 末尾数字："饼干 - 1" / "红色40号 - 2"（只取行尾数字，避免吃掉
    //    "红色40号"这类标题自身的数字）
    final m2 =
        RegExp(r'^(.*?)[\s\-—.:：、,，]*(?:第)?(\d{1,3})\s*$').firstMatch(title);
    if (m2 != null) {
      final rest = (m2.group(1) ?? '').trim();
      final n = int.tryParse(m2.group(2)!);
      if (n != null && rest.isNotEmpty && rest != title.trim()) {
        return '${_chineseOrdinal(n)} ${rest}';
      }
    }
    // 3) 纯剧名无数字 → 用真实集号补中文序数前缀
    return '${_chineseOrdinal(fallbackNo)} ${title}';
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
                    color: _libAccent,
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
    final accent = _libAccent;
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
                        fit: BoxFit.fill, // 同上：封面不裁切
                        placeholder: (_, __) =>
                            ColoredBox(color: _libCard),
                        errorWidget: (_, __, ___) =>
                            ColoredBox(color: _libCard),
                      )
                    : ColoredBox(color: _libCard),
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
                        fit: BoxFit.fill, // 同上：封面不裁切
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
                  color: _libAccent,
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
          color: _libCard.withValues(alpha: 0.8),
          shape: BoxShape.circle,
          border: Border.all(color: _libBorder, width: 0.6),
        ),
        child: label != null
            // 文字型圆形按钮（如「匹配 TMDB」的 T 字）
            ? Center(
                child: Text(
                  label,
                  style: TextStyle(
                    color: _libText,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              )
            : Icon(icon, color: _libText, size: 20),
      ),
    );
  }
}
