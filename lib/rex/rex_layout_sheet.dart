import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../common/theme.dart';
import '../services/player_prefs.dart';
import '../widgets/common_widgets.dart';

/// REX 页面的「视图」面板（与影视首页「切换布局」同一套视觉）。
///
/// 返回值：`null` = 没改；`0` = 列表；`2/3/4` = 一行几列。
///
/// 列数跟首页共用 `PlayerPrefs.gridColumns`，用户在影视首页选过的列数
/// 直接沿用，不用在每个页面各记一套。
Future<int?> showRexLayoutSheet(
  BuildContext context, {
  required bool listMode,
  bool allowList = true,
  int maxColumns = 4,
}) {
  final prefs = PlayerPrefs.instance;
  return showModalBottomSheet<int>(
    context: context,
    backgroundColor: AppTheme.backgroundSecondary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) => kbSheet(
      SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text(
                '视图',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Text(
                allowList ? '列表，或一行显示几列' : '一行显示几列',
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Obx(() {
                // 读一下这个 Rx：外部改了列数，面板里的选中态跟着变
                final cols = prefs.gridColumns.value.clamp(2, 4);
                final width = (MediaQuery.of(ctx).size.width - 50) / 2;
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (allowList)
                      SizedBox(
                        width: width,
                        child: _cell(
                          ctx,
                          label: '列表',
                          selected: listMode,
                          columns: 0,
                          value: 0,
                        ),
                      ),
                    for (var n = 2; n <= maxColumns; n++)
                      SizedBox(
                        width: width,
                        child: _cell(
                          ctx,
                          label: '$n 列',
                          selected: !listMode && cols == n,
                          columns: n,
                          value: n,
                        ),
                      ),
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 单个选项格子：左侧用方块示意「列表 / N 列」，右侧文字。
Widget _cell(
  BuildContext ctx, {
  required String label,
  required bool selected,
  required int columns,
  required int value,
}) {
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () async {
      // 0 = 列表，不动列数偏好；>0 时才落盘
      if (value > 0) await PlayerPrefs.instance.setGridColumns(value);
      if (ctx.mounted) Navigator.pop(ctx, value);
    },
    child: Container(
      height: 62,
      decoration: BoxDecoration(
        color: selected
            ? AppTheme.accentColor.withValues(alpha: 0.14)
            : AppTheme.backgroundTertiary,
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
        border: Border.all(
          color: selected
              ? AppTheme.accentColor.withValues(alpha: 0.7)
              : AppTheme.glassBorderSoft,
          width: selected ? 1.2 : 0.6,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (columns == 0)
            // 列表：三条横杠
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 3; i++)
                  Container(
                    width: 20,
                    height: 3.5,
                    margin: const EdgeInsets.symmetric(vertical: 1.5),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppTheme.accentColor
                          : AppTheme.textTertiary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
              ],
            )
          else
            for (var i = 0; i < columns && i < 4; i++)
              Container(
                width: 7,
                height: 15,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: selected ? AppTheme.accentColor : AppTheme.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: selected ? AppTheme.accentColor : AppTheme.textSecondary,
              fontSize: AppTheme.fontSubhead,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    ),
  );
}
