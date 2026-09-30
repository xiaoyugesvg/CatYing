import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../services/live_service.dart';

/// 屏蔽分类 —— 独立管理页（对应参考图：右上「＋」新增，列表可删）
///
/// 与直播设置页原来的内联勾选相比：
///   - 这里只管"要屏蔽哪些分类名"，更聚焦
///   - 支持**手动输入**未出现在当前源里的分类名（换源后依然生效）
class BlockedCategoriesPage extends StatelessWidget {
  const BlockedCategoriesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = LiveService.instance;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text('屏蔽分类',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
        actions: [
          IconButton(
            icon: Icon(Icons.add, color: AppTheme.accentColor),
            tooltip: '添加分类',
            onPressed: () => _addCategory(context),
          ),
        ],
      ),
      body: Obx(() {
        final blocked = svc.blockedGroups;
        if (blocked.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.block,
                    size: 42,
                    color: AppTheme.textTertiary.withValues(alpha: 0.5)),
                const SizedBox(height: 14),
                Text('暂无屏蔽分类',
                    style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: AppTheme.fontSubhead)),
                const SizedBox(height: 6),
                Text('点右上角「＋」添加要屏蔽的分类名称',
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
          itemCount: blocked.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final name = blocked[i];
            return Container(
              decoration: BoxDecoration(
                color: AppTheme.backgroundCard,
                borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
                border:
                    Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 14),
                  Icon(Icons.block, size: 17, color: AppTheme.textSecondary),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(name,
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontSubhead + 0.5)),
                  ),
                  IconButton(
                    icon: Icon(Icons.close,
                        size: 18, color: AppTheme.textTertiary),
                    tooltip: '取消屏蔽',
                    onPressed: () => svc.toggleBlockedGroup(name),
                  ),
                ],
              ),
            );
          },
        );
      }),
    );
  }

  /// 添加分类：输入名称（可从当前源的分组里选，也可手输）
  Future<void> _addCategory(BuildContext context) async {
    final svc = LiveService.instance;
    final ctrl = TextEditingController();
    // 候选：当前源里还没被屏蔽的分组名
    final candidates = svc.groups
        .map((g) => g.name)
        .where((n) => !svc.blockedGroups.contains(n))
        .toList();

    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.glassRadius)),
        title: Text('添加分类',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              cursorColor: AppTheme.accentColor,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                hintText: '输入要屏蔽的分类名称',
                hintStyle: TextStyle(
                    color: AppTheme.textTertiary, fontSize: 13),
                filled: true,
                fillColor: AppTheme.backgroundTertiary,
                border: OutlineInputBorder(
                  borderRadius:
                      BorderRadius.circular(AppTheme.glassRadiusSmall),
                  borderSide:
                      BorderSide(color: AppTheme.accentColor, width: 1),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius:
                      BorderRadius.circular(AppTheme.glassRadiusSmall),
                  borderSide:
                      BorderSide(color: AppTheme.accentColor, width: 1),
                ),
              ),
            ),
            if (candidates.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('或从当前源选择：',
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final n in candidates.take(12))
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx, n),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppTheme.backgroundTertiary,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: AppTheme.borderLight, width: 0.5),
                        ),
                        child: Text(n,
                            style: TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: AppTheme.fontCaption)),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (name == null || name.isEmpty) return;
    if (!LiveService.instance.blockedGroups.contains(name)) {
      LiveService.instance.toggleBlockedGroup(name);
    }
  }
}
