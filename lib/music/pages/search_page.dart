import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../widgets/music_components.dart';

/// 搜索页 —— 移植自 Beans 的 `SearchView.swift`（1127 行，取其主干）。
///
/// ── 与 Beans 一致的部分 ───────────────────────────────────────
///   · 顶部搜索框（聚焦时展示"取消"）
///   · 未输入时：**搜索历史**（可清空）+ **热门搜索**（词云/列表）
///   · 输入后：**分类切换**（单曲 / 歌手 / 专辑）
///   · 单曲结果整列表作为播放队列（这样才有"下一首"）
///   · 搜索历史持久化
///
/// Beans 还有"歌单/歌词"搜索分类，本项目公开接口没做，所以只留 3 类。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

enum _Kind { song, artist, album }

class _SearchPageState extends State<SearchPage>
    with AutomaticKeepAliveClientMixin {
  final api = MusicApi.instance;
  final ctrl = TextEditingController();
  final focus = FocusNode();

  _Kind _kind = _Kind.song;
  bool _loading = false;
  String _error = '';

  List<Song> _songs = const [];
  List<Artist> _artists = const [];
  List<Album> _albums = const [];

  List<String> _history = const [];
  List<String> _hot = const [];

  static const _kHistory = 'music.searchHistory.v1';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadHot();
    focus.addListener(() => setState(() {}));
  }

  /// #10：搜索防抖定时器（300ms）
  ///
  /// 原来 `onChanged` 只 `setState({})` —— **输入时不搜索**，必须按回车。
  /// 现在改成"停止输入 300ms 后自动搜"，同时**防抖**：
  /// 快速打字只会在最后一次停顿后发一次请求，不会每个字符都发。
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel(); // 不取消的话：页面已销毁，定时器仍会触发网络请求
    ctrl.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _history = prefs.getStringList(_kHistory) ?? const []);
  }

  Future<void> _pushHistory(String kw) async {
    final k = kw.trim();
    if (k.isEmpty) return;
    final next = [k, ..._history.where((e) => e != k)].take(20).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kHistory, next);
    if (mounted) setState(() => _history = next);
  }

  Future<void> _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kHistory);
    if (mounted) setState(() => _history = const []);
  }

  Future<void> _loadHot() async {
    final h = await api.hotSearch();
    if (!mounted) return;
    setState(() => _hot = h);
  }

  Future<void> _run(String kw) async {
    final k = kw.trim();
    if (k.isEmpty) return;
    ctrl.text = k;
    ctrl.selection =
        TextSelection.collapsed(offset: k.length);
    focus.unfocus();
    setState(() {
      _loading = true;
      _error = '';
      _songs = const [];
      _artists = const [];
      _albums = const [];
    });
    await _pushHistory(k);

    try {
      switch (_kind) {
        case _Kind.song:
          final r = await api.search(k, limit: 40);
          if (!mounted) return;
          setState(() {
            _loading = false;
            _songs = r.list;
            if (!r.ok) _error = r.message;
          });
        case _Kind.artist:
          final r = await api.searchArtists(k, limit: 30);
          if (!mounted) return;
          setState(() {
            _loading = false;
            _artists = r.list;
            if (!r.ok) _error = r.message;
          });
        case _Kind.album:
          final r = await api.searchAlbums(k, limit: 30);
          if (!mounted) return;
          setState(() {
            _loading = false;
            _albums = r.list;
            if (!r.ok) _error = r.message;
          });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  bool get _searching => ctrl.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _searchBar(),
          if (_searching) _kindTabs(),
          Expanded(
            child: _searching ? _results() : _landingPage(),
          ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: MusicTheme.fill,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.search_rounded,
                      size: 18, color: MusicTheme.secondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: ctrl,
                      focusNode: focus,
                      textInputAction: TextInputAction.search,
                      onSubmitted: _run,
                      onChanged: (v) {
                        // 只重建（清空按钮/空状态要跟着变）
                        setState(() {});
                        // 防抖后再真搜（300ms）
                        _debounce?.cancel();
                        final k = v.trim();
                        if (k.isEmpty) return; // 清空时回到落地页，不发请求
                        _debounce = Timer(const Duration(milliseconds: 300), () {
                          if (!mounted) return;
                          unawaited(_run(k));
                        });
                      },
                      style: TextStyle(
                          color: MusicTheme.label, fontSize: 15),
                      cursorColor: MusicTheme.tint,
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '搜索歌曲、歌手、专辑',
                        hintStyle: TextStyle(
                            color: MusicTheme.secondary, fontSize: 14),
                      ),
                    ),
                  ),
                  if (_searching)
                    GestureDetector(
                      onTap: () {
                        ctrl.clear();
                        setState(() {});
                      },
                      child: Icon(Icons.cancel,
                          size: 16, color: MusicTheme.secondary),
                    ),
                ],
              ),
            ),
          ),
          if (focus.hasFocus || _searching)
            TextButton(
              onPressed: () {
                ctrl.clear();
                focus.unfocus();
                setState(() {});
              },
              child: Text('取消',
                  style: TextStyle(color: MusicTheme.tint, fontSize: 14)),
            ),
        ],
      ),
    );
  }

  Widget _kindTabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: _Kind.values.map((k) {
          final active = k == _kind;
          final label = switch (k) {
            _Kind.song => '单曲',
            _Kind.artist => '歌手',
            _Kind.album => '专辑',
          };
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () {
                setState(() => _kind = k);
                if (_searching) _run(ctrl.text);
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: active
                      ? MusicTheme.tint.withValues(alpha: 0.16)
                      : MusicTheme.fill,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(label,
                    style: TextStyle(
                      color: active ? MusicTheme.tint : MusicTheme.secondary,
                      fontSize: 13,
                      fontWeight:
                          active ? FontWeight.w600 : FontWeight.w400,
                    )),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ============================================================
  // 落地页（历史 + 热门）
  // ============================================================

  Widget _landingPage() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 150),
      children: [
        if (_history.isNotEmpty) ...[
          Row(
            children: [
              Text('搜索历史',
                  style: TextStyle(
                      color: MusicTheme.label,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              GestureDetector(
                onTap: _clearHistory,
                child: Icon(Icons.delete_outline,
                    size: 18, color: MusicTheme.secondary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _history
                .map((h) => _chip(h, () => _run(h), filled: true))
                .toList(),
          ),
          const SizedBox(height: 26),
        ],
        if (_hot.isNotEmpty) ...[
          Row(
            children: [
              Text('热门搜索',
                  style: TextStyle(
                      color: MusicTheme.label,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              GestureDetector(
                onTap: _loadHot,
                child: Icon(Icons.refresh_rounded,
                    size: 17, color: MusicTheme.secondary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _hot
                .take(20)
                .toList()
                .asMap()
                .entries
                .map((e) => _chip(
                      e.value,
                      () => _run(e.value),
                      hot: e.key < 3,
                    ))
                .toList(),
          ),
        ],
        if (_history.isEmpty && _hot.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 60),
            child: Center(
              child: Text('输入关键词开始搜索',
                  style:
                      TextStyle(color: MusicTheme.secondary, fontSize: 13)),
            ),
          ),
      ],
    );
  }

  Widget _chip(String text, VoidCallback onTap,
      {bool filled = false, bool hot = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: filled ? MusicTheme.tint.withValues(alpha: 0.12) : MusicTheme.fill,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hot) ...[
              Icon(Icons.local_fire_department_rounded,
                  size: 13, color: MusicTheme.tint),
              const SizedBox(width: 4),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: filled ? MusicTheme.tint : MusicTheme.label,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 结果
  // ============================================================

  Widget _results() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: MusicTheme.tint));
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(_error,
              textAlign: TextAlign.center,
              style: TextStyle(color: MusicTheme.secondary, fontSize: 13)),
        ),
      );
    }

    switch (_kind) {
      case _Kind.song:
        if (_songs.isEmpty) return _empty();
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 150),
          itemCount: _songs.length,
          itemBuilder: (c, i) => SongCell(
            song: _songs[i],
            playbackContext: _songs,
          ),
        );
      case _Kind.artist:
        if (_artists.isEmpty) return _empty();
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 150),
          itemCount: _artists.length,
          itemBuilder: (c, i) {
            final a = _artists[i];
            return ListTile(
              leading: CoverImage(
                  url: a.avatarUrl, size: 46, cornerRadius: 23),
              title: Text(a.name,
                  style: TextStyle(color: MusicTheme.label, fontSize: 15)),
              subtitle: Text('歌手',
                  style:
                      TextStyle(color: MusicTheme.secondary, fontSize: 12)),
              onTap: () => _openArtist(a),
            );
          },
        );
      case _Kind.album:
        if (_albums.isEmpty) return _empty();
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 150),
          itemCount: _albums.length,
          itemBuilder: (c, i) {
            final al = _albums[i];
            return ListTile(
              leading: CoverImage(url: al.coverUrl, size: 46, cornerRadius: 8),
              title: Text(al.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: MusicTheme.label, fontSize: 15)),
              subtitle: Text(al.artist ?? '',
                  style:
                      TextStyle(color: MusicTheme.secondary, fontSize: 12)),
              onTap: () => _openAlbum(al),
            );
          },
        );
    }
  }

  Widget _empty() => Center(
        child: Text('没有找到相关结果',
            style: TextStyle(color: MusicTheme.secondary, fontSize: 13)),
      );

  Future<void> _openArtist(Artist a) async {
    final songs = await api.artistSongs(a.id);
    if (!mounted) return;
    if (songs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${a.name} 没有可播放的歌曲')),
      );
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _SongListPage(title: a.name, songs: songs),
    ));
  }

  Future<void> _openAlbum(Album al) async {
    final songs = await api.albumSongs(al.id);
    if (!mounted) return;
    if (songs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${al.name} 没有可播放的歌曲')),
      );
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _SongListPage(title: al.name, songs: songs),
    ));
  }
}

/// 通用歌曲列表页（歌手热门 / 专辑曲目）
class _SongListPage extends StatelessWidget {
  const _SongListPage({required this.title, required this.songs});

  final String title;
  final List<Song> songs;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        backgroundColor: MusicTheme.background,
        appBar: AppBar(
          backgroundColor: MusicTheme.background,
          elevation: 0,
          iconTheme: IconThemeData(color: MusicTheme.label),
          title: Text(title,
              style: TextStyle(color: MusicTheme.label, fontSize: 16)),
          actions: [
            IconButton(
              tooltip: '播放全部',
              icon: Icon(Icons.play_circle_outline_rounded,
                  color: MusicTheme.tint),
              onPressed: () =>
                  MusicPlayerManager.instance.playQueue(songs, index: 0),
            ),
          ],
        ),
        body: ListView.builder(
          padding: const EdgeInsets.only(bottom: 120),
          itemCount: songs.length,
          itemBuilder: (c, i) =>
              SongCell(song: songs[i], index: i, playbackContext: songs),
        ),
      ),
    );
  }
}
