import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/movie.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/card_action_sheet.dart';
import 'package:tvbox/widgets/vod_card.dart';
import 'package:tvbox/rex/rex_detail_page.dart';
import 'package:tvbox/rex/rex_layout_sheet.dart';
import 'package:tvbox/rex/rex_manage_page.dart';
import 'package:tvbox/rex/rex_market_page.dart';
import 'package:tvbox/rex/rex_models.dart';
import 'package:tvbox/rex/rex_service.dart';

/// 「REX」首页 —— 视觉与交互对齐影视首页：
///   顶栏源切换 + 幻灯片 → 模块分类 chips → 海报网格（VodCard）
///
/// 底栏里的「REX」tab **默认关闭**，在「设置 → 主页页面」里打开。
/// 导入 / 启停 / 排序 / 改地址 / 删除统一放在「REX 订阅管理」页。
class RexHomePage extends StatefulWidget {
  const RexHomePage({super.key});

  @override
  State<RexHomePage> createState() => _RexHomePageState();
}

class _RexHomePageState extends State<RexHomePage> {
  final _service = RexService.instance;
  final _scroll = ScrollController();

  /// 顶部幻灯片（用当前列表前几条当大图）
  final _bannerCtrl = PageController(viewportFraction: 0.9);
  Timer? _bannerTimer;
  int _bannerIndex = 0;

  String? _selectedUrl;
  RexFunction? _fn;
  final List<RexItem> _items = [];
  int _nextPage = 1;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  String _keyword = '';

  /// 请求代次：切模块/切分类/搜索时递增，旧请求回来直接丢弃
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _service.revision.addListener(_onServiceChanged);
    // 幻灯片自动轮播：内容不够两条时自动跳过
    _bannerTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_bannerCtrl.hasClients) return;
      final count = _bannerCount;
      if (count < 2) return;
      final next = (_bannerIndex + 1) % count;
      _bannerCtrl.animateToPage(
        next,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
      );
    });
    _service.load().then((_) {
      if (!mounted) return;
      _ensureSelection();
      _reload();
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _service.revision.removeListener(_onServiceChanged);
    _bannerTimer?.cancel();
    _bannerCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 幻灯片最多 6 张
  int get _bannerCount => _items.length < 6 ? _items.length : 6;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;

  List<RexModule> get _modules => _service.browsableModules;

  RexModule? get _module {
    final list = _modules;
    if (list.isEmpty) return null;
    for (final m in list) {
      if (m.url == _selectedUrl) return m;
    }
    return list.first;
  }

  void _ensureSelection() {
    final list = _modules;
    if (list.isEmpty) {
      _selectedUrl = null;
      _fn = null;
      return;
    }
    // 当前选中的模块被停用/删除 → 回到第一个
    if (!list.any((m) => m.url == _selectedUrl)) {
      _selectedUrl = list.first.url;
      RexService.instance.lastModuleUrl = _selectedUrl;
      _fn = list.first.listFunctions.isEmpty
          ? null
          : list.first.listFunctions.first;
      _keyword = '';
    }
  }

  void _onServiceChanged() {
    if (!mounted) return;
    final beforeUrl = _selectedUrl;
    _ensureSelection();
    if (beforeUrl != _selectedUrl) {
      setState(() => _items.clear());
      _reload();
    } else {
      setState(() {});
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading || _loadingMore || !_hasMore) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      _fetch(more: true);
    }
  }

  Future<void> _reload() async {
    final m = _module;
    if (m == null) return;
    _seq++;
    _nextPage = 1;
    _hasMore = true;
    setState(() {
      _items.clear();
      _error = null;
      _loadingMore = false;
      // ⚠️ 必须一起复位：否则上一个模块的请求在途时切到"没有分类函数"的模块，
      //    _fetch 会在早退分支直接 return，_loading 永远停在 true → 永久转圈。
      _loading = false;
      // 换模块/换分类：幻灯片回到第一张
      _bannerIndex = 0;
    });
    if (_bannerCtrl.hasClients) _bannerCtrl.jumpToPage(0);
    await _fetch(seq: _seq);
  }

  Future<void> _fetch({bool more = false, int? seq}) async {
    final m = _module;
    if (m == null) return;
    // 翻页要防重入；重新加载（more=false）允许打断上一次请求，
    // 旧请求靠 _seq 丢弃结果 —— 否则快速切分类会卡在"永远加载中"
    if (more && (_loading || _loadingMore)) return;
    if (_keyword.isEmpty && _fn == null) {
      // 无可用的列表函数（仅有 search / loadHome 的模块）：直接退出，
      // 但不能把 _loading 留在 true（那会让整页永远转圈）
      if (_loading || _loadingMore) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
      return;
    }
    final token = seq ?? _seq;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
      }
      _error = null;
    });
    try {
      final list = _keyword.isEmpty
          ? await _service.list(m, _fn!, page: _nextPage)
          : await _service.search(m, _keyword, page: _nextPage);
      if (!mounted || token != _seq) return;
      setState(() {
        if (!more) _items.clear();
        final seen = _items.map((e) => '${e.link}|${e.title}').toSet();
        for (final e in list) {
          if (seen.add('${e.link}|${e.title}')) _items.add(e);
        }
        _hasMore = list.isNotEmpty;
        _nextPage++;
      });
    } catch (e) {
      if (mounted && token == _seq) setState(() => _error = '$e');
    } finally {
      if (mounted && token == _seq) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  void _selectModule(RexModule m) {
    if (m.url == _selectedUrl) return;
    // 记下"首页正在用的模块"，订阅管理页的「定位」要用
    RexService.instance.lastModuleUrl = m.url;
    setState(() {
      _selectedUrl = m.url;
      _fn = m.listFunctions.isEmpty ? null : m.listFunctions.first;
      _keyword = '';
      _items.clear();
    });
    _reload();
  }

  void _selectFunction(RexFunction f) {
    if (identical(f, _fn)) return;
    setState(() {
      _fn = f;
      _keyword = '';
      _items.clear();
    });
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      // 顶栏不悬浮：和影视首页一样，顶栏 + 内容在同一个纵向布局里，
      // 幻灯片从顶栏下面开始（不会压到按钮上）
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _headerBar(),
            Expanded(child: _modules.isEmpty ? _empty() : _content()),
          ],
        ),
      ),
    );
  }

  /// 顶栏：左「源（模块）切换」，右功能按钮 —— 与影视首页同一套布局
  Widget _headerBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openModuleSheet,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.extension_rounded,
                      size: 17, color: AppTheme.accentColor),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _module?.title ?? '选择模块',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w600,
                          color: _fg),
                    ),
                  ),
                  Icon(Icons.arrow_drop_down_rounded, size: 20, color: _sub),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '切换布局',
            icon: Icon(Icons.grid_view_rounded, size: 21, color: _fg),
            onPressed: _openLayout,
          ),
          if (_module?.canSearch == true)
            IconButton(
              tooltip: '搜索',
              icon: Icon(Icons.search, size: 21, color: _fg),
              onPressed: _showSearch,
            ),
          IconButton(
            tooltip: 'REX 订阅管理',
            icon: Icon(Icons.tune_rounded, size: 21, color: _fg),
            onPressed: _openManage,
          ),
          IconButton(
            tooltip: 'REX 市场',
            icon: Icon(Icons.storefront_rounded, size: 21, color: _fg),
            onPressed: _openMarket,
          ),
        ],
      ),
    );
  }

  Widget _content() {
    final m = _module!;
    final fns = m.listFunctions;
    final cols = PlayerPrefs.instance.rexGridColumns.value.clamp(2, 4);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = (constraints.maxWidth -
                32 -
                AppTheme.cardSpacing * (cols - 1)) /
            cols;
        const posterRatio = 0.72;
        const textArea = 30.0;
        final ratio = cardWidth / (cardWidth * posterRatio + textArea);
        return RefreshIndicator(
          color: AppTheme.accentColor,
          onRefresh: _reload,
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // 顶部幻灯片：用当前列表前几条当大图轮播
              if (_keyword.isEmpty) _bannerSliver(),
              if (fns.isNotEmpty)
                SliverToBoxAdapter(child: _functionChips(fns)),
              if (_keyword.isNotEmpty)
                SliverToBoxAdapter(child: _searchHint()),
              if (_error != null && _items.isEmpty)
                SliverFillRemaining(hasScrollBody: false, child: _errorView())
              else if (_loading && _items.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_items.isEmpty)
                SliverFillRemaining(
                    hasScrollBody: false, child: _emptyItems())
              else
                _grid(cols, ratio),
              if (_loadingMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 110, top: 8),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 顶部幻灯片：取当前列表前 6 条，自动轮播 + 指示点。
  ///
  /// REX 模块没有统一的「首页推荐」接口（各家 loadHome 形状不一），
  /// 所以直接用列表前几条当大图 —— 影视首页的幻灯片本质上也是这么来的。
  Widget _bannerSliver() {
    final count = _bannerCount;
    if (count < 2 || _keyword.isNotEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final slides = _items.take(count).toList();
    // 与影视首页同一规格：16:9 大图卡片 + 左右露边（viewportFraction 0.9），
    // 顶栏保持普通布局（不悬浮、不压到图片上）
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 10),
        child: Column(
          children: [
            SizedBox(
              height: 196,
              child: PageView.builder(
                controller: _bannerCtrl,
                itemCount: slides.length,
                onPageChanged: (i) => setState(() => _bannerIndex = i),
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: GestureDetector(
                    onTap: () => _openItem(slides[i]),
                    child: ClipRRect(
                      borderRadius:
                          BorderRadius.circular(AppTheme.glassRadiusCard),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (slides[i].cover.isNotEmpty)
                            CachedNetworkImage(
                              imageUrl: slides[i].cover,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => ColoredBox(
                                  color: AppTheme.backgroundTertiary),
                            )
                          else
                            ColoredBox(color: AppTheme.backgroundTertiary),
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Color(0x22000000),
                                  Color(0xCC000000),
                                ],
                              ),
                            ),
                          ),
                          Positioned(
                            left: 14,
                            right: 14,
                            bottom: 12,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  slides[i].title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: AppTheme.fontHeadline,
                                    fontWeight: FontWeight.w700,
                                    shadows: [
                                      Shadow(
                                          blurRadius: 6,
                                          color: Colors.black87)
                                    ],
                                  ),
                                ),
                                if (slides[i].description.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    slides[i].description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.78),
                                      fontSize: AppTheme.fontCaption,
                                      shadows: const [
                                        Shadow(
                                            blurRadius: 5,
                                            color: Colors.black87)
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < slides.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: i == _bannerIndex ? 14 : 5,
                    height: 5,
                    margin: const EdgeInsets.symmetric(horizontal: 2.5),
                    decoration: BoxDecoration(
                      color: i == _bannerIndex
                          ? AppTheme.accentColor
                          : _sub.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 源（模块）切换面板 —— 顶栏左上角那个名字点开就是它。
  ///
  /// 模块一多，纯两列卡片往下翻很难找，所以这里补了：
  /// 搜索 / 排序 / 视图（列表 · 2 列 · 3 列）/ 定位当前模块。
  Future<void> _openModuleSheet() async {
    final all = _modules;
    if (all.isEmpty) return;
    // 面板内的临时状态（不落盘；列数那一项跟随 REX 的视图偏好）
    var keyword = '';
    var sort = 0; // 0 默认 / 1 名称 / 2 作者
    var listMode = false;
    var cols = PlayerPrefs.instance.rexGridColumns.value.clamp(2, 3);
    final searchCtrl = TextEditingController();
    final scroll = ScrollController();

    List<RexModule> visible() {
      final k = keyword.trim().toLowerCase();
      final list = k.isEmpty
          ? List<RexModule>.of(all)
          : all
              .where((m) =>
                  m.title.toLowerCase().contains(k) ||
                  m.author.toLowerCase().contains(k) ||
                  m.id.toLowerCase().contains(k))
              .toList();
      if (sort == 1) {
        list.sort((a, b) => a.title.compareTo(b.title));
      } else if (sort == 2) {
        list.sort((a, b) => a.author.compareTo(b.author));
      }
      return list;
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final shown = visible();
          final width = MediaQuery.of(ctx).size.width;
          final crossAxisCount = listMode ? 1 : cols;
          final itemW =
              (width - 32 - 10 * (crossAxisCount - 1)) / crossAxisCount;
          // 列表模式按「一行 50 高」算；网格 2 列沿用原来的 3.4，3 列收紧一点
          final ratio = listMode ? (itemW / 50) : (cols == 2 ? 3.4 : 2.7);
          final itemH = itemW / ratio;
          final compact = !listMode && cols >= 3;

          // 定位到当前模块：按固定的行高算偏移（GridView 里屏幕外的项没被
          // build，用 GlobalKey + ensureVisible 是拿不到 context 的）
          void locate() {
            final i = shown.indexWhere((m) => m.url == _module?.url);
            if (i < 0 || !scroll.hasClients) return;
            final row = i ~/ crossAxisCount;
            final target = row * (itemH + 8) - itemH;
            scroll.animateTo(
              target.clamp(0.0, scroll.position.maxScrollExtent),
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
            );
          }

          return SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.62),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
                    child: Row(
                      children: [
                        Text('切换模块',
                            style: TextStyle(
                                color: _fg,
                                fontSize: AppTheme.fontHeadline,
                                fontWeight: FontWeight.w600)),
                        const Spacer(),
                        Text(
                            shown.length == all.length
                                ? '${all.length} 个'
                                : '${shown.length}/${all.length} 个',
                            style: TextStyle(
                                color: _sub,
                                fontSize: AppTheme.fontCaption)),
                      ],
                    ),
                  ),
                  // ── 工具行：搜索 / 排序 / 视图 / 定位 ──────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 34,
                            child: TextField(
                              controller: searchCtrl,
                              style: TextStyle(
                                  color: _fg,
                                  fontSize: AppTheme.fontSubhead),
                              decoration: InputDecoration(
                                hintText: '搜索模块 / 作者',
                                hintStyle: TextStyle(
                                    color: _sub,
                                    fontSize: AppTheme.fontSubhead),
                                prefixIcon: Icon(Icons.search_rounded,
                                    size: 17, color: _sub),
                                prefixIconConstraints: const BoxConstraints(
                                    minWidth: 32, minHeight: 32),
                                isDense: true,
                                contentPadding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                filled: true,
                                fillColor: AppTheme.backgroundTertiary,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(
                                      AppTheme.radiusMD),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              onChanged: (v) =>
                                  setSheet(() => keyword = v.trim()),
                            ),
                          ),
                        ),
                        PopupMenuButton<int>(
                          tooltip: '排序',
                          padding: EdgeInsets.zero,
                          iconSize: 20,
                          icon: Icon(Icons.sort_rounded, size: 20, color: _sub),
                          initialValue: sort,
                          onSelected: (v) => setSheet(() => sort = v),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 0, child: Text('默认顺序')),
                            PopupMenuItem(value: 1, child: Text('按名称')),
                            PopupMenuItem(value: 2, child: Text('按作者')),
                          ],
                        ),
                        IconButton(
                          tooltip: '视图',
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            listMode
                                ? Icons.view_list_rounded
                                : Icons.grid_view_rounded,
                            size: 20,
                            color: _sub,
                          ),
                          onPressed: () async {
                            final picked = await showRexLayoutSheet(
                              ctx,
                              listMode: listMode,
                              current: cols,
                              maxColumns: 3,
                              onPick: (n) =>
                                  PlayerPrefs.instance.setRexGridColumns(n),
                            );
                            if (picked == null) return;
                            setSheet(() {
                              listMode = picked == 0;
                              if (picked > 0) cols = picked.clamp(2, 3);
                            });
                          },
                        ),
                        IconButton(
                          tooltip: '定位当前模块',
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.my_location_rounded,
                              size: 19, color: _sub),
                          onPressed: locate,
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: shown.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 28),
                            child: Center(
                              child: Text('没有匹配的模块',
                                  style: TextStyle(
                                      color: _sub,
                                      fontSize: AppTheme.fontFootnote)),
                            ),
                          )
                        : GridView.builder(
                            controller: scroll,
                            shrinkWrap: true,
                            padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: crossAxisCount,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 10,
                              childAspectRatio: ratio,
                            ),
                            itemCount: shown.length,
                            itemBuilder: (_, i) {
                              final m = shown[i];
                              final on = m.url == _module?.url;
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _selectModule(m);
                                },
                                // 长按 → 卡片式菜单（与影视源面板同一套手势）
                                onLongPress: () => _moduleMenu(ctx, m),
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: compact ? 8 : 12),
                                  decoration: BoxDecoration(
                                    color: on
                                        ? AppTheme.accentColor
                                            .withValues(alpha: 0.12)
                                        : AppTheme.backgroundTertiary,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: on
                                          ? AppTheme.accentColor
                                              .withValues(alpha: 0.4)
                                          : AppTheme.glassBorderSoft,
                                      width: on ? 1 : 0.5,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        on
                                            ? Icons.check_circle
                                            : Icons.radio_button_unchecked,
                                        size: compact ? 14 : 16,
                                        color: on ? AppTheme.accentColor : _sub,
                                      ),
                                      SizedBox(width: compact ? 5 : 8),
                                      Expanded(
                                        child: Text(
                                          m.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: on ? _fg : _sub,
                                            fontSize: compact
                                                ? AppTheme.fontCaption
                                                : AppTheme.fontSubhead,
                                            fontWeight: on
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    searchCtrl.dispose();
    scroll.dispose();
  }

  /// 模块卡片长按 → 卡片式菜单（使用 / 刷新 / 管理）
  ///
  /// 影视的源面板是「长按拖动排序 + ⋮ 菜单」；REX 模块顺序在订阅管理页排，
  /// 所以这里长按直接给菜单，比再塞一个 ⋮ 更省空间。
  Future<void> _moduleMenu(BuildContext sheetCtx, RexModule m) async {
    HapticFeedback.mediumImpact();
    await showCardActions(
      context,
      title: m.title,
      subtitle: RexService.isLocal(m.url)
          ? '本地模块'
          : '${m.listFunctions.length} 个分类${m.canSearch ? ' · 可搜索' : ''}',
      actions: [
        CardAction(
          icon: Icons.play_circle_outline_rounded,
          label: '使用',
          onTap: () {
            if (sheetCtx.mounted) Navigator.pop(sheetCtx);
            _selectModule(m);
          },
        ),
        CardAction(
          icon: Icons.sync_rounded,
          label: '刷新',
          onTap: () async {
            try {
              await RexService.instance.refreshModule(m);
              if (mounted) setState(() {});
              AppToast.show('已刷新「${m.title}」', '');
            } catch (e) {
              AppToast.show('刷新失败：$e', '');
            }
          },
        ),
        CardAction(
          icon: Icons.tune_rounded,
          label: '管理',
          onTap: () {
            if (sheetCtx.mounted) Navigator.pop(sheetCtx);
            Navigator.of(context).push(MaterialPageRoute<void>(
              settings: const RouteSettings(name: 'rex:manage'),
              builder: (_) => const RexManagePage(),
            ));
          },
        ),
      ],
    );
  }

  /// 切换布局：2 / 3 / 4 列（REX 自己的偏好，默认 2 列）
  Future<void> _openLayout() async {
    final picked = await showRexLayoutSheet(
      context,
      listMode: false,
      allowList: false,
      current: PlayerPrefs.instance.rexGridColumns.value,
      onPick: (n) => PlayerPrefs.instance.setRexGridColumns(n),
    );
    if (picked == null || !mounted) return;
    setState(() {});
  }

  void _openItem(RexItem item) {
    final m = _module;
    if (m == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: 'rex:detail'),
      builder: (_) => RexDetailPage(module: m, item: item),
    ));
  }

  Widget _functionChips(List<RexFunction> fns) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: fns.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final f = fns[i];
          final active = identical(f, _fn);
          return GestureDetector(
            onTap: () => _selectFunction(f),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: active
                    ? AppTheme.accentColor.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: active
                        ? AppTheme.accentColor.withValues(alpha: 0.4)
                        : Colors.transparent,
                    width: 0.8),
              ),
              child: Text(
                f.title.isEmpty ? f.functionName : f.title,
                style: TextStyle(
                    color: active ? AppTheme.accentColor : _sub,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight:
                        active ? FontWeight.w600 : FontWeight.w400),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _searchHint() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
        child: Row(
          children: [
            Icon(Icons.search, size: 14, color: _sub),
            const SizedBox(width: 6),
            Expanded(
              child: Text('搜索：$_keyword',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
            ),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: () {
                setState(() => _keyword = '');
                _reload();
              },
              child: Text('清除',
                  style: TextStyle(fontSize: AppTheme.fontCaption)),
            ),
          ],
        ),
      );

  Widget _grid(int cols, double ratio) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 120),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          childAspectRatio: ratio,
          crossAxisSpacing: AppTheme.cardSpacing,
          mainAxisSpacing: AppTheme.cardSpacing,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) {
            final item = _items[i];
            return VodCard(
              video: _toVideo(item),
              posterHeightRatio: 0.72,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                settings: const RouteSettings(name: 'rex:detail'),
                builder: (_) => RexDetailPage(module: _module!, item: item),
              )),
            );
          },
          childCount: _items.length,
        ),
      ),
    );
  }

  Video _toVideo(RexItem it) => Video(
        id: it.id.isEmpty ? it.link : it.id,
        name: it.title,
        pic: it.cover,
        note: it.description.length > 30
            ? it.description.substring(0, 30)
            : it.description,
        sourceKey: 'rex',
      );

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(36, 0, 36, 80),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.extension_outlined,
                  size: 38, color: _sub.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              Text(
                  _service.modules.isEmpty ? '还没有 REX 模块' : '没有可浏览的模块',
                  style: TextStyle(
                      color: _fg,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                _service.modules.isEmpty
                    ? '去「REX 市场」挑一个合集：\n'
                        '· 先列出里面的模块，勾选后再加载\n'
                        '· 也可以只加单个模块地址'
                    : '去「REX 订阅」把要用的模块打开。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: _sub, fontSize: AppTheme.fontFootnote, height: 1.7),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accentColor,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 42),
                ),
                onPressed:
                    _service.modules.isEmpty ? _openMarket : _openManage,
                icon: Icon(
                    _service.modules.isEmpty
                        ? Icons.storefront_rounded
                        : Icons.tune_rounded,
                    size: 18),
                label: Text(
                    _service.modules.isEmpty ? '打开 REX 市场' : '打开订阅管理'),
              ),
            ],
          ),
        ),
      );

  Widget _emptyItems() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            _fn == null ? '这个模块没有分类，试试搜索' : '没有内容',
            style: TextStyle(color: _sub, fontSize: AppTheme.fontFootnote),
          ),
        ),
      );

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 60),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded,
                  size: 34, color: _sub.withValues(alpha: 0.55)),
              const SizedBox(height: 10),
              Text('这个模块暂时取不到内容',
                  style: TextStyle(
                      color: _fg,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: _sub,
                    fontSize: AppTheme.fontFootnote,
                    height: 1.5),
              ),
              const SizedBox(height: 8),
              Text('多半是模块对应的站点挂了或被墙。可以重试，或切到上面的其它模块。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: _sub.withValues(alpha: 0.8),
                      fontSize: AppTheme.fontCaption,
                      height: 1.5)),
              const SizedBox(height: 14),
              OutlinedButton(onPressed: _reload, child: const Text('重试')),
            ],
          ),
        ),
      );

  Future<void> _openMarket() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'rex:market'),
      builder: (_) => const RexMarketPage(),
    ));
    if (!mounted) return;
    _ensureSelection();
    setState(() {});
    _reload();
  }

  Future<void> _openManage() async {
    await Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: 'rex:manage'),
      builder: (_) => const RexManagePage(),
    ));
    if (!mounted) return;
    _ensureSelection();
    setState(() {});
  }

  Future<void> _showSearch() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('搜索'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入关键词'),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('搜索')),
        ],
      ),
    );
    final kw = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || kw.isEmpty || !mounted) return;
    setState(() => _keyword = kw);
    await _reload();
    if (mounted && _items.isEmpty && _error == null) {
      AppToast.show('没有搜到结果', '');
    }
  }
}
