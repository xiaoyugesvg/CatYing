import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../models/movie.dart';
import '../../models/movie_sort.dart';
import '../../models/source_bean.dart';
import '../../services/api_config.dart';
import '../../services/source_service.dart';
import 'drama_banner.dart';
import 'drama_entry.dart';
import 'drama_history_page.dart';
import 'drama_manage_page.dart';
import 'drama_search_page.dart';
import 'drama_settings.dart';
import 'drama_source_sheet.dart';

/// 「短剧」分类页（2026-10-22）。
///
/// 底栏里的「短剧」tab（默认不启用，用户在「设置 → 主页页面」打开）。
///
/// 单源模式（用户 2026-10-24：「不要一下子刷新所有的…就是影视那种，
/// 左上角一个切换源，我一个个切换」）：
///   1. 左上角是当前源（默认跟随首页源），点头像/源名换一个，**一次只扫这一个**；
///   2. 在该源的分类里匹配关键词（默认 短剧/微短剧/竖屏/爽剧/短剧场）；
///   3. 命中的分类作为本页的 tab chips，选哪个就按普通分类接口拉列表。
/// 扫描结果按源落盘（DramaSettings.cachedGroups），换源时先读缓存，
/// 没缓存才扫 —— 不会每次进页面都打十几个源的分类接口。
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

  /// 当前源：设置里挑过的优先，否则跟随首页当前源
  Future<SourceBean?> _currentSource() async {
    final key = await DramaSettings.pickedSourceKey();
    if (key.isNotEmpty) {
      final hit = _findSource(key);
      if (hit != null) return hit;
    }
    return ApiConfig.instance.homeSourceBean.value;
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
  Future<void> _load({bool rescan = false}) async {
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

    final source = await _currentSource();
    if (!mounted) return;
    if (source == null) {
      setState(() {
        _source = null;
        _loading = false;
        _error = '还没有可用的视频源\n先到「切换源」里选一个影视源，或添加通用源';
      });
      return;
    }
    setState(() => _source = source);
    await _refreshHistorySources();

    // ── 缓存优先：这个源上次扫到的短剧分类直接用 ────────────────
    if (!rescan) {
      final cached = await _groupsFromCache(source.key);
      if (!mounted) return;
      if (cached != null) {
        setState(() {
          _groups = cached;
          _groupIdx = 0;
          _loading = false;
        });
        await _loadPage(1);
        return;
      }
    }

    // 只扫这一个源（不再并发扫所有源）
    setState(() => _scanHint = '正在扫描「${source.name}」的分类…');
    final found = await _probeSource(source);
    if (!mounted) return;

    if (found.isEmpty) {
      setState(() {
        _loading = false;
        _scanHint = '';
        _error = '「${source.name}」没有匹配短剧关键词的分类\n'
            '点左上角源名换一个源，或在「设置」里改关键词';
      });
      return;
    }
    // 落盘：保留其他源的缓存，整组替换这个源的
    final oldRows = await DramaSettings.cachedGroups();
    final merged = <Map<String, String>>[
      for (final r in oldRows)
        if (r['source'] != source.key) r,
      for (final g in found)
        {
          'source': g.source.key,
          'id': g.sort.id,
          'name': g.sort.name,
          'flag': g.sort.flag,
        },
    ];
    await DramaSettings.saveGroups(merged);
    if (!mounted) return;
    setState(() {
      _groups = found;
      _groupIdx = 0;
      _scanHint = '';
    });
    await _refreshHistorySources();
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
          _error = '「${g.sort.name}」加载失败：${e.toString().split('\n').first}';
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
    // 管理页可能改了关键词 —— 重扫当前源（单源，开销小）
    _load(rescan: true);
  }

  /// 左上角换源：列出全部源，扫出过短剧分类的标「短剧」徽章排前面。
  /// 选中后先读缓存，没缓存才扫 —— 换源不再是「把十几个源全刷一遍」。
  Future<void> _pickSource() async {
    final api = ApiConfig.instance;
    final all = <SourceBean>[
      ...api.sourceBeanList,
      if (api.localSourcesEnabled.value) ...api.localVideoSources,
    ];
    if (all.isEmpty) return;
    final rows = await DramaSettings.cachedGroups();
    // 已经扫出过短剧分类的源（面板里标徽章 + 缓存优先排序）
    final dramaKeys =
        rows.map((r) => r['source'] ?? '').where((e) => e.isNotEmpty).toSet();
    if (!mounted) return;

    // 面板能力与影视的源切换一致：两列网格 / 搜索 / 定位 / 排序 / 长按菜单
    final picked = await DramaSourceSheet.show(
      context,
      sources: all,
      cachedKeys: dramaKeys,
      currentKey: _source?.key,
    );
    if (picked == null || !mounted) return;
    await DramaSettings.savePickedSourceKey(picked.key);
    if (!mounted || picked.key == _source?.key) return;
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
          // 分类 chips：当前源命中的几个短剧分类（同影视首页的分类 tab）
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
                                  errorWidget: (_, __, ___) => isBack
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
