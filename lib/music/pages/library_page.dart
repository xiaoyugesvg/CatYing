import 'package:flutter/material.dart';

import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/services/library_store.dart';
import 'package:tvbox/music/services/download_service.dart';
import 'package:tvbox/music/services/music_api.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/services/settings_store.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/music_components.dart';
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
    _load();
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
          const SectionTitle(title: '我的内容'),
          // 卡片式导航行（原来是裸 ListTile：系统列表长相，
          // 跟下面的圆角卡片不是一个语言 —— 见 music_components 的说明）
          MusicNavTile(
            icon: Icons.queue_music_rounded,
            title: '我的歌单',
            subtitle: '本地歌单，不需要账号',
            trailingText: '${MusicLibraryStore.instance.playlists.length}',
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                  settings: const RouteSettings(name: 'music:page'),
                  builder: (_) => const PlaylistListPage()),
            ),
          ),
          MusicNavTile(
            icon: Icons.download_done_rounded,
            title: '本地音乐',
            subtitle: '已下载的歌，离线可听',
            trailingText:
                '${MusicDownloadService.instance.localSongs.length}',
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                settings: const RouteSettings(name: 'music:page'),
                // 🔴 音乐子页面是 push 到 root Navigator 的 → **不在**
                // `MusicRootView` 的 `Theme(MusicTheme.themeData())` 作用域里 ✗
                // → Scaffold/AppBar/Divider/Card 会回落到**影视侧** AppTheme 的配色 ✗
                // 所以每个 push 点自己包一层音乐主题 ✓
                builder: (_) => Theme(
                  data: MusicTheme.themeData(),
                  child: const LocalMusicPage(),
                ),
              ),
            ),
          ),

          // ② 正在播放（队列）
          _queueSection(),

          // ③④ 卡片式的两个"我的"列表
          _recentCard(),
          _favoriteCard(),
        ],
        ),
      ),
    );
  }

  // ============================================================
  // 卡片式的「最近播放」/「我的收藏」
  // ============================================================
  //
  // ── 为什么改成卡片（用户 2026 要求）──────────────────────────
  // 原来是 `ListTile` 一行一首的密列表：
  //   · 一行只看得到歌名 + 歌手，**封面很小（46）**，辨识度低
  //   · 长列表看起来像"系统列表"，不像音乐 App
  // 现在：
  //   · **2 列网格卡片**，封面大（整格宽、1:1）
  //   · 每格一张卡，视觉上就是"一张张能点的卡"
  //
  // ⚠️ 网格高度必须按**可用宽度**算，**不能用固定 childAspectRatio** ——
  //    固定比例在窄屏 + 系统大字号时会**溢出**（本项目已踩过两次，
  //    见 discover_page 里那两处注释）。
  //    算法：格子宽 w → 封面高 w + 两行文字 + 间距。

  /// 卡片网格（最近播放 / 收藏 共用）
  Widget _cardGrid({
    required List<Song> songs,
    required int maxCount,
    required bool showIndexBadge,
  }) {
    final shown = songs.take(maxCount).toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          mainAxisExtent: () {
            // 去掉左右 padding(16×2) 与列间距(12) 后每格宽度
            final w = (MediaQuery.sizeOf(context).width - 16 * 2 - 12) / 2;
            final ts = MediaQuery.textScalerOf(context);
            // 封面(w) + 间距 6 + 歌名一行 + 歌手一行
            return w + 6 + ts.scale(AppTheme.fontFootnote) * 1.35 * 2 + 6;
          }(),
        ),
        itemCount: shown.length,
        itemBuilder: (c, i) => _songCard(
          shown[i],
          index: showIndexBadge ? i + 1 : null,
          // 点卡片 → 从**整个列表**里对应的位置开始播（这样"下一首"才对）
          onTap: () {
            final at = songs.indexOf(shown[i]);
            player.playQueue(songs, index: at < 0 ? 0 : at);
          },
        ),
      ),
    );
  }

  /// 单张歌曲卡
  Widget _songCard(Song s, {int? index, required VoidCallback onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              // 封面撑满格子宽（正方形）
              AspectRatio(
                aspectRatio: 1,
                child: LayoutBuilder(
                  builder: (c, box) => CoverImage(
                    url: s.coverUrl,
                    size: box.maxWidth,
                    cornerRadius: 14,
                  ),
                ),
              ),
              // 序号角标（最近播放用 —— 让用户看得出播放顺序）
              if (index != null)
                Positioned(
                  left: 6,
                  top: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('$index',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: AppTheme.fontCaption,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              // VIP 角标
              if (s.isVIP)
                const Positioned(right: 6, top: 6, child: VipBadge()),
            ],
          ),
          const SizedBox(height: 6),
          Text(s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(
            s.artists.trim().isNotEmpty ? s.artists : s.album,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: MusicTheme.secondary, fontSize: AppTheme.fontCaption),
          ),
        ],
      ),
    );
  }

  /// ③ 最近播放（卡片式，最多 6 张）
  Widget _recentCard() {
    if (_recent.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title: '最近播放', action: '${_recent.length} 首'),
        _cardGrid(songs: _recent, maxCount: 6, showIndexBadge: true),
      ],
    );
  }

  /// ④ 我的收藏（卡片式，最多 6 张）
  Widget _favoriteCard() {
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
        _cardGrid(songs: _favorites, maxCount: 6, showIndexBadge: false),
      ],
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
                        color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
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
