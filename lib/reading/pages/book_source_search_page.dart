import 'package:cached_network_image_ce/cached_network_image.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../widgets/card_action_sheet.dart';
import '../models/book_source.dart';
import '../services/book_source_service.dart';
import '../services/qread_api.dart';
import '../services/reading_layout.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_icon_deck.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/jelly_filter_sheet.dart';
import '../widgets/jelly_pull_cord.dart';
import '../widgets/jelly_expandable_search.dart';
import '../widgets/source_order_sheet.dart';
import '../widgets/source_group_tabs.dart';
import '../widgets/jelly_search_bar.dart';
import 'book_download_records_page.dart';
import 'book_source_detail_page.dart';
import 'book_source_editor_page.dart';
import 'book_source_login_page.dart';
import 'book_source_repo_page.dart';
import 'browse_history_page.dart';
import 'favorites_page.dart';
import 'webview_page.dart';
import '../../common/theme.dart';
import '../utils/source_fail_text.dart';
import '../utils/text_match.dart';
// ✅ **外壳内嵌子页**（本轮重构 ✓）：本页由 `home_page.dart` 的外壳渲染 ✓
//   ⇒ 底部胶囊导航栏（"悬浮菜单栏"）**照常显示** ✓✓；返回用 `closeEmbeddedPage()` ✓
import 'shell_embedded_page.dart';

/// 书源搜索页 —— 用已导入的 Legado 书源跨站搜小说。
///
/// ── 对应 cmbok V2.0.7 ─────────────────────────────────────────
/// 截图里「搜索书源图书」那个入口 + 书源页右上角图标组。
/// 源码不可得（2.0.7 后闭源），这里依据截图与更新说明复刻：
///   · 多源并发搜索，**边搜边显示**（不等全部源跑完）
///   · 结果按书聚合去重，同一本书只出现一次（可点开看分别来自哪些源）
///   · 顶部显示搜索进度（已 N/M 个源）
class BookSourceSearchPage extends StatefulWidget {
  const BookSourceSearchPage({
    super.key,
    this.initialKeyword = '',
    this.initialSourceId,
  });

  final String initialKeyword;

  /// 指定只搜某一个书源（图书页拉绳「卷帘切源」传入；为空则搜全部启用源）
  final String? initialSourceId;

  @override
  State<BookSourceSearchPage> createState() => _BookSourceSearchPageState();
}

class _BookSourceSearchPageState extends State<BookSourceSearchPage> {
  final _ctrl = TextEditingController();
  final store = BookSourceStore.instance;

  /// 书源仓名下的源：书源 + 从书源仓导入的漫画源（漫画源用图片模式阅读）。
  /// 漫源仓库里的源不会出现在书源搜索 / 快速源列表 / 换源里
  ///（用户 2026-10-18：「我从哪个仓订阅就用哪个」）。
  List<BookSource> get _enabledBooks =>
      store.enabled.where((s) => s.belongsToBook).toList();

  /// 「搜索源」筛选框（快速书源列表弹窗用）
  final TextEditingController _sourceFilter = TextEditingController();

  /// 源标签行选中的单源 id（空 = 聚搜全部源；点击源标签切换）
  String _selectedSourceId = '';

  /// 上次在本页选中的书源 id（持久化）——下次进页面直接用它，
  /// 而不是每次都退回第一个源（对齐漫画页持久化 `SourceManager().current`）。
  static const _kLastSourceKey = 'book_source_last_id';

  /// 复搜模式：结果列表顶部下拉进入，源 chips 多选过滤
  bool _focusMode = false;
  final Set<String> _selectedSourceIds = {};

  /// 分类浏览（选中单源后，参考图「必读榜」网格 + 分类弹窗）
  List<ExploreCategory> _cats = [];
  ExploreCategory? _activeCat;
  List<BookSourceResult> _exploreList = [];
  bool _exploreLoading = false;
  String? _exploreError;

  /// 最近一次发起分类浏览的源 —— explore 出错时错误卡据此提供
  /// 「打开书源网站」降级（legado 语义：无分类的源点击 → 打开主站，
  /// 见 dickwin2003/legado《书源显示问题修复总结》openBookSource）
  BookSource? _lastExploreSource;

  /// 板块流模式（参考图 IMG_8581/8582）：exploreUrl 全部分类逐板块展示
  bool _exploreHomeMode = true;
  final Map<String, List<BookSourceResult>> _catBooksCache = {};
  final Map<String, bool> _catLoading = {};
  final Map<String, String?> _catError = {};
  int _exploreVisibleSections = 2; // 懒加载：初始渲染前 2 个板块

  bool _searching = false;
  String _keyword = '';

  /// 已聚合的结果（按**归一化书名**分组，每组内保留各源条目）
  final Map<String, List<BookSourceResult>> _grouped = {};
  final List<SourceSearchState> _states = [];
  int _doneCount = 0;
  int _totalCount = 0;

  /// 搜索会话号：用户改了关键词后，旧会话的回调必须被忽略
  int _session = 0;

  @override
  void initState() {
    super.initState();
    // 视图切换（宫格/列表 + 3/4/5 列）变化 → 整页重建
    // （结果体在 build 里读 SourceViewMode/ReadingLayout，只重建按钮不够）
    SourceViewMode().addListener(_onViewChanged);
    ReadingLayout().addListener(_onViewChanged);
    _ctrl.text = widget.initialKeyword;
    if (widget.initialKeyword.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    } else if (widget.initialSourceId != null) {
      // 从图书页拉绳指定单源进入：直接选中该源并加载分类浏览
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() => _selectedSourceId = widget.initialSourceId!);
        _loadExploreIfNeeded();
      });
    } else {
      // ✅ **进页面就自动选中一个源并展示它的分类内容**（用户 2026-10-07：
      //   "刚进书源页没选源、没输关键词，都没显示"）
      //   根因 ✗：`_selectedSourceId` 初值是空串 ✓，而 `_body()` 里
      //     `if (_selectedSourceId.isNotEmpty) return _exploreBody();`（:1004 ✓）
      //     ⇒ 空串直接落到最后一行「输入关键词，在 N 个书源里一起搜」空态 ✗
      //     ⇒ 分类浏览**必须有选中源才会加载** ✗，所以刚进来永远是空的 ✓
      //   修法 ✓：与漫画页一致 —— 漫画页 `initState` 里对当前源做了
      //     `_autoLoadCategoryContent()`（用户原话："漫画不是进去就显示，
      //     要他么的点击"✗ 已修 ✓），这里同样进来就选源 + 拉分类 ✓
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_autoSelectInitialSource());
      });
    }
  }

  /// 进页面默认要展示的源（随后立刻加载它的分类浏览）：
  ///   1) 上次在本页选过的源（仍启用着）→ 继续用它；
  ///   2) 否则取「排序后第一个启用的源」——内置的 5 个修复版书源
  ///      （assets/config/book_sources.json）带负 customOrder，会排在最前，
  ///      所以默认命中的是实测能出分类/目录/正文的那个源 ✓。
  Future<void> _autoSelectInitialSource() async {
    // ✅ 自动选中只考虑开启「发现」的源（与源 chips 同一过滤）：
    //   上次选过的源若后来关了发现，也跳过——否则进来就是"没有配置分类浏览"。
    final enabled = store
        .sorted()
        .where((s) => s.enabled && s.enabledExplore && s.belongsToBook)
        .toList();
    if (enabled.isEmpty) return;
    String? last;
    try {
      final prefs = await SharedPreferences.getInstance();
      last = prefs.getString(_kLastSourceKey);
    } catch (_) {
      // 读失败就用默认源，不阻塞进入页面
    }
    BookSource? pick;
    if (last != null && last.isNotEmpty) {
      for (final s in enabled) {
        if (s.id == last) {
          pick = s;
          break;
        }
      }
    }
    pick ??= enabled.first;
    if (!mounted) return;
    setState(() => _selectedSourceId = pick!.id);
    await _loadExploreIfNeeded();
  }

  /// 记住本页选中的书源（只在选中**具体源**时记；"聚搜"空串不记，
  /// 免得下次进来恢复成聚搜又变成没有内容可显示）。
  Future<void> _rememberSource(String id) async {
    if (id.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastSourceKey, id);
    } catch (_) {
      // 持久化失败不影响本次使用
    }
  }

  void _onViewChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    SourceViewMode().removeListener(_onViewChanged);
    ReadingLayout().removeListener(_onViewChanged);
    _ctrl.dispose();
    _sourceFilter.dispose();
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _titleColor => _isDark ? Colors.white : JellyTheme.textPrimaryLight;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// 壳模式：已连接 qread 服务端时，搜索/探索由服务端执行规则。
  bool get _serverMode => QreadServerConfig.instance.isLoggedIn;

  /// 服务端结果（QreadSearchResult）→ 本地结果（BookSourceResult）
  BookSourceResult _fromQread(QreadSearchResult r, BookSource src) =>
      BookSourceResult(
        source: src,
        name: r.name,
        author: r.author,
        bookUrl: r.bookUrl,
        coverUrl: r.coverUrl,
        intro: r.intro,
        kind: r.kind,
        lastChapter: r.latestChapterTitle,
        wordCount: r.wordCount,
      );

  /// 服务端聚合搜索：分批并发调 qread，边搜边显示（与本地引擎同款 UI）。
  Future<void> _runViaServer(
    List<BookSource> enabled,
    String kw,
    int mySession,
  ) async {
    const batch = 4;
    var idx = 0;
    while (idx < enabled.length) {
      final chunk = enabled.skip(idx).take(batch).toList();
      await Future.wait(chunk.map((s) => _searchOneServer(s, kw, mySession)));
      idx += batch;
      if (!mounted || _session != mySession) return;
    }
    if (!mounted || _session != mySession) return;
    setState(() => _searching = false);
  }

  Future<void> _searchOneServer(BookSource s, String kw, int mySession) async {
    final st = SourceSearchState(source: s);
    final sw = Stopwatch()..start();
    try {
      final list = await QreadApi.instance.searchBook(s.url, kw);
      final results = list.map((r) => _fromQread(r, s)).toList();
      st
        ..done = true
        ..ok = results.isNotEmpty
        ..count = results.length
        ..elapsed = sw.elapsed;
      if (!mounted || _session != mySession) return;
      setState(() {
        _perSource[s.id] = results;
        _states.add(st);
        _doneCount++;
        rebuildGroups();
      });
    } on QreadException catch (e) {
      if (!mounted || _session != mySession) return;
      setState(() {
        st
          ..done = true
          ..ok = false
          ..error = e.message
          ..elapsed = sw.elapsed;
        _perSource[s.id] = const [];
        _states.add(st);
        _doneCount++;
        rebuildGroups();
      });
    } catch (e) {
      if (!mounted || _session != mySession) return;
      setState(() {
        st
          ..done = true
          ..ok = false
          ..error = '$e'
          ..elapsed = sw.elapsed;
        _perSource[s.id] = const [];
        _states.add(st);
        _doneCount++;
        rebuildGroups();
      });
    }
  }

  Future<void> _run([String? kwArg]) async {
    // 兼容两处调用：胶囊提交时传 value（提交后输入框会被清空收起），
    // 初筛自动搜索时无参（从 _ctrl.text 读）
    final kw = (kwArg ?? _ctrl.text).trim();
    if (kw.isEmpty) {
      _toast('请输入书名或作者');
      return;
    }
    final allEnabled = _enabledBooks;
    // 优先级：构造指定源 → 源标签行选中源 → 跨全部源聚搜
    final enabled = widget.initialSourceId != null
        ? allEnabled.where((s) => s.id == widget.initialSourceId).toList()
        : (_selectedSourceId.isEmpty
              ? allEnabled
              : allEnabled.where((s) => s.id == _selectedSourceId).toList());
    if (enabled.isEmpty) {
      _toast('未找到指定书源，请先在书源仓库确认源已启用');
      setState(() => _searching = false);
      return;
    }
    if (enabled.isEmpty) {
      _toast('还没有启用的书源，先去导入');
      return;
    }

    FocusScope.of(context).unfocus();
    final mySession = ++_session;
    setState(() {
      _searching = true;
      _keyword = kw;
      _grouped.clear();
      _states.clear();
      // 🔴 原来这里**漏了 `_perSource`** ✗ —— 它是"按源分组的结果" ✓，
      // 上一轮搜索留下的内容**一直没被清** ✓ → 新搜索开始后（甚至新搜索还没回来时）
      // 列表里会混进**上一次关键词**的书 ✓（"搜索结果串了 / 多了不相干的书" ✓）。
      // 这里与其它状态一起复位 ✓
      _perSource.clear();
      _doneCount = 0;
      _totalCount = enabled.length;
      // 新搜索复位复搜模式
      _focusMode = false;
      _selectedSourceIds.clear();
    });

    // 壳模式：服务端执行书源规则（解决本地引擎 @js: 垫片不全 / 接口 500）
    if (_serverMode) {
      await _runViaServer(enabled, kw, mySession);
      return;
    }

    await BookSourceService.instance.searchAll(
      enabled,
      kw,
      shouldStop: () => !mounted || _session != mySession,
      onSourceResults: (st, list) {
        if (!mounted || _session != mySession) return;
        setState(() {
          _perSource[st.source.id] = list;
          _states.add(st);
          _doneCount++;
          rebuildGroups();
        });
      },
    );

    if (!mounted || _session != mySession) return;
    setState(() => _searching = false);
  }

  /// 把 Node 引擎透传的原始异常文本转成简短中文提示（用户可读）。
  String _friendlyError(String raw) {
    if (raw.contains('没有配置 exploreUrl') || raw.contains('未配置 exploreUrl')) {
      return '该源未配置分类浏览（无 exploreUrl）：可直接用上方搜索找书；如需首页板块，可在源编辑里补充 exploreUrl';
    }
    if (raw.contains('status code of 500')) {
      return '该源分类接口返回服务器错误（HTTP 500）：接口可能失效或被源站拒绝，请换一个书源或更新书源配置';
    }
    if (raw.contains('status code of 404')) {
      return '该源分类接口不存在（HTTP 404）：书源 exploreUrl 已失效，请更新书源';
    }
    if (raw.contains('status code of 403')) {
      return '该源拒绝了访问（HTTP 403）：可能需要登录或请求头，请换源';
    }
    if (raw.contains('Connection timed out') ||
        raw.contains('timed out') ||
        raw.contains('SocketException')) {
      return '连接超时：源站响应太慢，请重试或换源';
    }
    final m = RegExp(r'status code of (\d+)').firstMatch(raw);
    if (m != null) {
      return '该源分类接口返回 HTTP ${m.group(1)} 错误：接口失效或源站拒绝，请换源或更新书源';
    }
    // ✅ 兜底交给**统一文案表** ✓（"同一原因同一类" ✓）——
    //   本页前几条已覆盖 500 / 404 / 403 / 超时 ✓（措辞比通用句更贴合"分类接口"场景 ✓，
    //   所以**有意保留** ✗✓）；剩下的与"未知原因"统一由 `describeSourceFail` 分级 ✓
    //   ⇒ 与体检页共用**同一套判据** ✓，解掉那边注释里"两处必须同步"✗ 的隐患 ✓。
    return describeSourceFail(raw, what: '该源分类接口').text;
  }

  /// 切到某个源后：未搜索时加载该源的分类浏览（exploreUrl）。
  Future<void> _loadExploreIfNeeded() async {
    if (_selectedSourceId.isEmpty) {
      setState(() {
        _cats = [];
        _activeCat = null;
        _exploreList = [];
        _exploreError = null;
        _exploreLoading = false;
      });
      return;
    }
    final sources = _enabledBooks;
    if (sources.isEmpty) return;
    BookSource? source;
    for (final s in sources) {
      if (s.id == _selectedSourceId) {
        source = s;
        break;
      }
    }
    if (source == null) return;
    _lastExploreSource = source;

    setState(() {
      _exploreLoading = true;
      _exploreError = null;
      _cats = [];
      _activeCat = null;
      _exploreList = [];
      _catBooksCache.clear();
      _catLoading.clear();
      _catError.clear();
      _exploreVisibleSections = 2;
      _exploreHomeMode = true;
    });
    // 壳模式：服务端解析 exploreKinds（分类列表）
    if (_serverMode) {
      try {
        final res = await QreadApi.instance.getExploreKinds(source.url);
        final found = res['found'];
        final cats = <ExploreCategory>[];
        if (found is List) {
          for (final e in found) {
            if (e is! Map) continue;
            final title = (e['title'] ?? '').toString().trim();
            final url = (e['url'] ?? '').toString().trim();
            if (title.isEmpty) continue;
            cats.add(ExploreCategory(title: title, url: url));
          }
        }
        if (!mounted || source.id != _selectedSourceId) return;
        if (cats.isEmpty) {
          setState(() {
            _exploreLoading = false;
            _exploreError = _friendlyError('该源没有配置分类浏览（exploreKinds 为空）');
          });
          return;
        }
        setState(() {
          _cats = cats;
          _exploreLoading = false;
        });
        final src = source;
        for (final c in cats.take(_exploreVisibleSections)) {
          unawaited(_loadSection(src, c));
        }
        return;
      } on QreadException catch (e) {
        if (!mounted || source.id != _selectedSourceId) return;
        setState(() {
          _exploreLoading = false;
          _exploreError = e.message;
        });
        return;
      }
    }

    final r = await BookSourceService.instance.exploreCategories(source);
    if (!mounted || source.id != _selectedSourceId) return;
    if (!r.ok || r.categories.isEmpty) {
      setState(() {
        _exploreLoading = false;
        _exploreError = _friendlyError(r.error ?? '该源没有配置分类浏览');
      });
      return;
    }
    setState(() {
      _cats = r.categories;
      _exploreLoading = false;
    });
    // 板块流：并发加载前 2 个板块（懒加载，滚动追加）
    final src = source;
    for (final c in r.categories.take(_exploreVisibleSections)) {
      unawaited(_loadSection(src, c));
    }
  }

  /// 板块流：加载单个板块的书籍（exploreBooks → 缓存）
  Future<void> _loadSection(BookSource source, ExploreCategory cat) async {
    if (_catLoading[cat.url] == true) return;
    setState(() => _catLoading[cat.url] = true);
    // 壳模式：服务端执行 exploreBook
    if (_serverMode) {
      try {
        final list = await QreadApi.instance.exploreBook(source.url, cat.url);
        if (!mounted || source.id != _selectedSourceId) return;
        setState(() {
          _catLoading[cat.url] = false;
          _catError[cat.url] = null;
          _catBooksCache[cat.url] = list
              .map((r) => _fromQread(r, source))
              .toList();
        });
      } on QreadException catch (e) {
        if (!mounted || source.id != _selectedSourceId) return;
        setState(() {
          _catLoading[cat.url] = false;
          _catError[cat.url] = e.message;
          _catBooksCache[cat.url] ??= const [];
        });
      }
      return;
    }
    final r = await BookSourceService.instance.exploreBooks(source, cat.url);
    if (!mounted || source.id != _selectedSourceId) return;
    setState(() {
      _catLoading[cat.url] = false;
      if (r.ok) {
        _catBooksCache[cat.url] = r.list;
        _catError[cat.url] = null;
      } else {
        _catError[cat.url] = r.error ?? '加载失败';
        _catBooksCache[cat.url] ??= const [];
      }
    });
  }

  /// 板块流懒加载：滚动接近底部时追加下一板块
  void _loadMoreSections() {
    if (_exploreVisibleSections >= _cats.length) return;
    final next = _cats[_exploreVisibleSections];
    setState(() => _exploreVisibleSections++);
    if (_catBooksCache[next.url] == null && _catLoading[next.url] != true) {
      final src = _enabledBooks.firstWhere(
        (s) => s.id == _selectedSourceId,
        orElse: () => _enabledBooks.first,
      );
      if (src.id == _selectedSourceId) unawaited(_loadSection(src, next));
    }
  }

  /// 加载某个分类的书籍列表（ruleExplore）：单分类视图（板块流点击"分类"进入）。
  Future<void> _loadCatBooks(BookSource source, ExploreCategory cat) async {
    setState(() {
      _exploreHomeMode = false; // 退出板块流，显示单分类
      _exploreLoading = true;
      _exploreError = null;
      _activeCat = cat;
      _exploreList = [];
    });
    // 板块流缓存命中则直接复用
    final cached = _catBooksCache[cat.url];
    if (cached != null && cached.isNotEmpty) {
      setState(() {
        _exploreLoading = false;
        _exploreList = cached;
      });
      return;
    }
    // 壳模式：服务端执行 exploreBook
    if (_serverMode) {
      try {
        final list = await QreadApi.instance.exploreBook(source.url, cat.url);
        if (!mounted || source.id != _selectedSourceId) return;
        setState(() {
          _exploreLoading = false;
          _exploreError = null;
          _catBooksCache[cat.url] = list
              .map((r) => _fromQread(r, source))
              .toList();
          _exploreList = _catBooksCache[cat.url]!;
        });
      } on QreadException catch (e) {
        if (!mounted || source.id != _selectedSourceId) return;
        setState(() {
          _exploreLoading = false;
          _exploreError = _friendlyError(e.message);
          _catBooksCache[cat.url] = const [];
        });
      }
      return;
    }
    final r = await BookSourceService.instance.exploreBooks(source, cat.url);
    if (!mounted || source.id != _selectedSourceId) return;
    setState(() {
      _exploreLoading = false;
      _catBooksCache[cat.url] = r.ok ? r.list : const [];
      if (r.ok) {
        _exploreList = r.list;
      } else {
        _exploreError = _friendlyError(r.error ?? '加载分类失败');
      }
    });
  }

  /// 从各源结果重建聚合视图。
  ///
  /// 「边搜边显示」的关键：每收到一个源的结果就重建一次，
  /// 用户不必等 40 个源全跑完才看到东西。
  void rebuildGroups() {
    _grouped.clear();
    _perSource.forEach((_, list) {
      // 同一源返回重复条目（分卷/重复抓取）先按「源 + 地址 + 作者」去重
      final seen = <String>{};
      for (final r in list) {
        final key = normalizeForMatch(r.name);
        if (key.isEmpty) continue;
        final dedupe = '${r.source.id}|${r.bookUrl}|${r.author}';
        if (!seen.add(dedupe)) continue;
        _grouped.putIfAbsent(key, () => []).add(r);
      }
    });
  }

  /// 单源结果暂存（onSourceResults 时写入）
  final Map<String, List<BookSourceResult>> _perSource = {};

  /// 所有已到结果按书名聚合
  List<_BookGroup> get _groups {
    final out = <_BookGroup>[];
    _grouped.forEach((k, v) {
      if (v.isEmpty) return;
      out.add(_BookGroup(key: k, items: v));
    });
    // 复搜模式：按选中的源多选过滤
    if (_focusMode && _selectedSourceIds.isNotEmpty) {
      out.removeWhere(
        (g) => !g.items.any((r) => _selectedSourceIds.contains(r.source.id)),
      );
    }
    // 三级排序（对齐 MiDu 的思路，自己实现）：
    //   0 书名与关键词归一化后完全相同（多源同书合并）
    //   1 互相包含（「斗罗大陆」/「斗罗大陆（精校版）」）
    //   2 模糊相似（Dice ≥ 0.55）
    //   3 其余
    // 同级再按「相似度 → 来源数 → 书名」排，避免结果看起来随机。
    out.sort((a, b) {
      final ra = matchRank(a.items.first.name, _keyword);
      final rb = matchRank(b.items.first.name, _keyword);
      if (ra != rb) return ra.compareTo(rb);
      final sa = nameSimilarity(a.items.first.name, _keyword);
      final sb = nameSimilarity(b.items.first.name, _keyword);
      if ((sa - sb).abs() > 0.01) return sb.compareTo(sa);
      final c = b.items.length.compareTo(a.items.length);
      return c != 0 ? c : a.items.first.name.compareTo(b.items.first.name);
    });
    return out;
  }

  /// 结果涉及的所有源（复搜 chips 用）
  List<({String id, String name})> get _involvedSources {
    final map = <String, String>{};
    for (final list in _grouped.values) {
      for (final r in list) {
        map.putIfAbsent(r.source.id, () => r.source.name);
      }
    }
    return map.entries.map((e) => (id: e.key, name: e.value)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _isDark
          ? JellyTheme.backgroundDark
          : JellyTheme.backgroundLight,
      appBar: AppBar(
        // 去掉返回箭头：书源页返回靠标题旁的拉绳（maybePop）/ 系统返回
        automaticallyImplyLeading: false,
        // AppBar 背景透明：露出 Scaffold 页面背景（backgroundLight/Dark），
        // 让搜索框的透明底和漫画/书架/收藏页一致（原来 AppBar 用主题默认
        // 背景色，透明搜索框露出的底色不一样）
        backgroundColor: Colors.transparent,
        titleSpacing: 0,
        // ── 标题行（按截图：一行放下全部控件）──────────────────
        //   书源 ⋮拉绳  [搜索书源图书]  (工具) (历史) (菜单)
        //
        // 原来是"AppBar 里只放标题+拉绳+图标组，搜索框在下面单独一行"。
        // 截图里是一行，所以把搜索框并进 AppBar 的 title。
        // 用 Expanded 撑开，右侧 actions 才不会被长标题/长搜索框挤掉。
        title: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            children: [
              Text(
                '书源',
                style: TextStyle(
                  fontSize: AppTheme.fontTitle2,
                  fontWeight: FontWeight.w700,
                  color: _titleColor,
                ),
              ),
              // ✅ 2026-10-10 用户："拉绳离字间距大一些"：4 -> 10
              const SizedBox(width: 10),
              JellyPullCord(
                // ⚠️ 限高，否则绳子会把整行撑高导致同排控件错位。
                // ⚠️ 2026-10-09：拉绳整体减半（绳自然高 20）⇒ 这里同步 40→20。
                height: 20,
                tooltip: '切换到图书',
                // 书源页是 push 进来的，所以"切回图书"就是 pop。
                // ✅ **内嵌模式下的返回**（本轮重构 ✓）：本页现在由**外壳**渲染 ✓
                //   （`openEmbeddedPage(...)` ✓）⇒ 它**不在**导航栈里 ✗
                //   ⇒ 必须调 `closeEmbeddedPage()` 回到原 tab ✓（底栏仍在 ✓）
                // ℹ️ 非内嵌（万一还有别处 push 进来 ✓）仍走原来的 `maybePop` ✓ 两种都安全 ✓
                // 原注释保留 ✓：用 pop 而不是再 push 一个图书页：否则连点几下会在栈里
                // 堆出一串页面，返回键要按很多次才出得去。
                onTap: () {
                  if (shellEmbeddedPage.value != null) {
                    closeEmbeddedPage();
                  } else {
                    Navigator.maybePop(context);
                  }
                },
              ),
            ],
          ),
        ),
        actions: [
          // ✅ 2026-10-10 间距统一：搜索圆钮从 title 的 Expanded(tight 满宽)挪到
          //    actions 首位 —— 原来展开式搜索框收起成 32 圆钮后被 tight 满宽
          //    强行撑开、圆钮贴左，与右侧筛选/叠图标之间空一大截 ✗；
          //    挪过来后三页结构一致：[搜索] 10 [筛选] 10 [叠图标] ✓
          _searchField(),
          const SizedBox(width: 10),
          // ✅ 用户 2026-10-07 要求：
          //   ① 右上角**去掉刷新按钮**（原来那个 refresh ✗ 已删）；
          //   ② 原来是「搜索源」(view_list) 按钮 ✗ —— 它和**下面源标签行最右侧**
          //      那个 `_showQuickSources` 按钮**功能完全重复** ✗
          //      ⇒ 换成**与漫画页同款的「筛选」按钮**（tune 图标）✓：
          //        点开当前源的分类面板；没加载过分类就先拉一遍 ✓
          IconButton(
            tooltip: '分类筛选',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () {
              if (_cats.isNotEmpty) {
                _showCategorySheet();
                return;
              }
              if (_selectedSourceId.isEmpty) {
                _toast('先选一个书源再看分类');
                return;
              }
              _toast('正在加载分类…');
              _loadExploreIfNeeded();
            },
          ),
          // 视图切换：列表 / 宫格·3列 / 宫格·4列 / 宫格·5列
          // （用户 2026-10-07：书源页也要宫格/列表 + 3/4/5 列）
          // ✅ 用户 2026-10-07：「将视图按钮只在我的里面的显示设置里面就行」
          //   ⇒ 书源页顶栏的视图按钮**已移除** ✓（只留右边的**筛选**按钮）
          //   视图（列表 / 宫格·3/4/5 列）+ 书源视图 统一在
          //   「我的 → 显示设置 → 书源页视图」里选 ✓
          // ✅ 用户 2026-10-07：「去掉那个云端按钮」——
          //   顶部那个 `cloud_outlined`（云端网页版，指向 CloudBookSourcePage）按钮
          //   **已移除** ✓（页面代码保留，只是不再有顶栏入口）
          // ⚠️ 用户 2026-10-07（第二轮修正）：
          //   · **筛选按钮单独拉出来** ✓（上面那个 tune 按钮保持不动）
          //   · 其余 4 个动作叠在一起、左右滑动轮换 ✓
          //     （原来是 ··· 下拉菜单，现在换成滑动动作栏同款）
          // ⚠️ 用户要求（本轮）：右上角由「并排滑动动作栏」改成**叠图标控件** ——
          //   · 最前的**完整可见**（深色圆底）
          //   · 后面各露出一部分，**左右滑动**循环切换最前
          //   · **长按**竖向展开全部
          //   原来的 `JellySlidingActions` 已整体替换（筛选按钮仍单独保留在它左边）。
          JellyIconDeck(
            items: [
              JellyIconDeckItem(
                icon: Icons.history_rounded,
                tooltip: '浏览记录',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const BrowseHistoryPage()),
                ),
              ),
              JellyIconDeckItem(
                icon: Icons.favorite_rounded,
                tooltip: '收藏',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const FavoritesPage(showBackButton: true),
                  ),
                ),
              ),
              JellyIconDeckItem(
                icon: Icons.file_download_rounded,
                tooltip: '下载',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const BookDownloadRecordsPage(),
                  ),
                ),
              ),
              JellyIconDeckItem(
                icon: Icons.storefront_rounded,
                tooltip: '书源仓库',
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const BookSourceRepoPage(),
                    ),
                  );
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          // 搜索框已并入 AppBar 的标题行（按截图的一行布局），
          // 这里不再重复渲染。
          // 源标签行（聚搜 + 各启用书源，点击切换单源/聚搜）
          _sourceTabs(),
          if (_searching) _progressBar(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  /// 源标签行（参考图：聚搜/画涯爱子/猫眼看书…）：
  /// 聚搜 = 跨全部源；选中某个源 = 单源搜索。
  /// 右侧「快速书源」按钮弹源列表筛选弹窗。
  Widget _sourceTabs() {
    // 按 customOrder 排序展示（内置的 5 个修复版书源排最前）——
    // 与进入页面时自动选中的那个源保持一致，否则默认选中的 chip 跑到最右，
    // 用户看不出"当前选中了哪个源"。
    // ✅ 过滤掉关闭「发现」的源（用户 2026-10-11）：书源页主体是发现页，
    //   关了发现的源点进去只会报"没有配置分类浏览"，不如不展示。
    //   聚搜/单源搜索不受影响（enabledExplore 只管发现）。
    final sources = store
        .sorted()
        .where((s) => s.enabled && s.enabledExplore && s.belongsToBook)
        .toList();
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          // 聚搜固定在第一位，不随源列表滑动（对齐参考图）
          // ✅ 用户 2026-10-07：与漫画页统一成**只留图标**（去掉"聚搜"文字）
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: _aggregateChip(),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(0, 4, 4, 4),
              itemCount: sources.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) =>
                  _sourceChip(sources[i].name, sources[i].id),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Material(
              color: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _showQuickSources,
                child: SizedBox(
                  width: 32,
                  height: 32,
                  // ✅ 用户 2026-10-07：与漫画页统一成**向下箭头**（原来是 view_list ✗）
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 22,
                    color: JellyTheme.textPrimaryLight,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「聚搜」按钮（跨全部书源）
  ///
  /// 用户 2026-10-18：改为**图标 + 文字**（∞ + 聚搜）的胶囊，
  /// 与漫画页 `_buildAggregateChip`、图书页「推荐」保持同一形态。
  Widget _aggregateChip() {
    final selected = _selectedSourceId.isEmpty;
    final fg = selected ? Colors.white : JellyTheme.primary;
    return GestureDetector(
      onTap: () {
        setState(() => _selectedSourceId = '');
        _toast('已切换到聚搜：跨全部书源');
        if (_keyword.isNotEmpty) _run(_keyword);
      },
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? JellyTheme.primary
              : (_isDark ? JellyTheme.cardDark : JellyTheme.cardLight),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.all_inclusive_rounded, size: 16, color: fg),
            const SizedBox(width: 4),
            Text(
              '聚搜',
              style: TextStyle(
                fontSize: AppTheme.fontCaption + 1,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceChip(String name, String id) {
    final selected = id == _selectedSourceId;
    return GestureDetector(
      // 用户 2026-10-19：长按源标签 → 操作菜单（排序/编辑/登录/分享/多选/删除）；
      // 双击 → 删除确认（保留旧手势）
      onLongPress: () => _showBookSourceActions(name, id),
      onDoubleTap: () => _confirmDeleteBookSource(id, name),
      onTap: () {
        setState(() => _selectedSourceId = id);
        _rememberSource(id);
        _toast(id.isEmpty ? '已切换到聚搜：跨全部书源' : '已切换到书源：$name');
        if (_keyword.isNotEmpty) {
          // 有当前关键词则立刻用新源重搜
          _run(_keyword);
        } else {
          // 未搜索：加载该源的分类浏览
          _loadExploreIfNeeded();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected
              ? JellyTheme.primary
              : (_isDark
                    ? JellyTheme.cardDark
                    : JellyTheme.primary.withValues(alpha: 0.08)),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          name,
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected
                ? Colors.white
                : (_isDark ? Colors.white70 : JellyTheme.textPrimaryLight),
          ),
        ),
      ),
    );
  }

  /// 长按源标签：调整书源顺序（写回 customOrder，持久化）
  Future<void> _reorderBookSources() async {
    final sources = store
        .sorted()
        .where((s) => s.enabled && s.enabledExplore && s.belongsToBook)
        .toList();
    if (sources.length < 2) {
      _toast('可发现的源不足 2 个，无需排序');
      return;
    }
    final ids = await showSourceOrderSheet(
      context,
      title: '调整书源顺序',
      items: [for (final s in sources) (s.id, s.name)],
    );
    if (ids == null || !mounted) return;
    // 未展示的源接在后面，避免它们的 customOrder 与可见源交错
    final visible = ids.toSet();
    final rest = store
        .sorted()
        .map((e) => e.id)
        .where((id) => !visible.contains(id))
        .toList();
    await store.reorder([...ids, ...rest]);
    if (mounted) setState(() {});
  }

  /// 长按源标签 → 操作菜单（排序 / 编辑 / 登录 / 分享 / 多选 / 删除）
  ///
  /// 与漫画源 tab 的长按菜单保持一致（2026-10-19 用户要求）。
  Future<void> _showBookSourceActions(String name, String id) async {
    final src = store.all.firstWhere(
      (s) => s.id == id,
      orElse: () => BookSource(raw: const {}, id: id),
    );
    final group = src.group.trim();
    await showCardActions(
      context,
      title: name,
      subtitle: group.isEmpty ? '书源' : '书源 · $group',
      actions: [
        CardAction(
          icon: Icons.swap_vert_rounded,
          label: '排序',
          onTap: _reorderBookSources,
        ),
        CardAction(
          icon: Icons.edit_outlined,
          label: '编辑',
          onTap: () => _editBookSource(src),
        ),
        CardAction(
          icon: Icons.login_rounded,
          label: '登录',
          onTap: () => _loginBookSource(src),
        ),
        CardAction(
          icon: Icons.ios_share_rounded,
          label: '分享',
          onTap: () => _shareBookSource(src),
        ),
        CardAction(
          icon: Icons.checklist_rounded,
          label: '多选',
          onTap: _showBookSourceMultiSelect,
        ),
        CardAction(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          danger: true,
          onTap: () => _confirmDeleteBookSource(id, name),
        ),
      ],
    );
  }

  /// 编辑书源：打开书源编辑器
  Future<void> _editBookSource(BookSource src) async {
    if (src.id.isEmpty || src.raw.isEmpty) {
      _toast('找不到这条书源（可能已被删除）');
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookSourceEditorPage(source: src)),
    );
    // 编辑页保存时会自己刷新；这里只刷新本页标签
    if (mounted) setState(() {});
  }

  /// 登录 / 浏览器验证：复用 Legado 书源登录页
  Future<void> _loginBookSource(BookSource src) async {
    if (src.id.isEmpty || src.raw.isEmpty) {
      _toast('找不到这条书源（可能已被删除）');
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookSourceLoginPage(source: src)),
    );
    // Cookie 写进书源 header 后，搜索/探索请求才会带上 ⇒ 刷新本页
    if (mounted) setState(() {});
  }

  /// 分享书源：把原始 JSON 复制到剪贴板
  Future<void> _shareBookSource(BookSource src) async {
    final data = src.raw;
    if (data.isEmpty) {
      _toast('这个源没有可分享的配置');
      return;
    }
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(data)),
    );
    _toast('源配置已复制到剪贴板');
  }

  /// 多选：批量启用 / 停用 / 删除书源
  Future<void> _showBookSourceMultiSelect() async {
    final all = store.sorted().where((s) => s.belongsToBook).toList();
    if (all.isEmpty) {
      _toast('还没有书源');
      return;
    }
    final picked = <String>{};
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final allPicked = picked.length == all.length;
          return SafeArea(
            top: false,
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.66,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
                    child: Row(
                      children: [
                        Text(
                          '多选書源',
                          style: TextStyle(
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '已选 ${picked.length}',
                          style: TextStyle(
                            fontSize: AppTheme.fontCaption,
                            color: AppTheme.textTertiary,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => setSheet(() {
                            if (allPicked) {
                              picked.clear();
                            } else {
                              picked
                                ..clear()
                                ..addAll(all.map((s) => s.id));
                            }
                          }),
                          child: Text(allPicked ? '取消全选' : '全选'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: all.length,
                      itemBuilder: (_, i) {
                        final s = all[i];
                        final on = picked.contains(s.id);
                        return CheckboxListTile(
                          dense: true,
                          value: on,
                          activeColor: JellyTheme.primary,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                            s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: AppTheme.fontSubhead,
                            ),
                          ),
                          subtitle: Text(
                            s.enabled ? '已启用' : '已停用',
                            style: TextStyle(
                              color: s.enabled
                                  ? JellyTheme.primary
                                  : AppTheme.textTertiary,
                              fontSize: AppTheme.fontCaption,
                            ),
                          ),
                          onChanged: (v) => setSheet(() {
                            if (v == true) {
                              picked.add(s.id);
                            } else {
                              picked.remove(s.id);
                            }
                          }),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: picked.isEmpty
                              ? null
                              : () async {
                                  for (final id in picked) {
                                    await store.setEnabled(id, true);
                                  }
                                  if (ctx.mounted) setSheet(() {});
                                },
                          child: const Text('启用'),
                        ),
                        TextButton(
                          onPressed: picked.isEmpty
                              ? null
                              : () async {
                                  for (final id in picked) {
                                    await store.setEnabled(id, false);
                                  }
                                  if (ctx.mounted) setSheet(() {});
                                },
                          child: const Text('停用'),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: picked.isEmpty
                              ? null
                              : () async {
                                  final ids = Set<String>.of(picked);
                                  final ok = await _confirmDeleteBookSources(
                                    ids.length,
                                  );
                                  if (!ok) return;
                                  for (final id in ids) {
                                    await store.remove(id);
                                  }
                                  picked.clear();
                                  if (ctx.mounted) setSheet(() {});
                                },
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                          ),
                          child: const Text('删除'),
                        ),
                        const SizedBox(width: 4),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  /// 批量删除确认
  Future<bool> _confirmDeleteBookSources(int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 $count 个书源？'),
        content: const Text(
          '删除后书源仓库里也会一并移除。',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 双击源标签：删除该源（先确认）
  Future<void> _confirmDeleteBookSource(String id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书源'),
        content: Text(
          '确定删除「$name」？\n\n删除后书源仓库里也会一并移除。',
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await store.remove(id);
    if (!mounted) return;
    setState(() {
      if (_selectedSourceId == id) _selectedSourceId = '';
    });
    _toast('已删除书源：$name');
  }

  /// 快速书源列表弹窗（参考图 IMG_8430：「搜索源」输入框 + 快速书源列表 + 收起）
  Future<void> _showQuickSources() async {
    // ✅ 与源 chips 同一过滤：关闭「发现」的源不在书源页展示（2026-10-11）
    final sources = store.all
        .where((s) => s.enabled && s.enabledExplore && s.belongsToBook)
        .toList();
    // 当前书源是否仍在这个弹窗的可见列表里（停用/关发现后会不在）
    final hasCurrent =
        _selectedSourceId.isNotEmpty &&
        sources.any((s) => s.id == _selectedSourceId);
    // 分组口径与「书源仓」一致（Legado 的 bookSourceGroup，空 = 未分组）
    final groups = collectSourceGroups(sources.map((s) => s.group));
    // 当前书源 chip 的 key：打开弹窗后自动滚到它（源多时定位到当前位置）
    final currentKey = GlobalKey();
    var selectedGroup = SourceGroupTabs.all;
    var positioned = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final kw = _sourceFilter.text.trim().toLowerCase();
            final shown = sources.where((s) {
              final g = sourceGroupLabel(s.group);
              if (selectedGroup != SourceGroupTabs.all && g != selectedGroup) {
                return false;
              }
              if (kw.isEmpty) return true;
              return s.name.toLowerCase().contains(kw) ||
                  g.toLowerCase().contains(kw);
            }).toList();
            if (!positioned) {
              positioned = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final c = currentKey.currentContext;
                if (c == null || !c.mounted) return;
                Scrollable.ensureVisible(
                  c,
                  alignment: 0.35,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              });
            }
            // 右上角「定位」：先清掉分组/关键词过滤，再滚到当前书源
            void locateCurrent() {
              setSheetState(() {
                selectedGroup = SourceGroupTabs.all;
                _sourceFilter.clear();
              });
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final c = currentKey.currentContext;
                if (c == null || !c.mounted) return;
                Scrollable.ensureVisible(
                  c,
                  alignment: 0.35,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              });
            }

            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.7,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 用户 2026-10-18：搜索框上方加可滑动的分类 tab，分组与书源仓一致
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SourceGroupTabs(
                        groups: groups,
                        selected: selectedGroup,
                        onSelected: (g) =>
                            setSheetState(() => selectedGroup = g),
                        // 聚搜 / 当前源已不在可见列表时，没有可定位目标
                        onLocate: hasCurrent ? locateCurrent : null,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: JellySearchBar(
                        controller: _sourceFilter,
                        hintText: '搜索源',
                        onChanged: (_) => setSheetState(() {}),
                        onCleared: () => setSheetState(() {}),
                      ),
                    ),
                    // ⚠️ 用户 2026-10-07：「那个源搜索能不能是一个接一个呢，
                    //   一行接一行的，不要以列表形式呢」
                    //   ⇒ 变成**自动换行的源 chip 流** ✓（与漫画页同款 ✓）
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: shown.isEmpty
                            ? const QuickSourcesEmpty()
                            : Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final s in shown)
                                    KeyedSubtree(
                                      key: s.id == _selectedSourceId
                                          ? currentKey
                                          : null,
                                      child: _quickSourceChip(
                                        name: s.name,
                                        selected: s.id == _selectedSourceId,
                                        onTap: () {
                                          setSheetState(() {
                                            _selectedSourceId = s.id;
                                          });
                                          _rememberSource(s.id);
                                          Navigator.pop(ctx);
                                          setState(() {});
                                          _toast('已切换到书源：${s.name}');
                                          if (_keyword.isNotEmpty) {
                                            _run(_keyword);
                                          } else {
                                            _loadExploreIfNeeded();
                                          }
                                        },
                                      ),
                                    ),
                                ],
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 搜索框本体（不带外边距）—— 放在 AppBar 的 title 里，
  /// 由外层 Row 的 Expanded 负责宽度。
  ///
  /// 与漫画/图书/书架/收藏页统一成小胶囊：收起 = 44 圆钮，点击展开成胶囊，
  /// 图标在左、提示「搜索书源图书」；搜索中右侧显示 spinner。
  Widget _searchField() {
    return JellyExpandableSearch(
      controller: _ctrl,
      hintText: '搜索书源图书',
      // 用户 2026-10-07：宽度改成原来的三分之二（200 → 133）
      maxWidth: 133,
      onSubmitted: (value) => _run(value),
      onChanged: (value) => setState(() {}),
      trailing: _searching
          ? const Padding(
              padding: EdgeInsets.all(10),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : null,
    );
  }

  /// 搜索进度：已 N/M 个源。
  ///
  /// 为什么要显示：导入 40 个源时最慢的源可能要十几秒，
  /// 没有进度用户会以为卡死并反复退出。
  Widget _progressBar() {
    final ok = _states.where((s) => s.ok).length;
    final bad = _states.where((s) => !s.ok).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: _totalCount == 0 ? null : _doneCount / _totalCount,
              color: JellyTheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '已搜索 $_doneCount/$_totalCount 个源'
            '${ok > 0 ? ' · 成功 $ok' : ''}'
            '${bad > 0 ? ' · 失败 $bad' : ''}',
            style: TextStyle(
              fontSize: AppTheme.fontFootnote,
              color: JellyTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_enabledBooks.isEmpty) return _emptySources();
    if (_groups.isNotEmpty) return _resultsBody();
    if (_searching) return const SizedBox.shrink();
    if (_keyword.isNotEmpty)
      return _hint('没有搜到「$_keyword」', Icons.search_off_rounded);
    // 未搜索 + 选中单源 → 分类浏览（参考图「必读榜」网格）
    if (_selectedSourceId.isNotEmpty) return _exploreBody();
    // 聚搜空态（参考图 IMG_8427）
    return _emptyHint(
      '输入关键词，在 ${_enabledBooks.length} 个书源里一起搜',
      '下拉切换复搜',
      Icons.manage_search_rounded,
    );
  }

  /// 搜索结果（聚搜/单源）—— 宫格 / 列表可切换（用户 2026-10-07），复搜 chips + 下拉切换
  Widget _resultsBody() {
    final grid = SourceViewMode().isGrid;
    return Column(
      children: [
        // 复搜模式：源 chips 多选过滤（结果列表顶部）
        if (_focusMode && _involvedSources.isNotEmpty) _focusChips(),
        Expanded(
          child: RefreshIndicator(
            color: JellyTheme.primary,
            // 结果列表顶部下拉 → 切换为「复搜」模式（参考 cmbok 引导）
            onRefresh: () async {
              if (!_focusMode) {
                setState(() => _focusMode = true);
                _toast('已切换到「复搜」模式：点选源标签组合过滤');
              }
            },
            child: grid ? _resultsGrid() : _resultsList(),
          ),
        ),
      ],
    );
  }

  /// 结果列表视图（横向大卡片）
  Widget _resultsList() {
    final groups = _groups;
    return ListView.builder(
      // ✅ 2026-10-10 内容布局统一：横向 16->12、底部 24 固定 -> 底栏避让
      //    （与漫画/图书/收藏页的 12 + JellyNavBar.contentBottomAvoid 对齐）
      padding: EdgeInsets.only(
        left: 12,
        top: 4,
        right: 12,
        bottom: 12 + JellyNavBar.contentBottomAvoid,
      ),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: groups.length,
      itemBuilder: (c, i) => _bookTile(groups[i]),
    );
  }

  /// 结果宫格视图（一排 3 / 4 / 5 个，由 ReadingLayout 决定）
  Widget _resultsGrid() {
    final groups = _groups;
    final cols = ReadingLayout().columns;
    return GridView.builder(
      padding: EdgeInsets.only(
        left: 12,
        top: 4,
        right: 12,
        bottom: 12 + JellyNavBar.contentBottomAvoid,
      ),
      physics: const AlwaysScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        // ✅ 2026-10-10 卡片去掉作者行后内容变矮，ratio 0.52/0.56 -> 0.56/0.61
        crossAxisCount: cols,
        mainAxisSpacing: 8,
        crossAxisSpacing: 12,
        childAspectRatio: cols >= 5 ? 0.56 : 0.61,
      ),
      itemCount: groups.length,
      itemBuilder: (c, i) => _bookGridTile(groups[i]),
    );
  }

  /// 分类浏览主体：源名·分类名标题行 + 分类弹窗按钮 + 封面网格
  Widget _exploreBody() {
    // ✅ 2026-10-10 用户：「源名称和分类去掉，筛选按钮本身就有分类」
    //    → 整行删掉（源名/分类按钮都不留），主体直接是分类板块流；
    //    分类入口保留在顶栏筛选弹窗（_showCategorySheet 仍被其调用）
    return _exploreGrid();
  }

  Widget _exploreGrid() {
    // 板块流模式（默认）：exploreUrl 全部分类逐板块整页滚动（参考图 IMG_8581/8582）
    if (_exploreHomeMode && _cats.isNotEmpty) {
      final src = _enabledBooks.firstWhere(
        (s) => s.id == _selectedSourceId,
        orElse: () => _enabledBooks.first,
      );
      return NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 600) {
            _loadMoreSections();
          }
          return false;
        },
        child: ListView.builder(
          padding: const EdgeInsets.only(bottom: 24),
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: _exploreVisibleSections + 1,
          itemBuilder: (c, i) {
            if (i == _exploreVisibleSections) {
              // 底部：正在加载更多板块 / 已全部加载
              if (_exploreVisibleSections >= _cats.length) {
                return const SizedBox(height: 8);
              }
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              );
            }
            return _sectionBlock(src, _cats[i]);
          },
        ),
      );
    }
    if (_exploreLoading && _exploreList.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (_exploreList.isEmpty) {
      // explore 出错（含"该源没有配置分类浏览"）→ 提供降级入口：
      // 直接用内置浏览器打开书源主站（legado openBookSource 的语义）
      if (_exploreError != null && _lastExploreSource != null) {
        return _exploreFallback(_lastExploreSource!, _exploreError!);
      }
      return _hint(_exploreError ?? '该分类暂时没有内容', Icons.auto_stories_outlined);
    }
    return GridView.builder(
      // ✅ 2026-10-10 内容布局统一：横向 16->12、底部 24 固定 -> 底栏避让
      //    （与漫画/图书/收藏页的 12 + JellyNavBar.contentBottomAvoid 对齐）
      padding: EdgeInsets.only(
        left: 12,
        top: 4,
        right: 12,
        bottom: 12 + JellyNavBar.contentBottomAvoid,
      ),
      physics: const AlwaysScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        // 分类浏览网格也跟随用户偏好列数（3/4/5）
        crossAxisCount: ReadingLayout().columns,
        mainAxisSpacing: 8,
        crossAxisSpacing: 12,
        childAspectRatio: 0.56,
      ),
      itemCount: _exploreList.length,
      itemBuilder: (context, i) => _exploreTile(_exploreList[i]),
    );
  }

  /// 「搜索源」弹窗里的一枚源 chip（**流式换行**排布，用户 2026-10-07：
  /// 原来是一行一个的列表，现在改成"一个接一个、满行自动换行"）✓
  /// 与漫画页 `_quickSourceChip` 同款视觉 ✓
  Widget _quickSourceChip({
    required String name,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? JellyTheme.primary
              : JellyTheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          // 兜底：空名书源用 '?' 占位（空串取首字符会抛 StateError）
          name.isEmpty ? '?' : name,
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? Colors.white : JellyTheme.primary,
          ),
        ),
      ),
    );
  }

  /// 板块流：单个板块 = 标题行 + 3 列封面网格
  Widget _sectionBlock(BookSource src, ExploreCategory cat) {
    // ⚠️ 用户 2026-10-07：「漫画页和书源页里面的分类内容只要显示前6个就行」
    //   ⇒ 板块只预览**前 6 个** ✓（点「查看全部」进去仍是完整列表，不受影响 ✓）
    final all = _catBooksCache[cat.url] ?? const <BookSourceResult>[];
    final items = all.length > 6 ? all.sublist(0, 6) : all;
    final loading = _catLoading[cat.url] == true;
    final err = _catError[cat.url];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  cat.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTheme.fontTitle3,
                    fontWeight: FontWeight.w700,
                    color: _titleColor,
                  ),
                ),
              ),
              // 进入单分类视图
              GestureDetector(
                onTap: () => _loadCatBooks(src, cat),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '查看全部',
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: JellyTheme.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (loading && items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          )
        else if (err != null && items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text(
                err,
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: JellyTheme.textSecondary,
                ),
              ),
            ),
          )
        else
          GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              // 板块网格跟随用户偏好列数（3/4/5）
              // ✅ 2026-10-10 卡片去掉作者/章节两行后内容变矮，ratio 0.56 -> 0.62/0.58
              crossAxisCount: ReadingLayout().columns,
              mainAxisSpacing: 8,
              crossAxisSpacing: 12,
              childAspectRatio: ReadingLayout().columns >= 5 ? 0.58 : 0.62,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) => _exploreTile(items[i]),
          ),
      ],
    );
  }

  /// 从「最新章节」标题解析角标文本：`第 123 章…` / `Chapter 45` 等
  /// → `123 章`；解析不出数字 → null（不显示角标）。纯本地正则，零网络。
  static final RegExp _chNumRe = RegExp(
    r'(?:第\s*(\d+)\s*[章话]|Chapter\s*#?\s*(\d+)|CH\.?\s*#?\s*(\d+))',
    caseSensitive: false,
  );

  String? _chapterBadgeText(String lastChapter) {
    if (lastChapter.isEmpty) return null;
    final m = _chNumRe.firstMatch(lastChapter);
    if (m == null) return null;
    final n = m.group(1) ?? m.group(2) ?? m.group(3);
    if (n == null || n.isEmpty) return null;
    return '$n 章';
  }

  /// 封面左上角作者角标：白字 + **透明灰底**（用户 2026-10-12：
  /// 原来只有白字加阴影，浮在封面上没有依托）。
  Widget _authorBadge(String author) {
    return Positioned(
      top: 4,
      left: 4,
      right: 36,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.38),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: AppTheme.fontCaption,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  /// 分类网格条目：竖版封面 + 书名 + 作者（点击直接进详情）
  Widget _exploreTile(BookSourceResult r) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BookSourceDetailPage(result: r),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面 + 左上角作者角标 + 右上角「N 章」更新角标
          // （✅ 2026-10-10 用户：名称下的作者/最新章节行去掉，作者上封面左上角）
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AspectRatio(
                  aspectRatio: 0.7, // 高 : 宽
                  child: r.coverUrl.isEmpty
                      ? Container(
                          color: JellyTheme.primary.withValues(alpha: 0.1),
                          child: Icon(
                            Icons.menu_book_rounded,
                            size: 26,
                            color: JellyTheme.primary,
                          ),
                        )
                      : CachedNetworkImage(
                          imageUrl: r.coverUrl,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            color: JellyTheme.primary.withValues(alpha: 0.1),
                            child: Icon(
                              Icons.menu_book_rounded,
                              size: 26,
                              color: JellyTheme.primary,
                            ),
                          ),
                        ),
                ),
              ),
              if (r.author.trim().isNotEmpty) _authorBadge(r.author),
              // 最新章节角标：**右下角** + 透明灰底（用户 2026-10-12：
              // 原来在右上角、还是红色，太抢眼）
              if (_chapterBadgeText(r.lastChapter) != null)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.38),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _chapterBadgeText(r.lastChapter)!,
                      style: const TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // ✅ ① **书名居中** ✓（原来走默认左对齐 ✗）
          //   包一层 `SizedBox(width: double.infinity)` 才能让 `textAlign` 生效 ✓；
          //   ⚠️ 外层 Column 的 `crossAxisAlignment` **保持 start** ✗ →
          //     下面**作者行仍左对齐** ✓（与截图 IMG_8595 一致 ✓）
          SizedBox(
            width: double.infinity,
            child: Text(
              r.name,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTheme.fontFootnote,
                fontWeight: FontWeight.w600,
                color: _titleColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 分类弹窗（参考图：「xx·分类」榜单/题材标签云，右上 ×）
  Future<void> _showCategorySheet() async {
    final src = _enabledBooks.firstWhere(
      (s) => s.id == _selectedSourceId,
      orElse: () => _enabledBooks.first,
    );
    if (_cats.isEmpty) {
      _toast('该源没有可用的分类');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      shape: jellySheetShape,
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 自绘把手（showModalBottomSheet 无 dragHandleColor 参数）
              const JellySheetHandle(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${src.name}·分类',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w700,
                        color: _titleColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  JellySheetCircleButton(
                    isDark: _isDark,
                    icon: Icons.close_rounded,
                    tooltip: '关闭',
                    onTap: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  // ✅ 与漫画页 / 图书页的筛选弹窗同款：**固定 3 列等宽网格**。
                  // 原来这里是 `Wrap` —— 而 `JellyFilterChip` 自身带 `alignment`，
                  // 放进 Wrap 会被撑满整行 ⇒ 变成"一行一个"
                  //（用户 2026-10-15：「书源页的筛选为啥还是一个一行」；
                  //   漫画页/图书页当时也是这么修的，见 search_page.dart / book_search_page.dart）。
                  child: GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                    childAspectRatio: 3.0,
                    children: _cats.map((c) {
                      final active = _activeCat?.url == c.url;
                      return JellyFilterChip(
                        label: c.title,
                        selected: active,
                        onTap: () {
                          Navigator.pop(ctx);
                          _loadCatBooks(src, c);
                        },
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 复搜模式下的源 chips（多选，点选即过滤）
  Widget _focusChips() {
    final sources = _involvedSources;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: sources.map((s) {
          final selected = _selectedSourceIds.contains(s.id);
          return GestureDetector(
            onTap: () => setState(() {
              if (selected) {
                _selectedSourceIds.remove(s.id);
              } else {
                _selectedSourceIds.add(s.id);
              }
            }),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: selected
                    ? JellyTheme.primary
                    : (_isDark
                          ? JellyTheme.cardDark
                          : JellyTheme.primary.withValues(alpha: 0.08)),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                s.name,
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? Colors.white
                      : (_isDark
                            ? Colors.white70
                            : JellyTheme.textPrimaryLight),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// 两行提示（主文案 + 副文案，参考图）
  Widget _emptyHint(String main, String sub, IconData icon) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 48,
          color: JellyTheme.textSecondary.withValues(alpha: 0.5),
        ),
        const SizedBox(height: 14),
        Text(
          main,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: FontWeight.w600,
            color: _titleColor,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          sub,
          style: TextStyle(
            fontSize: AppTheme.fontFootnote,
            color: JellyTheme.textSecondary,
          ),
        ),
      ],
    ),
  );

  Widget _emptySources() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.menu_book_outlined,
              size: 48,
              color: JellyTheme.textSecondary.withValues(alpha: 0.55),
            ),
            const SizedBox(height: 20),
            Text(
              '还没有书源',
              style: TextStyle(
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.w600,
                color: _titleColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '用地址、口令或本地文件导入书源',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                color: JellyTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const BookSourceRepoPage()),
                );
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('去导入书源'),
            ),
          ],
        ),
      ),
    );
  }

  /// explore 错误降级卡：错误文案 + 「打开书源网站」按钮
  /// （legado《书源显示问题修复总结》openBookSource：没有发现分类的源
  /// 点击 → 打开书源主站；这里在错误场景提供同样出路）
  Widget _exploreFallback(BookSource source, String error) {
    final siteUrl = source.url.trim();
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_stories_outlined,
            size: 48,
            color: JellyTheme.textSecondary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                color: JellyTheme.textSecondary,
              ),
            ),
          ),
          if (siteUrl.isNotEmpty) ...[
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        OnlineReaderPage(url: siteUrl, title: source.name),
                  ),
                );
              },
              icon: const Icon(Icons.public_rounded, size: 18),
              label: const Text('打开书源网站'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _hint(String text, IconData icon) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 48,
          color: JellyTheme.textSecondary.withValues(alpha: 0.5),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTheme.fontSubhead,
              color: JellyTheme.textSecondary,
            ),
          ),
        ),
      ],
    ),
  );

  /// 搜索结果卡片 —— **与漫画列表项（JellyComicListTile）同款视觉**：
  /// 大封面（84×112，3:4）+ 书名 + 作者/分类 + 来源标签 + 右下元信息。
  ///
  /// 用户 2026-10-07 要求："我要漫画是怎么显示的，这个书源这个也是怎么显示的"
  /// —— 原来书源结果用的是朴素的 ListTile + 46×62 小封面，与漫画/图书
  /// 侧的果冻卡片完全两个观感，这里统一过来。
  Widget _bookTile(_BookGroup g) {
    final first = g.items.first;
    final cardColor = _isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
    return GestureDetector(
      onTap: () => _open(g),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: JellyTheme.primary.withValues(alpha: 0.15),
              blurRadius: 15,
              spreadRadius: 2,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 封面：与漫画列表项同款 84×112（3:4），避免网络图尺寸导致抖动
              SizedBox(
                width: 84,
                height: 112,
                child: first.coverUrl.isEmpty
                    ? _bookCoverPlaceholder()
                    : CachedNetworkImage(
                        imageUrl: first.coverUrl,
                        fit: BoxFit.cover,
                        memCacheWidth: 300,
                        placeholder: (_, __) => _bookCoverPlaceholder(),
                        errorWidget: (_, __, ___) => _bookCoverPlaceholder(),
                      ),
              ),
              // 信息区
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        first.name.trim().isEmpty ? '未知书名' : first.name,
                        style: TextStyle(
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w700,
                          color: _titleColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      if (first.author.isNotEmpty || first.kind.isNotEmpty)
                        Text(
                          [
                            if (first.author.isNotEmpty) first.author,
                            if (first.kind.isNotEmpty) first.kind,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTheme.fontFootnote,
                            color: JellyTheme.textSecondary,
                          ),
                        ),
                      const SizedBox(height: 6),
                      // 来源标签（多源 = 换源入口，点卡片后会弹出选择）
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          ...g.items
                              .take(3)
                              .map(
                                (r) => Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: JellyTheme.primary.withValues(
                                      alpha: 0.12,
                                    ),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    r.source.name,
                                    style: TextStyle(
                                      fontSize: AppTheme.fontCaption,
                                      color: JellyTheme.primary,
                                    ),
                                  ),
                                ),
                              ),
                          if (g.items.length > 3)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: JellyTheme.primary.withValues(
                                  alpha: 0.08,
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '+${g.items.length - 3}',
                                style: TextStyle(
                                  fontSize: AppTheme.fontCaption,
                                  color: JellyTheme.primary,
                                ),
                              ),
                            ),
                        ],
                      ),
                      // 右下：最新章节 / 字数（搜索返回里本来就有，零额外请求）
                      if (first.lastChapter.isNotEmpty ||
                          first.wordCount.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Flexible(
                              child: Text(
                                first.lastChapter.isNotEmpty
                                    ? first.lastChapter
                                    : first.wordCount,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppTheme.fontCaption,
                                  color: JellyTheme.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 书源封面占位（无封面 / 加载失败时）——与漫画侧的卡片底色一致
  Widget _bookCoverPlaceholder() {
    return Container(
      color: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      child: Icon(
        Icons.menu_book_rounded,
        size: 30,
        color: JellyTheme.textSecondary,
      ),
    );
  }

  /// 书源结果**宫格卡片** —— 与漫画宫格（JellyComicCard）同款观感：
  /// 封面 3:4 + 书名（居中，1 行）+ 作者 + 来源数量角标。
  /// （用户 2026-10-07：书源也要宫格，一排 3/4/5 个）
  Widget _bookGridTile(_BookGroup g) {
    final first = g.items.first;
    return GestureDetector(
      onTap: () => _open(g),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  first.coverUrl.isEmpty
                      ? _bookCoverPlaceholder()
                      : CachedNetworkImage(
                          imageUrl: first.coverUrl,
                          fit: BoxFit.cover,
                          memCacheWidth: 300,
                          placeholder: (_, __) => _bookCoverPlaceholder(),
                          errorWidget: (_, __, ___) => _bookCoverPlaceholder(),
                        ),
                  // 左上角作者角标：透明灰底（用户 2026-10-12）
                  if (first.author.trim().isNotEmpty)
                    _authorBadge(first.author),
                  // 多源角标（>1 个来源才显示，提示可换源）
                  if (g.items.length > 1)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: JellyTheme.primary.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${g.items.length}源',
                          style: const TextStyle(
                            fontSize: AppTheme.fontCaption,
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          // 书名居中（与漫画/图书宫格一致）
          SizedBox(
            width: double.infinity,
            child: Text(
              first.name.trim().isEmpty ? '未知书名' : first.name,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTheme.fontFootnote,
                fontWeight: FontWeight.w600,
                color: _titleColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _open(_BookGroup g) async {
    // 单源直接进；多源先让用户选（这就是"换源"的入口）
    BookSourceResult chosen = g.items.first;
    if (g.items.length > 1) {
      final picked = await showModalBottomSheet<BookSourceResult>(
        context: context,
        backgroundColor: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 14),
              Text(
                '选择书源（${g.items.length} 个）',
                style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600,
                  color: _titleColor,
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: g.items
                      .map(
                        (r) => ListTile(
                          title: Text(
                            r.source.name,
                            style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              color: _titleColor,
                            ),
                          ),
                          subtitle: Text(
                            // 同名不同作者的书会合并到一张卡里，
                            // 选择面板必须显示作者才能区分
                            [
                              if (r.author.isNotEmpty) r.author,
                              if (r.lastChapter.isNotEmpty)
                                r.lastChapter
                              else if (r.wordCount.isNotEmpty)
                                r.wordCount
                              else
                                r.bookUrl,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppTheme.fontFootnote,
                              color: JellyTheme.textSecondary,
                            ),
                          ),
                          onTap: () => Navigator.pop(ctx, r),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      );
      if (picked == null) return;
      chosen = picked;
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookSourceDetailPage(result: chosen),
      ),
    );
  }
}

class _BookGroup {
  _BookGroup({required this.key, required this.items});
  final String key;
  final List<BookSourceResult> items;
}
