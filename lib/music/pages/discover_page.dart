import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/library_store.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import '../theme/discover_preset.dart';
import '../widgets/music_components.dart';
import '../widgets/discover_sections.dart';
import 'playlist_detail_page.dart';
import 'ximalaya_album_page.dart';
import 'bookan_album_page.dart';
import 'bookan_category_page.dart';
import 'book275_album_page.dart';
import 'book275_category_page.dart';
import '../../widgets/app_page_loading.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/app_empty_view.dart';
import '../../common/theme.dart';
import '../../services/app_log.dart';

/// 发现页（主页）—— 支持多平台：网易云 / 酷狗 / 喜马拉雅 / 博看听书 / 275听书
///
/// 各平台主页内容不同：
///   · 网易云：新歌速递 + 推荐歌单 + 排行榜 + 歌单广场
///   · 酷狗：新歌速递 + 排行榜（推荐歌单/歌单广场接口不支持）
///   · 喜马拉雅：分类浏览 + 热门专辑（有声书/播客形态）
///   · 博看：分类浏览 + 各分类热门专辑（有声书，纯 Dart 直连）
///   · 275：分类浏览 + 最近上架（有声小说，HTML 站 + PHP 会话）
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

  /// 发现页视觉预设（aurora / paper / midnight）。
  ///
  /// ⚠️ 它是**页面自己的偏好**，不覆盖全局主题 ——
  /// 颜色仍全部来自 `MusicTheme`，预设只决定背景与卡片材质。
  DiscoverPreset _preset = DiscoverPreset.aurora;

  // QQ 音乐（公开接口）：热搜关键词
  List<String> _hotKeywords = const [];

  /// QQ 排行榜（免登录可拿，实测 30 个榜单）
  List<TopList> _qqTopLists = const [];

  /// QQ 歌单广场（免登录可拿，实测 20 个歌单）
  List<Playlist> _qqSquare = const [];

  /// QQ 歌单广场分类名（实测 40 个）。
  ///
  /// ⚠️ **只用来展示"有哪些分类"，不做切换** ——
  /// QQ 的 `categoryId` 是**数字**（如 10000000=全部），而 Dart 侧
  /// `playlistCatlist()` 的返回被设计成**名字列表**（网易云/酷狗用名字）。
  /// 名字 → 数字 id 的映射在 Node 侧没暴露，所以硬做切换会把 id 猜错 →
  /// 用户点了"华语"却拿到"全部"（**假功能**）。
  /// 宁可不给切换，也不要给一个点了没用的按钮。
  List<String> _qqCats = const [];

  /// QQ「热门歌手」—— **带真头像**（头像模板实测可用）。
  ///
  /// ── 数据来源（为什么不是调歌手列表接口）──────────────────────
  /// QQ 免登录**没有**歌手列表接口（实测 `GetSingerList` → `code=500003`，
  /// `fcg_v8_singer_track_cp` → 404）。但：
  ///   · 歌手**头像模板是通的** → `T001R150x150M000{mid}.jpg`
  ///   · 歌曲里**带着 singerMid**
  /// 所以 Node 侧 `topArtistsList` 从榜单歌曲里收集去重歌手 + 拼头像 URL。
  ///
  /// ⚠️ 原来这里只是 `List<String>`（歌名），界面只能画**首字圆圈**
  ///（"王"/"G"/"K"）—— 用户对比参考图后指出"差远了"。
  List<({String name, String avatar, String mid})> _qqArtists = const [];

  // 喜马拉雅数据
  List<({String id, String name})> _xmCategories = const [];
  List<Song> _xmFeatured = const []; // 精选专辑（取若干分类的头部内容）
  String _xmFeaturedCat = '';

  // 博看听书数据（纯 Dart 直连，见 MusicApi.bookan*）
  List<Song> _bkFeatured = const []; // 热门推荐（各分类头部合并）

  // 275听书数据（纯 Dart 直连，见 MusicApi.book275*）
  List<Song> _b275Featured = const []; // 最近上架（首页）

  bool _loading = true;
  String _error = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _source = SettingsStore.instance.musicSource.value;
    // 视觉预设：读上次选的（默认 aurora）
    _preset = SettingsStore.instance.discoverPreset;
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
      } else if (_source == SongSource.bookan) {
        await _loadBookan();
      } else if (_source == SongSource.book275) {
        await _loadBook275();
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

    // ── QQ 的免登录发现页数据（排行榜 / 歌单广场 / 分类）─────────
    //
    // ⚠️ 这三样**免登录就能拿**（已实测 HTTP 200），
    //    与"播放地址"完全不同（那个必须 QQ 登录 Cookie）。
    //    文案上必须说清这个区别，否则用户会以为"既然能看到榜单，
    //    那应该也能播" → 点了播放失败 → 以为 App 坏了。
    try {
      final results = await Future.wait([
        api.topLists(source: SongSource.qq),
        // ⚠️ Dart 侧 `playlistSquare` 的参数是 **`cat`（分类名）**，
        //    QQ 的 Node 实现会把它当 categoryId 解析 ——
        //    不传时用 "全部"（Node 侧会兜底成 10000000）。
        api.playlistSquare(cat: '全部', limit: 12, source: SongSource.qq),
        api.playlistCatlist(source: SongSource.qq),
      ]);
      if (!mounted) return;
      _qqTopLists = results[0] as List<TopList>;
      _qqSquare = results[1] as List<Playlist>;
      _qqCats = (results[2] as List<String>).take(20).toList();
    } catch (e) {
      // 免登录接口失败不该阻塞整页（热搜/搜索仍可用）
      AppLog.instance.log('[Discover] QQ 发现页数据加载失败: $e');
    }

    // ── 热门歌手（**带真头像**）──────────────────────────────────
    //
    // Node 侧从榜单歌曲里收集去重歌手 + 拼头像 URL（见字段注释）。
    // 用热歌榜(26)当来源 —— 榜单 id 是 QQ 的固定值，不需要先拉榜单列表。
    final artists = await api.topArtists(topId: 26, limit: 14);
    if (!mounted) return;
    _qqArtists = artists;
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

  // ── 博看听书 ──────────────────────────────────────────────────

  Future<void> _loadBookan() async {
    // 热门推荐：各分类第一页头部合并（上限 30，容错：单分类失败跳过）
    final r = await api.bookanHome();
    if (!mounted) return;
    setState(() => _bkFeatured = r);
  }

  // ── 275听书 ──────────────────────────────────────────────────

  Future<void> _loadBook275() async {
    // 最近上架 = 首页卡片
    final r = await api.book275Home();
    if (!mounted) return;
    setState(() => _b275Featured = r);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return AppPageLoading(color: MusicTheme.tint);
    }
    // ── 视觉预设：决定背景与卡片材质（**颜色仍全从全局主题派生**）──
    //
    // 见 `discover_preset.dart` 的说明：预设只改"怎么画"，
    // 不改配色，所以三套预设 + 7 套全局主题 + 明暗 都能正确组合。
    final style = DiscoverStyle.of(_preset);
    return Stack(
      children: [
        // 背景层铺满，且**不吃触摸**
        Positioned.fill(
          child: DiscoverBackdrop(style: style),
        ),
        RefreshIndicator(
          color: style.accent,
          onRefresh: _loadAll,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _header(style)),
              SliverToBoxAdapter(child: _sourceTabs(style)),
              // Beans 主页顶部是**两张并排大卡**（每日推荐 / 私人漫游）。
              // 这里映射到**真实可用**的功能，不做假入口：
              //   · 每日推荐 → 直接播当天「新歌速递」
              //   · 私人漫游 → 从「我的收藏」随机漫游（没收藏就明确提示）
              SliverToBoxAdapter(child: _bigCards(style)),
              if (_error.isNotEmpty)
                SliverToBoxAdapter(child: _errorBox()),
              ..._buildSections(style),
              const SliverToBoxAdapter(child: SizedBox(height: 150)),
            ],
          ),
        ),
      ],
    );
  }

  // ============================================================
  // 顶部
  // ============================================================

  // ============================================================
  // 顶部两张并排大卡（对齐 Beans 主页排版）
  // ============================================================

  Widget _bigCards(DiscoverStyle style) {
    // ── 这两张卡依赖"新歌速递"和"收藏"──────────────────────────
    // 新歌速递（`newSongs`）在 QQ / 喜马拉雅下**不可用**
    // （QQ 侧 Node 明确返回 ok:false，需要登录态）。
    // 所以 QQ 页如果照常渲染，会得到一个**点不动的"每日推荐"假卡**
    // （用户实测截图：副标题停在兜底文案"每天更新的新歌"）✗
    //
    // 宁可**不显示**，也不要给一个按下去没反应的入口。
    if (_source == SongSource.qq) return const SizedBox.shrink();

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
          // ── 🔴 高度必须**随字号**算，不能写死 108（修黄黑溢出条纹）────
          //
          // 用户实测：这张卡（「每日推荐」/「私人漫游」）文字下面出现
          // **黄黑相间的溢出标记**。根因就是这里的固定高度：
          //   内容 = 上内边距 12 + 图标 18 + 弹性间距 + 标题(19) + 3 + 副标题(12) + 下内边距 12
          //   `Spacer` 在"内容已经超了"时会被压成 0，于是最小需求 ≈ 76 + 文字高
          //   字号 x1.5 时需求 ≈ **119.3 > 108** → `RenderFlex overflowed by 4.0 pixels
          //   on the bottom`（测试已复现，见 `music_bottom_overflow_test`）
          //
          // 现在按 `textScalerOf` 把文字那部分的增长算进去，
          // 并保留 108 作为**基准**（字号 1.0 时高度与原来完全一致，
          // 不会让布局跳变）。
          //
          // ⚠️ 与项目里其它网格一致的做法：按可用宽度/字号算尺寸，
          //    不用固定值（`library_page` / `ximalaya_category_page` 同款注释）。
          height: () {
            final ts = MediaQuery.textScalerOf(context);
            // 图标行 + 各段间距 + 上下内边距 = 76（字号 1.0 下与原来一致）
            const base = 76.0;
            // 文字部分（标题 19 + 间距 3 + 副标题 12）随字号增长
            const textBase = 19.0 + 3 + 12;
            return base + ts.scale(textBase);
          }(),
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
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 18, color: iconColor),
                    // ⚠️ 原来是 `Spacer()` —— 它只在"还有富余空间"时撑开；
                    //    内容一旦超出就被压成 0，**把溢出藏起来看不出原因**。
                    //    高度已经按字号算准（见上面 `height:`），
                    //    这里用固定间距，语义更清楚。
                    const SizedBox(height: 6),
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
  Widget _header(DiscoverStyle style) {
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
                        color: style.primary,
                        fontSize: AppTheme.fontPageTitle,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  // 副标题：不同来源给不同的引导语
                  //（原来这里三元两支**完全一样**，是死代码，一并修掉）
                  _source == SongSource.ximalaya
                      ? '有声书与播客，听点想听的'
                      : '今天想听点什么？',
                  style: TextStyle(
                      color: style.secondary, fontSize: AppTheme.fontSubhead),
                ),
              ],
            ),
          ),
          // ── 视觉预设切换（三套：青碧玻璃 / 纸感 / 午夜）──────────
          //
          // ⚠️ 放在标题右侧而不是设置页深处：它是**浏览时的即时观感**，
          // 用户想边看边切，不该为了换皮肤去翻设置。
          GestureDetector(
            onTap: () => _pickPreset(style),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: style.cardFill.withValues(alpha: style.fillAlpha),
                shape: BoxShape.circle,
                border: Border.all(
                  color: style.primary.withValues(alpha: 0.10),
                  width: 0.8,
                ),
              ),
              child: Icon(Icons.auto_awesome_outlined,
                  color: style.primary, size: 19),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _openSearchAll(),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: style.cardFill.withValues(alpha: style.fillAlpha),
                shape: BoxShape.circle,
                border: Border.all(
                  color: style.primary.withValues(alpha: 0.10),
                  width: 0.8,
                ),
              ),
              child: Icon(Icons.search_rounded, color: style.primary, size: 21),
            ),
          ),
        ],
      ),
    );
  }

  /// 平台切换胶囊（和搜索页同款）
  /// 平台切换器 —— **等宽分段胶囊**（对齐 Beans 的 providerPicker）。
  ///
  /// ── 与旧版的差别（照 Beans 规格抄的）─────────────────────────
  /// 旧版：一排不定宽的小胶囊，选中项填 `MusicTheme.tint` 纯色。
  /// Beans：**外层一个大胶囊**，里面各平台**等宽分段**，
  ///        选中段填**实心胶囊**（Beans 用平台品牌色）。
  ///
  /// ── 🔴 我**故意没用平台品牌色**（这是与 Beans 的唯一偏离）──────
  /// Beans 给网易云红 / QQ 绿 / 酷狗蓝。但那意味着
  /// **切到 QQ 时整个选择器是绿的，而页面其它地方还是主题色** ——
  /// 用户明确要求"整体外观和主题系统统一"，三个品牌色会直接破坏它
  ///（尤其全局主题换成紫色系时，红/绿/蓝三色并排会很花）。
  ///
  /// 所以这里**统一用 `style.accent`（= 全局主题主色）**，
  /// 靠**等宽分段 + 实心胶囊 + 白字**来体现"选中"，
  /// 不引入任何写死的色值。
  Widget _sourceTabs(DiscoverStyle style) {
    final tabs = const [
      _SourceTab(source: SongSource.netease, label: '网易云'),
      _SourceTab(source: SongSource.qq, label: 'QQ音乐'),
      _SourceTab(source: SongSource.kugou, label: '酷狗'),
      _SourceTab(source: SongSource.ximalaya, label: '喜马拉雅'),
      _SourceTab(source: SongSource.bookan, label: '博看'),
      _SourceTab(source: SongSource.book275, label: '275'),
    ];
    final isPaper = style.preset == DiscoverPreset.paper;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          // 玻璃系用半透明底 + 描边；paper 用实心卡片色
          color: isPaper
              ? style.cardFill
              : style.cardFill.withValues(alpha: style.fillAlpha),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: style.primary.withValues(alpha: isPaper ? 0.07 : 0.10),
            width: 0.8,
          ),
        ),
        child: Row(
          children: [
            for (final t in tabs)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _switchSource(t.source),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    decoration: BoxDecoration(
                      // 选中 = 实心主题色胶囊；未选 = 透明
                      color: _source == t.source
                          ? style.accent
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      t.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _source == t.source
                            ? Colors.white
                            : style.secondary,
                        fontSize: AppTheme.fontSubhead,
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
      ),
    );
  }

  /// 选视觉预设（底部弹窗，三选一 + 一句话说明）
  Future<void> _pickPreset(DiscoverStyle style) async {
    final picked = await showModalBottomSheet<DiscoverPreset>(
      context: context,
      backgroundColor: MusicTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('发现页外观',
                      style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    // ⚠️ 这句是**必须的**：用户会以为换预设 = 换主题。
                    // 说清"只改背景与卡片材质，配色仍跟全局主题"，
                    // 否则他会去报告"换了预设颜色没变"的假 bug。
                    '只影响发现页的背景与卡片材质；配色仍跟随全局主题（设置 → 主题与外观）。',
                    style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: AppTheme.fontCaption,
                        height: 1.45),
                  ),
                ],
              ),
            ),
            for (final p in DiscoverPreset.values)
              ListTile(
                leading: Icon(
                  switch (p) {
                    DiscoverPreset.aurora => Icons.blur_on_rounded,
                    DiscoverPreset.paper => Icons.layers_outlined,
                    DiscoverPreset.midnight => Icons.nightlight_round,
                  },
                  color: p == _preset ? style.accent : MusicTheme.secondary,
                ),
                title: Text(p.label,
                    style: TextStyle(color: MusicTheme.label)),
                subtitle: Text(
                  switch (p) {
                    DiscoverPreset.aurora => '氛围光斑 + 粒子，玻璃质感',
                    DiscoverPreset.paper => '纯色底 + 实心卡片，最省电',
                    DiscoverPreset.midnight => '深色渐变舞台',
                  },
                  style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontCaption),
                ),
                trailing: p == _preset
                    ? Icon(Icons.check_rounded, color: style.accent, size: 20)
                    : null,
                onTap: () => Navigator.pop(ctx, p),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _preset = picked);
    // 持久化（下次进发现页保持）
    await SettingsStore.instance.setDiscoverPreset(picked);
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

  List<Widget> _buildSections(DiscoverStyle style) {
    if (_source == SongSource.ximalaya) {
      return _buildXimalayaSections();
    }
    if (_source == SongSource.bookan) {
      return _buildBookanSections();
    }
    if (_source == SongSource.book275) {
      return _buildBook275Sections();
    }
    if (_source == SongSource.qq) {
      return _buildQQSections();
    }
    return _buildMusicSections(style);
  }

  /// QQ 音乐板块。
  ///
  /// ── 与网易云/酷狗的差别（决定了这里的排版）──────────────────────
  /// QQ 是**免登录只有搜索类接口**的平台（见 `music_source.js` 里
  /// `isQq` 分支的 action 白名单）。所以没有：
  ///   · 排行榜（`topLists`）        → 不造假数据
  ///   · 歌单广场（`playlistSquare`）→ 同上
  ///   · 新歌速递（`newSongs`）      → 同上
  ///   · 歌手列表（`searchArtists`）→ 用**搜索派生**的真实歌手替代
  ///
  /// 能拿到并真正有用的就三样，正好按"大→小"的视觉节奏排：
  ///   · 热门歌手 —— 圆头像行（和网易云的"歌手"行同款视觉）
  ///   · 热搜关键词 —— 前三名用主题色
  ///   · 能力说明 —— 明确告诉用户"想听什么直接搜"
  List<Widget> _buildQQSections() {
    final out = <Widget>[];

    // ── 热门歌手（圆头像行，视觉上对齐网易云的"歌手"）──────────
    if (_qqArtists.isNotEmpty) {
      out.add(const SliverToBoxAdapter(child: SectionTitle(title: '热门歌手')));
      out.add(SliverToBoxAdapter(
        child: SizedBox(
          height: 118,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _qqArtists.length,
            separatorBuilder: (_, __) => const SizedBox(width: 16),
            itemBuilder: (c, i) {
              final a = _qqArtists[i];
              return GestureDetector(
                onTap: () => showSearch<void>(
                  context: context,
                  delegate: _QuickSearchDelegate(
                      source: SongSource.qq, initialQuery: a.name),
                ),
                child: SizedBox(
                  width: 68,
                  child: Column(
                    children: [
                      // ── 真头像（用户 2026 对比参考图后要求）─────────
                      //
                      // 原来是"首字圆形块"（王/G/K/盛…），理由写在旧注释里：
                      // "QQ 搜索不返回歌手头像"。**那个理由只对了一半** ——
                      // 搜索确实不接头像，但**头像模板本身是通的**：
                      //   `y.gtimg.cn/music/photo_new/T001R150x150M000{mid}.jpg`
                      // 而歌曲里带着 `singerMid` → 从榜单歌里收集歌手
                      // 就能拿到真头像（Node 侧 `topArtistsList` 已实测可用）。
                      //
                      // 所以现在画真头像；`CoverImage` 自带占位与错误兜底，
                      // 万一某张图挂了也不会是空白圆。
                      CoverImage(
                        url: a.avatar,
                        size: 64,
                        circle: true,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: MusicTheme.label,
                            fontSize: AppTheme.fontFootnote),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ));
    }

    // ── 热搜关键词（两列，前三名用主题色）─────────────────────
    if (_hotKeywords.isNotEmpty) {
      out.add(const SliverToBoxAdapter(child: SectionTitle(title: 'QQ音乐热搜')));
      // ── 横滑卡片（用户 2026 要求：「弄成卡片式的横向滑动」）────────
      //
      // 原来是一个**2 列网格**、每格只有 48 高的一条窄行（序号 + 关键词），
      // 跟下面「排行榜」「歌单广场」的横滑大卡**不是一套观感**，
      // 整页看起来像两种设计拼起来的。
      //
      // 热搜词**没有封面**（它就是个词），所以卡片的视觉主体用
      // **大号名次数字** + 关键词 —— 参考网易云/QQ 的"热搜榜"卡，
      // 前三名用主题色，一眼看出热度排序。
      out.add(SliverToBoxAdapter(
        child: SizedBox(
          height: 116,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _hotKeywords.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (c, i) {
              final kw = _hotKeywords[i];
              final hot = i < 3;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => showSearch<void>(
                  context: context,
                  delegate: _QuickSearchDelegate(
                      source: SongSource.qq, initialQuery: kw),
                ),
                child: Container(
                  width: 132,
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  decoration: BoxDecoration(
                    // 与 `PresetCard` 一致的观感：填充 + 大圆角
                    color: MusicTheme.fill,
                    borderRadius: BorderRadius.circular(18),
                    border: hot
                        ? Border.all(
                            color: MusicTheme.tint.withValues(alpha: 0.45),
                            width: 1)
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // 大号名次（前三名主题色 + 更重）
                      Text(
                        '${i + 1}',
                        style: TextStyle(
                          color: hot ? MusicTheme.tint : MusicTheme.secondary,
                          fontSize: hot ? 30 : 24,
                          fontWeight: FontWeight.w800,
                          height: 1.0,
                        ),
                      ),
                      Text(
                        kw,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ));
    }

    // ── QQ 排行榜（**免登录可拿**，实测 30 个榜单）──────────────
    //
    // ⚠️ 点进去必须用 `isTopList: true` —— QQ 的 topId 不是歌单 id，
    //    用歌单接口查会得到空列表（实测 topListSongs 5 条 / playlistDetail 0 条）。
    //
    // ── 为什么是**横滑大卡片**而不是竖排列（用户 2026 反馈）────────
    // 原来用的是 `RankListCard`（单卡片内竖排行）。用户对比参考图后指出
    //「这种卡片式的差远了」——参考图的榜单是**横滑大封面卡**，
    // 视觉冲击力和"想点"的欲望都强得多，而竖排小行看起来像设置列表。
    //
    // 现在与"每日推荐"同一套横滑卡：封面 152 + 名称 + 副标题。
    if (_qqTopLists.isNotEmpty) {
      out.add(const SliverToBoxAdapter(child: SectionTitle(title: '排行榜')));
      out.add(SliverToBoxAdapter(
        child: HorizontalCards(
          itemCount: _qqTopLists.length,
          height: 212,
          itemWidth: 152,
          itemBuilder: (c, i) {
            final t = _qqTopLists[i];
            return CoverCard(
              coverUrl: t.coverUrl,
              title: t.name,
              subtitle: t.updateFrequency,
              width: 152,
              onTap: () => openPlaylist(
                context,
                t.id,
                t.name,
                source: SongSource.qq,
                isTopList: true,
              ),
            );
          },
        ),
      ));
    }

    // ── QQ 歌单广场（**免登录可拿**，实测 20 个歌单）────────────
    if (_qqSquare.isNotEmpty) {
      out.add(const SliverToBoxAdapter(
          child: SectionTitle(title: 'QQ歌单广场')));

      // ── 分类名横滑 ────────────────────────────────────────────
      //
      // ⚠️ 这些**不是"切换分类"按钮** —— 因为 QQ 的 categoryId 是数字，
      //    而 Dart 侧 `playlistCatlist()` 只回了**名字**，名字→数字 id
      //    的映射没暴露。硬做切换就是把 id 猜错，用户点"华语"却拿到"全部"
      //    （**假功能**，比没有更糟）。
      //
      // 所以改成**点名字 → 直接用这个名字搜 QQ**：
      //     · 语义干净（用户点"华语"就是想看华语歌）
      //     · 真的有效（搜索是免登录可用的）
      //     · 不假装自己是分类切换
      if (_qqCats.isNotEmpty) {
        out.add(SliverToBoxAdapter(
          child: SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
              itemCount: _qqCats.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (c, i) {
                final name = _qqCats[i];
                return GestureDetector(
                  onTap: () => showSearch<void>(
                    context: context,
                    delegate: _QuickSearchDelegate(
                        source: SongSource.qq, initialQuery: name),
                  ),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: MusicTheme.fill,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      name,
                      style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontCaption),
                    ),
                  ),
                );
              },
            ),
          ),
        ));
      }

      // ── 同一套横滑卡（与排行榜/每日推荐一致，用户要求卡片式）────
      out.add(SliverToBoxAdapter(
        child: HorizontalCards(
          itemCount: _qqSquare.length,
          height: 212,
          itemWidth: 152,
          itemBuilder: (c, i) {
            final p = _qqSquare[i];
            return CoverCard(
              coverUrl: p.coverUrl,
              title: p.name,
              subtitle: p.trackCount > 0 ? '${p.trackCount} 首' : null,
              width: 152,
              onTap: () =>
                  openPlaylist(context, p.id, p.name, source: SongSource.qq),
            );
          },
        ),
      ));
    }

    // ── 🔴 关键提示：**能看 ≠ 能播**（这是用户最容易误解的一点）──
    //
    // 上面的热搜/歌手/排行榜/歌单广场**全部免登录可用**，
    // 但点歌播放**必须 QQ 登录**（vkey 要登录 Cookie）——
    // 5 首实测全部拿不到地址。
    //
    // 不写清楚的话，用户看到榜单点进去点播放 → 失败 → 以为 App 坏了。
    out.add(SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 0),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: MusicTheme.fill,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 17, color: MusicTheme.tint),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('QQ 可以搜、可以看，但不能直接播',
                        style: TextStyle(
                            color: MusicTheme.label,
                            fontSize: AppTheme.fontFootnote,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                      '搜索 / 热搜 / 歌手 / 排行榜 / 歌单广场都是免登录的；\n'
                      '但 QQ 的播放地址必须登录（会员校验）。\n'
                      '想听 QQ 的歌，请把声音源导进来 —— 点歌失败时会自动'
                      '尝试你导入的源，并让你挑用哪个。',
                      style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontCaption,
                          height: 1.55),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ));

    return out;
  }

  List<Widget> _buildMusicSections(DiscoverStyle style) {
    final out = <Widget>[];

    // ── 每日推荐（Beans 规格：108 封面 + VIP 标 + 播放徽标 + 均衡器）──
    //
    // 数据源：`_newSongs`（新歌速递）。Beans 的「每日推荐」在网易云下取
    // `dailySongs`，本项目没有那个接口，所以用"新歌速递"当每日更新内容 ——
    // 语义一致（每天变、30 首），不是假入口。
    if (_newSongs.isNotEmpty) {
      out.add(SliverToBoxAdapter(
        child: SectionTitle(
          title: '每日推荐',
          action: '查看全部',
          onAction: () => _showAllNewSongs(style),
        ),
      ));
      out.add(SliverToBoxAdapter(
        // ── 🔴 必须监听 player（修"点歌后徽标不动"）────────────────
        //
        // 原来在**外层**取快照再当参数传进来：
        //   `final playing = MusicPlayerManager.instance.currentSong?.identityKey;`
        //   `isPlaying: MusicPlayerManager.instance.isPlaying.value`
        // 而 DiscoverPage `wantKeepAlive = true`、又没有任何 player 监听
        // → 点歌之后这一行的 `playingKey` / `isPlaying` 永远是**旧值** ✗
        //   · 不出现"正在播放"高亮
        //   · 暂停后仍是均衡器（配合上面 `discover_sections` 的修复才对）
        //
        // 把取值挪进 `ListenableBuilder` 的 builder 里，播放状态一变就重建
        //（`player_manager` 的切歌/播放/暂停都会 `notifyListeners()`）。
        child: ListenableBuilder(
          listenable: MusicPlayerManager.instance,
          builder: (context, _) => DailySongsRow(
            style: style,
            songs: _newSongs,
            playingKey:
                MusicPlayerManager.instance.currentSong?.identityKey,
            isPlaying: MusicPlayerManager.instance.isPlaying.value,
            onPlay: (i) =>
                MusicPlayerManager.instance.playQueue(_newSongs, index: i),
          ),
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

    // ── 排行榜（Beans 规格：**单卡片内竖排**，前 3 名主题色，收起 3/展开 10）──
    //
    // ⚠️ 原来这里是 **3 列大图网格**（注释说"对齐 Beans"），但 Beans 真实
    //    规格是**一张卡片里的竖排行**（名次 + 52 封面 + 榜名 + 更新频率）。
    //    3 列大图在榜单只有 3~5 个时很浪费，也看不出"排名"的意味。
    if (_topLists.isNotEmpty) {
      out.add(const SliverToBoxAdapter(child: SectionTitle(title: '排行榜')));
      out.add(SliverToBoxAdapter(
        child: RankListCard(
          style: style,
          items: _topLists,
          // ── 🔴 必须传 `source` + `isTopList`（修一个"点进去全空白"）──
          //
          // 原来写的是 `PlaylistDetailPage(id: t.id, title: t.name)` ——
          // **没传 `source`** → 页面默认 `SongSource.netease`。
          // 而 `_topLists` 是**按当前平台**拉的（比如用户选了酷狗）→
          // 于是拿**酷狗的榜单 id 去查网易云**：
          //   · 网易云恰好也有同数字 id 时 → 打开**另一个榜单**（张冠李戴）
          //   · 没有时 → `playlistDetail` 返回 ok:false → **整页空白**、
          //     连标题都没有（用户实测截图就是这个）✗
          //
          // `isTopList` 同理：QQ 的 topId **不是歌单 id**，
          // 走歌单接口必然空列表（`PlaylistDetailPage` 的字段注释写明了）。
          //
          // 用 `openPlaylist` 这个统一入口，而不是自己拼 `MaterialPageRoute`
          //（`charts_page.dart` 走的就是它，那边一直是对的）。
          onTap: (t) => openPlaylist(
            context,
            t.id,
            t.name,
            source: _source,
            isTopList: true,
          ),
        ),
      ));
    }

    // ── 歌单广场（Beans 规格：**固定 2 列网格**，144 封面，收起 6/展开）──
    if (_square.isNotEmpty) {
      out.add(SliverToBoxAdapter(
        child: SectionTitle(
          title: '歌单广场',
          action: '$_cat',
          onAction: _pickCat,
        ),
      ));
      out.add(SliverToBoxAdapter(
        child: PlaylistGrid(
          style: style,
          items: _square,
          onTap: (p) => openPlaylist(context, p.id, p.name, source: _source),
        ),
      ));
    }
    return out;
  }

  /// 「每日推荐 → 查看全部」弹窗（Beans 的 DailySongsSheet）
  Future<void> _showAllNewSongs(DiscoverStyle style) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: MusicTheme.card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('今日推荐',
                          style: TextStyle(
                              color: MusicTheme.label,
                              fontSize: AppTheme.fontTitle3,
                              fontWeight: FontWeight.w600)),
                    ),
                    // 只给**真的能用**的两个入口（不放假按钮）
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: style.accent,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999)),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        MusicPlayerManager.instance
                            .playQueue(_newSongs, index: 0);
                      },
                      child: const Text('播放全部'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: style.accent,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999)),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        final list = List<Song>.of(_newSongs)..shuffle();
                        MusicPlayerManager.instance.playQueue(list, index: 0);
                      },
                      child: const Text('随机'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: _newSongs.length,
                  itemBuilder: (c, i) => SongCell(
                    song: _newSongs[i],
                    index: i,
                    playbackContext: _newSongs,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
                MaterialPageRoute(settings: const RouteSettings(name: 'music:page'),
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
          // ── 🔴 不要用固定 `childAspectRatio`（修一个窄屏溢出）──────────
          //
          // 原来写的是 `childAspectRatio: 2.4` —— 格子高 = 格宽 / 2.4。
          // 而 `_CategoryTile` 的内容高是**固定**的：
          //   图标盒 36 + 上下 padding 12×2 = **60**
          // 在 **320pt 宽**的机型（iPhone SE 一代）上：
          //   格宽 = (320 − 16×2 − 10) / 2 = 139 → 格高 = 139 / 2.4 = **57.9 < 60**
          //   → 每个格子 `RenderFlex overflowed` ✗
          //
          // 这类"固定比例两头堵"本项目已经踩过两次，正确做法是**按内容算高度**
          //（范例：`ximalaya_category_page.dart` 的同一个网格、
          //  `library_page.dart` 的卡片网格）：
          //   · 窄屏：格子由内容决定，不会挤
          //   · 系统大字号：文字区跟着 `textScaler` 一起变高
          //
          // ⚠️ 这里格子是**横排**（图标 + 文字 + 箭头），所以文字只有一行、
          //    高度只随字号变化，不需要按"封面宽度"算。
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 12,
            mainAxisExtent: () {
              final ts = MediaQuery.textScalerOf(context);
              // 内容高 60（36 图标 + 12×2 padding）与文字行高中取大者，
              // 再留 4 的余量 —— 这样两种"撑高来源"都不会溢出。
              final textH = ts.scale(AppTheme.fontBody) * 1.4;
              return (36.0 + 12 * 2) > textH + 12 * 2
                  ? 36.0 + 12 * 2 + 4
                  : textH + 12 * 2 + 4;
            }(),
          ),
          delegate: SliverChildBuilderDelegate(
            (c, i) {
              final cat = _xmCategories[i];
              return _CategoryTile(
                name: cat.name,
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(settings: const RouteSettings(name: 'music:page'),
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

  /// 博看听书板块：热门推荐（各分类头部合并）+ 全部分类。
  List<Widget> _buildBookanSections() {
    final out = <Widget>[];

    // 热门推荐
    if (_bkFeatured.isNotEmpty) {
      out.add(const SliverToBoxAdapter(
          child: SectionTitle(title: '热门推荐')));
      out.add(SliverToBoxAdapter(
        child: HorizontalCards(
          itemCount: _bkFeatured.length,
          height: 212,
          itemWidth: 152,
          itemBuilder: (c, i) {
            final s = _bkFeatured[i];
            return CoverCard(
              coverUrl: s.coverUrl,
              title: s.name,
              subtitle: s.artists,
              width: 152,
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(settings: const RouteSettings(name: 'music:page'),
                  builder: (_) => BookanAlbumPage(
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

    // 全部分类（博看分类是固定配置，无需网络）
    final cats = MusicApi.bookanCategories;
    if (cats.isNotEmpty) {
      out.add(const SliverToBoxAdapter(
          child: SectionTitle(title: '全部分类')));
      out.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 12,
            mainAxisExtent: () {
              final ts = MediaQuery.textScalerOf(context);
              final textH = ts.scale(AppTheme.fontBody) * 1.4;
              return (36.0 + 12 * 2) > textH + 12 * 2
                  ? 36.0 + 12 * 2 + 4
                  : textH + 12 * 2 + 4;
            }(),
          ),
          delegate: SliverChildBuilderDelegate(
            (c, i) {
              final cat = cats[i];
              return _CategoryTile(
                name: cat.name,
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(settings: const RouteSettings(name: 'music:page'),
                    builder: (_) => BookanCategoryPage(),
                  ),
                ),
              );
            },
            childCount: cats.length,
          ),
        ),
      ));
    }

    return out;
  }

  /// 275听书板块：最近上架（首页）+ 全部分类。
  List<Widget> _buildBook275Sections() {
    final out = <Widget>[];

    // 最近上架
    if (_b275Featured.isNotEmpty) {
      out.add(const SliverToBoxAdapter(
          child: SectionTitle(title: '最近上架')));
      out.add(SliverToBoxAdapter(
        child: HorizontalCards(
          itemCount: _b275Featured.length,
          height: 212,
          itemWidth: 152,
          itemBuilder: (c, i) {
            final s = _b275Featured[i];
            return CoverCard(
              coverUrl: s.coverUrl,
              title: s.name,
              subtitle: s.artists,
              width: 152,
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(settings: const RouteSettings(name: 'music:page'),
                  builder: (_) => Book275AlbumPage(
                    bookId: s.id.toString(),
                    albumName: s.name,
                  ),
                ),
              ),
            );
          },
        ),
      ));
    }

    // 全部分类（275 分类是固定配置，无需网络）
    final cats = MusicApi.book275Categories;
    if (cats.isNotEmpty) {
      out.add(const SliverToBoxAdapter(
          child: SectionTitle(title: '全部分类')));
      out.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 12,
            mainAxisExtent: () {
              final ts = MediaQuery.textScalerOf(context);
              final textH = ts.scale(AppTheme.fontBody) * 1.4;
              return (36.0 + 12 * 2) > textH + 12 * 2
                  ? 36.0 + 12 * 2 + 4
                  : textH + 12 * 2 + 4;
            }(),
          ),
          delegate: SliverChildBuilderDelegate(
            (c, i) {
              final cat = cats[i];
              return _CategoryTile(
                name: cat.name,
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(settings: const RouteSettings(name: 'music:page'),
                    builder: (_) => Book275CategoryPage(),
                  ),
                ),
              );
            },
            childCount: cats.length,
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
                          MaterialPageRoute(settings: const RouteSettings(name: 'music:page'),
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
                  MaterialPageRoute(settings: const RouteSettings(name: 'music:page'),
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
