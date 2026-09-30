import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../models/subscription.dart';
import '../../services/api_config.dart';
import '../../pages/settings/controller.dart';
import 'edit_page.dart';
import 'pin_dialog.dart';

/// 订阅列表页 —— 多订阅管理
///
/// 对应参考图：卡片列表 + 「激活 / 已激活」+ 右上「编辑」「＋」。
/// 点卡片进入 [SubscriptionEditPage]。
class SubscriptionPage extends StatefulWidget {
  const SubscriptionPage({super.key});

  @override
  State<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends State<SubscriptionPage> {
  final svc = SubscriptionService.instance;

  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text('订阅',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
        actions: [
          // 「同步」：手动触发所有勾了自动更新的订阅拉一遍（忽略时间节流）
          Obx(() => svc.syncingId.value.isNotEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.8, color: AppTheme.accentColor),
                    ),
                  ),
                )
              : IconButton(
                  icon: Icon(Icons.sync, color: AppTheme.accentColor),
                  tooltip: '立即同步全部',
                  onPressed: _syncAll,
                )),
          // 「编辑」：进入后卡片右侧变成删除按钮
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _editing = !_editing),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Text(
                  _editing ? '完成' : '编辑',
                  style: TextStyle(
                      color: AppTheme.accentColor,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
          // 「＋」新增
          IconButton(
            icon: Icon(Icons.add, color: AppTheme.accentColor),
            tooltip: '新增订阅',
            onPressed: () => _openEdit(null),
          ),
        ],
      ),
      body: Obx(() {
        final list = svc.subscriptions;
        if (list.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.rss_feed,
                    size: 44,
                    color: AppTheme.textTertiary.withValues(alpha: 0.5)),
                const SizedBox(height: 14),
                Text('还没有订阅',
                    style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: AppTheme.fontSubhead)),
                const SizedBox(height: 6),
                Text('点右上角「＋」添加一个接口地址',
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption)),
              ],
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(
              AppTheme.spacingLG, AppTheme.spacingSM, AppTheme.spacingLG, 28),
          itemCount: list.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            final s = list[i];
            final isActive = svc.activeId.value == s.id;
            return _card(s, isActive);
          },
        );
      }),
    );
  }

  Widget _card(Subscription s, bool isActive) {
    return GestureDetector(
      onTap: () {
        if (_editing) return;
        _openEdit(s);
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isActive
              ? AppTheme.accentColor.withValues(alpha: 0.10)
              : AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          border: Border.all(
            color: isActive
                ? AppTheme.accentColor.withValues(alpha: 0.55)
                : AppTheme.glassBorderSoft,
            width: isActive ? 1.3 : 0.6,
          ),
        ),
        child: Row(
          children: [
            // 图标
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.accentColor.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
              ),
              child:
                  Icon(Icons.rss_feed, size: 20, color: AppTheme.accentColor),
            ),
            const SizedBox(width: 12),
            // 名称 + 地址 + 上次更新
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (s.locked) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.lock,
                            size: 13, color: AppTheme.textTertiary),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text('网络地址',
                          style: TextStyle(
                              color: AppTheme.textTertiary,
                              fontSize: AppTheme.fontCaption)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          s.maskedUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: AppTheme.fontCaption),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('上次更新 ${s.lastUpdatedText}',
                      style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 右侧：编辑模式下是删除；否则是「激活 / 已激活」
            if (_editing)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _confirmDelete(s),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.delete_outline,
                      size: 20, color: Colors.redAccent),
                ),
              )
            else
              _activateButton(s, isActive),
          ],
        ),
      ),
    );
  }

  Widget _activateButton(Subscription s, bool isActive) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: isActive ? null : () => _activate(s),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isActive
              ? AppTheme.accentColor
              : AppTheme.accentColor.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: AppTheme.accentColor.withValues(alpha: 0.5), width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isActive) ...[
              const Icon(Icons.check, size: 13, color: Colors.white),
              const SizedBox(width: 4),
            ],
            Text(
              isActive ? '已激活' : '激活',
              style: TextStyle(
                color: isActive ? Colors.white : AppTheme.accentColor,
                fontSize: AppTheme.fontCaption,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 激活 = 切换生效的订阅，并把它的地址交给 ApiConfig 真正加载
  Future<void> _activate(Subscription s) async {
    // 上锁的订阅需要先验证
    if (s.locked && svc.pinSet.value && !svc.unlocked.value) {
      final ok = await _askPin();
      if (!ok) return;
    }
    await svc.setActive(s.id);
    if (!mounted) return;
    await _applyActiveToApi();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已激活「${s.name}」')),
    );
  }

  Future<bool> _askPin() async {
    final r = await showDialog<String>(
      context: context,
      builder: (_) => const PinDialog(setup: false),
    );
    if (r == null || !r.startsWith('ok:')) return false;
    final pin = r.substring(3);
    final ok = await svc.verifyPin(pin);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('密码不正确')));
    }
    return ok;
  }

  /// 把激活订阅的地址写进 SettingsController 并重新加载配置
  Future<void> _applyActiveToApi() async {
    final a = svc.active;
    if (a == null) return;
    try {
      final sc = Get.isRegistered<SettingsController>()
          ? Get.find<SettingsController>()
          : Get.put(SettingsController());
      // SettingsController.loadConfig() 从 vodApiUrl 取值，
      // 所以先写入地址再触发加载（它内部会 loadConfigs + 持久化 + 记历史）
      sc.vodApiUrl.value = a.url;
      await sc.loadConfig();
      await svc.markSynced(a.id, ApiConfig.instance.configUrl.value);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载失败：$e')));
      }
    }
  }

  /// 手动「立即同步全部」：忽略 6 小时节流，逐条拉一遍并回报结果。
  Future<void> _syncAll() async {
    final svc = SubscriptionService.instance;
    final targets = svc.subscriptions.where((s) => s.autoUpdate).toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有开启「自动更新」的订阅')),
      );
      return;
    }
    await svc.syncAllNow();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(svc.lastSyncMessage.value.isEmpty
          ? '同步完成'
          : svc.lastSyncMessage.value)),
    );
  }

  Future<void> _openEdit(Subscription? s) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SubscriptionEditPage(subscription: s)),
    );
  }

  Future<void> _confirmDelete(Subscription s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.glassRadius)),
        title: Text('删除订阅',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('确定删除「${s.name}」？',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) await svc.remove(s.id);
  }
}
