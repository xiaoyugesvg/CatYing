import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../common/theme.dart';
import '../../miniapp/pages/mini_app_player_page.dart';
import '../../services/tg_service.dart';
import '../../services/tg_title_filter.dart';
import '../../services/translate_service.dart';
import '../../widgets/app_toast.dart';
import '../settings/sub/tg_source_page.dart';

/// 「TG」分类页 —— 按影视首页的结构重做（2026-10-25）
///
/// 顶栏（左 → 右）：
///   · 左边：**切换群组**（点开是弹窗：收藏 + 账号里的群）
///   · 中间：当前群名
///   · 右边：搜索 / 视图（网格↔列表）/ 设置
/// 内容：
///   · 幻灯片：当前群最新几条有封面的视频，4 秒自动翻
///   · 群组横滑条：一点就切
///   · 视频网格（2 列）或列表，每批 12 条，点击弹操作面板
class TgHomePage extends StatefulWidget {
  const TgHomePage({super.key});

  @override
  State<TgHomePage> createState() => _TgHomePageState();
}

class _TgHomePageState extends State<TgHomePage> {
  final TgService _tg = TgService.instance;
  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  static const int _pageSize = 12;
  static const _kViewMode = 'tg.viewMode.v1';

  // 当前群
  String _peer = '';
  String _title = '';
  String _mode = 'public';

  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _channels = []; // 收藏（含内置）
  List<Map<String, dynamic>> _dialogs = []; // 账号里的群

  bool _loading = true;
  bool _more = true;
  bool _grid = true;
  bool _searching = false;
  String _query = '';
  String _error = '';
  int _offset = 0;

  /// 请求是否在飞 + 代次号。
  ///
  /// ⚠️ 不加这两个会有两个真 bug：
  ///   1. 空列表时 `pixels > maxScrollExtent - 400` 恒成立 ⇒ 滚动监听在首屏
  ///      连发两次同 offset 请求，**首批 24 条重复/乱序**；
  ///   2. 拉取途中切群组，旧请求回来仍 `addAll` 到新群的列表里 ⇒ **串台**。
  bool _inflight = false;
  int _loadGen = 0;

  Timer? _bannerTimer;
  final PageController _bannerCtrl = PageController(viewportFraction: 0.92);
  int _bannerIndex = 0;

  @override
  void initState() {
    super.initState();
    TgTitleFilter.instance.ensureLoaded();
    TgTitleFilter.instance.addListener(_onFilterChanged);
    _scroll.addListener(() {
      if (_scroll.position.pixels >
          _scroll.position.maxScrollExtent - 400) {
        _loadMore();
      }
    });
    _boot();
  }

  @override
  void dispose() {
    TgTitleFilter.instance.removeListener(_onFilterChanged);
    _bannerTimer?.cancel();
    _bannerCtrl.dispose();
    _scroll.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// 标题筛选规则变了（设置页里加词/关开关）⇒ 重新拉一页
  void _onFilterChanged() {
    if (!mounted) return;
    _reloadItems();
  }

  Future<void> _boot() async {
    final p = await SharedPreferences.getInstance();
    _grid = (p.getBool(_kViewMode) ?? true);
    await _tg.loadSettings();
    await _tg.pushConfig();
    await _tg.seedDefaults();
    await _reloadGroups();
    if (_channels.isNotEmpty) {
      final c = _channels.first;
      _peer = (c['peer'] ?? '').toString();
      _title = (c['title'] ?? _peer).toString();
      _mode = (c['mode'] ?? 'public').toString();
    } else if (_dialogs.isNotEmpty) {
      final d = _dialogs.first;
      _peer = (d['peer'] ?? '').toString();
      _title = (d['title'] ?? _peer).toString();
      _mode = 'login';
    }
    await _reloadItems();
  }

  Future<void> _reloadGroups() async {
    _channels = await _tg.channels();
    final st = await _tg.status();
    if (st['authorized'] == true) {
      final r = await _tg.dialogs();
      _dialogs = ((r['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    if (mounted) setState(() {});
  }

  Future<void> _reloadItems() async {
    // 作废在飞的旧请求（结果回来会因代次号不符被丢弃），并把锁放开
    _loadGen++;
    _inflight = false;
    _items = [];
    _offset = 0;
    _more = true;
    _error = '';
    _bannerIndex = 0;
    if (mounted) setState(() => _loading = true);
    if (_peer.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    await _loadMore();
    // 换了群组 ⇒ 幻灯片回到第一张（否则会停在旧群的页码上跳一下）
    if (_bannerCtrl.hasClients) _bannerCtrl.jumpToPage(0);
    _startBanner();
  }

  Future<void> _loadMore() async {
    if (_inflight || !_more || _peer.isEmpty) return;
    _inflight = true;
    final gen = _loadGen;
    setState(() => _loading = true);
    final r = _mode == 'public'
        ? await _tg.publicList(_peer, offsetId: _offset)
        : await _tg.videos(_peer, offsetId: _offset, limit: _pageSize);
    if (!mounted) return;
    // ⚠️ 先解锁再判代次（否则切群组后永远卡在"请求在飞"）
    _inflight = false;
    // 期间切了群组 / 重新加载 ⇒ 这条结果已经不属于当前列表，直接丢掉
    if (gen != _loadGen) return;
    if (r['ok'] == true) {
      var list = (r['items'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      if (_mode == 'public' && list.length > _pageSize) {
        list = list.sublist(0, _pageSize);
      }
      // 游标在筛选前取（筛选只影响显示，不该少翻一页）
      final pageLast =
          list.isEmpty ? 0 : ((list.last['id'] as num?)?.toInt() ?? 0);
      list = list
          .where((it) =>
              !TgTitleFilter.instance.shouldHide(it['title']?.toString()))
          .toList();
      setState(() {
        _items.addAll(list);
        _offset = _mode == 'public'
            ? pageLast
            : ((r['next'] as num?)?.toInt() ?? 0);
        _more = _mode == 'public'
            ? pageLast > 0
            : (list.isNotEmpty && _offset > 0);
        _loading = false;
      });
    } else {
      setState(() {
        _loading = false;
        _error = r['error']?.toString() ?? '加载失败';
      });
    }
  }

  // ── 幻灯片 ─────────────────────────────────────────────
  List<Map<String, dynamic>> get _bannerItems => _items
      .where((e) => (e['thumb'] ?? '').toString().isNotEmpty)
      .take(6)
      .toList();

  void _startBanner() {
    _bannerTimer?.cancel();
    final n = _bannerItems.length;
    if (n <= 1) return;
    _bannerTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || !_bannerCtrl.hasClients) return;
      _bannerIndex = (_bannerIndex + 1) % n;
      _bannerCtrl.animateToPage(
        _bannerIndex,
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
      );
    });
  }

  // ── 搜索 ───────────────────────────────────────────────
  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _query = '';
        _searchCtrl.clear();
      }
    });
    if (_searching) {
      Future.delayed(const Duration(milliseconds: 120),
          () => _searchFocus.requestFocus());
    }
  }

  List<Map<String, dynamic>> get _visibleItems {
    if (_query.trim().isEmpty) return _items;
    final q = _query.trim().toLowerCase();
    return _items
        .where((e) => (e['title'] ?? '').toString().toLowerCase().contains(q))
        .toList();
  }

  void _toggleView() {
    setState(() => _grid = !_grid);
    SharedPreferences.getInstance().then((p) => p.setBool(_kViewMode, _grid));
  }

  // ── 切换群组（弹窗）─────────────────────────────────────
  Future<void> _openSwitchSheet() async {
    await _reloadGroups();
    if (!mounted) return;
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (c) => _switchSheet(c),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _peer = (picked['peer'] ?? '').toString();
      _title = (picked['title'] ?? _peer).toString();
      _mode = (picked['mode'] ?? 'public').toString();
    });
    await _reloadItems();
  }

  Widget _switchSheet(BuildContext c) {
    // 一行两个的**卡片**（用户 2026-10-25：切换源也要卡片网格）
    Widget card(Map<String, dynamic> d) {
      final peer = (d['peer'] ?? '').toString();
      final mode = (d['mode'] ?? 'public').toString();
      final on = peer == _peer;
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.pop(c, {
          'peer': peer,
          'title': (d['title'] ?? peer).toString(),
          'mode': mode,
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: on
                ? AppTheme.accentOnSurface.withValues(alpha: 0.16)
                : AppTheme.backgroundTertiary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: on
                  ? AppTheme.accentOnSurface
                  : AppTheme.borderLight.withValues(alpha: 0.6),
              width: on ? 1 : 0.6,
            ),
          ),
          child: Row(
            children: [
              Icon(mode == 'login' ? Icons.lock_outline : Icons.public,
                  size: 16,
                  color: on ? AppTheme.accentOnSurface : AppTheme.textTertiary),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (d['title'] ?? peer).toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                        color:
                            on ? AppTheme.accentOnSurface : AppTheme.textPrimary,
                      ),
                    ),
                    Text('@$peer',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10, color: AppTheme.textTertiary)),
                  ],
                ),
              ),
              if (on)
                Icon(Icons.check, size: 15, color: AppTheme.accentOnSurface),
            ],
          ),
        ),
      );
    }

    final all = [
      ..._channels,
      ..._dialogs.map((d) => {
            'peer': d['peer'],
            'title': d['title'],
            'mode': 'login',
          }),
    ];

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.72),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textTertiary.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Text('切换群组',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary)),
                  const Spacer(),
                  Text('${all.length} 个',
                      style: TextStyle(
                          fontSize: 11, color: AppTheme.textTertiary)),
                ],
              ),
            ),
            Flexible(
              child: all.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 30),
                      child: Center(
                        child: Text('还没有可切换的频道\n去「设置 → TG 设置」里加一个',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.6,
                                color: AppTheme.textTertiary)),
                      ),
                    )
                  : GridView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        mainAxisExtent: 56,
                      ),
                      itemCount: all.length,
                      itemBuilder: (_, i) => card(all[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 点击条目：操作弹窗 ──────────────────────────────────
  void _itemSheet(Map<String, dynamic> it) {
    final title = (it['title'] ?? '').toString();
    Get.bottomSheet(
      Container(
        decoration: BoxDecoration(
          color: AppTheme.backgroundSecondary,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textTertiary.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary)),
              ),
              // 操作项也做成**一行两个的卡片**（用户 2026-10-25：
              // 「切换源以及长按的也是卡片网格式的」）
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
                child: GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 2,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 2.6,
                  children: [
                    _actionCard(Icons.play_circle_outline, '播放', () {
                      Get.back();
                      _play(it);
                    }),
                    _actionCard(Icons.bookmark_add_outlined, '收藏当前频道',
                        () async {
                      Get.back();
                      await _tg.addChannel(_peer, title: _title, mode: _mode);
                      await _reloadGroups();
                      if (mounted) AppToast.message('已加入 TG 收藏');
                    }),
                    _actionCard(Icons.link_rounded, '复制消息链接', () async {
                      Get.back();
                      final url = 'https://t.me/$_peer/${it['id']}';
                      await _copy(url);
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      backgroundColor: Colors.transparent,
    );
  }

  /// 操作弹窗里的一张动作卡（一行两个）
  Widget _actionCard(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: AppTheme.borderLight.withValues(alpha: 0.6), width: 0.6),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppTheme.accentOnSurface),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textPrimary)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    AppToast.message('链接已复制');
  }

  /// 点标题翻译 / 再点还原（用户 2026-10-25：外语频道标题点一下出中文）
  Future<void> _toggleZh(Map<String, dynamic> it) async {
    final zh = it['_zh'];
    if (zh is String && zh.isNotEmpty) {
      setState(() => it.remove('_zh'));
      return;
    }
    final raw = (it['title'] ?? '').toString();
    if (!TranslateService.needsTranslation(raw)) {
      AppToast.message('这条本来就是中文');
      return;
    }
    AppToast.message('翻译中…');
    try {
      final t = await TranslateService.instance.toZh(raw);
      if (!mounted) return;
      setState(() => it['_zh'] = t);
    } catch (e) {
      if (mounted) AppToast.message('翻译失败：$e');
    }
  }

  void _play(Map<String, dynamic> it) {
    final rel = (it['url'] ?? '').toString();
    if (rel.isEmpty) {
      AppToast.message('地址为空');
      return;
    }
    Get.to(() => MiniAppPlayerPage(
          url: _tg.absolute(rel),
          title: (it['title'] ?? '').toString(),
        ));
  }

  // ── UI ─────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _header(),
            Expanded(child: _content()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 6),
      child: Row(
        children: [
          // 左：切换群组
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: _openSwitchSheet,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
              decoration: BoxDecoration(
                color: AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.swap_horiz_rounded,
                      size: 16, color: AppTheme.textSecondary),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(
                      _title.isEmpty ? '选择群组' : _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary),
                    ),
                  ),
                  Icon(Icons.expand_more_rounded,
                      size: 17, color: AppTheme.textTertiary),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 中：搜索框（点开才展开）
          Expanded(
            child: _searching
                ? Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundTertiary,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search,
                            size: 16, color: AppTheme.textTertiary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: TextField(
                            controller: _searchCtrl,
                            focusNode: _searchFocus,
                            onChanged: (v) => setState(() => _query = v),
                            style: TextStyle(
                                fontSize: 13, color: AppTheme.textPrimary),
                            decoration: InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              hintText: '在当前群内搜索',
                              hintStyle: TextStyle(
                                  fontSize: 12, color: AppTheme.textTertiary),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '搜索',
            onPressed: _toggleSearch,
            icon: Icon(_searching ? Icons.close : Icons.search,
                size: 20, color: AppTheme.textSecondary),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: _grid ? '切换为列表' : '切换为网格',
            onPressed: _toggleView,
            icon: Icon(_grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
                size: 20, color: AppTheme.textSecondary),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'TG 设置',
            onPressed: () async {
              await Get.to(() => const TgSourcePage());
              await _reloadGroups();
            },
            icon: Icon(Icons.settings_outlined,
                size: 20, color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _content() {
    if (_peer.isEmpty) {
      return _emptyGuide();
    }
    if (_items.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error.isEmpty ? '这个群组里没有视频文件' : _error,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 13)),
            const SizedBox(height: 12),
            TextButton(onPressed: _reloadItems, child: const Text('重试')),
          ],
        ),
      );
    }
    final list = _visibleItems;
    // 卡片高度 = 16:9 封面 + 6 间距 + 一行名称（名称在卡片外，居中）
    // 原来写死 194：文字区被算进卡片里 ⇒ 卡片之间空一大截（用户 2026-10-25）
    final gridW = MediaQuery.of(context).size.width - 12 * 2 - 10;
    final cardExtent = (gridW / 2) * 9 / 16 + 6 + 19;
    return RefreshIndicator(
      onRefresh: _reloadItems,
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          if (!_searching && _bannerItems.isNotEmpty)
            SliverToBoxAdapter(child: _banner()),
          if (!_searching) SliverToBoxAdapter(child: _groupStrip()),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Row(
                children: [
                  Text(_query.isEmpty ? '最新' : '搜索结果 ${list.length}',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary)),
                  const Spacer(),
                  if (_loading)
                    const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
            ),
          ),
          if (list.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('没有匹配的视频',
                      style: TextStyle(
                          fontSize: 12, color: AppTheme.textTertiary)),
                ),
              ),
            )
          else if (_grid)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  mainAxisExtent: cardExtent,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _card(list[i]),
                  childCount: list.length,
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _row(list[i]),
                  childCount: list.length,
                ),
              ),
            ),
          if (_more && _query.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 26),
                child: Center(
                  child: Text(_loading ? '加载中…' : '上滑加载更多',
                      style: TextStyle(
                          fontSize: 11, color: AppTheme.textTertiary)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyGuide() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.telegram, size: 40, color: AppTheme.textTertiary),
            const SizedBox(height: 12),
            Text('还没有可看的群组\n公开频道直接贴名字就能看，私有群需要扫码登录',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5, height: 1.7, color: AppTheme.textTertiary)),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: () async {
                await Get.to(() => const TgSourcePage());
                await _reloadGroups();
              },
              child: const Text('去设置'),
            ),
          ],
        ),
      ),
    );
  }

  // ── 幻灯片 ─────────────────────────────────────────────
  Widget _banner() {
    final items = _bannerItems;
    return SizedBox(
      height: 168,
      child: PageView.builder(
        controller: _bannerCtrl,
        itemCount: items.length,
        onPageChanged: (i) => setState(() => _bannerIndex = i),
        itemBuilder: (context, i) {
          final it = items[i];
          return GestureDetector(
            onTap: () => _itemSheet(it),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: AppTheme.backgroundTertiary,
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.network(
                    _tg.absolute((it['thumb'] ?? '').toString()),
                    fit: BoxFit.cover,
                    cacheWidth: 900,
                    errorBuilder: (_, __, ___) => Container(
                      color: AppTheme.backgroundTertiary,
                    ),
                  ),
                  // 底部渐变，保证文字可读
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.62),
                          ],
                          stops: const [0.45, 1.0],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 12,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (it['title'] ?? '').toString(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              height: 1.3),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          [
                            if ((it['duration'] as num? ?? 0) > 0)
                              _dur((it['duration'] as num).toInt()),
                            if ((it['size'] as num? ?? 0) > 0)
                              _size((it['size'] as num).toInt()),
                          ].join('  ·  '),
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.82),
                              fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── 群组横滑 ───────────────────────────────────────────
  Widget _groupStrip() {
    final all = [
      ..._channels,
      ..._dialogs.map((d) => {
            'peer': d['peer'],
            'title': d['title'],
            'mode': 'login',
          }),
    ];
    if (all.length <= 1) return const SizedBox.shrink();
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: all.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final d = all[i];
          final peer = (d['peer'] ?? '').toString();
          final on = peer == _peer;
          return GestureDetector(
            onTap: () async {
              if (on) return;
              setState(() {
                _peer = peer;
                _title = (d['title'] ?? peer).toString();
                _mode = (d['mode'] ?? 'public').toString();
              });
              await _reloadItems();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color:
                    on ? AppTheme.accentOnSurface : AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                (d['title'] ?? peer).toString(),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                  color: on ? Colors.white : AppTheme.textSecondary,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── 卡片 ───────────────────────────────────────────────
  Widget _card(Map<String, dynamic> it) {
    final title = (it['title'] ?? '').toString();
    final thumb = (it['thumb'] ?? '').toString();
    final dur = (it['duration'] as num?)?.toInt() ?? 0;
    // 用户 2026-10-25：名称**不放进卡片**（卡片只留 16:9 封面），
    // 否则固定高度的网格里多出一块文字区 ⇒ 卡片之间空一大截。
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _itemSheet(it),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (thumb.isEmpty)
                    Container(
                      color: AppTheme.backgroundTertiary,
                      child: Icon(Icons.movie_outlined,
                          size: 22, color: AppTheme.textTertiary),
                    )
                  else
                    Image.network(
                      _tg.absolute(thumb),
                      fit: BoxFit.cover,
                      cacheWidth: 400,
                      errorBuilder: (_, __, ___) => Container(
                        color: AppTheme.backgroundTertiary,
                        child: Icon(Icons.movie_outlined,
                            size: 22, color: AppTheme.textTertiary),
                      ),
                    ),
                  if (dur > 0)
                    Positioned(
                      right: 5,
                      bottom: 5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(_dur(dur),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                  Positioned(
                    left: 5,
                    top: 5,
                    child: Icon(Icons.play_circle_fill_rounded,
                        size: 20,
                        color: Colors.white.withValues(alpha: 0.9),
                        shadows: const [
                          Shadow(color: Colors.black26, blurRadius: 4)
                        ]),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          // 名称在卡片下方、居中（点一下还是切译文）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _toggleZh(it),
            child: Text(
              (it['_zh'] is String && (it['_zh'] as String).isNotEmpty)
                  ? it['_zh'] as String
                  : title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppTheme.textPrimary, fontSize: 12.5, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(Map<String, dynamic> it) {
    final title = (it['title'] ?? '').toString();
    final thumb = (it['thumb'] ?? '').toString();
    final dur = (it['duration'] as num?)?.toInt() ?? 0;
    final size = (it['size'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _itemSheet(it),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppTheme.backgroundCard,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 108,
                  height: 62,
                  child: thumb.isEmpty
                      ? Container(
                          color: AppTheme.backgroundTertiary,
                          child: Icon(Icons.movie_outlined,
                              size: 22, color: AppTheme.textTertiary))
                      : Image.network(_tg.absolute(thumb),
                          fit: BoxFit.cover,
                          cacheWidth: 216,
                          errorBuilder: (_, __, ___) => Container(
                                color: AppTheme.backgroundTertiary,
                                child: Icon(Icons.movie_outlined,
                                    size: 22, color: AppTheme.textTertiary),
                              )),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _toggleZh(it),
                      child: Text(
                          (it['_zh'] is String &&
                                  (it['_zh'] as String).isNotEmpty)
                              ? it['_zh'] as String
                              : title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 13,
                              height: 1.35)),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      [
                        if (dur > 0) _dur(dur),
                        if (size > 0) _size(size),
                      ].join('  ·  '),
                      style: TextStyle(
                          color: AppTheme.textTertiary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Icon(Icons.play_circle_outline,
                  color: AppTheme.accentOnSurface, size: 22),
            ],
          ),
        ),
      ),
    );
  }

  static String _dur(int s) {
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final ss = s % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final sss = ss.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$sss' : '$mm:$sss';
  }

  static String _size(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(0)} MB';
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }
}
