import 'package:flutter/material.dart';
import '../widgets/music_sheet.dart';

import '../models/models.dart';
import '../models/third_party_source.dart';
import '../services/library_store.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import '../theme/discover_preset.dart';
import '../widgets/music_components.dart';
import '../widgets/discover_sections.dart';
import 'playlist_detail_page.dart';
import 'plugin_market_page.dart';
import '../widgets/plugin_explore_view.dart';
import '../widgets/plugin_source_sheet.dart';
import 'ximalaya_album_page.dart';
import 'bookan_album_page.dart';
import 'ting15_album_page.dart';
import '../widgets/listen_category_content_page.dart';
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

  /// 顶部 Tab 模式：
  ///   · 'source'    —— 网易/QQ/酷狗/喜雅/博看/一五（平台页）
  ///   · 'recommend' —— 推荐（可切换已启用的插件源）
  ///   · 'soda'      —— 汽水（固定用「汽水音乐」MusicFree 插件）
  /// 插件页不是 SongSource，所以单独用字符串标记，不影响 `_source` 的持久化。
  String _tabMode = 'source';

  bool get _pluginTab => _tabMode != 'source';

  /// 当前选中的插件源 id（null = 用列表里第一个）
  String? _pluginId;

  // 音乐平台通用数据
  List<Song> _newSongs = const [];

  /// 「榜单热歌」：取第一个榜单的前 N 首（网易/酷狗都能走 `topListSongs`）
  List<Song> _chartSongs = const [];
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

  /// 热搜词 → 封面 URL（取该关键词搜索结果的**第一条**歌曲封面）。
  ///
  /// key = `'${平台}|$关键词'`。热搜本身只有关键词、没有图，
  /// 用户 2026-10-18：「QQ音乐热搜没有封面」——这里补一层背景图，
  /// 没有图时仍退回原来的渐变卡片，不会出现空白块。
  /// 只补前 6 条（每条一次搜索请求，再多不值当），并跨页面生命周期缓存。
  final Map<String, String> _hotCovers = {};
  /// 正在请求封面的 key（防止切平台/刷新时对同一个词重复发请求）
  final Set<String> _hotCoverInflight = {};

  /// QQ 排行榜（免登录可拿，实测 30 个榜单）
  List<TopList> _qqTopLists = const [];

  /// QQ 歌单广场（免登录可拿，实测 20 个歌单）
  List<Playlist> _qqSquare = const [];

  /// QQ 歌单广场分类（**带数字 categoryId**，实测 40 个）。
  ///
  /// ── 2026-10-13 修（用户：「QQ 分类的歌单分类怎么没有内容」）──────────
  /// 以前这里只有**名字**：Dart 的 `playlistCatlist()` 把 Node 已经返回的
  /// `id` 丢掉了，而 QQ 的 `playlistSquare` 收的是**数字 categoryId** ⇒
  /// 点分类只能退化成"拿名字去搜索"，点「华语」经常搜不出东西（像坏了）。
  /// 现在换成 [MusicApi.playlistCatlistQq]，id 一起拿，点分类就是**真的切分类**。
  List<({int id, String name})> _qqCats = const [];

  /// 当前选中的 QQ 歌单分类 id（10000000 = 全部，Node 侧兜底值）
  int _qqCatId = 10000000;

  /// 正在切分类（拉数据中，给个反馈免得以为点了没用）
  bool _qqCatLoading = false;

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

  /// QQ「每日推荐」的歌曲 —— **新歌榜**里取（免登录可拿）。
  ///
  /// ── 为什么不是 `newSongs`（用户 2026-10-14：「内容有点少…也加个每日推荐」）
  /// QQ 的 `newSongs`（新歌速递）**需要登录态**（Node 侧明确返回
  /// `ok:false`：「QQ 该接口需要登录态」）⇒ 原来 QQ 页干脆整块不显示。
  /// 但 QQ 的**新歌榜**（`topListSongs`）是免登录的、和排行榜/歌单广场同一批
  /// 接口 ⇒ 用它当"每日推荐"：语义一致（每天在变），且点得动。
  List<Song> _qqDaily = const [];

  // 喜马拉雅数据
  List<({String id, String name})> _xmCategories = const [];
  List<Song> _xmFeatured = const []; // 精选专辑（取若干分类的头部内容）
  String _xmFeaturedCat = '';

  // 博看听书数据（纯 Dart 直连，见 MusicApi.bookan*）
  List<Song> _bkFeatured = const []; // 热门推荐（各分类头部合并）

  // 一五听书数据（纯 Dart 直连，见 MusicApi.ting15*）
  List<Song> _t15Featured = const []; // 最近上架（首页）

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
    if (s == _source && _tabMode == 'source') return;
    await SettingsStore.instance.setMusicSource(s);
    if (!mounted) return;
    setState(() {
      _tabMode = 'source';
      _source = s;
      _loading = true;
      _error = '';
    });
    _loadAll();
  }

  /// 切到「推荐」Tab：内容是插件源，不需要走平台接口
  void _openRecommendTab() {
    if (_tabMode == 'recommend') return;
    setState(() {
      _tabMode = 'recommend';
      _loading = false;
      _error = '';
    });
  }

  /// 切到「汽水」Tab：固定用「汽水音乐」插件当内容源
  void _openSodaTab() {
    if (_tabMode == 'soda') return;
    setState(() {
      _tabMode = 'soda';
      _loading = false;
      _error = '';
    });
  }

  /// 已启用且可用的插件源（顺序 = 音源管理里的顺序）
  List<ThirdPartySource> get _enabledPlugins => ThirdPartySourceStore
      .instance.enabled
      .where((s) => s.isMusicFree)
      .toList();

  /// 是不是「汽水音乐」插件（按名字 / 文件名判断，兼容用户自装的同名源）
  static bool _isSodaPlugin(ThirdPartySource s) =>
      s.name.contains('汽水') ||
      s.id.toLowerCase().contains('qishui') ||
      s.updateUrl.toLowerCase().contains('qishui');

  /// 已启用的汽水插件（没有 = 没装 / 被停用）
  ThirdPartySource? get _sodaPlugin {
    for (final s in _enabledPlugins) {
      if (_isSodaPlugin(s)) return s;
    }
    return null;
  }

  /// 打开插件源切换弹窗（一行两列卡片 + 搜索 + 定位）
  Future<void> _pickPlugin(ThirdPartySource current) async {
    final picked = await PluginSourceSheet.show(
      context: context,
      items: _enabledPlugins,
      selectedId: current.id,
    );
    if (picked == null || !mounted) return;
    setState(() => _pluginId = picked);
  }

  /// 右上角「插件管理」→ 插件市场
  Future<void> _openPluginMarket() async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'music:page'),
      builder: (_) => const PluginMarketPage(),
    ));
    if (mounted) setState(() {});
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
      } else if (_source == SongSource.ting15) {
        await _loadTing15();
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
    // 后台补封面（不阻塞首屏）
    _ensureHotCovers(SongSource.qq);

    // ── QQ 的免登录发现页数据（排行榜 / 歌单广场 / 分类）─────────
    //
    // ⚠️ 这三样**免登录就能拿**（已实测 HTTP 200），
    //    与"播放地址"完全不同（那个必须 QQ 登录 Cookie）。
    //    文案上必须说清这个区别，否则用户会以为"既然能看到榜单，
    //    那应该也能播" → 点了播放失败 → 以为 App 坏了。
    try {
      // ⚠️ 歌单广场的 categoryId 依赖分类列表，不能和它真并行
      //    （否则要先按"全部"拉一次、再按国语拉一次，白多一次请求）。
      //    这里 topLists 与 catlist 并行，拿到分类后再拉广场。
      final topF = api.topLists(source: SongSource.qq);
      final catsF = api.playlistCatlistQq();
      final tops = await topF;
      final cats = await catsF;
      if (!mounted) return;
      _qqTopLists = tops;
      _qqCats = cats
          // 🔴 去掉「全部」（id 10000000，Node 侧兜底塞的第一个）。
          //    用户 2026-10-14：「QQ 歌单广场去掉那个"全部"分类」——
          //    它不切换任何东西（就是默认的全量列表），一个**选不中任何东西**
          //    的胶囊占着第一个位置，把真正的分类挤到后面。
          //    默认状态本来就是"全部"（`_qqCatId` 初值不变），不需要一个
          //    可点的胶囊来代表它。
          .where((c) => c.id != 10000000 && c.name != '全部')
          .take(24)
          .toList();

      // ── 默认分类：国语（用户 2026-10-18 要求）────────────────────
      // 首次进入时（仍是"全部"初值）自动选中「国语」；分类里没有国语时
      // 保持"全部"不动。用户手动切过分类后 `_qqCatId` 已不是初值，不受影响。
      if (_qqCatId == 10000000) {
        for (final c in _qqCats) {
          if (c.name == '国语') {
            _qqCatId = c.id;
            break;
          }
        }
      }

      // QQ 的 `playlistSquare(cat:)` 收的是**数字 categoryId**
      //（Node 侧 `Number(cat) || 10000000`）→ 传 id 字符串就是真·切分类。
      _qqSquare = await api.playlistSquare(
          cat: '$_qqCatId', limit: 20, source: SongSource.qq);
    } catch (e) {
      // 免登录接口失败不该阻塞整页（热搜/搜索仍可用）
      AppLog.instance.log('[Discover] QQ 发现页数据加载失败: $e');
    }

    // ── 每日推荐（用**新歌榜**的歌，免登录可拿；见 `_qqDaily` 的说明）──
    //
    // 榜单列表里找「新歌榜」；找不到就退回热歌榜(26) —— 都是 QQ 的固定 topId。
    try {
      var topId = 26;
      for (final t in _qqTopLists) {
        if (t.name.contains('新歌')) {
          topId = t.id;
          break;
        }
      }
      final daily =
          await api.topListSongs(topId, limit: 30, source: SongSource.qq);
      if (!mounted) return;
      _qqDaily = daily.ok ? daily.list : const [];
    } catch (e) {
      AppLog.instance.log('[Discover] QQ 每日推荐加载失败: $e');
    }

    // ── 热门歌手（**带真头像**）──────────────────────────────────
    //
    // Node 侧从榜单歌曲里收集去重歌手 + 拼头像 URL（见字段注释）。
    // 用热歌榜(26)当来源 —— 榜单 id 是 QQ 的固定值，不需要先拉榜单列表。
    final artists = await api.topArtists(topId: 26, limit: 14);
    if (!mounted) return;
    _qqArtists = artists;
  }

  /// 切 QQ 歌单广场的分类：**按 categoryId 重新拉**（不是拿名字去搜）。
  Future<void> _selectQqCat(int id) async {
    if (id == _qqCatId || _qqCatLoading) return;
    setState(() {
      _qqCatId = id;
      _qqCatLoading = true;
    });
    final list =
        await api.playlistSquare(cat: '$id', limit: 20, source: SongSource.qq);
    if (!mounted) return;
    setState(() {
      // 空列表也照实换掉：这分类确实没内容时，用户看到空比看到"上一个分类的
      // 内容"更不容易误会（否则会以为切换没生效）。
      _qqSquare = list;
      _qqCatLoading = false;
    });
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

    // ── 热搜关键词 ────────────────────────────────────────────────
    //
    // 网易云 / 酷狗**都支持** `hotSearch`（见 `music_source.js` 的
    // `case 'hotSearch'`），但原来只有 QQ 页渲染了它 ⇒ 酷狗页明明有这个接口
    // 却一格都不显示（用户 2026-10-14：「酷狗也是能多加点吗」）。
    //
    // 注意：必须**每个平台都重取一次** —— 否则从 QQ 切到酷狗时，
    // `_hotKeywords` 还留着 QQ 的热搜词，点下去会用酷狗去搜 QQ 的热搜 ✗
    //
    // 「榜单热歌」和热搜并行拉，避免串行多等一个来回。
    final chartFuture = _topLists.isEmpty
        ? Future<({bool ok, List<Song> list, String error})>.value(
            (ok: true, list: const <Song>[], error: ''))
        : api.topListSongs(_topLists.first.id, limit: 12, source: src);
    final hot = await api.hotSearchResult(source: src);
    _hotKeywords = hot.ok ? hot.list : const [];
    final chart = await chartFuture;
    _chartSongs = chart.ok ? chart.list : const [];
    // 后台补封面（不阻塞首屏）
    _ensureHotCovers(src);
  }

  /// 给热搜卡补封面：用该关键词**搜索第一条**歌曲的专辑封面当背景。
  ///
  /// 为什么是"搜索第一条"：热搜接口只返回关键词，本身没有图；
  /// 而一次搜索拿到第一条歌就能同时拿到封面，是成本最低的做法。
  /// 只补前 [count] 条（每条一次请求），结果按 `平台|关键词` 缓存，
  /// 重新进入页面/切分类都不会重复请求。
  Future<void> _ensureHotCovers(SongSource source, {int count = 6}) async {
    final todo = <String>[];
    for (final kw in _hotKeywords.take(count)) {
      if (kw.trim().isEmpty) continue;
      final key = '${source.key}|$kw';
      if (_hotCovers.containsKey(key) || _hotCoverInflight.contains(key)) {
        continue;
      }
      _hotCoverInflight.add(key);
      todo.add(kw);
    }
    if (todo.isEmpty) return;
    await Future.wait(todo.map((kw) async {
      final key = '${source.key}|$kw';
      try {
        final r = await api.search(kw, limit: 1, source: source);
        final cover =
            r.ok && r.list.isNotEmpty ? (r.list.first.coverUrl ?? '') : '';
        if (cover.isNotEmpty) _hotCovers[key] = cover;
      } catch (e) {
        AppLog.instance.log('[Discover] 热搜封面获取失败($kw): $e');
      } finally {
        _hotCoverInflight.remove(key);
      }
    }));
    if (mounted) setState(() {});
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

  // ── 一五听书 ──────────────────────────────────────────────────

  Future<void> _loadTing15() async {
    // 最近上架 = 首页卡片
    final r = await api.ting15Home();
    if (!mounted) return;
    setState(() => _t15Featured = r);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading && !_pluginTab) {
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
        if (_pluginTab)
          // 「推荐」Tab：头部+平台栏固定在顶部，内容是插件源自己的可滚动视图
          Column(
            children: [
              _header(style),
              _sourceTabs(style),
              Expanded(child: _pluginPane(style)),
            ],
          )
        else
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

  /// 「推荐 / 汽水」Tab 内容：左上角显示应用源名称（推荐可切换）+ 右上角插件管理
  Widget _pluginPane(DiscoverStyle style) {
    return ValueListenableBuilder<int>(
      valueListenable: ThirdPartySourceStore.instance.revision,
      builder: (context, _, __) {
        // ── 汽水：固定绑定「汽水音乐」插件 ──────────────────────
        if (_tabMode == 'soda') {
          final soda = _sodaPlugin;
          if (soda == null) {
            return _pluginEmpty(
              style,
              icon: Icons.local_drink_outlined,
              title: '还没有汽水音乐插件',
              hint: '去插件市场安装「汽水音乐」，或在音源管理里启用',
            );
          }
          return _pluginBody(style, soda);
        }

        // ── 推荐：可切换的插件源 ────────────────────────────────
        final plugins = _enabledPlugins;
        if (plugins.isEmpty) {
          return _pluginEmpty(
            style,
            icon: Icons.extension_off_rounded,
            title: '还没有启用的插件源',
            hint: '去插件市场安装，或在音源管理里启用',
          );
        }
        // 记住的 id 不存在了（被删/被停用）→ 回落到第一个
        final current = plugins.firstWhere(
          (p) => p.id == _pluginId,
          orElse: () => plugins.first,
        );
        if (current.id != _pluginId) {
          // build 内不能 setState：直接记下，下一次重建即生效
          _pluginId = current.id;
        }
        return _pluginBody(
          style,
          current,
          onSwitch: () => _pickPlugin(current),
        );
      },
    );
  }

  /// 插件 Tab 的通用骨架：源名称胶囊 + 插件管理按钮 + 插件内容
  Widget _pluginBody(
    DiscoverStyle style,
    ThirdPartySource source, {
    VoidCallback? onSwitch,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
          child: Row(
            children: [
              // 左上角：当前应用源（推荐页可点开切换弹窗）
              Flexible(
                child: GestureDetector(
                  onTap: onSwitch,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
                    decoration: BoxDecoration(
                      color:
                          style.cardFill.withValues(alpha: style.fillAlpha),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: style.primary.withValues(alpha: 0.10),
                        width: 0.8,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.extension_rounded,
                            size: 16, color: style.accent),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            source.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: style.primary,
                              fontSize: AppTheme.fontSubhead,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (onSwitch != null) ...[
                          const SizedBox(width: 2),
                          Icon(Icons.expand_more_rounded,
                              size: 18, color: style.secondary),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              const Spacer(),
              // 右上角：插件管理（→ 插件市场）
              IconButton(
                tooltip: '插件管理',
                visualDensity: VisualDensity.compact,
                onPressed: _openPluginMarket,
                icon: Icon(Icons.storefront_rounded,
                    size: 20, color: style.primary),
              ),
            ],
          ),
        ),
        Expanded(
          child: PluginExploreView(
            key: ValueKey(source.id),
            source: source,
          ),
        ),
      ],
    );
  }

  /// 插件 Tab 的空态（没装 / 没启用时给明确的下一步）
  Widget _pluginEmpty(
    DiscoverStyle style, {
    required IconData icon,
    required String title,
    required String hint,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: style.secondary),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                color: style.primary,
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: style.secondary,
                fontSize: AppTheme.fontFootnote,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: style.accent,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: _openPluginMarket,
              icon: const Icon(Icons.storefront_rounded, size: 18),
              label: const Text('插件市场'),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 顶部
  // ============================================================

  // ============================================================
  // 顶栏 / 平台切换
  // ============================================================

  // ============================================================
  // 顶部两张并排大卡（对齐 Beans 主页排版）
  // ============================================================

  Widget _bigCards(DiscoverStyle style) {
    // ── 「每日推荐」的数据源按平台取（这两张卡依赖"每日歌"和"收藏"）──
    //   · 网易云 / 酷狗 → 新歌速递（`newSongs` 免登录可用）
    //   · QQ           → **新歌榜**的歌曲（`newSongs` 在 QQ 需要登录态，
    //                     Node 侧明确 ok:false，见 `_qqDaily`）
    // 以前 QQ 是**整块不显示**（怕给一个点不动的假卡）✗ ——
    // 用户 2026-10-14：「内容有点少…也加个每日推荐、私人漫游」⇒ 现在换成
    // 用 QQ 真实拿得到的歌填，仍然是**点得动的真入口**。
    final List<Song> daily =
        _source == SongSource.qq ? _qqDaily : _newSongs;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Row(
        children: [
          Expanded(
            child: _bigCard(
              title: '每日推荐',
              subtitle: daily.isEmpty
                  ? '每天更新的新歌'
                  : '${daily.length} 首 · 每天更新',
              icon: Icons.calendar_month_rounded,
              // 用当天第一首的封面做底图（Beans 的「每日推荐」就是封面大图）
              coverUrl: daily.isEmpty ? null : daily.first.coverUrl,
              onTap: daily.isEmpty
                  ? null
                  : () =>
                      MusicPlayerManager.instance.playQueue(daily, index: 0),
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
                  _tabMode == 'soda'
                      ? '汽水音乐的榜单与推荐歌单'
                      : _pluginTab
                          ? '插件源里的榜单与歌单'
                          : _source == SongSource.ximalaya
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
      _SourceTab(source: SongSource.netease, label: '网易'),
      _SourceTab(source: SongSource.qq, label: 'QQ'),
      _SourceTab(source: SongSource.kugou, label: '酷狗'),
      _SourceTab(source: SongSource.ximalaya, label: '喜雅'),
      _SourceTab(source: SongSource.bookan, label: '博看'),
      _SourceTab(source: SongSource.ting15, label: '一五'),
    ];
    final isPaper = style.preset == DiscoverPreset.paper;
    return Padding(
      // 7 个分类（推荐 + 6 个平台）→ 左右留白收一点，保证每个胶囊都放得下
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
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
            // 「推荐」（2026-10-21）：内容是已启用插件的榜单/歌单
            _sourceChip(
              style: style,
              label: '推荐',
              selected: _tabMode == 'recommend',
              onTap: _openRecommendTab,
            ),
            for (final t in tabs) ...[
              _sourceChip(
                style: style,
                label: t.label,
                selected: _tabMode == 'source' && _source == t.source,
                onTap: () => _switchSource(t.source),
              ),
              // 「汽水」紧挨着酷狗（同为在线音乐平台，内容来自汽水插件）
              if (t.source == SongSource.kugou)
                _sourceChip(
                  style: style,
                  label: '汽水',
                  selected: _tabMode == 'soda',
                  onTap: _openSodaTab,
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sourceChip({
    required DiscoverStyle style,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            // 选中 = 实心主题色胶囊；未选 = 透明
            color: selected ? style.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            // 选中胶囊给一点柔和投影，层级更清楚（不引入新色值）
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: style.accent.withValues(alpha: 0.28),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? Colors.white : style.secondary,
              fontSize: AppTheme.fontSubhead,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  /// 选视觉预设（中间弹窗，三选一）
  Future<void> _pickPreset(DiscoverStyle style) async {
    final picked = await showMusicSheet<DiscoverPreset>(
      context: context,
      backgroundColor: MusicTheme.card,
      builder: (ctx) => SafeArea(
        // ⚠️ 弹窗高度被 showMusicSheet 限在 ~30% 屏高，内容必须能滚动，
        //   否则第三个选项被裁掉、点不到（"滑动不了"的来源）
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('外观',
                      style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w600)),
                ),
              ),
              for (final p in DiscoverPreset.values)
                ListTile(
                  dense: true,
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
                  trailing: p == _preset
                      ? Icon(Icons.check_rounded, color: style.accent, size: 20)
                      : null,
                  onTap: () => Navigator.pop(ctx, p),
                ),
              const SizedBox(height: 6),
            ],
          ),
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
    if (_source == SongSource.ting15) {
      return _buildTing15Sections();
    }
    if (_source == SongSource.qq) {
      return _buildQQSections(style);
    }
    return _buildMusicSections(style);
  }

  /// 热搜关键词横滑卡（QQ 页与网易云/酷狗页**共用一套**）。
  ///
  /// 卡片视觉主体是**大号名次**（热搜词没有封面），前三名用主题色描边 +
  /// 更大的数字，一眼看出热度；点击就用当前平台搜这个词。
  /// 提取成公共方法是因为：QQ 页早就有热搜，而**网易云/酷狗也支持
  /// `hotSearch`**（`music_source.js` 的 `case 'hotSearch'`），
  /// 但只有 QQ 页渲染了 —— 用户 2026-10-14：「酷狗也是能多加点吗」。
  List<Widget> _hotKeywordSlivers(String title, SongSource source) {
    if (_hotKeywords.isEmpty) return const [];
    return [
      SliverToBoxAdapter(child: SectionTitle(title: title)),
      SliverToBoxAdapter(
        child: SizedBox(
          height: 140,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _hotKeywords.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (c, i) {
              final kw = _hotKeywords[i];
              final hot = i < 3;
              // 补到的封面（关键词搜索第一条歌的专辑封面）；没有就用渐变底
              final cover = _hotCovers['${source.key}|$kw'];
              final onCover = cover != null && cover.isNotEmpty;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => showSearch<void>(
                  context: context,
                  delegate: _QuickSearchDelegate(
                      source: source, initialQuery: kw),
                ),
                child: Container(
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: hot
                        ? Border.all(
                            color: MusicTheme.tint.withValues(alpha: 0.50),
                            width: 1.2)
                        : Border.all(
                            color: MusicTheme.divider.withValues(alpha: 0.45),
                            width: 0.8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(17),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // ① 背景：有封面用封面，没有就渐变 + 音符装饰
                        if (onCover)
                          CoverImage(
                              url: cover, size: 132, cornerRadius: 17)
                        else
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: hot
                                    ? [
                                        MusicTheme.tint.withValues(alpha: 0.22),
                                        MusicTheme.tint.withValues(alpha: 0.06),
                                      ]
                                    : [
                                        MusicTheme.fill.withValues(alpha: 0.9),
                                        MusicTheme.fill.withValues(alpha: 0.55),
                                      ],
                              ),
                            ),
                            child: Stack(
                              children: [
                                Positioned(
                                  right: -4,
                                  bottom: -4,
                                  child: Icon(
                                    Icons.music_note_rounded,
                                    size: 44,
                                    color: (hot
                                            ? MusicTheme.tint
                                            : MusicTheme.secondary)
                                        .withValues(alpha: 0.08),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        // ② 压暗渐变：保证白字在任何封面上都可读
                        if (onCover)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black.withValues(alpha: 0.10),
                                  Colors.black.withValues(alpha: 0.05),
                                  Colors.black.withValues(alpha: 0.72),
                                ],
                                stops: const [0.0, 0.45, 1.0],
                              ),
                            ),
                          ),
                        // ③ 名次 + 关键词
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    '${i + 1}',
                                    style: TextStyle(
                                      color: onCover
                                          ? Colors.white
                                          : (hot
                                              ? MusicTheme.tint
                                              : MusicTheme.secondary),
                                      fontSize: hot ? 30 : 24,
                                      fontWeight: FontWeight.w900,
                                      height: 1.0,
                                      shadows: onCover
                                          ? const [
                                              Shadow(
                                                color: Colors.black45,
                                                blurRadius: 4,
                                                offset: Offset(0, 1),
                                              ),
                                            ]
                                          : null,
                                    ),
                                  ),
                                  if (hot) ...[
                                    const SizedBox(width: 4),
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: onCover
                                            ? Colors.white
                                            : MusicTheme.tint,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              Text(
                                kw,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: onCover
                                      ? Colors.white
                                      : MusicTheme.label,
                                  fontSize: AppTheme.fontSubhead,
                                  fontWeight: FontWeight.w500,
                                  height: 1.3,
                                  shadows: onCover
                                      ? const [
                                          Shadow(
                                            color: Colors.black54,
                                            blurRadius: 6,
                                            offset: Offset(0, 1),
                                          ),
                                        ]
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ];
  }

  /// QQ 音乐板块。
  ///
  /// ── 与网易云/酷狗的差别（决定了这里的排版）──────────────────────
  /// QQ 是**免登录只有发现类接口**的平台（见 `music_source.js` 里
  /// `isQq` 分支的 action 白名单）。免登录能拿到：排行榜、榜单歌曲、
  /// 歌单广场 + 分类、热门歌手（派生）、热搜；**拿不到**：新歌速递
  /// （`newSongs` 要登录）、推荐歌单（`code=500003`）、评论 / 相似 / 歌手专辑。
  ///
  /// 所以这里的板块是（按"大 → 小"的视觉节奏）：
  ///   · 每日推荐 —— 横滑歌卡（数据 = **新歌榜**的歌，见 [\_qqDaily]）
  ///   · 热门歌手 —— 圆头像行（和网易云的"歌手"行同款视觉）
  ///   · 热搜关键词 —— 前三名用主题色
  ///   · 排行榜 / 歌单广场 —— 横滑大卡
  ///   · 能力说明 —— 明确告诉用户"能看不能直接播"
  List<Widget> _buildQQSections(DiscoverStyle style) {
    final out = <Widget>[];

    // ── 每日推荐（横滑歌卡，与网易云页共用 `DailySongsRow`）──────────
    //
    // 数据 = QQ **新歌榜**的歌（免登录可拿，见 `_qqDaily` 的说明）。
    // 原来 QQ 页**一个"歌"的行都没有**（只有卡片/歌手/关键词）⇒
    // 用户 2026-10-14：「内容有点少…也加个每日推荐」。
    if (_qqDaily.isNotEmpty) {
      out.add(const SliverToBoxAdapter(child: SectionTitle(title: '每日推荐')));
      out.add(SliverToBoxAdapter(
        // 必须监听 player：否则点歌后"正在播放"徽标不动（同 `_buildMusicSections`）
        child: ListenableBuilder(
          listenable: MusicPlayerManager.instance,
          builder: (context, _) => DailySongsRow(
            style: style,
            songs: _qqDaily,
            playingKey: MusicPlayerManager.instance.currentSong?.identityKey,
            isPlaying: MusicPlayerManager.instance.isPlaying.value,
            onPlay: (i) =>
                MusicPlayerManager.instance.playQueue(_qqDaily, index: i),
          ),
        ),
      ));
    }

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

    // ── 热搜关键词（横滑卡片，前三名主题色）─────────────────────
    out.addAll(_hotKeywordSlivers('QQ音乐热搜', SongSource.qq));

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
                coverUrl: t.coverUrl,
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

      // ── 分类横滑：**真的切分类**（2026-10-13 修）──────────────────
      //
      // 以前这里是"点名字 → 拿名字去搜索"的退路：那时拿不到 QQ 的数字
      // categoryId（Dart 只取了名字）⇒ 点「华语」经常搜不出东西，看起来像坏了
      //（用户：「音乐模块里面 QQ 分类的歌单分类怎么没有内容」）。
      // 现在 `playlistCatlistQq()` 把 id 一起拿回来了 → 点分类就是
      // `playlistSquare(cat: id)`，下面那排歌单会**真的换成该分类**。
      if (_qqCats.isNotEmpty) {
        // ── 分类 UI（用户 2026-10-14：「这个 QQ 分类的 UI 做好看点」）──
        //   · 选中：主题色实底 + 白字 + **✓** + 一层同色柔光投影（"选中的感觉"）
        //   · 未选中：低调填充 + **细描边**（原来没描边，浅色底上几乎看不出边界）
        //   · 切换用 `AnimatedContainer`，点下去有个 160ms 的过渡，不是硬跳
        out.add(SliverToBoxAdapter(
          child: SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 3, 16, 6),
              itemCount: _qqCats.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (c, i) {
                final tag = _qqCats[i];
                final active = tag.id == _qqCatId;
                return GestureDetector(
                  onTap: _qqCatLoading ? null : () => _selectQqCat(tag.id),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOut,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 13),
                    decoration: BoxDecoration(
                      color: active ? MusicTheme.tint : MusicTheme.fill,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: active
                            ? MusicTheme.tint
                            : MusicTheme.divider,
                        width: 1,
                      ),
                      boxShadow: active
                          ? [
                              BoxShadow(
                                color: MusicTheme.tint.withValues(alpha: 0.32),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ]
                          : null,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (active) ...[
                          const Icon(Icons.check_rounded,
                              size: 13, color: Colors.white),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          tag.name,
                          style: TextStyle(
                            color:
                                active ? Colors.white : MusicTheme.secondary,
                            fontSize: AppTheme.fontCaption,
                            fontWeight:
                                active ? FontWeight.w600 : FontWeight.w400,
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
              onTap: () => openPlaylist(context, p.id, p.name,
                  source: SongSource.qq, coverUrl: p.coverUrl),
            );
          },
        ),
      ));
    }

    // 2026-10-21 用户要求：去掉页尾那段「QQ 可以搜、可以看，但不能直接播」
    // 的长说明（播不了时播放器自己会弹源选择，不需要在发现页常驻大段文字）。

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

    // ── 榜单热歌（2026-10-21 新增卡片）──────────────────────────────
    //
    // 数据 = 当前平台**第一个榜单**的前 12 首（`topListSongs`）。
    // 网易/酷狗的榜单 id 都能直接查歌（见 music_source.js 的说明），
    // 不额外引入接口，属于"真实可用"的内容卡。
    if (_chartSongs.isNotEmpty) {
      out.add(SliverToBoxAdapter(
        child: SectionTitle(
          title: '榜单热歌',
          action: '播放全部',
          onAction: () =>
              MusicPlayerManager.instance.playQueue(_chartSongs, index: 0),
        ),
      ));
      out.add(SliverToBoxAdapter(
        child: ListenableBuilder(
          listenable: MusicPlayerManager.instance,
          builder: (context, _) => DailySongsRow(
            style: style,
            songs: _chartSongs,
            playingKey: MusicPlayerManager.instance.currentSong?.identityKey,
            isPlaying: MusicPlayerManager.instance.isPlaying.value,
            onPlay: (i) =>
                MusicPlayerManager.instance.playQueue(_chartSongs, index: i),
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
              onTap: () => openPlaylist(context, p.id, p.name,
                  source: _source, coverUrl: p.coverUrl),
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
            coverUrl: t.coverUrl,
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
          onTap: (p) => openPlaylist(context, p.id, p.name,
              source: _source, coverUrl: p.coverUrl),
        ),
      ));
    }

    // ── 热搜关键词（网易云 / 酷狗 都有这个接口，见 `_loadMusicPlatform`）──
    out.addAll(_hotKeywordSlivers('${_source.displayName}热搜', _source));
    return out;
  }

  /// 「每日推荐 → 查看全部」弹窗（Beans 的 DailySongsSheet）
  Future<void> _showAllNewSongs(DiscoverStyle style) async {
    await showMusicSheet<void>(
      context: context,
      backgroundColor: MusicTheme.card,
      isScrollControlled: true,
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
                    builder: (_) => ListenCategoryContentPage(
                      title: cat.name,
                      sourceLabel: '喜雅',
                      loader: (page) => MusicApi.instance
                          .ximalayaCategory(cat.id, page: page),
                      onOpenAlbum: (ctx, song) =>
                          Navigator.of(ctx).push<void>(
                        MaterialPageRoute(
                          settings: const RouteSettings(name: 'music:page'),
                          builder: (_) => XimalayaAlbumPage(
                            albumId: '${song.id}',
                            albumName: song.name,
                          ),
                        ),
                      ),
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
                    builder: (_) => ListenCategoryContentPage(
                      title: cat.name,
                      sourceLabel: '博看',
                      loader: (page) =>
                          MusicApi.instance.bookanCategory(cat.id, page: page),
                      onOpenAlbum: (ctx, song) =>
                          Navigator.of(ctx).push<void>(
                        MaterialPageRoute(
                          settings: const RouteSettings(name: 'music:page'),
                          builder: (_) => BookanAlbumPage(
                            albumId: '${song.id}',
                            albumName: song.name,
                          ),
                        ),
                      ),
                    ),
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

  /// 一五听书板块：最近上架（首页）+ 全部分类。
  List<Widget> _buildTing15Sections() {
    final out = <Widget>[];

    // 最近上架
    if (_t15Featured.isNotEmpty) {
      out.add(const SliverToBoxAdapter(
          child: SectionTitle(title: '最近上架')));
      out.add(SliverToBoxAdapter(
        child: HorizontalCards(
          itemCount: _t15Featured.length,
          height: 212,
          itemWidth: 152,
          itemBuilder: (c, i) {
            final s = _t15Featured[i];
            return CoverCard(
              coverUrl: s.coverUrl,
              title: s.name,
              subtitle: s.artists,
              width: 152,
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(settings: const RouteSettings(name: 'music:page'),
                  builder: (_) => Ting15AlbumPage(
                    detailUrl: s.directUrl,
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
    final cats = MusicApi.ting15Categories;
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
                    builder: (_) => ListenCategoryContentPage(
                      title: cat.name,
                      sourceLabel: '一五',
                      // 一五分页：第 1 页 BASE+分类路径，第 2 页起 +indexN.html
                      loader: (page) async {
                        return MusicApi.instance.ting15Category(cat.id, page: page);
                      },
                      onOpenAlbum: (ctx, song) =>
                          Navigator.of(ctx).push<void>(
                        MaterialPageRoute(
                          settings: const RouteSettings(name: 'music:page'),
                          builder: (_) => Ting15AlbumPage(
                            detailUrl: song.directUrl,
                            albumName: song.name,
                          ),
                        ),
                      ),
                    ),
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
    final picked = await showMusicSheet<String>(
      context: context,
      backgroundColor: MusicTheme.card,
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
