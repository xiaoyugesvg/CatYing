// lib/rss/pages/rss_page.dart
//
// 「RSS」模块主页（底栏独立分类，用户 2026-10-15：直接加个 RSS 分类）。
//
// 结构对齐网页/程序模块：**顶栏左边是模块名，右边是操作**（源切换 / 刷新 / 管理），
// 下面是文章列表（封面 + 标题 + 来源·时间），点开进正文页。
//
// 一个源可能有多个分类（`sortUrl` 里 `名称::url`）⇒ 分类多的时候顶栏下面
// 出一条分类胶囊。

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../common/theme.dart';
import '../../services/nav_feature_service.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/common_widgets.dart';
import '../models/rss_article.dart';
import '../models/rss_source.dart';
import '../services/rss_reader.dart';
import '../services/rss_store.dart';
import '../widgets/rss_login_sheet.dart';
import 'rss_article_page.dart';
import 'rss_manage_page.dart';

class RssPage extends StatefulWidget {
  const RssPage({super.key});

  @override
  State<RssPage> createState() => _RssPageState();
}

class _RssPageState extends State<RssPage> {
  RssStore get store => RssStore.instance;

  List<RssArticle> _articles = [];
  bool _loading = false;
  String _error = '';
  int _page = 1;
  int _channel = 0;

  /// 上一页算出的"下一页地址"（仅 `ruleNextPage` 型源用；空 = 到底了）。
  String _nextUrl = '';

  /// 已经加载过内容的源 id（换源要重新拉，只是排序/启用变了不用）
  String _loadedId = '';

  /// 本次请求的序号：防止"快速换源 / 连续刷新"时旧结果覆盖新结果。
  int _seq = 0;

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

  WebViewController _webFor(String url) {
    if (_web != null && _webUrl == url) return _web!;
    _webUrl = url;
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppTheme.backgroundPrimary)
      ..loadRequest(Uri.parse(url));
    return _web!;
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

  void _start() {
    if (_started) return;
    _started = true;
    _boot();
  }

  @override
  void dispose() {
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
      setState(() {
        _articles = [];
        _error = '';
        _loadedId = '';
        _nextUrl = '';
        _siteLike = false;
        _channels = const [];
      });
      return;
    }
    if (cur.id != _loadedId) {
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
    setState(() {
      _loading = true;
      if (!append) {
        _error = '';
        _articles = [];
        _siteLike = false;
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
      setState(() {
        _articles = append ? [..._articles, ...list] : list;
        _nextUrl = res.nextUrl;
        _siteLike = res.siteLike;
        _loadedId = src.id;
        _error = list.isEmpty ? '没有抓到文章（源可能失效了，可到「RSS 管理」里换一个）' : '';
      });
    } catch (e) {
      if (!mounted || my != _seq) return;
      setState(() {
        _error = '抓取失败：${e.toString().split('\n').first}';
      });
    } finally {
      if (mounted && my == _seq) setState(() => _loading = false);
    }
  }

  bool get _canLoadMore {
    final src = store.current;
    if (src == null || _articles.isEmpty) return false;
    // 规则接力翻页：上一页算出了"下一页地址"就还能继续
    if (_nextUrl.isNotEmpty) return true;
    // 配了 ruleNextPage 却没算出下一页地址 ⇒ 到底了（该规则里没有 {{page}}）
    if ((src.ruleNextPage ?? '').trim().isNotEmpty) return false;
    // 行内模板翻页：地址里必须真有引用 page 的 {{…}} 才算
    final chs = _channels.isNotEmpty ? _channels : src.channels;
    final ch = chs[_channel.clamp(0, chs.length - 1)];
    return RssReader.isPagedUrl(ch.url);
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
      builder: (ctx) => _RssSourceSwitchSheet(
        sources: list,
        selectedId: store.selectedId,
        onPick: (id) {
          if (id != store.selectedId) store.select(id);
        },
        onManage: _openManage,
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
                          constraints: const BoxConstraints(maxWidth: 150),
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
                        Icon(Icons.expand_more_rounded,
                            size: 16, color: AppTheme.textTertiary),
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
                  _topIcon(Icons.refresh_rounded, '刷新', _loading ? null : _reload),
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
      return WebViewWidget(controller: _webFor(src.url));
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
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      color: AppTheme.accentColor,
      child: ListView.builder(
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

  /// 统一空态：图标 + 标题 + 说明 + （可选）按钮
  Widget _emptyView({
    required IconData icon,
    required String title,
    required String hint,
    String? btnText,
    VoidCallback? onBtn,
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
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RssArticlePage(source: src, article: a),
          ),
        ),
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
                      errorWidget: (_, __, ___) => const SizedBox.shrink(),
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
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600,
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
///   2 列卡片（3.4 纵横比）/ 单列行 → 底部「RSS 管理」入口
///
/// 用户 2026-10-15：「RSS 这个顶栏切换参考影视撒，顶栏太丑了」。
class _RssSourceSwitchSheet extends StatefulWidget {
  const _RssSourceSwitchSheet({
    required this.sources,
    required this.selectedId,
    required this.onPick,
    required this.onManage,
  });

  final List<RssSource> sources;
  final String selectedId;
  final ValueChanged<String> onPick;
  final VoidCallback onManage;

  @override
  State<_RssSourceSwitchSheet> createState() => _RssSourceSwitchSheetState();
}

class _RssSourceSwitchSheetState extends State<_RssSourceSwitchSheet> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  String _kw = '';

  /// false=单列列表 / true=双排网格（默认双排，与影视面板一致）
  bool _grid = true;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<RssSource> get _list {
    if (_kw.isEmpty) return widget.sources;
    final k = _kw.toLowerCase();
    return widget.sources.where((s) => s.name.toLowerCase().contains(k)).toList();
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
                  _circleBtn(Icons.my_location_rounded, _locate),
                  const SizedBox(width: 8),
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
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search,
                        size: 16, color: AppTheme.textTertiary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _search,
                        onChanged: (v) => setState(() => _kw = v.trim()),
                        style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            color: AppTheme.textPrimary),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '搜索订阅源',
                          hintStyle: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: AppTheme.textTertiary),
                        ),
                      ),
                    ),
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
                            itemBuilder: (c, i) => _tile(list[i]),
                          )
                        else
                          for (final s in list)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: _row(s),
                            ),
                      ],
                    ),
            ),
            // 底部入口：去管理页导入 / 排序 / 删除
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                Navigator.pop(context);
                widget.onManage();
              },
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  color: AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.borderLight, width: 0.5),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.tune_rounded,
                        size: 16, color: AppTheme.textSecondary),
                    const SizedBox(width: 6),
                    Text('RSS 管理',
                        style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            color: AppTheme.textPrimary)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _pick(RssSource s) {
    Navigator.pop(context);
    widget.onPick(s.id);
  }

  /// 网格卡片：首字头像 + 源名 + 地址
  Widget _tile(RssSource s) {
    final on = s.id == widget.selectedId;
    return GestureDetector(
      onTap: () => _pick(s),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: on
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: on
                ? AppTheme.accentColor.withValues(alpha: 0.5)
                : AppTheme.borderLight,
            width: on ? 1 : 0.5,
          ),
        ),
        child: Row(
          children: [
            CardGridAvatar(s.name, selected: on),
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
                          fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                          color: AppTheme.textPrimary)),
                  const SizedBox(height: 2),
                  Text(s.url,
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
      ),
    );
  }

  /// 单列行
  Widget _row(RssSource s) {
    final on = s.id == widget.selectedId;
    return GestureDetector(
      onTap: () => _pick(s),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: on
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: on
                ? AppTheme.accentColor.withValues(alpha: 0.5)
                : AppTheme.borderLight,
            width: on ? 1 : 0.5,
          ),
        ),
        child: Row(
          children: [
            CardGridAvatar(s.name, selected: on),
            const SizedBox(width: 10),
            Expanded(
              child: Text(s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                      color: AppTheme.textPrimary)),
            ),
            if (on)
              Icon(Icons.check_circle_rounded,
                  size: 16, color: AppTheme.accentColor),
          ],
        ),
      ),
    );
  }
}
