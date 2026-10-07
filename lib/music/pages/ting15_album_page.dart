import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../../common/theme.dart';
import '../widgets/listen_episode_list.dart';

/// 一五听书专辑页（有声小说）——「专辑 = 影片，单集 = 剧集」。
///
/// 单集 `directUrl` 填的是**章节页 URL**（`/{bookId}/0-{page}.html`），
/// 点击播放时由 `player_manager` 调 `ting15Resolve()` 调站点播放 API
/// 解析出真实音频直链。
class Ting15AlbumPage extends StatefulWidget {
  const Ting15AlbumPage({super.key, required this.detailUrl, this.albumName});

  /// 书籍详情页 URL（打开专辑的数据来源）
  final String detailUrl;
  final String? albumName;

  @override
  State<Ting15AlbumPage> createState() => _Ting15AlbumPageState();
}

class _Ting15AlbumPageState extends State<Ting15AlbumPage> {
  final _player = MusicPlayerManager.instance;

  bool _loading = true;
  String _error = '';
  String _albumName = '';
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
    final r = await MusicApi.instance.ting15Album(widget.detailUrl);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _songs = r.songs;
      _albumName = r.albumName.isNotEmpty
          ? r.albumName
          : (widget.albumName ?? '专辑');
      if (!r.ok) _error = r.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MusicTheme.background,
      appBar: AppBar(
        title: Text(_albumName.isEmpty ? '专辑' : _albumName,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (_songs.isNotEmpty)
            IconButton(
              tooltip: '播放全部',
              icon: const Icon(Icons.play_arrow_rounded),
              onPressed: () => _player.playQueue(_songs, index: 0),
            ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
              strokeWidth: 2.4, color: MusicTheme.tint),
        ),
      );
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: MusicTheme.secondary, size: 30),
              const SizedBox(height: 10),
              Text(_error,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontBody)),
              const SizedBox(height: 14),
              TextButton(
                onPressed: _load,
                child: Text('重试', style: TextStyle(color: MusicTheme.tint)),
              ),
            ],
          ),
        ),
      );
    }
    if (_songs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            '这本书没有可播放的章节',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontBody,
                height: 1.5),
          ),
        ),
      );
    }
    return ListenableBuilder(
      listenable: _player,
      builder: (context, _) => ListenEpisodeList(
        songs: _songs,
        sourceLabel: '一五',
        currentIdentityKey: _player.currentSong?.identityKey,
        onPlay: (index) => _player.playQueue(_songs, index: index),
      ),
    );
  }
}
