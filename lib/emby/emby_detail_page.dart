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

  late final EmbyApi _api = EmbyApi(widget.server);
  late EmbyItem _item = widget.item;
  List<EmbyItem> _episodes = const [];
  bool _loading = true;
  String? _error;
  bool _overviewExpanded = false;

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
                SizedBox(height: MediaQuery.paddingOf(context).top + 58),
                _buildHero(),
                const SizedBox(height: 16),
                // 壁纸 → 内容底的过渡（固定高度渐变，避免随内容长度拉伸）
                Container(
                  height: 32,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x000D0D12), Color(0xFF0D0D12)],
                    ),
                  ),
                ),
                Container(
                  // 媒体库同款：内容直接浮在深色壁纸上（不再垫浅色圆角底板）
                  color: const Color(0xFF0D0D12),
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
    return Stack(
      fit: StackFit.expand,
      children: [
        // 没有 Backdrop 时用海报铺满并模糊，避免一张竖图被硬拉成横屏
        ImageFiltered(
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
        // 顶部压暗（状态栏/返回键可读）+ 底部压暗（白色标题可读）
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x8C000000),
                Color(0x33000000),
                Color(0x66000000),
                Color(0xF0000000),
              ],
              stops: [0, 0.35, 0.7, 1],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHero() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 竖版海报
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 22,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 112,
                height: 168,
                child: CachedNetworkImage(
                  imageUrl: _api.imageUrl(_item.id, tag: _item.imageTag),
                  httpHeaders: _api.imageHeaders,
                  fit: BoxFit.cover,
                  placeholder: (_, _) =>
                      const ColoredBox(color: Color(0xFF1E1E22)),
                  errorWidget: (_, _, _) => const ColoredBox(
                    color: Color(0xFF1E1E22),
                    child: Icon(Icons.movie_outlined, color: Colors.white38),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _item.name,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
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
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
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
                if (!_item.isSeries && !_item.isEpisode) ...[
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () => _play(_item),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: _libAccent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.play_arrow_rounded,
                            size: 20,
                            color: Colors.white,
                          ),
                          SizedBox(width: 4),
                          Text(
                            '播放',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
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
          for (final ep in _episodes) ...[
            _episodeTile(ep),
            const SizedBox(height: 8),
          ],
      ],
    );
  }

  Widget _episodeTile(EmbyItem ep) {
    final radius = BorderRadius.circular(14);
    return Material(
      color: _libCard,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: () => _play(ep),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              // 单集缩略图（16:9）+ 集号角标
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 104,
                  height: 60,
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
                            size: 22,
                          ),
                        ),
                      ),
                      if (ep.episodeLabel.isNotEmpty)
                        Positioned(
                          left: 4,
                          bottom: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              ep.episodeLabel,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      ep.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _libText,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    if (ep.durationText.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        ep.durationText,
                        style: const TextStyle(
                          color: _libSub,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.play_circle_fill_rounded,
                size: 24,
                color: _libAccent.withValues(alpha: 0.95),
              ),
            ],
          ),
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
