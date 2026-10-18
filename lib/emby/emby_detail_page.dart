import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import 'emby_api.dart';
import 'emby_models.dart';
import 'emby_player_page.dart';

/// Emby 条目详情：电影显示简介 + 播放；剧集显示分集列表。
///
/// 视觉与「媒体库详情页」统一：全屏 Backdrop 头图 + 底部压暗 + 浮层大标题，
/// 下方接一块圆角内容底板（简介 / 选集），返回键悬浮在头图上。
class EmbyDetailPage extends StatefulWidget {
  const EmbyDetailPage({super.key, required this.item, required this.server});

  final EmbyItem item;
  final EmbyServer server;

  @override
  State<EmbyDetailPage> createState() => _EmbyDetailPageState();
}

class _EmbyDetailPageState extends State<EmbyDetailPage> {
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
                const SizedBox(height: 20),
                Container(
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundPrimary,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 44),
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
                      if (_item.overview.isNotEmpty) _buildOverview(),
                      if (_item.isSeries) ...[
                        if (_item.overview.isNotEmpty)
                          const SizedBox(height: 22),
                        _buildEpisodes(),
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
                Color(0xCC000000),
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
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (_item.year != null)
                      _MetaPill(text: '${_item.year}'),
                    if (_item.rating != null && _item.rating! > 0)
                      _MetaPill(
                        text: '★ ${_item.rating!.toStringAsFixed(1)}',
                        highlighted: true,
                      ),
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
                          horizontal: 20, vertical: 9),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.play_arrow_rounded,
                              size: 20, color: Colors.black),
                          SizedBox(width: 4),
                          Text(
                            '播放',
                            style: TextStyle(
                              color: Colors.black,
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

  Widget _buildOverview() {
    final long = _item.overview.length > 90;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 3,
              height: 14,
              decoration: BoxDecoration(
                color: AppTheme.accentColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '简介',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          _item.overview,
          maxLines: _overviewExpanded ? null : 4,
          overflow:
              _overviewExpanded ? TextOverflow.clip : TextOverflow.ellipsis,
          style: TextStyle(
            color: AppTheme.textSecondary,
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
        Row(
          children: [
            Container(
              width: 3,
              height: 14,
              decoration: BoxDecoration(
                color: AppTheme.accentColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '选集',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${_episodes.length} 集',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
          ],
        ),
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
              style: TextStyle(
                color: AppTheme.textTertiary,
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
      color: AppTheme.backgroundSecondary,
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
                        imageUrl: _api.imageUrl(ep.id,
                            tag: ep.imageTag, maxHeight: 240),
                        httpHeaders: _api.imageHeaders,
                        fit: BoxFit.cover,
                        placeholder: (_, _) => ColoredBox(
                            color:
                                AppTheme.backgroundPrimary.withValues(alpha: 0.5)),
                        errorWidget: (_, _, _) => ColoredBox(
                          color: AppTheme.backgroundPrimary.withValues(alpha: 0.5),
                          child: Icon(
                            Icons.play_circle_outline_rounded,
                            color: AppTheme.textTertiary,
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
                                horizontal: 5, vertical: 1),
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
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    if (ep.durationText.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        ep.durationText,
                        style: TextStyle(
                          color: AppTheme.textTertiary,
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
                color: AppTheme.accentColor.withValues(alpha: 0.9),
              ),
            ],
          ),
        ),
      ),
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
