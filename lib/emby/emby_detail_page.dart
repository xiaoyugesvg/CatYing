import 'dart:async';

import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import 'emby_api.dart';
import 'emby_models.dart';
import 'emby_player_page.dart';

/// Emby 条目详情：电影显示简介 + 播放；剧集显示分集列表。
///
/// 视觉与「媒体库详情页」（TMDB 刮削）统一：固定深色 + 蓝色强调色，
/// 全屏 Backdrop 头图 + 大标题 + 元信息胶囊，内容直接浮在暗底上
/// （简介 / 选集 / 演职人员 / 影片信息），返回键悬浮在头图上。
class EmbyDetailPage extends StatefulWidget {
  const EmbyDetailPage({super.key, required this.item, required this.server});

  final EmbyItem item;
  final EmbyServer server;

  @override
  State<EmbyDetailPage> createState() => _EmbyDetailPageState();
}

class _EmbyDetailPageState extends State<EmbyDetailPage> {
  // 媒体库详情页同款「固定深色」视觉：与全局明暗解耦，
  // 蓝强调色 + 白色文字 + 白色低透明度卡片（参照 media_library_detail_page）。
  static const Color _libAccent = Color(0xFF3B82F6);
  static const Color _libText = Colors.white;
  static const Color _libSub = Color(0xB3FFFFFF); // white70
  static const Color _libCard = Color(0x14FFFFFF); // white8
  static const Color _libBorder = Color(0x1FFFFFFF); // white12

  // ── 媒体库同款「封面主色调 → 渐变底色」────────────────────────────
  /// 头图取色未完成/失败时的兜底底色（同 media_library_detail_page：
  /// 不能用 AppTheme.backgroundPrimary，浅色模式是宣纸米白，压暗后是脏灰）。
  static const Color _libGradBase = Color(0xFF14141A);

  /// 压暗：保色相/饱和度，只降明度（比 lerp 到黑更"本色"，不会越调越灰）。
  static Color _darken(Color c, double amount) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness * (1 - amount)).clamp(0.0, 1.0))
        .toColor();
  }

  /// 渐变压暗比例（媒体库同款）：中段 / 末尾。
  static const double _kGradDarkenMid = 0.45;
  static const double _kGradDarkenEnd = 0.82;

  late final EmbyApi _api = EmbyApi(widget.server);
  late EmbyItem _item = widget.item;
  List<EmbyItem> _episodes = const [];
  bool _loading = true;
  String? _error;
  bool _overviewExpanded = false;

  /// 头图底部主色（媒体库同款取色，取到后 setState 刷新渐变）。
  Color? _posterEdgeColor;
  String? _posterEdgeUrl;

  /// 正文底色 = 主色压暗到渐变终点（与头图渐变无缝衔接）。
  Color get _bgColor => _posterEdgeColor == null
      ? _libGradBase
      : _darken(_posterEdgeColor!, _kGradDarkenEnd);

  /// 选集区域的 GlobalKey（用于"选集"按钮滚动定位）
  final _episodeSectionKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 列表里的字段可能不全，进来补一次详情
      final detail = await _api.getItem(widget.item.id);
      if (detail != null) _item = detail;
      if (_item.isSeries) {
        _episodes = await _api.getEpisodes(_item.id);
      }
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is EmbyApiException ? e.message : '加载失败：$e';
      });
    }
  }

  void _play(EmbyItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EmbyPlayerPage(
          server: widget.server,
          item: item,
          title: item.isEpisode
              ? '${_item.name} · ${item.episodeLabel}'
              : item.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _buildBackdrop()),
          if (_loading && _item.overview.isEmpty)
            const Center(
              child: CircularProgressIndicator(color: Colors.white70),
            )
          else
            ListView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                // 与媒体库详情页一致：标题下移叠在 backdrop 下部渐变区，
                // 给海报留足展示空间（原 58px 太靠前，标题几乎贴顶）
                SizedBox(height: MediaQuery.of(context).size.height * 0.40),
                _buildHero(),
                const SizedBox(height: 16),
                // 壁纸 → 内容底的过渡（固定高度渐变，避免随内容长度拉伸）
                Container(
                  height: 32,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, _bgColor],
                    ),
                  ),
                ),
                Container(
                  // 媒体库同款：内容直接浮在深色壁纸上（不再垫浅色圆角底板）
                  color: _bgColor,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 44),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_error != null) ...[
                        Text(
                          _error!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: AppTheme.fontFootnote,
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],
                      // 刮削到的类型标签（类型区）
                      if (_item.genres.isNotEmpty) ...[
                        _buildGenres(),
                        const SizedBox(height: 20),
                      ],
                      if (_item.overview.isNotEmpty) _buildOverview(),
                      if (_item.isSeries) ...[
                        if (_item.overview.isNotEmpty)
                          const SizedBox(height: 22),
                        _buildEpisodes(),
                      ],
                      // 刮削到的演职人员（导演 / 编剧 / 演员）
                      if (_item.people.isNotEmpty) ...[
                        const SizedBox(height: 22),
                        _buildPeople(),
                      ],
                      // 出品公司 / 首播日期 / 官方分级等
                      if (_hasFacts) ...[
                        const SizedBox(height: 22),
                        _buildFacts(),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          _buildTopBar(),
        ],
      ),
    );
  }

  // ── 头图 ──────────────────────────────────────────────────

  /// 取图片主色调（下半 40% 区域平均色 —— 主体色，做渐变用）。
  /// 失败返回黑色兜底；结果缓存到 [_posterEdgeColor]，同一头图只取一次。
  /// （与 media_library_detail_page 同款实现）
  Future<Color> _edgeColorOf(String url) async {
    try {
      final prov = CachedNetworkImageProvider(url);
      final stream = prov.resolve(ImageConfiguration.empty);
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

  Widget _buildBackdrop() {
    final hasBackdrop =
        _item.backdropTag != null && _item.backdropTag!.isNotEmpty;
    final url = hasBackdrop
        ? _api.imageUrl(
            _item.backdropImageId,
            tag: _item.backdropTag,
            imageType: 'Backdrop',
            maxHeight: 1080,
          )
        : _api.imageUrl(_item.id, tag: _item.imageTag, maxHeight: 1080);
    // 首次见到的头图 → 异步取底部主色（媒体库同款，取到后 setState 刷新渐变）
    if (_posterEdgeUrl != url) {
      _posterEdgeUrl = url;
      _edgeColorOf(url).then((c) {
        if (mounted && _posterEdgeUrl == url) {
          setState(() => _posterEdgeColor = c);
        }
      });
    }
    // 取色失败/未完成兜底：中性深色（同 media_library_detail_page）
    final edge = _posterEdgeColor ?? _libGradBase;
    // ⚠️ 头图**不能再 cover 铺满整屏**：Backdrop 是 16:9，手机屏是竖的，
    //   cover 会把图横向裁到只剩中间一小块（用户 2026-10-20 截图：
    //   「封面图片放大了很多」）。现在改成「顶部 16:9 清晰头图 + 全屏模糊色晕」。
    final w = MediaQuery.sizeOf(context).width;
    final bannerH = w * 9 / 16;
    return Stack(
      fit: StackFit.expand,
      children: [
        // ① 内容底色（下半屏与正文容器同色，渐变才有落点）
        ColoredBox(color: _bgColor),
        // ② 柔和底：同一张图模糊铺满，只保留色晕（不做清晰填充）
        Positioned.fill(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 32, sigmaY: 32),
            child: Opacity(
              opacity: 0.45,
              child: CachedNetworkImage(
                imageUrl: url,
                httpHeaders: _api.imageHeaders,
                fit: BoxFit.cover,
                placeholder: (_, _) => const ColoredBox(color: Colors.black),
                errorWidget: (_, _, _) => const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
        // ③ 顶部清晰头图：高度 = 宽 × 9/16 ⇒ 不放大、不裁切
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: bannerH,
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: hasBackdrop ? 0 : 18,
              sigmaY: hasBackdrop ? 0 : 18,
            ),
            child: CachedNetworkImage(
              imageUrl: url,
              httpHeaders: _api.imageHeaders,
              fit: BoxFit.cover,
              placeholder: (_, _) => const ColoredBox(color: Colors.black),
              errorWidget: (_, _, _) => const ColoredBox(color: Colors.black),
            ),
          ),
        ),
        // ④ 渐变（媒体库同款取色体系）：顶部压暗（状态栏/返回键可读）+
        //    头图底边起从封面主色向下压暗到正文底色。
        //    铺满整屏并**在正文之前完全变成不透明底色**，否则渐隐结束后
        //    模糊色晕又露出来（出现一条"分层"的硬边）。
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0x8C000000),
                  const Color(0x22000000),
                  Colors.transparent,
                  edge,
                  _darken(edge, _kGradDarkenMid),
                  _darken(edge, _kGradDarkenEnd),
                ],
                stops: [
                  0,
                  0.10,
                  bannerH / MediaQuery.sizeOf(context).height,
                  (bannerH / MediaQuery.sizeOf(context).height) + 0.08,
                  (bannerH / MediaQuery.sizeOf(context).height) + 0.33,
                  1,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHero() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 大标题
          Text(
            _item.name,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
          // 刮削到的宣传语（Tagline）
          if (_item.tagline.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              _item.tagline,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 12),
          // 元数据胶囊行
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_item.year != null) _MetaPill(text: '${_item.year}'),
              if (_item.rating != null && _item.rating! > 0)
                _MetaPill(
                  text: '★ ${_item.rating!.toStringAsFixed(1)}',
                  highlighted: true,
                ),
              if (_item.officialRating.isNotEmpty)
                _MetaPill(text: _item.officialRating),
              if (_item.durationText.isNotEmpty)
                _MetaPill(text: _item.durationText),
              if (_item.type.isNotEmpty)
                _MetaPill(
                  text: _item.isSeries
                      ? '剧集'
                      : _item.isEpisode
                      ? '单集'
                      : '电影',
                ),
            ],
          ),
          const SizedBox(height: 20),
          // 两个按钮：立即播放 + 选集
          Row(
            children: [
              // 立即播放（蓝色主按钮）
              Expanded(
                child: GestureDetector(
                  onTap: () => _play(_item.isEpisode ? _item : _episodes.isNotEmpty ? _episodes.first : _item),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: _libAccent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.play_arrow_rounded,
                          size: 22,
                          color: Colors.white,
                        ),
                        SizedBox(width: 6),
                        Text(
                          '立即播放',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // 选集（透明边框按钮）
              if (_item.isSeries)
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      // 滚动到选集区域
                      Scrollable.ensureVisible(
                        _episodeSectionKey.currentContext!,
                        duration: const Duration(milliseconds: 400),
                        alignment: 0.1,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 1.5),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.list_alt_rounded,
                            size: 22,
                            color: Colors.white,
                          ),
                          SizedBox(width: 6),
                          Text(
                            '选集',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ── 简介 ──────────────────────────────────────────────────

  /// 内容区小标题（左侧竖条 + 标题 + 可选右侧说明）
  Widget _sectionTitle(String title, {String? trailing}) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: _libAccent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: _libText,
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Text(
            trailing,
            style: const TextStyle(
              color: _libSub,
              fontSize: AppTheme.fontCaption,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildGenres() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final g in _item.genres)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            decoration: BoxDecoration(
              color: _libCard,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: _libBorder, width: 0.5),
            ),
            child: Text(
              g,
              style: const TextStyle(
                color: _libSub,
                fontSize: AppTheme.fontCaption,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildOverview() {
    final long = _item.overview.length > 90;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('简介'),
        const SizedBox(height: 10),
        Text(
          _item.overview,
          maxLines: _overviewExpanded ? null : 4,
          overflow: _overviewExpanded
              ? TextOverflow.clip
              : TextOverflow.ellipsis,
          style: const TextStyle(
            color: _libSub,
            fontSize: AppTheme.fontFootnote,
            height: 1.65,
          ),
        ),
        if (long)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () =>
                  setState(() => _overviewExpanded = !_overviewExpanded),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 30),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: _libText,
              ),
              child: Text(
                _overviewExpanded ? '收起' : '展开',
                style: const TextStyle(fontSize: AppTheme.fontFootnote),
              ),
            ),
          ),
      ],
    );
  }

  // ── 选集 ──────────────────────────────────────────────────

  Widget _buildEpisodes() {
    return Column(
      key: _episodeSectionKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('选集', trailing: '${_episodes.length} 集'),
        const SizedBox(height: 12),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_episodes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '没有分集信息',
              style: const TextStyle(
                color: _libSub,
                fontSize: AppTheme.fontFootnote,
              ),
            ),
          )
        else
          // 横向滚动剧集卡片列表
          SizedBox(
            height: 140,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: _episodes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final ep = _episodes[index];
                return _episodeCard(ep);
              },
            ),
          ),
      ],
    );
  }

  /// 横向剧集卡片（缩略图 + 集名 + 时长）
  Widget _episodeCard(EmbyItem ep) {
    return GestureDetector(
      onTap: () => _play(ep),
      child: SizedBox(
        width: 160,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 缩略图（16:9）
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 160,
                height: 90,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      imageUrl: _api.imageUrl(
                        ep.id,
                        tag: ep.imageTag,
                        maxHeight: 240,
                      ),
                      httpHeaders: _api.imageHeaders,
                      fit: BoxFit.cover,
                      placeholder: (_, _) =>
                          const ColoredBox(color: Color(0xFF1A1A20)),
                      errorWidget: (_, _, _) => const ColoredBox(
                        color: Color(0xFF1A1A20),
                        child: Icon(
                          Icons.play_circle_outline_rounded,
                          color: Colors.white38,
                          size: 28,
                        ),
                      ),
                    ),
                    // 播放按钮叠加
                    const Positioned(
                      right: 6,
                      bottom: 6,
                      child: Icon(
                        Icons.play_circle_fill_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                    // 集号角标
                    if (ep.episodeLabel.isNotEmpty)
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            ep.episodeLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // 集名
            Text(
              ep.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _libText,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
            // 时长
            if (ep.durationText.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                ep.durationText,
                style: const TextStyle(
                  color: _libSub,
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── 演职人员（服务端刮削） ─────────────────────────────────

  Widget _buildPeople() {
    final directors = _item.directors;
    final writers = _item.writers;
    final actors = _item.actors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('演职人员'),
        if (directors.isNotEmpty) _creditLine('导演', directors),
        if (writers.isNotEmpty) _creditLine('编剧', writers),
        if (actors.isNotEmpty) ...[
          const SizedBox(height: 14),
          SizedBox(
            height: 124,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: actors.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (_, i) => _personTile(actors[i]),
            ),
          ),
        ],
      ],
    );
  }

  Widget _creditLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0x8CFFFFFF),
                fontSize: AppTheme.fontCaption,
                height: 1.45,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: _libSub,
                fontSize: AppTheme.fontFootnote,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _personTile(EmbyPerson p) {
    return SizedBox(
      width: 72,
      child: Column(
        children: [
          ClipOval(
            child: SizedBox(
              width: 64,
              height: 64,
              child: p.hasPhoto
                  ? CachedNetworkImage(
                      imageUrl: _api.imageUrl(
                        p.id,
                        tag: p.imageTag,
                        maxHeight: 200,
                      ),
                      httpHeaders: _api.imageHeaders,
                      fit: BoxFit.cover,
                      placeholder: (_, _) =>
                          const ColoredBox(color: Color(0xFF1A1A20)),
                      errorWidget: (_, _, _) => _personPlaceholder(),
                    )
                  : _personPlaceholder(),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            p.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _libText,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (p.role.trim().isNotEmpty) ...[
            const SizedBox(height: 1),
            Text(
              p.role.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _libSub,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _personPlaceholder() {
    return const ColoredBox(
      color: Color(0xFF1A1A20),
      child: Icon(
        Icons.person_outline_rounded,
        color: Colors.white38,
        size: 28,
      ),
    );
  }

  // ── 影片信息（服务端刮削） ─────────────────────────────────

  bool get _hasFacts =>
      _item.studios.isNotEmpty ||
      _item.premiereDateText.isNotEmpty ||
      _item.officialRating.isNotEmpty ||
      (_item.criticRating ?? 0) > 0 ||
      (_item.originalTitle.isNotEmpty && _item.originalTitle != _item.name);

  Widget _buildFacts() {
    final rows = <(String, String)>[
      if (_item.studios.isNotEmpty) ('出品公司', _item.studios.join(' / ')),
      if (_item.premiereDateText.isNotEmpty) ('首播日期', _item.premiereDateText),
      if (_item.officialRating.isNotEmpty) ('官方分级', _item.officialRating),
      if ((_item.criticRating ?? 0) > 0)
        ('媒体评分', '${_item.criticRating!.round()} 分'),
      if (_item.originalTitle.isNotEmpty && _item.originalTitle != _item.name)
        ('原始标题', _item.originalTitle),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('影片信息'),
        const SizedBox(height: 4),
        for (final r in rows) _creditLine(r.$1, r.$2),
      ],
    );
  }

  // ── 顶栏 ──────────────────────────────────────────────────

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.maybePop(context),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.38),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.arrow_back,
                    size: 20,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 头图上的元信息小胶囊（年份 / 评分 / 时长 / 类型）。
class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.text, this.highlighted = false});

  final String text;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final bg = highlighted
        ? const Color(0xFFFFC107).withValues(alpha: 0.22)
        : Colors.white.withValues(alpha: 0.16);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: highlighted ? const Color(0xFFFFD54F) : Colors.white,
          fontSize: AppTheme.fontCaption,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
