// lib/music/pages/plugin_song_list_page.dart
//
// 插件榜单 / 歌单的歌曲列表页（2026-10-21；从 plugin_explore_page 拆出来）。

import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/models/third_party_source.dart';
import 'package:tvbox/music/services/music_api.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/music_components.dart';

class PluginSongListPage extends StatefulWidget {
  const PluginSongListPage({
    super.key,
    required this.source,
    required this.title,
    required this.item,
    required this.isTopList,
    this.coverUrl = '',
  });

  final ThirdPartySource source;
  final String title;
  final String coverUrl;

  /// 从上一页带下来的原始条目（榜单 or 歌单），**原样**交给插件
  final Map<String, dynamic> item;

  /// true = 榜单（`getTopListDetail`）；false = 歌单（`getMusicSheetInfo`）
  final bool isTopList;

  @override
  State<PluginSongListPage> createState() => _PluginSongListPageState();
}

class _PluginSongListPageState extends State<PluginSongListPage> {
  final api = MusicApi.instance;
  bool _loading = true;
  String _error = '';
  List<Song> _songs = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    final r = await api.musicFreeAction(
      widget.source,
      widget.isTopList ? 'musicFreeTopListDetail' : 'musicFreeSheetInfo',
      params: widget.isTopList
          ? {'topListItem': widget.item}
          : {'sheetItem': widget.item, 'page': 1},
    );
    if (!mounted) return;
    final songs = <Song>[];
    for (final e in (r['list'] as List? ?? const [])) {
      if (e is! Map) continue;
      try {
        // 插件歌没有平台归属 → 打上 pluginId，播放时优先问这个插件
        songs.add(
          Song.fromJson(Map<String, dynamic>.from(e))
              .withPluginId(widget.source.id),
        );
      } catch (_) {
        // 单条坏数据不影响整页
      }
    }
    setState(() {
      _loading = false;
      _songs = songs;
      if (r['ok'] != true) {
        _error = (r['error'] ?? '读取失败').toString();
      } else if (songs.isEmpty) {
        _error = '这个列表里没有歌曲';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: IconThemeData(color: MusicTheme.label),
          title: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontHeadline,
            ),
          ),
          actions: [
            IconButton(
              tooltip: '播放全部',
              icon: Icon(Icons.play_circle_outline_rounded,
                  color: MusicTheme.tint),
              onPressed: _songs.isEmpty
                  ? null
                  : () => MusicPlayerManager.instance
                      .playQueue(_songs, index: 0),
            ),
          ],
        ),
        body: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: MusicTheme.tint));
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 140),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Row(
            children: [
              CoverImage(
                url: widget.coverUrl.isEmpty ? null : widget.coverUrl,
                size: 64,
                cornerRadius: 14,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: MusicTheme.label,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_songs.length} 首 · 来自 ${widget.source.name}',
                      style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: AppTheme.fontFootnote,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_error.isNotEmpty && _songs.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontSubhead,
              ),
            ),
          ),
        for (var i = 0; i < _songs.length; i++)
          SongCell(
            song: _songs[i],
            index: i,
            playbackContext: _songs,
          ),
      ],
    );
  }
}
