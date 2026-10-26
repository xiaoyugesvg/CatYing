// lib/rss/pages/rss_page.dart
//
// 「RSS」模块主页（底栏独立分类，用户 2026-10-15：直接加个 RSS 分类）。
//
// 结构对齐网页/程序模块：**顶栏左边是模块名，右边是操作**（源切换 / 刷新 / 管理），
// 下面是文章列表（封面 + 标题 + 来源·时间），点开进正文页。
//
// 一个源可能有多个分类（`sortUrl` 里 `名称::url`）⇒ 分类多的时候顶栏下面
// 出一条分类胶囊。

import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/ad_block_service.dart';
import 'package:tvbox/services/nav_feature_service.dart';
import 'package:tvbox/widgets/ad_block_bubble.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/card_action_sheet.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/rss/models/rss_article.dart';
import 'package:tvbox/rss/models/rss_source.dart';
import 'package:tvbox/rss/services/rss_extra.dart';
import 'package:tvbox/rss/services/rss_reader.dart';
import 'package:tvbox/rss/services/rss_store.dart';
import 'package:tvbox/rss/widgets/rss_login_sheet.dart';
import 'package:tvbox/rss/pages/rss_article_page.dart';
import 'package:tvbox/rss/pages/rss_manage_page.dart';
import 'package:tvbox/rss/pages/rss_source_edit_page.dart';

class RssPage extends StatefulWidget {
  const RssPage({super.key});

  @override
  State<RssPage> createState() => _RssPageState();
}

/// 文章列表的展示方式：列表（左图右文）/ 卡片（一行两个大图）
enum _ArticleView { list, card }

class _RssPageState extends State<RssPage> {
  RssStore get store => RssStore.instance;

  static const String _viewKey = 'rss_article_view';

  List<RssArticle> _articles = [];
  bool _loading = false;
  String _error = '';
  int _page = 1;
  int _channel = 0;
  _ArticleView _view = _ArticleView.list;

  /// 上一页算出的"下一页地址"（仅 `ruleNextPage` 型源用；空 = 到底了）。
  String _nextUrl = '';

  /// 已经加载过内容的源 id（换源要重新拉，只是排序/启用变了不用）
  String _loadedId = '';

  /// 本次请求的序号：防止"快速换源 / 连续刷新"时旧结果覆盖新结果。
  int _seq = 0;

  /// 正在加载的源 id（空 = 无请求在飞）。
  ///
  /// 为什么要单独记：用户 A→B→A 快速切换时，`_loadedId` 仍是 A，
  /// 只凭它判断会认为"已经加载好了、不用重载"，而 B 的在飞请求随后返回
  /// 并把列表写成 B 的内容（看起来就是"切回来又变成别的源"）。
  String _loadingId = '';

  /// ── 站点型源（Legado `singleUrl`）的**内嵌网页** ──────────────────
  ///
  /// 用户 2026-10-15：「我其实就想用这种订阅源」—— 这类源（源仓库 / Yiove /
  /// 使用文档 / 一键导入…）在 Legado 里就是**直接打开这个站**，本来没有文章
  /// 列表。所以这里不再去抓列表、也不再报"没抓到内容"，而是把网页**内嵌**
  /// 在 RSS 页里显示（顶栏的切换源 / 刷新照样可用，刷新 = 重载网页）。
  WebViewController? _web;
  String _webUrl = '';

  /// 抓完之后才发现"这个地址其实是个网页"（无列表规则 + 0 条文章 + 返回体不像
  /// feed）。用于 `singleUrl` 标记缺失时的兜底 —— 一样走内嵌网页，不再报
  /// "没有抓到内容"。
  bool _siteLike = false;

  /// 当前源的**分类列表**（`sortUrl` 是 `<js>` / `@js:` 规则时要异步求值，
  /// 不能直接用 `src.channels` 的静态文本解析）。
  List<RssChannel> _channels = const [];

  /// 内嵌网页的浏览历史状态（右侧竖排导航栏用）
  bool _webCanBack = false;
  bool _webCanForward = false;

  WebViewController _webFor(String url) {
    if (_web != null && _webUrl == url) return _web!;
    _webUrl = url;
    _webCanBack = false;
    _webCanForward = false;
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppTheme.backgroundPrimary)
      ..setNavigationDelegate(NavigationDelegate(
        // 去广告：站点型 RSS 源就是直接开网站，广告最多的一类
        onPageStarted: (u) => AdBlockService.instance.injectInto(_web!, u),
        onPageFinished: (u) {
          AdBlockService.instance.injectInto(_web!, u);
          _refreshWebNavState();
        },
      ));
    AdBlockService.attach(_web!);
    AdBlockService.instance.ensureLoaded();
    _web!.loadRequest(Uri.parse(url));
    return _web!;
  }

  Future<void> _refreshWebNavState() async {
    final c = _web;
    if (c == null || !mounted) return;
    try {
      final back = await c.canGoBack();
      final forward = await c.canGoForward();
      if (!mounted) return;
      if (back != _webCanBack || forward != _webCanForward) {
        setState(() {
          _webCanBack = back;
          _webCanForward = forward;
        });
      }
    } catch (_) {}
  }

  /// 站点型 RSS 的右侧竖排导航（上一页 / 下一页 / 刷新 / 回主页）。
  ///
  /// 内嵌网页点进二级页后原来没有返回入口，也回不到源站首页。
  Widget _webNavBar(RssSource src) {
    final c = _webFor(src.url);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _webNavBtn(
            Icons.arrow_back_ios_new_rounded,
            '上一页',
            _webCanBack,
            () async {
              if (await c.canGoBack()) await c.goBack();
            },
          ),
          _webNavBtn(
            Icons.arrow_forward_ios_rounded,
            '下一页',
            _webCanForward,
            () async {
              if (await c.canGoForward()) await c.goForward();
            },
          ),
          _webNavBtn(Icons.refresh_rounded, '刷新', true, () => c.reload()),
          Container(
            width: 20,
            height: 0.5,
            margin: const EdgeInsets.symmetric(vertical: 2),
            color: AppTheme.borderLight,
          ),
          _webNavBtn(
            Icons.home_rounded,
            '回到主页',
            true,
            () => c.loadRequest(Uri.parse(src.url)),
          ),
        ],
      ),
    );
  }

  Widget _webNavBtn(
    IconData icon,
    String tip,
    bool enabled,
    VoidCallback onTap,
  ) {
    final color = enabled
        ? AppTheme.textPrimary
        : AppTheme.textTertiary.withValues(alpha: 0.35);
    return Tooltip(
      message: tip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 38,
          height: 36,
          child: Icon(icon, size: 17, color: color),
        ),
      ),
    );
  }

  /// ── 懒启动（用户 2026-10-15：「RSS、网页以及海阔默认关闭」）──────────
  ///
  /// 本页是 `IndexedStack` 的第 9 个 child ⇒ **模块没开进底栏也会被 build**，
  /// `initState` 照跑。原来这里无条件 `_boot()`（读源仓库 + 立刻拉当前订阅的
  /// 文章列表）⇒ "关着"的模块也在启动时发网络请求。
  /// 现在只在**开关打开**时才开工，关着时只挂一个监听等它被打开。
  bool _started = false;
  Worker? _navWorker;
  bool get _tabEnabled =>
      NavFeatureService.instance.enabled.contains(NavFeature.rss);

  @override
  void initState() {
    super.initState();
    _restoreView();
    _loadReadIds();
    store.tick.addListener(_onStoreChanged);
    if (_tabEnabled) {
      _start();
    } else {
      _navWorker = ever(NavFeatureService.instance.enabled, (_) {
        if (!_tabEnabled || _started) return;
        _start();
        if (mounted) setState(() {});
      });
    }
  }

  // 定时静默刷新（Legado 的"定时更新"）：每 30 分钟检查一次当前源
  Timer? _silentTimer;

  void _start() {
    if (_started) return;
    _started = true;
    _boot();
    _silentTimer?.cancel();
    _silentTimer = Timer.periodic(const Duration(minutes: 30), (_) async {
      if (!mounted || !_started || _loading) return;
      final s = store.current;
      if (s == null || s.isSiteOnly) return;
      if (await RssExtra.isStale(s)) {
        await _load(append: false, fresh: true);
      }
    });
  }

  @override
  void dispose() {
    _silentTimer?.cancel();
    store.tick.removeListener(_onStoreChanged);
    _navWorker?.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    if (!store.loaded) await store.load();
    if (!mounted) return;
    _reload();
  }

  void _onStoreChanged() {
    // 模块没开 ⇒ 不干活（否则"关着"的模块也会因为仓库变更去发请求）
    if (!mounted || !_started) return;
    final cur = store.current;
    if (cur == null) {
      // 源被全部删除/禁用：作废在飞请求，避免它回来又把列表写出来
      _seq++;
      _loadingId = '';
      setState(() {
        _articles = [];
        _error = '';
        _loading = false;
        _loadedId = '';
        _nextUrl = '';
        _siteLike = false;
        _channels = const [];
      });
      return;
    }
    if (cur.id != _loadedId ||
        (_loadingId.isNotEmpty && _loadingId != cur.id)) {
      _channel = 0;
      _reload();
    } else {
      setState(() {});
    }
  }

  void _reload() {
    final src = store.current;
    if (src == null) return;
    // `_siteLike` 是**上一个载入的源**的结论（抓完才发现"没规则 + 0 条 + 不像 feed"），
    // 换源时必须丢掉，否则新源要么不加载列表、要么被旧网页顶替。
    final sameAsLoaded = src.id == _loadedId;
    // 站点型源：刷新 = 重载内嵌网页
    if (src.isSiteOnly || (sameAsLoaded && _siteLike)) {
      // ⚠️ 只有**和当前内嵌网页同址**才叫"刷新"。换源/首次进入时原来只调
      //   `_web?.reload()`：从普通源切到站点型源时 `_web` 还是 null ⇒ 什么都不
      //   发生、界面也不重建（顶栏源名和内容都停在旧源上），用户看到的就是
      //   "切换不生效，重启软件才行"（重启后 `_siteLike`/`_web` 归零才走对路）。
      if (_web != null && _webUrl == src.url) {
        _web!.reload();
        return;
      }
      // 换到站点型源：作废在飞的列表请求，否则旧源的响应回来会写乱状态
      _seq++;
      _loadingId = '';
      setState(() {
        _siteLike = false;
        _loadedId = src.id;
      });
      return;
    }
    if (!sameAsLoaded) _siteLike = false;
    _reloadAsync();
  }

  Future<void> _reloadAsync() async {
    // `sortUrl` 可能是**规则**（`<js>` / `@js:`），要先跑规则才知道有哪些分类
    final seq = ++_seq; // 与 _load 共用同一序号：分类与列表必须成对是最新那次
    await _loadChannels(seq: seq);
    if (!mounted || seq != _seq) return;
    _page = 1;
    _nextUrl = '';
    // 用户主动刷新 ⇒ 绕过 `cacheFirst` 的缓存
    _load(append: false, fresh: true);
  }

  /// 求分类列表（纯文本直接拆；`<js>` / `@js:` 型走规则引擎求值）。
  ///
  /// ⚠️ 求值是异步的（跑 JS 规则）⇒ 快速换源时旧分类可能**后到**并盖住新源的分类。
  /// 这里的"是否已过期"由调用方在 await 之后用 `_seq` 再判一次（见 [_reloadAsync]
  /// 与 [_onStoreChanged]）。
  Future<void> _loadChannels({int? seq}) async {
    final src = store.current;
    if (src == null) {
      if (mounted) setState(() => _channels = const []);
      return;
    }
    if (src.isSiteOnly) {
      if (mounted) setState(() => _channels = const []);
      return;
    }
    final chs = await RssReader.loadChannels(src);
    // 求值是异步的：期间又换源/刷新过 ⇒ 这次结果作废（否则旧源的分类会盖住新的）
    if (!mounted || (seq != null && seq != _seq)) return;
    setState(() {
      _channels = chs;
      // 换源后分类下标可能越界
      if (_channel >= chs.length) _channel = 0;
    });
  }

  Future<void> _load({required bool append, bool fresh = false}) async {
    final src = store.current;
    if (src == null) return;
    // 站点型源不抓文章列表 —— 直接内嵌网页（见 [_webFor]）
    if (src.isSiteOnly) {
      // ⚠️ 也要占一个序号：否则"在飞的旧请求"回来时仍能通过 my == _seq 校验，
      //    把上一个源的列表写进这个站点型源里
      _seq++;
      _loadingId = '';
      setState(() {
        _articles = [];
        _error = '';
        _nextUrl = '';
        _siteLike = false;
        _loadedId = src.id;
        _loading = false;
      });
      return;
    }
    final my = ++_seq;
    _loadingId = src.id;
    final chs0 = _channels.isNotEmpty ? _channels : src.channels;
    final ch0 = chs0[_channel.clamp(0, chs0.length - 1)];
    // 离线缓存优先：首屏立刻有内容，再静默刷新（Legado 的"缓存优先"）
    if (!append && !fresh) {
      final cached = await RssExtra.readCache(src, ch0.url);
      if (cached != null && mounted && my == _seq) {
        setState(() {
          _articles = cached;
          _loadedId = src.id;
          _loading = false;
          _error = '';
        });
      }
    }
    setState(() {
      _loading = true;
      if (!append) {
        _error = '';
        if (_articles.isEmpty) _siteLike = false;
      }
    });
    try {
      final chs = _channels.isNotEmpty ? _channels : src.channels;
      final ch = chs[_channel.clamp(0, chs.length - 1)];
      // append 时用上一页算出的"下一页地址"接力（ruleNextPage 型源）
      final res = await RssReader.fetchArticles(
        src,
        channel: ch,
        page: _page,
        pageUrl: append ? _nextUrl : null,
        ignoreCache: fresh,
      );
      if (!mounted || my != _seq) return;
      final list = res.articles;
      // 抓成功就更新离线缓存（失败时保留旧缓存，断网也能看）
      if (list.isNotEmpty) {
        unawaited(RssExtra.writeCache(src, ch.url, list));
      }
      setState(() {
        _articles = append ? [..._articles, ...list] : list;
        _nextUrl = res.nextUrl;
        _siteLike = res.siteLike;
        _loadedId = src.id;
        _error = list.isEmpty ? '没有抓到文章（源可能失效了，可到「RSS 管理」里换一个）' : '';
      });
    } catch (e) {
      if (!mounted || my != _seq) return;
      // 有缓存时不拿错误盖掉列表：提示一句，内容照常可读
      setState(() {
        _error = _articles.isEmpty
            ? '抓取失败：${e.toString().split('\n').first}'
            : '';
      });
      if (_articles.isNotEmpty) {
        AppToast.message('刷新失败，正在显示离线缓存');
      }
    } finally {
      if (mounted && my == _seq) {
        _loadingId = '';
        setState(() => _loading = false);
      }
    }
  }

  bool get _canLoadMore {
    final src = store.current;
    if (src == null || _articles.isEmpty) return false;
    // 规则接力翻页：上一页算出了"下一页地址"就还能继续
    if (_nextUrl.isNotEmpty) return true;
    // 行内模板翻页：地址里必须真有引用 page 的 {{…}} 才算
    //
    // ⚠️ 必须放在 ruleNextPage 判断**之前**：不少源（如 XAnime）的
    // `ruleNextPage` 写了 `page`（实际取不到值），但分类地址本身是
    // `/page/{{page}}/` —— 以前被 ruleNextPage 非空直接判成"到底了"，
    // 上拉永远不加页。
    final chs = _channels.isNotEmpty ? _channels : src.channels;
    final ch = chs[_channel.clamp(0, chs.length - 1)];
    if (RssReader.isPagedUrl(ch.url)) return true;
    // 配了 ruleNextPage 却没算出下一页地址 ⇒ 到底了（该规则里没有 {{page}}）
    if ((src.ruleNextPage ?? '').trim().isNotEmpty) return false;
    return false;
  }

  void _openManage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RssManagePage()),
    );
  }

  /// 顶栏动作按钮：**圆形浅底**（与影视首页右上角 / 搜索源面板右上角同款）。
  ///
  /// 之前是无底色的裸图标（视觉上"飘"在顶栏里，用户 2026-10-15：「顶栏太丑了」）；
  /// 现在统一成 30×30 圆底 + 15 号图标，和影视模块完全一致。
  Widget _topIcon(IconData icon, String tooltip, VoidCallback? onTap) =>
      Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: AppTheme.backgroundTertiary,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: 15,
              color: onTap == null
                  ? AppTheme.textTertiary
                  : AppTheme.textSecondary,
            ),
          ),
        ),
      );

  /// 已读集合（Legado 语义：点开即已读）+ 源内搜索状态
  Set<String> _read = {};
  String _searchKw = '';
  List<RssArticle>? _preSearch;

  /// 当前列表的未读数
  int get _unreadCount =>
      _articles.where((a) => !_read.contains(RssExtra.articleKey(a))).length;

  Future<void> _loadReadIds() async {
    final s = await RssExtra.readIds();
    if (mounted) setState(() => _read = s);
  }

  /// 打开文章：先落"已读"，再进正文页。
  Future<void> _openArticle(RssArticle a, RssSource src) async {
    final k = RssExtra.articleKey(a);
    if (!_read.contains(k)) {
      unawaited(RssExtra.markRead(k));
      setState(() => _read.add(k));
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RssArticlePage(source: src, article: a),
      ),
    );
  }

  /// 源内搜索：源配了 `searchUrl` 走远端，否则退回当前列表的标题过滤。
  Future<void> _openSearch() async {
    final src = store.current;
    if (src == null) return;
    final c = TextEditingController();
    final kw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('搜索订阅内容'),
        content: TextField(
          controller: c,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: '输入关键词',
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('搜索'),
          ),
        ],
      ),
    );
    final key = (kw ?? '').trim();
    if (key.isEmpty || !mounted) return;
    if (src.searchUrl.trim().isEmpty) {
      // 没有 searchUrl：只在已抓到的列表里过滤，不清空原列表
      final old = _preSearch ??= List<RssArticle>.from(_articles);
      final hit = old
          .where((a) =>
              a.title.contains(key) || a.description.contains(key))
          .toList();
      setState(() {
        _searchKw = key;
        _articles = hit;
        _error = hit.isEmpty ? '当前列表里没有匹配「$key」的文章' : '';
      });
      return;
    }
    setState(() {
      _loading = true;
      _searchKw = key;
      _preSearch = List<RssArticle>.from(_articles);
    });
    try {
      final list = await RssExtra.search(src, key);
      if (!mounted) return;
      if (list == null) {
        // 源内搜索不可用（站点型 / 403 / 无结果）→ 退回当前列表标题过滤，
        // 与"源没配 searchUrl"那条分支保持一致
        final old = _preSearch ??= List<RssArticle>.from(_articles);
        final hit = old
            .where((a) =>
                a.title.contains(key) || a.description.contains(key))
            .toList();
        setState(() {
          _searchKw = key;
          _articles = hit;
          _loading = false;
          _error = hit.isEmpty ? '当前列表里没有匹配「$key」的文章' : '';
        });
        return;
      }
      setState(() {
        _articles = list;
        _loading = false;
        _error = list.isEmpty ? '没搜到「$key」' : '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '搜索失败：${e.toString().split('\n').first}';
      });
    }
  }

  void _clearSearch() {
    setState(() {
      _searchKw = '';
      _articles = _preSearch ?? _articles;
      _preSearch = null;
      _error = '';
    });
    _reload();
  }

  Future<void> _restoreView() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final v = sp.getInt(_viewKey);
      if (v != null && v >= 0 && v < _ArticleView.values.length && mounted) {
        setState(() => _view = _ArticleView.values[v]);
      }
    } catch (_) {}
  }

  Future<void> _toggleView() async {
    final next =
        _view == _ArticleView.list ? _ArticleView.card : _ArticleView.list;
    setState(() => _view = next);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_viewKey, next.index);
    } catch (_) {}
  }

  /// 登录 / 源站设置 —— 按源的 `loginUi` 动态生成表单，
  /// 保存后调源自己的 jsLib 钩子（`upLoginData`）并重载分类与列表。
  Future<void> _openLogin() async {
    final src = store.current;
    if (src == null) return;
    final fields = RssLoginField.parse(src.loginUi);
    if (fields.isEmpty) {
      AppToast.message('这个源没有可配置的登录项');
      return;
    }
    final v = await showRssLoginSheet(
      context,
      title: src.name,
      fields: fields,
      initial: RssReader.loginInfo(src),
    );
    if (v == null || !mounted) return;
    await RssReader.saveLogin(src, v);
    if (!mounted) return;
    AppToast.message('已保存，正在按新设置重载');
    _reload();
  }

  /// 切换订阅源 —— 版式**对齐影视模块的 `SourceSwitchSheet`**
  ///（用户 2026-10-15：「RSS 这个顶栏切换参考影视撒」）：
  /// 约 0.4 屏高、标题 + 定位 + 网格/列表切换、搜索胶囊、2 列卡片。
  Future<void> _pickSource() async {
    final list = store.sources.where((e) => e.enabled).toList();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // ⚠️ 必须套 kbSheet：否则点搜索框时键盘会直接盖住整个面板
      //   （与影视「搜索源」面板一致的处理）
      builder: (ctx) => kbSheet(
        _RssSourceSwitchSheet(
          sources: list,
          selectedId: store.selectedId,
          onPick: (id) {
            if (id != store.selectedId) store.select(id);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 模块没开进底栏 ⇒ 一行都不渲染（也保证上面那套懒启动不被绕过）
    if (!_started) return const SizedBox.shrink();
    final topInset = MediaQuery.paddingOf(context).top;
    final src = store.current;
    final channels = _channels;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: Column(
        children: [
          SizedBox(height: topInset),
          SizedBox(
            height: 46,
            child: Padding(
              // 左 16 与页面内容对齐；右侧只留 6 ⇒ 圆形按钮贴近屏幕边
              //（保留用户 2026-10-15「图标要到边」的要求）
              padding: const EdgeInsets.fromLTRB(16, 0, 6, 0),
              child: Row(
                children: [
                  // 左：Logo + 源名（**点它换源**）—— 与影视首页顶栏同款
                  //（用户 2026-10-15：「RSS 这个顶栏切换参考影视」）
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _pickSource,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _RssLogo(),
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 120),
                          child: Text(
                            src?.name ?? 'RSS',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: AppTheme.fontHeadline,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        // 换源/刷新中：箭头换成小转圈，点下去立刻有反馈
                        if (_loading)
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.6,
                              color: AppTheme.accentColor,
                            ),
                          )
                        else
                          Icon(Icons.expand_more_rounded,
                              size: 16, color: AppTheme.textTertiary),
                        // 未读数：当前列表里还没点开过的条数
                        if (_unreadCount > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE5484D),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Text(
                              '$_unreadCount',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Spacer(),
                  // 源配了 `loginUi` 才出「登录 / 源站设置」（如「影视聚合(资源站)」
                  // 靠它切 27 个影视源站）
                  if ((src?.loginUi ?? '').trim().isNotEmpty) ...[
                    _topIcon(Icons.key_rounded, '登录 / 源站设置', _openLogin),
                    const SizedBox(width: 8),
                  ],
                  _topIcon(Icons.search_rounded, '搜索', _openSearch),
                  const SizedBox(width: 8),
                  _topIcon(Icons.refresh_rounded, '刷新', _loading ? null : _reload),
                  const SizedBox(width: 8),
                  _topIcon(
                    _view == _ArticleView.card
                        ? Icons.view_list_rounded
                        : Icons.grid_view_rounded,
                    _view == _ArticleView.card ? '切换为列表视图' : '切换为卡片视图',
                    _toggleView,
                  ),
                  const SizedBox(width: 8),
                  _topIcon(Icons.tune_rounded, 'RSS 管理', _openManage),
                ],
              ),
            ),
          ),
          if (channels.length > 1)
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: channels.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (c, i) {
                  final on = i == _channel;
                  return GestureDetector(
                    onTap: () {
                      if (_channel == i) return;
                      // 只换分类 ⇒ 不用重算分类表（`sortUrl` 的 JS 可能很贵）
                      setState(() => _channel = i);
                      _page = 1;
                      _nextUrl = '';
                      _load(append: false);
                    },
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: on
                            ? AppTheme.accentColor
                            : AppTheme.backgroundTertiary,
                        borderRadius: BorderRadius.circular(20),
                        border: on
                            ? null
                            : Border.all(
                                color: AppTheme.borderLight, width: 0.5),
                      ),
                      child: Text(
                        channels[i].title,
                        style: TextStyle(
                          color: on ? Colors.white : AppTheme.textSecondary,
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
          // 搜索中：给一条可清除的提示（否则用户不知道列表为什么变短了）
          if (_searchKw.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Row(
                children: [
                  Icon(Icons.search_rounded,
                      size: 14, color: AppTheme.textTertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '搜索「$_searchKw」',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: _clearSearch,
                    child: Text(
                      '退出搜索',
                      style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: AppTheme.accentColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(child: _body(src)),
        ],
      ),
    );
  }

  Widget _body(RssSource? src) {
    if (src == null) {
      return _emptyView(
        icon: Icons.rss_feed,
        title: '还没有订阅源',
        hint: '到「RSS 管理」导入订阅链接、OPML 或本地文件',
        btnText: '去 RSS 管理',
        onBtn: _openManage,
      );
    }
    // 站点型源：**直接内嵌网页**。两条判定：
    //   · `src.isSiteOnly` —— Legado 的 `singleUrl` 标记（源仓库 / Yiove /
    //     使用文档 / 一键导入 都是这种）；
    //   · `_siteLike` —— 抓完发现"没规则 + 0 条 + 不像 feed"的兜底（标记缺失
    //     时也能认出来）。
    // 抓列表只会得到"没有抓到内容"，那才是真正的不兼容 ✗。
    if (src.isSiteOnly || _siteLike) {
      return Stack(
        children: [
          Positioned.fill(child: WebViewWidget(controller: _webFor(src.url))),
          // 右侧竖排浏览器导航：上一页 / 下一页 / 刷新 / 回主页
          Positioned(
            right: 8,
            top: 0,
            bottom: 0,
            child: Align(
              alignment: Alignment.centerRight,
              child: _webNavBar(src),
            ),
          ),
          // 去广告悬浮球：点它 → 点页面上的广告 → 存规则（重启后仍生效）
          ListenableBuilder(
            listenable: AdBlockService.instance,
            builder: (_, __) => AdBlockService.instance.showBubble
                ? AdBlockBubble(
                    controller: _webFor(src.url),
                    pageUrl: src.url,
                    margin: const EdgeInsets.only(right: 12, bottom: 96),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      );
    }
    if (_loading && _articles.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_articles.isEmpty) {
      return RefreshIndicator(
        onRefresh: () async => _reload(),
        color: AppTheme.accentColor,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 90),
            _emptyView(
              icon: _error.isEmpty
                  ? Icons.inbox_rounded
                  : Icons.error_outline_rounded,
              title: _error.isEmpty ? '这个源暂时没有文章' : '没抓到内容',
              hint: _error.isEmpty ? '下拉可以刷新，或换一个订阅源' : _error,
              btnText: '换一个订阅源',
              onBtn: _pickSource,
              // 抓不到时的兜底出口：直接内嵌打开源站网页
              // （用户 2026-10-20：「RSS 里面好多错误，兼容性不够」）
              btn2Text: '用网页打开',
              onBtn2: () => setState(() => _siteLike = true),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      color: AppTheme.accentColor,
      child: _view == _ArticleView.card
          ? _cardList(src)
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 110),
              itemCount: _articles.length + 1,
              itemBuilder: (c, i) {
                if (i == _articles.length) return _footer();
                return _articleRow(_articles[i], src);
              },
            ),
    );
  }

  /// 卡片视图：一行两个（封面在上、标题两行），与「RSS 管理」的卡片观感一致。
  Widget _cardList(RssSource src) {
    final rows = (_articles.length + 1) ~/ 2;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 110),
      itemCount: rows + 1,
      itemBuilder: (c, i) {
        if (i == rows) return _footer();
        final left = _articles[i * 2];
        final right =
            i * 2 + 1 < _articles.length ? _articles[i * 2 + 1] : null;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SizedBox(
            height: 188,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _articleCard(left, src)),
                const SizedBox(width: 8),
                Expanded(
                  child: right == null
                      ? const SizedBox.shrink()
                      : _articleCard(right, src),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _articleCard(RssArticle a, RssSource src) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: InkWell(
        onTap: () => _openArticle(a, src),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 96,
              child: a.hasImage
                  ? CachedNetworkImage(
                      imageUrl: a.image,
                      fit: BoxFit.cover,
                      placeholder: (_, __) =>
                          Container(color: AppTheme.backgroundTertiary),
                      errorBuilder: (_, __, ___) => _coverPlaceholder(),
                    )
                  : _coverPlaceholder(),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(9, 8, 9, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!_read.contains(RssExtra.articleKey(a)))
                          Padding(
                            padding: const EdgeInsets.only(top: 5, right: 5),
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: Color(0xFFE5484D),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        Expanded(
                          child: Text(
                            a.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      [a.sourceName, a.pubDate]
                          .where((e) => e.trim().isNotEmpty)
                          .join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
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
  }

  Widget _coverPlaceholder() => Container(
        color: AppTheme.backgroundTertiary,
        alignment: Alignment.center,
        child: Icon(Icons.rss_feed_rounded,
            size: 26, color: AppTheme.textTertiary),
      );

  /// 统一空态：图标 + 标题 + 说明 + （可选）按钮
  Widget _emptyView({
    required IconData icon,
    required String title,
    required String hint,
    String? btnText,
    VoidCallback? onBtn,
    String? btn2Text,
    VoidCallback? onBtn2,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 48,
                color: AppTheme.textTertiary.withValues(alpha: 0.55)),
            const SizedBox(height: 20),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: AppTheme.fontTitle3,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary)),
            const SizedBox(height: 8),
            Text(hint,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    height: 1.6,
                    color: AppTheme.textTertiary)),
            if (btnText != null && onBtn != null) ...[
              const SizedBox(height: 24),
              FilledButton(
                onPressed: onBtn,
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 12)),
                child: Text(btnText),
              ),
            ],
            if (btn2Text != null && onBtn2 != null) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onBtn2, child: Text(btn2Text)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _footer() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
            child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (!_canLoadMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text('— 已经到底了 —',
              style: TextStyle(
                  color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: TextButton(
          onPressed: () {
            _page += 1;
            _load(append: true);
          },
          child: const Text('加载更多'),
        ),
      ),
    );
  }

  /// 一条文章 = 一张卡片（与「RSS 管理」的源卡片同一套圆角/描边）
  Widget _articleRow(RssArticle a, RssSource src) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openArticle(a, src),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (a.hasImage)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 86,
                    height: 62,
                    child: CachedNetworkImage(
                      imageUrl: a.image,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              if (a.hasImage) const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        // 已读：颜色压灰；未读：正常主色 + 加粗
                        color: _read.contains(RssExtra.articleKey(a))
                            ? AppTheme.textTertiary
                            : AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: _read.contains(RssExtra.articleKey(a))
                            ? FontWeight.w400
                            : FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                    if (a.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        a.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption,
                          height: 1.4,
                        ),
                      ),
                    ],
                    const SizedBox(height: 5),
                    Text(
                      [a.sourceName, a.pubDate]
                          .where((e) => e.trim().isNotEmpty)
                          .join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// RSS 顶栏 Logo —— 与影视首页的 `_CatPawLogo` **同款造型**
///（34×34 圆角渐变方块 + 同色柔光），只是图标换成 RSS。
///
/// 用户 2026-10-15：「RSS 这个顶栏切换参考影视撒，顶栏太丑了」⇒ 顶栏左侧
/// 统一成"Logo + 加粗源名（点击换源）"，和影视首屏的视觉语言一致。
class _RssLogo extends StatelessWidget {
  const _RssLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppTheme.accentColor.withValues(alpha: 0.65),
            AppTheme.accentColor,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: AppTheme.accentColor.withValues(alpha: 0.35),
            blurRadius: 10,
          ),
        ],
      ),
      child: const Icon(Icons.rss_feed, color: Colors.white, size: 20),
    );
  }
}

/// 订阅源切换面板 —— **照影视模块 `SourceSwitchSheet` 的版式做**：
///   拖拽条 → 「标题 + 定位 + 网格/列表切换」→ 搜索胶囊 →
///   2 列卡片（3.4 纵横比）/ 单列行
///
/// 用户 2026-10-15：「RSS 这个顶栏切换参考影视撒，顶栏太丑了」。
/// 用户 2026-10-20：去掉底部「RSS 管理」入口 —— 它会遮住下面的源卡片。
class _RssSourceSwitchSheet extends StatefulWidget {
  const _RssSourceSwitchSheet({
    required this.sources,
    required this.selectedId,
    required this.onPick,
  });

  final List<RssSource> sources;
  final String selectedId;
  final ValueChanged<String> onPick;

  @override
  State<_RssSourceSwitchSheet> createState() => _RssSourceSwitchSheetState();
}

class _RssSourceSwitchSheetState extends State<_RssSourceSwitchSheet> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  String _kw = '';

  /// false=单列列表 / true=双排网格（默认双排，与影视面板一致）
  bool _grid = true;

  /// 面板内的源列表 —— 删除/排序后要原地生效，所以用可变副本
  late final List<RssSource> _items = List.of(widget.sources);

  /// 多选模式（长按菜单 / 顶栏 checklist 进入）
  bool _selectMode = false;
  final Set<String> _picked = <String>{};

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<RssSource> get _list {
    if (_kw.isEmpty) return _items;
    final k = _kw.toLowerCase();
    return _items.where((s) => s.name.toLowerCase().contains(k)).toList();
  }

  String get _selectedId => widget.selectedId;

  // ── 多选 ──────────────────────────────────────────────

  void _togglePick(String id) {
    setState(() {
      if (!_picked.remove(id)) _picked.add(id);
      if (_picked.isEmpty) _selectMode = false;
    });
  }

  void _enterSelectMode([String? first]) {
    setState(() {
      _selectMode = true;
      _picked.clear();
      if (first != null) _picked.add(first);
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _picked.clear();
    });
  }

  // ── 长按菜单（卡片式，一行两个）：分享 / 删除 / 分组 / 多选 ──

  Future<void> _onLongPress(RssSource s) async {
    if (_selectMode) {
      _togglePick(s.id);
      return;
    }
    await showCardActions(
      context,
      title: s.name,
      subtitle: s.url,
      actions: [
        CardAction(
          icon: Icons.tune_rounded,
          label: '编辑',
          onTap: () async {
            final ok = await Navigator.push<bool>(
              context,
              MaterialPageRoute(
                builder: (_) => RssSourceEditPage(source: s),
              ),
            );
            if (ok == true && mounted) {
              // 面板里的 _items 是打开时的快照 ⇒ 编辑后原地替换，避免还显示旧名字
              final updated = RssStore.instance.byId(s.id);
              final i = _items.indexWhere((e) => e.id == s.id);
              if (updated != null && i >= 0) {
                setState(() => _items[i] = updated);
              }
            }
          },
        ),
        CardAction(
          icon: Icons.ios_share_rounded,
          label: '分享',
          onTap: () => _share([s]),
        ),
        CardAction(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          danger: true,
          onTap: () => _confirmDelete([s]),
        ),
        CardAction(
          icon: Icons.folder_outlined,
          label: '分组',
          onTap: () => _pickGroup(s),
        ),
        CardAction(
          icon: Icons.checklist_rounded,
          label: '多选',
          onTap: () => _enterSelectMode(s.id),
        ),
      ],
    );
  }

  /// 分享 = 复制 Legado RSS 源 JSON（对方可直接导入）
  Future<void> _share(List<RssSource> list) async {
    if (list.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: encodeRssSources(list)));
    AppToast.message(list.length > 1 ? '已复制 ${list.length} 个源' : '已复制源');
  }

  Future<void> _confirmDelete(List<RssSource> targets) async {
    if (targets.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          targets.length > 1 ? '删除 ${targets.length} 个源？' : '删除这个源？',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: Text(
          targets.length > 1
              ? '删除后需要重新导入才能恢复。'
              : '「${targets.first.name}」删除后需要重新导入才能恢复。',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontBody,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              '删除',
              style: TextStyle(color: Colors.redAccent.shade100),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final ids = targets.map((e) => e.id).toSet();
    await RssStore.instance.removeAll(ids);
    if (!mounted) return;
    setState(() {
      _items.removeWhere((e) => ids.contains(e.id));
      _picked.removeAll(ids);
      if (_picked.isEmpty) _selectMode = false;
    });
  }

  Future<void> _pickGroup(RssSource s) async {
    final groups = <String>{
      for (final e in _items)
        if (e.group.trim().isNotEmpty) e.group.trim(),
      if (s.group.trim().isNotEmpty) s.group.trim(),
    }.toList()..sort();
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '移动到分组',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _groupChipOf(
                        '未分组',
                        s.group.trim().isEmpty,
                        () => Navigator.of(ctx).pop(''),
                      ),
                      for (final g in groups)
                        _groupChipOf(
                          g,
                          s.group.trim() == g,
                          () => Navigator.of(ctx).pop(g),
                        ),
                      _groupChipOf('＋ 新建', false, () => Navigator.of(ctx).pop('__new__')),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    var target = picked;
    if (target == '__new__') {
      final name = await _askGroupName();
      if (name == null || name.isEmpty || !mounted) return;
      target = name;
    }
    await RssStore.instance.setGroup(s.id, target);
    if (!mounted) return;
    setState(() {
      final i = _items.indexWhere((e) => e.id == s.id);
      if (i >= 0) _items[i] = _items[i].copyWith(group: target);
    });
  }

  Future<String?> _askGroupName() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: Text('新建分组', style: TextStyle(color: AppTheme.textPrimary)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: AppTheme.textPrimary),
          decoration: const InputDecoration(hintText: '分组名称'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return (name ?? '').trim();
  }

  Widget _groupChipOf(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppTheme.accentColor : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderLight, width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : AppTheme.textSecondary,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// 拖动排序：只重排可见项占的坑位并落盘
  Future<void> _moveItem(String fromId, String toId) async {
    if (fromId == toId) return;
    final from = _items.indexWhere((e) => e.id == fromId);
    final to = _items.indexWhere((e) => e.id == toId);
    if (from < 0 || to < 0) return;
    final item = _items.removeAt(from);
    _items.insert(to, item);
    setState(() {});
    await RssStore.instance.reorderWithin(_items.map((e) => e.id).toList());
  }

  /// 定位到当前选中的源（与影视面板同款功能）。
  ///
  /// 用**算术**算行偏移，不用 `ensureVisible` —— 选中的源常在很下面、
  /// 还没被 build，那时拿不到 context。
  void _locate() {
    final list = _list;
    final i = list.indexWhere((s) => s.id == widget.selectedId);
    if (i < 0 || !_scroll.hasClients) return;
    final w = MediaQuery.of(context).size.width;
    // 与下面网格参数保持一致：2 列 / 间距 10 / 纵横比 3.4 / 行距 8
    final rowH = _grid ? ((w - 32 - 10) / 2) / 3.4 + 8 : 52.0;
    final offset = _grid ? (i ~/ 2) * rowH : i * rowH;
    final pos = _scroll.position;
    _scroll.animateTo(
      offset.clamp(0.0, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppTheme.backgroundTertiary,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 15, color: AppTheme.textSecondary),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final list = _list;
    return Container(
      height: (h * 0.4).clamp(h * 0.34, h * 0.48),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 10, bottom: 4),
              child: SheetHandle(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Text('切换订阅源',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (!_selectMode) ...[
                    _circleBtn(Icons.checklist_rounded, _enterSelectMode),
                    const SizedBox(width: 8),
                    _circleBtn(Icons.my_location_rounded, _locate),
                    const SizedBox(width: 8),
                  ],
                  _circleBtn(
                    _grid ? Icons.view_list_outlined : Icons.grid_view_outlined,
                    () => setState(() => _grid = !_grid),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  // 与影视「搜索源」面板一致：透明底 + 细边胶囊，
                  // 不再用灰色块（用户要求整体统一）
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(
                    color: AppTheme.borderLight,
                    width: 0.5,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search,
                        size: 14, color: AppTheme.textTertiary),
                    const SizedBox(width: 5),
                    Expanded(
                      child: TextField(
                        controller: _search,
                        onChanged: (v) => setState(() => _kw = v.trim()),
                        textAlignVertical: TextAlignVertical.center,
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textPrimary),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 6),
                          hintText: '搜索订阅源…',
                          hintStyle: TextStyle(
                              fontSize: 12, color: AppTheme.textTertiary),
                        ),
                      ),
                    ),
                    if (_kw.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          _search.clear();
                          setState(() => _kw = '');
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(5),
                          child: Icon(Icons.cancel,
                              size: 13, color: AppTheme.textTertiary),
                        ),
                      )
                    else
                      const SizedBox(width: 6),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: list.isEmpty
                  ? Center(
                      child: Text('未找到匹配的订阅源',
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: AppTheme.textTertiary)),
                    )
                  : ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      children: [
                        if (_grid)
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 10,
                              childAspectRatio: 3.4,
                            ),
                            itemCount: list.length,
                            itemBuilder: (c, i) => DragTarget<String>(
                              onWillAcceptWithDetails: (d) =>
                                  d.data != list[i].id,
                              onAcceptWithDetails: (d) =>
                                  _moveItem(d.data, list[i].id),
                              builder: (_, candidate, _) {
                                final tile = _tile(list[i]);
                                if (candidate.isEmpty) return tile;
                                return DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: AppTheme.accentColor.withValues(
                                        alpha: 0.6,
                                      ),
                                      width: 1.4,
                                    ),
                                  ),
                                  child: tile,
                                );
                              },
                            ),
                          )
                        else
                          for (final s in list)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: DragTarget<String>(
                                onWillAcceptWithDetails: (d) => d.data != s.id,
                                onAcceptWithDetails: (d) =>
                                    _moveItem(d.data, s.id),
                                builder: (_, candidate, _) {
                                  final row = _row(s);
                                  if (candidate.isEmpty) return row;
                                  return DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: AppTheme.accentColor.withValues(
                                          alpha: 0.6,
                                        ),
                                        width: 1.4,
                                      ),
                                    ),
                                    child: row,
                                  );
                                },
                              ),
                            ),
                      ],
                    ),
            ),
            // 多选底栏：全选 / 已选数 / 分享 / 删除 / 完成
            if (_selectMode) _selectBar(),
          ],
        ),
      ),
    );
  }

  void _pick(RssSource s) {
    if (_selectMode) {
      _togglePick(s.id);
      return;
    }
    Navigator.pop(context);
    widget.onPick(s.id);
  }

  /// 多选底栏：全选 / 已选数 / 分享 / 删除 / 完成
  Widget _selectBar() {
    final list = _list;
    final allPicked =
        list.isNotEmpty && list.every((e) => _picked.contains(e.id));
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppTheme.borderLight, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: () => setState(() {
              if (allPicked) {
                _picked.clear();
                _selectMode = false;
              } else {
                _picked.addAll(list.map((e) => e.id));
              }
            }),
            child: Text(
              allPicked ? '取消全选' : '全选',
              style: TextStyle(
                color: AppTheme.accentOnSurface,
                fontSize: AppTheme.fontSubhead,
              ),
            ),
          ),
          Text(
            '已选 ${_picked.length}',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontSubhead,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: '分享',
            onPressed: _picked.isEmpty ? null : _sharePicked,
            icon: Icon(
              Icons.ios_share_rounded,
              size: 20,
              color: _picked.isEmpty
                  ? AppTheme.textTertiary
                  : AppTheme.accentOnSurface,
            ),
          ),
          IconButton(
            tooltip: '删除',
            onPressed: _picked.isEmpty ? null : _deletePicked,
            icon: Icon(
              Icons.delete_outline_rounded,
              size: 20,
              color: _picked.isEmpty
                  ? AppTheme.textTertiary
                  : Colors.redAccent.shade100,
            ),
          ),
          TextButton(
            onPressed: _exitSelectMode,
            child: Text(
              '完成',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sharePicked() async {
    final targets = _items.where((e) => _picked.contains(e.id)).toList();
    await _share(targets);
  }

  Future<void> _deletePicked() async {
    final targets = _items.where((e) => _picked.contains(e.id)).toList();
    await _confirmDelete(targets);
  }

  /// 网格卡片：首字头像 + 源名 + 地址（长按 = 菜单 / 左上把手拖动）
  Widget _tile(RssSource s) {
    final on = s.id == _selectedId;
    final picked = _picked.contains(s.id);
    final active = _selectMode ? picked : on;
    return GestureDetector(
      onTap: () => _pick(s),
      onLongPress: () => _onLongPress(s),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? AppTheme.accentColor.withValues(alpha: 0.5)
                : AppTheme.borderLight,
            width: active ? 1 : 0.5,
          ),
        ),
        child: Stack(
          children: [
            Row(
              children: [
                CardGridAvatar(s.name, selected: active),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              fontWeight:
                                  active ? FontWeight.w600 : FontWeight.w400,
                              color: AppTheme.textPrimary)),
                      const SizedBox(height: 2),
                      Text(s.group.trim().isEmpty ? s.url : s.group.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              color: AppTheme.textTertiary)),
                    ],
                  ),
                ),
              ],
            ),
            // 右上角：多选 = 复选框；否则 = 拖动把手（长按它排序）
            Positioned(
              top: -2,
              right: -2,
              child: _selectMode
                  ? Icon(
                      picked
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded,
                      size: 16,
                      color: picked
                          ? AppTheme.accentColor
                          : AppTheme.textTertiary,
                    )
                  : CardDragHandle(data: s.id, label: s.name),
            ),
          ],
        ),
      ),
    );
  }

  /// 单列行
  Widget _row(RssSource s) {
    final on = s.id == _selectedId;
    final picked = _picked.contains(s.id);
    final active = _selectMode ? picked : on;
    return GestureDetector(
      onTap: () => _pick(s),
      onLongPress: () => _onLongPress(s),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? AppTheme.accentColor.withValues(alpha: 0.5)
                : AppTheme.borderLight,
            width: active ? 1 : 0.5,
          ),
        ),
        child: Row(
          children: [
            CardGridAvatar(s.name, selected: active),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w400,
                          color: AppTheme.textPrimary)),
                  if (s.group.trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(s.group.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption,
                            color: AppTheme.textTertiary)),
                  ],
                ],
              ),
            ),
            if (_selectMode)
              Icon(
                picked
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 16,
                color: picked ? AppTheme.accentColor : AppTheme.textTertiary,
              )
            else
              CardDragHandle(data: s.id, label: s.name),
          ],
        ),
      ),
    );
  }
}
