import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/subscription.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/pages/settings/controller.dart';
import 'package:tvbox/pages/subscription/edit_page.dart';
import 'package:tvbox/pages/subscription/pin_dialog.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/reading/widgets/swipe_action_tile.dart';

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

  /// 多选模式（长按卡片进入；右上角「编辑」也能进）
  bool _selectMode = false;
  final Set<String> _picked = <String>{};

  /// 正在激活的订阅 id（空 = 空闲）。
  /// 激活要重新加载整份配置（网络 + 引擎），需要即时反馈并防连点。
  String _activatingId = '';

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
          // 「编辑」：进入多选模式（长按卡片也能进）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() {
              _selectMode = !_selectMode;
              if (!_selectMode) _picked.clear();
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Text(
                  _selectMode ? '完成' : '编辑',
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
          if (!_selectMode)
            IconButton(
              icon: Icon(Icons.add, color: AppTheme.accentColor),
              tooltip: '新增订阅',
              onPressed: () => _openEdit(null),
            ),
        ],
      ),
      bottomNavigationBar: _selectMode ? _buildSelectBar() : null,
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
    final picked = _picked.contains(s.id);
    return SwipeActionTile(
      // 多选模式下关闭左滑，避免与勾选冲突
      enabled: !_selectMode,
      backgroundColor: AppTheme.backgroundCardElevated,
      borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
      actions: [
        SwipeAction(
          icon: Icons.edit_outlined,
          label: '编辑',
          color: AppTheme.accentColor,
          onTap: () => _openEdit(s),
        ),
        SwipeAction(
          icon: Icons.ios_share_rounded,
          label: '分享',
          color: const Color(0xFF3AA0FF),
          onTap: () => _copyUrl(s),
        ),
        SwipeAction(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          color: const Color(0xFFFF5A5A),
          onTap: () => _confirmDelete(s),
        ),
      ],
      child: GestureDetector(
        onTap: () {
          if (_selectMode) {
            _togglePick(s.id);
            return;
          }
          _openEdit(s);
        },
        onLongPress: () => _enterSelect(s.id),
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
              color: picked
                  ? AppTheme.accentColor
                  : (isActive
                        ? AppTheme.accentColor.withValues(alpha: 0.6)
                        : AppTheme.glassBorder),
              width: picked ? 1.4 : 1,
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
              // 右侧：多选模式显示勾选框；否则是「激活 / 已激活」
              if (_selectMode)
                Icon(
                  picked
                      ? Icons.check_box_rounded
                      : Icons.check_box_outline_blank_rounded,
                  size: 22,
                  color: picked ? AppTheme.accentColor : AppTheme.textTertiary,
                )
              else
                _activateButton(s, isActive),
            ],
          ),
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
    final busy = _activatingId == s.id;
    // 正在切换别的订阅时，全部禁用，避免并发 loadConfig
    final locked = _activatingId.isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: (isActive || locked) ? null : () => _activate(s),
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
            if (busy) ...[
              // 切换中：按钮内转圈（整页没有别的 loading 反馈）
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  // 激活成功后按钮变成实底白字，转圈也要跟着变白才看得见
                  color: isActive ? Colors.white : AppTheme.accentColor,
                ),
              ),
              const SizedBox(width: 6),
            ] else if (isActive) ...[
              const Icon(Icons.check, size: 13, color: Colors.white),
              const SizedBox(width: 4),
            ],
            Text(
              busy ? '切换中' : (isActive ? '已激活' : '激活'),
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
    // 正在切换时忽略再次点击（避免两次 loadConfig 并发、高亮来回跳）
    if (_activatingId.isNotEmpty) return;
    // 上锁的订阅需要先验证
    if (s.locked && svc.pinSet.value && !svc.unlocked.value) {
      final ok = await _askPin();
      if (!ok) return;
    }
    setState(() => _activatingId = s.id);
    try {
      await svc.setActive(s.id);
      if (!mounted) return;
      await _applyActiveToApi();
      if (!mounted) return;
      AppToast.message('已切换到「${s.name}」');
    } finally {
      if (mounted) setState(() => _activatingId = '');
    }
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

  // ============================================================
  // 多选
  // ============================================================

  void _enterSelect(String id) {
    setState(() {
      _selectMode = true;
      _picked.add(id);
    });
  }

  void _togglePick(String id) {
    setState(() {
      if (_picked.contains(id)) {
        _picked.remove(id);
      } else {
        _picked.add(id);
      }
    });
  }

  void _toggleAll() {
    final all = svc.subscriptions.map((e) => e.id).toSet();
    setState(() {
      if (_picked.length == all.length) {
        _picked.clear();
      } else {
        _picked
          ..clear()
          ..addAll(all);
      }
    });
  }

  Widget _buildSelectBar() {
    final all = svc.subscriptions;
    final allPicked = all.isNotEmpty && _picked.length == all.length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: AppTheme.backgroundSecondary,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              Text(
                '已选 ${_picked.length} 项',
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _toggleAll,
                child: Text(
                  allPicked ? '取消全选' : '全选',
                  style: const TextStyle(fontSize: AppTheme.fontSubhead),
                ),
              ),
              IconButton(
                tooltip: '复制所选地址',
                onPressed: _picked.isEmpty
                    ? null
                    : () async {
                        final urls = all
                            .where((s) => _picked.contains(s.id))
                            .map((s) => s.url)
                            .toList();
                        if (urls.isEmpty) return;
                        await Clipboard.setData(
                          ClipboardData(text: urls.join('\n')),
                        );
                        AppToast.message('已复制 ${urls.length} 个订阅地址');
                      },
                icon: Icon(
                  Icons.ios_share_rounded,
                  size: 20,
                  color: AppTheme.textSecondary,
                ),
              ),
              IconButton(
                tooltip: '删除所选',
                onPressed: _picked.isEmpty ? null : _deleteSelected,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: Colors.redAccent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteSelected() async {
    final n = _picked.length;
    if (n == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.glassRadius),
        ),
        title: Text('删除订阅', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          '确定删除选中的 $n 个订阅？',
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
    if (ok != true) return;
    for (final id in _picked.toList()) {
      await svc.remove(id);
    }
    if (!mounted) return;
    setState(() {
      _picked.clear();
      _selectMode = false;
    });
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
