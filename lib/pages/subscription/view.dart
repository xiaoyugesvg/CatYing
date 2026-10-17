import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../models/subscription.dart';
import '../../services/api_config.dart';
import '../../pages/settings/controller.dart';
import 'edit_page.dart';
import 'moontv_converter_page.dart';
import 'pin_dialog.dart';
import '../../widgets/app_toast.dart';

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
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(
          '订阅',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontTitle3,
          ),
        ),
        actions: [
          // 「同步」：手动触发所有勾了自动更新的订阅拉一遍（忽略时间节流）
          Obx(
            () => svc.syncingId.value.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: AppTheme.accentColor,
                        ),
                      ),
                    ),
                  )
                : IconButton(
                    icon: Icon(Icons.sync, color: AppTheme.accentColor),
                    tooltip: '立即同步全部',
                    onPressed: _syncAll,
                  ),
          ),
          // 「转换」：MoonTV / LunaTV video.json → TVBox 订阅
          IconButton(
            icon: Icon(Icons.swap_horiz_rounded, color: AppTheme.accentColor),
            tooltip: '影视仓转换器',
            onPressed: () => Get.to(() => const MoonTvConverterPage()),
          ),
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
                    fontWeight: FontWeight.w600,
                  ),
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
                Icon(
                  Icons.rss_feed,
                  size: 44,
                  color: AppTheme.textTertiary.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 14),
                Text(
                  '还没有订阅',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontSubhead,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '点右上角「＋」添加一个接口地址',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
              ],
            ),
          );
        }
        // 「当前激活」判定：直接按激活订阅的 id 精确命中。
        //
        // ── 为什么不用 SubscriptionService.active（getter 回退）──
        // `active` getter 在 activeId 找不到对应项时会**回退到第一条**，于是
        // "激活了第二个，第一个却一直亮着"。
        //
        // ── 为什么也不用 ApiConfig.configUrl（实际加载的地址）──
        // 激活流程里 `loadConfig()` 遇到**多仓库入口**会中断加载等用户挑选
        // （SettingsController.loadConfig 的 pending 分支直接 return），
        // 或网络加载失败时 configUrl 保持**上一条订阅的地址**——高亮永远
        // 停在旧订阅上（用户实测："激活第二个，但第一个常亮"）。
        //
        // activeId 是用户的明确选择：激活第二个后**立即**亮起第二个，
        // 不依赖网络加载是否成功；没有命中（id 失效）就都不亮，绝不回退。
        final activeId = svc.activeId.value;

        // 按「导入分类」分组显示：组标题 + 该组卡片。
        // 顺序按 SubscriptionKind.values 固定；空分组不显示。
        final grouped = <SubscriptionKind, List<Subscription>>{};
        for (final s in list) {
          grouped.putIfAbsent(s.kind, () => []).add(s);
        }
        final children = <Widget>[];
        for (final kind in SubscriptionKind.values) {
          final items = grouped[kind];
          if (items == null || items.isEmpty) continue;
          if (children.isNotEmpty) {
            // 组与组之间：留足一整段空白（24），上一组最后一张卡片不会贴着下一组标题
            children.add(const SizedBox(height: AppTheme.spacingXXL));
          }
          children.add(_groupHeader(kind, items.length));
          // 组标题与它下面第一张卡片之间：16，标题不会贴在卡片上
          children.add(const SizedBox(height: AppTheme.spacingLG));
          for (var i = 0; i < items.length; i++) {
            if (i > 0) {
              // 卡片之间：20，明显拉开（原来 16 太近，观感"贴在一起"）
              children.add(const SizedBox(height: AppTheme.spacingXL));
            }
            final s = items[i];
            children.add(_card(s, activeId.isNotEmpty && s.id == activeId));
          }
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spacingXL,
            AppTheme.spacingLG,
            AppTheme.spacingXL,
            AppTheme.spacingXXL,
          ),
          children: children,
        );
      }),
    );
  }

  /// 分组标题：分类图标 + 中文名 + 数量胶囊（用主题色，深浅都可读）
  Widget _groupHeader(SubscriptionKind kind, int count) {
    return Row(
      children: [
        Icon(kind.icon, size: 16, color: AppTheme.textSecondary),
        const SizedBox(width: AppTheme.spacingSM),
        Text(
          kind.label,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontSubhead + 0.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: AppTheme.spacingSM),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          decoration: BoxDecoration(
            color: AppTheme.accentColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(AppTheme.radiusMD),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              color: AppTheme.accentColor,
              fontSize: AppTheme.fontCaption,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _card(Subscription s, bool isActive) {
    return GestureDetector(
      onTap: () {
        if (_editing) return;
        _openEdit(s);
      },
      child: Container(
        // 内边距加大（14 → spacingLG=16），卡片不再显得挤
        padding: const EdgeInsets.all(AppTheme.spacingLG),
        decoration: BoxDecoration(
          color: isActive
              ? AppTheme.accentColor.withValues(alpha: 0.10)
              : AppTheme.backgroundCardElevated,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          // 统一 1px 描边：非激活改用更实的 glassBorder（原来 glassBorderSoft
          // 透明度只有 0.06/0.12，边几乎看不见，卡片在底上"糊成一片"）
          border: Border.all(
            color: isActive
                ? AppTheme.accentColor.withValues(alpha: 0.6)
                : AppTheme.glassBorder,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            // 分类图标
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: AppTheme.accentColor.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(AppTheme.radiusMD),
              ),
              child: Icon(s.kindIcon, size: 20, color: AppTheme.accentColor),
            ),
            const SizedBox(width: AppTheme.spacingMD),
            // 名称 + 分类徽标 / 地址 / 状态
            Expanded(
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
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (s.locked) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.lock,
                          size: 13,
                          color: AppTheme.textTertiary,
                        ),
                      ],
                      const SizedBox(width: AppTheme.spacingSM),
                      // 右上角：分类徽标
                      _kindBadge(s.kind),
                    ],
                  ),
                  const SizedBox(height: AppTheme.spacingSM),
                  // 地址（次要，小字、单行省略、可点击复制）
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _copyUrl(s),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            s.maskedUrl,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: AppTheme.fontCaption,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppTheme.spacingXS),
                        Icon(
                          Icons.copy_rounded,
                          size: 13,
                          color: AppTheme.textTertiary,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppTheme.spacingSM),
                  // 状态行：上次更新 / 自动更新 / 已上锁
                  Text(
                    _statusText(s),
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppTheme.spacingSM),
            // 右侧：编辑模式下是删除；否则是「激活 / 已激活」
            if (_editing)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _confirmDelete(s),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: Colors.redAccent,
                  ),
                ),
              )
            else
              _activateButton(s, isActive),
          ],
        ),
      ),
    );
  }

  /// 分类徽标（小胶囊，显示中文分类名）
  Widget _kindBadge(SubscriptionKind kind) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.accentColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
      ),
      child: Text(
        kind.label,
        style: TextStyle(
          color: AppTheme.accentColor,
          fontSize: AppTheme.fontCaption,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 状态行文案：上次更新 · 自动更新 · 已上锁
  String _statusText(Subscription s) {
    final parts = <String>[
      '上次更新 ${s.lastUpdatedText}',
      s.autoUpdate ? '自动更新' : '手动更新',
    ];
    if (s.locked) parts.add('已上锁');
    return parts.join(' · ');
  }

  /// 复制地址（上锁时复制脱敏后的地址，避免泄露真实地址）
  Future<void> _copyUrl(Subscription s) async {
    await Clipboard.setData(ClipboardData(text: s.maskedUrl));
    AppToast.message('已复制地址');
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
            color: AppTheme.accentColor.withValues(alpha: 0.5),
            width: 0.8,
          ),
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
    AppToast.message('已激活「${s.name}」');
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
      AppToast.message('密码不正确');
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
        AppToast.message('加载失败：$e');
      }
    }
  }

  /// 手动「立即同步全部」：忽略 6 小时节流，逐条拉一遍并回报结果。
  Future<void> _syncAll() async {
    final svc = SubscriptionService.instance;
    final targets = svc.subscriptions.where((s) => s.autoUpdate).toList();
    if (targets.isEmpty) {
      AppToast.message('没有开启「自动更新」的订阅');
      return;
    }
    await svc.syncAllNow();
    if (!mounted) return;
    AppToast.message(
      svc.lastSyncMessage.value.isEmpty ? '同步完成' : svc.lastSyncMessage.value,
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
          borderRadius: BorderRadius.circular(AppTheme.glassRadius),
        ),
        title: Text('删除订阅', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          '确定删除「${s.name}」？',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
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
