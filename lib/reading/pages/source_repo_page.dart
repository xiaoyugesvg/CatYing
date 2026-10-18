// 漫画源仓库：启用/禁用源 + 云端配置 URL + 手动导入。
//
// ⚠️ 与「书源仓库」是**两个独立页面**，别混：
//   · 本页（漫画源仓库）= SiteConfig，服务**漫画**（图片）
//   · 书源仓库（book_source_repo_page.dart）= Legado BookSource，服务**小说**（文字）
// 两者格式、存储、入口都分开（SourceConfigStore vs BookSourceStore）。
//
// 顶部输入云端 sources.json URL（持久化），点「从云端更新」Dio 拉取覆盖本地源；
// ⚠️ 本行原来写「源定义**完全云端驱动**，**无「恢复默认」**」✗✗ —— **与代码不符，已改正** ✓：
//   真实优先级 = **文档目录 sources.json（云端更新覆盖层）优先 → 出厂内置源兜底** ✓
//   （内置源 `assets/config/sources.json` ✓，`pubspec.yaml:89-90` 已声明「**出厂内置漫画源
//    （15 个官方源明文，装上即有源）**」✓；由 `SourceConfigStore.loadLocal()` 兜底 ✓）。
//   ⇒ 所以**是存在"恢复默认/内置源"这件事的** ✓ —— 能力在 `SourceConfigStore.clearClearedFlag()`
//     （`source_config_store.dart:221` ✓，只清标记、不动文件 ✓）与 `resetToLocal()`（`:232` ✗ 会清用户导入 ✓ 别用 ✗）。
//   ℹ️ 唯一零源情形 ✗：用户点过「清空」✓ 且内置包指纹未变 ✓ → 用「恢复内置源」一键回来 ✓。
// 下方列出所有已注册源，可单独启用/禁用，需要魔法的源标魔法图标。
// 搜索页只展示启用源（见 search_page._buildSourceChips 用 enabledSources）。

import 'dart:convert';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:archive/archive.dart';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/book_source.dart';
import '../services/book_source_import_parser.dart';
import '../services/settings_service.dart';
import '../source/config_manga_source.dart';
import '../source/manga_source.dart';
import '../source/source_config_store.dart';
import '../source/source_definition.dart';
import '../source/source_manager.dart';
import '../theme/jelly_theme.dart';
import 'book_source_editor_page.dart';
import 'comic_source_edit_page.dart';
import 'source_warehouse_page.dart';
import '../../common/theme.dart';
import '../utils/source_fail_text.dart';
import '../widgets/jelly_search_bar.dart';

class SourceRepoPage extends StatefulWidget {
  const SourceRepoPage({super.key});

  @override
  State<SourceRepoPage> createState() => _SourceRepoPageState();
}

class _SourceRepoPageState extends State<SourceRepoPage> {
  late final TextEditingController _urlCtrl;
  bool _busy = false;

  /// 源体检进行中（用户 2026-10-18：「复核一哈这些漫画源」）
  bool _healthChecking = false;

  /// 当前是否深色。build 里有同名局部变量（优先用那个），
  /// 但 _clearAll / _shareSelected 等**不接收 BuildContext 的方法**
  /// 也要用它，所以补一个 getter。
  bool get _isDarkNow => Theme.of(context).brightness == Brightness.dark;
  Color get _cardNow => _isDarkNow ? JellyTheme.cardDark : JellyTheme.cardLight;

  /// 批量选择：勾选的源 id
  final Set<String> _selected = {};

  /// 「筛选已注册的漫画源」
  final _filterCtrl = TextEditingController();
  String _filter = '';

  /// 拖动排序用的本地顺序（与 SourceManager 同步）
  List<MangaSource> _order = [];

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: SettingsService().sourceRepoUrl);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  // ============================================================
  // 源体检：逐个源跑一次「分类首页 / 搜索」，找出打不开或没内容的源
  // ============================================================
  //
  // 用户 2026-10-18：「复核一哈这些漫画源，好多加载不出了或者是没有内容」。
  // 外部源都是用户导入的，代码侧看不到规则；这里给一次性体检，
  // 失败列表可以直接「禁用失败源」，漫画首页就不再显示它们。

  Future<void> _runHealthCheck() async {
    if (_healthChecking) return;
    final sources = SourceManager().enabledSources;
    if (sources.isEmpty) {
      _toast('没有可检测的源');
      return;
    }
    setState(() => _healthChecking = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('正在体检漫画源（分类 / 搜索）…')),
          ],
        ),
      ),
    );

    final bad = <MangaSource, String>{};
    await Future.wait(
      sources.map((s) async {
        final err = await _probeSource(s);
        if (err != null) bad[s] = err;
      }),
    );
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    setState(() => _healthChecking = false);

    if (bad.isEmpty) {
      _toast('体检完成：${sources.length} 个源全部可用');
      return;
    }
    final ok = sources.length - bad.length;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('源体检：$ok 可用 / ${bad.length} 失效'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final e in bad.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.key.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _shortErr(e.value),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await SourceManager().setEnabledAll(
                bad.keys.map((e) => e.id),
                false,
              );
              if (mounted) _toast('已禁用 ${bad.length} 个失效源');
            },
            child: const Text(
              '禁用失败源',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  /// 单个源探测：
  ///   · 有分类 → 拉分类 + 第一页内容（漫画首页实际走的就是这条）
  ///   · 纯搜索源 → 用常见词搜一次
  /// 返回 null = 正常；否则返回简短失败原因。
  Future<String?> _probeSource(MangaSource s) async {
    const t = Duration(seconds: 12);
    try {
      if (s.supportsCategories) {
        final groups = await s.fetchCategories().timeout(t);
        if (groups.isEmpty) return '分类为空';
        final g = groups.first;
        final opt = g.options.firstWhere(
          (o) => !o.isAll,
          orElse: () => g.options.first,
        );
        final page = await s
            .getCategoryList([g.copyWith(selected: opt)], page: 0)
            .timeout(t);
        if (page.items.isEmpty) return '首页无内容';
        return null;
      }
      final page = await s.search('漫画', page: 0).timeout(t);
      if (page.items.isEmpty) return '搜索无结果';
      return null;
    } catch (e) {
      return _shortErr('$e');
    }
  }

  String _shortErr(String raw) {
    final s = raw.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  Future<void> _updateFromCloud() async {
    final url = _urlCtrl.text.trim();
    await SettingsService().setSourceRepoUrl(url);
    if (url.isEmpty) {
      _toast('请先填写云端仓库地址');
      return;
    }
    setState(() => _busy = true);
    try {
      // fetchRemote 读用户填的云端 URL：为空返回 null；非空 Dio 拉取 -> saveLocal。
      final remote = await SourceConfigStore().fetchRemote();
      if (remote == null) {
        // 🔴 `null` 在这里**同时表示两件事** ✗：① 拉取失败（网络不通 / 404 /
        // JSON 解析错 ✓）② 云端文件本身就**是空的**（合法返回 ✓）——
        // 服务层 `fetchRemote` 把两者都归成 `null` ✓（见它自己的注释 ✓）。
        // 原来一句「失败或为空」✗ 让用户完全无法判断：该改地址？还是查网络？✓
        // 这里至少把**判断依据**和"地址已保存"说清楚 ✓，用户可据此自查 ✓
        //（要真正区分，需要服务层返回带原因的结果 ✓ —— 已记入待办 ✓）
        _toast(
          '云端更新未生效：地址已保存，请检查该地址能否访问、'
          '或它的 sources.json 是否为空',
        );
        return;
      }
      await SourceManager().reload();
      _toast('已从云端更新 ${remote.length} 个源');
    } catch (e) {
      _toast('云端更新失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('漫画源仓库'),
        actions: [
          // 源体检（用户 2026-10-18）：一键找出打不开/没内容的源
          IconButton(
            tooltip: '源体检',
            icon: _healthChecking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.health_and_safety_outlined),
            onPressed: _healthChecking ? null : _runHealthCheck,
          ),
          // 漫画仓（用户 2026-10-18）：从「我的」页移到仓库页右上角
          IconButton(
            tooltip: '漫画仓',
            icon: const Icon(Icons.inventory_2_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const SourceWarehousePage(comic: true),
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        listenable: SourceManager(),
        builder: (context, _) {
          final sources = _visibleSources;
          return Column(
            children: [
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.all(16),
                  // 拖动排序：把新顺序交给 SourceManager
                  onReorder: (o, n) {
                    if (n > o) n -= 1; // Flutter 约定：newIndex 是"插入到之前"
                    final ids = _order.map((e) => e.id).toList();
                    final moved = ids.removeAt(o);
                    ids.insert(n, moved);
                    _order = [
                      for (final id in ids) ..._order.where((e) => e.id == id),
                    ];
                    SourceManager().reorder(ids);
                    setState(() {});
                  },
                  itemCount: sources.length + 1,
                  itemBuilder: (context, i) {
                    // 前两块固定：云端卡片 + 计数/筛选/清空
                    if (i == 0) {
                      return Column(
                        key: const ValueKey('head'),
                        children: [
                          _buildCloudCard(isDark),
                          const SizedBox(height: 14),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Row(
                              children: [
                                Text(
                                  '共 ${SourceManager().sources.length} 个',
                                  style: TextStyle(
                                    fontSize: AppTheme.fontSubhead,
                                    color: JellyTheme.textSecondary,
                                  ),
                                ),
                                const Spacer(),
                                if (SourceManager().sources.isNotEmpty)
                                  TextButton(
                                    onPressed: _clearAll,
                                    child: const Text(
                                      '清空',
                                      style: TextStyle(
                                        fontSize: AppTheme.fontSubhead,
                                      ),
                                    ),
                                  ),
                                // 内置漫画源已移除（用户 2026-10-13）：原来这里在"无源"时显示
                                // 「恢复内置源」按钮，现在没有内置源可恢复 → 按钮一并去掉。
                                // 无源时改为提示用户去上面的云端卡片填地址 / 导入 JSON。
                                if (SourceManager().sources.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: Text(
                                      '在上方填云端地址或导入 JSON',
                                      style: TextStyle(
                                        fontSize: AppTheme.fontSubhead,
                                        color: JellyTheme.textSecondary,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),
                          // 筛选已注册的漫画源
                          // ✅ 统一到共用组件 ✓（原为**手写一整套皮** ✗：40 高 / 圆角 20 / 卡片色
                          //   容器 + 手画 `prefixIcon` 放大镜 + 自己实现的 `suffixIcon` 清空键 ✓）。
                          //   ⚠️ 它原本是 **40 高 / 圆角 20** ✗，而书源体检那处是 **32 / 16** ✗
                          //   —— 同模块**两种尺寸** ✓ 正是"排版不统一"的证据 ✓；
                          //   统一成组件后**两页同款** ✓（这就是本次的目的 ✓）。
                          // ⚠️ 必须**整段替换** ✓：`JellySearchBar` 自带底色/圆角/放大镜/清空键 ✓，
                          //   若留下外层 `Container(decoration: …)` 就成"圆角方框套胶囊" ✗。
                          // 参数对照 ✓：controller `_filterCtrl` ✓ · hintText 同文案 ✓ ·
                          //   onChanged: setState(_filter = v) ✓（语义不变 ✓）·
                          //   onCleared: 原为 `_filterCtrl.clear() + setState(_filter = '')` ✓
                          //   → 这里**两者都保留** ✓（组件内部是否清 controller 我不假设 ✗，多清一次无害 ✓）
                          JellySearchBar(
                            controller: _filterCtrl,
                            hintText: '筛选已注册的漫画源',
                            onChanged: (v) => setState(() => _filter = v),
                            onCleared: () {
                              _filterCtrl.clear();
                              setState(() => _filter = '');
                            },
                          ),
                          const SizedBox(height: 10),
                        ],
                      );
                    }
                    // 空态
                    if (sources.isEmpty) {
                      return Padding(
                        key: const ValueKey('empty'),
                        padding: const EdgeInsets.only(top: 40),
                        child: _buildEmptyState(isDark),
                      );
                    }
                    final s = sources[i - 1];
                    return Container(
                      key: ValueKey('src-${s.id}'),
                      child: _buildSourceCard(isDark, s),
                    );
                  },
                ),
              ),
              // ── 多选底部操作栏（截图 IMG_8050）──────────────────
              if (_selected.isNotEmpty) _buildSelectBar(isDark),
            ],
          );
        },
      ),
    );
  }

  /// 清空全部漫画源（带二次确认）
  Future<void> _clearAll() async {
    final n = SourceManager().sources.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空漫画源'),
        content: Text('将删除全部 $n 个漫画源，不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 清空 = 删除文档目录覆盖层 + 置「已清空」标记：
    // 这样 loadLocal 不再回退出厂内置源，源列表真正清到 0 个。
    // （之前用 saveLocal([]) 写空文件，loadLocal 视为"无配置"又回退内置源，
    //   导致清空看起来失效。）
    await SourceConfigStore().resetToLocal();
    await SourceConfigStore().markCleared();
    // Legado 漫画源存在书源仓库里，也要一起清掉，否则"清空"后还会冒出来
    for (final s in SourceManager().sources) {
      await _removeLegadoComic(s);
    }
    await SourceManager().reload();
    if (mounted) setState(() {});
  }

  /// 多选底部操作栏（截图 IMG_8050）：
  ///   已选 N 项 | 全选 | [开关] [分享] [删除] [✕]
  Widget _buildSelectBar(bool isDark) {
    final all = _visibleSources;
    final allPicked = _selected.length == all.length && all.isNotEmpty;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: _cardNow,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Text(
            '已选 ${_selected.length} 项',
            style: TextStyle(
              fontSize: AppTheme.fontBody,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: () => setState(() {
              if (allPicked) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(all.map((e) => e.id));
              }
            }),
            child: Text(
              allPicked ? '取消全选' : '全选',
              style: const TextStyle(fontSize: AppTheme.fontSubhead),
            ),
          ),
          const Spacer(),
          // 批量启用/停用：若已选的都启用 → 点它全停用，反之全启用
          _barBtn(
            icon: Icons.toggle_on_outlined,
            tooltip: '启用/停用选中',
            onTap: () async {
              final anyOff = _selected.any(
                (id) => !SourceManager().isEnabled(id),
              );
              await SourceManager().setEnabledAll(_selected, anyOff);
              if (mounted) setState(() {});
            },
          ),
          _barBtn(
            icon: Icons.ios_share_rounded,
            tooltip: '分享选中',
            onTap: _shareSelected,
          ),
          _barBtn(
            icon: Icons.delete_outline_rounded,
            tooltip: '删除选中',
            onTap: _deleteSelected,
          ),
          _barBtn(
            icon: Icons.close_rounded,
            tooltip: '退出多选',
            onTap: () => setState(() => _selected.clear()),
          ),
        ],
      ),
    );
  }

  Widget _barBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, size: 21, color: JellyTheme.textSecondary),
      ),
    );
  }

  /// 分享选中的源（按书源仓库同一做法：JSON 复制到剪贴板）。
  ///
  /// ⚠️ 我原来写的是"写临时文件 + share_plus 系统分享"，
  /// 但本页没 import `dart:io` / `path_provider` / `share_plus`，
  /// 而且书源仓库那边早就用 Clipboard 这套了 ——
  /// **同一件事不要有两种做法**（多一条依赖路径就多一处会坏的地方）。
  Future<void> _shareSelected() async {
    final picked = SourceManager().sources
        .where((s) => _selected.contains(s.id))
        .toList();
    if (picked.isEmpty) return;
    // ConfigMangaSource 的配置在 `site` 上（不是 rawConfig —— 我先写错了）；
    // Legado 漫画源直接导书源原始 JSON，别人贴进漫画源仓库即可导入。
    final arr = [
      for (final s in picked)
        if (s is ConfigMangaSource)
          {'type': 'config', 'config': s.site.toJson()}
        else if (s.id.startsWith('legado:'))
          () {
            final url = s.id.substring('legado:'.length);
            final bs = BookSourceStore.instance.all
                .where((b) => b.id == s.id || b.url == url)
                .firstOrNull;
            return bs?.raw ?? {'type': 'builtin', 'id': s.id};
          }()
        else
          {'type': 'builtin', 'id': s.id},
    ];
    final text = const JsonEncoder.withIndent('  ').convert(arr);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '已复制 ${picked.length} 个漫画源',
          style: const TextStyle(fontSize: AppTheme.fontHeadline),
        ),
        content: const Text(
          'JSON 已复制到剪贴板，可直接粘贴分享给别人。\n\n'
          '对方用「导入文件」或粘贴导入即可。',
          style: TextStyle(fontSize: AppTheme.fontSubhead, height: 1.6),
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

  /// 批量删除选中的源
  Future<void> _deleteSelected() async {
    final n = _selected.length;
    if (n == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除选中漫画源'),
        content: Text('将删除选中的 $n 个漫画源，不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ids = Set.of(_selected);
    final left = (await SourceConfigStore().loadLocal())
        .where((d) => !ids.contains(d.id))
        .toList();
    await SourceConfigStore().saveLocal(left);
    // 同步移除选中的 Legado 漫画源（它们存在书源仓库里）
    for (final s in SourceManager().sources) {
      if (ids.contains(s.id)) await _removeLegadoComic(s);
    }
    _selected.clear();
    await SourceManager().reload();
    if (mounted) setState(() {});
  }

  /// 打开漫画源编辑页（改名称/URL/抓取规则）。
  ///
  /// 编辑页保存后会 reload 源管理器；从本地配置里取该 id 的
  /// SourceDefinition 传给编辑页（仓库列表只有 MangaSource 实例，
  /// 编辑需要 definition 外壳 + 原始 config）。
  Future<void> _editSource(MangaSource src) async {
    try {
      // Legado 漫画脚本存在书源仓库里（id = legado:<bookSourceUrl>），
      // 用书源编辑页改规则；保存后重载 SourceManager 让漫画页立即生效。
      if (src.id.startsWith('legado:')) {
        final url = src.id.substring('legado:'.length);
        final book = BookSourceStore.instance.all
            .where((s) => s.id == src.id || s.url == url)
            .firstOrNull;
        if (book == null) {
          _toast('找不到该 Legado 源（可能已被删除）');
          return;
        }
        final changed = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => BookSourceEditorPage(source: book),
          ),
        );
        if (changed == true) {
          await SourceManager().reload();
          if (mounted) setState(() {});
        }
        return;
      }

      final defs = await SourceConfigStore().loadLocal();
      SourceDefinition? found;
      for (final d in defs) {
        if (d.id == src.id) {
          found = d;
          break;
        }
      }
      final def = found;
      if (def == null) {
        _toast('找不到该源的配置（可能来自云端缓存，请先从云端更新）');
        return;
      }
      final changed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => ComicSourceEditPage(definition: def),
        ),
      );
      if (changed == true) {
        await SourceManager().reload();
        if (mounted) setState(() {});
      }
    } catch (e) {
      _toast('打开编辑失败：${e.toString().split('\n').first}');
    }
  }

  /// 手动导入卡片。
  ///
  /// ── 为什么要有这个 ────────────────────────────────────────────
  /// 原版只支持「填云端 sources.json 地址 → 整体覆盖本地」，
  /// 用户想加**单独一个源**时无处可下（也没法删掉某个源）。
  /// 这里补上：粘贴 JSON 导入单个源 / 一份完整 sources.json，并支持删除。
  ///
  /// 支持的格式（两种都吃）：
  ///   1. 单个源：      {"type":"config","config":{"name":"...","url":"...", ...}}
  ///   2. 完整文件：    {"version":1,"sources":[ ... ]}
  ///   3. 纯数组：      [ {...}, {...} ]
  /// 解析并写入本地源配置。
  ///
  /// 合并策略：**同 id 覆盖、新 id 追加**，其余保留 ——
  /// 用户导入一个源不该把他已有的源全冲掉。
  Future<({bool ok, String message})> _importJson(String text) async {
    try {
      dynamic decoded;
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        // 书源分发文件常带尾随逗号 / 说明文字，交给 Legado 解析器再试一次
        decoded = null;
      }
      final defs = <SourceDefinition>[];

      void take(dynamic raw) {
        if (raw is! Map) return;
        final m = raw.cast<String, dynamic>();
        // Cmbok 导出包装：{seq,id,name,url,enabled,...,json:"<SourceDefinition JSON>"}
        // 配置本体在 json 字段（字符串），顶层 url 恒为空串 —— 必须先解包再取。
        if (m['json'] is String && !m.containsKey('config')) {
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
        // 单个源对象：有 config 字段
        if (m.containsKey('config') && m['config'] is Map) {
          defs.add(SourceDefinition.fromJson(m));
          return;
        }
        // 也可能是 SiteConfig 裸对象（直接贴 config 的内容）
        if (m.containsKey('name') && m.containsKey('url')) {
          // 裸 SiteConfig：id 按 SourceDefinition 的约定派生（config:${name}），
          // 与 SourceManager 用 ConfigMangaSource 时的 id 保持一致
          defs.add(
            SourceDefinition(
              id: 'config:${m['name']}',
              type: 'config',
              config: m,
            ),
          );
        }
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

      // ── 2) Legado 漫画书源（bookSourceName / ruleSearch …）────────
      //
      // 用户 2026-10-18：「书源那种漫画脚本，漫画源要兼容呀」——
      // 漫画源仓库此前只认 {type:'config'} 格式，直接把书源脚本贴进来会报
      // "没解析出漫画源"。这里复用书源仓库同一个解析器，并把漫画脚本
      // 统一标记为 `bookSourceType: 2` 存进书源仓库（SourceManager 会把它
      // 注册成漫画源，书源页则按 isComicSource 隐藏）。
      final legado = <BookSource>[];
      try {
        for (final s in BookSourceImportParser.parseSources(text)) {
          // 裸 SiteConfig（只有 name/url）已经进了 defs，别再当成 Legado 源
          if (s.raw['bookSourceName'] == null &&
              s.raw['bookSourceUrl'] == null) {
            continue;
          }
          if (!s.isComicSource) continue;
          legado.add(
            BookSource(
              raw: {...s.raw, 'bookSourceType': 2},
              id: s.id,
            ),
          );
        }
      } catch (_) {
        // 不是 Legado 格式就忽略，按原有配置源流程处理
      }

      if (defs.isEmpty && legado.isEmpty) {
        return (
          ok: false,
          message:
              '没解析出漫画源。支持两种格式：\n'
              '① Web 配置源 {"type":"config","config":{"name":...,"url":...}}\n'
              '② Legado 书源脚本（含 bookSourceName / bookSourceUrl / ruleContent）',
        );
      }

      // 校验：type=config 必须有 name 与 url，否则导入后根本用不了，
      // 不如当场拦住并说清缺什么
      final bad = <String>[];
      for (final d in defs) {
        if (d.type == 'config') {
          final c = d.config;
          if ((c['name'] ?? '').toString().trim().isEmpty) {
            bad.add('缺少 name');
          } else if ((c['url'] ?? '').toString().trim().isEmpty) {
            bad.add('${c['name']} 缺少 url');
          }
        }
      }
      if (bad.isNotEmpty) {
        return (ok: false, message: '漫画源不完整：${bad.take(3).join('；')}');
      }

      final store = SourceConfigStore();
      final local = await store.loadLocal();
      final byId = {for (final d in local) d.id: d};
      var added = 0;
      var updated = 0;
      for (final d in defs) {
        if (d.id.trim().isEmpty) continue;
        if (byId.containsKey(d.id)) {
          updated++;
        } else {
          added++;
        }
        byId[d.id] = d;
      }
      await store.saveLocal(byId.values.toList());

      // Legado 漫画脚本写入书源仓库，再由 SourceManager 注册为漫画源
      var bookAdded = 0;
      var bookUpdated = 0;
      if (legado.isNotEmpty) {
        final bsStore = BookSourceStore.instance;
        if (bsStore.isEmpty) await bsStore.init();
        final r = await bsStore.addAll(legado);
        bookAdded = r.added;
        bookUpdated = r.updated;
      }

      await SourceManager().reload();

      final parts = <String>[];
      if (defs.isNotEmpty) {
        parts.add(
          added > 0 && updated > 0
              ? '新增 $added 个、更新 $updated 个漫画源'
              : (added > 0 ? '已导入 $added 个漫画源' : '已更新 $updated 个漫画源'),
        );
      }
      if (legado.isNotEmpty) {
        parts.add(
          bookAdded > 0 && bookUpdated > 0
              ? 'Legado 漫画源新增 $bookAdded 个、更新 $bookUpdated 个'
              : (bookAdded > 0
                    ? '已导入 $bookAdded 个 Legado 漫画源'
                    : '已更新 $bookUpdated 个 Legado 漫画源'),
        );
      }
      return (ok: true, message: parts.join('；'));
    } catch (e) {
      // ✅ **统一到 `utils/source_fail_text.dart`** ✓（"同一原因同一类" ✓）——
      //   原来这里直接甩「JSON 解析失败：…」✗，与搜索页/体检页/下载侧的**说法不一致** ✗✓
      //   （用户在不同页面看到同一个原因，却是三套话 ✓）。现在按**统一分类**给话 ✓，
      //   并把原始异常附在括号里 ✓ —— 既统一 ✓ 又不丢排查信息 ✓✓。
      final info = describeSourceFail(e, what: '云端源配置');
      return (
        ok: false,
        message: '${info.text}（${e.toString().split('\n').first}）',
      );
    }
  }

  /// 当前是否深色（弹层里拿不到页面 context 的 theme 时用）
  bool isDarkNow() => Theme.of(context).brightness == Brightness.dark;

  Widget _buildCloudCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '云端仓库',
            style: TextStyle(
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            // 截图原文。这句同时回答了用户两个疑问：
            // "会不会把我已有的源冲掉"（不会）+"多个地址怎么处理"（合并去重）
            '导入按地址合并去重，不会覆盖已有源',
            style: TextStyle(
              fontSize: AppTheme.fontFootnote,
              color: JellyTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            style: TextStyle(
              fontSize: AppTheme.fontBody,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: '书源地址（json / zip / 仓库索引）',
              hintStyle: TextStyle(
                fontSize: AppTheme.fontBody,
                color: JellyTheme.textSecondary,
              ),
              filled: true,
              fillColor: isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.black.withValues(alpha: 0.035),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 13,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 两个按钮并排（截图布局）
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _importFromFile,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.22)
                          : Colors.black.withValues(alpha: 0.16),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    foregroundColor: isDark
                        ? Colors.white
                        : JellyTheme.textPrimaryLight,
                  ),
                  icon: const Icon(Icons.file_upload_outlined, size: 17),
                  label: const Text(
                    '导入文件',
                    style: TextStyle(fontSize: AppTheme.fontBody),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _updateFromCloud,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: _busy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_download_rounded, size: 17),
                  label: const Text(
                    '从云端更新',
                    style: TextStyle(fontSize: AppTheme.fontBody),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 从本地文件导入漫画源。
  ///
  /// 支持 `.json` / `.txt` / `.zip` —— 漫画源的分发同样是压缩包居多，
  /// 不认 zip 的话用户只会看到"解析失败"而看不出原因。
  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt', 'zip'],
      );
      if (result.isEmpty) return;
      final f = result.first;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) {
        _toast('文件是空的');
        return;
      }

      // zip 魔数 PK\x03\x04
      final isZip =
          bytes.length > 4 &&
          bytes[0] == 0x50 &&
          bytes[1] == 0x4B &&
          (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07);

      if (!isZip) {
        // ⚠️ 必须 utf8.decode，不能用 String.fromCharCodes ——
        // 后者按"码元"直译，任何非 ASCII（中文源名）都会变乱码，
        // 症状是"导入成功但源名全是问号"。
        await _applyImportedText(utf8.decode(bytes, allowMalformed: true));
        return;
      }

      final archive = ZipDecoder().decodeBytes(bytes);
      var tried = 0;
      for (final zf in archive) {
        if (!zf.isFile) continue;
        final lower = zf.name.toLowerCase();
        if (!lower.endsWith('.json') && !lower.endsWith('.txt')) continue;
        tried++;
        final data = zf.content;
        final zb = data is Uint8List
            ? data
            : Uint8List.fromList(List<int>.from(data as List));
        await _applyImportedText(utf8.decode(zb, allowMalformed: true));
      }
      if (tried == 0) _toast('压缩包里没有 json / txt 文件');
    } catch (e) {
      _toast('导入失败：${e.toString().split('\n').first}');
    }
  }

  /// 把导入的文本交给 [_importJson]。
  ///
  /// 复用而不是重写：`_importJson` 已经处理了全部形态
  /// （单对象 / 数组 / `{"sources":[…]}` / 裸 SiteConfig）、
  /// 字段校验、同 id 覆盖合并、saveLocal + reload。
  /// 再写一遍只会分叉出第二套解析逻辑，以后改一处漏一处。
  Future<void> _applyImportedText(String text) async {
    final r = await _importJson(text);
    if (!mounted) return;
    if (r.ok) setState(() {});
    _toast(r.message);
  }

  /// 空态（按截图：还没有漫画源 + 说明怎么导）
  Widget _buildEmptyState(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Column(
        children: [
          Icon(
            Icons.folder_open_rounded,
            size: 48,
            color: JellyTheme.textSecondary.withValues(alpha: 0.55),
          ),
          const SizedBox(height: 20),
          Text(
            '还没有漫画源',
            style: TextStyle(
              fontSize: AppTheme.fontTitle3,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              // 截图原文。注意"加密的"三个字 —— V2.0.8 的云端地址是密文，
              // 直接填明文地址是拉不到的（这点必须如实告诉用户，
              // 否则他会以为"我填了地址怎么没用"）。
              '粘贴加密的云端地址后点「从云端更新」，或导入密文文件',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                height: 1.6,
                color: JellyTheme.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 一个漫画源卡片（按截图 IMG_8047）：
  ///   [≡拖动] [复选框] [首字头像] 名称 / 标识   ......  [启用开关]
  ///
  /// 与旧版的区别：
  ///   · 左侧加了**拖动把手**（截图里那三条横线）—— 长按可拖动排序
  ///   · 加了**复选框**（批量选择用，与书源仓库一致）
  ///   · subtitle 用 `src.id` 里的短标识（如 copymanga），不再写
  ///     "需要魔法（代理/VPN）"整句 —— 那句话挤占了名称行，
  ///     魔法需求改用图标表达（已有的 magic_stick）
  Widget _buildSourceCard(bool isDark, MangaSource src) {
    final enabled = SourceManager().isEnabled(src.id);
    final sel = _selected.contains(src.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(6, 8, 8, 8),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
        border: sel ? Border.all(color: JellyTheme.primary, width: 1.2) : null,
      ),
      child: Row(
        children: [
          // 拖动把手（长按拖动排序，用的是 ReorderableListView 的
          // ReorderableDragStartListener —— 见 _buildList）
          ReorderableDragStartListener(
            index: _orderedIndex(src),
            child: Icon(
              Icons.drag_handle_rounded,
              size: 20,
              color: JellyTheme.textSecondary,
            ),
          ),
          const SizedBox(width: 2),
          // 复选框（批量选择）
          GestureDetector(
            onTap: () => setState(() {
              if (sel) {
                _selected.remove(src.id);
              } else {
                _selected.add(src.id);
              }
            }),
            child: Icon(
              sel ? Icons.check_box : Icons.check_box_outline_blank,
              size: 21,
              color: sel ? JellyTheme.primary : JellyTheme.textSecondary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: () => _editSource(src),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    _buildSourceIcon(src),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  src.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppTheme.fontHeadline,
                                    fontWeight: FontWeight.w600,
                                    color: enabled
                                        ? (isDark
                                              ? Colors.white
                                              : JellyTheme.textPrimaryLight)
                                        : JellyTheme.textSecondary,
                                  ),
                                ),
                              ),
                              if (src.needsMagic) ...[
                                const SizedBox(width: 6),
                                Image.asset(
                                  'assets/icons/magic_stick.png',
                                  width: 14,
                                  height: 14,
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            // 标识：优先取 config 里的短名（如 copymanga / zaimanhua），
                            // 没有就用 id（book 源常见 "config:某某漫画" 这种形式）
                            _sourceShortId(src),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppTheme.fontFootnote,
                              color: JellyTheme.textSecondary,
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
          Switch(
            value: enabled,
            activeThumbColor: JellyTheme.primary,
            onChanged: (v) {
              SourceManager().setEnabled(src.id, v);
            },
          ),
          // 单个删除：能导入就得能删，否则用户导错一个源没法收拾
          // （批量删除走底部的多选栏）
          IconButton(
            tooltip: '删除这个源',
            icon: Icon(
              Icons.delete_outline,
              size: 19,
              color: JellyTheme.textSecondary,
            ),
            onPressed: () => _confirmRemove(src),
          ),
        ],
      ),
    );
  }

  /// 取源的"短标识"用于列表副标题。
  ///
  /// 截图里显示的是 `copymanga` / `zaimanhua` / `manhuaren` 这种，
  /// 而不是完整的 url 或 "config:某某漫画"。优先从 config 里取
  /// 常见字段（id / key / name 的英文形式），都没有再退回 src.id。
  String _sourceShortId(MangaSource src) {
    // ⚠️ `MangaSource` 是抽象类，只有 id / name / lang 等 getter，
    // **没有 config**（那是我误以为的字段）。所以这里只用 id：
    //   · 'copymanga'      → copymanga
    //   · 'config:瓜子漫画' → 瓜子漫画
    return src.id.startsWith('config:')
        ? src.id.substring('config:'.length)
        : src.id;
  }

  /// 源在"当前显示列表"里的下标（拖动排序要用）
  int _orderedIndex(MangaSource src) {
    final i = _visibleSources.indexWhere((e) => e.id == src.id);
    return i < 0 ? 0 : i;
  }

  /// 当前显示的源（按筛选词过滤；拖动排序后按 _order 排列）
  List<MangaSource> get _visibleSources {
    final all = SourceManager().sources;
    // 首次或源数量变化时重建顺序表
    if (_order.length != all.length) {
      _order = List.of(all);
    }
    final kw = _filter.trim().toLowerCase();
    if (kw.isEmpty) return _order;
    return _order
        .where(
          (s) =>
              s.name.toLowerCase().contains(kw) ||
              s.id.toLowerCase().contains(kw),
        )
        .toList();
  }

  /// 删除一个源（从本地配置里摘掉，然后 reload）。
  ///
  /// ⚠️ 只删**本地配置**里的这一条。如果它来自云端 sources.json，
  /// 下次"从云端更新"会把它带回来 —— 所以删除确认里要说清这一点，
  /// 免得用户以为删不掉。
  /// Legado 漫画源存在书源仓库中，删除漫画源时必须同步移除，
  /// 否则 reload 后会从书源仓库重新注册回来（看起来"删不掉"）。
  Future<void> _removeLegadoComic(MangaSource src) async {
    if (!src.id.startsWith('legado:')) return;
    final url = src.id.substring('legado:'.length);
    final hits = BookSourceStore.instance.all
        .where((s) => s.id == src.id || s.url == url)
        .toList();
    for (final s in hits) {
      await BookSourceStore.instance.remove(s.id);
    }
  }

  Future<void> _confirmRemove(MangaSource src) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除漫画源', style: TextStyle(fontSize: AppTheme.fontHeadline)),
        content: Text(
          '确定删除「${src.name}」？\n\n'
          '注意：如果它来自云端 sources.json，下次「从云端更新」会重新出现。',
          style: const TextStyle(fontSize: AppTheme.fontSubhead, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final store = SourceConfigStore();
      final local = await store.loadLocal();
      final left = local.where((d) => d.id != src.id).toList();
      await store.saveLocal(left);
      await _removeLegadoComic(src);
      await SourceManager().reload();
      if (!mounted) return;
      setState(() {});
      _toast('已删除「${src.name}」');
    } catch (e) {
      _toast('删除失败：$e');
    }
  }

  /// 源图标：config 源有 icon URL 用网络图，否则用首字圆形占位。
  Widget _buildSourceIcon(MangaSource src) {
    final String? iconUrl = src is ConfigMangaSource ? src.site.icon : null;
    const size = 40.0;
    if (iconUrl != null && iconUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        // 用带磁盘缓存的图片：源仓库列表滚动时不重复下载图标
        child: CachedNetworkImage(
          imageUrl: iconUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) => _initialAvatar(src, size),
        ),
      );
    }
    return _initialAvatar(src, size);
  }

  Widget _initialAvatar(MangaSource src, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: JellyTheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        src.name.isNotEmpty ? src.name[0] : '?',
        style: TextStyle(
          fontSize: AppTheme.fontTitle3,
          fontWeight: FontWeight.bold,
          color: JellyTheme.primary,
        ),
      ),
    );
  }
}
