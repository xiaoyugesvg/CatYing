import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../../common/theme.dart';
import '../widgets/listen_episode_list.dart';

/// 博看听书专辑页（有声书）——「专辑 = 影片，单集 = 剧集」。
///
/// 与喜马拉雅专辑页同形态，但数据来自**纯 Dart 直连**（`bookanAlbum`）：
/// 单集 `file` 直链已填进 `Song.directUrl`，点任意一集直接播。
class BookanAlbumPage extends StatefulWidget {
  const BookanAlbumPage({super.key, required this.albumId, this.albumName});

  final String albumId;
  final String? albumName;

  @override
  State<BookanAlbumPage> createState() => _BookanAlbumPageState();
}

class _BookanAlbumPageState extends State<BookanAlbumPage> {
  final _player = MusicPlayerManager.instance;

  bool _loading = true;
  String _error = '';
  String _albumName = '';
  String? _coverUrl;
  String _author = '';
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
    final r = await MusicApi.instance.bookanAlbum(widget.albumId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _songs = r.songs;
      _albumName = r.albumName.isNotEmpty
          ? r.albumName
          : (widget.albumName ?? '专辑');
      _coverUrl = r.coverUrl;
      _author = r.author ?? '';
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
            '这张专辑没有可播放的单集',
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
        sourceLabel: '博看',
        albumCoverUrl: _coverUrl,
        albumName: _albumName,
        albumIntro: _author.isNotEmpty ? '作者：$_author' : null,
        albumProgress: '共 ${_songs.length} 集',
        currentIdentityKey: _player.currentSong?.identityKey,
        onPlay: (index) => _player.playQueue(_songs, index: index),
      ),
    );
  }
}
