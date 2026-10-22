import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../widgets/app_toast.dart';
import 'rex_service.dart';

/// 弹出「导入 REX 模块」对话框并执行导入。
///
/// 首页与订阅管理页共用，避免两处各写一份导入逻辑。
/// 返回值：是否成功导入了至少一个模块。
Future<bool> showRexImportDialog(BuildContext context) async {
  final ctrl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final isDark = Theme.of(ctx).brightness == Brightness.dark;
      final sub = isDark ? Colors.white54 : Colors.black54;
      return AlertDialog(
        title: const Text('导入 REX 模块'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                hintText: 'https://…/api/modules/<id>/raw\n'
                    '或 https://…/api/collections/xxx.rex',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '支持单个模块地址或 .rex 集合；集合会一次导入里面的所有模块。',
              style: TextStyle(
                  fontSize: AppTheme.fontCaption, color: sub, height: 1.5),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导入')),
        ],
      );
    },
  );
  final input = ctrl.text.trim();
  ctrl.dispose();
  if (ok != true) return false;
  if (input.isEmpty) {
    if (context.mounted) AppToast.show('先粘贴模块地址', '');
    return false;
  }

  try {
    final loaded = await RexService.instance.importFrom(input);
    await RexService.instance.addAll(loaded);
    if (context.mounted) {
      AppToast.show(
        loaded.length == 1
            ? '已导入「${loaded.first.title}」'
            : '已导入 ${loaded.length} 个模块',
        '',
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) AppToast.show('$e', '');
    return false;
  }
}
