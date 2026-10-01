import 'package:flutter/material.dart';
import '../../widgets/common_widgets.dart';

import '../theme/jelly_theme.dart';
import 'about_page.dart';
import 'display_settings_page.dart';
import 'reading_settings_page.dart';

/// 阅读模块的设置入口。
///
/// ── 为什么放在书架页而不是照搬 cmbok 的「我的」页 ────────────────
/// cmbok 这三个设置页由 `me_page.dart` 打开，而那个页面依赖
/// `update_service` / `url_launcher`（原生插件）—— 本项目按硬约束
/// **没有引入**，所以不移植它。
/// 阅读相关的设置改成从**书架右上角**进，路径更短也更贴合使用场景。
Future<void> showReadingMenu(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: JellyTheme.backgroundLight,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => kbSheet(SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: JellyTheme.textSecondary.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          _item(
            ctx,
            icon: Icons.chrome_reader_mode_outlined,
            title: '阅读设置',
            subtitle: '翻页方式 / 自动隐藏 / 预加载',
            page: () => const ReadingSettingsPage(),
          ),
          _item(
            ctx,
            icon: Icons.grid_view_rounded,
            title: '显示设置',
            subtitle: '书架布局 / 导航栏 / 默认内容',
            page: () => const DisplaySettingsPage(),
          ),
          _item(
            ctx,
            icon: Icons.info_outline,
            title: '关于',
            subtitle: '版本与说明',
            page: () => const AboutPage(),
          ),
          const SizedBox(height: 8),
        ],
      ),
    )),
  );
}

Widget _item(
  BuildContext ctx, {
  required IconData icon,
  required String title,
  required String subtitle,
  required Widget Function() page,
}) {
  return ListTile(
    leading: Icon(icon, color: JellyTheme.primary, size: 22),
    title: Text(title,
        style: TextStyle(color: JellyTheme.textPrimaryLight, fontSize: 15)),
    subtitle: Text(subtitle,
        style: TextStyle(color: JellyTheme.textSecondary, fontSize: 12)),
    trailing: Icon(Icons.chevron_right,
        size: 18, color: JellyTheme.textSecondary),
    onTap: () {
      Navigator.pop(ctx);
      Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => page()));
    },
  );
}
