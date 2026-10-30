import 'package:flutter/material.dart';

import 'package:tvbox/widgets/engine_load_panel.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';

/// 设置 → 引擎管理
///
/// 给用户一个**手动加载**的兜底入口：Node（js/jar spider 引擎）与
/// Python（CPython，.py 源引擎）各一个按钮。自动启动失败、或切源后
/// 想强制把引擎拉起来时，点一下即可，不用重启 App。
///
/// 实际的行 UI 与首页右上角齿轮弹窗共用 [EngineLoadPanel]。
class EngineSettingsPage extends StatelessWidget {
  const EngineSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '引擎管理',
      help: const [
        SettingsHelpItem(
          icon: Icons.terminal_rounded,
          title: 'Node 引擎（.js / .jar 源）',
          body: 'JS 与 jar 爬虫源都跑在这个 Node 运行时里。App 启动时会自动拉起来，'
              '正常用不着管它。只有在「切了源却没反应」「某源一直报错」时，'
              '点一下「加载」强制重载一次 —— 不用重启 App。',
        ),
        SettingsHelpItem(
          icon: Icons.code_rounded,
          title: 'Python 引擎（.py 源）',
          body: '本地 PY / 订阅里的 Python 源跑在 CPython 里，与 Node 完全独立：'
              '一个挂了不影响另一个。同样是启动时自动加载，出问题才手动点。',
        ),
        SettingsHelpItem(
          icon: Icons.info_outline_rounded,
          title: '看到「加载中」一直不动怎么办',
          body: '说明引擎启动失败或端口没起来。先点「加载」重试一次；'
              '还不行就去「设置 → 订阅管理」确认源本身没问题，'
              '或到「日志诊断」看具体报错。',
        ),
      ],
      children: [
        SettingsGroup(
          title: '运行时引擎',
          hint: '自动加载失败、或切换源后想强制重载时，点右侧「加载」即可，无需重启 App。',
          children: const [EngineLoadPanel()],
        ),
      ],
    );
  }
}
