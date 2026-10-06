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
          // 下面 `playing` 读的是 `_player.currentSong`，而本页原来
          // **没有任何 player 监听**、`onTap` 也不 `setState` →
          // 点了第 5 集开始播放，第 5 行的序号/标题**不会**变成主题色 ✗
          //（要等页面因别的原因重建才更新）
          //
          // `Listenable.merge([_svc, _player])` 是项目里的标准解法
          //（`local_music_page.dart` 的注释专门写了这一条），
          // `ListenableBuilder` 与 `AnimatedBuilder` 等价。
          child: ListenableBuilder(
            listenable: _player,
            builder: (context, _) => ListView.separated(
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
                          fontWeight:
                              playing ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
                // 单集：只播放（方案 C）—— 反馈由**悬浮播放球**提供，不打断浏览
                onTap: () => _player.playQueue(_songs, index: i),
              );
            },
            ),
          ),
        ),
      ],
    );
  }
}
