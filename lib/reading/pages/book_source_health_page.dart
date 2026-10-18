// lib/reading/pages/book_source_health_page.dart
//
// 「书源体检」完整页（对齐参考图 IMG_8554~8561）：
//   空闲页   ：盾牌图标 + 流程文案 + 并发数选择(1/2/3/4/6/8/12) + 开始体检
//   进行中   ：进度 X/N + 并发 N + 发热提示 + 实时统计(可用/网络不通/解析失败)
//              + 搜索框 + 统计 tab + 分类标签 + 实时列表
//   完成页   ：体检完成·时间 + 统计 + 列表 + 全选 + 一键优化 + 清理
// 退出页面不中断（结果写入服务缓存）。
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../models/book_source.dart';
import '../services/book_source_health_service.dart';
import '../services/book_source_service.dart';
import '../theme/jelly_theme.dart';
import '../utils/source_fail_text.dart';
import '../widgets/jelly_search_bar.dart';

/// 体检进行状态
enum _Phase { idle, running, done }

/// 条目展示状态（由体检结果推导）
enum _ItemState { untested, healthy, networkFail, parseFail }

class BookSourceHealthPage extends StatefulWidget {
  const BookSourceHealthPage({
    super.key,
    this.healthService,
    this.store,
  });

  /// 体检服务（**默认进程级单例** ✓；单测/widget 测试可注入假实现 ✓）。
  final BookSourceHealthService? healthService;

  /// 书源仓库（默认 [BookSourceStore.instance] ✓）。
  final BookSourceStore? store;

  @override
  State<BookSourceHealthPage> createState() => _BookSourceHealthPageState();
}

class _BookSourceHealthPageState extends State<BookSourceHealthPage> {
  // ✅ 体检逻辑已抽到 `services/book_source_health_service.dart` ✓ ——
  //   本页**只负责 UI** ✓：进度条 / 列表 / 确认弹窗 ✓，
  //   逐条真跑（含 Dart 引擎优先 → Node 回落 ✓）、并发、超时、取消全在服务里 ✓。
  late final BookSourceHealthService service =
      widget.healthService ?? BookSourceHealthService.instance;
  late final BookSourceStore store = widget.store ?? BookSourceStore.instance;

  _Phase _phase = _Phase.idle;
  int _concurrency = 12;
  int _done = 0;

  /// 已测结果缓存（按源 id）；页面退出后体检继续写服务缓存，下次进入可续显
  final Map<String, BookSourceHealth> _health = {};

  /// 统计 tab：0 全部 / 1 可用 / 2 收藏 / 3 密钥 / 4 网络异常 / 5 解析失败
  int _statTab = 0;

  /// 分类：0 全部 / 1 通常书源 / 2 快速书源
  int _groupTab = 0;

  final _searchCtrl = TextEditingController();
  String _kw = '';

  /// 多选：选中的源 id
  final Set<String> _selected = {};
  bool _selectAll = false;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _titleColor => _isDark ? Colors.white : JellyTheme.textPrimaryLight;
  Color get _subColor => _isDark ? Colors.white54 : JellyTheme.textSecondary;

  @override
  void initState() {
    super.initState();
    // 续显上次体检结果（退出页面不中断）
    _health.addAll(service.healthCache);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ============================================================
  // 统计推导
  // ============================================================

  static bool _isNetworkError(String detail) {
    // ✅ **判据已统一到 `utils/source_fail_text.dart`** ✓✓ ——
    //   原来本函数与 `services/book_source_service.dart` 的 `_isNetError` **各写一份** ✗
    //   （上面那段注释自己也写着「**两处必须同步**」✗，就是这次要解掉的隐患 ✓）。
    //   ⚠️ **映射有意"三合一"** ✗✓：本页只有两档（网络不通 / 解析失败 ✓），没有「拒绝」档 ✗，
    //     所以 `network` ✓ `denied`（403/401 ✓）`apiBroken`（404/5xx ✓）**都算"网络/服务类"** ✓✓
    //     —— 与改造前的行为**等价** ✓（旧判据里 `status code` 一律算网络 ✓）。
    //     若这里只认 `network` ✗，403 会掉进"解析失败" ✗✗ —— 那正是这段注释上面记录的老 bug ✓
    //     （"223 个源全被标解析失败"✗），所以**绝不能收窄** ✗✓。
    final kind = describeSourceFail(detail, what: '该源').kind;
    return kind == SourceFailKind.network ||
        kind == SourceFailKind.denied ||
        kind == SourceFailKind.apiBroken;
  }

  _ItemState _itemState(BookSource s) {
    final h = _health[s.id];
    if (h == null) return _ItemState.untested;
    if (h.level == BookSourceHealthLevel.healthy) return _ItemState.healthy;
    if (h.level == BookSourceHealthLevel.dead && _isNetworkError(h.detail)) {
      return _ItemState.networkFail;
    }
    return _ItemState.parseFail;
  }

  /// 只体检/展示**书源**：漫画源统一归漫画模块（用户 2026-10-18 分离）。
  List<BookSource> get _bookSources =>
      store.all.where((s) => !s.isComicSource).toList();

  int get _total => _bookSources.length;
  int get _usable =>
      _bookSources.where((s) => _itemState(s) == _ItemState.healthy).length;
  int get _networkFail =>
      _bookSources.where((s) => _itemState(s) == _ItemState.networkFail).length;
  int get _parseFail =>
      _bookSources.where((s) => _itemState(s) == _ItemState.parseFail).length;

  /// 分类分组（对齐原版「通常书源 / 快速书源」）：组名含「快速」→ 快速书源
  bool _isFast(BookSource s) => s.group.contains('快速');

  List<BookSource> get _filtered {
    var list = List<BookSource>.of(_bookSources);
    if (_kw.isNotEmpty) {
      final k = _kw.trim().toLowerCase();
      list = list.where((s) => s.name.toLowerCase().contains(k)).toList();
    }
    switch (_statTab) {
      case 1:
        list = list.where((s) => _itemState(s) == _ItemState.healthy).toList();
      case 2: // 收藏：无数据维度，等同全部
      case 3: // 密钥：无数据维度，等同全部
        break;
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

  int get _fastCount => _bookSources.where((s) => _isFast(s)).length;
  int get _normalCount => _bookSources.where((s) => !_isFast(s)).length;

  // ============================================================
  // 动作
  // ============================================================

  Future<void> _start() async {
    setState(() {
      _phase = _Phase.running;
      _done = 0;
      _health.clear();
      service.healthCache.clear();
    });
    await service.healthCheckAll(
      _bookSources,
      concurrency: _concurrency,
      // 退出页面不中断：dispose 后 onOne 不再 setState，但结果继续写服务缓存
      onOne: (h) {
        service.healthCache[h.source.id] = h;
        if (!mounted) return;
        setState(() {
          _health[h.source.id] = h;
          _done++;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _phase = _Phase.done;
      _done = _total;
    });
  }

  Future<void> _optimize() async {
    final usable = _bookSources
        .where((s) => _itemState(s) == _ItemState.healthy)
        .toList();
    final bad = _bookSources.where(
      (s) =>
          _itemState(s) == _ItemState.networkFail ||
          _itemState(s) == _ItemState.parseFail,
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '一键优化',
          style: TextStyle(fontSize: AppTheme.fontHeadline),
        ),
        content: Text(
          '将把 ${usable.length} 个可用源置顶，其中重新启用 0 个；'
          '停用 ${bad.length} 个网络不通/解析失败的源'
          '（不删除，可再次体检恢复）。确定继续？',
          style: const TextStyle(fontSize: AppTheme.fontSubhead, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('优化'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 可用源置顶（按原顺序），其余保持原顺序在后
    final ordered = <String>[
      ...usable.map((s) => s.id),
      ..._bookSources.where((s) => !usable.contains(s)).map((s) => s.id),
    ];
    await store.reorder(ordered);
    for (final s in bad) {
      if (s.enabled) await store.setEnabled(s.id, false);
    }
    if (mounted) _toast('已优化：置顶 ${usable.length} 个可用源，停用 ${bad.length} 个失败源');
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
        title: const Text(
          '清理书源',
          style: TextStyle(fontSize: AppTheme.fontHeadline),
        ),
        content: Text(
          '将删除 $n 个书源，删除后不可恢复，确定继续？',
          style: const TextStyle(fontSize: AppTheme.fontSubhead, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: JellyTheme.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final id in _selected.toList()) {
      await store.remove(id);
    }
    setState(() => _selected.clear());
    _toast('已删除 $n 个书源');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: const TextStyle(fontSize: AppTheme.fontFootnote),
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  // ============================================================
  // 构建
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _isDark
          ? JellyTheme.backgroundDark
          : JellyTheme.backgroundLight,
      appBar: AppBar(
        backgroundColor: _isDark
            ? JellyTheme.backgroundDark
            : JellyTheme.backgroundLight,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 20,
            color: _titleColor,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '书源体检',
          style: TextStyle(
            fontSize: AppTheme.fontTitle2,
            fontWeight: FontWeight.w600,
            color: _titleColor,
          ),
        ),
        actions: [
          // 防护（装饰，对齐参考图右上盾牌）
          Icon(Icons.shield_rounded, size: 18, color: _subColor),
          const SizedBox(width: 4),
          // 刷新：重跑体检（进行中禁用）
          IconButton(
            tooltip: '重新体检',
            icon: Icon(Icons.refresh_rounded, size: 20, color: _titleColor),
            onPressed: _phase == _Phase.running ? null : _start,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                if (_phase == _Phase.idle) ..._buildIdle(),
                if (_phase != _Phase.idle) ..._buildResult(),
              ],
            ),
          ),
          if (_phase != _Phase.idle) _buildBottomBar(),
        ],
      ),
    );
  }

  // ── 空闲页（8554）────────────────────────────────────────────
  List<Widget> _buildIdle() {
    return [
      const SizedBox(height: 60),
      Icon(Icons.verified_user_rounded, size: 84, color: JellyTheme.primary),
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
          '逐源体检：取书→详情→目录→正文；退出页面不中断',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: AppTheme.fontFootnote, color: _subColor),
        ),
      ),
      const SizedBox(height: 44),
      // 并发数选择（1/2/3/4/6/8/12，12 选中）
      Center(
        child: Wrap(
          spacing: 8,
          alignment: WrapAlignment.center,
          children: [
            1,
            2,
            3,
            4,
            6,
            8,
            12,
          ].map((n) => _concurrencyChip(n)).toList(),
        ),
      ),
      const SizedBox(height: 40),
      // 开始体检
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
          sel ? '✓ $n' : '$n',
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
            color: sel ? JellyTheme.primary : _titleColor,
          ),
        ),
      ),
    );
  }

  // ── 进行中 / 完成页（8555~8561）─────────────────────────────
  List<Widget> _buildResult() {
    final running = _phase == _Phase.running;
    final doneTime = _fmtTime(DateTime.now());
    return [
      // 信息行：进度/完成时间 + 并发
      Row(
        children: [
          Expanded(
            child: Text(
              running ? '体检中 $_done/$_total（取书→详情→目录→正文）' : '体检完成·$doneTime',
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w600,
                color: _titleColor,
              ),
            ),
          ),
          Text(
            '并发 $_concurrency',
            style: TextStyle(fontSize: AppTheme.fontFootnote, color: _subColor),
          ),
        ],
      ),
      if (running) ...[
        const SizedBox(height: 6),
        Text(
          '后台多线程体检会使手机发热，属正常现象',
          style: TextStyle(fontSize: AppTheme.fontCaption, color: _subColor),
        ),
      ],
      const SizedBox(height: 12),
      // 统计胶囊：可用 / 网络或源站异常 / 解析失败
      // ✅ **标签已改准**（本轮 ✓）—— 原来写「**网络不通**」✗ 会**冤枉用户自家网络** ✓：
      //   这一档其实是「网络 + **源站拒绝/5xx**」三合一 ✓（见 `_isNetworkError` 的注释 ✓，
      //   它**有意**把 403 与 5xx 都归进来 ✗✓ —— 因为本页只有两档、收窄会让 403 掉进"解析失败"✗）。
      //   ⇒ 但用户看到「网络不通 223」会以为**自己网坏了** ✗ ⇒ 改成「**网络/源站异常**」✓✓
      //     （一句话说清"可能是它那边的服务器出错"，而不是只怪网络 ✓）
      Row(
        children: [
          _statPill('可用', _usable, Colors.green),
          const SizedBox(width: 10),
          _statPill('网络/源站异常', _networkFail, Colors.orange),
          const SizedBox(width: 10),
          _statPill('解析失败', _parseFail, JellyTheme.error),
        ],
      ),
      const SizedBox(height: 14),
      // 搜索框（小胶囊，参考影视首页右上角样式）
      _searchBar(),
      const SizedBox(height: 10),
      // 统计 tab：总数/可用/收藏/密钥/网络异常/解析失败
      Row(
        children: [
          _numTab(0, '总数', _total),
          _numTab(1, '可用', _usable),
          _numTab(2, '收藏', 0),
          _numTab(3, '密钥', 0),
          _numTab(4, '网络/源站异常', _networkFail),
          _numTab(5, '解析失败', _parseFail),
        ],
      ),
      const SizedBox(height: 8),
      // 分类标签：全部/通常书源/快速书源
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
      // 列表
      if (_filtered.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 60),
          child: Center(
            child: Text(
              running && _done == 0 ? '暂无可用的源' : '暂无可用的源',
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                color: _subColor,
              ),
            ),
          ),
        )
      else
        ..._filtered.map(_itemTile),
      const SizedBox(height: 12),
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

  Widget _searchBar() {
    // ✅ **统一到共用组件** ✓（原实现是**手写一套皮** ✗：外层
    //   `Container(height:32, decoration: 圆角16 卡片色)` ✓ + 自己画的
    //   `Icon(Icons.search_rounded, size:16)` ✓ + 裸 `TextField` ✓ ——
    //   而「书架搜索页」等处用的是 `JellySearchBar` ✓ = 同一种控件**两套皮** ✗）。
    // ⚠️ 注意必须是**整段替换** ✓：`JellySearchBar` **自带**底色 / 圆角 / 左侧图标 ✓，
    //   若只换里面那层、把外层 `Container(decoration: …)` 留下 ✗，
    //   就会变成"**圆角方框里再套一个胶囊**" ✗（两层底 ✗）。
    // 参数对照 ✓：height:32 → 组件自带 ✓ · hintText '搜索书源' → 同名参数 ✓ ·
    //   onChanged: setState(_kw = v.trim()) → 同名参数，语义不变 ✓
    // 🆕 顺带补上 `onCleared` ✓ —— 原手写版**没有清空键** ✗，组件版自带 ✓（体验改善 ✓）
    return JellySearchBar(
      controller: _searchCtrl,
      hintText: '搜索书源',
      onChanged: (v) => setState(() => _kw = v.trim()),
      onCleared: () => setState(() => _kw = ''),
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
  Widget _itemTile(BookSource s) {
    final state = _itemState(s);
    final h = _health[s.id];
    final selected = _selected.contains(s.id);
    final (Color color, IconData icon, String sub) = switch (state) {
      _ItemState.healthy => (
        Colors.green,
        Icons.check_circle_rounded,
        '${h!.elapsed.inMilliseconds}ms·${h.detail}',
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
          _selected.remove(s.id);
        } else {
          _selected.add(s.id);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            // 勾选框
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
                  ? const Icon(
                      Icons.check_rounded,
                      size: 14,
                      color: Colors.white,
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.name,
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
                            fontSize: AppTheme.fontCaption,
                            color: color,
                          ),
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

  // ── 底部操作条：全选 / 一键优化 / 清理 ───────────────────────
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
            // 全选
            TextButton.icon(
              onPressed: () => setState(() {
                _selectAll = !_selectAll;
                if (_selectAll) {
                  _selected
                    ..clear()
                    ..addAll(list.map((s) => s.id));
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
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  color: _titleColor,
                ),
              ),
            ),
            const Spacer(),
            if (_phase == _Phase.done) ...[
              // 一键优化（盾牌+魔法棒，对齐 8560 底部操作）
              IconButton(
                tooltip: '一键优化',
                icon: Icon(
                  Icons.auto_fix_high_rounded,
                  size: 20,
                  color: JellyTheme.primary,
                ),
                onPressed: _usable > 0 ? _optimize : null,
              ),
              const SizedBox(width: 4),
            ],
            // 清理（删除选中）
            TextButton.icon(
              onPressed: _selected.isEmpty ? null : _cleanup,
              icon: Icon(
                Icons.delete_outline_rounded,
                size: 18,
                color: JellyTheme.error,
              ),
              label: Text(
                '清理',
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  color: JellyTheme.error,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
