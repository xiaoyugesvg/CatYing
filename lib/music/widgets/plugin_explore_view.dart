// lib/music/widgets/plugin_explore_view.dart
//
// 插件内容视图（榜单 + 推荐歌单）—— 2026-10-21。
//
// 从 `PluginExplorePage` 抽出来的**可嵌入组件**：
//   · 插件发现页（独立页面）用它
//   · 发现页「推荐」Tab 也用它（同一份逻辑，不复制）
//
// 插件返回的 item 形状各家不同，所以这里**不建强模型**：直接把 Node
// 归一化后的 Map 存下来，点进详情时**原样回传**给插件
//（例如 `getMusicSheetInfo(sheetItem)` 需要它自己那套字段）。

import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../models/third_party_source.dart';
import '../services/music_api.dart';
import '../theme/music_theme.dart';
import 'music_components.dart';
import '../pages/plugin_song_list_page.dart';

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

class PluginExploreView extends StatefulWidget {
  const PluginExploreView({super.key, required this.source});

  final ThirdPartySource source;

  @override
  State<PluginExploreView> createState() => _PluginExploreViewState();
}

class _PluginExploreViewState extends State<PluginExploreView> {
  final api = MusicApi.instance;

  bool _loading = true;
  String _error = '';

  List<_PGroup> _groups = const [];
  List<({String name, List<String> tags})> _tagGroups = const [];
  String _tag = '';
  List<_PItem> _sheets = const [];

  /// 推荐歌单分页状态（支持「加载更多」）
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

  /// 加载下一页推荐歌单并**追加**
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
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: MusicTheme.tint));
    }
    if (_error.isNotEmpty && _groups.isEmpty && _tagGroups.isEmpty) {
      return RefreshIndicator(
        color: MusicTheme.tint,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
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
          ],
        ),
      );
    }
    return RefreshIndicator(
      color: MusicTheme.tint,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
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
                    for (final t in g.tags) _tagChip(t),
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
      ),
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
