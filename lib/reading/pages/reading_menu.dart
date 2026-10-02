import 'package:flutter/material.dart';
import '../../widgets/common_widgets.dart';

import '../theme/jelly_theme.dart';
import 'display_settings_page.dart';
import 'reading_settings_page.dart';
import '../../common/theme.dart';

/// 阅读模块的设置入口。
///
/// ── 为什么放在书架页而不是照搬 cmbok 的「我的」页 ────────────────
/// cmbok 这三个设置页由 `me_page.dart` 打开，而那个页面依赖
/// `url_launcher`（原生插件）—— 本项目按硬约束
/// **没有引入**，所以不移植它。
/// 阅读相关的设置改成从**书架右上角**进，路径更短也更贴合使用场景。
///
/// ⚠️ 按用户要求**去掉了「关于」入口**：
/// 原 cmbok 的「我的」页里还有 分享软件 / GitHub / QQ群 / 甜甜的小站
/// 等一堆外链，那些是原作者的推广与自更新通道，
/// 在猫影里没有意义（反而会跳转到别人的仓库/群），已全部移除。
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
              borderRadius: BorderRadius.circular(10),
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
        style: TextStyle(color: JellyTheme.textPrimaryLight, fontSize: AppTheme.fontHeadline)),
    subtitle: Text(subtitle,
        style: TextStyle(color: JellyTheme.textSecondary, fontSize: AppTheme.fontFootnote)),
    trailing: Icon(Icons.chevron_right,
        size: 18, color: JellyTheme.textSecondary),
    onTap: () {
      Navigator.pop(ctx);
      Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => page()));
    },
  );
}
