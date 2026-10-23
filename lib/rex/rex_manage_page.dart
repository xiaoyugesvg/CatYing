import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/theme.dart';
import '../widgets/app_toast.dart';
import 'rex_market_page.dart';
import 'rex_models.dart';
import 'rex_service.dart';

/// REX 订阅管理：市场入口 + 启用/停用 + 刷新 + 排序 + 改地址 + 删除。
///
/// 布局按「已启用 / 已停用」两段分组 —— 原来的单列表里开关一关，
/// 卡片只是变灰、位置不变，用户很难看清「现在到底有几个源在首页」。
class RexManagePage extends StatefulWidget {
  const RexManagePage({super.key});

  @override
  State<RexManagePage> createState() => _RexManagePageState();
}

class _RexManagePageState extends State<RexManagePage> {
  final _service = RexService.instance;
  bool _busy = false;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;
  Color get _line => _isDark
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.06);
  Color get _tile => _isDark
      ? Colors.white.withValues(alpha: 0.05)
      : Colors.black.withValues(alpha: 0.025);

  /// 文字 / 图标用的强调色（暗色下 accentColor 是墨灰，看不见）
  Color get _accent => AppTheme.accentOnSurface;

  @override
  void initState() {
    super.initState();
    _service.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('REX 订阅',
            style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
                color: _fg)),
        actions: [
          IconButton(
            tooltip: '打开市场',
            icon: Icon(Icons.storefront_rounded, color: _fg),
            onPressed: _busy ? null : _openMarket,
          ),
          IconButton(
            tooltip: '全部刷新元数据',
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.sync_rounded, color: _fg),
            onPressed: _busy ? null : _refreshAll,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: _service.revision,
        builder: (context, _, __) {
          final all = _service.modules;
          final on = all.where((e) => e.enabled).toList();
          final off = all.where((e) => !e.enabled).toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            children: [
              _summaryCard(all.length, on.length),
              if (all.isEmpty) ...[
                const SizedBox(height: 30),
                _empty(),
              ],
              if (on.isNotEmpty) ...[
                const SizedBox(height: 18),
                _sectionTitle('已启用', on.length),
                for (var i = 0; i < on.length; i++)
                  _card(on[i], onIndex: i, onTotal: on.length),
              ],
              if (off.isNotEmpty) ...[
                const SizedBox(height: 18),
                _sectionTitle('已停用', off.length),
                for (var i = 0; i < off.length; i++)
                  _card(off[i], onIndex: -1, onTotal: off.length),
              ],
              if (all.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '首页只显示「已启用 + 有列表/搜索能力」的模块；'
                  '标着「仅播放」的模块没有可浏览内容，只作为取流源保留。',
                  style: TextStyle(
                      color: _sub,
                      fontSize: AppTheme.fontCaption,
                      height: 1.6),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _summaryCard(int total, int enabled) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              _accent.withValues(alpha: _isDark ? 0.20 : 0.11),
              _accent.withValues(alpha: _isDark ? 0.05 : 0.02),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          border: Border.all(
              color: _accent.withValues(alpha: 0.20), width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.extension_rounded,
                    size: 18, color: _accent),
                const SizedBox(width: 8),
                Text('我的模块',
                    style: TextStyle(
                        color: _fg,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w700)),
                const Spacer(),
                Text('$enabled / $total',
                    style: TextStyle(
                        color: _accent,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            Text('启用 $enabled 个，停用 ${total - enabled} 个',
                style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accentColor,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 42),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMD)),
                ),
                onPressed: _busy ? null : _openMarket,
                icon: const Icon(Icons.add_rounded, size: 19),
                label: const Text('从市场添加模块'),
              ),
            ),
          ],
        ),
      );

  Widget _sectionTitle(String text, int count) => Padding(
        padding: const EdgeInsets.only(bottom: 2, left: 2),
        child: Row(
          children: [
            Text(text,
                style: TextStyle(
                    color: _fg,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: _tile,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text('$count',
                  style:
                      TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
            ),
          ],
        ),
      );

  Widget _empty() => Column(
        children: [
          Icon(Icons.extension_outlined,
              size: 36, color: _sub.withValues(alpha: 0.6)),
          const SizedBox(height: 10),
          Text('还没有模块',
              style: TextStyle(
                  color: _fg,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('去市场挑一个合集，勾选后一键导入。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: _sub, fontSize: AppTheme.fontFootnote, height: 1.6)),
        ],
      );

  Widget _card(RexModule m, {required int onIndex, required int onTotal}) {
    final host = Uri.tryParse(m.url)?.host ?? m.url;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 长按 → 快捷操作（卸载 / 分享 / 刷新…），比一个个点小箭头快
      onLongPress: _busy ? null : () => _quickActions(m),
      child: Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 11, 6, 6),
      decoration: BoxDecoration(
        color: _tile,
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
        border: Border.all(color: _line, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _accent
                      .withValues(alpha: m.enabled ? 0.15 : 0.06),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(Icons.extension_rounded,
                    size: 19,
                    color: m.enabled
                        ? _accent
                        : _sub.withValues(alpha: 0.7)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.title.isEmpty ? 'REX 模块' : m.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: m.enabled ? _fg : _sub,
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      children: [
                        if (m.version.isNotEmpty) _chip('v${m.version}'),
                        _chip('${m.listFunctions.length} 个分类'),
                        if (m.canSearch) _chip('可搜索'),
                        if (m.canPlay) _chip('可播放'),
                        if (m.streamOnly) _chip('仅播放', accent: true),
                      ],
                    ),
                  ],
                ),
              ),
              Switch(
                value: m.enabled,
                activeThumbColor: _accent,
                onChanged: _busy
                    ? null
                    : (v) => _service.setEnabled(m.url, v),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text('$host',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: _sub.withValues(alpha: 0.8),
                        fontSize: 10)),
              ),
              if (onIndex >= 0) ...[
                _mini(Icons.keyboard_arrow_up_rounded,
                    onIndex == 0 ? null : () => _service.move(m.url, -1)),
                _mini(Icons.keyboard_arrow_down_rounded,
                    onIndex >= onTotal - 1 ? null : () => _service.move(m.url, 1)),
              ],
              _more(m),
            ],
          ),
        ],
      ),
      ),
    );
  }

  /// 长按卡片 → 快捷操作面板。
  ///
  /// 用户 2026-10-23：「长按可以卸载、分享」。分享 = 把模块地址复制到
  /// 剪贴板（社区里分享 REX 模块就是分享它的 raw 地址）。
  void _quickActions(RexModule m) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final dark = Theme.of(ctx).brightness == Brightness.dark;
        final fg = dark ? Colors.white : AppTheme.textPrimary;
        final sub = dark ? Colors.white60 : Colors.black54;
        return Container(
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF1C1C1E) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: sub.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(height: 12),
                Text(m.title.isEmpty ? 'REX 模块' : m.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: fg,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(m.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: sub, fontSize: AppTheme.fontCaption)),
                const SizedBox(height: 8),
                _action(ctx, Icons.ios_share_rounded, '分享（复制地址）', fg, () {
                  Clipboard.setData(ClipboardData(text: m.url));
                  AppToast.show('地址已复制', m.url);
                }),
                _action(ctx, Icons.sync_rounded, '刷新元数据', fg, () {
                  _refreshOne(m);
                }),
                _action(ctx, Icons.delete_outline_rounded, '卸载模块',
                    Colors.redAccent, () {
                  _confirmRemove(m);
                }),
                const SizedBox(height: 6),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _action(BuildContext ctx, IconData icon, String label, Color color,
          VoidCallback onTap) =>
      ListTile(
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        leading: Icon(icon, size: 19, color: color),
        title: Text(label,
            style: TextStyle(color: color, fontSize: AppTheme.fontSubhead)),
        onTap: () {
          Navigator.pop(ctx);
          onTap();
        },
      );

  Widget _chip(String text, {bool accent = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(
          color: accent
              ? _accent.withValues(alpha: 0.15)
              : (_isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.04)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text,
            style: TextStyle(
              color: accent ? _accent : _sub,
              fontSize: 9.5,
              fontWeight: accent ? FontWeight.w600 : FontWeight.w400,
            )),
      );

  Widget _mini(IconData icon, VoidCallback? onTap) => IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
        icon: Icon(icon,
            size: 19,
            color: onTap == null ? _sub.withValues(alpha: 0.3) : _sub),
        onPressed: onTap,
      );

  Widget _more(RexModule m) => PopupMenuButton<String>(
        tooltip: '更多',
        padding: EdgeInsets.zero,
        icon: Icon(Icons.more_horiz_rounded, size: 19, color: _sub),
        onSelected: (v) {
          switch (v) {
            case 'refresh':
              _refreshOne(m);
              break;
            case 'url':
              _editUrl(m);
              break;
            case 'cache':
              _clearCache(m);
              break;
            case 'remove':
              _confirmRemove(m);
              break;
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'refresh', child: Text('刷新元数据')),
          PopupMenuItem(value: 'url', child: Text('修改地址')),
          PopupMenuItem(value: 'cache', child: Text('清空编译缓存')),
          PopupMenuItem(
            value: 'remove',
            child: Text('移除模块', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      );

  Future<void> _openMarket() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'rex:market'),
      builder: (_) => const RexMarketPage(),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _refreshOne(RexModule m) async {
    setState(() => _busy = true);
    try {
      await _service.refreshModule(m);
      if (mounted) AppToast.show('已刷新「${m.title}」', '');
    } catch (e) {
      if (mounted) AppToast.show('刷新失败：$e', '');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshAll() async {
    if (_service.modules.isEmpty) return;
    setState(() => _busy = true);
    try {
      final errors = await _service.refreshAll();
      if (!mounted) return;
      AppToast.show(
        errors.isEmpty
            ? '全部刷新完成（${_service.modules.length} 个模块）'
            : '${_service.modules.length - errors.length} 个成功，'
                '${errors.length} 个失败：${errors.first}',
        '',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearCache(RexModule m) async {
    await _service.clearCache(m);
    if (mounted) AppToast.show('已清空「${m.title}」的编译缓存', '');
  }

  Future<void> _editUrl(RexModule m) async {
    final ctrl = TextEditingController(text: m.url);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改模块地址'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(labelText: '模块 raw 地址'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    final newUrl = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || newUrl.isEmpty || newUrl == m.url || !mounted) return;
    setState(() => _busy = true);
    try {
      await _service.updateUrl(m.url, newUrl);
      if (mounted) AppToast.show('地址已更新', '');
    } catch (e) {
      if (mounted) AppToast.show('更新失败：$e', '');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmRemove(RexModule m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除模块？'),
        content: Text('「${m.title}」会从订阅列表移除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('移除')),
        ],
      ),
    );
    if (ok == true) await _service.remove(m.url);
  }
}
