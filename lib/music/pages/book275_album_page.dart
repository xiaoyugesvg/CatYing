import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../../common/theme.dart';

/// 275听书专辑页（有声小说）——「专辑 = 影片，单集 = 剧集」。
///
/// 单集 `directUrl` 填的是**播放页 URL**（`/play/{book}/{cid}.html`），
/// 点击播放时由 `player_manager` 调 `book275Resolve()` 解析出真实音频
/// 直链（含 PHPSESSID 会话 + lrts 懒人听书 token）。
class Book275AlbumPage extends StatefulWidget {
  const Book275AlbumPage({super.key, required this.bookId, this.albumName});

  final String bookId;
  final String? albumName;

  @override
  State<Book275AlbumPage> createState() => _Book275AlbumPageState();
}

class _Book275AlbumPageState extends State<Book275AlbumPage> {
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
    final r = await MusicApi.instance.book275Album(widget.bookId);
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
      builder: (context, _) => ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: _songs.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final s = _songs[i];
          final playing = _player.currentSong?.identityKey == s.identityKey;
          return ListTile(
            leading: SizedBox(
              width: 28,
              child: Text('${i + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: playing ? MusicTheme.tint : MusicTheme.secondary,
                      fontSize: AppTheme.fontFootnote)),
            ),
            title: Row(
              children: [
                Icon(
                  Icons.audiotrack_rounded,
                  size: 15,
                  color: playing ? MusicTheme.tint : MusicTheme.secondary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    s.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: playing ? MusicTheme.tint : MusicTheme.label,
                      fontWeight: playing ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
            onTap: () => _player.playQueue(_songs, index: i),
          );
        },
      ),
    );
  }
}
