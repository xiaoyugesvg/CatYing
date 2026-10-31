import 'package:flutter/material.dart';

import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/services/library_store.dart';
import 'package:tvbox/music/services/download_service.dart';
import 'package:tvbox/music/services/music_api.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/services/settings_store.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/music_components.dart';
import 'package:tvbox/music/widgets/mo_lv_blocks.dart';
import 'package:tvbox/music/widgets/mo_lv_pages.dart';
import 'package:tvbox/music/pages/playlist_page.dart';
import 'package:tvbox/music/pages/local_music_page.dart';
import 'package:tvbox/widgets/app_page_loading.dart';
import 'package:tvbox/common/theme.dart';

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
    // ── 🔴 收藏 / 最近播放变化时**必须刷新**（修"收藏了但乐库看不到"）──
    //
    // 本页 `wantKeepAlive = true`（见上面 `wantKeepAlive`），切 tab 不重建，
    // 而 `_load()` 只在 `initState` 和"切平台"时跑。所以：
    //   在**播放页**点收藏 → 切回「乐库」→ 列表里**没有这首歌**，
    //   而且不会自愈（要下拉刷新或杀进程重进）。
    //
    // `MusicLibraryStore` 每次变更都会 `revisionProxy.value++`
    //（见 `library_store.dart` 的 `_bump()`），
    // 而本文件 :400-401 的 `FavoriteStore.revision` 注释也写明
    // "收藏变化时列表要刷新" —— 但**之前全项目没有一个地方监听它**
    //（定义了却没人用 = 等于没写）。
    //
    // 这里挂上就修好了：收藏/取消收藏/加最近播放/换歌单 → 自动重载。
    MusicLibraryStore.instance.revisionProxy.addListener(_onLibraryChanged);
    // ── 🔴 下载完成 / 删除 / 清空时**必须重建**（修"下载了但乐库显示 0"）──
    //
    // 用户 2026-10-31 截图：本地音乐页明明写着「已下载 1 首 · 8.6 MB」，
    // 乐库页的统计格却是「0 下载」、本地音乐那行也是「0」。
    //
    // 根因是两件事叠在一起：
    //   ① 本页 `wantKeepAlive = true` ⇒ 切 tab **不重建**（见上面注释）；
    //   ② `MusicDownloadService` 是个 `ChangeNotifier`，`notifyListeners()`
    //      一直在发（下载进度每一帧都发），但**全项目没有一处监听它** ——
    //      定义了却没人收 = 等于没写。
    // 于是 `build()` 里读到的 `localSongs.length` 永远停在"第一次 build 时"的
    // 值：启动时清单是空的（`main.dart` 的 `init()` 那时还没下过歌）⇒ 0 卡死。
    //
    // 本地音乐页之所以是对的：它每次进入都新建 State、在 `initState` 里现读。
    MusicDownloadService.instance.addListener(_onDownloadsChanged);
    _load();
  }

  /// 下载清单变了（完成 / 删除 / 清空）→ 重建，让统计格和「本地音乐」计数跟上
  ///
  /// ⚠️ 不能无脑 `setState`：`onReceiveProgress` 每收一块数据就
  /// `notifyListeners()` 一次，无脑重建等于给一个**在别的 tab 上、还
  /// keepAlive 活着**的页面每帧刷新一遍。只在**条数变了**的时候重建。
  int _downloadCount = -1;

  void _onDownloadsChanged() {
    if (!mounted) return;
    final n = MusicDownloadService.instance.localSongs.length;
    if (n == _downloadCount) return;
    setState(() => _downloadCount = n);
  }

  /// 收藏 / 最近播放 / 歌单发生变化 → 重新读一份
  void _onLibraryChanged() {
    // ⚠️ `revisionProxy` 可能在 `_load()` 的 await 期间再次触发
    //（例如连续点收藏），所以 `_load()` 自己也会判 `mounted`
    //（见 `_load` 里的 `if (!mounted) return;`）——
    // 这里只是再加一道，避免已销毁的 State 白跑一趟。
    if (mounted) _load();
  }

  void _onSourceChanged() {
    if (mounted) _load();
  }

  @override
  void dispose() {
    SettingsStore.instance.musicSource.removeListener(_onSourceChanged);
    // ⚠️ 成对移除：`ValueNotifier` 会**一直持有**监听闭包，
    // 不移除就是"页面已销毁但每次收藏仍会调它"的泄漏。
    MusicLibraryStore.instance.revisionProxy.removeListener(_onLibraryChanged);
    // 同上，成对移除（`ChangeNotifier` 也会一直持有闭包）
    MusicDownloadService.instance.removeListener(_onDownloadsChanged);
    super.dispose();
  }

  Future<void> _load() async {
    // ⚠️ 这里**不再拉榜单** —— 榜单已拆成独立 tab（见 `charts_page.dart`）。
    //    原来为了"榜单加载失败可点重试"插哨兵项（id=-1）的那套逻辑
    //    一起移走了（`ChartsPage` 自己用 `topListsResult` 并显示重试按钮）。
    final favs = await FavoriteStore.instance.all();
    await MusicLibraryStore.instance.init();
    if (!mounted) return;
    setState(() {
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
    final playlists = MusicLibraryStore.instance.playlists;
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
          // 大标题 + 副标题（对齐设计稿「墨律」：每页都是"大标题 + 一行说明"）
          const MusicPageHeader(
            title: '乐库',
            subtitle: '全部存在本机 · 不需要账号',
          ),
          // 四个统计格：收藏 / 歌单 / 最近 / 下载（等分，随数量变）
          MusicStatRow(
            stats: [
              MusicStat(value: '${_favorites.length}', label: '收藏'),
              MusicStat(
                value: '${MusicLibraryStore.instance.playlists.length}',
                label: '歌单',
              ),
              MusicStat(value: '${_recent.length}', label: '最近'),
              MusicStat(
                value: '${MusicDownloadService.instance.localSongs.length}',
                label: '下载',
              ),
            ],
          ),

          // ══════════════════════════════════════════════════════════
          // 区块顺序（用户 2026 明确指定）
          // ══════════════════════════════════════════════════════════
          //
          //   ① 我的内容   —— 歌单 / 本地音乐（"我的"最该在最上面）
          //   ② 正在播放   —— 当前队列
          //   ③ 最近播放   —— **卡片式**
          //   ④ 我的收藏   —— **卡片式**
          //
          // ⚠️ 原来顺序是"队列 → 收藏 → 最近 → 我的内容 → 榜单"，
          //    没有逻辑（"我的内容"被压到中间、榜单压到最后），
          //    而且 `榜单` 已拆成独立 tab（见 charts_page.dart），
          //    这里**不再重复**。
          // ══════════════════════════════════════════════════════════
          // 按设计稿 `02_乐库.png` 重排（2026-10-31）
          //
          //   ① 我的歌单   —— **横滑方卡**（原来是一行导航条，看不出有几首）
          //   ② 最近播放   —— **行列表**（原来是 2 列大网格，一屏只放 4 首）
          //   ③ 正在播放   —— 行列表
          //   ④ 我的收藏   —— 行列表
          //   ⑤ 本地音乐   —— 导航条（它是"入口"，不是内容）
          //
          // 为什么网格换成行列表：设计稿 02 的「最近播放」是三行紧凑列表，
          // 一行 = 封面 + 歌名 + 歌手 + 时长。网格适合"专辑/歌单"这种有封面
          // 主体的东西，单曲用网格一屏只能放 4 首，找歌反而慢。
          // ══════════════════════════════════════════════════════════
          MoLvSectionTitle(
            title: '我的歌单',
            trailing: playlists.isEmpty ? null : '${playlists.length} 个',
            onMore: _openPlaylists,
          ),
          if (playlists.isEmpty)
            _emptyPlaylistHint()
          else
            MoLvShelf(
              items: [
                for (final p in playlists.take(10))
                  MoLvShelfItem(title: p.name, subtitle: '${p.length} 首'),
              ],
              onTap: (i) => _openPlaylist(playlists[i]),
            ),

          _recentSection(),
          _queueSection(),
          _favoriteSection(),

          const SizedBox(height: 12),
          MusicNavTile(
            icon: Icons.download_done_rounded,
            title: '本地音乐',
            subtitle: '已下载的歌，离线可听',
            trailingText:
                '${MusicDownloadService.instance.localSongs.length}',
            onTap: _openLocalMusic,
          ),
        ],
        ),
      ),
    );
  }

  // ============================================================
  // 页面跳转 / 空状态
  // ============================================================
  //
  // 🔴 音乐子页面是 push 到 root Navigator 的 → **不在**
  //    `MusicRootView` 的 `Theme(MusicTheme.themeData())` 作用域里 ✗
  //    → Scaffold/AppBar/Divider/Card 会回落到**影视侧** AppTheme 的配色 ✗
  //    所以每个 push 点自己包一层音乐主题 ✓

  void _openPlaylists() => Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: 'music:page'),
          builder: (_) => Theme(
            data: MusicTheme.themeData(),
            child: const PlaylistListPage(),
          ),
        ),
      );

  void _openPlaylist(MusicPlaylist p) => Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: 'music:page'),
          builder: (_) => Theme(
            data: MusicTheme.themeData(),
            child: PlaylistDetailPage(playlistId: p.id),
          ),
        ),
      );

  void _openLocalMusic() => Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: 'music:page'),
          builder: (_) => Theme(
            data: MusicTheme.themeData(),
            child: const LocalMusicPage(),
          ),
        ),
      );

  Widget _emptyPlaylistHint() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: GlassCard(
          child: Row(
            children: [
              Icon(Icons.queue_music_rounded,
                  color: MusicTheme.secondary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '还没有歌单。在歌曲右侧菜单里可以把歌加进新歌单（存在本机，不需要账号）。',
                  style: TextStyle(
                    color: MusicTheme.secondary,
                    fontSize: AppTheme.fontFootnote,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  /// ② 最近播放（设计稿 02：行列表，最多 4 行）
  Widget _recentSection() {
    if (_recent.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MoLvSectionTitle(title: '最近播放', trailing: '${_recent.length} 首'),
        MoLvTrackList(
          songs: _recent,
          maxCount: 4,
          playingKey: player.currentSong?.identityKey,
          // 从**整个列表**里对应的位置开始播（这样"下一首"才对）
          onTap: (i) => player.playQueue(_recent, index: i),
        ),
      ],
    );
  }

  /// ④ 我的收藏（行列表）
  Widget _favoriteSection() {
    if (_favorites.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
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
        MoLvSectionTitle(title: '我的收藏', trailing: '${_favorites.length} 首'),
        MoLvTrackList(
          songs: _favorites,
          maxCount: 4,
          playingKey: player.currentSong?.identityKey,
          onTap: (i) => player.playQueue(_favorites, index: i),
        ),
      ],
    );
  }


  /// ③ 正在播放队列（等于"当前歌单"，最实用的一个板块）
  Widget _queueSection() {
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final q = player.queue;
        if (q.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MoLvSectionTitle(
              title: '正在播放',
              trailing: '${q.length} 首',
            ),
            MoLvTrackList(
              songs: q,
              maxCount: 4,
              playingKey: player.currentSong?.identityKey,
              onTap: (i) => player.playQueue(q, index: i),
            ),
            if (q.length > 4)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 4),
                child: Text('还有 ${q.length - 4} 首…',
                    style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: AppTheme.fontFootnote)),
              ),
          ],
        );
      },
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
