import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/hiker/models/hiker_source.dart';
import 'package:tvbox/hiker/pages/hiker_detail_page.dart';
import 'package:tvbox/hiker/services/hiker_engine.dart';
import 'package:tvbox/hiker/services/hiker_route.dart';
import 'package:tvbox/hiker/services/hiker_store.dart';
import 'package:tvbox/hiker/widgets/hiker_blocks.dart';
import 'package:tvbox/hiker/widgets/hiker_widgets.dart';

/// 「海阔小程序」的一个**页面模块**（`hiker://page/<名>`）。
///
/// ── 为什么需要这个页面 ──────────────────────────────────────────────
/// 海阔的「小程序脚本」不是"一个首页 + 一个详情"，而是一套**多页**：
/// 源的 `pages` 里每个模块（`{name, rule}`）就是一个页面，条目地址写成
/// `hiker://page/<名>`，点开 = **执行那个模块的 rule**，再用同一套列表渲染
/// 把结果铺出来。官方的 首页 → 分类 → 详情 → 播放 就是靠这条链串起来的。
///
/// 我们原来只把 `pages` 当 `$.require` 的**代码库**，从来没真正"打开过"其中
/// 一页 ⇒ 小程序源点进去只弹一句「海阔内部页面，本版不支持」，等于整套多页
/// 功能没移植。这个页面就是补上那一环：
///
///   · 进来就跑一次 `action: 'page'`（见 `hiker_engine.js` 的 page 分支）；
///   · 结果按 `col_type` 用 [HikerBlocks] 渲染（与首页/详情同一套观感）；
///   · 条目又是 `hiker://page/…` ⇒ **继续压栈**（这就是"多页"）；
///   · 其它条目 ⇒ 交给 [HikerDetailPage]（它已经有全套链接分流 + 播放链路），
///     并把本页的"重放"能力传下去，让页面里注册的延迟规则也能解。
class HikerPageView extends StatefulWidget {
  final HikerSource source;

  /// 模块名（`hiker://page/` 之后那段，已去掉 `?参数`）
  final String module;

  /// 原始链接（含 `?参数`）—— 页面模块里的 `MY_URL` 读它
  final String url;

  /// `?a=b&c=d` 解析出来的入参 —— 页面模块里的 `MY_PARAMS` 读它
  final Map<String, String> args;

  /// 入口条目上的文字（取不到 `pageTitle` 时当标题兜底）
  final String title;

  /// 延迟规则**链条**（父→子）：本页是从哪条链点进来的（空 = 顶层）
  final List<String> lazyChain;

  const HikerPageView({
    super.key,
    required this.source,
    required this.module,
    this.url = '',
    this.args = const {},
    this.title = '',
    this.lazyChain = const [],
  });

  @override
  State<HikerPageView> createState() => _HikerPageViewState();
}

class _HikerPageViewState extends State<HikerPageView> {
  bool _loading = false;
  String? _error;
  List<HikerItem> _items = const [];

  /// 规则自己给的页面标题（`setPageTitle`）
  String _pageTitle = '';

  /// 官方 `setNextPage`：非空表示还有下一页
  String _nextPage = '';
  int _page = 1;

  /// `addListener('onClose', …)` 登记的回调：**离开本页时回放**
  final List<String> _onClose = [];

  /// 最近一次规则跑完的变量（回放 onClose / 重放延迟规则时当上下文）
  Map<String, dynamic> _lastVars = const {};

  /// 本次请求序号 —— 防"连点刷新 / 加载更多"时旧结果覆盖新结果
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _fireOnClose();
    super.dispose();
  }

  /// 回放 `onClose`（fire-and-forget；销毁时不能 await）
  void _fireOnClose() {
    final codes = List<String>.from(_onClose);
    if (codes.isEmpty) return;
    final src = widget.source;
    final vars = _lastVars.isEmpty
        ? HikerStore.instance.varsOf(src.id)
        : _lastVars;
    unawaited(() async {
      try {
        final r = await HikerEngine.instance.runEvents(
          src,
          codes,
          vars: vars,
          url: widget.url,
        );
        if (r.ok) {
          await HikerStore.instance.saveVarsIfChanged(src.id, vars, r.vars);
        }
      } catch (e) {
        AppLog.instance.log('[Hiker] 页面模块 onClose 回放失败: $e');
      }
    }());
  }

  /// 跑一次本页规则（[lazyIds] 非空 = 解这一页里注册的延迟规则）
  Future<HikerResult> _run({
    int page = 1,
    List<String> lazyIds = const [],
    String lazyInput = '',
  }) async {
    final src = widget.source;
    final vars = _lastVars.isEmpty
        ? HikerStore.instance.varsOf(src.id)
        : _lastVars;
    final r = await HikerEngine.instance.page(
      src,
      module: widget.module,
      url: widget.url,
      args: widget.args,
      page: page,
      vars: vars,
      lazyIds: lazyIds,
      lazyInput: lazyInput,
    );
    if (r.ok) {
      await HikerStore.instance.saveVarsIfChanged(src.id, vars, r.vars);
    }
    return r;
  }

  /// 吸收一次结果里的"页面级"信息（标题 / 下一页 / onClose / 变量）
  void _absorb(HikerResult r) {
    _lastVars = r.vars;
    if (r.pageTitle.isNotEmpty) _pageTitle = r.pageTitle;
    _nextPage = r.nextPage;
    final closeCodes = r.listeners['onClose'];
    if (closeCodes != null) {
      for (final c in closeCodes) {
        if (_onClose.length >= 16) break;
        if (!_onClose.contains(c)) _onClose.add(c);
      }
    }
  }

  /// 拉第一页（AppBar 刷新 / 下拉刷新 / 重试都走它）
  Future<void> _load() => _fetch(1);

  /// 拉下一页（`setNextPage` 非空时底部出现「加载更多」）
  Future<void> _loadMore() => _fetch(_page + 1);

  Future<void> _fetch(int page) async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    HikerResult r;
    try {
      r = await _run(page: page);
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
      return;
    }
    if (!mounted || seq != _seq) return;
    _absorb(r);
    setState(() {
      _loading = false;
      _error = r.ok ? null : (r.error ?? '页面规则执行失败');
      _page = page;
      if (page == 1) {
        _items = r.list;
      } else {
        // 分页：同地址去重（源偶尔把上一页尾巴再吐一遍）
        _items = [
          ..._items,
          ...r.list.where((x) => !_items.any((y) => y.url == x.url)),
        ];
      }
    });
    // 页面规则直接给出播放地址（没有列表）⇒ 交给详情页那条统一链路打开
    if (r.ok && r.list.isEmpty && r.playUrl.isNotEmpty) {
      _openUrl(r.playUrl, headers: r.playHeaders, label: _pageTitle);
    }
  }

  /// 按地址打开（统一走详情页：那里有全套链接分流 + 播放链路）
  void _openUrl(
    String url, {
    Map<String, String> headers = const {},
    String label = '',
  }) {
    final src = widget.source;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HikerDetailPage(
          source: src,
          item: HikerItem(
            title: label.isEmpty ? widget.title : label,
            url: url,
          ),
          lazyChain: widget.lazyChain,
          // 页面里注册的延迟规则：用**同一个页面模块**重放才能解
          replayLazy: (ids, {String lazyInput = ''}) => _run(
            lazyIds: ids,
            lazyInput: lazyInput,
          ),
          // 「下一页 / 下一章」不是 lazy 时：让本页按那个地址再跑一次
          runPage: (u) => HikerEngine.instance.page(
            src,
            module: widget.module,
            url: u,
            args: widget.args,
            vars: HikerStore.instance.varsOf(src.id),
          ),
        ),
      ),
    );
  }

  /// 点条目：页面模块 ⇒ 继续压栈（这就是"多页"）；其余 ⇒ 详情页
  void _open(HikerItem it) {
    final url = it.url.trim();
    if (url.isEmpty) {
      AppToast.message('这个条目没有地址');
      return;
    }
    final pm = parseHikerPageUrl(url);
    if (pm != null) {
      _pushPage(pm);
      return;
    }
    // `条目地址 + hiker://lazy#id`：本页注册的延迟规则，仍由本页重放
    final lazySplit = splitHikerLazyUrl(url);
    if (lazySplit != null) {
      _runLazyThenOpen(lazySplit.id, lazySplit.input, it.title);
      return;
    }
    _openUrl(url, label: it.title);
  }

  /// 打开另一个页面模块（多页导航）
  void _pushPage(({String module, String url, Map<String, String> args}) pm) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HikerPageView(
          source: widget.source,
          module: pm.module,
          url: pm.url,
          args: pm.args,
          title: pm.module,
        ),
      ),
    );
  }

  /// 解一层本页注册的延迟规则，能出地址就直接打开
  Future<void> _runLazyThenOpen(String id, String input, String label) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    HikerResult r;
    try {
      r = await _run(lazyIds: [...widget.lazyChain, id], lazyInput: input);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
      return;
    }
    if (!mounted) return;
    _absorb(r);
    setState(() => _loading = false);
    if (!r.ok) {
      setState(() => _error = r.error ?? '延迟规则执行失败');
      return;
    }
    if (r.playUrl.isNotEmpty) {
      _openUrl(r.playUrl, headers: r.playHeaders, label: label);
      return;
    }
    if (r.list.isEmpty) {
      AppToast.message('这一步没有内容');
      return;
    }
    // 解出来的是下一层条目 ⇒ 就地铺开（海阔的 分类→详情→选集 就是一层层）
    setState(() {
      _items = r.list;
      _page = 1;
    });
  }

  /// 分类 / 按钮类条目：页面模块 ⇒ 打开；延迟规则 ⇒ 就地重跑；其余 ⇒ 当内容打开
  void _triggerAction(HikerItem it) {
    final url = it.url.trim();
    if (url.isEmpty || url == 'hiker://empty') return;
    final pm = parseHikerPageUrl(url);
    if (pm != null) {
      _pushPage(pm);
      return;
    }
    final lazySplit = splitHikerLazyUrl(url);
    if (lazySplit == null) {
      _open(it);
      return;
    }
    _triggerLazy(lazySplit.id, lazySplit.input);
  }

  /// 点分类/工具按钮：跑那条延迟规则 → 源一般只改变量 + `refreshPage()`
  /// ⇒ 带上新变量再跑一轮整页（与首页 `_triggerAction` 同一套口径）
  Future<void> _triggerLazy(String id, String input) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    HikerResult r;
    try {
      r = await _run(lazyIds: [...widget.lazyChain, id], lazyInput: input);
      if (r.needRefresh) {
        final r2 = await _run();
        if (r2.list.isNotEmpty || r2.playUrl.isNotEmpty) r = r2;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
      return;
    }
    if (!mounted) return;
    _absorb(r);
    setState(() {
      _loading = false;
      if (r.ok && r.list.isNotEmpty) {
        _items = r.list;
        _page = 1;
      }
      if (!r.ok) _error = r.error ?? '规则执行失败';
    });
    if (r.ok && r.list.isEmpty && r.playUrl.isNotEmpty) {
      _openUrl(r.playUrl, headers: r.playHeaders);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        foregroundColor: AppTheme.textPrimary,
        elevation: 0,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _titleText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${widget.source.title} · 页面 ${widget.module}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: Icon(Icons.refresh_rounded, color: AppTheme.textSecondary),
          ),
        ],
      ),
      body: _body(),
    );
  }

  String get _titleText {
    if (_pageTitle.trim().isNotEmpty) return hikerPlainText(_pageTitle);
    if (widget.title.trim().isNotEmpty) return hikerPlainText(widget.title);
    return widget.module;
  }

  Widget _body() {
    if (_loading && _items.isEmpty) return const HikerStateView(loading: true);
    if (_error != null && _items.isEmpty) {
      return HikerStateView(error: _error, onRetry: _load);
    }
    if (_items.isEmpty) {
      return HikerStateView(
        emptyText: '这个页面没有内容',
        onRetry: _load,
      );
    }
    // 源产出的「分类区」（scroll_button / icon_* 行）固定在列表上方 ——
    // 与首页同一套语义（海阔把分类当 tab）
    final split = splitLeadingNav(_items);
    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (split.pinned.isNotEmpty) ...[
          HikerNavStrip(items: split.pinned, onTap: _triggerAction),
          Divider(height: 1, thickness: 0.5, color: AppTheme.borderLight),
        ],
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: HikerBlocks(
              items: split.rest,
              onTapItem: _open,
              onTapAction: _triggerAction,
              bottomPadding: 40,
            ),
          ),
        ),
        if (_nextPage.isNotEmpty && !_loading)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextButton(
              onPressed: _loadMore,
              child: Text(
                '加载更多',
                style: TextStyle(color: AppTheme.accentOnSurface),
              ),
            ),
          ),
      ],
    );
  }
}
