import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../widgets/music_components.dart';
import '../../widgets/app_page_loading.dart';
import '../../common/theme.dart';

/// 歌单/榜单详情 —— 对齐 Beans 的 `PlaylistView` + 详情页。
///
/// 顶部大头图 + 歌单信息 + 「播放全部 / 随机播放」，
/// 下面是歌曲列表。点歌从该列表位置开始播（这样"下一首"才正确）。
Future<void> openPlaylist(
  BuildContext context,
  int id,
  String title, {
  SongSource source = SongSource.netease,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => PlaylistDetailPage(id: id, title: title, source: source)),
  );
}

class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({super.key, required this.id, required this.title, this.source = SongSource.netease});

  final int id;
  final String title;
  final SongSource source;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  final api = MusicApi.instance;
  Playlist? _pl;
  List<Song> _songs = const [];
  bool _loading = true;
  String _error = '';

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
    final (pl, songs) = await api.playlistDetail(widget.id, source: widget.source);
    if (!mounted) return;
    setState(() {
      _pl = pl;
      _songs = songs;
      _loading = false;
      if (pl == null && songs.isEmpty) _error = '歌单加载失败';
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = _pl?.name ?? widget.title;
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: _loading
            ? AppPageLoading(color: MusicTheme.tint)
            : CustomScrollView(
                slivers: [
                  _header(name),
                  if (_error.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text(_error,
                              style: TextStyle(
                                  color: MusicTheme.secondary, fontSize: AppTheme.fontSubhead)),
                        ),
                      ),
                    ),
                  SliverList.builder(
                    itemCount: _songs.length,
                    itemBuilder: (c, i) => SongCell(
                      song: _songs[i],
                      index: i,
                      playbackContext: _songs,
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 120)),
                ],
              ),
      ),
    );
  }

  Widget _header(String name) {
    return SliverAppBar(
      pinned: true,
      // 🔴 原来 `expandedHeight: 300` → 头部**可用高度只有 300-84-12 = 204px**，
      // 而内容最少 ≈221px（128 封面 + 12 + 标题 + 4 + 副标题 + 12 + 33 按钮行）✗
      // → FlexibleSpaceBar 里**必然 RenderFlex overflow**（按钮被裁掉）✗；
      // 标题两行时约 257px，溢出更多 ✗。抬到 360 给足余量 ✓
      expandedHeight: 360,
      backgroundColor: Colors.transparent,
      iconTheme: IconThemeData(color: MusicTheme.label),
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            // 背景：封面模糊放大（Beans 的 CoverBlurBackground）
            if ((_pl?.coverUrl ?? '').isNotEmpty)
              CachedNetworkImage(
                imageUrl: _pl!.coverUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.55),
                    MusicTheme.background,
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 84, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CoverImage(
                      url: _pl?.coverUrl, size: 128, cornerRadius: 14),
                  const SizedBox(height: 12),
                  Text(name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontTitle2,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (_songs.isNotEmpty) '${_songs.length} 首',
                      if ((_pl?.creator ?? '').isNotEmpty) _pl!.creator!,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _playBtn('播放全部', Icons.play_arrow_rounded, () {
                        if (_songs.isNotEmpty) {
                          MusicPlayerManager.instance
                              .playQueue(_songs, index: 0);
                        }
                      }),
                      const SizedBox(width: 10),
                      _playBtn('随机播放', Icons.shuffle_rounded, () {
                        if (_songs.isNotEmpty) {
                          final p = MusicPlayerManager.instance;
                          p.setMode(PlayMode.shuffle);
                          p.playQueue(List<Song>.of(_songs)..shuffle(),
                              index: 0);
                        }
                      }, outlined: true),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playBtn(String label, IconData icon, VoidCallback onTap,
      {bool outlined = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          gradient: outlined
              ? null
              : LinearGradient(colors: MusicTheme.accentGradient),
          color: outlined ? MusicTheme.fill : null,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 17,
                color: outlined ? MusicTheme.label : Colors.white),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w600,
                    color: outlined ? MusicTheme.label : Colors.white)),
          ],
        ),
      ),
    );
  }
}
