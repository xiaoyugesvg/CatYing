import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/models/third_party_source.dart';
import 'package:tvbox/music/services/music_api.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/services/settings_store.dart';
import 'package:tvbox/music/pages/ximalaya_category_page.dart';
import 'package:tvbox/music/pages/ximalaya_album_page.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/music_components.dart';
import 'package:tvbox/music/widgets/music_sheet.dart';
import 'package:tvbox/widgets/app_page_loading.dart';
import 'package:tvbox/common/theme.dart';

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

  /// 当前选中的 **MusicFree 插件源**（null = 用内置平台）。
  ///
  /// 2026-10-21 第二阶段：插件从"播放兜底"变成**可搜索的平台**。
  /// 歌曲结果会带上 `pluginId`（播放器据此优先用同一个插件取地址）；
  /// 第三阶段补齐：歌手 / 专辑分类也走插件（type=artist/album）。
  ThirdPartySource? _plugin;

  List<Song> _songs = const [];
  List<Artist> _artists = const [];
  List<Album> _albums = const [];

  /// 插件搜索的**原始歌手/专辑条目**（字段与内置模型不同，点详情时原样回传）
  List<Map<String, dynamic>> _pluginArtists = const [];
  List<Map<String, dynamic>> _pluginAlbums = const [];

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

  /// 搜索代次（见 `_run`）：只认最后一次发起的搜索。
  int _runEpoch = 0;

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
    // 搜索代次：快速连打关键词 / 切 tab 时，先发的请求后回来会把
    // 新结果覆盖成旧结果（防抖只解决"还没发"，不解决"已在途乱序"）。
    final epoch = ++_runEpoch;
    ctrl.text = k;
    ctrl.selection = TextSelection.collapsed(offset: k.length);
    focus.unfocus();
    setState(() {
      _loading = true;
      _error = '';
      _songs = const [];
      _artists = const [];
      _albums = const [];
      _pluginArtists = const [];
      _pluginAlbums = const [];
    });
    // 🔴 `_pushHistory` **必须放进 try**：
    // 它原本在 try **之外**（下一行才是 `try {`）→ 一旦它抛异常（写历史失败），
    // 流程就**跳过了下面的 catch** → `_loading` 永远停在 `true` ✗
    // → 搜索页**永久转圈**，而且再搜也救不回来（新的一次搜索又会走到这一行 ✗）。
    // 这就是"永久转圈"的最短路径。
    try {
      await _pushHistory(k);
      if (!mounted || epoch != _runEpoch) return;
      // ── 插件源：走该插件的 search()（2026-10-21 第二阶段）──────────
      //    2026-10-21 补充：歌手 / 专辑分类也走插件（type=artist/album）
      final plugin = _plugin;
      if (plugin != null) {
        if (_kind == _Kind.song) {
          final r = await api.searchByMusicFree(plugin, k, type: 'music');
          if (!mounted || epoch != _runEpoch) return;
          setState(() {
            _loading = false;
            // ⚠️ 必须打上 pluginId：插件歌没有真实平台归属，
            //   播放时要靠它找到"产出这首歌的插件"（见 player_manager._load）
            _songs = r.list.map((s) => s.withPluginId(plugin.id)).toList();
            if (!r.ok) _error = r.message;
          });
        } else {
          final r = await api.searchRawByMusicFree(
            plugin,
            k,
            type: _kind == _Kind.artist ? 'artist' : 'album',
          );
          if (!mounted || epoch != _runEpoch) return;
          setState(() {
            _loading = false;
            if (_kind == _Kind.artist) {
              _pluginArtists = r.list;
            } else {
              _pluginAlbums = r.list;
            }
            if (!r.ok) _error = r.message;
          });
        }
        return;
      }
      switch (_kind) {
        case _Kind.song:
          // 平台由「平台切换条」决定（默认网易云；不传时 Node 侧也默认 netease）
          final r = await api.search(
            k,
            limit: 40,
            source: SettingsStore.instance.musicSource.value,
          );
          if (!mounted || epoch != _runEpoch) return;
          setState(() {
            _loading = false;
            _songs = r.list;
            if (!r.ok) _error = r.message;
          });
        case _Kind.artist:
          final r = await api.searchArtists(k, limit: 30);
          if (!mounted || epoch != _runEpoch) return;
          setState(() {
            _loading = false;
            _artists = r.list;
            if (!r.ok) _error = r.message;
          });
        case _Kind.album:
          final r = await api.searchAlbums(k, limit: 30);
          if (!mounted || epoch != _runEpoch) return;
          setState(() {
            _loading = false;
            _albums = r.list;
            if (!r.ok) _error = r.message;
          });
      }
    } catch (e) {
      if (!mounted || epoch != _runEpoch) return;
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
          // 大标题只在「还没搜」时出现：输入后要立刻把纵向空间让给结果，
          // 搜索框自己会顶到最上面（iOS 搜索页的常见做法）。
          if (!_searching)
            const MusicPageHeader(
              title: '搜索',
              subtitle: '跨平台找歌 · 点一下就播',
              padding: EdgeInsets.fromLTRB(16, 10, 16, 2),
            ),
          _searchBar(),
          _platformBar(),
          if (_searching) _kindTabs(),
          Expanded(
            child: _searching ? _results() : _landingPage(),
          ),
        ],
      ),
    );
  }

  /// 平台切换条（网易云 / 酷狗）。
  ///
  /// 只决定"**搜索**用哪个内置数据源"；**播放地址不受它影响** ——
  /// 解析永远按每首歌自己的 `Song.source`（否则酷狗的歌会被拿酷狗 id
  /// 去查网易云，必然取不到地址）。
  Widget _platformBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      // 平台多了（内置 3 个 + 插件源）→ 横向滑动，不再挤出屏幕
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // 「有声书」**不是"平台切换"**，而是进分类页：
            // 喜马拉雅是**专辑模型**（专辑→单集），跟"单曲搜索"不是一回事；
            // 直接切换搜索平台会让搜索结果出现"点一下播不了"的假可用。
            GestureDetector(
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  settings: const RouteSettings(name: 'music:page'),
                  builder: (_) => const XimalayaCategoryPage(),
                ),
              ),
              child: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: MusicTheme.fill,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: MusicTheme.secondary.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.headphones_rounded,
                      size: 13,
                      color: MusicTheme.secondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '喜雅',
                      style: TextStyle(
                        color: MusicTheme.label,
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            for (final s in const [
              SongSource.netease,
              SongSource.kugou,
              SongSource.ximalaya,
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ValueListenableBuilder<SongSource>(
                  valueListenable: SettingsStore.instance.musicSource,
                  builder: (_, cur, __) {
                    final on = cur == s;
                    return GestureDetector(
                      onTap: () async {
                        if (on && _plugin == null) return;
                        await SettingsStore.instance.setMusicSource(s);
                        if (!mounted) return;
                        // 切回内置平台 ⇒ 退出插件搜索模式
                        setState(() => _plugin = null);
                        // 已有关键词就立刻用新平台重搜
                        final k = ctrl.text.trim();
                        if (k.isNotEmpty) unawaited(_run(k));
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: on ? MusicTheme.tint : MusicTheme.fill,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          s.displayName,
                          style: TextStyle(
                            color: on ? Colors.white : MusicTheme.label,
                            fontSize: AppTheme.fontCaption,
                            fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            // 插件源（2026-10-21 第二阶段）：点开选择已启用的 MusicFree 插件
            _pluginChip(),
          ],
        ),
      ),
    );
  }

  /// 「插件源」胶囊 + 选择弹层。
  ///
  /// 只列**已启用**的 MusicFree 插件（LX 脚本没有 search，不参与）。
  Widget _pluginChip() {
    final plugins = ThirdPartySourceStore.instance.enabled
        .where((s) => s.isMusicFree)
        .toList();
    final on = _plugin != null;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: plugins.isEmpty ? null : () => _pickPlugin(plugins),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: on ? MusicTheme.tint : MusicTheme.fill,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.extension_rounded,
                size: 13,
                color: on ? Colors.white : MusicTheme.secondary,
              ),
              const SizedBox(width: 4),
              Text(
                on
                    ? _plugin!.name
                    : '插件源${plugins.isEmpty ? '' : ' ${plugins.length}'}',
                style: TextStyle(
                  color: on ? Colors.white : MusicTheme.label,
                  fontSize: AppTheme.fontCaption,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickPlugin(List<ThirdPartySource> plugins) async {
    final id = await showMusicSheet<String>(
      context: context,
      backgroundColor: MusicTheme.card,
      isScrollControlled: true,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: Icon(Icons.apps_rounded, color: MusicTheme.secondary),
            title: Text('内置平台', style: TextStyle(color: MusicTheme.label)),
            subtitle: Text(
              '网易云 / 酷狗 / 喜马拉雅',
              style: TextStyle(color: MusicTheme.secondary, fontSize: 12),
            ),
            trailing: _plugin == null
                ? Icon(Icons.check_rounded, color: MusicTheme.tint, size: 20)
                : null,
            onTap: () => Navigator.pop(ctx, '__builtin__'),
          ),
          const Divider(height: 1),
          for (final p in plugins)
            ListTile(
              leading: Icon(
                Icons.extension_rounded,
                color: MusicTheme.secondary,
              ),
              title: Text(
                p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: MusicTheme.label),
              ),
              subtitle: p.quality.isEmpty
                  ? null
                  : Text(
                      '音质 ${p.quality}',
                      style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: 12,
                      ),
                    ),
              trailing: _plugin?.id == p.id
                  ? Icon(Icons.check_rounded, color: MusicTheme.tint, size: 20)
                  : null,
              onTap: () => Navigator.pop(ctx, p.id),
            ),
        ],
      ),
    );
    if (!mounted || id == null) return;
    setState(() {
      _plugin = id == '__builtin__'
          ? null
          : ThirdPartySourceStore.instance.byId(id);
      // 换源后回到「单曲」，避免把上一源的分类结果当成本源的结果
      _kind = _Kind.song;
    });
    final k = ctrl.text.trim();
    if (k.isNotEmpty) unawaited(_run(k));
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
                  Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: MusicTheme.secondary,
                  ),
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
                        _debounce = Timer(
                          const Duration(milliseconds: 300),
                          () {
                            if (!mounted) return;
                            unawaited(_run(k));
                          },
                        );
                      },
                      style: TextStyle(
                        color: MusicTheme.label,
                        fontSize: AppTheme.fontHeadline,
                      ),
                      cursorColor: MusicTheme.tint,
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '搜索歌曲、歌手、专辑',
                        hintStyle: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontBody,
                        ),
                      ),
                    ),
                  ),
                  if (_searching)
                    GestureDetector(
                      onTap: () {
                        ctrl.clear();
                        setState(() {});
                      },
                      child: Icon(
                        Icons.cancel,
                        size: 16,
                        color: MusicTheme.secondary,
                      ),
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
              child: Text(
                '取消',
                style: TextStyle(
                  color: MusicTheme.tint,
                  fontSize: AppTheme.fontBody,
                ),
              ),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: active
                      ? MusicTheme.tint.withValues(alpha: 0.16)
                      : MusicTheme.fill,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: active ? MusicTheme.tint : MusicTheme.secondary,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
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
              Text(
                '搜索历史',
                style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _clearHistory,
                child: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: MusicTheme.secondary,
                ),
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
              Text(
                '热门搜索',
                style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _loadHot,
                child: Icon(
                  Icons.refresh_rounded,
                  size: 17,
                  color: MusicTheme.secondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 对齐 Beans 截图⑤：热搜是**2 列等宽圆角格**，每条左侧一个放大镜图标
          // （原来是变宽的胶囊 Wrap，看起来"散"。用 LayoutBuilder 算列宽比
          //  嵌 GridView 安全：这里在 ListView 内部，嵌套滚动容易出问题）
          LayoutBuilder(
            builder: (c, cons) {
              const gap = 10.0;
              final w = (cons.maxWidth - gap) / 2;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: _hot
                    .take(8)
                    .map((k) => _hotCell(k, () => _run(k), w))
                    .toList(),
              );
            },
          ),
        ],
        if (_history.isEmpty && _hot.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 60),
            child: Center(
              child: Text(
                '输入关键词开始搜索',
                style: TextStyle(
                  color: MusicTheme.secondary,
                  fontSize: AppTheme.fontSubhead,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 热搜格（对齐 Beans 截图⑤）：等宽圆角格 + 左侧放大镜 + 文字左对齐。
  ///
  /// 图标用 `MusicTheme.tint` 而不是 Beans 的品牌红 —— 外观系统不动。
  Widget _hotCell(String text, VoidCallback onTap, double width) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: MusicTheme.fill,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 15, color: MusicTheme.tint),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontBody,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(
    String text,
    VoidCallback onTap, {
    bool filled = false,
    bool hot = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: filled
              ? MusicTheme.tint.withValues(alpha: 0.12)
              : MusicTheme.fill,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hot) ...[
              Icon(
                Icons.local_fire_department_rounded,
                size: 13,
                color: MusicTheme.tint,
              ),
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
                  fontSize: AppTheme.fontSubhead,
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
      return AppPageLoading(color: MusicTheme.tint);
    }
    if (_error.isNotEmpty) {
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

    switch (_kind) {
      case _Kind.song:
        if (_songs.isEmpty) return _empty();
        // ⚠️ 喜马拉雅的"搜索结果"其实是**专辑**（有声书没有单曲概念）。
        // 必须走专辑页、**不能直接播** —— 它的播放直链是跟着专辑单集列表
        // 一起返回的，直接拿专辑 id 去播只会得到"没取到直链"。
        // 🔴 按"**这批结果实际来自哪个平台**"渲染，而不是读**全局当前平台** ✗。
        // 原来读全局：搜完**再切平台**（比如切到喜马拉雅）→ 上一次的
        // 网易云结果会被当成"喜马拉雅专辑"渲染 ✗ / 反过来喜马拉雅的**专辑**
        // 被当单曲渲染 → **点了必然播失败** ✗。
        // 用结果自带的 `Song.source` 最可靠（它就是这批数据的真实来源 ✓）；
        // 结果为空时才退回全局值（此时渲染什么都不会有影响 ✓）。
        final fromXimalaya = _songs.isNotEmpty
            ? _songs.first.source == SongSource.ximalaya
            : SettingsStore.instance.musicSource.value == SongSource.ximalaya;
        if (fromXimalaya) {
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 150),
            itemCount: _songs.length,
            itemBuilder: (c, i) {
              final a = _songs[i];
              return ListTile(
                leading: CoverImage(url: a.coverUrl, size: 46, cornerRadius: 8),
                title: Text(
                  a.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontHeadline,
                  ),
                ),
                subtitle: Text(
                  a.artists.isEmpty ? '喜马拉雅专辑' : a.artists,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: MusicTheme.secondary,
                    fontSize: AppTheme.fontFootnote,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    settings: const RouteSettings(name: 'music:page'),
                    builder: (_) => XimalayaAlbumPage(
                      albumId: '${a.id}',
                      albumName: a.name,
                    ),
                  ),
                ),
              );
            },
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 150),
          itemCount: _songs.length,
          itemBuilder: (c, i) => SongCell(
            song: _songs[i],
            playbackContext: _songs,
          ),
        );
      case _Kind.artist:
        // 插件模式：歌手条目是插件原始 Map（字段与内置 Artist 不同）
        if (_plugin != null) return _pluginPeopleList(artist: true);
        if (_artists.isEmpty) return _empty();
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 150),
          itemCount: _artists.length,
          itemBuilder: (c, i) {
            final a = _artists[i];
            return ListTile(
              leading: CoverImage(url: a.avatarUrl, size: 46, cornerRadius: 23),
              title: Text(
                a.name,
                style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontHeadline,
                ),
              ),
              subtitle: Text(
                '歌手',
                style: TextStyle(
                  color: MusicTheme.secondary,
                  fontSize: AppTheme.fontFootnote,
                ),
              ),
              onTap: () => _openArtist(a),
            );
          },
        );
      case _Kind.album:
        // 插件模式：专辑条目同样是插件原始 Map
        if (_plugin != null) return _pluginPeopleList(artist: false);
        if (_albums.isEmpty) return _empty();
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 150),
          itemCount: _albums.length,
          itemBuilder: (c, i) {
            final al = _albums[i];
            return ListTile(
              leading: CoverImage(url: al.coverUrl, size: 46, cornerRadius: 8),
              title: Text(
                al.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontHeadline,
                ),
              ),
              subtitle: Text(
                al.artist ?? '',
                style: TextStyle(
                  color: MusicTheme.secondary,
                  fontSize: AppTheme.fontFootnote,
                ),
              ),
              onTap: () => _openAlbum(al),
            );
          },
        );
    }
  }

  Widget _empty() => Center(
    child: Text(
      '没有找到相关结果',
      style: TextStyle(
        color: MusicTheme.secondary,
        fontSize: AppTheme.fontSubhead,
      ),
    ),
  );

  /// 插件搜索的歌手 / 专辑列表（条目是插件的原始 Map）。
  Widget _pluginPeopleList({required bool artist}) {
    final list = artist ? _pluginArtists : _pluginAlbums;
    if (list.isEmpty) return _empty();
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 150),
      itemCount: list.length,
      itemBuilder: (c, i) {
        final m = list[i];
        final name = (m['name'] ?? '').toString();
        final cover = artist
            ? (m['avatar'] ?? '').toString()
            : (m['cover'] ?? '').toString();
        final sub = artist
            ? '歌手'
            : ((m['artist'] ?? '').toString().isEmpty
                  ? '专辑'
                  : (m['artist'] ?? '').toString());
        return ListTile(
          leading: CoverImage(
            url: cover.isEmpty ? null : cover,
            size: 46,
            cornerRadius: artist ? 23 : 8,
          ),
          title: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontHeadline,
            ),
          ),
          subtitle: Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: MusicTheme.secondary,
              fontSize: AppTheme.fontFootnote,
            ),
          ),
          trailing: Icon(
            Icons.chevron_right,
            size: 18,
            color: MusicTheme.secondary,
          ),
          onTap: () => artist ? _openPluginArtist(m) : _openPluginAlbum(m),
        );
      },
    );
  }

  /// 插件歌手 → 作品列表（`getArtistWorks(type:'music')`）
  Future<void> _openPluginArtist(Map<String, dynamic> raw) async {
    final p = _plugin;
    if (p == null) return;
    final r = await api.musicFreeAction(
      p,
      'musicFreeArtistWorks',
      params: {'artistItem': raw, 'page': 1, 'type': 'music'},
    );
    _openPluginSongList(r, p, (raw['name'] ?? '歌手').toString());
  }

  /// 插件专辑 → 曲目列表（`getAlbumInfo`）
  Future<void> _openPluginAlbum(Map<String, dynamic> raw) async {
    final p = _plugin;
    if (p == null) return;
    final r = await api.musicFreeAction(
      p,
      'musicFreeAlbumInfo',
      params: {'albumItem': raw, 'page': 1},
    );
    _openPluginSongList(r, p, (raw['name'] ?? '专辑').toString());
  }

  /// 把插件返回的歌曲列表变成 Song（带 pluginId）并打开列表页。
  void _openPluginSongList(
    Map<String, dynamic> r,
    ThirdPartySource p,
    String title,
  ) {
    if (!mounted) return;
    final songs = <Song>[];
    for (final e in (r['list'] as List? ?? const [])) {
      if (e is! Map) continue;
      try {
        songs.add(
          Song.fromJson(Map<String, dynamic>.from(e)).withPluginId(p.id),
        );
      } catch (_) {
        // 单条坏数据不影响整页
      }
    }
    if (songs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「$title」没有可播放的歌曲')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: 'music:page'),
        builder: (_) => _SongListPage(title: title, songs: songs),
      ),
    );
  }

  Future<void> _openArtist(Artist a) async {
    final songs = await api.artistSongs(a.id);
    if (!mounted) return;
    if (songs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${a.name} 没有可播放的歌曲')),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: 'music:page'),
        builder: (_) => _SongListPage(title: a.name, songs: songs),
      ),
    );
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
    await Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: 'music:page'),
        builder: (_) => _SongListPage(title: al.name, songs: songs),
      ),
    );
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
        // 原来是 `Colors.transparent` + AppBar —— push 到这个页面时
        // 底下已经没有内容可透，透明等于让系统底色露出来（深色下会发灰）。
        backgroundColor: MusicTheme.background,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // 和其他音乐子页面统一：返回按钮 + 大标题 + 一行说明
              MusicPageHeader(
                leading: const MusicBackButton(),
                title: title,
                subtitle: '${songs.length} 首',
                action: MusicRoundAction(
                  icon: Icons.play_arrow_rounded,
                  tooltip: '播放全部',
                  onTap: () =>
                      MusicPlayerManager.instance.playQueue(songs, index: 0),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(0, 6, 0, 120),
                  itemCount: songs.length,
                  itemBuilder: (c, i) => SongCell(
                    song: songs[i],
                    index: i,
                    playbackContext: songs,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
