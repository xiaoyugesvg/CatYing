import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../widgets/music_components.dart';
import 'playlist_detail_page.dart';

/// 音乐库 —— 移植自 Beans 的 `LibraryView.swift`（817 行，取其主干）。
///
/// ── 与 Beans 的差异（必须说明）────────────────────────────────
/// Beans 的「音乐库」主体是**用户的云端歌单/收藏/最近播放**，
/// 那些都需要登录态；本项目不做账号，所以这里改成：
///
///   1. **正在播放队列**（真实可用，就是当前 PlayerManager 的队列）
///   2. **本地收藏**（用户在本机标星的歌，存本地，不需要账号）
///   3. 榜单入口（公开接口，等于"别人的歌单"）
///   4. 歌单广场按分类（公开接口）
///
/// 这是**在没有账号的前提下能做到的最接近"音乐库"的形态**。
/// 等以后如果要做账号，这里就是接云端歌单的位置。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with AutomaticKeepAliveClientMixin {
  final api = MusicApi.instance;
  final player = MusicPlayerManager.instance;

  List<TopList> _tops = const [];
  List<Song> _favorites = const [];
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final tops = await api.topLists();
    final favs = await FavoriteStore.instance.all();
    if (!mounted) return;
    setState(() {
      _tops = tops;
      _favorites = favs;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: MusicTheme.tint));
    }
    return RefreshIndicator(
      color: MusicTheme.tint,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 160),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text('音乐库',
                style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: 24,
                    fontWeight: FontWeight.w700)),
          ),
          _queueSection(),
          _favoriteSection(),
          if (_tops.isNotEmpty) ...[
            const SectionTitle(title: '榜单'),
            ..._tops.map((t) => ListTile(
                  leading: CoverImage(
                      url: t.coverUrl, size: 46, cornerRadius: 8),
                  title: Text(t.name,
                      style:
                          TextStyle(color: MusicTheme.label, fontSize: 15)),
                  subtitle: Text(t.updateFrequency ?? '',
                      style: TextStyle(
                          color: MusicTheme.secondary, fontSize: 12)),
                  trailing: Icon(Icons.chevron_right,
                      size: 18, color: MusicTheme.secondary),
                  onTap: () => openPlaylist(context, t.id, t.name),
                )),
          ],
        ],
      ),
    );
  }

  /// 正在播放队列（等于"当前歌单"，最实用的一个板块）
  Widget _queueSection() {
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final q = player.queue;
        if (q.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle(
              title: '正在播放',
              action: '${q.length} 首',
            ),
            ...q.take(6).toList().asMap().entries.map((e) => SongCell(
                  song: e.value,
                  index: e.key,
                  showCover: true,
                  playbackContext: q,
                )),
            if (q.length > 6)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 4),
                child: Text('还有 ${q.length - 6} 首…',
                    style: TextStyle(
                        color: MusicTheme.secondary, fontSize: 12)),
              ),
          ],
        );
      },
    );
  }

  Widget _favoriteSection() {
    if (_favorites.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
        child: GlassCard(
          child: Row(
            children: [
              Icon(Icons.favorite_border_rounded,
                  color: MusicTheme.secondary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '还没有收藏的歌曲。在歌曲右侧菜单里可以收藏（存在本机，不需要账号）。',
                  style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: 12,
                      height: 1.5),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title: '我的收藏', action: '${_favorites.length} 首'),
        ..._favorites.asMap().entries.map((e) => SongCell(
              song: e.value,
              playbackContext: _favorites,
            )),
      ],
    );
  }
}

/// 本机收藏（存在 SharedPreferences，**不需要登录**）。
///
/// Beans 的收藏是云端同步的（`FavoritesStore` 走账号）；
/// 这里退化成纯本地 —— 功能可用，只是换设备不同步。
class FavoriteStore {
  FavoriteStore._();
  static final FavoriteStore instance = FavoriteStore._();

  static const _key = 'music.favorites.v1';

  final revision = ValueNotifier<int>(0);

  Future<List<Song>> all() async {
    try {
      return await _cache();
    } catch (_) {
      return const [];
    }
  }

  Future<List<Song>> _cache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    return Song.listFromJson(raw);
  }

  Future<bool> isFavorite(Song s) async {
    final list = await _cache();
    return list.any((e) => e.identityKey == s.identityKey);
  }

  Future<void> toggle(Song s) async {
    final list = List<Song>.of(await _cache());
    final i = list.indexWhere((e) => e.identityKey == s.identityKey);
    if (i >= 0) {
      list.removeAt(i);
    } else {
      list.insert(0, s);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      Song.listToJson(list),
    );
    revision.value++;
  }
}
