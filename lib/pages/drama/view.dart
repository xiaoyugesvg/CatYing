import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../models/movie.dart';
import '../../models/movie_sort.dart';
import '../../services/api_config.dart';
import '../../services/source_service.dart';

/// 「短剧」分类页（2026-10-22）。
///
/// 底栏里的「短剧」tab（默认不启用，用户在「设置 → 主页页面」打开）。
/// 数据完全来自当前视频源：先从源的分类里找「短剧 / 微短剧 / 竖屏 / 爽剧 /
/// 短剧场」类目，再按普通分类列表拉取；不写死任何站源、不内置内容。
class DramaPage extends StatefulWidget {
  const DramaPage({super.key});

  @override
  State<DramaPage> createState() => _DramaPageState();
}

class _DramaPageState extends State<DramaPage> {
  final _scroll = ScrollController();

  final List<SortData> _matches = [];
  SortData? _selected;
  final List<Video> _videos = [];

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 1;
  String? _error;

  static const _keys = ['短剧', '微短剧', '竖屏', '爽剧', '短剧场'];

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
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 400) {
      _loadPage(_page + 1);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _matches.clear();
      _videos.clear();
    });
    final source = ApiConfig.instance.homeSourceBean.value;
    if (source == null) {
      setState(() {
        _loading = false;
        _error = '还没有选择视频源';
      });
      return;
    }
    try {
      final r = await SourceService.instance.getSort(source);
      final hits = r.$1
          .where((s) => _keys.any(s.name.contains))
          .toList(growable: false);
      if (!mounted) return;
      if (hits.isEmpty) {
        setState(() {
          _loading = false;
          _error = '当前源（${source.name}）没有短剧分类\n'
              '可在「切换源」里换一个源再试';
        });
        return;
      }
      setState(() {
        _matches.addAll(hits);
        _selected = hits.first;
      });
      await _loadPage(1);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _loadPage(int page) async {
    final source = ApiConfig.instance.homeSourceBean.value;
    final sort = _selected;
    if (source == null || sort == null) return;
    if (page > 1) {
      if (_loadingMore || !_hasMore) return;
      setState(() => _loadingMore = true);
    }
    try {
      final list = await SourceService.instance.getList(
        source,
        sort,
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
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (page == 1) _error = '加载失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
            color: isDark ? Colors.white : AppTheme.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: Icon(Icons.refresh_rounded,
                color: isDark ? Colors.white : AppTheme.textPrimary),
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
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
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
              OutlinedButton(onPressed: _load, child: const Text('重试')),
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
          if (_matches.length > 1)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  itemCount: _matches.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final s = _matches[i];
                    final on = s.id == _selected?.id;
                    return Center(
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _selected = s;
                            _page = 1;
                            _hasMore = true;
                            _videos.clear();
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
                            s.name,
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
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.55,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final v = _videos[i];
                    return _card(v, isDark);
                  },
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
                  ? Container(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : Colors.black.withValues(alpha: 0.05),
                      child: const Icon(Icons.movie_outlined, size: 26),
                    )
                  : CachedNetworkImage(
                      imageUrl: v.pic,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorWidget: (_, __, ___) => Container(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.black.withValues(alpha: 0.05),
                        child: const Icon(Icons.movie_outlined, size: 26),
                      ),
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
}
