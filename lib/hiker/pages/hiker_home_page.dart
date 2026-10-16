import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../services/app_log.dart';
import '../../services/main_tab_controller.dart';
import '../../services/nav_feature_service.dart';
import '../../widgets/app_toast.dart';
import '../models/hiker_source.dart';
import '../services/hiker_builtin.dart';
import '../services/hiker_engine.dart';
import '../services/hiker_prefs.dart';
import '../services/hiker_store.dart';
import '../widgets/hiker_blocks.dart';
import '../widgets/hiker_widgets.dart';
import 'hiker_detail_page.dart';
import 'hiker_search_page.dart';
import 'hiker_settings_page.dart';

/// 「海阔」模块主页（底栏分类，默认关闭，在「设置 → 主页页面」开启）。
///
/// 功能：换源 / 分类切换 / 列表 / 分页加载更多 / 搜索页 / 设置页 / 长按菜单。
/// 与其它模块**零耦合**：只读写自己的 Store / Prefs / Engine。
class HikerHomePage extends StatefulWidget {
  const HikerHomePage({super.key});

  @override
  State<HikerHomePage> createState() => _HikerHomePageState();
}

class _HikerHomePageState extends State<HikerHomePage> {
  final _store = HikerStore.instance;
  final _prefs = HikerPrefs.instance;

  bool _loading = false;
  String? _error;
  List<HikerItem> _items = const [];

  /// 当前分类（空 = 首页）
  String _cate = '';
  String _cateName = '首页';

  /// 当前列表对应的**延迟规则链条**（父→子）。
  ///
  /// 海阔的条目大多是"一段延迟规则"（分类/详情/选集/立即播放），点进去时要重跑
  /// 产生它的那次查询并逐层执行 —— 所以每换一层列表就记一条链，
  /// 点条目时连同链条一起交给详情页（见 hiker_engine.js 的 lazyRuleImpl）。
  List<String> _lazyChain = const [];

  int _page = 1;
  bool _hasMore = false;

  /// 规则返回 `needRefresh`（调过 `refreshPage()`）时只自动补拉一轮，防死循环
  bool _didAutoRefresh = false;

  /// 上一次执行的统计（抓取次数 / 耗时 / 条数），显示在内容上方
  int _reqCount = 0;
  int _elapsedMs = 0;

  /// 是否已经跑过预热（加载设置/源 + 首次取数据）
  bool _started = false;

  /// 规则用 `addListener('onClose', …)` 登记的回调：离开本页时回放
  ///（本页是底栏 tab ⇒ 实际等价于"退出/离开海阔模块"）
  final List<String> _onClose = [];
  Map<String, dynamic> _lastVars = const {};

  /// 底栏开关监听：本页在 `IndexedStack` 里**已被构建**，
  /// 之后用户打开「海阔」开关时不会再走 `initState` ⇒ 靠这个补一次预热。
  Worker? _navWorker;

  bool get _tabEnabled =>
      NavFeatureService.instance.enabled.contains(NavFeature.hiker);

  /// 底栏 tab 监听：本页是 `IndexedStack` 的常驻 child ⇒ **切走时不会走 dispose**，
  /// 所以"离开海阔模块"要靠这个来触发 onClose 回放（见 [_fireOnClose]）。
  Worker? _closeWorker;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChanged);
    _prefs.addListener(_onChanged);
    // 离开海阔 tab（含首次进入前的其它 tab）⇒ 回放规则登记的 onClose 清理
    _closeWorker = ever(MainTabController.instance.selectedTab, (v) {
      if (v != NavFeature.hiker.tabIndex) _fireOnClose();
    });
    if (_tabEnabled) {
      _start();
    } else {
      // ⚠️ 底栏没开「海阔」时不预热：IndexedStack 会**无条件构建所有 tab**，
      //   若在这里直接 bootstrap，就等于"每次启动都解析一遍内置源 + 跑一次
      //   当前源的网络请求"，而用户可能压根没用过这个模块。
      _navWorker = ever(NavFeatureService.instance.enabled, (_) {
        if (_tabEnabled) _start();
      });
    }
  }

  void _start() {
    if (_started) return;
    _started = true;
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _prefs.load();
    await _store.load();
    // 首次进入且仓库为空 → 自动装一份**内置源**（实测可用的那批），开箱可用
    await HikerBuiltin.installIfEmpty();
    // 释放随包的**App 自带资源**（assets/hiker/files/* → Documents/hiker/builtin）
    // 规则里的 `hiker://assets/xxx` 靠它才能读到内容；幂等，只补缺失的
    await HikerBuiltin.installAssets();
    if (!mounted) return;
    _load(page: 1);
  }

  @override
  void dispose() {
    _store.removeListener(_onChanged);
    _prefs.removeListener(_onChanged);
    _navWorker?.dispose();
    _closeWorker?.dispose();
    _fireOnClose();
    super.dispose();
  }

  /// 回放 `onClose`（fire-and-forget；销毁时不能 await）
  ///
  /// ⚠️ 本页是常驻 tab，用户"切到别的 tab"不会触发 dispose —— 由 [_closeWorker]
  /// （监听 `MainTabController.selectedTab`）在离开海阔 tab 时调用。
  /// 回放后**清空队列**，避免每次切 tab 都重放一遍。
  void _fireOnClose() {
    final codes = List<String>.from(_onClose);
    if (codes.isEmpty) return;
    _onClose.clear();
    final src = _store.current;
    if (src == null) return;
    final vars = _lastVars.isEmpty ? _store.varsOf(src.id) : _lastVars;
    unawaited(() async {
      try {
        final r = await HikerEngine.instance.runEvents(src, codes, vars: vars);
        if (r.ok) await _store.saveVarsIfChanged(src.id, vars, r.vars);
      } catch (e) {
        AppLog.instance.log('[Hiker] onClose 回放失败: $e');
      }
    }());
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  // ── 数据 ──────────────────────────────────────────────

  /// 本次加载的序号 —— 防"切源 / 切分类 / 连点加载更多"时**旧请求后返回**把新列表覆盖掉
  int _loadSeq = 0;

  Future<void> _load({int page = 1}) async {
    final seq = ++_loadSeq;
    final src = _store.current;
    if (src == null) {
      setState(() {
        _items = const [];
        _error = null;
        _hasMore = false;
      });
      return;
    }
    if (!src.usable) {
      setState(() {
        _items = const [];
        _hasMore = false;
        _error = src.unusableReason.isEmpty ? '该源不可用' : src.unusableReason;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final vars = _store.varsOf(src.id);
    final r = _cate.isEmpty
        ? await HikerEngine.instance
            .home(src, page: page, vars: vars, lazyIds: _lazyChain)
        : await HikerEngine.instance.category(src, _cate,
            cateName: _cateName, page: page, vars: vars, lazyIds: _lazyChain);
    // 期间又发起了新的加载（切源 / 切分类 / 加载更多）⇒ 这次结果作废
    if (!mounted || seq != _loadSeq) return;
    // 变量**有变化**才落盘（判据见 HikerStore.saveVarsIfChanged 的注释：
    // 规则清空全部变量时结果是空表，用 isNotEmpty 判断会把这次清空吞掉）
    await _store.saveVarsIfChanged(src.id, vars, r.vars);
    _lastVars = r.vars;
    // 规则登记的事件回调 → 离开本页时回放（见 dispose / _fireOnClose）
    final closeCodes = r.listeners['onClose'];
    if (closeCodes != null) {
      // 去重 + 限量：同一页会反复跑规则，别让列表无限增长
      for (final c in closeCodes) {
        if (_onClose.length >= 16) break;
        if (!_onClose.contains(c)) _onClose.add(c);
      }
    }
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      _loading = false;
      _page = page;
      _reqCount = r.requests;
      _elapsedMs = r.elapsedMs;
      _error = r.ok ? null : (r.error ?? '规则执行失败');
      _hasMore = r.ok && r.nextPage.isNotEmpty && r.list.isNotEmpty;
      _items = page == 1
          ? r.list
          : [
              ..._items,
              ...r.list.where((x) => !_items.any((y) => y.url == x.url)),
            ];
    });
    // 规则调过 `refreshPage()`（海阔的分类按钮 / 自定义刷新都这么写）：
    // 官方会重拉一次当前页 —— 我们跟着补一轮（只补一轮，防坏规则死循环）。
    if (r.needRefresh) {
      if (!_didAutoRefresh) {
        _didAutoRefresh = true;
        unawaited(_load(page: 1));
      }
    } else {
      _didAutoRefresh = false;
    }
  }

  void _pickCate(String url, String name) {
    if (_cate == url && _cateName == name) return;
    setState(() {
      _cate = url;
      _cateName = name;
      _items = const [];
      _lazyChain = const []; // 换静态分类 = 回到顶层查询
    });
    _load(page: 1);
  }

  /// 源的分类（`class_name` / `class_url` 用 `&` 或 `#` 分隔）
  List<({String name, String url})> _cats(HikerSource s) {
    final names = s.className
        .split(RegExp(r'[&#]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final urls = s.classUrl
        .split(RegExp(r'[&#]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final out = <({String name, String url})>[];
    final n = names.length < urls.length ? names.length : urls.length;
    for (var i = 0; i < n; i++) {
      out.add((name: names[i], url: urls[i]));
    }
    return out;
  }

  // ── 交互 ──────────────────────────────────────────────

  void _open(HikerItem it) {
    if (it.url.isEmpty) {
      AppToast.message('这个条目没有地址');
      return;
    }
    final src = _store.current;
    if (src == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HikerDetailPage(
          source: src,
          item: it,
          lazyChain: _lazyChain,
          replayLazy: _replayLazyFor(src),
        ),
      ),
    );
  }

  /// 延迟规则执行入口：重跑**当前这次查询**并把父链带上（见 hiker_engine.js）
  Future<HikerResult> Function(List<String>) _replayLazyFor(HikerSource src) {
    final cate = _cate;
    final cateName = _cateName;
    return (ids) async {
      final vars = _store.varsOf(src.id);
      final r = cate.isEmpty
          ? await HikerEngine.instance.home(src, vars: vars, lazyIds: ids)
          : await HikerEngine.instance.category(src, cate,
              cateName: cateName, vars: vars, lazyIds: ids);
      await _store.saveVarsIfChanged(src.id, vars, r.vars);
      return r;
    };
  }

  /// 分类 / 按钮 / 图标 / 文本类条目的点击 —— 海阔语义是**就地切换**（不是进详情页）。
  ///
  /// 为什么这么做（用户 2026-10-16：「海阔是将分类作为 tab 的，每个分类也有内容」）：
  /// 规则给这类条目的地址一般是 `$('...').lazyRule(fn)` 产出的 `hiker://lazy#<id>`。
  /// 官方流程 = 执行那一段 JS → 页面换成它产出的内容；我们等价实现为
  /// **"带上父链重跑 + 直接用这次的结果当新列表"**（引擎会执行到最深那层 fn）。
  Future<void> _triggerAction(HikerItem it) async {
    final src = _store.current;
    if (src == null) return;
    final u = it.url;
    if (u.isEmpty || u == 'hiker://empty') return;
    if (!u.startsWith('hiker://lazy#')) {
      // 老式写法：直接给一个分类地址（http 或 `hiker://empty##xxx##fypage` 规则串）
      _pickCate(u, hikerPlainText(it.title));
      return;
    }
    final chain = [..._lazyChain, u.substring('hiker://lazy#'.length)];
    setState(() {
      _loading = true;
      _error = null;
    });
    HikerResult r;
    try {
      r = await _replayLazyFor(src)(chain);
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        AppToast.error('这个分类打不开：$e');
      }
      return;
    }
    if (!mounted) return;
    if (r.playUrl.isNotEmpty) {
      // 少数源的分类按钮直接给播放地址（少见）：交给详情页那套播放逻辑
      setState(() => _loading = false);
      _open(it);
      return;
    }
    setState(() {
      _loading = false;
      _lazyChain = chain;
      _items = r.list;
      _page = 1;
      _hasMore = false;
      _reqCount = r.requests;
      _elapsedMs = r.elapsedMs;
      _error = r.ok ? null : (r.error ?? '规则执行失败');
    });
    if (r.list.isEmpty && r.ok) {
      AppToast.message('这个分类没有内容');
    }
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
              title: Text(it.title.isEmpty ? '(无标题)' : it.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppTheme.textPrimary, fontSize: AppTheme.fontBody)),
              subtitle: Text(
                  it.url.isEmpty ? '(没有地址)' : it.url,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
            ),
            ListTile(
              leading: Icon(Icons.play_arrow_rounded, color: AppTheme.accentOnSurface),
              title: Text('打开',
                  style: TextStyle(
                      color: AppTheme.textPrimary, fontSize: AppTheme.fontBody)),
              onTap: () {
                Navigator.of(ctx).pop();
                _open(it);
              },
            ),
            ListTile(
              leading: Icon(Icons.refresh_rounded, color: AppTheme.accentOnSurface),
              title: Text('刷新列表',
                  style: TextStyle(
                      color: AppTheme.textPrimary, fontSize: AppTheme.fontBody)),
              onTap: () {
                Navigator.of(ctx).pop();
                _load(page: 1);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pickSource() async {
    final list = _store.sources.where(_store.isEnabled).toList();
    if (list.isEmpty) {
      AppToast.message('还没有可用的海阔源，先去「海阔设置」导入');
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.backgroundCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: AppTheme.borderMedium, borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('切换海阔源',
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.bold)),
                  ),
                  GestureDetector(
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _openSettings();
                    },
                    child: Text('管理',
                        style: TextStyle(
                            color: AppTheme.accentOnSurface,
                            fontSize: AppTheme.fontSubhead)),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final s = list[i];
                  final cur = s.id == _store.currentId;
                  return ListTile(
                    dense: true,
                    title: Text(s.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: cur ? AppTheme.accentOnSurface : AppTheme.textPrimary,
                            fontSize: AppTheme.fontBody,
                            fontWeight: cur ? FontWeight.w700 : FontWeight.w500)),
                    subtitle: Text(
                      s.usable ? s.author : '${s.author} · 不可用',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: s.usable
                              ? AppTheme.textTertiary
                              : Colors.orange.shade400,
                          fontSize: AppTheme.fontCaption),
                    ),
                    trailing: cur
                        ? Icon(Icons.check_rounded,
                            size: 18, color: AppTheme.accentOnSurface)
                        : null,
                    onTap: () => Navigator.of(ctx).pop(s.id),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null && picked != _store.currentId) {
      await _store.setCurrent(picked);
      setState(() {
        _cate = '';
        _cateName = '首页';
        _items = const [];
      });
      _load(page: 1);
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HikerSettingsPage()),
    );
    if (mounted) setState(() {});
  }

  void _openSearch() {
    final src = _store.current;
    if (src == null) {
      AppToast.message('先选择一个海阔源');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => HikerSearchPage(source: src)),
    );
  }

  // ── UI ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final src = _store.current;
    final cats = src == null ? const <({String name, String url})>[] : _cats(src);
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: Column(
        children: [
          SizedBox(height: topInset),
          _header(src),
          if (cats.isNotEmpty && src != null && src.usable)
            _categoryBar(cats),
          if (_needConfigHint(src)) _configHint(src!),
          if (_items.isNotEmpty) _statsLine(),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  /// 这个源要读 `config.xxx`，但用户还没填 → 给一条可点的提示（不挡内容）
  bool _needConfigHint(HikerSource? s) =>
      s != null && s.usable && s.needsConfig && _store.configOf(s.id).isEmpty;

  Widget _configHint(HikerSource s) {
    return GestureDetector(
      onTap: _openSettings,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 15, color: Colors.orange.shade400),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '这个源需要填「源配置」（${s.configKeys.map((k) => 'config.$k').join('、')}）',
                maxLines: 2,
                style: TextStyle(
                    color: AppTheme.textSecondary, fontSize: AppTheme.fontCaption),
              ),
            ),
            Text('去设置',
                style: TextStyle(
                    color: AppTheme.accentOnSurface, fontSize: AppTheme.fontCaption)),
          ],
        ),
      ),
    );
  }

  Widget _header(HikerSource? src) {
    return SizedBox(
      height: 46,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 6, 0),
        child: Row(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _pickSource,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const HikerLogo(),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 132),
                    child: Text(
                      src?.title ?? '海阔',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.expand_more_rounded,
                      size: 16, color: AppTheme.textTertiary),
                ],
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: '搜索',
              onPressed: _openSearch,
              icon: Icon(Icons.search_rounded,
                  color: AppTheme.textSecondary, size: 20),
            ),
            IconButton(
              tooltip: '海阔设置',
              onPressed: _openSettings,
              icon: Icon(Icons.tune_rounded, color: AppTheme.textSecondary, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Widget _categoryBar(List<({String name, String url})> cats) {
    final items = <({String name, String url})>[
      (name: '首页', url: ''),
      ...cats,
    ];
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: items.map((c) {
          final on = _cate == c.url && _cateName == c.name;
          return GestureDetector(
            onTap: () => _pickCate(c.url, c.name),
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? AppTheme.accentSurface : AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(c.name,
                  style: TextStyle(
                      color: on ? AppTheme.accentOnSurface : AppTheme.textSecondary,
                      fontSize: AppTheme.fontFootnote,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _statsLine() {
    final parts = <String>['共 ${_items.length} 条'];
    if (_reqCount > 0) parts.add('抓取 $_reqCount 次');
    if (_elapsedMs > 0) parts.add('${(_elapsedMs / 1000).toStringAsFixed(1)}s');
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 2),
      child: Row(
        children: [
          Text(parts.join(' · '),
              style: TextStyle(
                  color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
          const Spacer(),
          if (_cate.isNotEmpty)
            Text(_cateName,
                style: TextStyle(
                    color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
        ],
      ),
    );
  }

  Widget _body() {
    final src = _store.current;
    if (_store.sources.isEmpty) return _guide();
    if (src != null && !src.usable && _error != null) {
      return HikerStateView(error: _error);
    }
    if (_loading && _items.isEmpty) return const HikerStateView(loading: true);
    if (_error != null && _items.isEmpty) {
      return HikerStateView(error: _error, onRetry: () => _load(page: 1));
    }
    if (_items.isEmpty) {
      return HikerStateView(
        emptyText: '这个源没有内容',
        onRetry: () => _load(page: 1),
      );
    }
    // 源产出的「分类区」（scroll_button / icon_* 行）固定在列表上方 —— 这就是海阔的
    // 「分类 tab」语义（用户 2026-10-16：「海阔是将分类作为 tab 的，每个分类也有内容」）。
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
            onRefresh: () => _load(page: 1),
            child: HikerBlocks(
              items: split.rest,
              onTapItem: _open,
              onTapAction: _triggerAction,
              onLongPress: _showItemMenu,
              onTapSearch: _openSearch,
            ),
          ),
        ),
        if (_hasMore && !_loading)
          Container(
            padding: const EdgeInsets.only(bottom: 6),
            child: TextButton(
              onPressed: () => _load(page: _page + 1),
              child: Text('加载更多',
                  style: TextStyle(color: AppTheme.accentOnSurface)),
            ),
          ),
      ],
    );
  }

  Widget _guide() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const HikerLogo(size: 52),
            const SizedBox(height: 14),
            Text('还没有海阔源',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              '去「海阔设置」导入海阔视界导出的 JSON（数组）。\n'
              '导入时会自动标出哪些源在 Phase 1 可用。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontFootnote,
                  height: 1.6),
            ),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.accentColor),
              onPressed: _openSettings,
              child: const Text('打开海阔设置'),
            ),
          ],
        ),
      ),
    );
  }
}
