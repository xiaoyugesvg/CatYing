import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tvbox/music/widgets/music_sheet.dart';

import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/models/third_party_source.dart';
import 'package:tvbox/music/services/music_api.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/services/settings_store.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/theme/discover_preset.dart';
import 'package:tvbox/music/widgets/music_components.dart';
import 'package:tvbox/music/pages/playlist_detail_page.dart';
import 'package:tvbox/music/pages/discover_playlists_page.dart';
import 'package:tvbox/music/pages/charts_page.dart';
import 'package:tvbox/music/widgets/mei_cards.dart';
import 'package:tvbox/music/widgets/mo_lv_blocks.dart';
import 'package:tvbox/music/pages/plugin_market_page.dart';
import 'package:tvbox/music/widgets/plugin_explore_view.dart';
import 'package:tvbox/music/widgets/plugin_source_sheet.dart';
import 'package:tvbox/music/pages/ximalaya_album_page.dart';
import 'package:tvbox/music/pages/bookan_album_page.dart';
import 'package:tvbox/music/pages/ting15_album_page.dart';
import 'package:tvbox/music/widgets/listen_category_content_page.dart';
import 'package:tvbox/widgets/app_page_loading.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/app_empty_view.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/app_log.dart';

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
  ///   · 'migu'      —— 咪咕（固定用「咪咕音乐」MusicFree 插件）
  ///   · 'bili'      —— B站（固定用「B站」MusicFree 插件）
  /// 插件页不是 SongSource，所以单独用字符串标记，不影响 `_source` 的持久化。
  String _tabMode = 'source';

  bool get _pluginTab => _tabMode != 'source';

  /// 当前选中的插件源 id（null = 用列表里第一个）
  String? _pluginId;

  // 音乐平台通用数据
  List<Song> _newSongs = const [];

  List<Playlist> _recommend = const [];
  List<TopList> _topLists = const [];
  List<Playlist> _square = const [];
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

  /// 切到「汽水 / 咪咕 / B站」Tab：各自固定用对应的 MusicFree 插件当内容源
  void _openPluginTab(String mode) {
    if (_tabMode == mode) return;
    setState(() {
      _tabMode = mode;
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

  /// 是不是「咪咕音乐」插件（含 Cookie 版）
  static bool _isMiguPlugin(ThirdPartySource s) =>
      s.name.contains('咪咕') ||
      s.id.toLowerCase().contains('migu') ||
      s.updateUrl.toLowerCase().contains('migu');

  /// 是不是「B站 / 哔哩哔哩」插件
  static bool _isBiliPlugin(ThirdPartySource s) =>
      s.name.contains('B站') ||
      s.name.contains('哔哩') ||
      s.id.toLowerCase().contains('bilibili') ||
      s.updateUrl.toLowerCase().contains('bilibili');

  /// 已启用的汽水插件（没有 = 没装 / 被停用）
  ThirdPartySource? get _sodaPlugin => _firstPluginWhere(_isSodaPlugin);

  /// 「咪咕」Tab 的内容源。
  ///
  /// ⚠️ 不能直接用「第一个咪咕插件」（用户 2026-10-25 截图：咪咕页一片空白，
  ///   只有"该插件没有提供榜单或推荐歌单"）：
  ///   · 「咪咕音乐（Cookie 版）」只实现了 搜索 / 歌词 / 取地址 ——
  ///     没有 `getTopLists` / `getRecommendSheetTags`；
  ///   · 内置源顺序又把 Cookie 版排在最前（播放时优先用登录态）
  ///   ⇒ 拿它当内容源时榜单/歌单必然是空的。
  ///   所以这里优先挑**脚本里真的实现了 getTopLists** 的那个（官方版）。
  ThirdPartySource? get _miguExplorePlugin {
    final list = _enabledPlugins.where(_isMiguPlugin).toList();
    if (list.isEmpty) return null;
    for (final s in list) {
      if ((s.script ?? '').contains('getTopLists')) return s;
    }
    // 全都没实现榜单 ⇒ 仍然给第一个，让页面显示明确说明而不是"没装插件"
    return list.first;
  }

  /// 已启用的 B站插件
  ThirdPartySource? get _biliPlugin => _firstPluginWhere(_isBiliPlugin);

  ThirdPartySource? _firstPluginWhere(bool Function(ThirdPartySource) test) {
    for (final s in _enabledPlugins) {
      if (test(s)) return s;
    }
    return null;
  }

  /// 打开插件源切换弹窗（中间弹窗：一行四列 + 搜索 + 定位）
  Future<void> _pickPlugin(ThirdPartySource current) async {
    final picked = await PluginSourceSheet.show(
      context: context,
      items: _enabledPlugins,
      selectedId: current.id,
    );
    if (picked == null || !mounted) return;
    setState(() => _pluginId = picked);
  }

  /// **长按「推荐」Tab** → 打开插件源选择
  ///
  /// 用户 2026-10-21：去掉推荐页顶部那个源切换胶囊，改成 Tab 长按。
  Future<void> _openRecommendSourcePicker() async {
    final plugins = _enabledPlugins;
    if (plugins.isEmpty) {
      AppToast.show('还没有启用的插件源', '去插件市场安装，或在音源管理里启用');
      return;
    }
    final current = plugins.firstWhere(
      (p) => p.id == _pluginId,
      orElse: () => plugins.first,
    );
    // 长按即切到推荐页：避免"选完了还停在原平台"的困惑
    if (_tabMode != 'recommend') {
      setState(() {
        _tabMode = 'recommend';
        _loading = false;
        _error = '';
      });
    }
    await _pickPlugin(current);
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

    // 「热门歌手」不再拉：Mei 的发现页没有这一块（2026-10-30 重构），
    // 少一次 `topArtists` 请求，首屏也快一点。
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
      futures.add(api.playlistSquare(cat: _cat, limit: 12, source: src));
      // ⚠️ 不再拉 `playlistCatlist`（2026-10-30）：那个接口只回**分组名**
      //    （语种/风格/场景/情感/主题），拿它当分类查歌单必然是空的。
      //    网易云的分类改用客户端内置表 `neteaseDiscoverCats()`。
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
    } else {
      _square = const [];
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
    final hot = await api.hotSearchResult(source: src);
    _hotKeywords = hot.ok ? hot.list : const [];
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
                // ── 2026-10-30 重构：按 Mei 的发现页只留「概览区块」──
                //
                // 去掉的四块（幻灯片轮播 / 二级分类 tab / 分类歌单网格 /
                // 两张并排大卡）：Mei 的发现页没有它们，而且它们让首屏被
                // 无关内容占满 —— 分类已经改成「探索歌单」上面那行胶囊，
                // 点进去是独立的「全部歌单」页（有排序 + 分页）。
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

  /// 「推荐 / 汽水 / 咪咕 / B站」Tab 内容：左上角显示应用源名称（推荐可切换）+ 右上角插件管理
  Widget _pluginPane(DiscoverStyle style) {
    return ValueListenableBuilder<int>(
      valueListenable: ThirdPartySourceStore.instance.revision,
      builder: (context, _, __) {
        // ── 汽水 / 咪咕 / B站：各自固定绑定一个插件 ─────────────
        if (_tabMode != 'recommend') {
          final bound = switch (_tabMode) {
            'soda' => _sodaPlugin,
            'migu' => _miguExplorePlugin,
            'bili' => _biliPlugin,
            _ => null,
          };
          if (bound == null) return _boundPluginEmpty(style, _tabMode);
          return _pluginBody(bound);
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
        return _pluginBody(current);
      },
    );
  }

  /// 插件 Tab 的内容（源切换已改为**长按「推荐」Tab**，这里不再有顶部胶囊）
  Widget _pluginBody(ThirdPartySource source) {
    return PluginExploreView(
      key: ValueKey(source.id),
      source: source,
    );
  }

  /// 汽水 / 咪咕 / B站 的空态：按 Tab 给对应的文案
  Widget _boundPluginEmpty(DiscoverStyle style, String mode) {
    final (icon, name) = switch (mode) {
      'migu' => (Icons.music_note_rounded, '咪咕音乐'),
      'bili' => (Icons.smart_display_outlined, 'B站'),
      _ => (Icons.local_drink_outlined, '汽水音乐'),
    };
    return _pluginEmpty(
      style,
      icon: icon,
      title: '还没有$name插件',
      hint: '去插件市场安装「$name」，或在音源管理里启用',
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
                      : _tabMode == 'migu'
                          ? '咪咕音乐的榜单与推荐歌单'
                          : _tabMode == 'bili'
                              ? 'B站音频：视频音乐与歌单'
                              : _tabMode == 'recommend'
                                  ? '长按「推荐」可切换插件源'
                                  : _source == SongSource.ximalaya
                                      ? '有声书与播客，听点想听的'
                                      : '今天想听点什么？',
                  style: TextStyle(
                      color: style.secondary, fontSize: AppTheme.fontSubhead),
                ),
              ],
            ),
          ),
          // ── 插件市场（2026-10-21：从推荐页右上角挪到顶栏）──────────
          //   位置：搜索按钮左边那个按钮（视觉预设）的**左边**
          _headerIcon(
            style: style,
            icon: Icons.storefront_rounded,
            tooltip: '插件市场',
            onTap: _openPluginMarket,
          ),
          const SizedBox(width: 8),
          // ── 视觉预设切换（三套：青碧玻璃 / 纸感 / 午夜）──────────
          //
          // ⚠️ 放在标题右侧而不是设置页深处：它是**浏览时的即时观感**，
          // 用户想边看边切，不该为了换皮肤去翻设置。
          _headerIcon(
            style: style,
            icon: Icons.auto_awesome_outlined,
            tooltip: '切换视觉预设',
            size: 19,
            onTap: () => _pickPreset(style),
          ),
          const SizedBox(width: 8),
          _headerIcon(
            style: style,
            icon: Icons.search_rounded,
            tooltip: '搜索',
            size: 21,
            onTap: _openSearchAll,
          ),
        ],
      ),
    );
  }

  /// 顶栏圆形图标按钮（与音乐模块的卡片/胶囊同一套视觉：淡底 + 细描边）
  Widget _headerIcon({
    required DiscoverStyle style,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    double size = 20,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: style.cardFill.withValues(alpha: style.fillAlpha),
            shape: BoxShape.circle,
            border: Border.all(
              color: style.primary.withValues(alpha: 0.10),
              width: 0.8,
            ),
          ),
          child: Icon(icon, color: style.primary, size: size),
        ),
      ),
    );
  }

  /// 平台切换器 —— **可横滑的胶囊条**（原来是等宽分段，照 Beans 的 providerPicker）。
  ///
  /// ── 配色：**不用平台品牌色**（这是与 Beans 的刻意偏离）──────────
  /// Beans 给网易云红 / QQ 绿 / 酷狗蓝，那会让"切到 QQ 时整个选择器是绿的、
  /// 而页面其它地方还是主题色"。用户要求整体外观和主题系统统一，
  /// 所以统一用 `style.accent`（全局主题主色），靠实心胶囊 + 白字表示选中。
  ///
  /// ── 布局：2026-10-25 改成可横滑 ──────────────────────────────
  /// 分类从 7 个涨到 10 个（加汽水/咪咕/B站）后，等宽分段在 375dp 上每个只剩
  /// ~34dp，字挤在一起 ⇒ 改成**固定宽度 62 + 横向滚动**，不再均分屏宽。
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
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // 胶囊条本身要吃掉多余的高度，避免带动整个头部跳动
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 「推荐」（2026-10-21）：内容是已启用插件的榜单/歌单
              //   长按 → 中间弹窗切换插件源（原来顶部那个胶囊已去掉）
              _sourceChip(
                style: style,
                label: '推荐',
                selected: _tabMode == 'recommend',
                onTap: _openRecommendTab,
                onLongPress: _openRecommendSourcePicker,
              ),
              for (final t in tabs) ...[
                _sourceChip(
                  style: style,
                  label: t.label,
                  selected: _tabMode == 'source' && _source == t.source,
                  onTap: () => _switchSource(t.source),
                ),
                // 「汽水 / 咪咕 / B站」紧挨着酷狗（同为在线音乐平台，内容来自各自插件）
                if (t.source == SongSource.kugou) ...[
                  _sourceChip(
                    style: style,
                    label: '汽水',
                    selected: _tabMode == 'soda',
                    onTap: () => _openPluginTab('soda'),
                  ),
                  _sourceChip(
                    style: style,
                    label: '咪咕',
                    selected: _tabMode == 'migu',
                    onTap: () => _openPluginTab('migu'),
                  ),
                  _sourceChip(
                    style: style,
                    label: 'B站',
                    selected: _tabMode == 'bili',
                    onTap: () => _openPluginTab('bili'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _sourceChip({
    required DiscoverStyle style,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        alignment: Alignment.center,
        // 固定宽度（不再均分屏宽）：10 个分类横向滚动，字距才不会挤
        width: 62,
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
  // ── Mei 规格发现页（2026-10-30 重构）─────────────────────────────
  //
  // 用户：「推荐、网易这些分页整个要重构，严格按照刚才这个仓库的界面来」
  //（`ljyh223/Mei` 的 `ui/screen/main/findmusic`）。
  //
  // Mei 的发现页只放**概览**，完整集合是独立页面（`DiscoverPlaylistsScreen`）。
  // 所以这里只做三件事：
  //   ① 每个区块 = `MeiSectionHeader`（标题 + 「全部 ›」）+ 一条横向滑动货架
  //   ② 分类不再做成二级 tab，而是「探索歌单」上面那行胶囊 —— 点任意一个
  //      （含"全部分类"）都**进「全部歌单」页**，排序/分页都在那边
  //   ③ 幻灯片轮播 / 二级 tab / 分类网格 / 大卡入口全部去掉 ——
  //      Mei 的发现页没有这些，它们也正是"首屏塞满、翻不到底"的原因
  //
  // ⚠️ QQ 页原来有自己的一整套（`_buildQQSections`：歌手行 + 热搜 + 榜单大卡）。
  //    现在**并入同一套**：数据用下面几个 getter 取，视觉完全一致。
  //    「热门歌手」行按 Mei 的发现页规格去掉了（Mei 没有这一块），
  //    歌手仍然可以从搜索进入。

  bool get _isQq => _source == SongSource.qq;

  /// 「探索歌单」的数据源：QQ 用自己的歌单广场，其余优先"推荐歌单"。
  List<Playlist> get _discoverPlaylists {
    if (_isQq) return _qqSquare;
    if (_recommend.isNotEmpty) return _recommend;
    return _square;
  }

  /// 当前平台的全部分类（含"全部"）。
  ///
  /// ⚠️ 网易云的分类是**客户端内置表**（见 `neteaseDiscoverCats` 的说明）：
  /// 官方 catalogue 接口只回分组名，直接拿"语种/风格"当分类查歌单必然是空的。
  List<DiscoverCat> get _discoverCats {
    if (_isQq) {
      return [for (final c in _qqCats) DiscoverCat('${c.id}', c.name)];
    }
    if (_source == SongSource.netease) return neteaseDiscoverCats();
    return const [DiscoverCat('全部', '全部')];
  }

  /// 胶囊条上露出的热门分类（Mei 取前 8 个）。
  List<DiscoverCat> get _discoverHotCats {
    final all = _discoverCats;
    if (all.length <= 1) return const [];
    if (_source == SongSource.netease) {
      final out = <DiscoverCat>[];
      for (final key in neteaseHotCats) {
        for (final c in all) {
          if (c.key == key) out.add(c);
        }
      }
      return out.take(8).toList();
    }
    return all.where((c) => c.key != '全部').take(8).toList();
  }

  List<TopList> get _discoverTopLists => _isQq ? _qqTopLists : _topLists;

  List<Song> get _discoverNewSongs => _isQq ? _qqDaily : _newSongs;

  /// 进「全部歌单」页（[cat] 不传 = 全部）
  void _openAllPlaylists([DiscoverCat? cat]) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DiscoverPlaylistsPage(
        source: _source,
        initialCat: cat?.key ?? '全部',
        cats: _discoverCats,
      ),
    ));
  }

  /// 「全部分类」胶囊：先选分类，再进集合页（对应 Mei 的 `DiscoverCategorySheet`）
  Future<void> _pickCatThenOpen() async {
    final cats = _discoverCats;
    if (cats.length <= 1) {
      _openAllPlaylists();
      return;
    }
    final picked = await showDiscoverCatSheet(context, cats: cats, current: '全部');
    if (picked != null) _openAllPlaylists(picked);
  }

  /// 横向滑动货架（Mei 的 `LazyRow`：页边距 16 + 间距 12）
  ///
  /// 高度固定 214 = 152 封面 + 8 间距 + 两行标题(~40) + 副标题(~16)。
  /// 用固定高度而不是 `IntrinsicHeight`：后者在长列表里要跑一遍完整布局，
  /// 首屏会有肉眼可见的掉帧。
  Widget _meiShelf({required int count, required Widget Function(int) item}) {
    return SizedBox(
      height: 214,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: count,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (c, i) => item(i),
      ),
    );
  }

  List<Widget> _buildSections(DiscoverStyle style) {
    // 三个"听书"源内容形态完全不同（专辑 / 章节 / 分类），保留各自的分区。
    if (_source == SongSource.ximalaya) return _buildXimalayaSections();
    if (_source == SongSource.bookan) return _buildBookanSections();
    if (_source == SongSource.ting15) return _buildTing15Sections();
    // ⚠️ QQ **不再单开一套**（2026-10-30）：原来 `_buildQQSections` 有自己的
    //    歌手行 / 热搜 / 榜单大卡，和网易云页长得完全不一样。用户要求
    //    "严格按照 Mei" ⇒ 所有音乐平台共用同一套 Mei 版式，
    //    平台差异只体现在数据 getter（`_discoverPlaylists` 等）里。
    return _buildMusicSections(style);
  }

  List<Widget> _buildMusicSections(DiscoverStyle style) {
    final out = <Widget>[];

    // ── ⓪ 「墨律」首屏三件套（2026-10-31）─────────────────────────
    //
    // 设计稿 `outputs/music_ui/01_首页.png`：
    //   hero 大卡 → 今日推荐 3 方卡 → 榜单热歌 01/02/03 编号列表
    //
    // ⚠️ 所有平台共用（QQ / 网易 / 酷狗 / 汽水 / 咪咕 / B站 / 第三方插件）：
    //    组件只吃 `List<Song>`，平台差异全在 `_discoverNewSongs` 这类 getter 里，
    //    所以换源、换平台时版式不会跳。
    final homeSongs = _discoverNewSongs;
    if (homeSongs.isNotEmpty) {
      final first = homeSongs.first;
      out.add(SliverToBoxAdapter(
        child: MoLvHeroCard(
          badge: _isQq ? '每日推荐' : '今日推荐',
          title: first.name,
          subtitle: '${first.artists} · 共 ${homeSongs.length} 首 · 每天更新',
          accent: style.accent,
          coverUrl: first.coverUrl,
          onPlay: () =>
              MusicPlayerManager.instance.playQueue(homeSongs, index: 0),
        ),
      ));

      if (homeSongs.length > 1) {
        out.add(const SliverToBoxAdapter(
          child: MoLvSectionTitle(title: '今日推荐', trailing: '为你挑的'),
        ));
        out.add(SliverToBoxAdapter(
          child: MoLvRecGrid(
            songs: homeSongs.skip(1).toList(),
            accent: style.accent,
            onTap: (i) =>
                MusicPlayerManager.instance.playQueue(homeSongs, index: i + 1),
          ),
        ));
      }

      if (homeSongs.length > 4) {
        out.add(SliverToBoxAdapter(
          child: MoLvSectionTitle(
            title: '榜单热歌',
            trailing: _isQq ? '新歌榜' : '每日更新',
            onMore: () => _showAllNewSongs(style, songs: homeSongs),
          ),
        ));
        // 必须监听 player：否则点歌后"正在播放"那条高亮不动
        out.add(SliverToBoxAdapter(
          child: ListenableBuilder(
            listenable: MusicPlayerManager.instance,
            builder: (context, _) => MoLvChartList(
              songs: homeSongs.skip(4).toList(),
              accent: style.accent,
              playingKey: MusicPlayerManager.instance.currentSong?.identityKey,
              isPlaying: MusicPlayerManager.instance.isPlaying.value,
              onTap: (i) => MusicPlayerManager.instance.playQueue(homeSongs,
                  index: i + 4),
            ),
          ),
        ));
      }
    }

    // ── ① 探索歌单：分类胶囊 + 歌单货架 ────────────────────────────
    final playlists = _discoverPlaylists;
    if (playlists.isNotEmpty || _discoverCats.length > 1) {
      out.add(SliverToBoxAdapter(
        child: MeiSectionHeader(
          title: '探索歌单',
          onShowAll: () => _openAllPlaylists(),
        ),
      ));
      // 胶囊是**导航入口**（不是页内筛选）—— 点哪个都进集合页，与 Mei 一致
      final hot = _discoverHotCats;
      out.add(SliverToBoxAdapter(
        child: SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: 12),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: MeiFilterPill(
                  label: '全部分类',
                  selected: false,
                  onTap: _pickCatThenOpen,
                ),
              ),
              for (final c in hot)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: MeiFilterPill(
                    label: c.label,
                    selected: false,
                    onTap: () => _openAllPlaylists(c),
                  ),
                ),
            ],
          ),
        ),
      ));
      if (playlists.isNotEmpty) {
        final shown = playlists.take(12).toList();
        out.add(SliverToBoxAdapter(
          child: _meiShelf(
            count: shown.length,
            item: (i) {
              final p = shown[i];
              return MeiPlaylistCard(
                playlist: p,
                width: 152,
                onTap: () => openPlaylist(
                  context,
                  p.id,
                  p.name,
                  source: _source,
                  coverUrl: p.coverUrl,
                ),
              );
            },
          ),
        ));
      }
    }

    // ── ② 排行榜 ──────────────────────────────────────────────────
    final tops = _discoverTopLists;
    if (tops.isNotEmpty) {
      out.add(SliverToBoxAdapter(
        child: MeiSectionHeader(
          title: '排行榜',
          onShowAll: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ChartsPage()),
          ),
        ),
      ));
      final shown = tops.take(12).toList();
      out.add(SliverToBoxAdapter(
        child: _meiShelf(
          count: shown.length,
          item: (i) {
            final t = shown[i];
            return MeiArtworkCard(
              coverUrl: t.coverUrl,
              title: t.name,
              subtitle: t.updateFrequency,
              width: 152,
              onTap: () => openPlaylist(
                context,
                t.id,
                t.name,
                source: _source,
                // ⚠️ 必须 isTopList：QQ 的 topId 不是歌单 id，
                //    用歌单接口查会得到空列表（见旧注释里的实测结论）
                isTopList: true,
                coverUrl: t.coverUrl,
              ),
            );
          },
        ),
      ));
    }

    // ── ③ 新歌速递 / 每日推荐 ──────────────────────────────────────
    // 2026-10-31：**已上移到 ⓪**，改成「墨律」三件套（hero + 3 方卡 + 编号列表）。
    // 原来这里是「区块标题 + 横滑歌卡货架」，同一批歌在首屏要横滑才看得完；
    // 现在 hero 直接给一首主推、方卡给 3 首、列表给 5 首，一屏内交代清楚。
    // `_showAllNewSongs` 仍然保留（hero/列表的「全部 ›」都指向它）。

    // ── ④ 热搜关键词（真实接口，本来就是横滑卡片行）─────────────────
    out.addAll(_hotKeywordSlivers('${_source.displayName}热搜', _source));
    return out;
  }

  /// 「每日推荐 → 查看全部」弹窗（Beans 的 DailySongsSheet）
  /// 「新歌速递 / 每日推荐」的查看全部弹窗。
  ///
  /// [songs] 必须由调用方传入：QQ 页的"每日推荐"是 `_qqDaily`（新歌榜），
  /// 网易云才是 `_newSongs`。原来这里写死读 `_newSongs` ⇒ QQ 点「查看全部」
  /// 会弹出一份**空列表**（QQ 的 newSongs 需要登录态，恒为空）。
  Future<void> _showAllNewSongs(DiscoverStyle style,
      {List<Song>? songs}) async {
    final list0 = songs ?? _newSongs;
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
                            .playQueue(list0, index: 0);
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
                        final list = List<Song>.of(list0)..shuffle();
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
                  itemCount: list0.length,
                  itemBuilder: (c, i) => SongCell(
                    song: list0[i],
                    index: i,
                    playbackContext: list0,
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
