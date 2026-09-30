import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../services/book_service.dart';
import '../../../widgets/common_widgets.dart';
import 'settings_shared.dart';

/// 设置 → 书源管理（阅读 3.0 书源）
///
/// 三件事：导入（URL / 粘贴 / 文件）、启用停用、删除。
/// 不追求 Legado 书源编辑器的完整度 —— 目标是"导进来就能用"。
class BookSourceSettingsPage extends StatefulWidget {
  const BookSourceSettingsPage({super.key});

  @override
  State<BookSourceSettingsPage> createState() => _BookSourceSettingsPageState();
}

class _BookSourceSettingsPageState extends State<BookSourceSettingsPage> {
  BookService get svc => BookService.instance;

  final _urlCtrl = TextEditingController();
  final _pasteCtrl = TextEditingController();
  bool _busy = false;
  bool _pasteMode = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _pasteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '书源管理',
      children: [
        // ---------- 导入 ----------
        AppCard(
          dense: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('导入书源',
                          style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: AppTheme.fontSubhead + 1,
                              fontWeight: FontWeight.w600)),
                    ),
                    // 切换 粘贴 / URL
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _pasteMode = !_pasteMode),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Text(
                          _pasteMode ? '用网址导入' : '粘贴 JSON',
                          style: TextStyle(
                              color: AppTheme.accentColor,
                              fontSize: AppTheme.fontCaption),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (!_pasteMode) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundTertiary,
                      borderRadius:
                          BorderRadius.circular(AppTheme.glassRadiusSmall),
                      border:
                          Border.all(color: AppTheme.borderLight, width: 0.5),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: TextField(
                      controller: _urlCtrl,
                      cursorColor: AppTheme.accentColor,
                      style: TextStyle(
                          color: AppTheme.textPrimary, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: '书源 JSON 直链（如 https://…/id/123.json）',
                        hintStyle: TextStyle(
                            color: AppTheme.textTertiary, fontSize: 12.5),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _button(
                    _busy ? '导入中…' : '从网址导入',
                    filled: true,
                    onTap: _busy ? null : _importFromUrl,
                  ),
                ),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Container(
                    height: 130,
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundTertiary,
                      borderRadius:
                          BorderRadius.circular(AppTheme.glassRadiusSmall),
                      border:
                          Border.all(color: AppTheme.borderLight, width: 0.5),
                    ),
                    padding: const EdgeInsets.all(10),
                    child: TextField(
                      controller: _pasteCtrl,
                      maxLines: null,
                      expands: true,
                      cursorColor: AppTheme.accentColor,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 11,
                          fontFamily: 'monospace'),
                      decoration: InputDecoration(
                        hintText: '把书源 JSON 粘贴到这里（支持单个对象或数组）',
                        hintStyle: TextStyle(
                            color: AppTheme.textTertiary, fontSize: 12),
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _button(
                    _busy ? '导入中…' : '导入粘贴内容',
                    filled: true,
                    onTap: _busy ? null : _importPasted,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Text(
                  '说明：只支持「阅读 3.0」(Legado) 格式的书源 JSON。\n'
                  '依赖浏览器内核（webView）或 Java 解密（Packages.java）的源'
                  '可能无法正常取正文。',
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                      height: 1.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 已导入 ----------
        Obx(() {
          final list = svc.sources;
          if (list.isEmpty) {
            return SettingsGroup(
              title: '已导入',
              children: const [
                SettingsRow(
                  icon: Icons.info_outline,
                  title: '还没有书源',
                  value: '0 个',
                ),
              ],
            );
          }
          return SettingsGroup(
            title: '已导入（${list.length}）',
            children: [
              for (final s in list) _sourceRow(s),
              SettingsRow(
                icon: Icons.delete_sweep_outlined,
                iconColor: Colors.redAccent,
                titleColor: Colors.redAccent,
                title: '清空全部书源',
                value: '${list.length} 个',
                onTap: _confirmClearAll,
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget _sourceRow(BookSource s) {
    return Obx(() => _RowShell(
          icon: s.isComic
              ? Icons.photo_library_outlined
              : (s.isAudio ? Icons.headphones : Icons.menu_book_outlined),
          title: s.name,
          subtitle: [
            if (s.group.isNotEmpty) s.group,
            if (s.isComic) '漫画',
            if (s.isAudio) '有声',
            if (!s.hasSearch) '无搜索',
          ].join(' · '),
          trailing: Switch(
            value: s.enabled,
            activeColor: AppTheme.accentColor,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (v) => svc.setEnabled(s, v),
          ),
          onLongPress: () => _confirmRemove(s),
        ));
  }

  // ============================================================
  // 行为
  // ============================================================

  Future<void> _importFromUrl() async {
    final messenger = ScaffoldMessenger.of(context);
    final u = _urlCtrl.text.trim();
    if (u.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('请先填写网址')));
      return;
    }
    setState(() => _busy = true);
    final r = await svc.importFromUrl(u);
    if (!mounted) return;
    setState(() => _busy = false);
    _report(messenger, r.added, r.skipped, r.error);
  }

  Future<void> _importPasted() async {
    final messenger = ScaffoldMessenger.of(context);
    final t = _pasteCtrl.text.trim();
    if (t.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('请先粘贴内容')));
      return;
    }
    setState(() => _busy = true);
    final r = await svc.importJson(t);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.added > 0) _pasteCtrl.clear();
    _report(messenger, r.added, r.skipped, r.error);
  }

  void _report(
      ScaffoldMessengerState m, int added, int skipped, String error) {
    final String msg;
    if (error.isNotEmpty) {
      msg = error;
    } else if (added == 0 && skipped == 0) {
      msg = '没有解析到书源';
    } else if (added == 0) {
      msg = '全部已存在（更新 $skipped 个）';
    } else {
      msg = '成功导入 $added 个${skipped > 0 ? "，更新 $skipped 个" : ""}';
    }
    m.showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error.isNotEmpty ? Colors.redAccent : null,
    ));
  }

  Future<void> _confirmRemove(BookSource s) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.glassRadius)),
        title: Text('删除书源', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('删除「${s.name}」？',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await svc.remove(s.key);
    messenger.showSnackBar(SnackBar(content: Text('已删除「${s.name}」')));
  }

  Future<void> _confirmClearAll() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.glassRadius)),
        title:
            Text('清空书源', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('将删除全部书源，确定？',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await svc.clearAll();
    messenger.showSnackBar(const SnackBar(content: Text('已清空')));
  }

  Widget _button(String text, {required bool filled, VoidCallback? onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled
              ? AppTheme.accentColor
              : AppTheme.accentColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
        ),
        child: Text(text,
            style: TextStyle(
                color: filled ? Colors.white : AppTheme.accentColor,
                fontSize: 14,
                fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// 书源行外壳（图标 + 标题 + 副标题 + 右侧控件 + 长按）
class _RowShell extends StatelessWidget {
  const _RowShell({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.onLongPress,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spacingMD, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.accentColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: AppTheme.accentColor),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontSubhead + 0.5,
                          fontWeight: FontWeight.w500)),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontCaption)),
                  ],
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}
