import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/pages/playlist_detail_page.dart';
import 'package:tvbox/music/services/music_api.dart';
import 'package:tvbox/music/services/settings_store.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/music_components.dart';

/// 「榜单」页 —— **左窄栏榜单列表 + 右内容区**。
///
/// ── 为什么改成左右分栏（2026-10-30）────────────────────────────
/// 用户：「排行榜能不能做小点，一边是排行榜一边其余的列表或者网格式」。
///
/// 原来是 2 列**大卡片网格**（封面边长 = 半屏宽），一屏只装得下 4 个榜单，
/// 而且点进去才知道里面有什么歌 —— 榜单页的价值本来是"一眼扫到排名"，
/// 大卡片把排名藏起来了。
///
/// 现在的结构对齐主流音乐 App 的榜单页：
///   · 左栏 104px：全部榜单（小封面 + 榜名），竖向可滚，选中高亮
///   · 右栏：**选中榜单的歌曲**，默认列表，可一键切 2 列网格
/// 切榜单不再跳页，右边原地换内容。
class ChartsPage extends StatefulWidget {
  const ChartsPage({super.key});

  @override
  State<ChartsPage> createState() => _ChartsPageState();
}

class _ChartsPageState extends State<ChartsPage>
    with AutomaticKeepAliveClientMixin {
  final api = MusicApi.instance;

  SongSource _source = SongSource.netease;
  List<TopList> _tops = const [];
  bool _loading = true;
  String _error = '';

  /// 当前选中的榜单（左栏高亮 + 右栏内容）
  int _selected = 0;

  List<Song> _songs = const [];
  bool _songsLoading = false;
  String _songsError = '';

  /// 右栏布局：列表 / 网格
  bool _grid = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _source = SettingsStore.instance.musicSource.value;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    final src = SettingsStore.instance.musicSource.value;
    final r = await api.topListsResult(source: src);
    if (!mounted) return;
    setState(() {
      _source = src;
      _tops = r.list;
      _loading = false;
      _selected = 0;
      // ⚠️ 区分"接口失败"和"该平台确实没榜单"：
      // QQ 免登录**有** 30 个榜单（实测），所以失败就是真失败；
      // 而喜马拉雅那种"本来就没有榜单"的平台要给不同文案。
      if (!r.ok && r.list.isEmpty) {
        _error = src == SongSource.ximalaya
            ? '喜马拉雅没有榜单（它是有声书平台）'
            : (r.error.isNotEmpty ? r.error : '榜单加载失败');
      }
    });
    if (_tops.isNotEmpty) await _loadSongs();
  }

  Future<void> _loadSongs() async {
    if (_tops.isEmpty) return;
    final top = _tops[_selected.clamp(0, _tops.length - 1)];
    setState(() {
      _songsLoading = true;
      _songsError = '';
      _songs = const [];
    });
    final r = await api.topListSongs(top.id, limit: 60, source: _source);
    if (!mounted) return;
    // 切榜单时可能已经换了选中项，回来的旧结果直接丢掉
    if (_tops.isEmpty || _tops[_selected.clamp(0, _tops.length - 1)].id != top.id) {
      return;
    }
    setState(() {
      _songs = r.list;
      _songsLoading = false;
      if (!r.ok && r.list.isEmpty) {
        _songsError = r.error.isEmpty ? '这个榜单暂时拿不到歌曲' : r.error;
      }
    });
  }

  void _select(int i) {
    if (i == _selected) return;
    setState(() => _selected = i);
    _loadSongs();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          MusicPageHeader(
            title: '榜单',
            subtitle: '当前平台 · ${_source.displayName}',
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (_error.isNotEmpty) return _errorBox();
    if (_tops.isEmpty) {
      return Center(
        child: Text(
          '这个平台没有榜单',
          style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontBody),
        ),
      );
    }
    return RefreshIndicator(
      color: MusicTheme.tint,
      onRefresh: _load,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _chartRail(),
          Container(width: 0.5, color: MusicTheme.divider),
          Expanded(child: _songsPane()),
        ],
      ),
    );
  }

  /// 左窄栏：全部榜单，竖向滚动
  Widget _chartRail() {
    return SizedBox(
      width: 104,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(10, 4, 6, 160),
        itemCount: _tops.length,
        itemBuilder: (c, i) => _railTile(_tops[i], i),
      ),
    );
  }

  Widget _railTile(TopList t, int i) {
    final active = i == _selected;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _select(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 7),
        decoration: BoxDecoration(
          color: active
              ? MusicTheme.tint.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? MusicTheme.tint : Colors.transparent,
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            CoverImage(url: t.coverUrl, size: 74, cornerRadius: 9),
            const SizedBox(height: 5),
            Text(
              t.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active ? MusicTheme.tint : MusicTheme.label,
                fontSize: AppTheme.fontCaption,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 右内容区：选中榜单的歌曲（列表 / 网格）
  Widget _songsPane() {
    final top = _tops[_selected.clamp(0, _tops.length - 1)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      top.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: MusicTheme.label,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if ((top.updateFrequency ?? '').trim().isNotEmpty)
                      Text(
                        top.updateFrequency!.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                  ],
                ),
              ),
              _iconButton(
                icon: _grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
                tooltip: _grid ? '列表' : '网格',
                onTap: () => setState(() => _grid = !_grid),
              ),
              _iconButton(
                icon: Icons.play_circle_fill_rounded,
                tooltip: '播放全部',
                color: MusicTheme.tint,
                onTap: _songs.isEmpty
                    ? null
                    : () => openPlaylist(
                          context,
                          top.id,
                          top.name,
                          source: _source,
                          isTopList: true,
                          coverUrl: top.coverUrl,
                        ),
              ),
            ],
          ),
        ),
        Expanded(child: _songList(top)),
      ],
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    Color? color,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 20, color: color ?? MusicTheme.secondary),
    );
  }

  Widget _songList(TopList top) {
    if (_songsLoading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_songs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _songsError.isEmpty ? '这个榜单暂时没有歌曲' : _songsError,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: MusicTheme.secondary,
              fontSize: AppTheme.fontFootnote,
            ),
          ),
        ),
      );
    }
    if (!_grid) {
      return ListView.builder(
        padding: const EdgeInsets.only(bottom: 160),
        itemCount: _songs.length,
        itemBuilder: (c, i) => SongCell(
          song: _songs[i],
          index: i,
          playbackContext: _songs,
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        const gap = 10.0;
        const pad = 12.0;
        final cellW = (box.maxWidth - pad * 2 - gap) / 2;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(pad, 2, pad, 160),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: gap,
            // 高度按宽度算：封面(cellW) + 歌名 2 行 + 歌手 1 行
            mainAxisExtent: cellW +
                6 +
                MediaQuery.textScalerOf(context).scale(AppTheme.fontSubhead) *
                    1.3 *
                    2 +
                MediaQuery.textScalerOf(context).scale(AppTheme.fontCaption) *
                    1.3,
          ),
          itemCount: _songs.length,
          itemBuilder: (c, i) {
            final s = _songs[i];
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => openPlaylist(
                context,
                top.id,
                top.name,
                source: _source,
                isTopList: true,
                coverUrl: top.coverUrl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CoverImage(url: s.coverUrl, size: cellW, cornerRadius: 12),
                  const SizedBox(height: 6),
                  Text(
                    s.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: MusicTheme.label,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  Text(
                    s.artists,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontCaption,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _errorBox() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 0),
      child: Column(
        children: [
          Icon(Icons.cloud_off_rounded, size: 40, color: MusicTheme.secondary),
          const SizedBox(height: 12),
          Text(
            _error,
            textAlign: TextAlign.center,
            style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontBody),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: MusicTheme.tint,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
