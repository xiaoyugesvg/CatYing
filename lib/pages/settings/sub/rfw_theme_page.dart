import 'package:flutter/material.dart';

import 'package:tvbox/pages/settings/sub/rfw_theme_section.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';

/// 设置 → 主页页面 → RFW 首页主题
///
/// ⚠️ **只作用于影视模块的首页**：换主题只改「分类 / 筛选 / 推荐 / 片单」
/// 这一块的排版与配色，音乐、阅读、直播、设置等页面完全不受影响。
/// 原因见 `RfwThemeEntry` 的注释 —— 主题能用的两个库
/// （`core.widgets` / `peek.home`）本来就是为首页片单设计的。
///
/// 2026-10-30：内容整块搬到 [RfwThemeSettingsSection]，与「主题与外观」
/// 管理页**引用同一份实现**。用户要求外观 / 壁纸 / RFW 主题收进一个入口，
/// 如果这里再维护一份副本，两边必然分叉（改一边忘另一边）。
/// 这个页面保留，是因为「主页页面」菜单里还有指向它的入口，不能断。
class RfwThemePage extends StatelessWidget {
  const RfwThemePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsSubPage(
      title: 'RFW 首页主题',
      help: [
        SettingsHelpItem(
          icon: Icons.dashboard_customize_outlined,
          title: '这是什么',
          body: '用一段文本（.rfwtxt）描述的**影视首页皮肤**：分类、筛选、推荐位、'
              '片单网格长什么样，全由主题决定。它只管首页，播放页/详情页/'
              '其它模块都不受影响。默认关闭，保持原生首页。',
        ),
        SettingsHelpItem(
          icon: Icons.palette_outlined,
          title: '配色会跟着软件走',
          body: '内置主题的颜色不是写死的，而是从「外观 → 配色」里你当前选的'
              '那套配色实时算出来的：换配色，首页跟着变。'
              '卡片里的缩略图就是真实渲染结果，换配色它也会立刻跟着变。',
        ),
        SettingsHelpItem(
          icon: Icons.visibility_outlined,
          title: '先预览再选',
          body: '每张主题卡右下角有「预览」：点开是全屏效果，可以现场切'
              '网格/列表/横幅等显示样式，满意了点「用这个主题」直接应用，'
              '不用来回退出去看首页。',
        ),
        SettingsHelpItem(
          icon: Icons.grid_view_rounded,
          title: '显示样式怎么选',
          body: '网格/大网格适合挑海报；列表信息多、扫得快；'
              '横幅适合有横图的源；纯文字列表最省流量。'
              '换样式只改排版，不改内容。',
        ),
        SettingsHelpItem(
          icon: Icons.upload_file_rounded,
          title: '导入自己的主题',
          body: '点主题条最后那张「导入主题」卡，选一个 .rfwtxt。主题只能引用'
              '内置的两个库（core.widgets / peek.home），越权的文件会被拒绝 —— '
              '这是防止主题拿到系统能力的安全边界。导入后长按可删除。',
        ),
        SettingsHelpItem(
          icon: Icons.report_problem_outlined,
          title: '首页显示成一片「?」或空白',
          body: '「?」是主题里的图标缺字体信息（老版本主题的问题，重新导入或换内置主题'
              '即可）。空白/报错说明主题解析失败，换回内置主题先保证能用。',
        ),
      ],
      children: [RfwThemeSettingsSection()],
    );
  }
}
