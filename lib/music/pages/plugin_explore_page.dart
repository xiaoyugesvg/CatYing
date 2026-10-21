// lib/music/pages/plugin_explore_page.dart
//
// 「插件发现页」—— 2026-10-21 第二阶段。
//
// 背景：MusicFree 插件以前只被用来「给某首歌取播放地址」（unblock_service），
// 但它本身就是一个平台：能搜歌、能出榜单、能出推荐歌单。第一阶段已经把
// Node 侧的 action 补齐（`musicFreeTopLists / musicFreeTopListDetail /
// musicFreeRecommendSheetTags / musicFreeRecommendSheets / musicFreeSheetInfo`），
// 这个页面就是它们的 UI：
//
//   插件 → 榜单分组 + 推荐歌单（按标签） → 点进去看歌曲 → 整列表播放
//
// ⚠️ 插件返回的 item 形状各家不同，所以这里**不建强模型**：
// 直接把 Node 归一化后的 Map 存下来，点进详情时**原样回传**给插件
//（例如 `getMusicSheetInfo(sheetItem)` 需要它自己那套字段）。

import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../models/models.dart';
import '../models/third_party_source.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../widgets/music_components.dart';

/// 插件里的一个「条目」（榜单 / 歌单 / 专辑都用它）
class _PItem {
  const _PItem({
    required this.id,
    required this.name,
    required this.cover,
    required this.subtitle,
    required this.raw,
  });

  final String id;
  final String name;
  final String cover;
  final String subtitle;

  /// 原始 Map —— 点进详情时原样回传给插件（不要重构成别的形状）
  final Map<String, dynamic> raw;

  static _PItem? from(Map e) {
    final m = Map<String, dynamic>.from(e);
    final id = (m['id'] ?? '').toString();
    if (id.isEmpty) return null;
    final worksNum = (m['worksNum'] is num) ? (m['worksNum'] as num).toInt() : 0;
    final desc = (m['description'] ?? '').toString().trim();
    // 插件详情接口要读**它自己的原始对象**（见 adapter 里 mapSheetItem 的
    // `_raw` 说明）—— 优先用它，没有才退回归一化后的 Map。
    final raw = (m['_raw'] is Map)
        ? Map<String, dynamic>.from(m['_raw'] as Map)
        : m;
    return _PItem(
      id: id,
      name: (m['name'] ?? '').toString(),
      cover: (m['cover'] ?? '').toString(),
      subtitle: worksNum > 0
          ? '$worksNum 首'
          : (desc.isEmpty ? (m['artist'] ?? '').toString() : desc),
      raw: raw,
    );
  }
}

/// 插件内的一个榜单分组
class _PGroup {
  const _PGroup({required this.name, required this.items});
  final String name;
  final List<_PItem> items;
}

class PluginExplorePage extends StatefulWidget {
  const PluginExplorePage({super.key, required this.source});

  final ThirdPartySource source;

  @override
  State<PluginExplorePage> createState() => _PluginExplorePageState();
}

class _PluginExplorePageState extends State<PluginExplorePage> {
  final api = MusicApi.instance;

  bool _loading = true;
  String _error = '';

  List<_PGroup> _groups = const [];
  List<({String name, List<String> tags})> _tagGroups = const [];
  String _tag = '';
  List<_PItem> _sheets = const [];

  /// 推荐歌单分页状态（2026-10-21：支持「加载更多」）
  int _sheetPage = 1;
  bool _sheetEnd = false;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      // 榜单与标签互不依赖 → 并行
      final results = await Future.wait([
        api.musicFreeAction(widget.source, 'musicFreeTopLists'),
        api.musicFreeAction(widget.source, 'musicFreeRecommendSheetTags'),
      ]);
      final top = results[0];
      final tags = results[1];
      if (!mounted) return;

      final groups = <_PGroup>[];
      for (final g in (top['list'] as List? ?? const [])) {
        if (g is! Map) continue;
        final items = <_PItem>[];
        for (final e in (g['list'] as List? ?? const [])) {
          if (e is! Map) continue;
          final it = _PItem.from(e);
          if (it != null) items.add(it);
        }
        if (items.isNotEmpty) {
          groups.add(_PGroup(
            name: (g['name'] ?? '榜单').toString(),
            items: items,
          ));
        }
      }

      final tagGroups = <({String name, List<String> tags})>[];
      for (final g in (tags['list'] as List? ?? const [])) {
        if (g is! Map) continue;
        final ts = (g['tags'] as List? ?? const [])
            .map((e) => e.toString())
            .where((e) => e.trim().isNotEmpty)
            .toList();
        if (ts.isNotEmpty) {
          tagGroups.add((name: (g['name'] ?? '标签').toString(), tags: ts));
        }
      }

      setState(() {
        _groups = groups;
        _tagGroups = tagGroups;
        _loading = false;
        // 榜单/歌单都没有 → 给明确说明（不是"空白页"）
        if (groups.isEmpty && tagGroups.isEmpty) {
          _error = '该插件没有提供榜单或推荐歌单（只支持搜索/取地址）';
        }
      });

      final firstTag =
          tagGroups.isNotEmpty ? tagGroups.first.tags.first : '';
      if (firstTag.isNotEmpty) await _loadSheets(firstTag);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadSheets(String tag) async {
    setState(() {
      _tag = tag;
      _sheets = const [];
      _sheetPage = 1;
      _sheetEnd = false;
    });
    final r = await api.musicFreeAction(
      widget.source,
      'musicFreeRecommendSheets',
      params: {'tag': tag, 'page': 1},
    );
    if (!mounted) return;
    setState(() {
      _sheets = _parseSheets(r);
      _sheetEnd = r['isEnd'] == true || _sheets.isEmpty;
    });
  }

  /// 加载下一页推荐歌单并**追加**（用户 2026-10-21：原来只加载第 1 页）
  Future<void> _loadMoreSheets() async {
    if (_loadingMore || _sheetEnd || _tag.isEmpty) return;
    setState(() => _loadingMore = true);
    final next = _sheetPage + 1;
    final r = await api.musicFreeAction(
      widget.source,
      'musicFreeRecommendSheets',
      params: {'tag': _tag, 'page': next},
    );
    if (!mounted) return;
    final more = _parseSheets(r);
    setState(() {
      _loadingMore = false;
      _sheetPage = next;
      _sheets = [..._sheets, ...more];
      _sheetEnd = r['isEnd'] == true || more.isEmpty;
    });
  }

  List<_PItem> _parseSheets(Map<String, dynamic> r) {
    final list = <_PItem>[];
    for (final e in (r['list'] as List? ?? const [])) {
      if (e is! Map) continue;
      final it = _PItem.from(e);
      if (it != null) list.add(it);
    }
    return list;
  }

  void _openTopList(_PItem item) {
    Navigator.of(context).push<void>(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'music:page'),
      builder: (_) => PluginSongListPage(
        source: widget.source,
        title: item.name,
        coverUrl: item.cover,
        item: item.raw,
        isTopList: true,
      ),
    ));
  }

  void _openSheet(_PItem item) {
    Navigator.of(context).push<void>(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'music:page'),
      builder: (_) => PluginSongListPage(
        source: widget.source,
        title: item.name,
        coverUrl: item.cover,
        item: item.raw,
        isTopList: false,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: IconThemeData(color: MusicTheme.label),
          title: Text(
            widget.source.name,
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontHeadline,
            ),
          ),
          actions: [
            IconButton(
              tooltip: '刷新',
              icon: Icon(Icons.refresh_rounded, color: MusicTheme.tint),
              onPressed: _loading ? null : _load,
            ),
          ],
        ),
        body: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: MusicTheme.tint));
    }
    if (_error.isNotEmpty && _groups.isEmpty && _tagGroups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _error,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: MusicTheme.secondary,
              fontSize: AppTheme.fontSubhead,
            ),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 140),
      children: [
        for (final g in _groups) ...[
          SectionTitle(title: g.name),
          HorizontalCards(
            itemCount: g.items.length,
            height: 212,
            itemWidth: 132,
            itemBuilder: (c, i) {
              final it = g.items[i];
              return CoverCard(
                coverUrl: it.cover,
                title: it.name,
                subtitle: it.subtitle,
                width: 132,
                onTap: () => _openTopList(it),
              );
            },
          ),
        ],
        if (_tagGroups.isNotEmpty) SectionTitle(title: '推荐歌单'),
        if (_tagGroups.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final g in _tagGroups)
                  for (final t in g.tags)
                    _tagChip(t),
              ],
            ),
          ),
        if (_tagGroups.isNotEmpty) const SizedBox(height: 12),
        if (_sheets.isNotEmpty)
          HorizontalCards(
            // 还没到底时多给一张「加载更多」卡
            itemCount: _sheets.length + (_sheetEnd ? 0 : 1),
            height: 212,
            itemWidth: 152,
            itemBuilder: (c, i) {
              if (i >= _sheets.length) return _loadMoreCard();
              final it = _sheets[i];
              return CoverCard(
                coverUrl: it.cover,
                title: it.name,
                subtitle: it.subtitle,
                width: 152,
                onTap: () => _openSheet(it),
              );
            },
          )
        else if (_tag.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              '「$_tag」下没有歌单',
              style: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontSubhead,
              ),
            ),
          ),
      ],
    );
  }

  /// 推荐歌单末尾的「加载更多」卡
  Widget _loadMoreCard() {
    return GestureDetector(
      onTap: _loadingMore ? null : _loadMoreSheets,
      child: Container(
        width: 152,
        height: 152,
        decoration: BoxDecoration(
          color: MusicTheme.fill,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(
          child: _loadingMore
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: MusicTheme.tint,
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_rounded, color: MusicTheme.tint, size: 26),
                    const SizedBox(height: 6),
                    Text(
                      '加载更多',
                      style: TextStyle(
                        color: MusicTheme.tint,
                        fontSize: AppTheme.fontFootnote,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _tagChip(String tag) {
    final on = tag == _tag;
    return GestureDetector(
      onTap: () => _loadSheets(tag),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: on ? MusicTheme.tint : MusicTheme.fill,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          tag,
          style: TextStyle(
            color: on ? Colors.white : MusicTheme.label,
            fontSize: AppTheme.fontSubhead,
            fontWeight: on ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// 插件榜单 / 歌单的歌曲列表页。
class PluginSongListPage extends StatefulWidget {
  const PluginSongListPage({
    super.key,
    required this.source,
    required this.title,
    required this.item,
    required this.isTopList,
    this.coverUrl = '',
  });

  final ThirdPartySource source;
  final String title;
  final String coverUrl;

  /// 从上一页带下来的原始条目（榜单 or 歌单），**原样**交给插件
  final Map<String, dynamic> item;

  /// true = 榜单（`getTopListDetail`）；false = 歌单（`getMusicSheetInfo`）
  final bool isTopList;

  @override
  State<PluginSongListPage> createState() => _PluginSongListPageState();
}

class _PluginSongListPageState extends State<PluginSongListPage> {
  final api = MusicApi.instance;
  bool _loading = true;
  String _error = '';
  List<Song> _songs = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    final r = await api.musicFreeAction(
      widget.source,
      widget.isTopList ? 'musicFreeTopListDetail' : 'musicFreeSheetInfo',
      params: widget.isTopList
          ? {'topListItem': widget.item}
          : {'sheetItem': widget.item, 'page': 1},
    );
    if (!mounted) return;
    final songs = <Song>[];
    for (final e in (r['list'] as List? ?? const [])) {
      if (e is! Map) continue;
      try {
        // 插件歌没有平台归属 → 打上 pluginId，播放时优先问这个插件
        songs.add(
          Song.fromJson(Map<String, dynamic>.from(e))
              .withPluginId(widget.source.id),
        );
      } catch (_) {
        // 单条坏数据不影响整页
      }
    }
    setState(() {
      _loading = false;
      _songs = songs;
      if (r['ok'] != true) {
        _error = (r['error'] ?? '读取失败').toString();
      } else if (songs.isEmpty) {
        _error = '这个列表里没有歌曲';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: IconThemeData(color: MusicTheme.label),
          title: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontHeadline,
            ),
          ),
          actions: [
            IconButton(
              tooltip: '播放全部',
              icon: Icon(Icons.play_circle_outline_rounded,
                  color: MusicTheme.tint),
              onPressed: _songs.isEmpty
                  ? null
                  : () => MusicPlayerManager.instance
                      .playQueue(_songs, index: 0),
            ),
          ],
        ),
        body: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: MusicTheme.tint));
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 140),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Row(
            children: [
              CoverImage(
                url: widget.coverUrl.isEmpty ? null : widget.coverUrl,
                size: 64,
                cornerRadius: 14,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: MusicTheme.label,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_songs.length} 首 · 来自 ${widget.source.name}',
                      style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: AppTheme.fontFootnote,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_error.isNotEmpty && _songs.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontSubhead,
              ),
            ),
          ),
        for (var i = 0; i < _songs.length; i++)
          SongCell(
            song: _songs[i],
            index: i,
            playbackContext: _songs,
          ),
      ],
    );
  }
}
