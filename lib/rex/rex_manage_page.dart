import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../widgets/app_toast.dart';
import 'rex_import.dart';
import 'rex_models.dart';
import 'rex_service.dart';

/// REX 订阅管理：导入、启用/停用、刷新元数据、改地址、排序、删除。
///
/// 和「音乐源管理」「书源管理」是同一套心智：首页只展示启用中的模块，
/// 所有维护动作集中在这一页。
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('REX 订阅管理',
            style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
                color: _fg)),
        actions: [
          IconButton(
            tooltip: '导入模块',
            icon: Icon(Icons.add_link_rounded, color: _fg),
            onPressed: _busy
                ? null
                : () async {
                    final ok = await showRexImportDialog(context);
                    if (ok && mounted) setState(() {});
                  },
          ),
          IconButton(
            tooltip: '全部刷新元数据',
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.refresh_rounded, color: _fg),
            onPressed: _busy ? null : _refreshAll,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: _service.revision,
        builder: (context, _, __) {
          final list = _service.modules;
          if (list.isEmpty) return _empty();
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            itemCount: list.length + 1,
            itemBuilder: (context, i) {
              if (i == list.length) {
                return Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(
                    '首页只显示「已启用」的模块。长按首页卡片也可以快速移除。',
                    style: TextStyle(
                        color: _sub,
                        fontSize: AppTheme.fontCaption,
                        height: 1.5),
                  ),
                );
              }
              return _tile(list[i], i, list.length);
            },
          );
        },
      ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(36, 0, 36, 80),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.extension_outlined,
                  size: 36, color: _sub.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              Text('还没有导入 REX 模块',
                  style: TextStyle(
                      color: _fg,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('右上角可以粘贴模块地址或 .rex 集合地址。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: _sub,
                      fontSize: AppTheme.fontFootnote,
                      height: 1.6)),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accentColor,
                  foregroundColor: Colors.white,
                ),
                onPressed: _busy
                    ? null
                    : () async {
                        final ok = await showRexImportDialog(context);
                        if (ok && mounted) setState(() {});
                      },
                icon: const Icon(Icons.add_link_rounded, size: 18),
                label: const Text('导入模块'),
              ),
            ],
          ),
        ),
      );

  Widget _tile(RexModule m, int index, int total) {
    final host = Uri.tryParse(m.url)?.host ?? m.url;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(13, 12, 10, 4),
      decoration: BoxDecoration(
        color: _isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
        border: Border.all(
            color: _isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.06),
            width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.accentColor
                      .withValues(alpha: m.enabled ? 0.14 : 0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.extension_rounded,
                    size: 18,
                    color: m.enabled
                        ? AppTheme.accentColor
                        : _sub.withValues(alpha: 0.7)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(m.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: m.enabled ? _fg : _sub,
                                  fontSize: AppTheme.fontHeadline,
                                  fontWeight: FontWeight.w600)),
                        ),
                        if (m.version.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text('v${m.version}',
                              style: TextStyle(
                                  color: _sub,
                                  fontSize: AppTheme.fontCaption)),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$host · ${m.listFunctions.length} 个分类'
                      '${m.canSearch ? ' · 可搜索' : ''}'
                      '${m.canPlay ? ' · 可播放' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: _sub, fontSize: AppTheme.fontCaption),
                    ),
                  ],
                ),
              ),
              Switch(
                value: m.enabled,
                activeThumbColor: AppTheme.accentColor,
                onChanged: _busy
                    ? null
                    : (v) => _service.setEnabled(m.url, v),
              ),
            ],
          ),
          if (m.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 6),
              child: Text(m.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: _sub,
                      fontSize: AppTheme.fontFootnote,
                      height: 1.35)),
            ),
          const SizedBox(height: 4),
          Text(m.url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: _sub.withValues(alpha: 0.75),
                  fontSize: 10)),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _action(Icons.sync_rounded, '刷新',
                  _busy ? null : () => _refreshOne(m)),
              _action(Icons.link_rounded, '改地址',
                  _busy ? null : () => _editUrl(m)),
              _action(Icons.arrow_upward_rounded, '上移',
                  _busy || index == 0 ? null : () => _service.move(m.url, -1)),
              _action(Icons.arrow_downward_rounded, '下移',
                  _busy || index >= total - 1
                      ? null
                      : () => _service.move(m.url, 1)),
              _action(Icons.delete_outline, '删除',
                  _busy ? null : () => _confirmRemove(m)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback? onTap) =>
      TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: _sub,
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 7),
          visualDensity: VisualDensity.compact,
        ),
        onPressed: onTap,
        icon: Icon(icon, size: 15),
        label: Text(label,
            style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
      );

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
