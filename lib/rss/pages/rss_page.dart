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

import '../../common/theme.dart';
import '../../widgets/common_widgets.dart';
import '../models/rss_article.dart';
import '../models/rss_source.dart';
import '../services/rss_reader.dart';
import '../services/rss_store.dart';
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

  @override
  void initState() {
    super.initState();
    store.tick.addListener(_onStoreChanged);
    _boot();
  }

  @override
  void dispose() {
    store.tick.removeListener(_onStoreChanged);
    super.dispose();
  }

  Future<void> _boot() async {
    if (!store.loaded) await store.load();
    if (!mounted) return;
    _reload();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    final cur = store.current;
    if (cur == null) {
      setState(() {
        _articles = [];
        _error = '';
        _loadedId = '';
        _nextUrl = '';
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
    _page = 1;
    _nextUrl = '';
    _load(append: false);
  }

  Future<void> _load({required bool append}) async {
    final src = store.current;
    if (src == null) return;
    final my = ++_seq;
    setState(() {
      _loading = true;
      if (!append) {
        _error = '';
        _articles = [];
      }
    });
    try {
      final chs = src.channels;
      final ch = chs[_channel.clamp(0, chs.length - 1)];
      // append 时用上一页算出的"下一页地址"接力（ruleNextPage 型源）
      final res = await RssReader.fetchArticles(
        src,
        channel: ch,
        page: _page,
        pageUrl: append ? _nextUrl : null,
      );
      if (!mounted || my != _seq) return;
      final list = res.articles;
      setState(() {
        _articles = append ? [..._articles, ...list] : list;
        _nextUrl = res.nextUrl;
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
    final chs = src.channels;
    final ch = chs[_channel.clamp(0, chs.length - 1)];
    return RssReader.isPagedUrl(ch.url);
  }

  void _openManage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RssManagePage()),
    );
  }

  /// 顶栏动作图标：内边距清零 + 固定 36 热区 ⇒ 视觉上**紧贴右边**。
  Widget _topIcon(IconData icon, String tooltip, VoidCallback? onTap) =>
      IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        iconSize: 20,
        onPressed: onTap,
        icon: Icon(icon, color: AppTheme.textPrimary),
      );

  /// 切换订阅源：**卡片网格**（一行 2 个）—— 用户 2026-10-15：
  /// 「弹窗也太丑了，要卡片式的，一行 2-3 个这种」。
  Future<void> _pickSource() async {
    final list = store.sources.where((e) => e.enabled).toList();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHandle(),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text('切换订阅源',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('停用的源不显示',
                      style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption)),
                ],
              ),
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  child: CardGrid(
                    columns: 2,
                    children: [
                      for (final s in list)
                        CardGridItem(
                          title: s.name,
                          subtitle: s.url,
                          selected: s.id == store.selectedId,
                          leading: CardGridAvatar(s.name,
                              selected: s.id == store.selectedId),
                          onTap: () {
                            Navigator.pop(ctx);
                            if (s.id != store.selectedId) store.select(s.id);
                          },
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              CardGridItem(
                icon: Icons.settings_outlined,
                title: 'RSS 管理',
                subtitle: '导入订阅链接 / OPML / 本地文件',
                onTap: () {
                  Navigator.pop(ctx);
                  _openManage();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final src = store.current;
    final channels = src?.channels ?? const <RssChannel>[];
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: Column(
        children: [
          SizedBox(height: topInset),
          SizedBox(
            height: 46,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Text('RSS',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                if (src != null)
                  Flexible(
                    child: Text(
                      src.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption),
                    ),
                  ),
                const Spacer(),
                // ⚠️ 三个图标必须**贴到右边**（用户 2026-10-15：「图标没有到边」）：
                //   IconButton 自带 8px 内边距 + 末尾 4px 留白 ⇒ 视觉上离屏幕边
                //   还有一段。这里把内边距清零、只留 36 的点击热区 + 末尾 2px。
                _topIcon(Icons.swap_horiz_rounded, '切换订阅源', _pickSource),
                _topIcon(Icons.refresh_rounded, '刷新', _loading ? null : _reload),
                _topIcon(Icons.tune_rounded, 'RSS 管理', _openManage),
                const SizedBox(width: 2),
              ],
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
                      setState(() => _channel = i);
                      _reload();
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
    if (_loading && _articles.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_articles.isEmpty) {
      // 站点型源（Legado `singleUrl`）：它本来就没有文章列表 ⇒ 别报"没抓到内容"，
      // 直接告诉用户这是站点型、给「用网页打开」出口（用户 2026-10-15 导入的
      // 源仓库 / Yiove / 使用文档 这批都属于这种）。
      if (_error.isEmpty && src.isSiteOnly) {
        return _emptyView(
          icon: Icons.public_rounded,
          title: '「${src.name}」是站点型订阅源',
          hint: '它本身是一个网站、没有文章列表，所以抓不到文章。\n可以用网页直接打开看。',
          btnText: '用网页打开',
          onBtn: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RssWebViewPage(url: src.url, title: src.name),
            ),
          ),
        );
      }
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
