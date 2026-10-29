import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/main_tab_controller.dart';
import 'package:tvbox/services/nav_feature_service.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/hiker/widgets/card_source_sheet.dart';
import 'package:tvbox/hiker/models/hiker_source.dart';
import 'package:tvbox/hiker/services/hiker_builtin.dart';
import 'package:tvbox/hiker/services/hiker_cache.dart';
import 'package:tvbox/hiker/services/hiker_engine.dart';
import 'package:tvbox/hiker/services/hiker_prefs.dart';
import 'package:tvbox/hiker/services/hiker_store.dart';
import 'package:tvbox/hiker/widgets/hiker_blocks.dart';
import 'package:tvbox/hiker/widgets/hiker_widgets.dart';
import 'package:tvbox/hiker/pages/hiker_detail_page.dart';
import 'package:tvbox/hiker/pages/hiker_manage_page.dart';
import 'package:tvbox/hiker/pages/hiker_search_page.dart';
import 'package:tvbox/hiker/pages/hiker_settings_page.dart';

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

  /// 当前列表属于哪个源。
  ///
  /// 从「海阔设置」返回时用它判断当前源是否被删除/切换过：
  /// 变了就必须重载，否则界面还挂着上一个源的列表。
  String _loadedSrcId = '';

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
    // 内置源：仓库为空时装一份（开箱可用）；**清单变了也补装**（升级带了新源）
    await HikerBuiltin.installIfNeeded();
    // 释放随包的**App 自带资源**（assets/hiker/files/* → Documents/hiker/builtin）
    // 规则里的 `hiker://assets/xxx` 靠它才能读到内容；幂等，只补缺失的
    await HikerBuiltin.installAssets();
    // 预置远程 require 缓存（assets/hiker/libs/* → Documents/hiker/files/libs）
    // 大量源 `$.require('https://…/f')` 靠它首次运行/断网也能跑
    await HikerBuiltin.installRequireLibs();
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
        _loadedSrcId = '';
      });
      return;
    }
    // 只拦"**确实没规则**"的源（没有任何东西可跑）。
    //
    // ⚠️ 不要再按 [HikerSource.usable] 直接拦下 —— 那是**静态**判定
    //（扫规则文本里有没有引用自己 pages 之外的 `hiker://page|assets/*`），
    // 实测有假阴性：45 个内置源全量真跑 home 时，𝟕𝐌𝐌𝐓𝐕 / 星集Media /
    // 𝐉𝐌𝐂𝐨𝐦𝐢𝐜𝟐本地 等被判"依赖内置模块"，实际首页都能出内容。
    // 能不能跑交给引擎（它按 basename 归一化找模块，找不到会抛明确报错），
    // 这样界面上看到的是**真实原因**，而不是一句笼统的"该源不可用"。
    // 「不可用」标签仍保留在源列表 / 管理页里，供参考。
    if (src.findRule.isEmpty) {
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
    // 首页/分类第一页：先秒显示本地缓存，再等网络刷新（用户 2026-10-18：
    // 「每次进去加载好长时间」—— 规则常要抓多页，不能每次都干等）。
    final cacheKey = HikerCache.keyOf(src.id, _cate, page);
    if (page == 1 && _items.isEmpty) {
      final cached = await HikerCache.read(cacheKey, allowExpired: true);
      if (cached != null && mounted && seq == _loadSeq && _items.isEmpty) {
        setState(() {
          _items = cached.items;
          _loadedSrcId = src.id;
        });
      }
    }
    final vars = _store.varsOf(src.id);
    final r = _cate.isEmpty
        ? await HikerEngine.instance.home(
            src,
            page: page,
            vars: vars,
            lazyIds: _lazyChain,
          )
        : await HikerEngine.instance.category(
            src,
            _cate,
            cateName: _cateName,
            page: page,
            vars: vars,
            lazyIds: _lazyChain,
          );
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
      _loadedSrcId = src.id;
      _items = page == 1
          ? r.list
          : [
              ..._items,
              ...r.list.where((x) => !_items.any((y) => y.url == x.url)),
            ];
    });
    // 首页/分类第一页成功后落缓存，下次进入先秒开
    if (page == 1 && r.ok && r.list.isNotEmpty) {
      unawaited(HikerCache.write(cacheKey, r.list));
    }
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
          // 「下一页」不是 lazy 时（有些源直接给 http / 规则串）用它跑一次新房页面，
          // 供看图阅读器的"下拉自动下一章"接续
          runPage: (u) => HikerEngine.instance.category(
            src,
            u,
            cateName: hikerPlainText(it.title),
            vars: HikerStore.instance.varsOf(src.id),
          ),
        ),
      ),
    );
  }

  /// 延迟规则执行入口：重跑**当前这次查询**并把父链带上（见 hiker_engine.js）
  ///
  /// [persistVars] = false 用于「工具入口弹窗」：那次重跑多半是把源的 `mode`
  /// 变量改成 `settings` / `favorites` 这类**粘性**状态，落盘之后用户就再也
  /// 回不到视频列表了（下次 `_load` 跑出来还是设置页）。弹窗只是"看一眼"，
  /// 所以丢弃它产生的变量；弹窗里真正要存的设置项走源的 `setItem`（自己落盘）。
  ///
  /// [vars] 用来**续用上一轮的变量**（源切页 = 改 mode 变量 + `refreshPage()`，
  /// 真正的内容要带上刚改过的变量再跑一轮，见 [_runToolEntry]）。
  Future<HikerResult> Function(List<String>, {String lazyInput}) _replayLazyFor(
    HikerSource src, {
    bool persistVars = true,
    Map<String, dynamic>? vars,
  }) {
    final cate = _cate;
    final cateName = _cateName;
    return (ids, {String lazyInput = ''}) async {
      final v = vars ?? _store.varsOf(src.id);
      final r = cate.isEmpty
          ? await HikerEngine.instance.home(
              src,
              vars: v,
              lazyIds: ids,
              lazyInput: lazyInput,
            )
          : await HikerEngine.instance.category(
              src,
              cate,
              cateName: cateName,
              vars: v,
              lazyIds: ids,
              lazyInput: lazyInput,
            );
      if (persistVars) {
        await _store.saveVarsIfChanged(src.id, v, r.vars);
      }
      return r;
    };
  }

  /// 跑一次「工具入口」，并自动补上 `refreshPage()` 的第二轮；**全程不落盘**。
  ///
  /// 海阔的「收藏 / 历史 / 设置」按钮典型写法是：
  ///   `putMyVar('mode','settings'); refreshPage(false); return 'hiker://empty'`
  /// 也就是**第一轮只改状态、返回空**，真正的设置内容要带上改过的变量再跑一轮。
  /// 少这一轮的话弹窗里永远是空的。
  Future<HikerResult> _runToolEntry(
    HikerSource src,
    List<String> chain, {
    Map<String, dynamic>? vars,
  }) async {
    var r = await _replayLazyFor(src, persistVars: false, vars: vars)(chain);
    if (r.needRefresh) {
      final r2 = await _replayLazyFor(src, persistVars: false, vars: r.vars)(
        const [],
      );
      if (r2.list.isNotEmpty || r2.playUrl.isNotEmpty) r = r2;
    }
    return r;
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
    // 海阔老写法：`真实地址 + $('').lazyRule(fn)`（lazy 标记在中间），不能只判开头
    final lazySplit = splitHikerLazyUrl(u);
    if (lazySplit == null) {
      // 老式写法：直接给一个分类地址（http 或 `hiker://empty##xxx##fypage` 规则串）
      _pickCate(u, hikerPlainText(it.title));
      return;
    }
    final chain = [..._lazyChain, lazySplit.id];

    // **工具入口**（`text_2/3/4` 多列文本按钮，典型是「收藏 / 历史 / 设置」）：
    // 官方语义是把整页换成它产出的内容，而源多半靠一个**粘性**的 mode 变量切页
    // —— 换掉之后用户就回不到视频列表了（下次刷新跑出来还是设置页）。
    // 所以这里改成**弹窗**：主列表原样保留，关掉弹窗就回去（用户 2026-10-16 要求）。
    if (_isToolButton(it)) {
      await _openToolSheet(src, it, chain);
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    HikerResult r;
    try {
      r = await _replayLazyFor(src)(chain, lazyInput: lazySplit.input);
      // 源切分类的典型写法：`putMyVar('分类', id); refreshPage(false); return 'hiker://empty'`
      // —— 第一轮**只改状态**，真正的分类内容要带上新变量再跑一轮
      //（实测「探色视频」的首页 tab：不补这一轮，点哪个 tab 都还是原来的列表）。
      if (r.needRefresh) {
        final r2 = await _replayLazyFor(src)(const []);
        if (r2.list.isNotEmpty || r2.playUrl.isNotEmpty) r = r2;
      }
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

  /// 是不是"工具入口"按钮：官方 12 栅格里的**多列文本**（`text_2/3/4`）。
  ///
  /// 源里这些条目基本只有一种用途 —— 「收藏 / 历史 / 设置 / ××开关」这类
  /// **就地切页的工具按钮**（`text_1` 是整行内容行，不当工具）。
  static bool _isToolButton(HikerItem it) =>
      it.colType == 'text_2' ||
      it.colType == 'text_3' ||
      it.colType == 'text_4';

  /// 「工具入口」弹窗：把按钮产出的内容（收藏列表 / 设置项 …）放进底部弹窗。
  ///
  /// 两条硬约束：
  ///   · **不动主列表** —— 关掉弹窗就回到原来的视频列表；
  ///   · **不落盘变量** —— 源切页靠改自己的 mode 变量，落了盘就回不去了
  ///     （见 [_replayLazyFor] 的 `persistVars`）。
  /// 弹窗里的设置项按**一行三个卡片**排（[HikerBlocks.textColumns]）。
  Future<void> _openToolSheet(
    HikerSource src,
    HikerItem entry,
    List<String> chain,
  ) async {
    HikerResult r;
    try {
      r = await _runToolEntry(src, chain);
    } catch (e) {
      AppToast.error('这个入口打不开：$e');
      return;
    }
    if (!mounted) return;
    if (r.playUrl.isNotEmpty) {
      // 少数源的按钮直接给播放地址：交给详情页那套播放逻辑
      _open(entry);
      return;
    }
    // 源重跑后总是把整页的头（搜索框 / 分类 / 这行按钮）又带一遍 —— 弹窗里掐掉
    final toolItems = stripLeadingShell(r.list);
    if (toolItems.isEmpty) {
      if (r.ok) {
        AppToast.message('这个入口没有内容');
      } else {
        AppToast.error(r.error ?? '规则执行失败');
      }
      return;
    }
    final rawTitle = hikerPlainText(entry.title);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.backgroundCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        var items = toolItems;
        final sheetVars = r.vars;
        return StatefulBuilder(
          builder: (ctx, setSheet) => SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.76,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sheetHeader(ctx, rawTitle.isEmpty ? '设置' : rawTitle),
                  Flexible(
                    child: SingleChildScrollView(
                      child: HikerBlocks(
                        items: items,
                        textColumns: 3,
                        shrinkWrap: true,
                        bottomPadding: 20,
                        onTapItem: (it) {
                          Navigator.of(ctx).pop();
                          _open(it);
                        },
                        onTapAction: (it) => _sheetAction(
                          src: src,
                          ctx: ctx,
                          chain: chain,
                          vars: sheetVars,
                          item: it,
                          replace: (list) => setSheet(() => items = list),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 弹窗内再点一次（例如设置页里的「恢复默认设置」）：重跑一层并**替换弹窗内容**
  Future<void> _sheetAction({
    required HikerSource src,
    required BuildContext ctx,
    required List<String> chain,
    required Map<String, dynamic> vars,
    required HikerItem item,
    required void Function(List<HikerItem>) replace,
  }) async {
    final u = item.url;
    if (u.isEmpty || u == 'hiker://empty') return;
    if (!u.startsWith('hiker://lazy#')) {
      // 老式写法（直接给分类地址）：交给主页那套（会换主列表）
      Navigator.of(ctx).pop();
      await _triggerAction(item);
      return;
    }
    final c2 = [...chain, u.substring('hiker://lazy#'.length)];
    try {
      final r2 = await _runToolEntry(src, c2, vars: vars);
      if (!mounted) return;
      if (r2.playUrl.isNotEmpty) {
        Navigator.of(ctx).pop();
        _open(item);
        return;
      }
      if (r2.list.isEmpty) {
        AppToast.error(r2.ok ? '这一步没有内容' : (r2.error ?? '规则执行失败'));
        return;
      }
      // 同一口径：弹窗内容一律掐掉页面外壳
      final next = stripLeadingShell(r2.list);
      if (next.isEmpty) {
        AppToast.message('这一步没有内容');
        return;
      }
      replace(next);
    } catch (e) {
      AppToast.error('$e');
    }
  }

  Widget _sheetHeader(BuildContext ctx, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(ctx).pop(),
            icon: Icon(
              Icons.close_rounded,
              size: 20,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
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
                it.title.isEmpty ? '(无标题)' : hikerPlainText(it.title),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontBody,
                ),
              ),
              subtitle: Text(
                it.url.isEmpty ? '(没有地址)' : it.url,
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
            ListTile(
              leading: Icon(
                Icons.refresh_rounded,
                color: AppTheme.accentOnSurface,
              ),
              title: Text(
                '刷新列表',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontBody,
                ),
              ),
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

  /// 长按源卡片「编辑源」：直接弹源配置框（与「源管理」页同一个）
  Future<void> _editSourceConfig(String id) async {
    final hit = _store.sources.where((e) => e.id == id).toList();
    if (hit.isEmpty || !mounted) return;
    await showHikerSourceConfigDialog(context, hit.first);
  }

  /// 长按源卡片 / 多选「分享」：导出成可再次导入的 JSON 放剪贴板
  Future<void> _shareSources(List<String> ids) async {
    final list = _store.sources.where((e) => ids.contains(e.id)).toList();
    if (list.isEmpty) return;
    final data = list.length == 1
        ? list.first.raw
        : [for (final s in list) s.raw];
    final text = const JsonEncoder.withIndent('  ').convert(data);
    await Clipboard.setData(ClipboardData(text: text));
    AppToast.message('已复制 ${list.length} 个源，可粘贴到导入框');
  }

  /// 长按 / 多选「删除」。返回删除后的当前源 id（面板据此重标勾）。
  Future<String?> _deleteSources(List<String> ids) async {
    final before = _store.currentId;
    for (final id in ids) {
      await _store.remove(id);
    }
    if (!mounted) return _store.currentId;
    AppToast.message('已删除 ${ids.length} 个源');
    if (_store.currentId != before) {
      // 删掉的正是当前源 ⇒ 与「设置页返回」同一套重置，避免列表还挂旧源
      setState(() {
        _cate = '';
        _cateName = '首页';
        _items = const [];
        _lazyChain = const [];
        _lastVars = const {};
        _onClose.clear();
        _didAutoRefresh = false;
        _page = 1;
        _hasMore = false;
        _reqCount = 0;
        _elapsedMs = 0;
        _error = null;
      });
      _load(page: 1);
    } else {
      setState(() {});
    }
    return _store.currentId;
  }

  Future<void> _pickSource() async {
    final list = _store.sources.where(_store.isEnabled).toList();
    if (list.isEmpty) {
      AppToast.message('还没有可用的海阔源，先去「海阔设置」导入');
      return;
    }
    // 版式**对齐影视模块的源切换面板**（底部面板 + 双排卡片网格 + 搜索），
    // 原来是 ListTile 列表弹窗，与影视那个观感完全不同（用户 2026-10-16）
    final picked = await CardSourceSheet.show(
      context: context,
      title: '切换海阔源',
      searchable: true,
      actionLabel: '管理',
      onAction: _openSettings,
      emptyHint: '还没有可用的海阔源',
      onEdit: _editSourceConfig,
      onDelete: _deleteSources,
      onShare: _shareSources,
      // 长按卡片左上角把手 → 直接拖动排序（落盘，重启保持）
      onReorder: (ids) => _store.reorder(ids),
      items: [
        for (final s in list)
          CardSourceItem(
            id: s.id,
            title: s.title,
            // 不可用的源仍列出来（与「海阔设置」一致），只是标红提示
            subtitle: s.usable ? s.author : '${s.author} · 不可用',
            warn: !s.usable,
            // 分类 tab 与「海阔源管理」页同一口径（源自己的 group）
            group: s.groupLabel,
            // 一级 tab：海阔脚本 / 海阔小程序脚本（两类都有时才出现）
            kind: s.kindLabel,
            selected: s.id == _store.currentId,
          ),
      ],
    );
    if (picked != null && picked != _store.currentId) {
      await _store.setCurrent(picked);
      // ⚠️ 换源必须把**上一个源的会话状态**全部清掉：
      //    · `_lazyChain` 是上一源规则的链条，带给新源会查错内容甚至空列表；
      //    · `_lastVars` / `_onClose` 同理属于上一个源；
      //    · 分页与统计也归零，避免"新源第一页却带着旧页码"。
      setState(() {
        _cate = '';
        _cateName = '首页';
        _items = const [];
        _lazyChain = const [];
        _lastVars = const {};
        _onClose.clear();
        _didAutoRefresh = false;
        _page = 1;
        _hasMore = false;
        _reqCount = 0;
        _elapsedMs = 0;
        _error = null;
      });
      _load(page: 1);
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HikerSettingsPage()),
    );
    if (!mounted) return;
    // 设置页里可能删掉/停用了当前源 → 回到首页必须换到新的 current 并重载，
    // 否则列表还挂着一个已经不存在的源。
    final cur = _store.current;
    if (cur?.id != _loadedSrcId) {
      setState(() {
        _cate = '';
        _cateName = '首页';
        _items = const [];
        _lazyChain = const [];
        _lastVars = const {};
        _onClose.clear();
        _didAutoRefresh = false;
        _page = 1;
        _hasMore = false;
      });
      _load(page: 1);
    } else {
      setState(() {});
    }
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
    final cats = src == null
        ? const <({String name, String url})>[]
        : _cats(src);
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: Column(
        children: [
          SizedBox(height: topInset),
          _header(src),
          // 分类条只看"源自己声明了分类"，不再看静态的 usable 判定 ——
          // 否则被判"依赖内置模块"但实际能跑的源（见 _load 的注释）连分类都没了
          if (cats.isNotEmpty && src != null) _categoryBar(cats),
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
      // 用户 2026-10-18：直接弹「源配置」编辑框，不再绕到海阔设置首页
      onTap: () => showHikerSourceConfigDialog(context, s),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
        decoration: BoxDecoration(
          // 与详情页卡片同一套：卡片底 + 0.6 细边 + 圆角 12
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.borderLight, width: 0.6),
        ),
        child: Row(
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 15,
              color: Colors.orange.shade400,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                '这个源需要填「源配置」（${s.configKeys.map((k) => 'config.$k').join('、')}）',
                maxLines: 2,
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: AppTheme.fontCaption,
                  height: 1.45,
                ),
              ),
            ),
            const SizedBox(width: 6),
            HikerPill('去设置', icon: Icons.chevron_right_rounded, accent: true),
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
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // 换源/加载中：箭头换成小转圈，点下去立刻有反馈
                  if (_loading)
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: AppTheme.accentColor,
                      ),
                    )
                  else
                    Icon(
                      Icons.expand_more_rounded,
                      size: 16,
                      color: AppTheme.textTertiary,
                    ),
                ],
              ),
            ),
            const Spacer(),
            // 顶栏图标统一成 30×30 圆底（与 CCTV/RSS/影视首页同款）
            _topIcon(Icons.search_rounded, '搜索', _openSearch),
            const SizedBox(width: 8),
            _topIcon(Icons.tune_rounded, '海阔设置', _openSettings),
          ],
        ),
      ),
    );
  }

  /// 顶栏圆形图标按钮（与 RSS / 影视首页同款）
  Widget _topIcon(IconData icon, String tooltip, VoidCallback? onTap) =>
      Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: AppTheme.backgroundTertiary,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: 15,
              color: onTap == null
                  ? AppTheme.textTertiary
                  : AppTheme.textSecondary,
            ),
          ),
        ),
      );

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
                // 与 RSS / 影视首页分类条同一套胶囊：选中实底 + 白字
                color: on ? AppTheme.accentColor : AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: on ? AppTheme.accentColor : AppTheme.borderLight,
                  width: 0.6,
                ),
              ),
              child: Text(
                c.name,
                style: TextStyle(
                  color: on ? Colors.white : AppTheme.textSecondary,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: on ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
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
          Text(
            parts.join(' · '),
            style: TextStyle(
              color: AppTheme.textTertiary,
              fontSize: AppTheme.fontCaption,
            ),
          ),
          const Spacer(),
          if (_cate.isNotEmpty)
            Text(
              _cateName,
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
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
              child: Text(
                '加载更多',
                style: TextStyle(color: AppTheme.accentOnSurface),
              ),
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
            Text(
              '还没有海阔源',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '去「海阔设置」导入海阔视界导出的 JSON（数组）。\n'
              '导入时会自动标出哪些源在 Phase 1 可用。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontFootnote,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accentColor,
              ),
              onPressed: _openSettings,
              child: const Text('打开海阔设置'),
            ),
          ],
        ),
      ),
    );
  }
}
