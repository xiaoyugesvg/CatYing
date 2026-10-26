import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/subscription.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/pages/subscription/pin_dialog.dart';
import 'package:tvbox/widgets/app_toast.dart';

/// 编辑订阅页 —— 对应参考图
///
/// 区块：数据源地址/名称 → 自动更新/上锁 → 上次更新/内容指纹 → 删除订阅
/// [subscription] 为 null 时是「新增」。
class SubscriptionEditPage extends StatefulWidget {
  final Subscription? subscription;

  const SubscriptionEditPage({super.key, this.subscription});

  @override
  State<SubscriptionEditPage> createState() => _SubscriptionEditPageState();
}

class _SubscriptionEditPageState extends State<SubscriptionEditPage> {
  final svc = SubscriptionService.instance;

  late final TextEditingController _urlCtrl;
  late final TextEditingController _nameCtrl;
  late bool _autoUpdate;
  late bool _locked;

  /// 所选分类。
  ///
  /// 2026-10-13 用户要求：**去掉「自动识别」**，分类固定为
  /// CatVod / TvBox / CMS / PY源 / T4源 / JS源（见 [SubscriptionKind.selectable]），
  /// 一行排 2 个。新建时默认 [SubscriptionKind.tvbox]。
  late SubscriptionKind _kind;

  bool get isNew => widget.subscription == null;

  @override
  void initState() {
    super.initState();
    final s = widget.subscription;
    _urlCtrl = TextEditingController(text: s?.url ?? '');
    _nameCtrl = TextEditingController(text: s?.name ?? '');
    _autoUpdate = s?.autoUpdate ?? true;
    _locked = s?.locked ?? false;
    // 新建默认 TvBox；编辑沿用已有分类（旧数据解析不出会是"未分类"）
    _kind = s?.kind ?? SubscriptionKind.tvbox;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(
          isNew ? '新增订阅' : '编辑订阅',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontTitle3,
          ),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(
              '保存',
              style: TextStyle(
                color: AppTheme.accentColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG,
          AppTheme.spacingSM,
          AppTheme.spacingLG,
          28,
        ),
        children: [
          // ---- 地址 / 名称 ----
          AppCard(
            dense: true,
            child: Column(
              children: [
                _labeledField(
                  label: '数据源地址',
                  controller: _urlCtrl,
                  hint: 'https://… 接口地址',
                  // 地址可能很长，允许多行展示
                  maxLines: 2,
                  trailing: Icon(
                    Icons.lock_outline,
                    size: 16,
                    color: AppTheme.textTertiary,
                  ),
                ),
                Divider(color: AppTheme.borderLight, height: 1, thickness: 0.5),
                _labeledField(
                  label: '名称',
                  controller: _nameCtrl,
                  hint: '给这个订阅起个名字',
                  trailing: GestureDetector(
                    onTap: () => setState(() => _nameCtrl.clear()),
                    child: Icon(
                      Icons.cancel,
                      size: 16,
                      color: AppTheme.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.spacingLG),

          // ---- 分类（导入分类，用于订阅管理分组显示）----
          AppCard(
            dense: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spacingXS,
                vertical: 12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '分类',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppTheme.spacingSM),
                  // 一行 2 个（用户 2026-10-13 要求）：
                  // CatVod / TvBox / CMS / PY源 / T4源 / JS源 —— 无「自动识别」。
                  for (var i = 0;
                      i < SubscriptionKind.selectable.length;
                      i += 2)
                    Padding(
                      padding: EdgeInsets.only(
                          top: i == 0 ? 0 : AppTheme.spacingSM),
                      child: Row(
                        children: [
                          Expanded(
                              child: _kindChip(SubscriptionKind.selectable[i])),
                          const SizedBox(width: AppTheme.spacingSM),
                          Expanded(
                            child: (i + 1 < SubscriptionKind.selectable.length)
                                ? _kindChip(SubscriptionKind.selectable[i + 1])
                                : const SizedBox(),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppTheme.spacingLG),

          // ---- 自动更新 / 上锁 ----
          AppCard(
            dense: true,
            child: Column(
              children: [
                _switchRow(
                  icon: Icons.sync,
                  title: '自动更新',
                  subtitle: '随启动自动同步最新内容',
                  value: _autoUpdate,
                  onChanged: (v) => setState(() => _autoUpdate = v),
                ),
                Divider(color: AppTheme.borderLight, height: 1, thickness: 0.5),
                _switchRow(
                  icon: Icons.lock,
                  title: '上锁',
                  subtitle: '上锁后需验证锁密码才可见',
                  value: _locked,
                  onChanged: _onLockChanged,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.spacingLG),

          // ---- 上次更新 / 内容指纹（仅编辑已有订阅时显示）----
          if (!isNew) ...[
            AppCard(
              dense: true,
              child: Column(
                children: [
                  _infoRow(
                    icon: Icons.schedule,
                    label: '上次更新',
                    value: widget.subscription!.lastUpdatedText,
                  ),
                  Divider(
                    color: AppTheme.borderLight,
                    height: 1,
                    thickness: 0.5,
                  ),
                  _infoRow(
                    icon: Icons.fingerprint,
                    label: '内容指纹',
                    value: widget.subscription!.fingerprint.isEmpty
                        ? '—'
                        : widget.subscription!.fingerprint,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppTheme.spacingLG),

            // ---- 删除订阅 ----
            AppCard(
              dense: true,
              child: InkWell(
                onTap: _confirmDelete,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.spacingXS,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: Colors.redAccent,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '删除订阅',
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontSize: AppTheme.fontSubhead + 0.5,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        Icons.chevron_right,
                        size: 17,
                        color: AppTheme.textTertiary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ============================================================
  // 组件
  // ============================================================

  Widget _labeledField({
    required String label,
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacingXS,
        vertical: 10,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: AppTheme.textTertiary,
              fontSize: AppTheme.fontCaption,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: AppTheme.backgroundTertiary,
              borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
              border: Border.all(color: AppTheme.borderLight, width: 0.5),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    maxLines: maxLines,
                    minLines: 1,
                    cursorColor: AppTheme.accentColor,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontBody,
                    ),
                    decoration: InputDecoration(
                      hintText: hint,
                      hintStyle: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontSubhead,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 分类选项（一行两个用 Expanded 撑满半宽）
  Widget _kindChip(SubscriptionKind k) => SelectableChip(
        title: k.label,
        isSelected: _kind == k,
        onTap: () => setState(() => _kind = k),
      );

  Widget _switchRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacingXS,
        vertical: 12,
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.accentColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 16, color: AppTheme.accentColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead + 0.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
              ],
            ),
          ),
          Transform.scale(
            scale: 0.9,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: AppTheme.accentColor,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacingXS,
        vertical: 14,
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: AppTheme.textSecondary),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontSubhead + 0.5,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: AppTheme.textTertiary,
              fontSize: AppTheme.fontSubhead,
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 行为
  // ============================================================

  /// 上锁时：没有 PIN 先引导设置，已有 PIN 则要求验证
  Future<void> _onLockChanged(bool v) async {
    if (!v) {
      setState(() => _locked = false);
      return;
    }
    if (!svc.pinSet.value) {
      final pin = await showDialog<String>(
        context: context,
        builder: (_) => const PinDialog(setup: true),
      );
      if (pin == null) return;
      await svc.setPin(pin);
      if (mounted) setState(() => _locked = true);
      return;
    }
    if (!svc.unlocked.value) {
      final r = await showDialog<String>(
        context: context,
        builder: (_) => const PinDialog(setup: false),
      );
      if (r == null || !r.startsWith('ok:')) return;
      final ok = await svc.verifyPin(r.substring(3));
      if (!ok) {
        if (mounted) {
          AppToast.message('密码不正确');
        }
        return;
      }
    }
    if (mounted) setState(() => _locked = true);
  }

  Future<void> _save() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      AppToast.message('请填写数据源地址');
      return;
    }
    final name = _nameCtrl.text.trim();
    // 分类由用户手选（「自动识别」已按用户要求去掉）
    final chosenKind = _kind;

    if (isNew) {
      final s = await svc.add(url: url, name: name, kind: chosenKind);
      s
        ..autoUpdate = _autoUpdate
        ..locked = _locked;
      await svc.update(s);
    } else {
      final s = widget.subscription!
        ..url = url
        ..name = name.isEmpty ? widget.subscription!.name : name
        ..autoUpdate = _autoUpdate
        ..locked = _locked
        ..kind = chosenKind;
      await svc.update(s);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    final s = widget.subscription!;
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
    if (ok != true) return;
    await svc.remove(s.id);
    if (mounted) Navigator.of(context).pop();
  }
}
