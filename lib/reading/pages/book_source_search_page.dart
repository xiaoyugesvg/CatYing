import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/book_source.dart';
import '../services/book_source_service.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_pull_cord.dart';
import '../widgets/jelly_sliding_actions.dart';
import 'book_source_detail_page.dart';
import 'book_source_repo_page.dart';

/// 书源搜索页 —— 用已导入的 Legado 书源跨站搜小说。
///
/// ── 对应 cmbok V2.0.7 ─────────────────────────────────────────
/// 截图里「搜索书源图书」那个入口 + 书源页右上角图标组。
/// 源码不可得（2.0.7 后闭源），这里依据截图与更新说明复刻：
///   · 多源并发搜索，**边搜边显示**（不等全部源跑完）
///   · 结果按书聚合去重，同一本书只出现一次（可点开看分别来自哪些源）
///   · 顶部显示搜索进度（已 N/M 个源）
class BookSourceSearchPage extends StatefulWidget {
  const BookSourceSearchPage({super.key, this.initialKeyword = ''});

  final String initialKeyword;

  @override
  State<BookSourceSearchPage> createState() => _BookSourceSearchPageState();
}

class _BookSourceSearchPageState extends State<BookSourceSearchPage> {
  final _ctrl = TextEditingController();
  final store = BookSourceStore.instance;

  bool _searching = false;
  String _keyword = '';

  /// 已聚合的结果（按 identityKey 去重，保留每个源各自的条目）
  final Map<String, List<BookSourceResult>> _grouped = {};
  final List<SourceSearchState> _states = [];
  int _doneCount = 0;
  int _totalCount = 0;

  /// 搜索会话号：用户改了关键词后，旧会话的回调必须被忽略
  int _session = 0;

  @override
  void initState() {
    super.initState();
    _ctrl.text = widget.initialKeyword;
    if (widget.initialKeyword.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _titleColor =>
      _isDark ? Colors.white : JellyTheme.textPrimaryLight;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  Future<void> _run() async {
    final kw = _ctrl.text.trim();
    if (kw.isEmpty) {
      _toast('请输入书名或作者');
      return;
    }
    final enabled = store.enabled;
    if (enabled.isEmpty) {
      _toast('还没有启用的书源，先去导入');
      return;
    }

    FocusScope.of(context).unfocus();
    final mySession = ++_session;
    setState(() {
      _searching = true;
      _keyword = kw;
      _grouped.clear();
      _states.clear();
      _doneCount = 0;
      _totalCount = enabled.length;
    });

    await BookSourceService.instance.searchAll(
      enabled,
      kw,
      shouldStop: () => !mounted || _session != mySession,
      onSourceResults: (st, list) {
        if (!mounted || _session != mySession) return;
        setState(() {
          _perSource[st.source.id] = list;
          _states.add(st);
          _doneCount++;
          rebuildGroups();
        });
      },
    );

    if (!mounted || _session != mySession) return;
    setState(() => _searching = false);
  }

  /// 从各源结果重建聚合视图。
  ///
  /// 「边搜边显示」的关键：每收到一个源的结果就重建一次，
  /// 用户不必等 40 个源全跑完才看到东西。
  void rebuildGroups() {
    _grouped.clear();
    _perSource.forEach((_, list) {
      for (final r in list) {
        _grouped.putIfAbsent(r.identityKey, () => []).add(r);
      }
    });
  }

  /// 单源结果暂存（onSourceResults 时写入）
  final Map<String, List<BookSourceResult>> _perSource = {};

  /// 所有已到结果按书名聚合
  List<_BookGroup> get _groups {
    final out = <_BookGroup>[];
    _grouped.forEach((k, v) {
      if (v.isEmpty) return;
      out.add(_BookGroup(key: k, items: v));
    });
    // 来源多的排前面（更可能有完整章节），其次书名
    out.sort((a, b) {
      final c = b.items.length.compareTo(a.items.length);
      return c != 0 ? c : a.items.first.name.compareTo(b.items.first.name);
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          _isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        titleSpacing: 0,
        // ── 标题行（按截图：一行放下全部控件）──────────────────
        //   书源 ⋮拉绳  [搜索书源图书]  (工具) (历史) (菜单)
        //
        // 原来是"AppBar 里只放标题+拉绳+图标组，搜索框在下面单独一行"。
        // 截图里是一行，所以把搜索框并进 AppBar 的 title。
        // 用 Expanded 撑开，右侧 actions 才不会被长标题/长搜索框挤掉。
        title: Row(
          children: [
            Text('书源',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: _titleColor)),
            const SizedBox(width: 4),
            JellyPullCord(
              // ⚠️ 限高，否则绳子把整行撑到 50px 导致同排控件错位
              height: 40,
              tooltip: '切换到图书',
              // 书源页是 push 进来的，所以"切回图书"就是 pop。
              // 用 pop 而不是再 push 一个图书页：否则连点几下会在栈里
              // 堆出一串页面，返回键要按很多次才出得去。
              onTap: () => Navigator.maybePop(context),
            ),
            const SizedBox(width: 10),
            Expanded(child: _searchField()),
          ],
        ),
        actions: [
          JellySlidingActions(
            isDark: _isDark,
            width: 130,
            actions: [
              JellyAction(
                icon: Icons.manage_search_rounded,
                tooltip: '书源仓库',
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const BookSourceRepoPage()),
                  );
                  if (mounted) setState(() {});
                },
              ),
              JellyAction(
                icon: Icons.health_and_safety_rounded,
                tooltip: '书源体检',
                onPressed: () => _toast('请在书源仓库里点「体检」'),
              ),
              JellyAction(
                icon: Icons.clear_all_rounded,
                tooltip: '清空结果',
                onPressed: () => setState(() {
                  _grouped.clear();
                  _states.clear();
                  _perSource.clear();
                  _doneCount = 0;
                  _totalCount = 0;
                }),
              ),
            ],
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          // 搜索框已并入 AppBar 的标题行（按截图的一行布局），
          // 这里不再重复渲染。
          if (_searching) _progressBar(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  /// 搜索框本体（不带外边距）—— 放在 AppBar 的 title 里，
  /// 由外层 Row 的 Expanded 负责宽度。
  Widget _searchField() {
    return TextField(
        controller: _ctrl,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _run(),
        style: TextStyle(fontSize: 15, color: _titleColor),
        decoration: InputDecoration(
          hintText: '搜索书源图书',
          hintStyle: TextStyle(fontSize: 15, color: JellyTheme.textSecondary),
          prefixIcon: Icon(Icons.search_rounded,
              size: 20, color: JellyTheme.textSecondary),
          suffixIcon: _searching
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : null,
          filled: true,
          fillColor: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
    );
  }

  /// 搜索进度：已 N/M 个源。
  ///
  /// 为什么要显示：导入 40 个源时最慢的源可能要十几秒，
  /// 没有进度用户会以为卡死并反复退出。
  Widget _progressBar() {
    final ok = _states.where((s) => s.ok).length;
    final bad = _states.where((s) => !s.ok).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: _totalCount == 0 ? null : _doneCount / _totalCount,
              color: JellyTheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '已搜索 $_doneCount/$_totalCount 个源'
            '${ok > 0 ? ' · 成功 $ok' : ''}'
            '${bad > 0 ? ' · 失败 $bad' : ''}',
            style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (store.enabled.isEmpty) return _emptySources();
    if (_groups.isEmpty) {
      if (_searching) return const SizedBox.shrink();
      if (_keyword.isEmpty) {
        return _hint('输入书名或作者，跨所有已启用书源搜索',
            Icons.manage_search_rounded);
      }
      return _hint('没有搜到「$_keyword」', Icons.search_off_rounded);
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: _groups.length,
      itemBuilder: (c, i) => _bookTile(_groups[i]),
    );
  }

  Widget _emptySources() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_outlined,
                size: 56,
                color: JellyTheme.textSecondary.withValues(alpha: 0.55)),
            const SizedBox(height: 20),
            Text('还没有书源',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: _titleColor)),
            const SizedBox(height: 8),
            Text('用地址、口令或本地文件导入书源',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 13, color: JellyTheme.textSecondary)),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const BookSourceRepoPage()),
                );
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('去导入书源'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hint(String text, IconData icon) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 48,
                color: JellyTheme.textSecondary.withValues(alpha: 0.5)),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13, color: JellyTheme.textSecondary)),
            ),
          ],
        ),
      );

  Widget _bookTile(_BookGroup g) {
    final first = g.items.first;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        leading: _cover(first.coverUrl),
        title: Text(
          first.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w600, color: _titleColor),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              [
                if (first.author.isNotEmpty) first.author,
                if (first.kind.isNotEmpty) first.kind,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
            ),
            const SizedBox(height: 4),
            // 来源标签：点开可以选从哪个源看（换源的基础）
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: g.items
                  .take(4)
                  .map((r) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: JellyTheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          r.source.name,
                          style: TextStyle(
                              fontSize: 10.5, color: JellyTheme.primary),
                        ),
                      ))
                  .toList(),
            ),
            if (g.items.length > 4)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('等 ${g.items.length} 个源',
                    style: TextStyle(
                        fontSize: 10.5, color: JellyTheme.textSecondary)),
              ),
          ],
        ),
        trailing: Icon(Icons.chevron_right_rounded,
            color: JellyTheme.textSecondary),
        onTap: () => _open(g),
      ),
    );
  }

  Widget _cover(String url) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 46,
        height: 62,
        child: url.isEmpty
            ? Container(
                color: JellyTheme.primary.withValues(alpha: 0.1),
                child: Icon(Icons.menu_book_rounded,
                    size: 20, color: JellyTheme.primary),
              )
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Container(
                  color: JellyTheme.primary.withValues(alpha: 0.1),
                  child: Icon(Icons.menu_book_rounded,
                      size: 20, color: JellyTheme.primary),
                ),
              ),
      ),
    );
  }

  Future<void> _open(_BookGroup g) async {
    // 单源直接进；多源先让用户选（这就是"换源"的入口）
    BookSourceResult chosen = g.items.first;
    if (g.items.length > 1) {
      final picked = await showModalBottomSheet<BookSourceResult>(
        context: context,
        backgroundColor:
            _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 14),
              Text('选择书源（${g.items.length} 个）',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: _titleColor)),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: g.items
                      .map((r) => ListTile(
                            title: Text(r.source.name,
                                style:
                                    TextStyle(fontSize: 14, color: _titleColor)),
                            subtitle: Text(
                              r.lastChapter.isNotEmpty
                                  ? r.lastChapter
                                  : (r.wordCount.isNotEmpty
                                      ? r.wordCount
                                      : r.bookUrl),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: JellyTheme.textSecondary),
                            ),
                            onTap: () => Navigator.pop(ctx, r),
                          ))
                      .toList(),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      );
      if (picked == null) return;
      chosen = picked;
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookSourceDetailPage(result: chosen),
      ),
    );
  }
}

class _BookGroup {
  _BookGroup({required this.key, required this.items});
  final String key;
  final List<BookSourceResult> items;
}
