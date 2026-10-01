import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../widgets/music_components.dart';
import 'playlist_detail_page.dart';
import '../../widgets/app_page_loading.dart';
import '../../widgets/app_empty_view.dart';

/// 发现页（主页）—— 移植自 Beans 的 `DiscoverView.swift`（2074 行，取其主干）。
///
/// ── 版块（与 Beans 一致，按顺序）──────────────────────────────
///   1. 顶部问候 + 搜索入口（滚动到顶时显示大标题）
///   2. 每日推荐 / 新歌速递（横向大卡）
///   3. 推荐歌单（横向卡）
///   4. 排行榜（横向卡，点进去是歌单详情）
///   5. 歌单广场（按分类，网格）
///
/// Beans 的"每日推荐"需要账号（个性化）；这里用**新歌速递 + 推荐歌单**
/// 替代 —— 都是公开接口，效果接近且不需要登录。
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage>
    with AutomaticKeepAliveClientMixin {
  final api = MusicApi.instance;

  List<Song> _newSongs = const [];
  List<Playlist> _recommend = const [];
  List<TopList> _topLists = const [];
  List<Playlist> _square = const [];
  List<String> _cats = const ['全部'];
  String _cat = '全部';

  bool _loading = true;
  String _error = '';

  @override
  bool get wantKeepAlive => true; // 切 tab 回来不要重新加载

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final r = await Future.wait([
        api.newSongs(limit: 12),
        api.personalized(limit: 12),
        api.topLists(),
        api.playlistSquare(cat: _cat, limit: 9),
        api.playlistCatlist(),
      ]);
      if (!mounted) return;
      setState(() {
        _newSongs = r[0] as List<Song>;
        _recommend = r[1] as List<Playlist>;
        _topLists = r[2] as List<TopList>;
        _square = r[3] as List<Playlist>;
        final cats = r[4] as List<String>;
        _cats = cats.isEmpty ? const ['全部'] : cats;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _switchCat(String cat) async {
    setState(() => _cat = cat);
    final list = await api.playlistSquare(cat: cat, limit: 9);
    if (!mounted) return;
    setState(() => _square = list);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return AppPageLoading(color: MusicTheme.tint);
    }
    return RefreshIndicator(
      color: MusicTheme.tint,
      onRefresh: _loadAll,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _header()),
          if (_error.isNotEmpty)
            SliverToBoxAdapter(child: _errorBox()),
          ..._buildSections(),
          const SliverToBoxAdapter(child: SizedBox(height: 150)),
        ],
      ),
    );
  }

  // ============================================================
  // 顶部
  // ============================================================

  Widget _header() {
    final h = DateTime.now().hour;
    final greet = h < 6
        ? '夜深了'
        : h < 12
            ? '早上好'
            : h < 14
                ? '中午好'
                : h < 18
                    ? '下午好'
                    : '晚上好';
    return Padding(
      // ⚠️ 顶部内边距必须 ≥ 状态栏高度，否则问候语会被状态栏盖住。
      // 这里直接用 viewPadding.top 而不是硬编码数字 —— 刘海机/非刘海机
      // 高度不同，硬编码必然在其中一种上出错。
      padding: EdgeInsets.fromLTRB(
          16, MediaQuery.viewPaddingOf(context).top + 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(greet,
                    style: TextStyle(
                        color: MusicTheme.label,
                        fontSize: 24,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('今天想听点什么？',
                    style: TextStyle(
                        color: MusicTheme.secondary, fontSize: 13)),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _openSearchAll(),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: MusicTheme.fill,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.search_rounded,
                  color: MusicTheme.label, size: 21),
            ),
          ),
        ],
      ),
    );
  }

  void _openSearchAll() {
    // 主页的搜索按钮：跳到搜索 tab 的语义由外层 RootView 管，
    // 这里给一个轻量替代 —— 打开一个搜索弹层
    showSearch<void>(
      context: context,
      delegate: _QuickSearchDelegate(),
    );
  }

  Widget _errorBox() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: GlassCard(
          child: Row(
            children: [
              Icon(Icons.wifi_off_rounded,
                  color: MusicTheme.secondary, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text('部分内容加载失败：$_error',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: MusicTheme.secondary, fontSize: 12)),
              ),
              TextButton(
                onPressed: _loadAll,
                child: Text('重试',
                    style: TextStyle(color: MusicTheme.tint, fontSize: 12)),
              ),
            ],
          ),
        ),
      );

  // ============================================================
  // 版块
  // ============================================================

  List<Widget> _buildSections() {
    final out = <Widget>[];

    if (_newSongs.isNotEmpty) {
      out.add(const SliverToBoxAdapter(
          child: SectionTitle(title: '新歌速递')));
      out.add(SliverToBoxAdapter(
        child: HorizontalCards(
          itemCount: _newSongs.length,
          height: 186,
          itemWidth: 130,
          itemBuilder: (c, i) {
            final s = _newSongs[i];
            return CoverCard(
              coverUrl: s.coverUrl,
              title: s.name,
              subtitle: s.artists,
              width: 130,
              badge: s.isVIP ? 'VIP' : null,
              onTap: () => MusicPlayerManager.instance
                  .playQueue(_newSongs, index: i),
            );
          },
        ),
      ));
    }

    if (_recommend.isNotEmpty) {
      out.add(const SliverToBoxAdapter(
          child: SectionTitle(title: '推荐歌单')));
      out.add(SliverToBoxAdapter(
        child: HorizontalCards(
          itemCount: _recommend.length,
          height: 186,
          itemWidth: 130,
          itemBuilder: (c, i) {
            final p = _recommend[i];
            return CoverCard(
              coverUrl: p.coverUrl,
              title: p.name,
              subtitle: p.trackCount > 0 ? '${p.trackCount} 首' : null,
              width: 130,
              onTap: () => openPlaylist(context, p.id, p.name),
            );
          },
        ),
      ));
    }

    if (_topLists.isNotEmpty) {
      out.add(const SliverToBoxAdapter(child: SectionTitle(title: '排行榜')));
      out.add(SliverToBoxAdapter(
        child: HorizontalCards(
          itemCount: _topLists.length,
          height: 186,
          itemWidth: 130,
          itemBuilder: (c, i) {
            final t = _topLists[i];
            return CoverCard(
              coverUrl: t.coverUrl,
              title: t.name,
              subtitle: t.updateFrequency,
              width: 130,
              onTap: () => openPlaylist(context, t.id, t.name),
            );
          },
        ),
      ));
    }

    // 歌单广场（分类切换 + 网格）
    out.add(SliverToBoxAdapter(
      child: SectionTitle(title: '歌单广场', action: '$_cat', onAction: _pickCat),
    ));
    if (_square.isNotEmpty) {
      out.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 10,
            mainAxisSpacing: 14,
            childAspectRatio: 0.66,
          ),
          delegate: SliverChildBuilderDelegate(
            (c, i) {
              final p = _square[i];
              return CoverCard(
                coverUrl: p.coverUrl,
                title: p.name,
                subtitle: p.creator,
                width: double.infinity,
                onTap: () => openPlaylist(context, p.id, p.name),
              );
            },
            childCount: _square.length,
          ),
        ),
      ));
    }
    return out;
  }

  Future<void> _pickCat() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MusicTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          children: _cats
              .map((c) => ListTile(
                    title: Text(c,
                        style: TextStyle(
                            color: c == _cat
                                ? MusicTheme.tint
                                : MusicTheme.label)),
                    trailing: c == _cat
                        ? Icon(Icons.check, color: MusicTheme.tint, size: 18)
                        : null,
                    onTap: () => Navigator.pop(ctx, c),
                  ))
              .toList(),
        ),
      ),
    );
    if (picked != null && picked != _cat) await _switchCat(picked);
  }
}

/// 轻量搜索弹层（主页放大镜用；完整搜索在「搜索」tab）
class _QuickSearchDelegate extends SearchDelegate<void> {
  @override
  ThemeData appBarTheme(BuildContext context) => Theme.of(context).copyWith(
        scaffoldBackgroundColor: MusicTheme.background,
        appBarTheme: AppBarTheme(
          backgroundColor: MusicTheme.background,
          elevation: 0,
        ),
        inputDecorationTheme: const InputDecorationTheme(border: InputBorder.none),
      );

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            icon: Icon(Icons.close, color: MusicTheme.secondary),
            onPressed: () => query = '',
          ),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: Icon(Icons.arrow_back, color: MusicTheme.label),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _results(context);

  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    if (query.trim().isEmpty) {
      return Center(
        child: Text('输入歌名、歌手或专辑',
            style: TextStyle(color: MusicTheme.secondary, fontSize: 13)),
      );
    }
    return FutureBuilder<MusicListResult<Song>>(
      future: MusicApi.instance.search(query, limit: 30),
      builder: (c, snap) {
        if (!snap.hasData) {
          return AppPageLoading(color: MusicTheme.tint);
        }
        final r = snap.data!;
        if (!r.ok || r.list.isEmpty) {
          return AppEmptyView(
            icon: Icons.search_off_rounded,
            title: r.message.isEmpty ? '没有找到结果' : r.message,
          );
        }
        return ListView.builder(
          itemCount: r.list.length,
          itemBuilder: (c, i) => SongCell(
            song: r.list[i],
            playbackContext: r.list,
            onTap: () => MusicPlayerManager.instance
                .playQueue(r.list, index: i),
          ),
        );
      },
    );
  }
}
