import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import '../source/global_proxy.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book_source.dart';
import '../services/book_source_service.dart';
import '../services/qread_api.dart';
import 'book_source_editor_page.dart';
import 'book_source_health_page.dart';
import 'book_source_login_page.dart';
// cloud_book_source_page 的 import 已移除（云端网页入口迁到书源页）
// ✅ **补齐缺失的 import** ✗✓（本轮修的 8 条 error 全因它们 ✗）：
//   · `JellySearchBar` / `JellyExpandableSearch` / `JellySlidingActions`(+`JellyAction`)
//     这三个是**共用组件** ✓ —— 我之前误以为"能被传递导出"✗，那是因为**闸门跑错了目录** ✗✗
//     （`dart analyze` 没带仓库根 → 分析的是别的项目 ✓ → 假绿 ✓）。
//   （书源页本身不再提供「浏览记录 / 收藏」入口，如需查看请到漫画/图书搜索页或“我的”页。）
import '../widgets/jelly_expandable_search.dart';
import '../widgets/jelly_search_bar.dart';
import '../widgets/jelly_sliding_actions.dart';
import '../theme/jelly_theme.dart';
import '../../common/theme.dart';

/// 书源仓库 —— 小说书源（Legado 格式）的导入与管理。
///
/// ── 界面参照 ──────────────────────────────────────────────────
/// 按 **cmbok V2.0.7** 的书源页重做（用户提供截图）：
///   · 标题「书源」+ 右侧搜索框「搜索书源图书」
///   · 空态：「还没有书源 / 用地址、口令或本地文件导入书源」+「+ 去导入书源」
///   · 导入三种方式：**地址 / 口令 / 本地文件**（截图原文）
///
/// ── 为什么早期判断失误（记下来免得再错）────────────────────────
/// 开源仓库 hlning/cmbok_app 的快照停在 **V2.0.3**，而书源仓库是
/// **V2.0.7** 新增的功能（其更新说明明确列出"书源仓库：多选删除、分享"、
/// "书源页/仓库：分组功能"、"书源体检"、"书源编辑"、"书源变量"），
/// 之后源码不再开源 —— 所以源码里搜不到，但发布版里确实有。
/// **教训：判断某功能是否存在，不能只看开源快照，要看发布说明。**
///
/// ── 与「漫画源仓库」的关系 ────────────────────────────────────
/// 两个**独立**页面，不共用任何代码：
///   · 漫画源仓库 = SiteConfig（取图片）+ SourceConfigStore
///   · 本页       = Legado BookSource（取文字）+ BookSourceStore
class BookSourceRepoPage extends StatefulWidget {
  const BookSourceRepoPage({super.key});

  @override
  State<BookSourceRepoPage> createState() => _BookSourceRepoPageState();
}

class _BookSourceRepoPageState extends State<BookSourceRepoPage> {
  final store = BookSourceStore.instance;
  final _searchCtrl = TextEditingController();
  /// 顶部导入卡片的地址输入框
  final _urlCtrl = TextEditingController();
  bool _busy = false;
  bool _selectMode = false;
  bool _searching = false;
  String _keyword = '';
  bool _autoImportHandled = false;
  final Set<String> _selected = {};

  // ── 主列表的筛选与分组（按截图）────────────────────────────
  /// 顶部「筛选已导入的书源」输入框
  final _filterCtrl = TextEditingController();
  String _filter = '';
  /// 分组 chip 当前选中项：null = 「全部」
  String? _pickedGroup;
  /// 被「隐藏组」的组名（不显示其书源）
  final Set<String> _hiddenGroups = {};

  /// 书源体检结果（id → 健康度）。「体检」按钮跑完填这里，
  /// 卡片上会显示徽标 —— 不用逐个点进去看。
  final Map<String, BookSourceHealth> _health = {};
  /// 体检进行中（按钮转圈 + 禁用重复点击）
  bool _healthChecking = false;

  @override
  void initState() {
    super.initState();
    if (store.isEmpty) store.init();
    QreadServerConfig.instance.load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 带 {action:'import'} 进入时直接弹导入（供"去导入书源"类入口复用）。
    // 只用一次，避免每次依赖变化都弹。
    if (_autoImportHandled) return;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['action'] == 'import') {
      _autoImportHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showImportSheet();
      });
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _urlCtrl.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _card => _isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
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

  /// 搜索过滤结果
  List<BookSource> get _visible {
    final all = store.sorted();
    if (_keyword.isEmpty) return all;
    final k = _keyword.toLowerCase();
    return all
        .where((s) =>
            s.name.toLowerCase().contains(k) ||
            s.url.toLowerCase().contains(k) ||
            s.group.toLowerCase().contains(k))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          _isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: _buildAppBar(),
      body: ListenableBuilder(
        listenable: store.revision,
        builder: (context, _) {
          final list = _visible;
          return Column(
            children: [
              // 导入卡片**常驻页面顶部**（不藏进弹层）。
              // 按 cmbok V2.0.7 截图：地址输入框 + 三个并排按钮就在页面上，
              // 用户一眼看到"能怎么导"。
              _importCard(),
              if (_selectMode) _selectBar(store.sorted()),
              Expanded(
                child: store.isEmpty
                    ? _emptyState()
                    : (list.isEmpty ? _noMatchState() : _sourceList(list)),
              ),
            ],
          );
        },
      ),
      floatingActionButton: _selectMode && _selected.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _deleteSelected,
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除选中'),
              backgroundColor: Colors.redAccent,
            )
          : null,
    );
  }

  // ============================================================
  // 导入卡片（按截图：标题 + 说明 + 地址框 + 三个并排按钮）
  // ============================================================

  Widget _importCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('导入书源',
              style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w700,
                  color: _titleColor)),
          const SizedBox(height: 3),
          Text(
            // 截图原文。这句很重要：用户最怕"导入会不会把我已有的源冲掉"
            '导入按地址合并去重，不会覆盖已有的源',
            style: TextStyle(fontSize: AppTheme.fontFootnote, color: JellyTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            style: TextStyle(fontSize: AppTheme.fontBody, color: _titleColor),
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: '书源地址（json / zip / 仓库索引）',
              hintStyle:
                  TextStyle(fontSize: AppTheme.fontBody, color: JellyTheme.textSecondary),
              filled: true,
              fillColor: _isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.black.withValues(alpha: 0.035),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _importByFile,
                  style: _outlineStyle(),
                  child: const Text('导入文件', style: TextStyle(fontSize: AppTheme.fontBody)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _importByCode,
                  style: _outlineStyle(),
                  child: const Text('口令导入', style: TextStyle(fontSize: AppTheme.fontBody)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _importByUrlFromField,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('从地址导入',
                          style: TextStyle(fontSize: AppTheme.fontBody)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  ButtonStyle _outlineStyle() => OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 12),
        side: BorderSide(
          color: _isDark
              ? Colors.white.withValues(alpha: 0.22)
              : Colors.black.withValues(alpha: 0.16),
        ),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        foregroundColor: _titleColor,
      );

  // ============================================================
  // qread 服务端连接（壳模式）
  // ============================================================

  /// 服务端设置弹窗：地址/账号/密码 + 登录/登出 + 一键拉取服务端书源。
  Future<void> _showServerDialog() async {
    final cfg = QreadServerConfig.instance;
    final baseCtrl = TextEditingController(text: cfg.baseUrl);
    final userCtrl = TextEditingController(text: cfg.username);
    final passCtrl = TextEditingController(text: cfg.password);
    var busy = false;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          decoration: BoxDecoration(
            color: _card,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 12,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: JellyTheme.textSecondary.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Icon(Icons.cloud_outlined,
                        size: 22,
                        color: cfg.isLoggedIn
                            ? Colors.lightBlueAccent
                            : _titleColor),
                    const SizedBox(width: 8),
                    Text('qread 服务端',
                        style: TextStyle(
                            fontSize: AppTheme.fontTitle2,
                            fontWeight: FontWeight.w700,
                            color: _titleColor)),
                    const Spacer(),
                    Text(
                      cfg.isLoggedIn ? '已连接' : '未连接',
                      style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        color: cfg.isLoggedIn
                            ? Colors.lightGreenAccent
                            : JellyTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  cfg.isLoggedIn
                      ? '书源规则由服务端执行；本页导入/编辑/删除会同步到服务端'
                      : '配置你的 qread（轻阅读）服务端地址与账号，书源规则改由服务端执行，解决客户端加密站/接口 500 问题',
                  style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: JellyTheme.textSecondary),
                ),
                const SizedBox(height: 14),
                _serverField(baseCtrl, '服务端地址', 'https://example.com:8080',
                    keyboardType: TextInputType.url),
                const SizedBox(height: 10),
                _serverField(userCtrl, '账号', '服务端注册的用户名'),
                const SizedBox(height: 10),
                _serverField(passCtrl, '密码', '服务端密码', obscure: true),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: busy
                            ? null
                            : () async {
                                setSheet(() => busy = true);
                                try {
                                  await cfg.save(
                                    baseUrl: baseCtrl.text.trim(),
                                    username: userCtrl.text.trim(),
                                    password: passCtrl.text,
                                  );
                                  await QreadApi.instance.login();
                                  if (ctx.mounted) {
                                    Navigator.pop(ctx);
                                  }
                                  if (mounted) {
                                    setState(() {});
                                    _toast('服务端连接成功');
                                  }
                                } on QreadException catch (e) {
                                  if (mounted) _toast('连接失败：${e.message}');
                                } catch (e) {
                                  if (mounted) _toast('连接失败：$e');
                                } finally {
                                  setSheet(() => busy = false);
                                }
                              },
                        icon: busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.login_rounded, size: 18),
                        label: const Text('保存并连接'),
                      ),
                    ),
                    if (cfg.isLoggedIn) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () async {
                                  setSheet(() => busy = true);
                                  try {
                                    await _syncFromServer();
                                    if (ctx.mounted) Navigator.pop(ctx);
                                    if (mounted) setState(() {});
                                  } finally {
                                    setSheet(() => busy = false);
                                  }
                                },
                          icon: const Icon(Icons.cloud_download_outlined,
                              size: 18),
                          label: const Text('拉取书源'),
                        ),
                      ),
                    ],
                  ],
                ),
                // 「打开云端网页版」按钮已移除（用户 2026-10-07）：
                // 该入口现在放在**书源页**顶栏（cloud_outlined 图标按钮），
                // 而不是书源仓库里 —— 云端网页是"看书"的入口，
                // 放书源页更顺手；仓库页只保留书源的管理能力。
                if (cfg.isLoggedIn) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () async {
                        await cfg.logout();
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) {
                          setState(() {});
                          _toast('已断开服务端，回到本地模式');
                        }
                      },
                      child: Text('断开连接（回到本地模式）',
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: JellyTheme.textSecondary)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _serverField(TextEditingController c, String label, String hint,
      {bool obscure = false, TextInputType? keyboardType}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      keyboardType: keyboardType,
      style: TextStyle(fontSize: AppTheme.fontBody, color: _titleColor),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: TextStyle(
            fontSize: AppTheme.fontBody, color: JellyTheme.textSecondary),
        filled: true,
        fillColor: _isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.035),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  /// 从服务端拉取全部书源（完整规则 JSON）并替换本地书源列表。
  /// 服务端是权威库：替换前弹确认，防止冲掉本地手动导入的源。
  Future<void> _syncFromServer() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从服务端拉取书源'),
        content: const Text('将用服务端书源列表替换本地书源列表（含已禁用的），继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('拉取')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final list = await QreadApi.instance.exportSources(null);
      final parsed = <BookSource>[];
      for (final m in list) {
        final s = BookSource.fromJson(m);
        if (s != null) parsed.add(s);
      }
      if (parsed.isEmpty) {
        _toast('服务端没有书源');
        return;
      }
      await store.removeAll();
      final r = await store.addAll(parsed);
      _toast('已从服务端拉取 ${parsed.length} 个书源'
          '（新增 ${r.added}、更新 ${r.updated}）');
    } on QreadException catch (e) {
      _toast('拉取失败：${e.message}');
    } catch (e) {
      _toast('拉取失败：$e');
    }
  }

  /// 导入双写：本地已保存成功后，把完整规则同步到服务端。
  Future<void> _pushImportToServer(List<BookSource> parsed) async {
    if (!QreadServerConfig.instance.isLoggedIn) return;
    try {
      final n = await QreadApi.instance
          .saveSources(parsed.map((s) => s.raw).toList());
      _toast('已同步 $n 个书源到服务端');
    } on QreadException catch (e) {
      _toast('本地已导入，服务端同步失败：${e.message}');
    } catch (e) {
      _toast('本地已导入，服务端同步失败：$e');
    }
  }

  // ============================================================
  // AppBar：标题「书源仓库」（居中）+ 分享 + 体检（按截图）
  // ============================================================

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      // ── 🔴 `centerTitle` 改成 false（修用户反馈"搜索框要往右靠"）──────
      //
      // 原来 `centerTitle: true` ✗，而搜索框就挂在 `title` 里 →
      // 它被塞进**居中区**，再叠加组件内部当时写死的 `Alignment.centerLeft` ✗
      // ⇒ 搜索框落在屏幕偏左，离右边 `actions` 的图标**空一大截** ✗
      // 用户原话：「搜索框要靠右，然后右边的图标也要靠右，不要贴那么近」
      //
      // 改成 false 后 `title` 从左侧排版，再由下面的 `Spacer`
      // 把搜索框推到**紧挨右侧图标**的位置 ✓
      centerTitle: false,
      title: Row(
        children: [
          // 非搜索态：显示标题
          if (!_searching)
            Flexible(
              child: Text(
                _selectMode ? '已选 ${_selected.length}' : '书源仓库',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTheme.fontTitle2,
                  fontWeight: FontWeight.w600,
                  color: _titleColor,
                ),
              ),
            ),
          // 搜索态：搜索框 + 靠右（原来的三元两支拆成两个分支，语义更清楚）
          if (_searching) ...[
            // ⚠️ **必须用 `Spacer`，不能用 `Expanded(child: 搜索框)`** ✗
            //
            // 实测（量胶囊本体，不是外层 Align）：
            //   · `Expanded` 包裹 → 组件内部那个 `Align(centerLeft)` 生效，
            //     胶囊被推到可用区**左缘**，与右侧图标之间空 **46.8px** ✗
            //     （这正是用户报"搜索框不靠右"的成因）
            //   · `Spacer` → 组件只占内容宽（`maxWidth`），内部 `Align`
            //     没有可推空间 ⇒ 胶囊自然贴到右侧 ✓ 间距 = 下面那个 12px ✓
            const Spacer(),
            JellyExpandableSearch(
              controller: _searchCtrl,
              hintText: '搜索书源',
              // 用户 2026-10-07：宽度改成原来的三分之二（210 → 140）
              maxWidth: 140,
              height: 32,
              // ⚠️ 组件**没有** `autofocus` 参数（那是 `JellySearchBar` 的能力）——
              //    本页是"标题行内常驻胶囊"，也不该自动弹键盘（会盖住列表）。
              onChanged: (v) => setState(() => _keyword = v.trim()),
              onSubmitted: (v) => setState(() => _keyword = v.trim()),
            ),
            // 与右侧 `actions` 的图标留出间距（用户：**不要贴那么近**）
            const SizedBox(width: 12),
          ],
        ],
      ),
      actions: [
        // ✅ **qread 服务端连接**（壳模式）—— 书源规则执行挪到自建服务端：
        //   · 未连接：普通云图标，点击打开服务端设置
        //   · 已连接：云图标高亮 + 右上角小圆点（表示服务端同步模式已生效）
        IconButton(
          tooltip: QreadServerConfig.instance.isLoggedIn
              ? 'qread 服务端已连接'
              : 'qread 服务端设置',
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(
                Icons.cloud_outlined,
                size: 20,
                color: QreadServerConfig.instance.isLoggedIn
                    ? Colors.lightBlueAccent
                    : _titleColor,
              ),
              if (QreadServerConfig.instance.isLoggedIn)
                const Positioned(
                  right: -2,
                  top: -2,
                  child: Icon(Icons.circle,
                      size: 7, color: Colors.lightGreenAccent),
                ),
            ],
          ),
          onPressed: _showServerDialog,
        ),
        // ✅ **滑动动作栏**（③ 的正确形式 ✓）—— 与漫画页 `search_page.dart:1371` **同款** ✓✓：
        //   `JellySlidingActions` = **左右一个个滑动切换** ✓ + **下滑展开成一列** ✓
        //   （就是我先前误做成"顶栏指环"✗的那个东西 ✓；指环已撤 ✓，这里换成正确的 ✓）
        //   动作与漫画页对齐 ✓：只保留**书源体检** ✓（浏览记录/收藏入口已按要求移除 ✓）
        JellySlidingActions(
          isDark: _isDark,
          actions: [
            JellyAction(
              icon: Icons.verified_user_rounded,
              tooltip: '书源体检',
              // ⚠️ **`JellyAction.onPressed` 是非空 `VoidCallback`** ✓（`jelly_sliding_actions.dart:405` ✓），
              //   不能传 `? null : …` ✗（我原来那样写 ✗ → `void Function()? can't be assigned` ✗）。
              //   ⇒ 改成"进来先判条件、不满足就 return" ✓✓ —— 语义与原意一致 ✓（空库/体检中不响应 ✓），
              //     而且这样 `_runHealthCheck` **重新有了调用者** ✓✓（消掉它"未被引用"的 warning ✓）。
              onPressed: () {
                if (store.isEmpty || _healthChecking) return;
                _runHealthCheck();
              },
            ),
          ],
        ),
        // 分享（截图右上第一个）：导出全部书源 JSON
        IconButton(
          tooltip: '分享书源',
          icon: Icon(Icons.ios_share_rounded, size: 20, color: _titleColor),
          onPressed: store.isEmpty ? null : _shareAll,
        ),
        // ✅ 用户 2026-10-07：「去掉一个重复的检测按钮」——
        //   这里原来还有**第二个**「书源体检」按钮（同一个 `verified_user_rounded`
        //   图标 + 同一个 `_runHealthCheck`），和上面 `JellySlidingActions` 里那个
        //   完全重复 ⇒ **已移除** ✓，只保留滑动作栏里的那一个 ✓
        // 搜索 + 多选放在体检之后（截图里没有，但少了不好用）
        IconButton(
          tooltip: _searching ? '关闭搜索' : '搜索书源',
          icon: Icon(
            _searching ? Icons.close_rounded : Icons.search_rounded,
            size: 20,
          ),
          onPressed: () => setState(() {
            _searching = !_searching;
            if (!_searching) {
              _searchCtrl.clear();
              _keyword = '';
            }
          }),
        ),
        if (!store.isEmpty)
          IconButton(
            tooltip: _selectMode ? '退出多选' : '多选',
            icon: Icon(
                _selectMode ? Icons.done_rounded : Icons.checklist_rounded,
                size: 20),
            onPressed: () => setState(() {
              _selectMode = !_selectMode;
              _selected.clear();
            }),
          ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// 分享全部书源：复制 JSON 到剪贴板（并提示可粘贴给他人）
  Future<void> _shareAll() async {
    final json =
        BookSourceService.instance.exportSources(store.sorted());
    await Clipboard.setData(ClipboardData(text: json));
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('已复制书源', style: TextStyle(fontSize: AppTheme.fontHeadline)),
        content: Text(
          '${store.all.length} 个书源的 JSON 已复制到剪贴板，'
          '可直接粘贴分享给别人。\n\n'
          '对方用「口令导入」粘贴即可导入。',
          style: const TextStyle(fontSize: AppTheme.fontSubhead, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 从顶部地址栏导入
  Future<void> _importByUrlFromField() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      _toast('请先填写书源地址');
      return;
    }
    await _fetchAndImport(url);
  }


  Widget _selectBar(List<BookSource> list) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Row(
        children: [
          TextButton(
            onPressed: () => setState(() {
              if (_selected.length == list.length) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(list.map((e) => e.id));
              }
            }),
            child: Text(_selected.length == list.length ? '取消全选' : '全选'),
          ),
          const Spacer(),
          TextButton(
            onPressed: () {
              for (final id in _selected.toList()) {
                store.setEnabled(id, true);
              }
              _toast('已启用 ${_selected.length} 个');
            },
            child: const Text('启用'),
          ),
          TextButton(
            onPressed: () {
              for (final id in _selected.toList()) {
                store.setEnabled(id, false);
              }
              _toast('已停用 ${_selected.length} 个');
            },
            child: const Text('停用'),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 空态（照截图：还没有书源 / 用地址、口令或本地文件导入书源 / 去导入书源）
  // ============================================================

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_outlined,
                  size: 48,
                  color: JellyTheme.textSecondary.withValues(alpha: 0.55)),
              const SizedBox(height: 20),
              Text('还没有书源',
                  style: TextStyle(
                      fontSize: AppTheme.fontTitle3,
                      fontWeight: FontWeight.w600,
                      color: _titleColor)),
              const SizedBox(height: 8),
              Text('用上面的地址、口令或本地文件导入',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: AppTheme.fontSubhead, color: JellyTheme.textSecondary)),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: _busy ? null : _showImportSheet,
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('去导入书源'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _noMatchState() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded,
                size: 42,
                color: JellyTheme.textSecondary.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text('没有匹配「$_keyword」的书源',
                style: TextStyle(fontSize: AppTheme.fontSubhead, color: JellyTheme.textSecondary)),
          ],
        ),
      );

  // ============================================================
  // 列表
  // ============================================================

  /// 主列表（按截图）：
  ///   共 N 个 + 清空  →  筛选输入框  →  分组 chip 行  →  书源卡片
  Widget _sourceList(List<BookSource> all) {
    // 1) 按"隐藏组"和"选中分组"过滤
    var list = all
        .where((s) => !_hiddenGroups.contains(s.group))
        .toList();
    if (_pickedGroup != null) {
      list = list.where((s) => s.group == _pickedGroup).toList();
    }
    // 🔴 「筛选已导入的书源」输入框**一直是死的** ✗：它的 `onChanged` 确实在写
    // `_filter`（见本文件 :571-605 的输入框 ✓），但**这里从来没读过它** ✓
    // → 用户输入关键词后列表**纹丝不动** ✗（这是本页最常用的控件之一 ✓）。
    // 按 名称 / 地址 / 分组 做不区分大小写的包含匹配 ✓
    final kw = _filter.trim().toLowerCase();
    if (kw.isNotEmpty) {
      list = list
          .where((s) =>
              s.name.toLowerCase().contains(kw) ||
              s.url.toLowerCase().contains(kw) ||
              s.group.toLowerCase().contains(kw))
          .toList();
    }
    // 2) 分组统计（用过滤后的全集算，chip 上的数字才对）
    final base = all.where((s) => !_hiddenGroups.contains(s.group)).toList();
    final counts = <String, int>{};
    for (final s in base) {
      counts[s.group] = (counts[s.group] ?? 0) + 1;
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      children: [
        // ── 共 N 个 + 清空 ────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 0, 6),
          child: Row(
            children: [
              Text('共 ${base.length} 个',
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead, color: JellyTheme.textSecondary)),
              const Spacer(),
              TextButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('清空书源'),
                      content: Text('将删除全部 ${base.length} 个书源，不可恢复。'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('取消')),
                        TextButton(
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('清空',
                                style: TextStyle(color: Colors.redAccent))),
                      ],
                    ),
                  );
                  if (ok == true) {
                    // removeAll() 无参（清空全部）；这里要删的是
                    // "未被隐藏的组"里的源，所以逐个 remove
                    for (final s in base) {
                      await store.remove(s.id);
                    }
                  }
                },
                child: const Text('清空', style: TextStyle(fontSize: AppTheme.fontSubhead)),
              ),
            ],
          ),
        ),
        // ── 筛选已导入的书源 ──────────────────────────────────
        // ✅ 统一到 `JellySearchBar` ✓ —— 这是**全宽**场景 ✓（注意与同页标题行那个
        //   210 宽的**小胶囊**不同 ✗：那个用 `JellyExpandableSearch` ✓；
        //   判据就是"**有没有固定宽度**" ✓：有 → Expandable ✓；无（Column 内）→ Bar ✓）。
        //   原为手写：`Container(高40 / 圆角20 / 卡片色)` + 手画 `prefixIcon` 放大镜 +
        //   自己实现的 `suffixIcon` 清空键 ✓。
        // ⚠️ 必须**整段替换** ✓：组件自带底色 / 圆角 / 放大镜 / 清空键 ✓，
        //   留下外层 `Container(decoration: …)` 就会"圆角方框套胶囊" ✗。
        // 参数对照 ✓：controller `_filterCtrl` ✓ · hintText 同文案 ✓ ·
        //   ⚠️ `onChanged` 里的 **`.trim().toLowerCase()` 必须原样保留** ✓
        //   （该页的过滤是**大小写不敏感**的 ✓，漏掉就退化成大小写敏感 ✗）·
        //   onCleared：保留 `_filterCtrl.clear()` ✓（我不假设组件内部是否清 controller ✗，
        //   多清一次无害 ✓）+ 置空 ✓
        JellySearchBar(
          controller: _filterCtrl,
          hintText: '筛选已导入的书源',
          onChanged: (v) => setState(() => _filter = v.trim().toLowerCase()),
          onCleared: () {
            _filterCtrl.clear();
            setState(() => _filter = '');
          },
        ),
        // ── 分组 chip 行 ──────────────────────────────────────
        //
        // 截图：最左是「排序/分组设置」圆钮 + 「＋」新建分组，
        // 接着是「∞ 全部 N」「未分组 N」「通常书源 N」…
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _groupActionBtn(Icons.tune_rounded, '分组设置', _showManageGroups),
                const SizedBox(width: 8),
                _groupActionBtn(Icons.add_box_outlined, '新建分组', _showNewGroup),
                const SizedBox(width: 8),
                _groupChip('全部', base.length, _pickedGroup == null,
                    () => setState(() => _pickedGroup = null)),
                for (final e in counts.entries) ...[
                  const SizedBox(width: 8),
                  _groupChip(e.key, e.value, _pickedGroup == e.key,
                      () => setState(() => _pickedGroup = e.key)),
                ],
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        // ── 书源卡片 ──────────────────────────────────────────
        for (final s in list) _sourceTile(s),
      ],
    );
  }

  /// 分组 chip 行左侧的小圆钮（分组设置 / 新建分组）
  Widget _groupActionBtn(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: Material(
        color: _isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.04),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(icon, size: 18, color: JellyTheme.textSecondary),
          ),
        ),
      ),
    );
  }

  /// 一个分组 chip（选中=深色实底白字，未选=浅底灰字）
  Widget _groupChip(String label, int count, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on
              ? (_isDark ? Colors.white : JellyTheme.primary)
              : (_isDark
                  ? Colors.white.withValues(alpha: 0.07)
                  : Colors.black.withValues(alpha: 0.04)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 「全部」前面有个 ∞ 标记（截图如此）
            if (label == '全部') ...[
              Icon(Icons.all_inclusive_rounded,
                  size: 14,
                  color: on
                      ? (_isDark ? JellyTheme.backgroundDark : Colors.white)
                      : JellyTheme.textSecondary),
              const SizedBox(width: 4),
            ],
            Text(
              '$label $count',
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                fontWeight: on ? FontWeight.w600 : FontWeight.normal,
                color: on
                    ? (_isDark ? JellyTheme.backgroundDark : Colors.white)
                    : JellyTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「新建分组」对话框（截图：标题 + 输入框 + 取消/确定）
  Future<void> _showNewGroup() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text('新建分组',
            style: TextStyle(fontSize: AppTheme.fontTitle3, color: _titleColor)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '输入分组名称',
            filled: true,
            fillColor: _isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.04),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(c, ctrl.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    // 新建分组本身不产生书源 —— 它只是个"待用"的分组名。
    // 这里把它落成一个空分组的可见占位：取消隐藏它并选中，
    // 用户随后可以给书源改分组（截图里的「设置分组」）。
    setState(() {
      _hiddenGroups.remove(name);
      _pickedGroup = name;
    });
    _toast('已创建分组「$name」，可在书源上点「设置分组」归入');
  }

  /// 「管理分组」弹层（截图：管理分组 + 设置/新建/批量删除 + 拖动/眼睛）
  Future<void> _showManageGroups() async {
    final all = store.sorted();
    final names = <String>{for (final s in all) s.group}.toList();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          decoration: BoxDecoration(
            color: _card,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 6),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: JellyTheme.textSecondary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 8, 6),
                  child: Row(
                    children: [
                      Text('管理分组',
                          style: TextStyle(
                              fontSize: AppTheme.fontTitle3,
                              fontWeight: FontWeight.w700,
                              color: _titleColor)),
                      const Spacer(),
                      IconButton(
                        tooltip: '新建分组',
                        onPressed: () {
                          Navigator.pop(ctx);
                          _showNewGroup();
                        },
                        icon: Icon(Icons.create_new_folder_outlined,
                            size: 21, color: _titleColor),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: names.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(40),
                          child: Text('还没有分组',
                              style: TextStyle(
                                  fontSize: AppTheme.fontSubhead,
                                  color: JellyTheme.textSecondary)),
                        )
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            for (final g in names)
                              ListTile(
                                leading: Icon(Icons.drag_handle_rounded,
                                    size: 20,
                                    color: JellyTheme.textSecondary),
                                title: Text(
                                  g,
                                  style: TextStyle(
                                      fontSize: AppTheme.fontHeadline, color: _titleColor),
                                ),
                                subtitle: Text(
                                  '${all.where((s) => s.group == g).length} 个源',
                                  style: TextStyle(
                                      fontSize: AppTheme.fontFootnote,
                                      color: JellyTheme.textSecondary),
                                ),
                                // 眼睛 = 该组是否显示在列表里
                                trailing: IconButton(
                                  tooltip: _hiddenGroups.contains(g)
                                      ? '当前隐藏，点击显示'
                                      : '当前显示，点击隐藏',
                                  onPressed: () => setSheet(() {
                                    setState(() {
                                      if (!_hiddenGroups.remove(g)) {
                                        _hiddenGroups.add(g);
                                      }
                                    });
                                  }),
                                  icon: Icon(
                                    _hiddenGroups.contains(g)
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                    size: 20,
                                    color: JellyTheme.textSecondary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 一个书源卡片（按截图）：
  ///   [复选框] [首字头像] 名称 / 分组   ......  [启用开关]
  ///
  /// 与旧版的区别：
  ///   · 左侧由"书本图标"改为**名称首字头像**（截图如此，一眼能认出是哪个源）
  ///   · subtitle 由"URL / 分组"改为**只看分组**（URL 在详情页里看）
  ///   · 非选择模式下也显示**复选框**（截图里常驻），点它进选择模式
  Widget _sourceTile(BookSource s) {
    final sel = _selected.contains(s.id);
    // 首字头像：取名称第一个字符（中文取一字，英文取首字母大写）
    final initial = s.name.isEmpty
        ? '?'
        : s.name.characters.first.toUpperCase();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: sel ? Border.all(color: JellyTheme.primary, width: 1.2) : null,
      ),
      child: Row(
        children: [
          // 复选框（常驻）
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: GestureDetector(
              onTap: () => setState(() {
                if (sel) {
                  _selected.remove(s.id);
                } else {
                  _selected.add(s.id);
                  // 勾选即进入选择模式（顶栏出现"选中 N"）
                  _selectMode = true;
                }
                if (_selected.isEmpty) _selectMode = false;
              }),
              child: Icon(
                sel ? Icons.check_box : Icons.check_box_outline_blank,
                size: 22,
                color: sel ? JellyTheme.primary : JellyTheme.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: ListTile(
              contentPadding: const EdgeInsets.fromLTRB(8, 2, 6, 2),
              leading: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: JellyTheme.primary.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  initial,
                  style: TextStyle(
                    fontSize: AppTheme.fontTitle3,
                    fontWeight: FontWeight.w700,
                    color: s.enabled
                        ? (_isDark ? Colors.white : JellyTheme.textPrimaryLight)
                        : JellyTheme.textSecondary,
                  ),
                ),
              ),
              title: Text(
                s.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600,
                  color: s.enabled ? _titleColor : JellyTheme.textSecondary,
                ),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    s.group.isEmpty ? '未分组' : s.group,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: AppTheme.fontFootnote, color: JellyTheme.textSecondary),
                  ),
                  if (_health[s.id] != null) _healthBadge(_health[s.id]!),
                ],
              ),
              onTap: _selectMode
                  ? () => setState(() {
                        if (sel) {
                          _selected.remove(s.id);
                        } else {
                          _selected.add(s.id);
                        }
                        if (_selected.isEmpty) _selectMode = false;
                      })
                  : () => _showSourceMenu(s),
              onLongPress: () => _showSourceMenu(s),
              trailing: Switch(
                value: s.enabled,
                activeThumbColor: JellyTheme.primary,
                onChanged: (v) => store.setEnabled(s.id, v),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 点书源卡片弹出的底部菜单（按截图）：
  ///   顶部：源名 + 分组名 + ✏编辑 / ⬆置顶 / 🗑删除
  ///   列表：设置分组
  Future<void> _showSourceMenu(BookSource s) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 10),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: JellyTheme.textSecondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              // 标题行：源名/分组 + 三个圆钮
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 16, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(s.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: AppTheme.fontTitle3,
                                  fontWeight: FontWeight.w700,
                                  color: _titleColor)),
                          const SizedBox(height: 3),
                          Text(s.group.isEmpty ? '未分组' : s.group,
                              style: TextStyle(
                                  fontSize: AppTheme.fontSubhead,
                                  color: JellyTheme.textSecondary)),
                        ],
                      ),
                    ),
                    _groupActionBtn(Icons.edit_outlined, '编辑',
                        () async {
                      Navigator.pop(ctx);
                      // 🔴 config 型源**不能**走 Legado 的 7-tab 编辑页 ✗：
                      // 那个表单是给 Legado 书源写的（读 `bookSourceName/Url/rule*`
                      // 等顶层键 ✓），而 config 源的数据在 **`config` 体内** ✗ →
                      // 打开后**表单全空** ✓（用户会以为源坏了 ✓）。
                      // 更糟的是保存：`_save` 会把 62 个字段全部写进 raw ✓ →
                      // ① **污染 JSON**（凭空多出 5 个空 `ruleSearch/ruleExplore/
                      //    ruleBookInfo/ruleToc/ruleContent` 对象 ✗）
                      // ② 重算 id（`config:正式名` → 用户填的名字 ✓）→ **id 漂移** ✗，
                      //    连带按 id 存的键（`bsr.progress.<id>.<书名>`、笔记 sourceId）
                      //    全部失配 ✓（重启后又变回 `config:原名` ✓）。
                      // 所以这里**直接拦住** ✓，比"打开一个会写坏数据的表单"好 ✓；
                      // 真想改 config 源应走它自己的配置编辑页 ✓（待做 ✓）
                      if (s.isConfig) {
                        _toast('这是 config 型源：请用它的配置编辑方式修改，'
                            '此编辑页会写坏它的 JSON');
                        return;
                      }
                      // 打开 7-tab 完整编辑页（源变量/基础/搜索/发现/详情/目录/正文）
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => BookSourceEditorPage(source: s),
                        ),
                      );
                      if (mounted) setState(() {});
                      // 壳模式：编辑完成后把最新规则同步到服务端
                      if (QreadServerConfig.instance.isLoggedIn) {
                        final updated = store.byId(s.id);
                        if (updated != null) {
                          try {
                            await QreadApi.instance
                                .editSource(updated.id, jsonEncode(updated.raw));
                            if (mounted) _toast('已同步到服务端');
                          } on QreadException catch (e) {
                            if (mounted) {
                              _toast('本地已保存，服务端同步失败：${e.message}');
                            }
                          } catch (e) {
                            if (mounted) _toast('本地已保存，服务端同步失败：$e');
                          }
                        }
                      }
                    }),
                    const SizedBox(width: 8),
                    _groupActionBtn(Icons.vertical_align_top_rounded, '置顶',
                        () {
                      Navigator.pop(ctx);
                      // 置顶 = 把它排到最前（store 有 order 字段）
                      store.reorder([s.id]);
                      // 壳模式：同步置顶到服务端
                      if (QreadServerConfig.instance.isLoggedIn) {
                        QreadApi.instance.topSources([s.id]).catchError((Object e) {
                          if (mounted) _toast('服务端置顶失败：$e');
                          return false;
                        });
                      }
                    }),
                    const SizedBox(width: 8),
                    // ⚠️ 这个「登录」圆钮必须有：BookSourceLoginPage 原来的
                    // 唯一入口是被我删掉的 _showDetail。删了它登录页就成了
                    // 孤儿页面（代码在但用户进不去）——等于弄丢功能。
                    // 截图里圆钮位置只画了 3 个，但登录是必需功能，
                    // 多一个不影响主流程。
                    _groupActionBtn(
                        Icons.login_rounded,
                        '登录',
                        () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => BookSourceLoginPage(source: s),
                          ),
                        )),
                    const SizedBox(width: 8),
                    _groupActionBtn(
                        Icons.delete_outline_rounded, '删除', () async {
                      Navigator.pop(ctx);
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('删除书源'),
                          content: Text('删除「${s.name}」？不可恢复。'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(c, false),
                                child: const Text('取消')),
                            TextButton(
                                onPressed: () => Navigator.pop(c, true),
                                child: const Text('删除',
                                    style:
                                        TextStyle(color: Colors.redAccent))),
                          ],
                        ),
                      );
                      if (ok == true) {
                        await store.remove(s.id);
                        // 壳模式：同步删除到服务端
                        if (QreadServerConfig.instance.isLoggedIn) {
                          try {
                            await QreadApi.instance.deleteSource(s.id);
                            if (mounted) _toast('已同步删除服务端书源');
                          } on QreadException catch (e) {
                            if (mounted) {
                              _toast('本地已删除，服务端删除失败：${e.message}');
                            }
                          } catch (e) {
                            if (mounted) _toast('本地已删除，服务端删除失败：$e');
                          }
                        }
                      }
                    }),
                  ],
                ),
              ),
              const Divider(height: 1),
              // 设置分组
              ListTile(
                leading:
                    Icon(Icons.folder_outlined, size: 22, color: _titleColor),
                title: Text('设置分组',
                    style: TextStyle(fontSize: AppTheme.fontHeadline, color: _titleColor)),
                subtitle: Text(s.group.isEmpty ? '未分组' : s.group,
                    style: TextStyle(
                        fontSize: AppTheme.fontSubhead, color: JellyTheme.textSecondary)),
                trailing: Icon(Icons.chevron_right_rounded,
                    size: 20, color: JellyTheme.textSecondary),
                onTap: () {
                  Navigator.pop(ctx);
                  _showPickGroup(s);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// 「设置分组」：给单个书源选一个已有分组，或新建
  Future<void> _showPickGroup(BookSource s) async {
    final names = <String>{for (final x in store.sorted()) x.group}.toList();
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 14),
              Text('设置分组',
                  style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w700,
                      color: _titleColor)),
              const SizedBox(height: 8),
              for (final g in names)
                ListTile(
                  title: Text(g,
                      style: TextStyle(fontSize: AppTheme.fontHeadline, color: _titleColor)),
                  trailing: s.group == g
                      ? Icon(Icons.check_rounded,
                          size: 20, color: JellyTheme.primary)
                      : null,
                  onTap: () => Navigator.pop(ctx, g),
                ),
              ListTile(
                leading: Icon(Icons.add_rounded,
                    size: 20, color: JellyTheme.textSecondary),
                title: Text('新建分组…',
                    style: TextStyle(
                        fontSize: AppTheme.fontHeadline, color: JellyTheme.textSecondary)),
                onTap: () => Navigator.pop(ctx, '__new__'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    var target = picked;
    if (picked == '__new__') {
      final ctrl = TextEditingController();
      final name = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('新建分组'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: '输入分组名称'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c), child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(c, ctrl.text.trim()),
                child: const Text('确定')),
          ],
        ),
      );
      if (name == null || name.isEmpty) return;
      target = name;
    }
    await store.setGroup(s.id, target);
    _toast('已归入「$target」');
    // 壳模式：同步分组到服务端（editsourcegroup 批量改分组）
    if (QreadServerConfig.instance.isLoggedIn) {
      try {
        await QreadApi.instance.setGroup(target, ids: [s.id]);
      } on QreadException catch (e) {
        if (mounted) _toast('本地已改分组，服务端同步失败：${e.message}');
      } catch (e) {
        if (mounted) _toast('本地已改分组，服务端同步失败：$e');
      }
    }
  }

  // ============================================================

  Future<void> _showImportSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: JellyTheme.textSecondary.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(height: 16),
              Text('导入书源',
                  style: TextStyle(
                      fontSize: AppTheme.fontTitle3,
                      fontWeight: FontWeight.w600,
                      color: _titleColor)),
              const SizedBox(height: 6),
              Text('用地址、口令或本地文件导入书源',
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead, color: JellyTheme.textSecondary)),
              const SizedBox(height: 18),
              _importOption(
                icon: Icons.link_rounded,
                title: '地址导入',
                subtitle: '填书源列表网址，自动拉取',
                onTap: () {
                  Navigator.pop(ctx);
                  _importByUrl();
                },
              ),
              _importOption(
                icon: Icons.key_rounded,
                title: '口令导入',
                subtitle: '粘贴分享口令或书源 JSON',
                onTap: () {
                  Navigator.pop(ctx);
                  _importByCode();
                },
              ),
              _importOption(
                icon: Icons.folder_open_rounded,
                title: '本地文件导入',
                subtitle: '选择 .json / .txt 书源文件',
                onTap: () {
                  Navigator.pop(ctx);
                  _importByFile();
                },
              ),
              const SizedBox(height: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _importOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) =>
      ListTile(
        onTap: onTap,
        leading: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: JellyTheme.primary.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: JellyTheme.primary),
        ),
        title: Text(title,
            style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
                color: _titleColor)),
        subtitle: Text(subtitle,
            style: TextStyle(fontSize: AppTheme.fontFootnote, color: JellyTheme.textSecondary)),
        trailing: Icon(Icons.chevron_right_rounded,
            color: JellyTheme.textSecondary),
      );

  /// 地址导入
  Future<void> _importByUrl() async {
    final ctrl = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('地址导入',
                    style: TextStyle(
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600,
                        color: _titleColor)),
                const SizedBox(height: 4),
                Text('支持 http(s) 链接；返回内容为书源 JSON',
                    style: TextStyle(
                        fontSize: AppTheme.fontFootnote, color: JellyTheme.textSecondary)),
                const SizedBox(height: 10),
                TextField(
                  controller: ctrl,
                  style: const TextStyle(fontSize: AppTheme.fontSubhead),
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    hintText: 'https://example.com/booksource.json',
                    hintStyle: TextStyle(
                        fontSize: AppTheme.fontSubhead, color: JellyTheme.textSecondary),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  child: FilledButton(
                    onPressed: () async {
                      final url = ctrl.text.trim();
                      if (url.isEmpty) {
                        _toast('请先填写网址');
                        return;
                      }
                      Navigator.pop(ctx);
                      await _fetchAndImport(url);
                    },
                    child: const Text('拉取并导入'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    ctrl.dispose();
  }

  /// 口令导入（粘贴）
  Future<void> _importByCode() async {
    final ctrl = TextEditingController();
    var error = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          top: false,
          child: Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('口令导入',
                      style: TextStyle(
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w600,
                          color: _titleColor)),
                  const SizedBox(height: 4),
                  Text('粘贴分享口令或书源 JSON（单个 / 数组 / {"sources":[…]} 都行）',
                      style: TextStyle(
                          fontSize: AppTheme.fontFootnote, color: JellyTheme.textSecondary)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: ctrl,
                    maxLines: 7,
                    minLines: 4,
                    style: const TextStyle(fontSize: AppTheme.fontSubhead),
                    decoration: InputDecoration(
                      hintText: '在此粘贴…',
                      hintStyle: TextStyle(
                          fontSize: AppTheme.fontSubhead, color: JellyTheme.textSecondary),
                      filled: true,
                      fillColor: _isDark
                          ? Colors.white.withValues(alpha: 0.05)
                          : Colors.black.withValues(alpha: 0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  if (error.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(error,
                        style: const TextStyle(
                            fontSize: AppTheme.fontFootnote, color: Colors.redAccent)),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          final d = await Clipboard.getData('text/plain');
                          final t = d?.text;
                          if (t != null && t.isNotEmpty) {
                            ctrl.text = t;
                            setSheet(() => error = '');
                          }
                        },
                        icon:
                            const Icon(Icons.content_paste_rounded, size: 17),
                        label: const Text('读剪贴板'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () async {
                          final text = ctrl.text.trim();
                          if (text.isEmpty) {
                            setSheet(() => error = '请先粘贴内容');
                            return;
                          }
                          final parsed = _parseSources(text);
                          if (parsed.isEmpty) {
                            setSheet(() => error =
                                '没解析出书源。Legado 书源需含 bookSourceName / bookSourceUrl');
                            return;
                          }
                          final r = await store.addAll(parsed);
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          _toast(r.added > 0
                              ? '已导入 ${r.added} 个书源'
                              : '已更新 ${r.updated} 个书源');
                        },
                        child: const Text('导入'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    ctrl.dispose();
  }

  /// 从字节导入：自动识别 zip 还是文本。
  ///
  /// 为什么要判 zip：**书源分发最常见的形态就是一个 zip**
  /// （截图里地址栏也写着 `json / zip`）。不认 zip 的话，
  /// 用户下载到的书源包导进来只会得到"JSON 解析失败"，
  /// 而且完全看不出原因是"这是个压缩包"。
  Future<void> _importBytes(Uint8List bytes) async {
    // zip 魔数 PK\x03\x04（空 zip 是 PK\x05\x06，跨卷是 PK\x07\x08）
    final isZip = bytes.length > 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07);

    if (!isZip) {
      final text = utf8.decode(bytes, allowMalformed: true);
      await _doImportText(text);
      return;
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      _toast('压缩包解析失败：$e');
      return;
    }

    // 把包里所有 .json/.txt 都当书源试一遍。
    // 不假设"只有一个文件" —— 书源包常按站点分组放多个 json。
    var totalAdded = 0;
    var totalUpdated = 0;
    var tried = 0;
    var failed = 0;

    for (final f in archive) {
      if (!f.isFile) continue;
      final lower = f.name.toLowerCase();
      if (!lower.endsWith('.json') && !lower.endsWith('.txt')) continue;
      tried++;
      try {
        final data = f.content;
        final fb = data is Uint8List
            ? data
            : Uint8List.fromList(List<int>.from(data as List));
        final text = utf8.decode(fb, allowMalformed: true);
        final parsed = _parseSources(text);
        if (parsed.isEmpty) continue;
        final r = await store.addAll(parsed);
        totalAdded += r.added;
        totalUpdated += r.updated;
      } catch (_) {
        failed++;
      }
    }

    if (tried == 0) {
      _toast('压缩包里没有 json / txt 书源文件');
      return;
    }
    if (totalAdded == 0 && totalUpdated == 0) {
      _toast('压缩包里的 $tried 个文件都没解析出书源');
      return;
    }
    _toast(
      '已从压缩包导入：新增 $totalAdded 个'
      '${totalUpdated > 0 ? '、更新 $totalUpdated 个' : ''}'
      '${failed > 0 ? '（$failed 个文件解析失败）' : ''}',
    );
  }

  /// 本地文件导入。
  ///
  /// ⚠️ file_picker 13.x 的 API 与旧版差别很大，这里踩过坑，写清楚：
  ///   · `FilePicker.pickFiles(...)` 是**静态**方法（旧版是 `FilePicker.platform.pickFiles`）
  ///   · 返回值是 **`List<PlatformFile>`**（旧版是 `FilePickerResult?`）
  ///   · 没有 `withData` 参数；`PlatformFile` 也没有 `bytes` 属性
  ///   · 读内容用 **`f.readAsBytes()`**（返回 `Future<Uint8List>`），
  ///     或经 `f.path` 自己读文件
  Future<void> _importByFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt', 'zip'],
      );
      if (result.isEmpty) return;
      final f = result.first;

      Uint8List bytes;
      try {
        // 首选 readAsBytes：不依赖 path（某些平台 path 可能为 null）
        bytes = await f.readAsBytes();
      } catch (_) {
        // 退回按路径读
        final path = f.path;
        if (path == null) {
          _toast('读不出这个文件（没有本地路径）');
          return;
        }
        bytes = await File(path).readAsBytes();
      }

      if (bytes.isEmpty) {
        _toast('文件是空的');
        return;
      }
      await _importBytes(bytes);
    } catch (e) {
      _toast('导入失败：${e.toString().split('\n').first}');
    }
  }

  Future<void> _fetchAndImport(String url) async {
    setState(() => _busy = true);
    try {
      // 用 bytes 而不是 String：书源地址可能是 zip，
      // 当字符串解出来会是乱码，根本判不出问题在哪
      // ✅ **书源包下载也走「网络代理」**（本轮接上 ✓）—— 原来这里是**内联新建** ✗
      //   （`await Dio().get(...)` ✓ 一行里建完就用 ✓），没法"先构造再挂" ✓
      //   ⇒ 所以**拆成两行** ✓：先建 `proxyDio` ✓ → 挂代理 ✓ → 再用它请求 ✓✓。
      //   ℹ️ 安全依据 ✓：本处**无自定义适配器 / 无自定义 UA** ✗✓（就在下面几行 ✓）
      //     ⇒ 挂代理不会影响任何东西 ✓；而且本页**已有**浏览器 UA 的补丁 ✓（`:1707-1720` ✓）
      //       那是在 `Options(headers:)` 里 ✓（**Dio 选项层** ✓）→ 与 socket 层适配器**互不干扰** ✓✓（不会丢 ✓）。
      //   · 代理**关闭** ✓ → 返回 false ✓ **一行不改** ✓（与从前完全一致 ✓✓）
      final proxyDio = Dio();
      applyGlobalProxy(proxyDio);
      final res = await proxyDio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          // ✅ **补浏览器 UA**（本轮新增 ✓）—— 兼容 `yckceo.com/yuedu/shuyuan/json/id/N.json` 这类地址 ✓。
          //   为什么需要 ✗：此前没有任何 headers ✓ → 用的是 **Dio 默认 UA（`Dart/xxx`）** ✗，
          //   而不少书源分发站 / CDN 会因此**直接返回 403 / 空体** ✗✓
          //   —— 本仓对同一问题早有记录 ✓：`download_service:178`「默认 Dart/xxx 会被 c-nd3 等 CDN 拦 403
          //   （同 `app_image_cache.dart` 的 **UA 拦截器修复**）」✓✓，这里属于**同一类修复** ✓。
          //   ℹ️ 用**移动 Safari** 的 UA ✓（与 App 场景一致 ✓）；这只是**请求头** ✓，
          //     不改变任何解析逻辑 ✓（`_parseSources` 的 4 种形态兼容保持不变 ✓）。
          headers: const {
            'User-Agent':
                'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
                    'Mobile/15E148 Safari/604.1',
            'Accept': 'application/json,text/plain,*/*',
          },
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final list = res.data;
      if (list == null || list.isEmpty) {
        _toast('网址返回内容为空');
        return;
      }
      await _importBytes(Uint8List.fromList(list));
    } catch (e) {
      _toast('拉取失败：${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doImportText(String text) async {
    final parsed = _parseSources(text);
    if (parsed.isEmpty) {
      _toast('没解析出书源。Legado 书源需含 bookSourceName / bookSourceUrl');
      return;
    }
    final r = await store.addAll(parsed);
    _toast(r.added > 0 && r.updated > 0
        ? '新增 ${r.added} 个、更新 ${r.updated} 个书源'
        : (r.added > 0 ? '已导入 ${r.added} 个书源' : '已更新 ${r.updated} 个书源'));
    // 壳模式：已连接服务端时把完整规则同步过去（服务端为权威书源库）
    await _pushImportToServer(parsed);
  }

  /// 解析书源 JSON。兼容 4 种形态 + 带尾随逗号的脏 JSON。
  List<BookSource> _parseSources(String text) {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      // 有些分发文件带尾随逗号 / 前后有说明文字，退回"截取首尾括号"再试
      final a = text.indexOf('[');
      final b = text.lastIndexOf(']');
      final c = text.indexOf('{');
      final d = text.lastIndexOf('}');
      String? candidate;
      if (a >= 0 && b > a) {
        candidate = text.substring(a, b + 1);
      } else if (c >= 0 && d > c) {
        candidate = text.substring(c, d + 1);
      }
      if (candidate == null) rethrow;
      decoded = jsonDecode(candidate);
    }

    final out = <BookSource>[];
    void take(dynamic e) {
      if (e is! Map) return;
      final m = e.cast<String, dynamic>();
      // Cmbok 导出包装：{seq,id,name,url,enabled,...,json:"<Legado 书源 JSON>"}
      // 书源本体在 json 字段（字符串），顶层没有 bookSourceName/bookSourceUrl ——
      // 必须先解包再走 BookSource.fromJson，否则整包判"没解析出书源"。
      if (m['json'] is String && !m.containsKey('bookSourceName')) {
        try {
          final inner = jsonDecode(m['json'] as String);
          if (inner is List) {
            for (final x in inner) {
              take(x);
            }
            return;
          }
          if (inner is Map) {
            take(inner);
            return;
          }
        } catch (_) {
          // 解包失败就当普通对象继续走下方分支
        }
      }
      final s = BookSource.fromJson(m);
      if (s != null) out.add(s);
    }

    if (decoded is List) {
      for (final e in decoded) {
        take(e);
      }
    } else if (decoded is Map) {
      final m = decoded.cast<String, dynamic>();
      if (m['sources'] is List) {
        for (final e in (m['sources'] as List)) {
          take(e);
        }
      } else {
        take(m);
      }
    }
    return out;
  }

  // ============================================================
  // 详情 / 删除
  // ============================================================

  Future<void> _runHealthCheck() async {
    final targets = _visible;
    if (targets.isEmpty) return;
    // 完整「书源体检」页：并发选择 → 逐源体检（取书→详情→目录→正文）→
    // 统计分组列表 → 一键优化 / 清理（对齐参考图 IMG_8554~8561）
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookSourceHealthPage(),
      ),
    );
  }

  /// 体检标记：小圆点 + 文字（可用/部分可用/可疑/失效）
  Widget _healthBadge(BookSourceHealth h) {
    final (color, icon) = switch (h.level) {
      BookSourceHealthLevel.healthy => (Colors.green, Icons.check_circle_rounded),
      BookSourceHealthLevel.partial => (Colors.orange, Icons.error_rounded),
      BookSourceHealthLevel.suspect => (Colors.amber, Icons.help_rounded),
      BookSourceHealthLevel.dead => (Colors.redAccent, Icons.cancel_rounded),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '${h.levelText} · ${h.detail}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: AppTheme.fontCaption, color: color),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 书源编辑（V2.0.7 的「书源编辑」）
  // ============================================================

  // ❌ 这里原来挂着一段与"编辑弹层"有关的文档注释 ✗ —— 内容是：
  //   「编辑弹层。为什么做成"常用字段表单 + 完整 JSON"两段……
  //     常用字段（名称/网址/分组）走表单，其余走 JSON，且互相同步」
  // 但它**挂错了方法** ✗：紧跟在它后面的其实是 `_deleteSelected`（批量删除 ✓），
  // 跟"编辑弹层"毫无关系 ✓ → 属**孤儿注释** ✓，已移除 ✓。
  // ⚠️ 如果本文件里确实还有那个"编辑弹层"（表单 + JSON 两段 ✓），
  //   请把上面那段说明**移到它自己头上** ✓；否则那段描述本身也是过时的 ✓。
  /// 批量删除选中的书源（含二次确认 ✓）
  Future<void> _deleteSelected() async {
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书源', style: TextStyle(fontSize: AppTheme.fontHeadline)),
        content: Text('确定删除选中的 $n 个书源？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ids = _selected.toList();
    for (final id in ids) {
      await store.remove(id);
    }
    // 壳模式：同步批量删除到服务端
    if (QreadServerConfig.instance.isLoggedIn) {
      try {
        await QreadApi.instance.deleteSources(ids);
      } on QreadException catch (e) {
        if (mounted) _toast('本地已删除，服务端删除失败：${e.message}');
      } catch (e) {
        if (mounted) _toast('本地已删除，服务端删除失败：$e');
      }
    }
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
    _toast('已删除 $n 个书源');
  }
}
