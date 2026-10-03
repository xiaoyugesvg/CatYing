import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../../common/theme.dart';

/// 喜马拉雅专辑页（有声书/播客）——「专辑 = 影片，单集 = 剧集」。
///
/// ── 为什么必须有这个页面（而不是直接在搜索结果里播）─────────────
/// 喜马拉雅的播放直链是**跟着专辑的单集列表一起返回**的，Node 侧拿到后才
/// 填进直链缓存。所以**必须先打开专辑**（调 `ximalayaAlbum`），再去播某一集；
/// 直接播搜索到的"专辑 id"是拿不到地址的 —— 这是该数据源的既定取舍，
/// 页面里也如实提示，不假装能播。
class XimalayaAlbumPage extends StatefulWidget {
  const XimalayaAlbumPage({super.key, required this.albumId, this.albumName});

  final String albumId;
  final String? albumName;

  @override
  State<XimalayaAlbumPage> createState() => _XimalayaAlbumPageState();
}

class _XimalayaAlbumPageState extends State<XimalayaAlbumPage> {
  final _player = MusicPlayerManager.instance;

  bool _loading = true;
  String _error = '';
  String _message = ''; // 整张专辑不可播时的原因
  int _skipped = 0;
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
    final r = await MusicApi.instance.ximalayaAlbum(widget.albumId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _songs = r.songs;
      _skipped = r.skipped;
      _message = r.message;
      _albumName = r.albumName.isNotEmpty
          ? r.albumName
          : (widget.albumName ?? '专辑');
      if (!r.ok) _error = r.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
      // 如实说明为什么是空的 —— 不要只显示"暂无内容"
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            _message.isEmpty
                ? '这张专辑没有可播放的单集'
                : '$_message\n（共过滤掉 $_skipped 集无可用音频的条目）',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontBody,
                height: 1.5),
          ),
        ),
      );
    }
    return Column(
      children: [
        // 有被过滤掉的集时，顶部说明一句（用户会奇怪"怎么少了这么多集"）
        if (_skipped > 0)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            color: MusicTheme.fill,
            child: Text(
              '已列出 ${_songs.length} 集可播放；另有 $_skipped 集没有可用音频'
              '（通常是会员/版权限制），未列出',
              style: TextStyle(
                  color: MusicTheme.secondary,
                  fontSize: AppTheme.fontFootnote,
                  height: 1.4),
            ),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: _songs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final s = _songs[i];
              final playing =
                  _player.currentSong?.identityKey == s.identityKey;
              return ListTile(
                leading: SizedBox(
                  width: 28,
                  child: Text('${i + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: playing
                              ? MusicTheme.tint
                              : MusicTheme.secondary,
                          fontSize: AppTheme.fontFootnote)),
                ),
                title: Text(
                  s.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: playing ? MusicTheme.tint : MusicTheme.label,
                    fontWeight: playing ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                onTap: () => _player.playQueue(_songs, index: i),
              );
            },
          ),
        ),
      ],
    );
  }
}
