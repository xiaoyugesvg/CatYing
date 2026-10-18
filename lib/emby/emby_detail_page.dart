import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import 'emby_api.dart';
import 'emby_models.dart';
import 'emby_player_page.dart';

/// Emby 条目详情：电影显示简介 + 播放；剧集显示分集列表。
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
    final canPlayDirectly = !_item.isSeries;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        foregroundColor: AppTheme.textPrimary,
        title: Text(
          _item.isSeries ? _item.name : _item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _loading && _item.overview.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.28),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ],
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                          width: 0.8,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(13),
                        child: SizedBox(
                          width: 116,
                          height: 174,
                          child: CachedNetworkImage(
                            imageUrl:
                                _api.imageUrl(_item.id, tag: _item.imageTag),
                            httpHeaders: _api.imageHeaders,
                            fit: BoxFit.cover,
                            placeholder: (_, _) => ColoredBox(
                                color: AppTheme.backgroundSecondary),
                            errorWidget: (_, _, _) => ColoredBox(
                              color: AppTheme.backgroundSecondary,
                              child: Icon(
                                Icons.movie_outlined,
                                color: AppTheme.textTertiary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _item.name,
                            style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: AppTheme.fontHeadline,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          // 元信息统一做成一排小胶囊（年份 / 评分 / 时长 / 类型）
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (_item.year != null)
                                _MetaChip(text: '${_item.year}'),
                              if (_item.rating != null && _item.rating! > 0)
                                _MetaChip(
                                  text: '★ ${_item.rating!.toStringAsFixed(1)}',
                                  highlighted: true,
                                ),
                              if (_item.durationText.isNotEmpty)
                                _MetaChip(text: _item.durationText),
                              if (_item.type.isNotEmpty)
                                _MetaChip(
                                  text: _item.type == 'Movie'
                                      ? '电影'
                                      : _item.type == 'Series'
                                          ? '剧集'
                                          : _item.type,
                                ),
                            ],
                          ),
                          if (canPlayDirectly) ...[
                            const SizedBox(height: 14),
                            FilledButton.icon(
                              onPressed: () => _play(_item),
                              icon: const Icon(Icons.play_arrow_rounded,
                                  size: 20),
                              label: const Text('播放'),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppTheme.accentColor,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 22, vertical: 10),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                textStyle: const TextStyle(
                                  fontSize: AppTheme.fontSubhead,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: AppTheme.fontFootnote,
                    ),
                  ),
                ],
                if (_item.overview.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(
                    '简介',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _item.overview,
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: AppTheme.fontFootnote,
                      height: 1.6,
                    ),
                  ),
                ],
                if (_item.isSeries) ...[
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Text(
                        '分集',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontSubhead,
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
                  const SizedBox(height: 6),
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
                    for (final ep in _episodes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Material(
                          color: AppTheme.backgroundSecondary,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _play(ep),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: Row(
                                children: [
                                  // 集号胶囊
                                  Container(
                                    width: 46,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 4),
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: AppTheme.accentColor
                                          .withValues(alpha: 0.14),
                                      borderRadius:
                                          BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      ep.episodeLabel.isEmpty
                                          ? '${ep.indexNumber ?? ''}'
                                          : ep.episodeLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: AppTheme.accentColor,
                                        fontSize: AppTheme.fontCaption,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          ep.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: AppTheme.textPrimary,
                                            fontSize: AppTheme.fontSubhead,
                                          ),
                                        ),
                                        if (ep.durationText.isNotEmpty) ...[
                                          const SizedBox(height: 2),
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
                                  Icon(
                                    Icons.play_circle_fill_rounded,
                                    size: 22,
                                    color: AppTheme.accentColor
                                        .withValues(alpha: 0.85),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                ],
              ],
            ),
    );
  }
}

/// 详情页元信息小胶囊（年份 / 评分 / 时长 / 类型）
class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.text, this.highlighted = false});

  final String text;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final base = highlighted ? AppTheme.accentColor : AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: highlighted ? AppTheme.accentColor : AppTheme.textSecondary,
          fontSize: AppTheme.fontCaption,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
