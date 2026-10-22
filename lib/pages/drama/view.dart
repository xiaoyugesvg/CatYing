import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../models/movie.dart';
import '../../models/movie_sort.dart';
import '../../models/source_bean.dart';
import '../../services/api_config.dart';
import '../../services/source_service.dart';
import 'drama_banner.dart';
import 'drama_manage_page.dart';
import 'drama_settings.dart';

/// 「短剧」分类页（2026-10-22）。
///
/// 底栏里的「短剧」tab（默认不启用，用户在「设置 → 主页页面」打开）。
///
/// 数据完全来自视频线路：
///   1. 扫描参与聚合的源（默认只有当前源，可在本页「设置」里多选）；
///   2. 在每个源的分类里匹配关键词（默认 短剧/微短剧/竖屏/爽剧/短剧场）；
///   3. 命中的「源 · 分类」作为一组，选哪组就按普通分类接口拉列表。
/// 不写死任何站源、不内置内容、不绕过任何 VIP。
class DramaPage extends StatefulWidget {
  const DramaPage({super.key});

  @override
  State<DramaPage> createState() => _DramaPageState();
}

/// 一个「源 + 分类」组合
class _DramaGroup {
  const _DramaGroup(this.source, this.sort);
  final SourceBean source;
  final SortData sort;

  String get label => source.name == sort.name
      ? source.name
      : '${source.name} · ${sort.name}';
}

class _DramaPageState extends State<DramaPage> {
  final _scroll = ScrollController();

  List<_DramaGroup> _groups = [];
  int _groupIdx = 0;
  List<String> _keywords = DramaSettings.defaultKeywords;

  final List<Video> _videos = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;
  String _scanHint = '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
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

  /// 参与聚合的源：设置里选了就按选择，没选就只扫当前源
  Future<List<SourceBean>> _targets() async {
    final api = ApiConfig.instance;
    final all = <SourceBean>[
      ...api.sourceBeanList,
      if (api.localSourcesEnabled.value) ...api.localVideoSources,
    ];
    final keys = await DramaSettings.sourceKeys();
    if (keys.isEmpty) {
      final cur = api.homeSourceBean.value;
      return cur == null ? const [] : [cur];
    }
    return all.where((s) => keys.contains(s.key)).toList();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _groups = [];
      _videos.clear();
      _page = 1;
      _hasMore = true;
      _scanHint = '';
    });
    _keywords = await DramaSettings.keywords();
    final targets = await _targets();
    if (targets.isEmpty) {
      setState(() {
        _loading = false;
        _error = '还没有可用的视频源\n先到「切换源」里选一个影视源，或添加通用源';
      });
      return;
    }

    final found = <_DramaGroup>[];
    var done = 0;
    // 并发 4 个一批，避免一次把几百条线路全打出去
    for (var i = 0; i < targets.length; i += 4) {
      final batch = targets.skip(i).take(4).toList();
      final results = await Future.wait(batch.map(_probeSource));
      found.addAll(results.expand((e) => e));
      done += batch.length;
      if (mounted) {
        setState(() => _scanHint = '正在扫描 $done/${targets.length} 个源…');
      }
    }
    if (!mounted) return;

    if (found.isEmpty) {
      setState(() {
        _loading = false;
        _scanHint = '';
        _error = '已扫描 ${targets.length} 个源，没有找到短剧分类\n'
            '可在「设置」里改关键词，或添加通用源';
      });
      return;
    }
    setState(() {
      _groups = found;
      _groupIdx = 0;
      _scanHint = '';
    });
    await _loadPage(1);
  }

  Future<List<_DramaGroup>> _probeSource(SourceBean s) async {
    try {
      final r = await SourceService.instance
          .getSort(s)
          .timeout(const Duration(seconds: 12));
      return [
        for (final sort in r.$1)
          if (_keywords.any(sort.name.contains)) _DramaGroup(s, sort),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _loadPage(int page) async {
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (page == 1) {
          _error = '「${g.label}」加载失败：${e.toString().split('\n').first}';
        }
      });
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<bool>(MaterialPageRoute(
      settings: const RouteSettings(name: 'drama:manage'),
      builder: (_) => const DramaManagePage(),
    ));
    if (!mounted) return;
    // 管理页里也可能没改就退出 —— 无论如何重扫一次最省心（只读本地设置）
    _load();
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
        centerTitle: true,
        title: Text(
          '短剧',
          style: TextStyle(
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w600,
            color: fg,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '短剧设置',
            icon: Icon(Icons.tune_rounded, color: fg),
            onPressed: _openSettings,
          ),
          IconButton(
            tooltip: '刷新',
            icon: Icon(Icons.refresh_rounded, color: fg),
            onPressed: _loading ? null : _load,
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
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: _load,
                    child: const Text('重试'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
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
      onRefresh: _load,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // 分组 chips：多个「源 · 分类」时用来切换
          if (_groups.length > 1)
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
                          _loadPage(1);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: on
                                ? AppTheme.accentColor
                                : (isDark
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : Colors.black.withValues(alpha: 0.05)),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Text(
                            _groups[i].label,
                            style: TextStyle(
                              fontSize: AppTheme.fontFootnote,
                              color: on
                                  ? Colors.white
                                  : (isDark
                                      ? Colors.white70
                                      : Colors.black87),
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
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.55,
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

  Widget _card(Video v, bool isDark) {
    return GestureDetector(
      onTap: () => Get.toNamed('/detail', arguments: v),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: v.pic.isEmpty
                  ? _ph(isDark)
                  : CachedNetworkImage(
                      imageUrl: v.pic,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorWidget: (_, __, ___) => _ph(isDark),
                    ),
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
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          if (v.note.isNotEmpty)
            Text(
              v.note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white54 : Colors.black45,
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
