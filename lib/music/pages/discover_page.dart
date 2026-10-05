import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/library_store.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import '../widgets/music_components.dart';
import 'playlist_detail_page.dart';
import 'ximalaya_album_page.dart';
import '../../widgets/app_page_loading.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/app_empty_view.dart';
import '../../common/theme.dart';

/// 发现页（主页）—— 支持多平台：网易云 / 酷狗 / 喜马拉雅
///
/// 各平台主页内容不同：
///   · 网易云：新歌速递 + 推荐歌单 + 排行榜 + 歌单广场
///   · 酷狗：新歌速递 + 排行榜（推荐歌单/歌单广场接口不支持）
///   · 喜马拉雅：分类浏览 + 热门专辑（有声书/播客形态）
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage>
    with AutomaticKeepAliveClientMixin {
  final api = MusicApi.instance;

  // 当前平台
  SongSource _source = SongSource.netease;

  // 音乐平台通用数据
  List<Song> _newSongs = const [];
  List<Playlist> _recommend = const [];
  List<TopList> _topLists = const [];
  List<Playlist> _square = const [];
  List<String> _cats = const ['全部'];
  String _cat = '全部';

  // QQ 音乐（公开接口）：热搜关键词
  List<String> _hotKeywords = const [];

  // 喜马拉雅数据
  List<({String id, String name})> _xmCategories = const [];
  List<Song> _xmFeatured = const []; // 精选专辑（取若干分类的头部内容）
  String _xmFeaturedCat = '';

  bool _loading = true;
  String _error = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _source = SettingsStore.instance.musicSource.value;
    _loadAll();
  }

  Future<void> _switchSource(SongSource s) async {
    if (s == _source) return;
    await SettingsStore.instance.setMusicSource(s);
    if (!mounted) return;
    setState(() {
      _source = s;
      _loading = true;
      _error = '';
    });
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      if (_source == SongSource.ximalaya) {
        await _loadXimalaya();
      } else if (_source == SongSource.qq) {
        await _loadQQ();
      } else {
        await _loadMusicPlatform();
      }
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  // ── QQ 音乐（公开接口：热搜 + 搜索，无登录态）──────────────────

  Future<void> _loadQQ() async {
    final h = await api.hotSearchResult(source: SongSource.qq);
    if (!mounted) return;
    _hotKeywords = h.ok ? h.list : const [];
    // 热搜失败不阻塞页面（搜索/播放仍可用）
    if (!h.ok) _error = h.error;
  }

  // ── 音乐平台（网易云 / 酷狗）──────────────────────────────────────

  Future<void> _loadMusicPlatform() async {
    final src = _source;
    final hasRecommend = src == SongSource.netease;
    final hasSquare = src == SongSource.netease;

    final futures = <Future<dynamic>>[
      api.newSongs(limit: 12, source: src),
      api.topLists(source: src),
    ];
    if (hasRecommend) {
      futures.insert(1, api.personalized(limit: 12, source: src));
    }
    if (hasSquare) {
      futures.add(api.playlistSquare(cat: _cat, limit: 9, source: src));
      futures.add(api.playlistCatlist(source: src));
    }

    final r = await Future.wait(futures);

    _newSongs = r[0] as List<Song>;
    var idx = 1;
    if (hasRecommend) {
      _recommend = r[idx] as List<Playlist>;
      idx++;
    } else {
      _recommend = const [];
    }
    _topLists = r[idx] as List<TopList>;
    idx++;
    if (hasSquare) {
      _square = r[idx] as List<Playlist>;
      idx++;
      final cats = r[idx] as List<String>;
      _cats = cats.isEmpty ? const ['全部'] : cats;
    } else {
      _square = const [];
      _cats = const ['全部'];
    }
  }

  Future<void> _switchCat(String cat) async {
    setState(() => _cat = cat);
    final list = await api.playlistSquare(cat: cat, limit: 9, source: _source);
    if (!mounted) return;
    setState(() => _square = list);
  }

  // ── 喜马拉雅 ──────────────────────────────────────────────────

  Future<void> _loadXimalaya() async {
    final cats = await api.ximalayaCategories();
    _xmCategories = cats;

    // 精选专辑：取第一个分类的前 12 条作为"热门推荐"
    if (cats.isNotEmpty) {
      _xmFeaturedCat = cats.first.name;
      final r = await api.ximalayaCategory(cats.first.id, page: 1);
      _xmFeatured = r.ok ? r.list : const [];
    } else {
      _xmFeaturedCat = '';
      _xmFeatured = const [];
    }
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
          SliverToBoxAdapter(child: _sourceTabs()),
          // Beans 主页顶部是**两张并排大卡**（每日推荐 / 私人漫游）。
          // 这里映射到**真实可用**的功能，不做假入口：
          //   · 每日推荐 → 直接播当天「新歌速递」
          //   · 私人漫游 → 从「我的收藏」随机漫游（没收藏就明确提示）
          SliverToBoxAdapter(child: _bigCards()),
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

  // ============================================================
  // 顶部两张并排大卡（对齐 Beans 主页排版）
  // ============================================================

  Widget _bigCards() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Row(
        children: [
          Expanded(
            child: _bigCard(
              title: '每日推荐',
              subtitle: _newSongs.isEmpty
                  ? '每天更新的新歌'
                  : '${_newSongs.length} 首 · 每天更新',
              icon: Icons.calendar_month_rounded,
              // 用当天新歌第一首的封面做底图（Beans 的「每日推荐」就是封面大图）
              coverUrl: _newSongs.isEmpty ? null : _newSongs.first.coverUrl,
              onTap: _newSongs.isEmpty
                  ? null
                  : () =>
                      MusicPlayerManager.instance.playQueue(_newSongs, index: 0),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _bigCard(
              title: '私人漫游',
              subtitle: '从收藏的歌开始漫游',
              icon: Icons.graphic_eq_rounded,
              onTap: _roam,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bigCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback? onTap,
    String? coverUrl,
  }) {
    final cover = (coverUrl ?? '').trim();
    final onCover = cover.isNotEmpty;
    // 有封面 → 图上的字用白色（靠图对比，同排行榜卡的处理）；
    // 没封面 → 回落到主题色 + 浅色底（**不写死页面配色**）
    final titleColor = onCover ? Colors.white : MusicTheme.label;
    final subColor = onCover
        ? Colors.white.withValues(alpha: 0.85)
        : MusicTheme.secondary;
    final iconColor = onCover ? Colors.white : MusicTheme.tint;

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 108,
          color: MusicTheme.tint.withValues(alpha: 0.14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (onCover)
                LayoutBuilder(
                  builder: (c, cons) => CoverImage(
                    url: cover,
                    size: cons.maxWidth,
                    cornerRadius: 0,
                  ),
                ),
              if (onCover)
                // 压暗，保证白字可读
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.18),
                        Colors.black.withValues(alpha: 0.58),
                      ],
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 18, color: iconColor),
                    const Spacer(),
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: titleColor,
                            fontSize: 19,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: subColor, fontSize: AppTheme.fontFootnote)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 私人漫游：从「我的收藏」随机播。
  ///
  /// 没有收藏时**明确告知**（而不是静默无反应）—— 否则用户点了没动静，
  /// 会以为功能坏了。
  Future<void> _roam() async {
    final store = MusicLibraryStore.instance;
    await store.init();
    final favs = List<Song>.of(store.favorites);
    if (favs.isEmpty) {
      AppToast.show('还没有收藏的歌', '先收藏几首，再回来漫游');
      return;
    }
    favs.shuffle();
    MusicPlayerManager.instance.playQueue(favs, index: 0);
  }

  /// 排行榜卡（对齐 Beans 原版）：
  ///   封面（1:1）**上面叠榜单名的大字** → 卡下：名称 + 更新频率。
  ///
  /// 说明为什么这里出现 `Colors.white`：封面上的叠字必须靠**图片对比**保证
  /// 可读性（Beans 也是这么做的），主题色在任意封面上都可能读不清 ——
  /// 这属于"图上文字"，不是页面配色，所以不违反"外观系统不变"。
  Widget _rankCard(TopList t) {
    final freq = (t.updateFrequency ?? '').trim();
    return GestureDetector(
      onTap: () => openPlaylist(context, t.id, t.name, source: _source),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LayoutBuilder(
                    builder: (c, cons) => CoverImage(
                      url: t.coverUrl,
                      size: cons.maxWidth,
                      cornerRadius: 0,
                    ),
                  ),
                  // 底部压暗，保证叠字可读
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.50),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: Text(
                      t.name,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        height: 1.15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(t.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: FontWeight.w600,
                  height: 1.2)),
          if (freq.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(freq,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: MusicTheme.secondary, fontSize: 11)),
          ],
        ],
      ),
    );
  }

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
                        fontSize: AppTheme.fontPageTitle,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  _source == SongSource.ximalaya
                      ? '今天想听点什么？'
                      : '今天想听点什么？',
                  style: TextStyle(
                      color: MusicTheme.secondary, fontSize: AppTheme.fontSubhead),
                ),
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

  /// 平台切换胶囊（和搜索页同款）
  Widget _sourceTabs() {
    final tabs = const [
      _SourceTab(source: SongSource.netease, label: '网易云'),
      _SourceTab(source: SongSource.qq, label: 'QQ音乐'),
      _SourceTab(source: SongSource.kugou, label: '酷狗'),
      _SourceTab(source: SongSource.ximalaya, label: '有声书'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          for (final t in tabs)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => _switchSource(t.source),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: _source == t.source
                        ? MusicTheme.tint
                        : MusicTheme.fill,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    t.label,
                    style: TextStyle(
                      color: _source == t.source
                          ? Colors.white
                          : MusicTheme.label,
                      fontSize: AppTheme.fontCaption,
                      fontWeight: _source == t.source
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _openSearchAll() {
    showSearch<void>(
      context: context,
      delegate: _QuickSearchDelegate(source: _source),
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
                        color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
              ),
              TextButton(
                onPressed: _loadAll,
                child: Text('重试',
                    style: TextStyle(color: MusicTheme.tint, fontSize: AppTheme.fontFootnote)),
              ),
            ],
          ),
        ),
      );

  // ============================================================
  // 版块
  // ============================================================

  List<Widget> _buildSections() {
    if (_source == SongSource.ximalaya) {
      return _buildXimalayaSections();
    }
    if (_source == SongSource.qq) {
      return _buildQQSections();
    }
    return _buildMusicSections();
  }

  /// QQ 音乐板块：热搜关键词（公开接口能拿到的就是这些）
  List<Widget> _buildQQSections() {
    final out = <Widget>[];
    if (_hotKeywords.isNotEmpty) {
      out.add(const SliverToBoxAdapter(child: SectionTitle(title: 'QQ音乐热搜')));
      out.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 48,
          ),
          delegate: SliverChildBuilderDelegate(
            (c, i) {
              final kw = _hotKeywords[i];
              return GestureDetector(
                onTap: () => showSearch<void>(
                  context: context,
                  delegate: _QuickSearchDelegate(source: SongSource.qq, initialQuery: kw),
                ),
                child: Container(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: MusicTheme.fill,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Text('${i + 1}',
                          style: TextStyle(
                              color: i < 3 ? MusicTheme.tint : MusicTheme.secondary,
                              fontSize: AppTheme.fontFootnote,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(kw,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: MusicTheme.label, fontSize: AppTheme.fontSubhead)),
                      ),
                    ],
                  ),
                ),
              );
            },
            childCount: _hotKeywords.length,
          ),
        ),
      ));
    }
    return out;
  }

  List<Widget> _buildMusicSections() {
    final out = <Widget>[];

    if (_newSongs.isNotEmpty) {
      out.add(const SliverToBoxAdapter(
          child: SectionTitle(title: '新歌速递')));
      out.add(SliverToBoxAdapter(
        child: HorizontalCards(
          itemCount: _newSongs.length,
          height: 212,
          itemWidth: 152,
          itemBuilder: (c, i) {
            final s = _newSongs[i];
            return CoverCard(
              coverUrl: s.coverUrl,
              title: s.name,
              subtitle: s.artists,
              width: 152,
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
          height: 212,
          itemWidth: 152,
          itemBuilder: (c, i) {
            final p = _recommend[i];
            return CoverCard(
              coverUrl: p.coverUrl,
              title: p.name,
              subtitle: p.trackCount > 0 ? '${p.trackCount} 首' : null,
              width: 152,
              onTap: () => openPlaylist(context, p.id, p.name, source: _source),
            );
          },
        ),
      ));
    }

    if (_topLists.isNotEmpty) {
      out.add(const SliverToBoxAdapter(child: SectionTitle(title: '排行榜')));
      // 对齐 Beans：**3 列大图卡**（不是横向小卡），卡下两行 = 名称 + 更新频率
      out.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 14,
            crossAxisSpacing: 12,
            // 🔴 与喜马拉雅分类页同款问题：固定比例**两头堵** ✗ ——
            // 宽屏格子被拉高、底部大片留白；窄屏 + 系统大字号时内容溢出 ✗。
            // 改成按**可用宽度**算格子高（1:1 封面 + 两行标题，随字号缩放）✓
            mainAxisExtent: () {
              final w =
                  (MediaQuery.sizeOf(context).width - 16 * 2 - 12 * 2) / 3;
              final ts = MediaQuery.textScalerOf(context);
              return w + 8 + ts.scale(12) * 1.35 * 2 + 6;
            }(),
          ),
          delegate: SliverChildBuilderDelegate(
            (c, i) => _rankCard(_topLists[i]),
            childCount: _topLists.length,
          ),
        ),
      ));
    }

    if (_square.isNotEmpty) {
      out.add(SliverToBoxAdapter(
        child: SectionTitle(title: '歌单广场', action: '$_cat', onAction: _pickCat),
      ));
      out.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 10,
            mainAxisSpacing: 14,
            // 🔴 同榜单/分类页：固定比例**两头堵** ✗（宽屏格子被拉高、底部大片留白；
            // 窄屏 + 系统大字号溢出）→ 改成按**可用宽度**算格子高
            //（1:1 封面 + 一行标题，随字号缩放）✓
            mainAxisExtent: () {
              final w =
                  (MediaQuery.sizeOf(context).width - 16 * 2 - 10 * 2) / 3;
              final ts = MediaQuery.textScalerOf(context);
              return w + 8 + ts.scale(12) * 1.35 + 6;
            }(),
          ),
          delegate: SliverChildBuilderDelegate(
            (c, i) {
              final p = _square[i];
              return CoverCard(
                coverUrl: p.coverUrl,
                title: p.name,
                subtitle: p.creator,
                width: double.infinity,
                onTap: () => openPlaylist(context, p.id, p.name, source: _source),
              );
            },
            childCount: _square.length,
          ),
        ),
      ));
    }
    return out;
  }

  List<Widget> _buildXimalayaSections() {
    final out = <Widget>[];

    // 精选专辑
    if (_xmFeatured.isNotEmpty) {
      out.add(SliverToBoxAdapter(
          child: SectionTitle(title: _xmFeaturedCat)));
      out.add(SliverToBoxAdapter(
        child: HorizontalCards(
          itemCount: _xmFeatured.length,
          height: 212,
          itemWidth: 152,
          itemBuilder: (c, i) {
            final s = _xmFeatured[i];
            return CoverCard(
              coverUrl: s.coverUrl,
              title: s.name,
              subtitle: s.artists,
              width: 152,
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => XimalayaAlbumPage(
                    albumId: s.id.toString(),
                    albumName: s.name,
                  ),
                ),
              ),
            );
          },
        ),
      ));
    }

    // 全部分类
    if (_xmCategories.isNotEmpty) {
      out.add(const SliverToBoxAdapter(
          child: SectionTitle(title: '全部分类')));
      out.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 12,
            childAspectRatio: 2.4,
          ),
          delegate: SliverChildBuilderDelegate(
            (c, i) {
              final cat = _xmCategories[i];
              return _CategoryTile(
                name: cat.name,
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => _AlbumListPage(
                      categoryId: cat.id,
                      categoryName: cat.name,
                    ),
                  ),
                ),
              );
            },
            childCount: _xmCategories.length,
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

class _SourceTab {
  final SongSource source;
  final String label;
  const _SourceTab({required this.source, required this.label});
}

/// 喜马拉雅分类卡片（大圆角、图标+文字）
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: MusicTheme.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: MusicTheme.label.withValues(alpha: 0.06),
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: MusicTheme.tint.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.graphic_eq_rounded,
                  color: MusicTheme.tint, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w500),
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: MusicTheme.secondary, size: 18),
          ],
        ),
      ),
    );
  }
}

/// 分类下的专辑列表页（内嵌；独立页也有一个，这里保持轻量）
class _AlbumListPage extends StatefulWidget {
  const _AlbumListPage({required this.categoryId, required this.categoryName});

  final String categoryId;
  final String categoryName;

  @override
  State<_AlbumListPage> createState() => _AlbumListPageState();
}

class _AlbumListPageState extends State<_AlbumListPage> {
  final _scrollCtrl = ScrollController();
  final _items = <Song>[];
  int _page = 1;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
    _scrollCtrl.addListener(() {
      if (!_hasMore || _loadingMore) return;
      if (_scrollCtrl.position.pixels >=
          _scrollCtrl.position.maxScrollExtent - 200) {
        _loadMore();
      }
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final r = await MusicApi.instance
          .ximalayaCategory(widget.categoryId, page: 1);
      if (!mounted) return;
      setState(() {
        _items.clear();
        _items.addAll(r.list);
        _page = 1;
        _hasMore = r.list.length >= 20;
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

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final r = await MusicApi.instance
          .ximalayaCategory(widget.categoryId, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _items.addAll(r.list);
        _page++;
        _hasMore = r.list.length >= 20;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        appBar: AppBar(title: Text(widget.categoryName)),
        body: _loading
            ? Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: MusicTheme.tint),
                ),
              )
            : _error.isNotEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error,
                            style: TextStyle(
                                color: MusicTheme.secondary,
                                fontSize: AppTheme.fontBody)),
                        const SizedBox(height: 14),
                        TextButton(
                            onPressed: _load,
                            child: Text('重试',
                                style: TextStyle(color: MusicTheme.tint))),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: _items.length + (_hasMore ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i == _items.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: MusicTheme.tint),
                            ),
                          ),
                        );
                      }
                      final s = _items[i];
                      return SongCell(
                        song: s,
                        onTap: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => XimalayaAlbumPage(
                              albumId: s.id.toString(),
                              albumName: s.name,
                            ),
                          ),
                        ),
                        trailing: Icon(Icons.chevron_right_rounded,
                            color: MusicTheme.secondary, size: 20),
                      );
                    },
                  ),
      ),
    );
  }
}

/// 轻量搜索弹层（主页放大镜用；完整搜索在「搜索」tab）
class _QuickSearchDelegate extends SearchDelegate<void> {
  _QuickSearchDelegate({required this.source, this.initialQuery = ''});

  final SongSource source;

  /// 热搜/榜单直接点词搜索时预置的关键词（query 为空时用它兜底）
  final String initialQuery;

  @override
  ThemeData appBarTheme(BuildContext context) => Theme.of(context).copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
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
    // 热搜点击预置词：SearchDelegate 的 query 只读，用 initialQuery 兜底
    final q = query.trim().isEmpty ? initialQuery.trim() : query.trim();
    if (q.isEmpty) {
      return Center(
        child: Text('输入歌名、歌手或专辑',
            style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontSubhead)),
      );
    }
    return FutureBuilder<MusicListResult<Song>>(
      future: MusicApi.instance.search(q, limit: 30, source: source),
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
          itemBuilder: (c, i) {
            final song = r.list[i];
            if (source == SongSource.ximalaya) {
              return SongCell(
                song: song,
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => XimalayaAlbumPage(
                      albumId: song.id.toString(),
                      albumName: song.name,
                    ),
                  ),
                ),
                trailing: Icon(Icons.chevron_right_rounded,
                    color: MusicTheme.secondary, size: 20),
              );
            }
            return SongCell(
              song: song,
              playbackContext: r.list,
              onTap: () => MusicPlayerManager.instance
                  .playQueue(r.list, index: i),
            );
          },
        );
      },
    );
  }
}
