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
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                      child: SizedBox(
                        width: 112,
                        height: 168,
                        child: CachedNetworkImage(
                          imageUrl:
                              _api.imageUrl(_item.id, tag: _item.imageTag),
                          httpHeaders: _api.imageHeaders,
                          fit: BoxFit.cover,
                          placeholder: (_, _) =>
                              ColoredBox(color: AppTheme.backgroundSecondary),
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
                          Text(
                            [
                              if (_item.year != null) '${_item.year}',
                              if (_item.rating != null && _item.rating! > 0)
                                '★ ${_item.rating!.toStringAsFixed(1)}',
                              if (_item.durationText.isNotEmpty)
                                _item.durationText,
                            ].join('  ·  '),
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: AppTheme.fontFootnote,
                            ),
                          ),
                          if (_item.type.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              _item.type == 'Movie'
                                  ? '电影'
                                  : _item.type == 'Series'
                                      ? '剧集'
                                      : _item.type,
                              style: TextStyle(
                                color: AppTheme.textTertiary,
                                fontSize: AppTheme.fontCaption,
                              ),
                            ),
                          ],
                          if (canPlayDirectly) ...[
                            const SizedBox(height: 14),
                            FilledButton.icon(
                              onPressed: () => _play(_item),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: const Text('播放'),
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
                      Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        color: AppTheme.backgroundSecondary,
                        elevation: 0,
                        child: ListTile(
                          leading: SizedBox(
                            width: 48,
                            child: Text(
                              ep.episodeLabel.isEmpty
                                  ? '${ep.indexNumber ?? ''}'
                                  : ep.episodeLabel,
                              style: TextStyle(
                                color: AppTheme.textTertiary,
                                fontSize: AppTheme.fontCaption,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          title: Text(
                            ep.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: AppTheme.fontSubhead,
                            ),
                          ),
                          subtitle: ep.durationText.isEmpty
                              ? null
                              : Text(
                                  ep.durationText,
                                  style: TextStyle(
                                    color: AppTheme.textTertiary,
                                    fontSize: AppTheme.fontCaption,
                                  ),
                                ),
                          trailing: const Icon(Icons.play_circle_outline),
                          onTap: () => _play(ep),
                        ),
                      ),
                ],
              ],
            ),
    );
  }
}
