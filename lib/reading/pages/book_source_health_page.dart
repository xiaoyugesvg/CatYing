// lib/reading/pages/book_source_health_page.dart
//
// 「书源体检」页 —— 对齐备份3.0 book_source_health_page（IMG_8554~8561）：
//   空闲页：  盾牌图标 + 流程文案 + 并发数选择(1/2/3/4/6/8/12) + 开始体检
//   进行中：进度 X/N + 并发 N + 发热提示 + 实时统计(可用/网络源站异常/解析失败)
//   完成页：体检完成·时间 + 统计 + 列表 + 全部/一键优化/清理
// 引擎接线（Nexhub WebBook）：逐源 取书(searchBook)→详情(getBookInfo)
//   →目录(getChapterList)→正文(getContent) 四环节，全部通过才算健康。
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../novel_source/model/book_source.dart';
import '../novel_source/model/search_book.dart';
import '../novel_source/model/xiaoshuo_book.dart';
import '../novel_source/model/xiaoshuo_book_chapter.dart';
import '../novel_source/shuyuan_source_service.dart';
import '../novel_source/web_book/web_book.dart';
import '../services/book_favorites_service.dart';
import '../services/shuyuan_source_store.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_search_bar.dart';

/// 体检进行状态
enum _Phase { idle, running, done }

/// 条目展示状态（由体检结果推导）
enum _ItemState { untested, healthy, networkFail, parseFail }

/// 单个源的体检结果
class _SourceHealth {
  final bool healthy;
  final Duration elapsed;
  final String detail;
  const _SourceHealth({
    required this.healthy,
    required this.elapsed,
    required this.detail,
  });
}

/// 失败归类：网络/源站类（超时/连接/4xx/5xx/验证） vs 解析类
enum _FailKind { network, parse }

class BookSourceHealthPage extends StatefulWidget {
  const BookSourceHealthPage({super.key});

  @override
  State<BookSourceHealthPage> createState() => _BookSourceHealthPageState();
}

class _BookSourceHealthPageState extends State<BookSourceHealthPage> {
  final WebBook _webBook = WebBook();

  _Phase _phaseVal = _Phase.idle;

  int _concurrency = 12;
  int _done = 0;

/// 已测结果缓存（按源 url）
final Map<String, _SourceHealth> _health = {};

  /// 统计 tab：0 全部 / 1 可用 / 4 网络异常 / 5 解析失败；2 收藏 / 3 密钥（无数据维度）
  int _statTab = 0;

  /// 分类：0 全部 / 1 通常书源 / 2 快速书源
int _groupTab = 0;

  final _searchCtrl = TextEditingController();
  String _kw = '';

  // 多选：选中的源 url
  final Set<String> _selected = {};
  bool _selectAll = false;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _titleColor => _isDark ? Colors.white : JellyTheme.textPrimaryLight;
  Color get _subColor => _isDark ? Colors.white54 : JellyTheme.textSecondary;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ============================================================
// 统计推导
  // ============================================================

  _ItemState _itemState(ShuyuanSource s) {
    final h = _health[s.bookSourceUrl];
    if (h == null) return _ItemState.untested;
    if (h.healthy) return _ItemState.healthy;
    final kind = _failKind(h.detail);
    return kind == _FailKind.network ? _ItemState.networkFail : _ItemState.parseFail;
  }

  int get _total => ShuyuanSourceStore.instance.allSources.length;
  int get _usable => ShuyuanSourceStore.instance.allSources
      .where((s) => _itemState(s) == _ItemState.healthy)
      .length;
  int get _networkFail => ShuyuanSourceStore.instance.allSources
      .where((s) => _itemState(s) == _ItemState.networkFail)
      .length;
  int get _parseFail => ShuyuanSourceStore.instance.allSources
      .where((s) => _itemState(s) == _ItemState.parseFail)
      .length;

  /// 分类分组：组名含「快速」→ 快速书源
bool _isFast(ShuyuanSource s) =>
      (s.bookSourceGroup ?? '').contains('快速');

/// 该源是否有被收藏的书（详情页收藏时带 sourceName）
bool _isFavoritedSource(ShuyuanSource s) => BookFavoritesService()
      .books
      .any((b) => (b.sourceName ?? '').isNotEmpty && b.sourceName == s.bookSourceName);

  /// 该源是否带登录态（密钥，header 含 Cookie/token 类字段）
  bool _isKeyedSource(ShuyuanSource s) {
    final h = (s.header ?? '').toLowerCase();
    return h.contains('cookie') || h.contains('token') || h.contains('secret');
  }

  List<ShuyuanSource> get _filtered {
    var list =
        List<ShuyuanSource>.of(ShuyuanSourceStore.instance.allSources);
    if (_kw.isNotEmpty) {
      final k = _kw.trim().toLowerCase();
      list = list
          .where((s) => s.bookSourceName.toLowerCase().contains(k))
          .toList();
    }
    switch (_statTab) {
      case 1:
        list = list
            .where((s) => _itemState(s) == _ItemState.healthy)
            .toList();
      case 2:
        list = list.where(_isFavoritedSource).toList();
      case 3:
        list = list.where(_isKeyedSource).toList();
      case 4:
        list = list
            .where((s) => _itemState(s) == _ItemState.networkFail)
            .toList();
      case 5:
        list = list
            .where((s) => _itemState(s) == _ItemState.parseFail)
            .toList();
      default:
        break;
    }
    switch (_groupTab) {
      case 1:
        list = list.where((s) => !_isFast(s)).toList();
      case 2:
        list = list.where((s) => _isFast(s)).toList();
      default:
        break;
    }
    return list;
  }

  int get _fastCount =>
      ShuyuanSourceStore.instance.allSources.where((s) => _isFast(s)).length;
  int get _normalCount =>
      ShuyuanSourceStore.instance.allSources.where((s) => !_isFast(s)).length;
  int get _favoritedCount => ShuyuanSourceStore.instance.allSources
      .where(_isFavoritedSource)
      .length;
  int get _keyedCount =>
      ShuyuanSourceStore.instance.allSources.where(_isKeyedSource).length;

  // ============================================================
  // 体检引擎（Nexhub WebBook 四环节）
  // ============================================================

  _FailKind _failKind(String detail) {
    final d = detail.toLowerCase();
    if (d.contains('timeout') ||
        d.contains('超时') ||
        d.contains('connection') ||
        d.contains('连接') ||
        d.contains('socket') ||
        d.contains('dioexception') ||
        d.contains('status code') ||
        d.contains('http 4') ||
        d.contains('http 5') ||
        d.contains('403') ||
        d.contains('404') ||
        d.contains('500') ||
        d.contains('楠岃瘉')) {
      return _FailKind.network;
    }
    return _FailKind.parse;
  }

/// 逐源体检：取书→详情→目录→正文。  /// 关键字固定用大众书名「大奉打更人」（与书源仓库体检口径一致）。
Future<_SourceHealth> _healthCheckOne(ShuyuanSource source) async {
    final sw = Stopwatch()..start();
    try {
      final src = source.toBookSource();
      final results = await _webBook.searchBook(source: src, key: '大奉打更人');
      if (results == null || results.isEmpty) {
        return _SourceHealth(
            healthy: false, elapsed: sw.elapsed, detail: '搜索无结果');
      }
      final first = results.first;
      // 详情
      final info = await _webBook.getBookInfo(
        source: src,
        bookUrl: first.bookUrl,
      );
// 目录
      final chapters = await _webBook.getChapterList(
        source: src,
        book: info,
      );
      if (chapters.isEmpty) {
        return _SourceHealth(
            healthy: false, elapsed: sw.elapsed, detail: '目录为空');
      }
// 正文（第一章）
      final content = await _webBook.getContent(
        source: src,
        chapterUrl: chapters.first.url,
        originalBook: info,
      );
      if (content.content.trim().isEmpty) {
        return _SourceHealth(
            healthy: false, elapsed: sw.elapsed, detail: '正文为空');
      }
      return _SourceHealth(
        healthy: true,
        elapsed: sw.elapsed,
        detail: '取书→详情→目录→正文全部通过',
      );
    } catch (e) {
      final msg = e.toString();
      return _SourceHealth(
          healthy: false, elapsed: sw.elapsed, detail: msg);
    }
  }

  Future<void> _start() async {
    setState(() {
      _phaseVal = _Phase.running;
      _done = 0;
      _health.clear();
    });
    final all = ShuyuanSourceStore.instance.allSources;
    // 并发分块：按 _concurrency 一组一组跑
    for (var i = 0; i < all.length; i += _concurrency) {
      final batch = all.skip(i).take(_concurrency).toList();
      final results = await Future.wait(batch.map(_healthCheckOne));
      if (!mounted) return;
      for (var j = 0; j < batch.length; j++) {
        _health[batch[j].bookSourceUrl] = results[j];
      }
      _done += batch.length;
      setState(() {});
    }
    if (!mounted) return;
    setState(() {
      _phaseVal = _Phase.done;
      _done = _total;
    });
  }

  Future<void> _optimize() async {
    final usable = ShuyuanSourceStore.instance.allSources
        .where((s) => _itemState(s) == _ItemState.healthy)
        .toList();
    final bad = ShuyuanSourceStore.instance.allSources
        .where((s) =>
            _itemState(s) == _ItemState.networkFail ||
            _itemState(s) == _ItemState.parseFail)
        .toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('一键优化', style: TextStyle(fontSize: AppTheme.fontHeadline)),
        content: Text(
          '将把 ${usable.length} 个可用源置顶，其中重新启用 0 个；'
          '停用 ${bad.length} 个网络不通/解析失败的源'
          '（不删除，可再次体检恢复）。确定继续？',
          style: const TextStyle(fontSize: AppTheme.fontSubhead, height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('优化')),
        ],
      ),
    );
    if (ok != true) return;
// 可用源置顶（按原顺序），其余保持原顺序在后
    final ordered = <String>[
      ...usable.map((s) => s.bookSourceUrl),
      ...ShuyuanSourceStore.instance.allSources
          .where((s) => !usable.contains(s))
          .map((s) => s.bookSourceUrl),
    ];
    await ShuyuanSourceStore.instance.reorder(ordered);
    for (final s in bad) {
      if (s.enabled) {
        await ShuyuanSourceStore.instance.setEnabled(s.bookSourceUrl, false);
      }
    }
    if (mounted) {
      _toast('已优化：置顶 ${usable.length} 个可用源，停用 ${bad.length} 个失败源');
    }
  }

  Future<void> _cleanup() async {
    final n = _selected.length;
    if (n == 0) {
      _toast('请先勾选要清理的书源');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理书源', style: TextStyle(fontSize: AppTheme.fontHeadline)),
        content: Text(
          '将删除 $n 个书源，删除后不可恢复，确定继续？',
          style: const TextStyle(fontSize: AppTheme.fontSubhead, height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: JellyTheme.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final url in _selected.toList()) {
      await ShuyuanSourceStore.instance.removeSource(url);
    }
    setState(() => _selected.clear());
    if (mounted) _toast('已删除 $n 个书源');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: AppTheme.fontFootnote)),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }

  // ============================================================
  // 构建
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark;
    return Scaffold(
      backgroundColor: isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        backgroundColor: isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: _titleColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '书源体检',
          style: TextStyle(
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w600,
            color: _titleColor,
          ),
        ),
        actions: [
          Icon(Icons.shield_rounded, size: 18, color: _subColor),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '重新体检',
            icon: Icon(Icons.refresh_rounded, size: 20, color: _titleColor),
            onPressed: _phaseVal == _Phase.running ? null : _start,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _phaseVal == _Phase.idle
                ? ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    children: _buildIdle(),
                  )
                : CustomScrollView(
                    slivers: [
                      // 固定头：进度/统计/搜索/统计tab/分组tab（懒加载不参与）
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: _buildResultHeader(),
                          ),
                        ),
                      ),
// 源条目：SliverList.builder 懒加载
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        sliver: SliverList.builder(
                          itemCount: _filtered.length,
                          itemBuilder: (context, i) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _itemTile(_filtered[i]),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          if (_phaseVal != _Phase.idle) _buildBottomBar(),
        ],
      ),
    );
  }

  // ── 空闲页（8554）────────────────────────────────────────────────
  List<Widget> _buildIdle() {
    return [
      const SizedBox(height: 60),
      Icon(Icons.verified_user_rounded, size: 48, color: JellyTheme.primary),
      const SizedBox(height: 20),
      Center(
        child: Text(
          '逐源体检：取书→详情→目录→正文',
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: FontWeight.w600,
            color: _titleColor,
          ),
        ),
      ),
      const SizedBox(height: 8),
      Center(
        child: Text(
          '搜索「大奉打更人」逐源验证，验证码/超时/403/5xx 计入网络或源站异常',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: AppTheme.fontFootnote, color: _subColor),
        ),
      ),
      const SizedBox(height: 44),
      Center(
        child: Wrap(
          spacing: 8,
          alignment: WrapAlignment.center,
          children: [1, 2, 3, 4, 6, 8, 12]
              .map((n) => _concurrencyChip(n))
              .toList(),
        ),
      ),
      const SizedBox(height: 40),
      Center(
        child: GestureDetector(
          onTap: _start,
          child: Container(
            width: 220,
            padding: const EdgeInsets.symmetric(vertical: 13),
            decoration: BoxDecoration(
              color: JellyTheme.primary,
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Center(
              child: Text(
                '开始体检',
                style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 40),
    ];
  }

  Widget _concurrencyChip(int n) {
    final sel = n == _concurrency;
    return GestureDetector(
      onTap: () => setState(() => _concurrency = n),
      child: Container(
        width: 46,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel
              ? (JellyTheme.primary.withValues(alpha: 0.14))
              : (_isDark ? JellyTheme.cardDark : JellyTheme.cardLight),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: sel ? JellyTheme.primary : Colors.transparent,
            width: 1.4,
          ),
        ),
        child: Text(
          sel ? '鉁?$n' : '$n',
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
            color: sel ? JellyTheme.primary : _titleColor,
          ),
        ),
      ),
    );
  }

  // ── 进行中 / 完成页（8555~8561）────────────────────────────────
  // 固定头部分（懒加载用 SliverToBoxAdapter），源条目用 SliverList.builder 提供
  List<Widget> _buildResultHeader() {
    final running = _phaseVal == _Phase.running;
    final doneTime = _fmtTime(DateTime.now());
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              running
                  ? '体检中 $_done/$_total（取书→详情→目录→正文）'
                  : '体检完成·$doneTime',
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w600,
                color: _titleColor,
              ),
            ),
          ),
          Text(
            '骞跺彂 $_concurrency',
            style: TextStyle(fontSize: AppTheme.fontFootnote, color: _subColor),
          ),
        ],
      ),
      if (running) ...[
        const SizedBox(height: 6),
        Text(
          '后台多线程体检会使手机发烫，属正常现象',
          style: TextStyle(fontSize: AppTheme.fontCaption, color: _subColor),
        ),
      ],
      const SizedBox(height: 12),
      Row(
        children: [
          _statPill('可用', _usable, Colors.green),
          const SizedBox(width: 10),
          _statPill('网络/源站异常', _networkFail, Colors.orange),
          const SizedBox(width: 10),
          _statPill('瑙ｆ瀽澶辫触', _parseFail, JellyTheme.error),
        ],
      ),
      const SizedBox(height: 14),
      JellySearchBar(
        controller: _searchCtrl,
        hintText: '搜索书源',
        onChanged: (v) => setState(() => _kw = v.trim()),
        onCleared: () => setState(() => _kw = ''),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          _numTab(0, '总数', _total),
          _numTab(1, '可用', _usable),
          _numTab(2, '收藏', _favoritedCount),
          _numTab(3, '密钥', _keyedCount),
          _numTab(4, '网络/源站异常', _networkFail),
          _numTab(5, '瑙ｆ瀽澶辫触', _parseFail),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          _groupTabChip(0, '全部', _total),
          const SizedBox(width: 8),
          _groupTabChip(1, '通常书源', _normalCount),
          const SizedBox(width: 8),
          _groupTabChip(2, '快速书源', _fastCount),
        ],
      ),
      const SizedBox(height: 12),
      if (_filtered.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 60),
          child: Center(
            child: Text(
              '暂无可用源',
              style: TextStyle(fontSize: AppTheme.fontSubhead, color: _subColor),
            ),
          ),
        ),
      const SizedBox(height: 4),
    ];
  }

  String _fmtTime(DateTime t) =>
      '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Widget _statPill(String label, int n, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$label $n',
        style: TextStyle(
          fontSize: AppTheme.fontFootnote,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _numTab(int index, String label, int n) {
    final sel = _statTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _statTab = index),
        child: Column(
          children: [
            Text(
              '$n',
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w700,
                color: sel ? JellyTheme.primary : _titleColor,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              label,
              style: TextStyle(
                fontSize: AppTheme.fontCaption,
                color: sel ? JellyTheme.primary : _subColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupTabChip(int index, String label, int n) {
    final sel = _groupTab == index;
    return GestureDetector(
      onTap: () => setState(() => _groupTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: sel
              ? JellyTheme.primary.withValues(alpha: 0.14)
              : (_isDark ? JellyTheme.cardDark : JellyTheme.cardLight),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: sel ? JellyTheme.primary : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Text(
          '$label $n',
          style: TextStyle(
            fontSize: AppTheme.fontCaption,
            fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
            color: sel ? JellyTheme.primary : _titleColor,
          ),
        ),
      ),
    );
  }

  // ── 列表条目 ────────────────────────────────────────────────
  Widget _itemTile(ShuyuanSource s) {
    final state = _itemState(s);
    final h = _health[s.bookSourceUrl];
    final selected = _selected.contains(s.bookSourceUrl);
    final (Color color, IconData icon, String sub) = switch (state) {
      _ItemState.healthy => (
          Colors.green,
          Icons.check_circle_rounded,
          '${h!.elapsed.inMilliseconds}ms路${h.detail}',
        ),
      _ItemState.networkFail => (
          Colors.orange,
          Icons.wifi_off_rounded,
          h!.detail,
        ),
      _ItemState.parseFail => (
          JellyTheme.error,
          Icons.error_rounded,
          h!.detail,
        ),
      _ItemState.untested => (
          _subColor,
          Icons.radio_button_unchecked_rounded,
          '尚未体检',
        ),
    };

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() {
        if (selected) {
          _selected.remove(s.bookSourceUrl);
        } else {
          _selected.add(s.bookSourceUrl);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? JellyTheme.primary
                    : (_isDark ? JellyTheme.cardDark : JellyTheme.cardLight),
                border: Border.all(
                  color: selected
                      ? JellyTheme.primary
                      : _subColor.withValues(alpha: 0.4),
                  width: 1.2,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.bookSourceName,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      color: _titleColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(icon, size: 12, color: color),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          sub,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: AppTheme.fontCaption, color: color),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 底部操作条：全部/一键优化/清理 ─────────────────────────
  Widget _buildBottomBar() {
    final list = _filtered;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        decoration: BoxDecoration(
          color: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Row(
          children: [
            TextButton.icon(
              onPressed: () => setState(() {
                _selectAll = !_selectAll;
                if (_selectAll) {
                  _selected
                    ..clear()
                    ..addAll(list.map((s) => s.bookSourceUrl));
                } else {
                  _selected.clear();
                }
              }),
              icon: Icon(
                _selectAll
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 18,
                color: _titleColor,
              ),
              label: Text(
                _selectAll ? '取消全选' : '全选',
                style: TextStyle(fontSize: AppTheme.fontFootnote, color: _titleColor),
              ),
            ),
            const Spacer(),
            if (_phaseVal == _Phase.done) ...[
              IconButton(
                tooltip: '一键优化',
                icon: Icon(Icons.auto_fix_high_rounded, size: 20, color: JellyTheme.primary),
                onPressed: _usable > 0 ? _optimize : null,
              ),
              const SizedBox(width: 4),
            ],
            TextButton.icon(
              onPressed: _selected.isEmpty ? null : _cleanup,
              icon: Icon(Icons.delete_outline_rounded, size: 18, color: JellyTheme.error),
              label: Text(
                '娓呯悊',
                style: TextStyle(fontSize: AppTheme.fontFootnote, color: JellyTheme.error),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

