import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import 'emby_accounts_page.dart';
import 'emby_api.dart';
import 'emby_detail_page.dart';
import 'emby_models.dart';
import 'emby_store.dart';

/// Emby 分类首页：媒体库 → 继续观看 / 最新加入。
///
/// 默认**不进入底栏**（「设置 → 菜单设置」里开启后才会出现在导航栏）。
class EmbyHomePage extends StatefulWidget {
  const EmbyHomePage({super.key});

  @override
  State<EmbyHomePage> createState() => _EmbyHomePageState();
}

class _EmbyHomePageState extends State<EmbyHomePage> {
  final _store = EmbyStore.instance;

  bool _loading = false;
  String? _error;
  List<EmbyItem> _views = const [];
  List<EmbyItem> _resume = const [];
  final Map<String, List<EmbyItem>> _latest = {};

  /// 当前列表属于哪台服务器：切服务器时先清空旧内容，
  /// 避免"标题已是新服务器、列表还是旧服务器"的串台。
  String? _loadedServerId;

  // ── 顶部幻灯片（Backdrop 轮播）──────────────────────────────
  final PageController _heroController =
      PageController(viewportFraction: 0.86);
  Timer? _heroTimer;
  int _heroIndex = 0;
  List<EmbyItem> _heroItems = const [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _heroTimer?.cancel();
    _heroController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _store.load();
    if (!mounted) return;
    setState(() {});
    if (_store.activeServer?.isConfigured == true) {
      await _refresh();
    }
  }

  Future<void> _refresh() async {
    final server = _store.activeServer;
    if (server == null || !server.isConfigured) {
      _heroTimer?.cancel();
      setState(() {
        _loading = false;
        _error = null;
        _loadedServerId = null;
        _views = const [];
        _resume = const [];
        _latest.clear();
        _heroItems = const [];
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      // 切了服务器：先清空旧服务器的列表，避免加载期间新旧混排
      if (_loadedServerId != null && _loadedServerId != server.id) {
        _views = const [];
        _resume = const [];
        _latest.clear();
        _heroItems = const [];
      }
    });
    final api = EmbyApi(server);
    try {
      final views = await api.getViews();
      final visibleViews = views
          .where((v) =>
              v.collectionType == null ||
              v.collectionType == 'movies' ||
              v.collectionType == 'tvshows' ||
              v.collectionType == 'mixed')
          .toList();
      final resume = await api.getResume();
      final latest = <String, List<EmbyItem>>{};
      for (final v in visibleViews) {
        try {
          latest[v.id] = await api.getLatest(v.id);
        } catch (_) {
          latest[v.id] = const [];
        }
      }
      if (!mounted) return;
      setState(() {
        _views = visibleViews;
        _resume = resume;
        _latest
          ..clear()
          ..addAll(latest);
        _loadedServerId = server.id;
        _loading = false;
        _heroItems = _pickHeroItems();
        _heroIndex = 0;
      });
      _scheduleHero();
    } on EmbyApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  /// 幻灯片候选：优先「继续观看」，再按各媒体库的最新条目补足；
  /// 只收有横版背景图（Backdrop）的条目，最多 6 张。
  List<EmbyItem> _pickHeroItems() {
    final seen = <String>{};
    final out = <EmbyItem>[];
    void take(Iterable<EmbyItem> list) {
      for (final it in list) {
        if (out.length >= 6) return;
        if (it.id.isEmpty || !seen.add(it.id)) continue;
        if (it.backdropTag == null || it.backdropTag!.isEmpty) continue;
        out.add(it);
      }
    }

    take(_resume);
    for (final v in _views) {
      take(_latest[v.id] ?? const <EmbyItem>[]);
    }
    return out;
  }

  void _scheduleHero() {
    _heroTimer?.cancel();
    if (_heroItems.length <= 1) return;
    _heroTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || _heroItems.length <= 1) return;
      if (!_heroController.hasClients) return;
      final next = (_heroIndex + 1) % _heroItems.length;
      _heroController.animateToPage(
        next,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const EmbyAccountsPage()),
    );
    if (!mounted) return;
    // 设置页可能新增/切换了服务器 → 重新加载
    await _store.load();
    if (!mounted) return;
    setState(() {});
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final servers = _store.servers;
    final server = _store.activeServer;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _header(server, servers)),
              if (_heroItems.isNotEmpty)
                SliverToBoxAdapter(child: _heroCarousel()),
              if (_loading && _views.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (server == null || !server.isConfigured)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _empty(
                    icon: Icons.dns_outlined,
                    title: '还没有连接 Emby',
                    subtitle: '在「设置 → Emby 管理」里添加服务器并登录',
                    action: '去配置',
                    onAction: _openSettings,
                  ),
                )
              else if (_error != null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _empty(
                    icon: Icons.error_outline_rounded,
                    title: '加载失败',
                    subtitle: _error!,
                    action: '重试',
                    onAction: _refresh,
                  ),
                )
              else ...[
                if (_resume.isNotEmpty) ...[
                  SliverToBoxAdapter(child: _sectionTitle('继续观看')),
                  SliverToBoxAdapter(child: _resumeRow()),
                ],
                for (final v in _views) ...[
                  SliverToBoxAdapter(child: _sectionTitle(v.name)),
                  SliverToBoxAdapter(child: _latestRow(v)),
                ],
                if (_views.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: Center(
                        child: Text(
                          '服务器上没有可用的电影 / 剧集媒体库',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: AppTheme.fontBody,
                          ),
                        ),
                      ),
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 110)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(EmbyServer? server, List<EmbyServer> servers) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 2),
      child: Row(
        children: [
          Text(
            'Emby',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 10),
          if (servers.length > 1)
            Flexible(
              child: PopupMenuButton<String>(
                tooltip: '切换服务器',
                color: AppTheme.backgroundSecondary,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppTheme.glassRadiusCard),
                ),
                onSelected: (id) async {
                  await _store.setActive(id);
                  if (mounted) setState(() {});
                  await _refresh();
                },
                itemBuilder: (_) => [
                  for (final s in servers)
                    PopupMenuItem(
                      value: s.id,
                      child: Row(
                        children: [
                          Icon(
                            s.id == _store.activeId
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            size: 16,
                            color: s.id == _store.activeId
                                ? AppTheme.accentColor
                                : AppTheme.textTertiary,
                          ),
                          const SizedBox(width: 8),
                          Flexible(child: Text(s.name)),
                        ],
                      ),
                    ),
                ],
                child: _serverChip(server?.name ?? '未配置'),
              ),
            )
          else if (server != null)
            Flexible(child: _serverChip(server.name)),
          const Spacer(),
          _headerAction(
            icon: Icons.refresh_rounded,
            tooltip: '刷新',
            onTap: _refresh,
          ),
          const SizedBox(width: 8),
          _headerAction(
            icon: Icons.settings_outlined,
            tooltip: 'Emby 管理',
            onTap: _openSettings,
          ),
        ],
      ),
    );
  }

  Widget _headerAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppTheme.backgroundTertiary,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 19, color: AppTheme.textSecondary),
        ),
      ),
    );
  }

  Widget _serverChip(String name) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.accentColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: AppTheme.accentColor,
          fontSize: AppTheme.fontCaption,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: AppTheme.accentColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  // ── 顶部幻灯片 ─────────────────────────────────────────────

  Widget _heroCarousel() {
    final width = MediaQuery.sizeOf(context).width;
    final cardWidth = width * 0.86;
    final height = (cardWidth * 9 / 16).clamp(170.0, 236.0);
    return Column(
      children: [
        SizedBox(
          height: height,
          child: PageView.builder(
            controller: _heroController,
            physics: const BouncingScrollPhysics(),
            onPageChanged: (i) => setState(() => _heroIndex = i),
            itemCount: _heroItems.length,
            itemBuilder: (_, i) => Padding(
              padding: EdgeInsets.only(
                left: i == 0 ? 16 : 6,
                right: i == _heroItems.length - 1 ? 16 : 6,
              ),
              child: _heroCard(_heroItems[i], cardWidth),
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (_heroItems.length > 1)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < _heroItems.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _heroIndex ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _heroIndex
                        ? AppTheme.accentColor
                        : AppTheme.textTertiary.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _heroCard(EmbyItem item, double cardWidth) {
    final title = item.isEpisode ? (item.seriesName ?? item.name) : item.name;
    final meta = [
      if (item.isEpisode && item.episodeLabel.isNotEmpty) item.episodeLabel,
      if (item.year != null) '${item.year}',
      if (item.rating != null && item.rating! > 0)
        '★ ${item.rating!.toStringAsFixed(1)}',
      item.isSeries ? '剧集' : '电影',
    ].join('  ·  ');
    return GestureDetector(
      onTap: () => _openItem(item),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _backdrop(item, width: cardWidth),
            // 底部压暗，保证标题在任何封面上都看得清
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Color(0x33000000),
                    Color(0xCC000000),
                  ],
                  stops: [0.35, 0.62, 1],
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 14,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.play_arrow_rounded,
                            size: 16, color: Colors.black),
                        const SizedBox(width: 2),
                        Text(
                          item.isSeries ? '选集' : '播放',
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resumeRow() {
    return SizedBox(
      height: 186,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _resume.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final item = _resume[i];
          final p = item.progress;
          return GestureDetector(
            onTap: () => _openItem(item),
            child: SizedBox(
              width: 220,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _posterShell(
                    radius: AppTheme.radiusMD,
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _image(item, width: 220),
                          if (p != null)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: LinearProgressIndicator(
                                value: p,
                                minHeight: 3,
                                backgroundColor:
                                    Colors.white.withValues(alpha: 0.25),
                                valueColor: AlwaysStoppedAnimation(
                                    AppTheme.accentColor),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.seriesName ?? item.episodeLabel,
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
          );
        },
      ),
    );
  }

  Widget _latestRow(EmbyItem view) {
    final items = _latest[view.id] ?? const <EmbyItem>[];
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          '暂无内容',
          style: TextStyle(
            color: AppTheme.textTertiary,
            fontSize: AppTheme.fontFootnote,
          ),
        ),
      );
    }
    return SizedBox(
      height: 236,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final item = items[i];
          return GestureDetector(
            onTap: () => _openItem(item),
            child: SizedBox(
              width: 118,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _posterShell(
                    radius: AppTheme.radiusMD,
                    child: AspectRatio(
                      aspectRatio: 2 / 3,
                      child: _image(item, width: 118),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 片名给足两行：中文长标题（如「机动战士高达 闪光的哈萨维」）
                  // 单行必然被截断（用户 2026-10-18 反馈）。
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (item.year != null) '${item.year}',
                      if (item.rating != null && item.rating! > 0)
                        '★ ${item.rating!.toStringAsFixed(1)}',
                    ].join('  '),
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
          );
        },
      ),
    );
  }

  /// 海报外壳：圆角 + 阴影，压住纯白/纯黑底色，观感更立体。
  Widget _posterShell({required Widget child, required double radius}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.16),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    );
  }

  Widget _backdrop(EmbyItem item, {required double width}) {
    final server = _store.activeServer;
    if (server == null) {
      return ColoredBox(color: AppTheme.backgroundSecondary);
    }
    final api = EmbyApi(server);
    return CachedNetworkImage(
      imageUrl: api.imageUrl(
        item.backdropImageId,
        tag: item.backdropTag,
        imageType: 'Backdrop',
        maxHeight: 720,
      ),
      httpHeaders: api.imageHeaders,
      fit: BoxFit.cover,
      memCacheWidth: (width * 2).round(),
      placeholder: (_, _) => ColoredBox(color: AppTheme.backgroundSecondary),
      errorWidget: (_, _, _) => ColoredBox(
        color: AppTheme.backgroundSecondary,
        child: Icon(
          Icons.image_outlined,
          color: AppTheme.textTertiary,
          size: 32,
        ),
      ),
    );
  }

  Widget _image(EmbyItem item, {required double width}) {
    final server = _store.activeServer;
    if (server == null || item.id.isEmpty) {
      return ColoredBox(color: AppTheme.backgroundSecondary);
    }
    final api = EmbyApi(server);
    return CachedNetworkImage(
      imageUrl: api.imageUrl(item.id, tag: item.imageTag),
      httpHeaders: api.imageHeaders,
      fit: BoxFit.cover,
      memCacheWidth: (width * 2).round(),
      placeholder: (_, _) => ColoredBox(color: AppTheme.backgroundSecondary),
      errorWidget: (_, _, _) => ColoredBox(
        color: AppTheme.backgroundSecondary,
        child: Icon(
          Icons.movie_outlined,
          color: AppTheme.textTertiary,
          size: 28,
        ),
      ),
    );
  }

  void _openItem(EmbyItem item) {
    final server = _store.activeServer;
    if (server == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EmbyDetailPage(item: item, server: server),
      ),
    );
  }

  Widget _empty({
    required IconData icon,
    required String title,
    required String subtitle,
    required String action,
    required VoidCallback onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: AppTheme.textTertiary),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontFootnote,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(action)),
          ],
        ),
      ),
    );
  }
}
