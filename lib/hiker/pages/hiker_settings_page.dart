import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../widgets/app_toast.dart';
import '../widgets/card_source_sheet.dart';
import '../services/hiker_builtin.dart';
import '../services/hiker_prefs.dart';
import '../services/hiker_store.dart';
import 'hiker_files_page.dart';
import 'hiker_manage_page.dart';

/// 「海阔设置」—— 模块的**总设置页**（入口：设置 → 海阔设置）。
///
/// 分 7 组，全部只影响「海阔」模块自己：
///   ① 源管理（导入 / 启停 / 删除 / 源配置）
///   ② 当前源
///   ③ 显示（列数 / 简介）
///   ④ 引擎（执行超时 / 单次最大条数）
///   ⑤ 源排序
///   ⑥ 数据清理（历史 / 规则变量 / 全部源）
///   ⑦ 调试与说明
class HikerSettingsPage extends StatefulWidget {
  const HikerSettingsPage({super.key});

  @override
  State<HikerSettingsPage> createState() => _HikerSettingsPageState();
}

class _HikerSettingsPageState extends State<HikerSettingsPage> {
  final _store = HikerStore.instance;
  final _prefs = HikerPrefs.instance;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChanged);
    _prefs.addListener(_onChanged);
    if (!_prefs.loaded) {
      _prefs.load().then((_) {
        if (mounted) setState(() {});
      });
    }
    if (!_store.loaded) {
      _store.load().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _store.removeListener(_onChanged);
    _prefs.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final total = _store.sources.length;
    final usable = _store.usableCount;
    final enabled = _store.enabledCount;
    final cur = _store.current;

    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        foregroundColor: AppTheme.textPrimary,
        elevation: 0,
        title: Text('海阔设置',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 40),
        children: [
          _statsCard(total, usable, enabled),
          const SizedBox(height: 18),

          // ① 源管理
          _section('源管理'),
          _navTile(
            icon: Icons.rocket_launch_outlined,
            title: '海阔源管理',
            subtitle: '导入 / 启停 / 删除 / 源配置 · 共 $total 个（可用 $usable）',
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HikerManagePage()),
              );
              if (mounted) setState(() {});
            },
          ),
          _navTile(
            icon: Icons.cloud_download_outlined,
            title: '安装内置源',
            subtitle: '随包内置、实测能跑的源（已装的更新，删掉的补回）'
                '；同时释放 App 自带资源',
            onTap: _installBuiltin,
            trailingIcon: Icons.add_circle_outline_rounded,
          ),
          _navTile(
            icon: Icons.folder_open_outlined,
            title: '文件管理（hiker://files）',
            subtitle: '导入规则包 zip / 放数据文件 · 一批源靠它才能跑'
                '（如 Apollo，官方 App 里也不带）',
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HikerFilesPage()),
              );
              if (mounted) setState(() {});
            },
            trailingIcon: Icons.chevron_right_rounded,
          ),
          const SizedBox(height: 18),

          // ② 当前源
          _section('当前源'),
          _navTile(
            icon: Icons.swap_horiz_rounded,
            title: cur == null ? '未选择' : cur.title,
            subtitle: cur == null
                ? '还没有源，先导入'
                : '${cur.author} · ${cur.usable ? "可用" : cur.unusableReason}',
            onTap: total == 0 ? null : _pickSource,
          ),
          const SizedBox(height: 18),

          // ③ 显示
          _section('显示'),
          _choiceTile<int>(
            icon: Icons.grid_view_rounded,
            title: '每行个数',
            value: _prefs.columns,
            options: HikerPrefs.columnOptions,
            labelOf: (v) => '$v',
            onChanged: (v) => _prefs.setColumns(v),
          ),
          _switchTile(
            icon: Icons.notes_rounded,
            title: '显示简介',
            subtitle: '卡片标题下方一行简述（关掉更紧凑）',
            value: _prefs.showDesc,
            onChanged: (v) => _prefs.setShowDesc(v),
          ),
          const SizedBox(height: 18),

          // ④ 引擎
          _section('引擎'),
          _choiceTile<int>(
            icon: Icons.timer_outlined,
            title: '执行超时',
            subtitle: '规则抓多少个网页的总预算',
            value: _prefs.timeoutSec,
            options: HikerPrefs.timeoutOptions,
            labelOf: (v) => '$v 秒',
            onChanged: (v) => _prefs.setTimeoutSec(v),
          ),
          _choiceTile<int>(
            icon: Icons.format_list_numbered_rounded,
            title: '单次最大条数',
            subtitle: '一条规则最多返回多少条',
            value: _prefs.maxItems,
            options: HikerPrefs.maxItemOptions,
            labelOf: (v) => '$v 条',
            onChanged: (v) => _prefs.setMaxItems(v),
          ),
          const SizedBox(height: 18),

          // ⑤ 源排序
          _section('源排序'),
          _choiceTile<String>(
            icon: Icons.sort_rounded,
            title: '排序方式',
            value: _prefs.sortBy,
            options: const ['default', 'name', 'usable'],
            labelOf: (v) => switch (v) {
              'name' => '按标题',
              'usable' => '可用优先',
              _ => '导入顺序',
            },
            onChanged: (v) => _prefs.setSortBy(v),
          ),
          const SizedBox(height: 18),

          // ⑥ 数据
          _section('数据'),
          _navTile(
            icon: Icons.history_rounded,
            title: '搜索历史',
            subtitle: '${_prefs.searchHistory.length} 条',
            onTap: _prefs.searchHistory.isEmpty ? null : _clearHistory,
            trailingIcon: Icons.delete_outline_rounded,
          ),
          _navTile(
            icon: Icons.restart_alt_rounded,
            title: '清空规则变量',
            subtitle: '规则用 setMyVar 存的登录态 / 域名缓存等（清完需重新登录）',
            onTap: _clearVars,
            trailingIcon: Icons.cleaning_services_outlined,
          ),
          _navTile(
            icon: Icons.delete_sweep_outlined,
            title: '清空全部海阔源',
            subtitle: '只影响「海阔」模块',
            onTap: total == 0 ? null : _clearAll,
            trailingIcon: Icons.delete_forever_outlined,
            danger: true,
          ),
          const SizedBox(height: 18),

          // ⑦ 调试与说明
          _section('调试'),
          _switchTile(
            icon: Icons.bug_report_outlined,
            title: '详情页显示原始地址',
            subtitle: '显示条目地址与解析结果（排查用）',
            value: _prefs.showRawUrl,
            onChanged: (v) => _prefs.setShowRawUrl(v),
          ),
          const SizedBox(height: 18),
          _section('说明'),
          _noticeCard(
            '内置源：随包自带一批「实跑筛过」的源（拿 115 个源逐个真跑 home，'
            '只有真出内容的才会内置）。首次进入模块时若仓库为空会自动装好；'
            '删掉后可在上面「安装内置源」补回。\n\n'
            '已支持：\n'
            '· 规则自包含的源（老式 DOM 规则、js: + setResult/setHomeResult）\n'
            '· 二级规则（容器; 标题; 链接; 图片; 描述）\n'
            '· CatVod 老三样 pdfa / pdfh / pd\n'
            '· 源内联 pages 模块（\$.require / evalPrivateJS / '
            'hiker://page|assets 当资源抓）\n'
            '· 源配置 config / 动态域名（URL 的 .js: 规则）\n'
            '· WebView 抓页 fetchCodeByWebView（App 侧真 WebView）\n'
            '· 延迟规则 lazyRule / 局部规则 \$(url).rule(fn)\n'
            '· App 自带资源 hiker://assets/*（随包内置一份，取自海阔官方源码\n'
            '  的 app/src/main/assets：home.js / inject.js / theme.js …）\n'
            '· 文件读写 hiker://files/*（落在 Documents/hiker/files）\n'
            '· **密文核心**：base64 → GZIP 流 → eval 出 JS 核心（如 JavDB）\n'
            '· java.* 的常用类（Base64 / MessageDigest / GZIP+字节流 /\n'
            '  Thread.sleep / UUID / StringBuilder / Integer / reflect.Array）\n'
            '· 页面事件 addListener(\'onClose\', …)：离开页面时回放（清变量等）\n'
            '· 分类切换 / 分页加载更多 / 搜索历史\n\n'
            '暂不支持（会给明确原因，不会静默）：\n'
            '· 需要「海阔内置页 / 用户文件」的源（如 Apollo）—— Apollo 这类\n'
            '  规则包**官方 App 里也不带**，原版同样要自己装；把 zip 从上面的\n'
            '  「文件管理」导进去即可\n'
            '· 任意 Java 类反射（java.lang.reflect 去调 Android SDK）\n'
            '· 新版海阔的**密文模块引用**（`\$.require(\'<加密串>\')`，6 个源用到）\n'
            '· `\$.require` 远程 JS 依赖（http 地址）—— 你的源里 0 个用到\n'
            '· 事件与定时器：setInterval 在**规则**里不是 API（只在网页里有）\n'
            '· 繁简转换 java.t2s/s2t：没有对照表，原样返回\n'
            '· 压缩侧 java.util.zip.GZIPOutputStream',
          ),
        ],
      ),
    );
  }

  // ── 各分组的小组件 ────────────────────────────────────

  Widget _statsCard(int total, int usable, int enabled) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Row(
        children: [
          _stat('源总数', '$total'),
          _stat('可运行', '$usable'),
          _stat('已启用', '$enabled'),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Expanded(
        child: Column(
          children: [
            Text(value,
                style: TextStyle(
                    color: AppTheme.accentOnSurface,
                    fontSize: AppTheme.fontTitle2,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
          ],
        ),
      );

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Text(t,
            style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5)),
      );

  Widget _navTile({
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
    IconData? trailingIcon,
    bool danger = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: ListTile(
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: Icon(icon,
            size: 20,
            color: danger ? Colors.redAccent : AppTheme.accentOnSurface),
        title: Text(title,
            style: TextStyle(
                color: danger ? Colors.redAccent : AppTheme.textPrimary,
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w500)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle,
                maxLines: 2,
                style: TextStyle(
                    color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
        trailing: trailingIcon == null
            ? Icon(Icons.chevron_right_rounded, size: 18, color: AppTheme.textTertiary)
            : Icon(trailingIcon,
                size: 18,
                color: danger ? Colors.redAccent : AppTheme.textTertiary),
      ),
    );
  }

  Widget _switchTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: SwitchListTile(
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppTheme.accentColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        secondary: Icon(icon, size: 20, color: AppTheme.accentOnSurface),
        title: Text(title,
            style: TextStyle(color: AppTheme.textPrimary, fontSize: AppTheme.fontBody)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle,
                style: TextStyle(
                    color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption)),
      ),
    );
  }

  /// 分段选择项（2/3/4、超时、条数、排序…统一用它，样式一致）
  Widget _choiceTile<T>({
    required IconData icon,
    required String title,
    String? subtitle,
    required T value,
    required List<T> options,
    required String Function(T) labelOf,
    required ValueChanged<T> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: AppTheme.accentOnSurface),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: AppTheme.textPrimary, fontSize: AppTheme.fontBody)),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(subtitle,
                            style: TextStyle(
                                color: AppTheme.textTertiary,
                                fontSize: AppTheme.fontCaption)),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: options.map((o) {
              final on = o == value;
              return Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(o),
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on ? AppTheme.accentSurface : AppTheme.backgroundTertiary,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: on
                            ? AppTheme.accentColor.withValues(alpha: 0.5)
                            : Colors.transparent,
                      ),
                    ),
                    child: Text(
                      labelOf(o),
                      style: TextStyle(
                        color: on ? AppTheme.accentOnSurface : AppTheme.textSecondary,
                        fontSize: AppTheme.fontFootnote,
                        fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _noticeCard(String text) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(text,
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontFootnote,
                height: 1.65)),
      );

  // ── 交互 ──────────────────────────────────────────────

  Future<void> _pickSource() async {
    final list = _store.sources;
    // 版式**对齐影视模块的源切换面板**（底部面板 + 双排卡片网格 + 搜索）；
    // 原来是 ListTile 列表弹窗，与影视那个观感完全不同（用户 2026-10-16）
    final picked = await CardSourceSheet.show(
      context: context,
      title: '选择当前源',
      searchable: true,
      emptyHint: '还没有海阔源，先点「安装内置源」或导入',
      items: [
        for (final s in list)
          CardSourceItem(
            id: s.id,
            title: s.title,
            subtitle: s.usable
                ? '${s.author} · 可用'
                : '${s.author} · ${s.unusableReason}',
            warn: !s.usable,
            // 分类 tab 与「源管理」页同一口径（源自己的 group）
            group: s.groupLabel,
            selected: s.id == _store.currentId,
          ),
      ],
    );
    if (picked != null) await _store.setCurrent(picked);
  }

  Future<void> _clearHistory() async {
    await _prefs.clearHistory();
    if (mounted) AppToast.message('已清空搜索历史');
  }

  /// 安装/补齐内置源（随包分发、实跑筛出来的那批）+ 释放 App 自带资源
  Future<void> _installBuiltin() async {
    final n = await HikerBuiltin.count();
    if (n == 0) {
      if (mounted) AppToast.error('内置源资源读不到（打包时漏了 assets/hiker/）');
      return;
    }
    final (added, updated, total) = await HikerBuiltin.install();
    // 顺带把「App 自带资源」铺到 Documents/hiker/builtin（hiker://assets/* 用）
    final files = await HikerBuiltin.installAssets();
    if (!mounted) return;
    AppToast.message('内置源：新增 $added、更新 $updated，共 $total 个源'
        '${files > 0 ? '；自带资源已释放 $files 个' : ''}');
    setState(() {});
  }

  Future<void> _clearVars() async {
    final ok = await _confirm('清空全部规则变量？', '规则下次运行会重新初始化（可能需要重新登录）。');
    if (ok != true) return;
    await _store.clearAllVars();
    if (mounted) AppToast.message('已清空规则变量');
  }

  Future<void> _clearAll() async {
    final ok = await _confirm('清空全部海阔源？', '只影响「海阔」模块，其它模块不受影响。');
    if (ok != true) return;
    await _store.clearAll();
    if (mounted) AppToast.message('已清空');
  }

  Future<bool?> _confirm(String title, String body) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundCard,
        title: Text(title,
            style: TextStyle(
                color: AppTheme.textPrimary, fontSize: AppTheme.fontHeadline)),
        content: Text(body,
            style: TextStyle(
                color: AppTheme.textSecondary, fontSize: AppTheme.fontSubhead)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('确定', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}
