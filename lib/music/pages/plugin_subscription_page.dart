// lib/music/pages/plugin_subscription_page.dart
//
// 「插件订阅」页 —— 2026-10-21 第三期。
//
// 一个订阅就是一个 registry/plugins.json 地址（MusicFree 生态的插件清单）。
//   · 不内置任何订阅，全部由用户自己添加
//   · 刷新后清单条目会出现在「插件市场」里

import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../widgets/app_toast.dart';
import '../models/plugin_subscription.dart';
import '../services/plugin_market_service.dart';
import '../theme/music_theme.dart';

class PluginSubscriptionPage extends StatefulWidget {
  const PluginSubscriptionPage({super.key});

  @override
  State<PluginSubscriptionPage> createState() => _PluginSubscriptionPageState();
}

class _PluginSubscriptionPageState extends State<PluginSubscriptionPage> {
  final _store = PluginSubscriptionStore.instance;
  final _market = PluginMarketService.instance;

  /// 正在刷新的订阅 id（'' = 全部）
  String? _busyId;

  @override
  void initState() {
    super.initState();
    // 打开时静默刷新一遍（订阅数量一般很少，代价很小）
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh({String? only}) async {
    if (_busyId != null) return;
    setState(() => _busyId = only ?? '');
    final n = await _market.refresh(only: only);
    if (!mounted) return;
    setState(() => _busyId = null);
    AppToast.success(n > 0 ? '已更新 $n 个订阅的插件清单' : '暂时没有可用清单（检查网络或地址）');
  }

  int _countFor(String subId) =>
      _market.entries.where((e) => e.subscriptionId == subId).length;

  Future<void> _add() async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MusicTheme.card,
        title: Text('添加订阅', style: TextStyle(color: MusicTheme.label)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              style: TextStyle(color: MusicTheme.label),
              decoration: const InputDecoration(
                labelText: '名称（可留空）',
                hintText: '例如：某某插件合集',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: urlCtrl,
              style: TextStyle(color: MusicTheme.label),
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'registry.json / plugins.json 地址',
                hintText: 'https://…/plugins.json',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: MusicTheme.secondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: MusicTheme.tint),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    final err = ok == true
        ? await _store.add(name: nameCtrl.text, url: urlCtrl.text)
        : null;
    nameCtrl.dispose();
    urlCtrl.dispose();
    if (!mounted) return;
    if (err != null) {
      AppToast.error(err);
      return;
    }
    if (ok == true) {
      // 新订阅立刻拉一次清单，用户能马上在市场里看到
      final sub = _store.all.last;
      setState(() => _busyId = sub.id);
      await _market.refresh(only: sub.id);
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _delete(PluginSubscription sub) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MusicTheme.card,
        title: Text('删除订阅', style: TextStyle(color: MusicTheme.label)),
        content: Text(
          '只删除订阅本身；已经安装的插件仍保留在「音乐源管理」里，不会被卸载。',
          style: TextStyle(color: MusicTheme.secondary, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: MusicTheme.secondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await _store.remove(sub.id);
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        backgroundColor: MusicTheme.background,
        appBar: AppBar(
          backgroundColor: MusicTheme.background,
          elevation: 0,
          iconTheme: IconThemeData(color: MusicTheme.label),
          title: Text(
            '插件订阅',
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontHeadline,
            ),
          ),
          actions: [
            IconButton(
              tooltip: '刷新全部',
              icon: Icon(Icons.refresh_rounded, color: MusicTheme.tint),
              onPressed: _busyId == null ? () => _refresh() : null,
            ),
            IconButton(
              tooltip: '添加订阅',
              icon: Icon(Icons.add_rounded, color: MusicTheme.tint),
              onPressed: _busyId == null ? _add : null,
            ),
          ],
        ),
        body: ValueListenableBuilder<int>(
          valueListenable: _store.revision,
          builder: (context, _, __) {
            final subs = _store.all;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
              children: [
                Text(
                  '订阅只是一个「插件清单」地址。刷新后，清单里的插件会出现在'
                  '「插件市场」，按需安装；装好的插件与内置源完全同权。',
                  style: TextStyle(
                    color: MusicTheme.secondary,
                    fontSize: AppTheme.fontFootnote,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                for (final s in subs) _subCard(s),
                if (subs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 40),
                    child: Center(
                      child: Text(
                        '还没有订阅，点右上角 + 添加',
                        style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontFootnote,
                        ),
                      ),
                    ),
                  ),
                if (_busyId == '')
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: MusicTheme.tint,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _subCard(PluginSubscription s) {
    final count = _countFor(s.id);
    final busy = _busyId == s.id;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
      decoration: BoxDecoration(
        color: MusicTheme.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Switch(
                value: s.enabled,
                activeThumbColor: MusicTheme.tint,
                onChanged: (v) => _store.setEnabled(s.id, v),
              ),
            ],
          ),
          Text(
            s.url,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: MusicTheme.secondary,
              fontSize: AppTheme.fontCaption,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                count > 0 ? '$count 个插件' : '还没有清单（点右侧刷新）',
                style: TextStyle(
                  color: MusicTheme.secondary,
                  fontSize: AppTheme.fontFootnote,
                ),
              ),
              const Spacer(),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                TextButton.icon(
                  onPressed: s.enabled ? () => _refresh(only: s.id) : null,
                  icon: Icon(Icons.refresh_rounded,
                      size: 16, color: MusicTheme.tint),
                  label: Text(
                    '刷新',
                    style: TextStyle(
                      color: MusicTheme.tint,
                      fontSize: AppTheme.fontFootnote,
                    ),
                  ),
                ),
              IconButton(
                tooltip: '删除订阅',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.delete_outline_rounded,
                    size: 18, color: MusicTheme.secondary),
                onPressed: () => _delete(s),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
