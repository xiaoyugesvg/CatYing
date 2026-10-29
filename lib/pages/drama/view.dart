import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/movie.dart';
import 'package:tvbox/models/movie_sort.dart';
import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/source_service.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/pages/drama/drama_banner.dart';
import 'package:tvbox/pages/drama/drama_entry.dart';
import 'package:tvbox/pages/drama/drama_history_page.dart';
import 'package:tvbox/pages/drama/drama_manage_page.dart';
import 'package:tvbox/pages/drama/drama_search_page.dart';
import 'package:tvbox/pages/drama/drama_settings.dart';
import 'package:tvbox/pages/drama/drama_source_sheet.dart';

/// 「短剧」分类页（2026-10-22）。
///
/// 底栏里的「短剧」tab（默认不启用，用户在「设置 → 主页页面」打开）。
///
/// 单源模式（用户 2026-10-24：「不要一下子刷新所有的…就是影视那种，
/// 左上角一个切换源，我一个个切换」）：
///   1. 左上角是当前源（默认跟随首页源），点头像/源名换一个，**一次只扫这一个**；
///   2. 在该源的分类里匹配关键词（默认 短剧/微短剧/竖屏/爽剧/短剧场）；
///   3. 命中的分类作为本页的 tab chips，选哪个就按普通分类接口拉列表。
/// 扫描结果按源落盘（DramaSettings.cachedGroups），**进页面**先读缓存秒出内容；
/// 但**换源**（`_pickSource`）一律重扫这个源，且缓存列表拉回空时自动重扫一次 ——
/// 用户 2026-10-27：「打开和切换不同的源不能直接刷新扫描加载吗？非要我自己手动刷新」。
/// 仍然是单源，不会每次进页面都打十几个源的分类接口。
/// 不写死任何站源、不内置内容、不绕过任何 VIP。
class DramaPage extends StatefulWidget {
  const DramaPage({super.key});

  @override
  State<DramaPage> createState() => _DramaPageState();
}

/// 当前源命中的一个短剧分类
class _DramaGroup {
  const _DramaGroup(this.source, this.sort);
  final SourceBean source;
  final SortData sort;
}

class _DramaPageState extends State<DramaPage> {
  final _scroll = ScrollController();

  List<_DramaGroup> _groups = [];
  int _groupIdx = 0;
  List<String> _keywords = DramaSettings.defaultKeywords;

  /// 当前在看的源（左上角切换）
  SourceBean? _source;

  /// 短剧源 key 集合（当前源 + 缓存里扫出过短剧分类的源）：
  /// 「继续观看」只挑这些源下的记录，避免把普通影视记录混进来
  final Set<String> _dramaSourceKeys = {};

  final List<Video> _videos = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;
  String _scanHint = '';

  /// 软提示（非致命）：刷新失败但已回落到缓存时显示一行说明，
  /// 不清空页面、不挡住已有内容（2026-10-28）。
  String _softHint = '';

  /// 加载代次：换源连点时用来丢弃旧请求的结果
  int _loadGen = 0;

  /// 已经「因为缓存列表为空而自动重扫过一次」的源 —— 防止死循环
  final Set<String> _autoRescanned = {};

  /// 这个 tab 是否在前台。
  ///
  /// 底栏是 IndexedStack，**15 个 tab 页在 App 启动时就全部 initState 了**
  /// （短剧页因此会在冷启动、网络/引擎还没就绪时抢跑一次）。等用户真正
  /// 点到「短剧」时，那次加载多半已经失败或过期，但页面不会自己再试 ——
  /// 用户 2026-10-27：「打开…不能直接刷新扫描加载吗？非要我自己手动刷新」。
  /// 这里借 IndexedStack 外层包着的 `TickerMode(enabled: i == tabIndex)`
  /// 判断前后台切换（见 pages/content_view.dart:426）。
  bool _tabActive = false;

  /// 首页源变化的监听（影视里切「本地 JS ↔ 订阅」要能传导到短剧页）。
  ///
  /// 🔴 2026-10-29 修（用户：「是本地JS和订阅切换的时候，没切换过来」）：
  ///   短剧页以前**完全不监听** `homeSourceBean` —— 在影视里换了源，
  ///   短剧页还挂着上一次解析出来的那个源（往往是已经没内容的本地 JS 源），
  ///   于是「切了源但短剧没变 / 内容不显示、扫描不成功」。
  StreamSubscription<SourceBean?>? _homeSub;

  /// 上次看到的首页源 key（Rx.stream 订阅时会先推一次当前值，用它挡掉）
  String? _lastHomeKey;

  /// 首页源在**后台**变化了 → 等切回这个 tab 再重载（不在后台白扫一遍）
  bool _pendingHomeReload = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _lastHomeKey = ApiConfig.instance.homeSourceBean.value?.key;
    _homeSub =
        ApiConfig.instance.homeSourceBean.stream.listen(_onHomeSourceChanged);
    _load();
  }

  /// 首页源换了 → 短剧页跟着换（解析结果没变就不打扰，避免白闪）。
  Future<void> _onHomeSourceChanged(SourceBean? s) async {
    final key = s?.key ?? '';
    if (key == (_lastHomeKey ?? '')) return;
    _lastHomeKey = key;
    if (!mounted) return;
    final next = await _currentSource();
    if (!mounted || next == null) return;
    if (next.key == _source?.key) return;
    if (!_tabActive) {
      // 用户现在在别的 tab：记一笔，切回短剧时再扫（省一次后台请求）
      _pendingHomeReload = true;
      return;
    }
    AppLog.instance.log(
      '[Drama] 首页源变化 → 短剧跟随切换: ${_source?.key ?? '(空)'} → ${next.key}',
    );
    // clearFirst：旧源的内容不能挂在新源名下
    await _load(clearFirst: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (active == _tabActive) return;
    _tabActive = active;
    // 在后台期间首页源换过了 → 这次切回来先把源跟上（不看有没有旧内容）
    if (active && _pendingHomeReload) {
      _pendingHomeReload = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _load(clearFirst: true);
      });
      return;
    }
    // 从别的 tab 切回来，且上次没拿到内容（或报错了）→ 自动补一次，
    // 不用用户再下拉。已有内容时不动，避免每次切 tab 都白闪一下。
    // 放到帧后再 setState：didChangeDependencies 还在 build 阶段里。
    if (active && (_videos.isEmpty || _error != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_videos.isNotEmpty && _error == null) return;
        _load();
      });
    }
  }

  @override
  void dispose() {
    _homeSub?.cancel();
    _homeSub = null;
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore || !_hasMore) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      _loadPage(_page + 1);
    }
  }

  /// 按 key 找源（订阅线路 + 本地源两套都查，缓存还原分组时要用）
  SourceBean? _findSource(String key) {
    final api = ApiConfig.instance;
    final hit = api.getSource(key);
    if (hit != null) return hit;
    for (final s in api.localVideoSources) {
      if (s.key == key) return s;
    }
    return null;
  }

  /// 全部可选源（订阅线路 + 本地源）
  List<SourceBean> _allSources() {
    final api = ApiConfig.instance;
    return <SourceBean>[
      ...api.sourceBeanList,
      if (api.localSourcesEnabled.value) ...api.localVideoSources,
    ];
  }

  /// 短剧可用的源白名单（「短剧设置 → 参与聚合的源」里勾选的）。
  ///
  /// 没勾过时返回全部（表示"不限"）—— 否则新用户第一次进短剧页
  /// 一个源都没有。过滤规则见 [DramaSettings.filterBySelection]。
  Future<List<SourceBean>> _allowedSources() async {
    return DramaSettings.filterBySelection(
      _allSources(),
      await DramaSettings.sourceKeys(),
    );
  }

  /// 当前源：设置里挑过的优先（且必须在白名单内），否则白名单第一个，
  /// 再否则跟随首页当前源。
  Future<SourceBean?> _currentSource() async {
    return DramaSettings.resolveCurrentSource(
      all: _allSources(),
      keys: await DramaSettings.sourceKeys(),
      pickedKey: await DramaSettings.pickedSourceKey(),
      homeSource: ApiConfig.instance.homeSourceBean.value,
      // 挑源时的首页 key：和现在的首页源不一致 ⇒ 那次挑的已过期，跟首页走
      pickedHomeKey: await DramaSettings.pickedHomeKey(),
    );
  }

  /// 某个源上次落盘的短剧分类（换源回来先走这里，不重扫）
  Future<List<_DramaGroup>?> _groupsFromCache(String sourceKey) async {
    final rows = await DramaSettings.cachedGroups();
    final out = <_DramaGroup>[];
    for (final r in rows) {
      if (r['source'] != sourceKey) continue;
      final source = _findSource(sourceKey);
      // 源被删/停用 → 这条缓存作废
      if (source == null) return null;
      out.add(_DramaGroup(
        source,
        SortData(
          id: r['id'] ?? '',
          name: r['name'] ?? '',
          flag: r['flag'] ?? '',
        ),
      ));
    }
    return out.isEmpty ? null : out;
  }

  /// 「继续观看」用的源集合：全部扫出过短剧分类的源 + 当前源
  Future<void> _refreshHistorySources() async {
    final rows = await DramaSettings.cachedGroups();
    if (!mounted) return;
    setState(() {
      _dramaSourceKeys
        ..clear()
        ..addAll(
          rows.map((r) => r['source'] ?? '').where((e) => e.isNotEmpty),
        );
      final s = _source;
      if (s != null) _dramaSourceKeys.add(s.key);
    });
  }

  /// [rescan] = true 才重新扫当前源的分类；否则优先用缓存。
  ///
  /// 换源现在是「点了就重扫」，用户连点几个源时会有多个请求在飞 ——
  /// 用 [_loadGen] 作代次号，回来的旧结果直接丢弃，避免后到的慢请求
  /// 把新源的内容盖掉（2026-10-27）。
  ///
  /// 2026-10-28：刷新失败**不再清空页面** —— 扫描异常 / 分类为空时一律回落到
  /// 上次缓存（分类 + 第一页列表），只多显示一行 [_softHint]。
  /// 用户原话：「短剧现在刷新，连原先明明有都没法出现了」。
  Future<void> _load({bool rescan = false, bool clearFirst = false}) async {
    final gen = ++_loadGen;
    // 已有内容时**不整屏 loading、不清空**：刷新过程中旧内容继续可见，
    // 新数据回来再替换（否则每次刷新都会白闪一下，失败还全空）。
    // 换源（clearFirst）例外 —— 旧源的内容不能挂在新源名下。
    final keepContent = !clearFirst && _groups.isNotEmpty;
    setState(() {
      _loading = !keepContent;
      _error = null;
      _softHint = '';
      _scanHint = '';
      if (!keepContent) {
        _groups = [];
        _videos.clear();
        _page = 1;
        _hasMore = true;
      }
    });
    _keywords = await DramaSettings.keywords();
    if (!mounted || gen != _loadGen) return;

    final source = await _currentSource();
    if (!mounted || gen != _loadGen) return;
    if (source == null) {
      setState(() {
        _source = null;
        _loading = false;
        _error = '还没有可用的视频源\n先到「切换源」里选一个影视源，或添加通用源';
      });
      return;
    }
    setState(() => _source = source);
    // 恢复这个源上次选中的分类下标（2026-10-28 修复）：
    // 之前每次加载都重置成 0，重进页面一定打回第一个分类 ——
    // 往往就是源改版后已经失效的那个。现在按源持久化，进来恢复。
    final savedIdx = await DramaSettings.readGroupIndex(source.key);
    if (!mounted || gen != _loadGen) return;
    await _refreshHistorySources();
    if (!mounted || gen != _loadGen) return;

    // ── 缓存优先：这个源上次扫到的短剧分类直接用 ────────────────
    //
    // 刷新（rescan）时也先铺缓存：切源 / 下拉时立刻有内容，随后再扫。
    // 扫描失败就停在这份缓存上（见 _showCacheFallback），不会变空白。
    final cached = await _groupsFromCache(source.key);
    if (!mounted || gen != _loadGen) return;
    if (cached != null) {
      setState(() {
        _groups = cached;
        _groupIdx = savedIdx.clamp(0, cached.length - 1);
        _loading = false;
      });
      if (!rescan) {
        await _loadPage(1, gen: gen);
        if (!mounted || gen != _loadGen) return;
        // 缓存里的分类可能已经失效（源改版 / 分类被删）→ 列表空着。
        // 这时自动重扫一次，别把「还没有内容」甩给用户去下拉
        // （用户 2026-10-27）。同一个源只自动重扫一次，
        // 避免「空 → 扫 → 还是空 → 再扫」的死循环。
        if (_videos.isEmpty && _error == null && _autoRescanned.add(source.key)) {
          return _load(rescan: true);
        }
        return;
      }
      // rescan：先把上次选中的分类的第一页铺上（不发请求），再继续往下扫描刷新
      await _applyCachedList(cached[_groupIdx.clamp(0, cached.length - 1)]);
      if (!mounted || gen != _loadGen) return;
    }

    // 只扫这一个源（不再并发扫所有源）
    setState(() => _scanHint = '正在扫描「${source.name}」的分类…');
    final probe = await _probeSource(source);
    if (!mounted || gen != _loadGen) return;

    // ── 扫描失败（网络 / 接口异常）：回落到缓存，绝不清空 ─────────
    if (!probe.ok) {
      await _showCacheFallback(
        source,
        gen: gen,
        hint: '「${source.name}」扫描失败（网络或接口异常），先显示上次缓存的内容',
        errorText: '「${source.name}」扫描失败\n${probe.error}',
      );
      return;
    }

    // ── 扫描成功，但没有任何分类命中短剧关键词 ───────────────────
    //
    // 2026-10-29：源**有分类**、只是没命中关键词时，退化为「显示全部分类」，
    // 避免整页空白（用户反馈「内容不显示，扫描不成功」）。真·空分类
    // （接口异常）仍走原来的错误提示。
    final emptySorts = probe.sortCount == 0;
    if (probe.groups.isEmpty && emptySorts) {
      AppLog.instance.log(
          '[Drama] 分类为空: ${source.name} type=${source.type} api=${source.api}');
      await _showCacheFallback(
        source,
        gen: gen,
        hint: '「${source.name}」返回的分类为空（接口可能异常），先显示上次缓存的内容',
        errorText: '「${source.name}」返回的分类为空\n'
            '接口可能异常，可点「重试」或左上角换个源',
      );
      return;
    }

    // 关键词命中优先；没命中但源有分类 → 用全部分类兜底
    final keywordFallback = probe.groups.isEmpty && probe.allSorts.isNotEmpty;
    final groups = keywordFallback
        ? [for (final sort in probe.allSorts) _DramaGroup(source, sort)]
        : probe.groups;
    if (keywordFallback) {
      AppLog.instance.log(
          '[Drama] 关键词未命中，退化为全部分类: ${source.name} (${probe.allSorts.length} 类)');
    }

    // 落盘：保留其他源的缓存，整组替换这个源的
    final oldRows = await DramaSettings.cachedGroups();
    if (!mounted || gen != _loadGen) return;
    final merged = <Map<String, String>>[
      for (final r in oldRows)
        if (r['source'] != source.key) r,
      for (final g in groups)
        {
          'source': g.source.key,
          'id': g.sort.id,
          'name': g.sort.name,
          'flag': g.sort.flag,
        },
    ];
    await DramaSettings.saveGroups(merged);
    if (!mounted || gen != _loadGen) return;
    setState(() {
      _groups = groups;
      _groupIdx = savedIdx.clamp(0, groups.length - 1);
      _scanHint = '';
      if (keywordFallback) {
        _softHint = '「${source.name}」没有匹配短剧关键词的分类，'
            '已显示全部分类（可在「短剧设置」里调整关键词）';
      }
    });
    await _refreshHistorySources();
    if (!mounted || gen != _loadGen) return;
    await _loadPage(1, gen: gen);
  }

  /// 把「源 · 分类」的第一页缓存直接铺到列表上（**不发网络请求**）。
  ///
  /// 刷新 / 切源时先让旧内容立刻可见，随后再扫分类、拉新列表覆盖。
  Future<bool> _applyCachedList(_DramaGroup g) async {
    final cached = await DramaSettings.cachedList(g.source.key, g.sort.id);
    if (cached == null || cached.isEmpty || !mounted) return false;
    setState(() {
      _videos
        ..clear()
        ..addAll(cached.map(Video.fromJson));
      _page = 1;
      _hasMore = false;
      _loading = false;
      _loadingMore = false;
      _error = null;
    });
    return true;
  }

  /// 扫描失败 / 无匹配时的统一兜底：有缓存就显示缓存（+ 一行软提示），
  /// 没缓存才把 [errorText] 摆到空页上。
  Future<void> _showCacheFallback(
    SourceBean source, {
    required int gen,
    required String hint,
    required String errorText,
  }) async {
    final cached = await _groupsFromCache(source.key);
    if (!mounted || gen != _loadGen) return;
    if (cached != null) {
      final idx = await DramaSettings.readGroupIndex(source.key);
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _groups = cached;
        _groupIdx = idx.clamp(0, cached.length - 1);
        _loading = false;
        _scanHint = '';
        _error = null;
        _softHint = hint;
      });
      // 已经铺过缓存（内容还在）就不再重复请求，避免二次失败盖掉提示
      if (_videos.isEmpty) await _loadPage(1, gen: gen);
      return;
    }
    setState(() {
      _loading = false;
      _scanHint = '';
      _softHint = '';
      _error = errorText;
    });
  }

  Future<
      ({
        List<_DramaGroup> groups,
        List<SortData> allSorts,
        bool ok,
        String error,
        int sortCount
      })> _probeSource(SourceBean s) async {
    try {
      // 20s：getSort 内部可能串行发 2 次请求（ac=class → ac=videolist 兜底），
      // 12s 在慢源上容易误判「扫描失败」（2026-10-29）。
      final r = await SourceService.instance
          .getSort(s)
          .timeout(const Duration(seconds: 20));
      return (
        groups: [
          for (final sort in r.$1)
            if (_keywords.any(sort.name.contains)) _DramaGroup(s, sort),
        ],
        allSorts: r.$1,
        ok: true,
        error: '',
        sortCount: r.$1.length,
      );
    } catch (e) {
      return (
        groups: const <_DramaGroup>[],
        allSorts: const <SortData>[],
        ok: false,
        error: e.toString().split('\n').first,
        sortCount: 0,
      );
    }
  }

  Future<void> _loadPage(int page, {int? gen}) async {
    if (_groups.isEmpty) return;
    final g = _groups[_groupIdx.clamp(0, _groups.length - 1)];
    if (page > 1) {
      if (_loadingMore || !_hasMore) return;
      setState(() => _loadingMore = true);
    }
    try {
      final list = await SourceService.instance.getList(
        g.source,
        g.sort,
        page: page,
      );
      if (!mounted) return;
      if (gen != null && gen != _loadGen) return;
      setState(() {
        if (page == 1) {
          _videos
            ..clear()
            ..addAll(list);
        } else {
          _videos.addAll(list);
        }
        _page = page;
        _hasMore = list.isNotEmpty;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
      // 第一页落盘：下次刷新失败时兜底（2026-10-28）
      if (page == 1 && list.isNotEmpty) {
        await DramaSettings.saveList(
          g.source.key,
          g.sort.id,
          [for (final v in list) v.toJsonLite()],
        );
      }
    } catch (e) {
      if (!mounted) return;
      if (page > 1) {
        setState(() => _loadingMore = false);
        return;
      }
      // 第一页失败：有缓存就显示缓存，**不把页面清空**（2026-10-28）
      final own = await DramaSettings.cachedList(g.source.key, g.sort.id);
      final cached = own ?? await DramaSettings.anyCachedList(g.source.key);
      final crossHint = own == null && cached != null;
      if (!mounted) return;
      if (gen != null && gen != _loadGen) return;
      if (cached != null) {
        setState(() {
          _videos
            ..clear()
            ..addAll(cached.map(Video.fromJson));
          _page = 1;
          _hasMore = false;
          _loading = false;
          _loadingMore = false;
          _error = null;
          _softHint = crossHint
              ? '「${g.sort.name}」加载失败，先显示同源其它分类的缓存'
              : '「${g.sort.name}」加载失败，先显示上次缓存的内容';
        });
        return;
      }
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = '「${g.sort.name}」加载失败：${e.toString().split('\n').first}';
      });
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<bool>(MaterialPageRoute(
      settings: const RouteSettings(name: 'drama:manage'),
      builder: (_) => const DramaManagePage(),
    ));
    if (!mounted) return;
    // 管理页可能改了关键词 —— 重扫当前源（单源，开销小）
    _load(rescan: true);
  }

  /// 左上角换源：**只列「短剧设置」里勾选的源**。
  ///
  /// 用户 2026-10-24：「源切换界面前面的必须只有我在短剧设置里面选择的」——
  /// 之前这里列的是全部源，跟设置里的白名单不一致，等于设置白设了。
  /// 没勾过（空集合）时仍列全部：否则新用户第一次进短剧页一个源都选不了。
  ///
  /// 选中后**立刻重扫这个源**（2026-10-27 改）：原来先读缓存，
  /// 缓存里的分类一失效就停在「这个短剧分类还没有内容」，用户得自己下拉。
  /// 现在换源 = 重新扫分类 + 拉第一页，重复点当前源也等于强制刷新。
  Future<void> _pickSource() async {
    if (_allSources().isEmpty) return;

    final allowed = await _allowedSources();
    if (!mounted) return;
    if (allowed.isEmpty) {
      AppToast.message('短剧设置里勾选的源都不可用，请重新选择');
      return;
    }

    final rows = await DramaSettings.cachedGroups();
    // 已经扫出过短剧分类的源（面板里标徽章 + 缓存优先排序）
    final dramaKeys =
        rows.map((r) => r['source'] ?? '').where((e) => e.isNotEmpty).toSet();
    if (!mounted) return;

    // 面板能力与影视的源切换一致：两列网格 / 搜索 / 定位 / 排序 / 长按菜单
    final picked = await DramaSourceSheet.show(
      context,
      sources: allowed,
      cachedKeys: dramaKeys,
      currentKey: _source?.key,
    );
    if (picked == null || !mounted) return;
    await DramaSettings.savePickedSourceKey(
      picked.key,
      // 记下「挑的时候首页是哪个」：之后在影视里换了首页源，这条记录就失效，
      // 短剧页跟着首页源走（见 DramaSettings.pickedHomeKey 的说明）。
      homeKey: ApiConfig.instance.homeSourceBean.value?.key ?? '',
    );
    if (!mounted) return;
    // 换源就**直接重扫**（用户 2026-10-27：「切换不同的源不能直接刷新扫描
    // 加载吗？非要我自己手动刷新」）。原来这里走 `_load()` 的缓存优先分支，
    // 缓存里的分类一旦失效就停在「这个短剧分类还没有内容」。
    // 顺手把自动重扫标记清掉：这次是用户主动换源，允许再兜底一次。
    _autoRescanned.remove(picked.key);
    // clearFirst：换源后旧源的内容不能挂在新源名下（哪怕只是扫描那几秒）
    await _load(rescan: true, clearFirst: true);
  }

  /// 顶部幻灯片：只取有封面的条目，最多 8 张
  List<Video> get _bannerVideos =>
      _videos.where((v) => v.pic.trim().isNotEmpty).take(8).toList();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppTheme.textPrimary;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        // 顶栏按小程序 / 影视的写法：大标题靠左 + 下面一行「当前源」药丸，
        // 右侧只留图标（用户 2026-10-24：参考小程序、影视、阅读的界面）。
        centerTitle: false,
        titleSpacing: 12,
        toolbarHeight: 72,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '短剧',
              style: TextStyle(
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.bold,
                height: 1.1,
                color: fg,
              ),
            ),
            const SizedBox(height: 5),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _pickSource,
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 3, 6, 3),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.live_tv_rounded,
                        size: 12,
                        color: isDark ? Colors.white70 : Colors.black54),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 170),
                      child: Text(
                        _source?.name ?? '选择源',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: isDark ? Colors.white70 : Colors.black87,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Icon(Icons.keyboard_arrow_down_rounded,
                        size: 15,
                        color: isDark ? Colors.white70 : Colors.black54),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '搜索短剧',
            icon: Icon(Icons.search_rounded, color: fg),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              settings: const RouteSettings(name: 'drama:search'),
              builder: (_) => const DramaSearchPage(),
            )),
          ),
          IconButton(
            tooltip: '观看记录',
            icon: Icon(Icons.history_rounded, color: fg),
            onPressed: _openHistory,
          ),
          IconButton(
            tooltip: '短剧设置',
            icon: Icon(Icons.tune_rounded, color: fg),
            onPressed: _openSettings,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _buildBody(isDark),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (_scanHint.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                _scanHint,
                style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: isDark ? Colors.white54 : Colors.black45,
                ),
              ),
            ],
          ],
        ),
      );
    }
    if (_error != null && _videos.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  height: 1.6,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => _load(rescan: true),
                    child: const Text('重试'),
                  ),
                  FilledButton(
                    onPressed: _pickSource,
                    child: const Text('换个源'),
                  ),
                  OutlinedButton(
                    onPressed: _openSettings,
                    child: const Text('短剧设置'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      // 下拉 = 重新扫当前源的分类（单源，开销小）；平时进页面走缓存
      onRefresh: () => _load(rescan: true),
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // 分类 chips：当前源命中的短剧分类（同影视首页的分类 tab）。
          // 命中 1 个也显示（2026-10-28 修复：之前 `length > 1` 才画，
          // 单分类时整条不显示，用户以为分类丢了）
          if (_groups.isNotEmpty)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 46,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
                  itemCount: _groups.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final on = i == _groupIdx;
                    return Center(
                      child: GestureDetector(
                        onTap: () {
                          if (i == _groupIdx) return;
                          setState(() {
                            _groupIdx = i;
                            _page = 1;
                            _hasMore = true;
                            _videos.clear();
                            _error = null;
                          });
                          // 记住这个源当前选中的分类（2026-10-28 修复）
                          DramaSettings.saveGroupIndex(
                              _groups[i].source.key, i);
                          _loadPage(1);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 13, vertical: 6),
                          decoration: BoxDecoration(
                            color: on
                                ? AppTheme.accentOnSurface.withValues(
                                    alpha: isDark ? 0.24 : 0.12)
                                : (isDark
                                    ? Colors.white.withValues(alpha: 0.07)
                                    : Colors.black.withValues(alpha: 0.045)),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            _groups[i].sort.name,
                            style: TextStyle(
                              fontSize: AppTheme.fontFootnote,
                              fontWeight:
                                  on ? FontWeight.w600 : FontWeight.w500,
                              color: on
                                  ? AppTheme.accentOnSurface
                                  : (isDark
                                      ? Colors.white70
                                      : Colors.black54),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          if (_bannerVideos.isNotEmpty)
            SliverToBoxAdapter(
              child: DramaBanner(videos: _bannerVideos, isDark: isDark),
            ),
          if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  _error!,
                  style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    color: isDark ? Colors.white54 : Colors.black45,
                  ),
                ),
              ),
            ),
          // 刷新失败但已回落到缓存：一行软提示，不挡内容（2026-10-28）
          if (_softHint.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.orange.withValues(alpha: 0.12)
                        : Colors.orange.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 14,
                          color: isDark
                              ? Colors.orange.shade200
                              : Colors.orange.shade800),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _softHint,
                          style: TextStyle(
                            fontSize: AppTheme.fontCaption,
                            height: 1.4,
                            color: isDark
                                ? Colors.orange.shade200
                                : Colors.orange.shade900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_videos.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  '这个短剧分类还没有内容',
                  style: TextStyle(
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.60,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _card(_videos[i], isDark),
                  childCount: _videos.length,
                ),
              ),
            ),
          if (_loadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(bottom: 90),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 右上角「观看记录」：单独一页列出短剧源下看过、存了进度的记录
  Future<void> _openHistory() async {
    await Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: 'drama:history'),
      builder: (_) => DramaHistoryPage(sourceKeys: _dramaSourceKeys.toSet()),
    ));
    // 回来可能删了记录/看了别的剧，刷新一下当前列表
    if (mounted) setState(() {});
  }

  Widget _card(Video v, bool isDark) {
    return GestureDetector(
      onTap: () async {
        await DramaEntry.open(v);
        // 回来刷新「继续观看」：刚看的这部进度变了
        if (mounted) setState(() {});
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: v.pic.isEmpty
                        ? _ph(isDark)
                        // 与影视卡片同一套：底层铺满压暗 + 前景完整显示，
                        // 既不拉伸也不裁掉封面内容
                        : LayoutBuilder(
                            builder: (context, box) {
                              final dpr =
                                  MediaQuery.of(context).devicePixelRatio;
                              final logicalW = box.maxWidth.isFinite
                                  ? box.maxWidth
                                  : 120.0;
                              final w =
                                  (logicalW * dpr).round().clamp(120, 600);
                              Widget layer(BoxFit fit,
                                  {bool dim = false, bool isBack = false}) {
                                return CachedNetworkImage(
                                  imageUrl: v.pic,
                                  fit: fit,
                                  width: double.infinity,
                                  memCacheWidth: w,
                                  maxWidthDiskCache: 600,
                                  fadeInDuration: Duration.zero,
                                  color: dim
                                      ? Colors.black.withValues(alpha: 0.45)
                                      : null,
                                  colorBlendMode:
                                      dim ? BlendMode.darken : null,
                                  errorBuilder: (_, __, ___) => isBack
                                      ? const SizedBox.shrink()
                                      : _ph(isDark),
                                );
                              }

                              return Stack(
                                fit: StackFit.expand,
                                children: [
                                  layer(BoxFit.cover,
                                      dim: true, isBack: true),
                                  layer(BoxFit.contain),
                                ],
                              );
                            },
                          ),
                  ),
                ),
                // 集数/更新信息压在封面左下角（和影视卡片一致，
                // 名称下面不再多一行，网格看起来更整齐）
                if (v.note.trim().isNotEmpty)
                  Positioned(
                    left: 5,
                    bottom: 5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        v.note,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            v.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppTheme.fontFootnote,
              height: 1.25,
              fontWeight: FontWeight.w500,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _ph(bool isDark) => Container(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.05),
        child: const Icon(Icons.movie_outlined, size: 26),
      );
}
