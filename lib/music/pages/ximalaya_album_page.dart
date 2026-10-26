import 'package:flutter/material.dart';

import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/services/music_api.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/widgets/listen_episode_list.dart';

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
  String? _coverUrl;
  String _intro = '';
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
      _coverUrl = r.coverUrl;
      _intro = r.intro;
      if (!r.ok) _error = r.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 🔴 这是 push 到 root Navigator 的页面 → **不在** `MusicRootView` 的
      // `Theme(MusicTheme.themeData())` 作用域内 ✗ → 不显式指定就会回落到
      // **影视侧** AppTheme 的 `scaffoldBackgroundColor`（选了不同调色板时一眼看出 ✗）。
      // 与「我的歌单」同一做法：只拉正底色，不动 Scaffold 右括号（最小改动 ✓）。
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
          // ── 🔴 必须监听 player（修"点歌后行号不变色"）────────────────
          //
          // `ListenableBuilder` 与 `AnimatedBuilder` 等价，保证切歌后
          // 当前集高亮即时刷新；单集列表自带搜索/视图/定位/排序。
          child: ListenableBuilder(
            listenable: _player,
            builder: (context, _) => ListenEpisodeList(
              songs: _songs,
              sourceLabel: '喜雅',
              albumCoverUrl: _coverUrl,
              albumName: _albumName,
              albumIntro: _intro.isEmpty ? null : _intro,
              albumProgress: '共 ${_songs.length} 集可播放',
              currentIdentityKey: _player.currentSong?.identityKey,
              onPlay: (index) => _player.playQueue(_songs, index: index),
            ),
          ),
        ),
      ],
    );
  }
}
