import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/library_store.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import '../widgets/music_components.dart';
import 'playlist_detail_page.dart';
import 'playlist_page.dart';
import 'local_music_page.dart';
import '../../widgets/app_page_loading.dart';
import '../../common/theme.dart';

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

  /// 最近播放（Beans 歌单页的「最近播放」板块）
  List<Song> _recent = const [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 榜单要**跟随当前音乐平台**：切换平台后自动重载。
    // 本页 `wantKeepAlive = true`（切 tab 不重建），不监听的话会一直显示
    // 上一个平台的榜单，直到用户手动下拉刷新 —— 那就是"切了平台内容没变"。
    SettingsStore.instance.musicSource.addListener(_onSourceChanged);
    _load();
  }

  void _onSourceChanged() {
    if (mounted) _load();
  }

  @override
  void dispose() {
    SettingsStore.instance.musicSource.removeListener(_onSourceChanged);
    super.dispose();
  }

  Future<void> _load() async {
    // 用**当前**平台拉榜单（原来没传 source → 永远走网易云）
    final tops =
        await api.topLists(source: SettingsStore.instance.musicSource.value);
    final favs = await FavoriteStore.instance.all();
    await MusicLibraryStore.instance.init();
    if (!mounted) return;
    setState(() {
      _tops = tops;
      _favorites = favs;
      _recent = List<Song>.of(MusicLibraryStore.instance.recent);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return AppPageLoading(color: MusicTheme.tint);
    }
    // ⚠️ 必须包 SafeArea(top)：列表第一项"音乐库"标题原来紧贴状态栏，
    // 在刘海机上会被状态栏文字/时间压住（用户实测反馈）。
    // bottom: false —— 底部导航栏自己有 SafeArea，这里再来一层会多留白。
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
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
                    fontSize: AppTheme.fontPageTitle,
                    fontWeight: FontWeight.w700)),
          ),
          _queueSection(),
          _favoriteSection(),
          _recentSection(),
          // ── 我的内容：本地歌单 / 已下载（都不需要账号）──────────────
          const SectionTitle(title: '我的内容'),
          ListTile(
            leading: Icon(Icons.queue_music_rounded, color: MusicTheme.tint),
            title: Text('我的歌单',
                style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontHeadline)),
            subtitle: Text('本地歌单，不需要账号',
                style: TextStyle(
                    color: MusicTheme.secondary,
                    fontSize: AppTheme.fontFootnote)),
            trailing:
                Icon(Icons.chevron_right, size: 18, color: MusicTheme.secondary),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => const PlaylistListPage()),
            ),
          ),
          ListTile(
            leading:
                Icon(Icons.download_done_rounded, color: MusicTheme.tint),
            title: Text('本地音乐',
                style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontHeadline)),
            subtitle: Text('已下载的歌，离线可听',
                style: TextStyle(
                    color: MusicTheme.secondary,
                    fontSize: AppTheme.fontFootnote)),
            trailing:
                Icon(Icons.chevron_right, size: 18, color: MusicTheme.secondary),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => const LocalMusicPage()),
            ),
          ),
          if (_tops.isNotEmpty) ...[
            const SectionTitle(title: '榜单'),
            ..._tops.map((t) => ListTile(
                  leading: CoverImage(
                      url: t.coverUrl, size: 46, cornerRadius: 8),
                  title: Text(t.name,
                      style:
                          TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
                  subtitle: Text(t.updateFrequency ?? '',
                      style: TextStyle(
                          color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
                  trailing: Icon(Icons.chevron_right,
                      size: 18, color: MusicTheme.secondary),
                  // 进详情也要带平台：否则会拿酷狗的榜单 id 去查网易云（必然空）
                  onTap: () => openPlaylist(context, t.id, t.name,
                      source: SettingsStore.instance.musicSource.value),
                )),
            ],
          ],
        ),
      ),
    );
  }

  /// 最近播放（对齐 Beans 歌单页：**行尾显示时长**，只列前 6 首）
  Widget _recentSection() {
    if (_recent.isEmpty) return const SizedBox.shrink();
    final head = _recent.take(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title: '最近播放', action: '${_recent.length} 首'),
        ...head.map((s) => ListTile(
              leading: CoverImage(url: s.coverUrl, size: 46, cornerRadius: 8),
              title: Text(s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: MusicTheme.label,
                      fontSize: AppTheme.fontHeadline)),
              subtitle: Text(s.artists,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontFootnote)),
              // Beans 的行尾不是箭头，而是**时长**
              trailing: Text(
                _fmtDur(s.duration),
                style: TextStyle(
                    color: MusicTheme.secondary,
                    fontSize: AppTheme.fontFootnote),
              ),
              onTap: () => player.playQueue(_recent, index: _recent.indexOf(s)),
            )),
      ],
    );
  }

  /// 秒 → `m:ss`（Beans 就是这么显示的）
  static String _fmtDur(double sec) {
    final t = sec.round();
    if (t <= 0) return '--:--';
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
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
                        color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
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
                      fontSize: AppTheme.fontFootnote,
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

/// 本机收藏 —— **薄委托**到 `MusicLibraryStore`（统一存储）。
///
/// ── 🔴 为什么必须改成委托（这是一个真实的数据覆盖 bug）──────────
/// 原来这个类自己直连 SharedPreferences，键是 `music.favorites.v1`。
/// 而播放页的红心走的是 `MusicLibraryStore.favorites`，
/// **两者的键完全相同**，且都是"读全量 → 改一份 → 写回全量"。
///
/// 后果：
///   · 两个 store 各持一份**内存副本**，谁后写谁覆盖对方
///   · 于是"在播放页收藏了，音乐库页看不到"；
///     反过来在音乐库页取消收藏，也可能被播放页的旧副本写回去
///
/// 保留这个类名是为了**不改 3 个调用点**（`library_page.dart` 里的
/// `FavoriteStore.instance.all()/isFavorite()/toggle()`）——
/// 与阅读搜索框的"薄委托"是同一个手法：
/// **实现只有一份，调用点不用动**。
class FavoriteStore {
  FavoriteStore._();
  static final FavoriteStore instance = FavoriteStore._();

  /// 转发 `MusicLibraryStore` 的 revision（收藏变化时列表要刷新）
  ValueNotifier<int> get revision => MusicLibraryStore.instance.revisionProxy;

  Future<List<Song>> all() async {
    await MusicLibraryStore.instance.init();
    return MusicLibraryStore.instance.favorites;
  }

  Future<bool> isFavorite(Song s) async {
    await MusicLibraryStore.instance.init();
    return MusicLibraryStore.instance.isFavorite(s);
  }

  /// 返回**操作后**是否已收藏（与原签名兼容 —— 原实现返回 void）
  Future<void> toggle(Song s) async {
    await MusicLibraryStore.instance.toggleFavorite(s);
  }
}
