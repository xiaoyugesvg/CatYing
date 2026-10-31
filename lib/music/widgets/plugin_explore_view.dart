// lib/music/widgets/plugin_explore_view.dart
//
// 插件内容视图（榜单 + 推荐歌单）—— 2026-10-21。
//
// 发现页「推荐」Tab 的内容本体（可嵌入组件，自带下拉刷新）。
// 原先还有一个独立的 `PluginExplorePage` 外壳；「插件推荐」横滑栏撤掉后
// 没有入口了，外壳一并删除，只留这个视图。
//
// 插件返回的 item 形状各家不同，所以这里**不建强模型**：直接把 Node
// 归一化后的 Map 存下来，点进详情时**原样回传**给插件
//（例如 `getMusicSheetInfo(sheetItem)` 需要它自己那套字段）。

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/models/third_party_source.dart';
import 'package:tvbox/music/services/music_api.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/music_components.dart';
import 'package:tvbox/music/widgets/mo_lv_blocks.dart';
import 'package:tvbox/music/pages/plugin_song_list_page.dart';

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

/// 推荐歌单的一个标签。
///
/// `value` 是**插件原始形态**（字符串 或 `{id,title}` 对象），点标签时原样回传：
/// 汽水这类插件靠对象里的 `id`（频道号）取歌单，转成字符串就查不到。
class _PTag {
  const _PTag({required this.title, required this.value});
  final String title;
  final Object? value;
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
  List<({String name, List<_PTag> tags})> _tagGroups = const [];

  /// 当前选中的标签：`title` 只用于显示/高亮，`value` 原样回传给插件
  String _tagTitle = '';
  Object? _tagValue;

  List<_PItem> _sheets = const [];

  /// 「热门单曲」：从第一个榜单取前 10 首。
  /// 汽水这类插件只给 3 个榜单、没有别的入口，不加这块整页就是一大片空白。
  List<Song> _hotSongs = const [];
  bool _hotLoading = false;

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

      final tagGroups = <({String name, List<_PTag> tags})>[];
      for (final g in (tags['list'] as List? ?? const [])) {
        if (g is! Map) continue;
        final ts = <_PTag>[];
        for (final e in (g['tags'] as List? ?? const [])) {
          if (e is Map) {
            final title = (e['title'] ?? '').toString().trim();
            if (title.isNotEmpty) ts.add(_PTag(title: title, value: e['value']));
          } else {
            final title = e.toString().trim();
            if (title.isNotEmpty) ts.add(_PTag(title: title, value: e));
          }
        }
        if (ts.isNotEmpty) {
          tagGroups.add((name: (g['name'] ?? '标签').toString(), tags: ts));
        }
      }

      setState(() {
        _groups = groups;
        _tagGroups = tagGroups;
        _loading = false;
        // 榜单/歌单都没有 → 给明确说明（不是"空白页"）
        // 带上插件名：同平台可能有多个插件（如咪咕官方版 / Cookie 版），
        // 只说"该插件"用户根本不知道该换哪个（2026-10-25）。
        if (groups.isEmpty && tagGroups.isEmpty) {
          _error = '「${widget.source.name}」没有提供榜单或推荐歌单'
              '（只支持搜索/取地址）\n\n'
              '同平台若装了支持榜单的插件（如咪咕官方版），'
              '在「我的 → 音源管理」里启用后会自动改用它';
        }
      });

      final firstTag = tagGroups.isNotEmpty ? tagGroups.first.tags.first : null;
      if (firstTag != null) await _loadSheets(firstTag.value, firstTag.title);
      // 热门单曲不阻塞首屏：骨架先出来，回来再补
      unawaited(_loadHotSongs());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadSheets(Object? value, String title) async {
    setState(() {
      _tagValue = value;
      _tagTitle = title;
      _sheets = const [];
      _sheetPage = 1;
      _sheetEnd = false;
    });
    final r = await api.musicFreeAction(
      widget.source,
      'musicFreeRecommendSheets',
      params: {'tag': value, 'page': 1},
    );
    if (!mounted) return;
    setState(() {
      _sheets = _parseSheets(r);
      _sheetEnd = r['isEnd'] == true || _sheets.isEmpty;
    });
  }

  /// 加载下一页推荐歌单并**追加**
  Future<void> _loadMoreSheets() async {
    if (_loadingMore || _sheetEnd || _tagTitle.isEmpty) return;
    setState(() => _loadingMore = true);
    final next = _sheetPage + 1;
    final r = await api.musicFreeAction(
      widget.source,
      'musicFreeRecommendSheets',
      params: {'tag': _tagValue, 'page': next},
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

  /// 「热门单曲」：取第一个榜单的前 10 首
  Future<void> _loadHotSongs() async {
    if (_groups.isEmpty) return;
    setState(() => _hotLoading = true);
    final first = _groups.first.items.first;
    final r = await api.musicFreeAction(
      widget.source,
      'musicFreeTopListDetail',
      params: {'topListItem': first.raw},
    );
    if (!mounted) return;
    final songs = <Song>[];
    for (final e in (r['list'] as List? ?? const [])) {
      if (e is! Map) continue;
      try {
        // 插件歌没有平台归属 → 打上 pluginId，播放时问这个插件要地址
        songs.add(Song.fromJson(Map<String, dynamic>.from(e))
            .withPluginId(widget.source.id));
      } catch (_) {
        // 单条坏数据不影响整块
      }
      if (songs.length >= 10) break;
    }
    setState(() {
      _hotSongs = songs;
      _hotLoading = false;
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
          else if (_tagTitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                '「$_tagTitle」下没有歌单',
                style: TextStyle(
                  color: MusicTheme.secondary,
                  fontSize: AppTheme.fontSubhead,
                ),
              ),
            ),
          // ── 热门单曲 → 「墨律」三件套（2026-10-31）─────────────────
          //
          // 插件只给榜单（汽水就 3 个榜）时，光靠横向卡片整页很空；
          // 这里把第一个榜单的前 10 首按设计稿铺开：
          //   hero 大卡 → 今日推荐 3 方卡 → 榜单热歌 01/02/03 编号列表
          // 和「推荐 / 网易 / 酷狗」那套是**同一批组件**，所以汽水、咪咕、
          // B站、第三方插件看起来跟内置平台完全一致。
          if (_hotSongs.isNotEmpty) ...[
            MoLvHeroCard(
              badge: '每日推荐',
              title: _hotSongs.first.name,
              subtitle:
                  '${_hotSongs.first.artists} · 共 ${_hotSongs.length} 首 · 每天更新',
              accent: MusicTheme.tint,
              coverUrl: _hotSongs.first.coverUrl,
              onPlay: () =>
                  MusicPlayerManager.instance.playQueue(_hotSongs, index: 0),
            ),
            if (_hotSongs.length > 1) ...[
              const MoLvSectionTitle(title: '今日推荐', trailing: '为你挑的'),
              MoLvRecGrid(
                songs: _hotSongs.skip(1).toList(),
                accent: MusicTheme.tint,
                onTap: (i) => MusicPlayerManager.instance
                    .playQueue(_hotSongs, index: i + 1),
              ),
            ],
            if (_hotSongs.length > 4) ...[
              MoLvSectionTitle(
                title: '榜单热歌',
                trailing: '热门单曲',
                onMore: () =>
                    MusicPlayerManager.instance.playQueue(_hotSongs, index: 0),
              ),
              ListenableBuilder(
                listenable: MusicPlayerManager.instance,
                builder: (context, _) => MoLvChartList(
                  songs: _hotSongs.skip(4).toList(),
                  accent: MusicTheme.tint,
                  playingKey:
                      MusicPlayerManager.instance.currentSong?.identityKey,
                  isPlaying: MusicPlayerManager.instance.isPlaying.value,
                  onTap: (i) => MusicPlayerManager.instance
                      .playQueue(_hotSongs, index: i + 4),
                ),
              ),
            ],
          ] else if (_hotLoading) ...[
            const SectionTitle(title: '热门单曲'),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: MusicTheme.tint,
                  ),
                ),
              ),
            ),
          ],
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

  Widget _tagChip(_PTag tag) {
    final on = tag.title == _tagTitle;
    return GestureDetector(
      onTap: () => _loadSheets(tag.value, tag.title),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: on ? MusicTheme.tint : MusicTheme.fill,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          tag.title,
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
