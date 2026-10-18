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

  @override
  void initState() {
    super.initState();
    _bootstrap();
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
      setState(() {
        _loading = false;
        _error = null;
        _loadedServerId = null;
        _views = const [];
        _resume = const [];
        _latest.clear();
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
      });
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
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Text(
            'Emby',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontTitle3,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 10),
          if (servers.length > 1)
            Flexible(
              child: PopupMenuButton<String>(
                tooltip: '切换服务器',
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
          IconButton(
            tooltip: '刷新',
            icon: Icon(Icons.refresh_rounded, color: AppTheme.textSecondary),
            onPressed: _refresh,
          ),
          IconButton(
            tooltip: 'Emby 管理',
            icon: Icon(Icons.settings_outlined, color: AppTheme.textSecondary),
            onPressed: _openSettings,
          ),
        ],
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
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Text(
        text,
        style: TextStyle(
          color: AppTheme.textPrimary,
          fontSize: AppTheme.fontHeadline,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _resumeRow() {
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _resume.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final item = _resume[i];
          return GestureDetector(
            onTap: () => _openItem(item),
            child: SizedBox(
              width: 200,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: _image(item, width: 200),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
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
      height: 196,
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
              width: 112,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                    child: AspectRatio(
                      aspectRatio: 2 / 3,
                      child: _image(item, width: 112),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead,
                    ),
                  ),
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
