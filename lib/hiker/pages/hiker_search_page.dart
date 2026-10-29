import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/hiker/models/hiker_source.dart';
import 'package:tvbox/hiker/services/hiker_engine.dart';
import 'package:tvbox/hiker/services/hiker_prefs.dart';
import 'package:tvbox/hiker/services/hiker_store.dart';
import 'package:tvbox/hiker/widgets/hiker_richtext.dart';
import 'package:tvbox/hiker/widgets/hiker_widgets.dart';
import 'package:tvbox/hiker/pages/hiker_detail_page.dart';

/// 海阔搜索页（独立页：主页顶栏的搜索按钮进来）。
///
/// 带搜索历史（存在「海阔设置」的独立键里），点历史直接重搜。
class HikerSearchPage extends StatefulWidget {
  final HikerSource source;

  /// 预填关键词（`hiker://search?rule=…&s=…` 深链带过来的）；非空时自动搜一次
  final String initialKeyword;

  const HikerSearchPage({
    super.key,
    required this.source,
    this.initialKeyword = '',
  });

  @override
  State<HikerSearchPage> createState() => _HikerSearchPageState();
}

class _HikerSearchPageState extends State<HikerSearchPage> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  bool _loading = false;
  String? _error;
  List<HikerItem> _items = const [];
  String _keyword = '';
  int _page = 1;
  bool _hasMore = false;

  /// `addListener('onClose', …)` 登记的回调：离开本页时回放
  final List<String> _onClose = [];
  Map<String, dynamic> _lastVars = const {};

  /// 本次搜索的序号 —— 防"连点历史 / 搜索后又点加载更多"时**旧结果覆盖新结果**
  /// （主页 `_load` 早就有这套守卫，搜索页原来漏了）
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    final kw = widget.initialKeyword.trim();
    if (kw.isNotEmpty) _ctrl.text = kw;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      // 深链带了关键词 ⇒ 进来直接搜（见 HikerDetailPage._openHikerSearch）
      if (kw.isNotEmpty) _search(kw);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    _fireOnClose();
    super.dispose();
  }

  /// 回放 `addListener('onClose', …)` 登记的回调（离开本页时）
  void _fireOnClose() {
    final codes = List<String>.from(_onClose);
    if (codes.isEmpty) return;
    final src = widget.source;
    final vars = _lastVars.isEmpty
        ? HikerStore.instance.varsOf(src.id)
        : _lastVars;
    unawaited(() async {
      try {
        final r = await HikerEngine.instance.runEvents(src, codes, vars: vars);
        if (r.ok)
          await HikerStore.instance.saveVarsIfChanged(src.id, vars, r.vars);
      } catch (e) {
        AppLog.instance.log('[Hiker] onClose 回放失败: $e');
      }
    }());
  }

  Future<void> _search(String kw, {int page = 1}) async {
    final k = kw.trim();
    if (k.isEmpty) {
      AppToast.message('请输入关键词');
      return;
    }
    if (widget.source.searchFind.trim().isEmpty) {
      setState(() {
        _items = const [];
        _error = '这个源没有搜索规则（searchFind）';
      });
      return;
    }
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
      _keyword = k;
      _page = page;
    });
    await HikerPrefs.instance.addHistory(k);
    final vars = HikerStore.instance.varsOf(widget.source.id);
    final r = await HikerEngine.instance.search(
      widget.source,
      k,
      page: page,
      vars: vars,
    );
    // 期间又发起了新的搜索 / 加载更多 ⇒ 这次结果作废（否则旧关键词会覆盖新列表）
    if (!mounted || seq != _seq) return;
    await HikerStore.instance.saveVarsIfChanged(widget.source.id, vars, r.vars);
    if (!mounted || seq != _seq) return;
    _lastVars = r.vars;
    final closeCodes = r.listeners['onClose'];
    if (closeCodes != null) {
      for (final c in closeCodes) {
        if (_onClose.length >= 16) break;
        if (!_onClose.contains(c)) _onClose.add(c);
      }
    }
    if (!mounted || seq != _seq) return;
    setState(() {
      _loading = false;
      _error = r.ok ? null : (r.error ?? '搜索失败');
      _hasMore = r.ok && r.nextPage.isNotEmpty && r.list.isNotEmpty;
      _items = page == 1
          ? r.list
          : [
              ..._items,
              ...r.list.where((x) => !_items.any((y) => y.url == x.url)),
            ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final history = HikerPrefs.instance.searchHistory;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        foregroundColor: AppTheme.textPrimary,
        elevation: 0,
        titleSpacing: 0,
        title: Container(
          height: 38,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: AppTheme.backgroundTertiary,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const SizedBox(width: 10),
              Icon(
                Icons.search_rounded,
                size: 18,
                color: AppTheme.textTertiary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focus,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (v) => _search(v),
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: '搜索 ${widget.source.title}',
                    hintStyle: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontSubhead,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _search(_ctrl.text),
            child: Text(
              '搜索',
              style: TextStyle(color: AppTheme.accentOnSurface),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_keyword.isEmpty && history.isNotEmpty) _historyBar(history),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _historyBar(List<String> history) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 与详情页 / 主页同一套区块标题（主题色竖条 + 加粗）
              const Expanded(
                child: HikerSectionTitle(
                  '搜索历史',
                  padding: EdgeInsets.zero,
                ),
              ),
              GestureDetector(
                onTap: () async {
                  await HikerPrefs.instance.clearHistory();
                  if (mounted) setState(() {});
                },
                child: Text(
                  '清空',
                  style: TextStyle(
                    color: AppTheme.accentOnSurface,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: history
                .map(
                  (k) => GestureDetector(
                    onTap: () {
                      _ctrl.text = k;
                      _search(k);
                    },
                    onLongPress: () async {
                      await HikerPrefs.instance.removeHistory(k);
                      if (mounted) setState(() {});
                    },
                    child: HikerPill(k, maxWidth: 180),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _items.isEmpty) return const HikerStateView(loading: true);
    if (_error != null && _items.isEmpty) {
      return HikerStateView(error: _error, onRetry: () => _search(_keyword));
    }
    if (_items.isEmpty) {
      return HikerStateView(
        emptyText: _keyword.isEmpty ? '输入关键词搜索' : '没有搜到结果',
      );
    }
    return RefreshIndicator(
      onRefresh: () => _search(_keyword),
      child: Column(
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: HikerGrid(
              items: _items,
              onTap: _open,
              onLongPress: _showItemMenu,
              bottomPadding: 40,
            ),
          ),
          if (_hasMore && !_loading)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextButton(
                onPressed: () => _search(_keyword, page: _page + 1),
                child: Text(
                  '加载更多',
                  style: TextStyle(color: AppTheme.accentOnSurface),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _open(HikerItem it) {
    if (it.url.isEmpty) {
      AppToast.message('这个条目没有地址');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HikerDetailPage(
          source: widget.source,
          item: it,
          // 「下一页」不是 lazy 时（有些源直接给 http / 规则串）用它跑一次新房页面
          runPage: (u) => HikerEngine.instance.category(
            widget.source,
            u,
            cateName: hikerPlainText(it.title),
            vars: HikerStore.instance.varsOf(widget.source.id),
          ),
          // 延迟规则链条：用同一个关键词重跑搜索，逐层执行（见 hiker_engine.js）
          replayLazy: (ids, {String lazyInput = ''}) async {
            final vars = HikerStore.instance.varsOf(widget.source.id);
            final r = await HikerEngine.instance.search(
              widget.source,
              _keyword,
              vars: vars,
              lazyIds: ids,
              lazyInput: lazyInput,
            );
            await HikerStore.instance.saveVarsIfChanged(
              widget.source.id,
              vars,
              r.vars,
            );
            return r;
          },
        ),
      ),
    );
  }

  void _showItemMenu(HikerItem it) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            ListTile(
              title: Text(
                hikerPlainText(it.title),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontBody,
                ),
              ),
              subtitle: Text(
                it.url,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption,
                ),
              ),
            ),
            ListTile(
              leading: Icon(
                Icons.play_arrow_rounded,
                color: AppTheme.accentOnSurface,
              ),
              title: Text(
                '打开',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontBody,
                ),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _open(it);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
